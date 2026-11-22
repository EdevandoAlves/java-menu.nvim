-- java_menu/hierarchy.lua
-- Shared infrastructure for JDTLS hierarchy menus (`java_menu.calls` and
-- `java_menu.types`): operation/request lifecycle, cancellation, stale-callback
-- guards, explicit multi-client selection, encoding-aware position handling,
-- and safe `file://` + canonical virtual `jdt://` URI navigation.

local ui = require("java_menu.ui")
local lsp = require("java_menu.lsp")
local project = require("java_menu.project")

local M = {}

M.REQUEST_CANCELLED_CODE = -32800

-- Shared canonical jdt:// buffer ownership index so Call Hierarchy and Type
-- Hierarchy never duplicate or collide on virtual jdt:// buffers.
local jdt_bufs = {}

function M.reset_jdt_bufs()
  jdt_bufs = {}
end

function M.client_stopped(client)
  return not client or (type(client.is_stopped) == "function" and client:is_stopped())
end

---Check whether `client` supports `method` on `bufnr`, falling back to
---`server_capabilities[capability_key]` for plain table mocks.
---@param client table|nil
---@param method string
---@param bufnr number
---@param capability_key string|nil
---@return boolean
function M.supports_method(client, method, bufnr, capability_key)
  if M.client_stopped(client) then
    return false
  end
  if type(client.supports_method) == "function" then
    return client:supports_method(method, bufnr) == true
  end
  if not capability_key or type(client.server_capabilities) ~= "table" then
    return false
  end
  local cap = client.server_capabilities[capability_key]
  return cap ~= nil and cap ~= false
end

function M.is_file_uri(uri)
  return type(uri) == "string" and vim.startswith(uri, "file://")
end

function M.is_jdt_uri(uri)
  return type(uri) == "string" and vim.startswith(uri, "jdt://")
end

function M.is_valid_range(range)
  return type(range) == "table"
    and type(range.start) == "table"
    and type(range.start.line) == "number"
    and type(range.start.character) == "number"
end

function M.zero_range()
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 0 },
  }
end

function M.pick_range(...)
  for i = 1, select("#", ...) do
    local candidate = select(i, ...)
    if M.is_valid_range(candidate) then
      return candidate
    end
  end
  return M.zero_range()
end

---Readable location label for a URI without assuming physical disk paths for
---virtual schemes such as `jdt://`.
---@param uri string
---@param project_root string|nil
---@return string
function M.uri_label(uri, project_root)
  if M.is_file_uri(uri) then
    local path = vim.fs.normalize(vim.uri_to_fname(uri))
    if project_root and project_root ~= "" then
      local rel = vim.fs.relpath(project_root, path)
      if rel and rel ~= "" then
        return rel
      end
    end
    local short = vim.fn.fnamemodify(path, ":~:.")
    return (short ~= "" and short) or vim.fn.fnamemodify(path, ":t")
  end
  if M.is_jdt_uri(uri) then
    local inner = uri:match("^jdt://contents/([^?]+)")
    if inner and inner ~= "" then
      return "jdt://" .. inner
    end
    local base = uri:match("^([^?]+)")
    return (base and base ~= "" and base) or "jdt://class"
  end
  return tostring(uri)
end

function M.format_symbol(item)
  local name = (type(item.name) == "string" and item.name ~= "") and item.name or "(symbol)"
  if type(item.detail) == "string" and item.detail ~= "" and item.detail ~= name then
    return string.format("%s  [%s]", name, item.detail)
  end
  return name
end

function M.unique_label(text, seen)
  if not seen[text] then
    seen[text] = true
    return text
  end
  local n = 2
  while seen[text .. "  #" .. n] do
    n = n + 1
  end
  local unique = text .. "  #" .. n
  seen[unique] = true
  return unique
end

