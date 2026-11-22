-- java_menu/calls.lua
-- <leader>jc: JDTLS Call Hierarchy (Incoming Calls / Outgoing Calls).
--
-- Uses the attached JDTLS client directly via Neovim LSP APIs and reuses
-- java_menu.ui for menus/pickers/notifications. Supports explicit client
-- selection when multiple JDTLS clients are attached, client offset encoding,
-- request cancellation with stale-callback protection, and safe navigation to
-- both file:// and canonical virtual jdt:// URIs (refusing cross-client or
-- pre-existing jdt:// buffer collisions rather than inventing non-canonical
-- LSP URIs or reusing foreign contents).

local ui = require("java_menu.ui")
local lsp = require("java_menu.lsp")
local project = require("java_menu.project")

local M = {}

local METHODS = {
  prepare = "textDocument/prepareCallHierarchy",
  incoming = "callHierarchy/incomingCalls",
  outgoing = "callHierarchy/outgoingCalls",
}

local REQUEST_CANCELLED_CODE = -32800

local state = {
  seq = 0,
  active_op = nil,
  pending = nil, -- { op_token, token, client, request_id, bufnr, label }
  jdt_bufs = {}, -- [owner_key] = bufnr
}

local function client_stopped(client)
  return not client or (type(client.is_stopped) == "function" and client:is_stopped())
end

local function is_op_active(op_token)
  return op_token ~= nil and state.active_op == op_token
end

local function cancel_pending_request()
  local pending = state.pending
  if not pending then
    return nil
  end
  state.pending = nil
  if pending.request_id ~= nil and pending.client and type(pending.client.cancel_request) == "function" then
    pcall(pending.client.cancel_request, pending.client, pending.request_id)
  end
  return pending
end

local function end_operation(op_token)
  if is_op_active(op_token) then
    cancel_pending_request()
    state.active_op = nil
  end
end

local function is_request_current(op_token, req_token)
  return is_op_active(op_token)
    and state.pending ~= nil
    and state.pending.token == req_token
    and state.pending.op_token == op_token
end

local function clear_pending(req_token)
  if state.pending ~= nil and state.pending.token == req_token then
    state.pending = nil
  end
end

local function cancel_pending(notify_user)
  local pending = cancel_pending_request()
  state.active_op = nil
  state.seq = state.seq + 1
  if pending and notify_user then
    ui.notify("call hierarchy request cancelled", vim.log.levels.INFO)
  end
  return pending ~= nil
end

local function begin_operation()
  cancel_pending_request()
  state.seq = state.seq + 1
  local op_token = state.seq
  state.active_op = op_token
  return op_token
end

local function begin_request(op_token, client, bufnr, label)
  if not is_op_active(op_token) then
    return nil
  end
  cancel_pending_request()
  state.seq = state.seq + 1
  local req_token = state.seq
  state.pending = {
    op_token = op_token,
    token = req_token,
    client = client,
    request_id = nil,
    bufnr = bufnr,
    label = label,
  }
  return req_token
end

local function attach_request_id(op_token, req_token, ok, req_id)
  if not ok then
    clear_pending(req_token)
    end_operation(op_token)
    return false
  end
  if is_request_current(op_token, req_token) then
    state.pending.request_id = req_id
  end
  return true
end

local function supports_method(client, method, bufnr)
  if client_stopped(client) then
    return false
  end
  if type(client.supports_method) == "function" then
    return client:supports_method(method, bufnr) == true
  end
  return type(client.server_capabilities) == "table"
    and client.server_capabilities.callHierarchyProvider ~= nil
    and client.server_capabilities.callHierarchyProvider ~= false
end

local function supports_call_hierarchy(client, bufnr, hierarchy_method)
  return supports_method(client, METHODS.prepare, bufnr)
    and supports_method(client, hierarchy_method or METHODS.incoming, bufnr)
end

local function is_file_uri(uri)
  return type(uri) == "string" and vim.startswith(uri, "file://")
end

local function is_jdt_uri(uri)
  return type(uri) == "string" and vim.startswith(uri, "jdt://")
end

local function is_valid_range(range)
  return type(range) == "table"
    and type(range.start) == "table"
    and type(range.start.line) == "number"
    and type(range.start.character) == "number"
end

local function zero_range()
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 0 },
  }
end

