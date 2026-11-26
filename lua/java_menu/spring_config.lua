-- java_menu/spring_config.lua
-- Contextual Spring configuration file discovery and opening
-- (`src/main/resources/application*.{properties,yml,yaml}` and
-- `src/main/resources/config/`). Read-only discovery: never executes Spring,
-- never evaluates properties or active profiles, and enforces project/module
-- boundaries.

local project = require("java_menu.project")
local run_config = require("java_menu.run_config")
local ui = require("java_menu.ui")

local M = {}

local NO_PROJECT_REASON = "no Maven/Gradle project from this buffer"
local NO_CONFIG_REASON = "no Spring configuration files (application*.properties/yml/yaml) found"

---@param parent string
---@param path string
---@return boolean
local function is_subtree(parent, path)
  if type(parent) ~= "string" or parent == "" or type(path) ~= "string" or path == "" then
    return false
  end
  local sep = parent:sub(-1) == "/" and "" or "/"
  return parent == path or path:sub(1, #parent + #sep) == parent .. sep
end

---@param bufnr integer|nil
---@return table|nil ctx, string|nil reason
local function resolve_context(bufnr)
  local buf = (bufnr and bufnr > 0) and bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil, NO_PROJECT_REASON
  end
  local root = project.root(buf)
  if not root then
    return nil, NO_PROJECT_REASON
  end
  local real_root = vim.uv.fs_realpath(root)
  if not real_root or vim.fn.isdirectory(real_root) ~= 1 then
    return nil, NO_PROJECT_REASON
  end
  local canon_root = vim.fs.normalize(real_root)

  local modules, seen_mod = {}, {}
  for _, mod in ipairs(project.modules(canon_root)) do
    local rm = vim.uv.fs_realpath(mod)
    if rm then
      local cm = vim.fs.normalize(rm)
      if is_subtree(canon_root, cm) and not seen_mod[cm] then
        seen_mod[cm] = true
        modules[#modules + 1] = cm
      end
    end
  end
  if not seen_mod[canon_root] then
    table.insert(modules, 1, canon_root)
  end

  local start = project.start_path(buf)
  local real_start = vim.uv.fs_realpath(start)
  local canon_start = vim.fs.normalize(real_start or start)
  local current_module = canon_root
  local best_len = -1
  for _, mod in ipairs(modules) do
    if is_subtree(mod, canon_start) and #mod > best_len then
      best_len = #mod
      current_module = mod
    end
  end

  return {
    bufnr = buf,
    root = canon_root,
    modules = modules,
    current_module = current_module,
    multi_module = #modules > 1,
  },
    nil
end

---@param item table
---@return string
local function profile_label(item)
  if item.is_default then
    return "default"
  end
  if item.profile and item.profile ~= "" then
    return "profile: " .. item.profile
  end
  return "other"
end

---@param item table
---@param ctx table
---@return integer
local function module_rank(item, ctx)
  if item.module == ctx.current_module then
    return 0
  end
  if item.module == ctx.root then
    return 1
  end
  return 2
end

---@param item table
---@return integer
local function profile_rank(item)
  if item.is_default then
    return 0
  end
  if item.profile and item.profile ~= "" then
    return 1
  end
  return 2
end

---@param item table
---@return integer
local function location_rank(item)
  return item.location == "resources" and 0 or 1
end

---@param item table
---@param ctx table
---@return string
local function format_label(item, ctx)
  local p_label = profile_label(item)
  if ctx.multi_module then
    local mod_label = item.module_rel
    if item.module == ctx.current_module then
      mod_label = mod_label .. " (current)"
    end
    return ("%s  ·  %s  ·  %s"):format(mod_label, p_label, item.relpath)
  end
  return ("%s  ·  %s"):format(p_label, item.relpath)
end

---Discover Spring configuration files contextually for `bufnr`.
---Reuses `run_config.scan_profiles` without executing Spring or inferring active values.
---@param bufnr integer|nil
---@return table|nil result, string|nil reason
function M.discover(bufnr)
  local ctx, reason = resolve_context(bufnr)
  if not ctx then
    return nil, reason
  end

  local scan = run_config.scan_profiles(ctx.root)
  if type(scan.files) ~= "table" or #scan.files == 0 then
    return nil, NO_CONFIG_REASON
  end

  local ordered = {}
  for _, item in ipairs(scan.files) do
    local copy = vim.deepcopy(item)
    copy.label = format_label(copy, ctx)
    ordered[#ordered + 1] = copy
  end

  table.sort(ordered, function(a, b)
    local ma, mb = module_rank(a, ctx), module_rank(b, ctx)
    if ma ~= mb then
      return ma < mb
    end
    if a.module_rel ~= b.module_rel then
      return a.module_rel < b.module_rel
    end
    local pa, pb = profile_rank(a), profile_rank(b)
    if pa ~= pb then
      return pa < pb
    end
    local ap, bp = a.profile or "", b.profile or ""
    if ap ~= bp then
      return ap < bp
    end
    local la, lb = location_rank(a), location_rank(b)
    if la ~= lb then
      return la < lb
    end
    return a.relpath < b.relpath
  end)

  return {
    bufnr = ctx.bufnr,
    root = ctx.root,
    modules = ctx.modules,
    current_module = ctx.current_module,
    multi_module = ctx.multi_module,
    files = ordered,
  },
    nil
end

---Is Open Spring Configuration available for `bufnr`?
---@param bufnr integer|nil
---@return boolean available, string|nil reason
function M.available(bufnr)
  local res, reason = M.discover(bufnr)
  if not res then
    return false, reason
  end
  return true, nil
end

---@param item table
---@param root string
---@param context_buf integer
---@return boolean
local function open_file(item, root, context_buf)
  local real = vim.uv.fs_realpath(item.path)
  local st = real and vim.uv.fs_stat(real) or nil
  if not real or not st or st.type ~= "file" then
    ui.notify("Spring configuration file no longer exists: " .. item.relpath, vim.log.levels.WARN)
    return false
  end
  real = vim.fs.normalize(real)
  local found = false
  for _, current in ipairs(run_config.scan_profiles(root).files or {}) do
    if current.path == real and current.module == item.module and real == item.path then
      found = true
      break
    end
  end
  if not found or not is_subtree(root, real) or vim.fn.filereadable(real) ~= 1 then
    ui.notify("Spring configuration file is outside the project or unreadable: " .. item.relpath, vim.log.levels.WARN)
    return false
  end

  local cur = vim.api.nvim_get_current_buf()
  if cur ~= context_buf and vim.bo[cur].buftype ~= "" then
    local wins = vim.fn.win_findbuf(context_buf)
    if wins and wins[1] and vim.api.nvim_win_is_valid(wins[1]) then
      pcall(vim.api.nvim_set_current_win, wins[1])
    end
  end

  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(real))
  if not ok then
    ui.notify("could not open " .. vim.fs.basename(real) .. ": " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

---List and open Spring configuration files (`application*.properties/yml/yaml`)
---for the contextual project/module. Safe on empty results, cancellation, and
---buffers outside a project.
---@param bufnr integer|nil
function M.open(bufnr)
  local res, reason = M.discover(bufnr)
  if not res then
    ui.notify(reason or NO_CONFIG_REASON, vim.log.levels.WARN)
    return
  end
  local origin_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(origin_win) ~= res.bufnr then
    ui.notify("the project buffer is no longer active", vim.log.levels.WARN)
    return
  end

  local labels, by_label = {}, {}
  for _, item in ipairs(res.files) do
    if not by_label[item.label] then
      labels[#labels + 1] = item.label
      by_label[item.label] = item
    end
  end

  local prompt = ("Java: Spring Configuration — %s"):format(vim.fs.basename(res.root))
  ui.pick_one(labels, prompt, function(choice)
    local item = choice and by_label[choice]
    if not item then
      return
    end
    if
      not vim.api.nvim_win_is_valid(origin_win)
      or vim.api.nvim_get_current_win() ~= origin_win
      or vim.api.nvim_win_get_buf(origin_win) ~= res.bufnr
    then
      ui.notify("the project window or buffer changed", vim.log.levels.WARN)
      return
    end
    open_file(item, res.root, res.bufnr)
  end)
end

return M