function M.build_position_params(bufnr, cursor, client)
  local encoding = lsp.encoding(client)
  local row = math.max(0, (cursor[1] or 1) - 1)
  local byte_col = math.max(0, cursor[2] or 0)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local ok, char = pcall(vim.str_utfindex, line, encoding, math.min(byte_col, #line))
  local character = (ok and type(char) == "number") and char or byte_col
  local text_doc = vim.lsp.util.make_text_document_params(bufnr)
  local jdt_uri = vim.b[bufnr] and vim.b[bufnr].java_menu_jdt_uri
  if type(jdt_uri) == "string" and jdt_uri ~= "" then
    text_doc.uri = jdt_uri
  end
  return {
    textDocument = text_doc,
    position = { line = row, character = character },
  }
end

function M.capture_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok_word, word = pcall(vim.fn.expand, "<cword>")
  return {
    bufnr = bufnr,
    win = win,
    cursor = vim.api.nvim_win_get_cursor(win),
    tick = vim.b[bufnr].changedtick,
    project_root = project.root(bufnr),
    cword = (ok_word and type(word) == "string") and word or "",
  }
end

function M.context_still_valid(ctx, check_tick, notify_on_mismatch, feature_label)
  local what = feature_label or "hierarchy"
  if not (ctx and ctx.bufnr and vim.api.nvim_buf_is_valid(ctx.bufnr)) then
    if ctx and notify_on_mismatch then
      ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    end
    return false
  end
  if ctx.win ~= nil then
    if
      not vim.api.nvim_win_is_valid(ctx.win)
      or vim.api.nvim_get_current_win() ~= ctx.win
      or vim.api.nvim_win_get_buf(ctx.win) ~= ctx.bufnr
    then
      if notify_on_mismatch then
        ui.notify("the window or buffer changed during " .. what .. " — run the operation again", vim.log.levels.WARN)
      end
      return false
    end
  end
  if vim.api.nvim_get_current_buf() ~= ctx.bufnr then
    if notify_on_mismatch then
      ui.notify("the buffer changed during " .. what .. " — run the operation again", vim.log.levels.WARN)
    end
    return false
  end
  if check_tick and ctx.tick ~= nil and vim.b[ctx.bufnr].changedtick ~= ctx.tick then
    if notify_on_mismatch then
      ui.notify("the buffer changed during " .. what .. " — run the operation again", vim.log.levels.WARN)
    end
    return false
  end
  return true
end

local function filetype_for_jdt_uri(uri)
  local class_fn = uri:match("contents/[^/]+/[%a%d._-]+/([^?]+)") or ""
  local class_ext = vim.fn.fnamemodify(class_fn, ":e")
  if class_fn ~= "" and class_ext ~= "class" and vim.filetype and vim.filetype.match then
    local ok, ft = pcall(vim.filetype.match, { filename = class_fn })
    if ok and ft then
      return ft
    end
  end
  return "java"
end

local function buffer_has_content(bufnr)
  if not (bufnr and bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)) then
    return false
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  if count > 1 then
    return true
  end
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  return first ~= ""
end

local function client_root_key(client)
  if type(client) == "table" and type(client.root_dir) == "string" and client.root_dir ~= "" then
    return vim.fs.normalize(client.root_dir)
  end
  return ""
end

local function make_owner(client, uri)
  return {
    client_id = client and client.id,
    root_dir = client_root_key(client),
    uri = uri,
  }
end

local function owner_key(client, uri)
  return string.format("%s\0%s\0%s", tostring(client and client.id or ""), client_root_key(client), tostring(uri))
end

local function has_foreign_client(bufnr, client)
  local my_id = client and client.id
  for _, attached in ipairs(vim.lsp.get_clients({ bufnr = bufnr }) or {}) do
    if attached.id ~= my_id then
      return true
    end
  end
  return false
end

local function owner_matches(bufnr, client, uri)
  if not (bufnr and bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and client) then
    return false
  end
  if vim.api.nvim_buf_get_name(bufnr) ~= uri then
    return false
  end
  local owner = vim.b[bufnr].java_menu_jdt_owner
  if type(owner) ~= "table" then
    return false
  end
  if owner.uri ~= uri or owner.client_id ~= client.id or owner.root_dir ~= client_root_key(client) then
    return false
  end
  if has_foreign_client(bufnr, client) then
    return false
  end
  return true
end

local function find_buf_by_exact_name(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return -1
end

local function find_owned_jdt_buffer(client, uri)
  local key = owner_key(client, uri)
  local tracked = jdt_bufs[key]
  if tracked then
    if owner_matches(tracked, client, uri) and buffer_has_content(tracked) then
      return tracked
    end
    jdt_bufs[key] = nil
  end
  local exact = find_buf_by_exact_name(uri)
  if exact ~= -1 and owner_matches(exact, client, uri) and buffer_has_content(exact) then
    jdt_bufs[key] = exact
    return exact
  end
  return nil
end

local function attach_client_if_live(bufnr, client)
  if
    client
    and type(client.id) == "number"
    and vim.lsp.get_client_by_id(client.id) ~= nil
    and not has_foreign_client(bufnr, client)
    and not vim.lsp.buf_is_attached(bufnr, client.id)
  then
    pcall(vim.lsp.buf_attach_client, bufnr, client.id)
  end
end

local function jdt_collision_reason(existing, client, uri)
  local label = M.uri_label(uri)
  local target_client = tostring((client and client.id) or "?")
  local owner = vim.b[existing].java_menu_jdt_owner
  if type(owner) == "table" then
    return string.format(
      "cannot open %s for jdtls #%s: canonical jdt:// buffer is already owned by jdtls #%s (close the existing buffer first; synthetic jdt:// URIs are not used so LSP requests preserve the canonical URI)",
      label,
      target_client,
      tostring(owner.client_id or "?")
    )
  end
  if has_foreign_client(existing, client) then
    return string.format(
      "cannot open %s for jdtls #%s: canonical jdt:// buffer is already attached to another LSP client",
      label,
      target_client
    )
  end
  return string.format(
    "cannot open %s for jdtls #%s: canonical jdt:// buffer already exists with unowned content",
    label,
    target_client
  )
end

-- Check canonical jdt:// buffer availability without creating a buffer.
-- Neovim LSP derives textDocument.uri from the buffer name, so creating a
-- synthetic `jdt://client-...` buffer and attaching it to LSP would send
-- invented URIs in didOpen/hover/definition. When a collision prevents safe
-- isolation under the canonical URI, refuse opening with a clear reason.
local function jdt_buffer_collision(uri, client)
  local existing = find_buf_by_exact_name(uri)
  if existing == -1 then
    return nil, nil
  end
  if
    owner_matches(existing, client, uri)
    or (
      not vim.api.nvim_buf_is_loaded(existing)
      and not buffer_has_content(existing)
      and vim.b[existing].java_menu_jdt_owner == nil
      and not has_foreign_client(existing, client)
    )
  then
    return existing, nil
  end
  return nil, jdt_collision_reason(existing, client, uri)
end

local function allocate_jdt_buffer(uri, client)
  local owned = find_owned_jdt_buffer(client, uri)
  if owned then
    return owned, false, nil
  end
  local reusable, collision_reason = jdt_buffer_collision(uri, client)
  if collision_reason then
    return nil, false, collision_reason
  end
  if reusable then
    return reusable, false, nil
  end
  return vim.uri_to_bufnr(uri), true, nil
end

local function append_eventignore(existing, extra)
  if existing == "all" then
    return "all"
  end
  if existing == "" then
    return extra
  end
  return existing .. "," .. extra
end

-- Arbitrary FileType autocmds and user/plugin runtimepath ftplugin/ scripts
-- (e.g. nvim-jdtls start_or_attach, nvim-lspconfig, vim.lsp.enable) cannot be
-- executed with proven isolation in Neovim: running them after content is
-- loaded can immediately attach a foreign client and leak buffer text via
-- textDocument/didOpen, while running them before content is loaded cannot
-- prevent deferred attachments (vim.schedule, async vim.lsp.start, BufEnter).
-- We therefore keep FileType suppressed on virtual jdt:// buffers and apply
-- only Neovim's bundled $VIMRUNTIME ftplugin and syntax rules locally.
local function init_safe_local_filetype(bufnr, ft)
  if type(ft) ~= "string" or ft == "" then
    return
  end
  local parts = vim.split(ft, ".", { plain = true })
  for _, part in ipairs(parts) do
    if not part:match("^[%a%d_-]+$") then
      return
    end
  end

  local vr = vim.env.VIMRUNTIME
  if type(vr) ~= "string" or vr == "" or vim.fn.isdirectory(vr) ~= 1 then
    return
  end

  local load_ftplugin = (vim.g.did_load_ftplugin ~= nil and vim.g.did_load_ftplugin ~= 0)
    and not vim.b[bufnr].did_ftplugin
  local load_syntax = (vim.g.syntax_on ~= nil and vim.g.syntax_on ~= 0) and not vim.b[bufnr].ts_highlight
  if not load_ftplugin and not load_syntax then
    return
  end

  vim.api.nvim_buf_call(bufnr, function()
    local saved_rtp = vim.o.runtimepath
    local ok_rt, rt_err = pcall(function()
      -- Confine runtime! strictly to bundled $VIMRUNTIME so user/plugin
      -- ftplugin/ and syntax/ entries on runtimepath cannot execute here.
      vim.opt.runtimepath = { vr }
      for _, name in ipairs(parts) do
        if load_ftplugin then
          vim.cmd(
            string.format(
              "silent! runtime! ftplugin/%s[.]{vim,lua} ftplugin/%s_*.{vim,lua} ftplugin/%s/*.{vim,lua}",
              name,
              name,
              name
            )
          )
        end
        if load_syntax then
          vim.cmd(string.format("silent! runtime! syntax/%s[.]{vim,lua} syntax/%s/*.{vim,lua}", name, name))
        end
      end
      if load_syntax then
        vim.bo[bufnr].syntax = ft
      end
    end)
    vim.o.runtimepath = saved_rtp
    if not ok_rt then
      error(rt_err)
    end
  end)
end

local function populate_jdt_buffer(uri, content, client)
  local jdt_buf, created_new, collision_reason = allocate_jdt_buffer(uri, client)
  if not jdt_buf then
    return nil, collision_reason
  end
  local saved_ei = vim.o.eventignore
  -- Suppress buffer-entry and filetype hooks during initialization, including
  -- the temporary window used by nvim_buf_call. Later user autocmds remain
  -- free to attach clients after the buffer is shown.
  vim.o.eventignore =
    append_eventignore(saved_ei, "BufReadCmd,BufNewFile,BufEnter,BufWinEnter,FileType,Syntax,OptionSet")
  local ok, err = pcall(function()
    vim.fn.bufload(jdt_buf)
    if has_foreign_client(jdt_buf, client) then
      error("canonical jdt:// buffer was attached to another LSP client")
    end
    vim.bo[jdt_buf].buftype = "nofile"
    vim.bo[jdt_buf].bufhidden = "hide"
    vim.bo[jdt_buf].swapfile = false
    vim.bo[jdt_buf].modifiable = true
    local normalized = content:gsub("\r\n", "\n")
    local lines = vim.split(normalized, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(jdt_buf, 0, -1, false, lines)
    vim.bo[jdt_buf].modifiable = false
    vim.bo[jdt_buf].modified = false
    local ft = filetype_for_jdt_uri(uri)
    vim.bo[jdt_buf].filetype = ft
    vim.b[jdt_buf].java_menu_jdt_uri = uri
    vim.b[jdt_buf].java_menu_jdt_owner = make_owner(client, uri)
    init_safe_local_filetype(jdt_buf, ft)
  end)
  vim.o.eventignore = saved_ei
  if not ok then
    if created_new and vim.api.nvim_buf_is_valid(jdt_buf) then
      pcall(vim.api.nvim_buf_delete, jdt_buf, { force = true })
    end
    error(err)
  end
  jdt_bufs[owner_key(client, uri)] = jdt_buf
  attach_client_if_live(jdt_buf, client)
  return jdt_buf, nil
end

function M.jump_to_loaded_buffer(win, target_buf, range, encoding)
  if not vim.api.nvim_buf_is_valid(target_buf) then
    return false
  end
  local target_win = vim.api.nvim_win_is_valid(win) and win or vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(target_win)

  pcall(vim.cmd, "normal! m'")
  local from = { vim.fn.bufnr("%"), vim.fn.line("."), vim.fn.col("."), 0 }
  local ok_word, word = pcall(vim.fn.expand, "<cword>")
  local tagname = (ok_word and type(word) == "string") and word or ""
  pcall(vim.fn.settagstack, vim.fn.win_getid(target_win), {
    items = { { tagname = tagname, from = from } },
  }, "t")

  vim.bo[target_buf].buflisted = true
  vim.api.nvim_win_set_buf(target_win, target_buf)

  local line_count = math.max(1, vim.api.nvim_buf_line_count(target_buf))
  local raw_line = (M.is_valid_range(range) and range.start.line) or 0
  local row0 = math.max(0, math.min(raw_line, line_count - 1))
  local raw_char = (M.is_valid_range(range) and range.start.character) or 0
  local line_text = vim.api.nvim_buf_get_lines(target_buf, row0, row0 + 1, false)[1] or ""
  local col = 0
  if raw_char > 0 and #line_text > 0 then
    local ok, byte_col = pcall(vim.str_byteindex, line_text, encoding or "utf-16", raw_char, false)
    if ok and type(byte_col) == "number" then
      col = math.max(0, math.min(byte_col, #line_text))
    else
      col = #line_text
    end
  end

  pcall(vim.api.nvim_win_set_cursor, target_win, { row0 + 1, col })
  pcall(vim.cmd, "normal! zv")
  return true
end

local Controller = {}
Controller.__index = Controller

---Create an isolated operation/request controller for a hierarchy menu module.
---@param opts { feature_label?: string }|nil
function M.new_controller(opts)
  opts = opts or {}
  return setmetatable({
    _seq = 0,
    _active_op = nil,
    _pending = nil, -- { op_token, token, client, request_id, bufnr, label }
    feature_label = opts.feature_label or "hierarchy",
  }, Controller)
end

function Controller:seq()
  return self._seq
end

function Controller:pending()
  return self._pending
end

function Controller:is_op_active(op_token)
  return op_token ~= nil and self._active_op == op_token
end

function Controller:_cancel_pending_request()
  local pending = self._pending
  if not pending then
    return nil
  end
  self._pending = nil
  if pending.request_id ~= nil and pending.client and type(pending.client.cancel_request) == "function" then
    pcall(pending.client.cancel_request, pending.client, pending.request_id)
  end
  return pending
end

function Controller:end_operation(op_token)
  if self:is_op_active(op_token) then
    self:_cancel_pending_request()
    self._active_op = nil
  end
end

function Controller:is_request_current(op_token, req_token)
  return self:is_op_active(op_token)
    and self._pending ~= nil
    and self._pending.token == req_token
    and self._pending.op_token == op_token
end

function Controller:clear_pending(req_token)
  if self._pending ~= nil and self._pending.token == req_token then
    self._pending = nil
  end
end

function Controller:cancel(notify_user)
  local pending = self:_cancel_pending_request()
  self._active_op = nil
  self._seq = self._seq + 1
  if pending and notify_user then
    ui.notify(self.feature_label .. " request cancelled", vim.log.levels.INFO)
  end
  return pending ~= nil
end

function Controller:reset()
  self:cancel(false)
  M.reset_jdt_bufs()
end

function Controller:begin_operation()
  self:_cancel_pending_request()
  self._seq = self._seq + 1
  local op_token = self._seq
  self._active_op = op_token
  return op_token
end

function Controller:begin_request(op_token, client, bufnr, label)
  if not self:is_op_active(op_token) then
    return nil
  end
  self:_cancel_pending_request()
  self._seq = self._seq + 1
  local req_token = self._seq
  self._pending = {
    op_token = op_token,
    token = req_token,
    client = client,
    request_id = nil,
    bufnr = bufnr,
    label = label,
  }
  return req_token
end

function Controller:attach_request_id(op_token, req_token, ok, req_id)
  if not ok then
    self:clear_pending(req_token)
    self:end_operation(op_token)
    return false
  end
  if self:is_request_current(op_token, req_token) then
    self._pending.request_id = req_id
  end
  return true
end

function Controller:context_still_valid(ctx, check_tick, notify_on_mismatch)
  return M.context_still_valid(ctx, check_tick, notify_on_mismatch, self.feature_label)
end

function Controller:handle_request_error(err, action_label)
  if type(err) == "table" and err.code == M.REQUEST_CANCELLED_CODE then
    ui.notify(self.feature_label .. " request was cancelled", vim.log.levels.INFO)
    return
  end
  local msg = (type(err) == "table" and err.message) or vim.inspect(err)
  ui.notify(action_label .. " failed: " .. tostring(msg), vim.log.levels.ERROR)
end

function Controller:menu_availability(bufnr, supports_fn, missing_reason)
  local clients = lsp.clients(bufnr)
  if #clients == 0 then
    return false, "jdtls is not attached to this buffer"
  end
  for _, client in ipairs(clients) do
    if supports_fn(client, bufnr) then
      return true, nil
    end
  end
  return false, missing_reason
end

local function client_label(client, bufnr, supports_fn, unsupported_tag)
  local root_desc = (type(client.root_dir) == "string" and client.root_dir ~= "")
      and (vim.fs.basename(client.root_dir) .. " — " .. client.root_dir)
    or "no root_dir"
  local cap = supports_fn(client, bufnr) and "" or (" " .. unsupported_tag)
  return string.format("#%s %s (%s)%s", tostring(client.id or "?"), client.name or "jdtls", root_desc, cap)
end

function Controller:select_client(op_token, ctx, opts, on_client)
  if not self:is_op_active(op_token) then
    return
  end
  if not self:context_still_valid(ctx, true, true) then
    self:end_operation(op_token)
    return
  end

  local clients = lsp.clients(ctx.bufnr)
  if #clients == 0 then
    ui.notify("jdtls is not attached to this buffer", vim.log.levels.WARN)
    self:end_operation(op_token)
    return
  end

  if #clients == 1 then
    local client = clients[1]
    if not opts.supports(client, ctx.bufnr) then
      ui.notify("jdtls client " .. opts.unsupported_reason, vim.log.levels.WARN)
      self:end_operation(op_token)
      return
    end
    on_client(client)
    return
  end

  local labels, by_label, seen = {}, {}, {}
  for _, client in ipairs(clients) do
    local label = M.unique_label(client_label(client, ctx.bufnr, opts.supports, opts.unsupported_tag), seen)
    labels[#labels + 1] = label
    by_label[label] = client
  end

  ui.pick_one(labels, opts.prompt, function(choice)
    if not self:is_op_active(op_token) then
      return
    end
    local picked = by_label[choice]
    if not picked then
      self:end_operation(op_token)
      return
    end
    if not self:context_still_valid(ctx, true, true) then
      self:end_operation(op_token)
      return
    end
    if M.client_stopped(picked) then
      ui.notify("selected jdtls client is no longer running", vim.log.levels.WARN)
      self:end_operation(op_token)
      return
    end
    if not opts.supports(picked, ctx.bufnr) then
      ui.notify("selected jdtls client " .. opts.unsupported_reason, vim.log.levels.WARN)
      self:end_operation(op_token)
      return
    end
    on_client(picked)
  end)
end

function Controller:request(op_token, client, bufnr, method, params, label, ctx, on_result)
  if not self:is_op_active(op_token) then
    return false
  end
  if not self:context_still_valid(ctx, true, true) then
    self:end_operation(op_token)
    return false
  end
  if M.client_stopped(client) then
    ui.notify("jdtls client stopped during " .. self.feature_label, vim.log.levels.WARN)
    self:end_operation(op_token)
    return false
  end

  local req_token = self:begin_request(op_token, client, bufnr, label)
  if not req_token then
    return false
  end

  local ok, req_id = client:request(method, params, function(err, result)
    vim.schedule(function()
      if not self:is_request_current(op_token, req_token) then
        return
      end
      self:clear_pending(req_token)

      if err then
        self:handle_request_error(err, method)
        self:end_operation(op_token)
        return
      end
      if M.client_stopped(client) then
        ui.notify("jdtls client stopped during " .. self.feature_label, vim.log.levels.WARN)
        self:end_operation(op_token)
        return
      end
      if not self:context_still_valid(ctx, true, true) then
        self:end_operation(op_token)
        return
      end

      on_result(result)
    end)
  end, bufnr)

  if not self:attach_request_id(op_token, req_token, ok, req_id) then
    ui.notify("failed to send " .. method .. " request to jdtls", vim.log.levels.ERROR)
    return false
  end
  return true
end

function Controller:choose_prepared_item(op_token, items, ctx, opts, on_item)
  if not self:is_op_active(op_token) then
    return
  end
  if type(items) ~= "table" or #items == 0 then
    ui.notify(opts.empty_reason, vim.log.levels.WARN)
    self:end_operation(op_token)
    return
  end

  if #items == 1 then
    on_item(items[1])
    return
  end

  local labels, by_label, seen = {}, {}, {}
  for _, item in ipairs(items) do
    local loc = type(item.uri) == "string" and M.uri_label(item.uri, ctx.project_root) or ""
    local r = M.pick_range(item.selectionRange, item.range)
    local text = loc ~= "" and string.format("%s  %s:%d", M.format_symbol(item), loc, r.start.line + 1)
      or M.format_symbol(item)
    local label = M.unique_label(text, seen)
    labels[#labels + 1] = label
    by_label[label] = item
  end

  ui.pick_one(labels, opts.prompt, function(choice)
    if not self:is_op_active(op_token) then
      return
    end
    local picked = by_label[choice]
    if not picked then
      self:end_operation(op_token)
      return
    end
    if not self:context_still_valid(ctx, true, true) then
      self:end_operation(op_token)
      return
    end
    on_item(picked)
  end)
end

function Controller:present_entries(op_token, entries, title, client, ctx)
  if not self:is_op_active(op_token) then
    return
  end
  local labels, by_label = {}, {}
  for _, entry in ipairs(entries) do
    labels[#labels + 1] = entry.label
    by_label[entry.label] = entry
  end

  ui.pick_one(labels, title, function(choice)
    if not self:is_op_active(op_token) then
      return
    end
    local picked = by_label[choice]
    if not picked then
      self:end_operation(op_token)
      return
    end
    if not self:context_still_valid(ctx, true, true) then
      self:end_operation(op_token)
      return
    end
    self:navigate_to(picked, client, ctx, op_token)
  end)
end

---Navigate safely to a `file://` or `jdt://` hierarchy location.
---@param entry table
---@param client table
---@param ctx table
---@param op_token number|nil
---@return boolean
function Controller:navigate_to(entry, client, ctx, op_token)
  if op_token ~= nil then
    if not self:is_op_active(op_token) then
      return false
    end
  else
    op_token = self:begin_operation()
  end

  if not self:context_still_valid(ctx, true, true) then
    self:end_operation(op_token)
    return false
  end

  local uri = entry and entry.uri
  local range = entry and entry.range
  local encoding = lsp.encoding(client)
  local win = (ctx and ctx.win and vim.api.nvim_win_is_valid(ctx.win)) and ctx.win or vim.api.nvim_get_current_win()

  if M.is_file_uri(uri) then
    local path = vim.uri_to_fname(uri)
    local existing = vim.fn.bufnr(path)
    local already_loaded = existing ~= -1 and vim.api.nvim_buf_is_loaded(existing)
    if not already_loaded and vim.fn.filereadable(path) ~= 1 then
      ui.notify("target file not found: " .. path, vim.log.levels.WARN)
      self:end_operation(op_token)
      return false
    end
    local target_buf = vim.uri_to_bufnr(uri)
    if not vim.api.nvim_buf_is_loaded(target_buf) then
      vim.fn.bufload(target_buf)
    end
    local jumped = M.jump_to_loaded_buffer(win, target_buf, range, encoding)
    self:end_operation(op_token)
    return jumped
  end

  if M.is_jdt_uri(uri) then
    local owned_buf = find_owned_jdt_buffer(client, uri)
    if owned_buf then
      attach_client_if_live(owned_buf, client)
      local jumped = M.jump_to_loaded_buffer(win, owned_buf, range, encoding)
      self:end_operation(op_token)
      return jumped
    end

    local _, pre_collision_reason = jdt_buffer_collision(uri, client)
    if pre_collision_reason then
      ui.notify(pre_collision_reason, vim.log.levels.WARN)
      self:end_operation(op_token)
      return false
    end

    if M.client_stopped(client) then
      ui.notify("jdtls client is not available to open " .. M.uri_label(uri), vim.log.levels.WARN)
      self:end_operation(op_token)
      return false
    end

    local req_token = self:begin_request(op_token, client, ctx.bufnr, "open " .. M.uri_label(uri))
    if not req_token then
      return false
    end
    local ok, req_id = client:request("java/classFileContents", { uri = uri }, function(err, content)
      vim.schedule(function()
        if not self:is_request_current(op_token, req_token) then
          return
        end
        self:clear_pending(req_token)

        if err then
          if err.code == M.REQUEST_CANCELLED_CODE then
            ui.notify(self.feature_label .. " request was cancelled", vim.log.levels.INFO)
          else
            ui.notify("could not open jdt:// source: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
          end
          self:end_operation(op_token)
          return
        end

        if type(content) ~= "string" or content == "" then
          ui.notify("jdtls returned empty source for " .. M.uri_label(uri), vim.log.levels.WARN)
          self:end_operation(op_token)
          return
        end

        if not self:context_still_valid(ctx, true, true) then
          self:end_operation(op_token)
          return
        end

        if M.client_stopped(client) then
          ui.notify("jdtls client is no longer available", vim.log.levels.WARN)
          self:end_operation(op_token)
          return
        end
        if ctx.navigation_guard and not ctx.navigation_guard() then
          self:end_operation(op_token)
          return
        end

        local ok_pop, target_buf, collision_reason = pcall(populate_jdt_buffer, uri, content, client)
        if not ok_pop then
          ui.notify("could not load jdt:// buffer: " .. tostring(target_buf), vim.log.levels.ERROR)
          self:end_operation(op_token)
          return
        end
        if not target_buf then
          ui.notify(collision_reason, vim.log.levels.WARN)
          self:end_operation(op_token)
          return
        end
        M.jump_to_loaded_buffer(win, target_buf, range, encoding)
        self:end_operation(op_token)
      end)
    end, ctx.bufnr)

    if not self:attach_request_id(op_token, req_token, ok, req_id) then
      ui.notify("failed to send java/classFileContents request to jdtls", vim.log.levels.ERROR)
      return false
    end
    return true
  end

  ui.notify("unsupported URI scheme for navigation: " .. tostring(uri), vim.log.levels.WARN)
  self:end_operation(op_token)
  return false
end

return M