local function pick_range(...)
  for i = 1, select("#", ...) do
    local candidate = select(i, ...)
    if is_valid_range(candidate) then
      return candidate
    end
  end
  return zero_range()
end

---Readable location label for a URI without assuming physical disk paths for
---virtual schemes such as `jdt://`.
---@param uri string
---@param project_root string|nil
---@return string
local function uri_label(uri, project_root)
  if is_file_uri(uri) then
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
  if is_jdt_uri(uri) then
    local inner = uri:match("^jdt://contents/([^?]+)")
    if inner and inner ~= "" then
      return "jdt://" .. inner
    end
    local base = uri:match("^([^?]+)")
    return (base and base ~= "" and base) or "jdt://class"
  end
  return tostring(uri)
end

local function format_symbol(item)
  local name = (type(item.name) == "string" and item.name ~= "") and item.name or "(symbol)"
  if type(item.detail) == "string" and item.detail ~= "" and item.detail ~= name then
    return string.format("%s  [%s]", name, item.detail)
  end
  return name
end

local function build_position_params(bufnr, cursor, client)
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

local function context_still_valid(ctx, check_tick, notify_on_mismatch)
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
        ui.notify("the window or buffer changed during call hierarchy — run the operation again", vim.log.levels.WARN)
      end
      return false
    end
  end
  if vim.api.nvim_get_current_buf() ~= ctx.bufnr then
    if notify_on_mismatch then
      ui.notify("the buffer changed during call hierarchy — run the operation again", vim.log.levels.WARN)
    end
    return false
  end
  if check_tick and ctx.tick ~= nil and vim.b[ctx.bufnr].changedtick ~= ctx.tick then
    if notify_on_mismatch then
      ui.notify("the buffer changed during call hierarchy — run the operation again", vim.log.levels.WARN)
    end
    return false
  end
  return true
end

local function capture_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return {
    bufnr = bufnr,
    win = win,
    cursor = vim.api.nvim_win_get_cursor(win),
    tick = vim.b[bufnr].changedtick,
    project_root = project.root(bufnr),
  }
end

local function unique_label(text, seen)
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

local function client_label(client, bufnr, hierarchy_method)
  local root_desc = (type(client.root_dir) == "string" and client.root_dir ~= "")
      and (vim.fs.basename(client.root_dir) .. " — " .. client.root_dir)
    or "no root_dir"
  local cap = supports_call_hierarchy(client, bufnr, hierarchy_method) and "" or " [no callHierarchy]"
  return string.format("#%s %s (%s)%s", tostring(client.id or "?"), client.name or "jdtls", root_desc, cap)
end

---Select the JDTLS client for the buffer, prompting explicitly when multiple
---JDTLS clients are attached.
local function select_client(op_token, ctx, hierarchy_method, on_client)
  if not is_op_active(op_token) then
    return
  end
  if not context_still_valid(ctx, true, true) then
    end_operation(op_token)
    return
  end

  local clients = lsp.clients(ctx.bufnr)
  if #clients == 0 then
    ui.notify("jdtls is not attached to this buffer", vim.log.levels.WARN)
    end_operation(op_token)
    return
  end

  if #clients == 1 then
    local client = clients[1]
    if not supports_call_hierarchy(client, ctx.bufnr, hierarchy_method) then
      ui.notify("jdtls client does not support call hierarchy", vim.log.levels.WARN)
      end_operation(op_token)
      return
    end
    on_client(client)
    return
  end

  local labels, by_label, seen = {}, {}, {}
  for _, client in ipairs(clients) do
    local label = unique_label(client_label(client, ctx.bufnr, hierarchy_method), seen)
    labels[#labels + 1] = label
    by_label[label] = client
  end

  ui.pick_one(labels, "Java: Call Hierarchy — select JDTLS client", function(choice)
    if not is_op_active(op_token) then
      return
    end
    local picked = by_label[choice]
    if not picked then
      end_operation(op_token)
      return
    end
    if not context_still_valid(ctx, true, true) then
      end_operation(op_token)
      return
    end
    if client_stopped(picked) then
      ui.notify("selected jdtls client is no longer running", vim.log.levels.WARN)
      end_operation(op_token)
      return
    end
    if not supports_call_hierarchy(picked, ctx.bufnr, hierarchy_method) then
      ui.notify("selected jdtls client does not support call hierarchy", vim.log.levels.WARN)
      end_operation(op_token)
      return
    end
    on_client(picked)
  end)
end

---Build navigable picker entries from `callHierarchy/incomingCalls` or
---`callHierarchy/outgoingCalls` responses.
---@param direction "incoming"|"outgoing"
---@param calls table[]
---@param project_root string|nil
---@return table[]
local function build_entries(direction, calls, project_root)
  local entries = {}
  local seen_labels = {}

  for _, call in ipairs(calls or {}) do
    if type(call) == "table" then
      local item = direction == "incoming" and call.from or call.to
      if type(item) == "table" and type(item.uri) == "string" and item.uri ~= "" then
        local symbol_text = format_symbol(item)
        local loc_text = uri_label(item.uri, project_root)

        if direction == "incoming" then
          local emitted = 0
          if type(call.fromRanges) == "table" then
            for _, range in ipairs(call.fromRanges) do
              if is_valid_range(range) then
                emitted = emitted + 1
                local pos_text = string.format("%d:%d", range.start.line + 1, range.start.character + 1)
                local label = unique_label(string.format("%s  %s:%s", symbol_text, loc_text, pos_text), seen_labels)
                entries[#entries + 1] = {
                  label = label,
                  uri = item.uri,
                  range = range,
                  item = item,
                  direction = direction,
                }
              end
            end
          end
          if emitted == 0 then
            local range = pick_range(item.selectionRange, item.range)
            local pos_text = string.format("%d:%d", range.start.line + 1, range.start.character + 1)
            local label = unique_label(string.format("%s  %s:%s", symbol_text, loc_text, pos_text), seen_labels)
            entries[#entries + 1] = {
              label = label,
              uri = item.uri,
              range = range,
              item = item,
              direction = direction,
            }
          end
        else
          -- Outgoing calls: navigate to the callee (`to.uri` + `to.selectionRange`/`to.range`),
          -- never confusing `fromRanges` (caller call sites) with locations inside `to.uri`.
          local range = pick_range(item.selectionRange, item.range)
          local pos_text = string.format("%d:%d", range.start.line + 1, range.start.character + 1)
          local callsite_lines = {}
          if type(call.fromRanges) == "table" then
            for _, r in ipairs(call.fromRanges) do
              if is_valid_range(r) then
                callsite_lines[#callsite_lines + 1] = "L" .. tostring(r.start.line + 1)
              end
            end
          end
          local suffix = #callsite_lines > 0 and ("  (from " .. table.concat(callsite_lines, ", ") .. ")") or ""
          local label = unique_label(string.format("%s  %s:%s%s", symbol_text, loc_text, pos_text, suffix), seen_labels)
          entries[#entries + 1] = {
            label = label,
            uri = item.uri,
            range = range,
            item = item,
            direction = direction,
          }
        end
      end
    end
  end

  return entries
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
  local tracked = state.jdt_bufs[key]
  if tracked then
    if owner_matches(tracked, client, uri) and buffer_has_content(tracked) then
      return tracked
    end
    state.jdt_bufs[key] = nil
  end
  local exact = find_buf_by_exact_name(uri)
  if exact ~= -1 and owner_matches(exact, client, uri) and buffer_has_content(exact) then
    state.jdt_bufs[key] = exact
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
  local label = uri_label(uri)
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

local function populate_jdt_buffer(uri, content, client)
  local jdt_buf, created_new, collision_reason = allocate_jdt_buffer(uri, client)
  if not jdt_buf then
    return nil, collision_reason
  end
  local saved_ei = vim.o.eventignore
  -- FileType hooks can attach a different client before ownership is recorded.
  -- Attach the selected client explicitly after the buffer is populated.
  vim.o.eventignore = (saved_ei ~= "" and (saved_ei .. ",") or "") .. "BufReadCmd,FileType"
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
    vim.bo[jdt_buf].filetype = filetype_for_jdt_uri(uri)
    vim.b[jdt_buf].java_menu_jdt_uri = uri
    vim.b[jdt_buf].java_menu_jdt_owner = make_owner(client, uri)
  end)
  vim.o.eventignore = saved_ei
  if not ok then
    if created_new and vim.api.nvim_buf_is_valid(jdt_buf) then
      pcall(vim.api.nvim_buf_delete, jdt_buf, { force = true })
    end
    error(err)
  end
  state.jdt_bufs[owner_key(client, uri)] = jdt_buf
  attach_client_if_live(jdt_buf, client)
  return jdt_buf, nil
end

local function jump_to_loaded_buffer(win, target_buf, range, encoding)
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
  local raw_line = (is_valid_range(range) and range.start.line) or 0
  local row0 = math.max(0, math.min(raw_line, line_count - 1))
  local raw_char = (is_valid_range(range) and range.start.character) or 0
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

---Navigate safely to a `file://` or `jdt://` CallHierarchy location.
---@param entry table
---@param client table
---@param ctx table
---@param op_token number|nil
---@return boolean
local function navigate_to(entry, client, ctx, op_token)
  if op_token ~= nil then
    if not is_op_active(op_token) then
      return false
    end
  else
    op_token = begin_operation()
  end

  if not context_still_valid(ctx, true, true) then
    end_operation(op_token)
    return false
  end

  local uri = entry and entry.uri
  local range = entry and entry.range
  local encoding = lsp.encoding(client)
  local win = (ctx and ctx.win and vim.api.nvim_win_is_valid(ctx.win)) and ctx.win or vim.api.nvim_get_current_win()

  if is_file_uri(uri) then
    local path = vim.uri_to_fname(uri)
    local existing = vim.fn.bufnr(path)
    local already_loaded = existing ~= -1 and vim.api.nvim_buf_is_loaded(existing)
    if not already_loaded and vim.fn.filereadable(path) ~= 1 then
      ui.notify("target file not found: " .. path, vim.log.levels.WARN)
      end_operation(op_token)
      return false
    end
    local target_buf = vim.uri_to_bufnr(uri)
    if not vim.api.nvim_buf_is_loaded(target_buf) then
      vim.fn.bufload(target_buf)
    end
    local jumped = jump_to_loaded_buffer(win, target_buf, range, encoding)
    end_operation(op_token)
    return jumped
  end

  if is_jdt_uri(uri) then
    local owned_buf = find_owned_jdt_buffer(client, uri)
    if owned_buf then
      attach_client_if_live(owned_buf, client)
      local jumped = jump_to_loaded_buffer(win, owned_buf, range, encoding)
      end_operation(op_token)
      return jumped
    end

    local _, pre_collision_reason = jdt_buffer_collision(uri, client)
    if pre_collision_reason then
      ui.notify(pre_collision_reason, vim.log.levels.WARN)
      end_operation(op_token)
      return false
    end

    if client_stopped(client) then
      ui.notify("jdtls client is not available to open " .. uri_label(uri), vim.log.levels.WARN)
      end_operation(op_token)
      return false
    end

    local req_token = begin_request(op_token, client, ctx.bufnr, "open " .. uri_label(uri))
    if not req_token then
      return false
    end
    local ok, req_id = client:request("java/classFileContents", { uri = uri }, function(err, content)
      vim.schedule(function()
        if not is_request_current(op_token, req_token) then
          return
        end
        clear_pending(req_token)

        if err then
          if err.code == REQUEST_CANCELLED_CODE then
            ui.notify("call hierarchy request was cancelled", vim.log.levels.INFO)
          else
            ui.notify("could not open jdt:// source: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
          end
          end_operation(op_token)
          return
        end

        if type(content) ~= "string" or content == "" then
          ui.notify("jdtls returned empty source for " .. uri_label(uri), vim.log.levels.WARN)
          end_operation(op_token)
          return
        end

        if not context_still_valid(ctx, true, true) then
          end_operation(op_token)
          return
        end

        local ok_pop, target_buf, collision_reason = pcall(populate_jdt_buffer, uri, content, client)
        if not ok_pop then
          ui.notify("could not load jdt:// buffer: " .. tostring(target_buf), vim.log.levels.ERROR)
          end_operation(op_token)
          return
        end
        if not target_buf then
          ui.notify(collision_reason, vim.log.levels.WARN)
          end_operation(op_token)
          return
        end
        jump_to_loaded_buffer(win, target_buf, range, encoding)
        end_operation(op_token)
      end)
    end, ctx.bufnr)

    if not attach_request_id(op_token, req_token, ok, req_id) then
      ui.notify("failed to request jdt:// class file contents", vim.log.levels.ERROR)
      return false
    end
    return true
  end

  ui.notify("unsupported URI scheme for navigation: " .. tostring(uri), vim.log.levels.WARN)
  end_operation(op_token)
  return false
end

local function handle_request_error(err, action_label)
  if type(err) == "table" and err.code == REQUEST_CANCELLED_CODE then
    ui.notify("call hierarchy request was cancelled", vim.log.levels.INFO)
    return
  end
  local msg = (type(err) == "table" and err.message) or vim.inspect(err)
  ui.notify(action_label .. " failed: " .. tostring(msg), vim.log.levels.ERROR)
end

local function present_calls(op_token, direction, origin_item, calls, client, ctx)
  if not is_op_active(op_token) then
    return
  end
  if type(calls) ~= "table" or #calls == 0 then
    local empty_kind = direction == "incoming" and "incoming calls" or "outgoing calls"
    ui.notify("no " .. empty_kind .. " found for " .. (origin_item.name or "symbol"), vim.log.levels.INFO)
    end_operation(op_token)
    return
  end

  local entries = build_entries(direction, calls, ctx.project_root)
  if #entries == 0 then
    ui.notify("jdtls returned no navigable call locations", vim.log.levels.WARN)
    end_operation(op_token)
    return
  end

  local labels, by_label = {}, {}
  for _, entry in ipairs(entries) do
    labels[#labels + 1] = entry.label
    by_label[entry.label] = entry
  end

  local title = direction == "incoming" and ("Java: Incoming Calls — " .. (origin_item.name or "symbol"))
    or ("Java: Outgoing Calls — " .. (origin_item.name or "symbol"))

  ui.pick_one(labels, title, function(choice)
    if not is_op_active(op_token) then
      return
    end
    local picked = by_label[choice]
    if not picked then
      end_operation(op_token)
      return
    end
    if not context_still_valid(ctx, true, true) then
      end_operation(op_token)
      return
    end
    navigate_to(picked, client, ctx, op_token)
  end)
end

local function fetch_calls(op_token, direction, item, client, ctx)
  if not is_op_active(op_token) then
    return
  end
  if not context_still_valid(ctx, true, true) then
    end_operation(op_token)
    return
  end
  if client_stopped(client) then
    ui.notify("jdtls client stopped during call hierarchy", vim.log.levels.WARN)
    end_operation(op_token)
    return
  end

  local method = direction == "incoming" and METHODS.incoming or METHODS.outgoing
  local label = (direction == "incoming" and "incoming calls" or "outgoing calls") .. " for " .. (item.name or "symbol")
  local req_token = begin_request(op_token, client, ctx.bufnr, label)
  if not req_token then
    return
  end

  local ok, req_id = client:request(method, { item = item }, function(err, result)
    vim.schedule(function()
      if not is_request_current(op_token, req_token) then
        return
      end
      clear_pending(req_token)

      if err then
        handle_request_error(err, method)
        end_operation(op_token)
        return
      end
      if client_stopped(client) then
        ui.notify("jdtls client stopped during call hierarchy", vim.log.levels.WARN)
        end_operation(op_token)
        return
      end
      if not context_still_valid(ctx, true, true) then
        end_operation(op_token)
        return
      end

      present_calls(op_token, direction, item, result, client, ctx)
    end)
  end, ctx.bufnr)

  if not attach_request_id(op_token, req_token, ok, req_id) then
    ui.notify("failed to send " .. method .. " request to jdtls", vim.log.levels.ERROR)
  end
end

local function choose_prepared_item(op_token, direction, items, client, ctx)
  if not is_op_active(op_token) then
    return
  end
  if type(items) ~= "table" or #items == 0 then
    ui.notify("no call hierarchy item found at the cursor", vim.log.levels.WARN)
    end_operation(op_token)
    return
  end

  if #items == 1 then
    fetch_calls(op_token, direction, items[1], client, ctx)
    return
  end

  local labels, by_label, seen = {}, {}, {}
  for _, item in ipairs(items) do
    local loc = type(item.uri) == "string" and uri_label(item.uri, ctx.project_root) or ""
    local r = pick_range(item.selectionRange, item.range)
    local text = loc ~= "" and string.format("%s  %s:%d", format_symbol(item), loc, r.start.line + 1)
      or format_symbol(item)
    local label = unique_label(text, seen)
    labels[#labels + 1] = label
    by_label[label] = item
  end

  ui.pick_one(labels, "Java: Call Hierarchy — select symbol", function(choice)
    if not is_op_active(op_token) then
      return
    end
    local picked = by_label[choice]
    if not picked then
      end_operation(op_token)
      return
    end
    fetch_calls(op_token, direction, picked, client, ctx)
  end)
end

local function run_direction(direction, ctx)
  local op_token = begin_operation()
  local hierarchy_method = direction == "incoming" and METHODS.incoming or METHODS.outgoing
  select_client(op_token, ctx, hierarchy_method, function(client)
    if not is_op_active(op_token) then
      return
    end
    if not context_still_valid(ctx, true, true) then
      end_operation(op_token)
      return
    end

    local params = build_position_params(ctx.bufnr, ctx.cursor, client)
    local req_token = begin_request(op_token, client, ctx.bufnr, "prepare " .. direction .. " calls")
    if not req_token then
      return
    end

    local ok, req_id = client:request(METHODS.prepare, params, function(err, items)
      vim.schedule(function()
        if not is_request_current(op_token, req_token) then
          return
        end
        clear_pending(req_token)

        if err then
          handle_request_error(err, METHODS.prepare)
          end_operation(op_token)
          return
        end
        if client_stopped(client) then
          ui.notify("jdtls client stopped during call hierarchy", vim.log.levels.WARN)
          end_operation(op_token)
          return
        end
        if not context_still_valid(ctx, true, true) then
          end_operation(op_token)
          return
        end

        choose_prepared_item(op_token, direction, items, client, ctx)
      end)
    end, ctx.bufnr)

    if not attach_request_id(op_token, req_token, ok, req_id) then
      ui.notify("failed to send " .. METHODS.prepare .. " request to jdtls", vim.log.levels.ERROR)
    end
  end)
end

local function menu_availability(bufnr, hierarchy_method)
  local clients = lsp.clients(bufnr)
  if #clients == 0 then
    return false, "jdtls is not attached to this buffer"
  end
  for _, client in ipairs(clients) do
    if supports_call_hierarchy(client, bufnr, hierarchy_method) then
      return true, nil
    end
  end
  return false, "jdtls client does not support call hierarchy"
end

---Cancel the active call hierarchy request, if any.
---@return boolean cancelled
function M.cancel()
  return cancel_pending(true)
end

---Resolve incoming calls (callers) for the symbol under the cursor.
function M.incoming()
  local ctx = capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  run_direction("incoming", ctx)
end

---Resolve outgoing calls (callees) for the symbol under the cursor.
function M.outgoing()
  local ctx = capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  run_direction("outgoing", ctx)
end

---Entry point of `<leader>jc`: lightweight Call Hierarchy menu.
function M.calls()
  local ctx = capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end

  local incoming_ready, incoming_reason = menu_availability(ctx.bufnr, METHODS.incoming)
  local outgoing_ready, outgoing_reason = menu_availability(ctx.bufnr, METHODS.outgoing)
  local entries = {}
  local opened_seq = state.seq
  local opened_pending_token = state.pending and state.pending.token or nil
  if state.pending then
    entries[#entries + 1] = {
      key = "cancel",
      label = "Cancel active request (" .. state.pending.label .. ")",
      enabled = true,
    }
  end
  entries[#entries + 1] = {
    key = "incoming",
    label = "Incoming Calls (callers)…",
    enabled = incoming_ready,
    reason = incoming_reason,
  }
  entries[#entries + 1] = {
    key = "outgoing",
    label = "Outgoing Calls (callees)…",
    enabled = outgoing_ready,
    reason = outgoing_reason,
  }

  ui.menu(entries, "Java: Call Hierarchy", function(entry)
    if state.seq ~= opened_seq then
      return
    end
    if entry.key == "cancel" then
      if state.pending and state.pending.token == opened_pending_token then
        M.cancel()
      end
    elseif entry.key == "incoming" then
      run_direction("incoming", ctx)
    elseif entry.key == "outgoing" then
      run_direction("outgoing", ctx)
    end
  end)
end

-- Exposed for deterministic tests
M._supports_call_hierarchy = supports_call_hierarchy
M._build_position_params = build_position_params
M._build_entries = build_entries
M._uri_label = uri_label
M._navigate_to = navigate_to
M._pending = function()
  return state.pending
end
M._reset = function()
  cancel_pending(false)
  state.jdt_bufs = {}
end

return M
