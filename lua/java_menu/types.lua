-- java_menu/types.lua
-- <leader>jh: JDTLS Type Hierarchy (Supertypes / Subtypes / Implementations).
--
-- Delegates shared operation/cancellation lifecycle, multi-client selection,
-- encoding-aware position handling, and safe `file://` / canonical `jdt://`
-- navigation to java_menu.hierarchy.

local ui = require("java_menu.ui")
local hierarchy = require("java_menu.hierarchy")

local M = {}

local METHODS = {
  prepare = "textDocument/prepareTypeHierarchy",
  supertypes = "typeHierarchy/supertypes",
  subtypes = "typeHierarchy/subtypes",
  implementation = "textDocument/implementation",
}

local MAX_SNIPPET_LEN = 60

local ctrl = hierarchy.new_controller({ feature_label = "type hierarchy" })

local function supports_type_hierarchy(client, bufnr, hierarchy_method)
  return hierarchy.supports_method(client, METHODS.prepare, bufnr, "typeHierarchyProvider")
    and hierarchy.supports_method(client, hierarchy_method or METHODS.supertypes, bufnr, "typeHierarchyProvider")
end

local function supports_implementations(client, bufnr)
  return hierarchy.supports_method(client, METHODS.implementation, bufnr, "implementationProvider")
end

local function normalize_list(result, is_single_fn)
  if type(result) ~= "table" then
    return {}
  end
  if is_single_fn(result) then
    return { result }
  end
  return result
end

local function is_single_type_item(tbl)
  return type(tbl.uri) == "string"
end

local function is_single_location(tbl)
  return type(tbl.uri) == "string" or type(tbl.targetUri) == "string"
end

local function read_line_snippet(uri, line0)
  if not hierarchy.is_file_uri(uri) or type(line0) ~= "number" or line0 < 0 then
    return ""
  end
  local path = vim.uri_to_fname(uri)
  local line
  local existing = vim.fn.bufnr(path)
  if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
    line = vim.api.nvim_buf_get_lines(existing, line0, line0 + 1, false)[1]
  elseif vim.fn.filereadable(path) == 1 then
    local ok, lines = pcall(vim.fn.readfile, path, "", line0 + 1)
    if ok and type(lines) == "table" then
      line = lines[line0 + 1]
    end
  end
  if type(line) ~= "string" then
    return ""
  end
  local trimmed = vim.trim(line):gsub("%s+", " ")
  if #trimmed > MAX_SNIPPET_LEN then
    trimmed = trimmed:sub(1, MAX_SNIPPET_LEN - 1) .. "…"
  end
  return trimmed
end

---Build navigable picker entries from `typeHierarchy/supertypes`,
---`typeHierarchy/subtypes`, or `textDocument/implementation` responses.
---@param mode "supertypes"|"subtypes"|"implementations"
---@param result table|nil
---@param project_root string|nil
---@return table[]
local function build_entries(mode, result, project_root)
  local entries = {}
  local seen_labels = {}

  if mode == "implementations" then
    for _, loc in ipairs(normalize_list(result, is_single_location)) do
      if type(loc) == "table" then
        local uri = loc.targetUri or loc.uri
        if type(uri) == "string" and uri ~= "" then
          local range = hierarchy.pick_range(loc.targetSelectionRange, loc.targetRange, loc.range)
          local loc_text = hierarchy.uri_label(uri, project_root)
          local pos_text = string.format("%d:%d", range.start.line + 1, range.start.character + 1)
          local snippet = read_line_snippet(uri, range.start.line)
          local base = snippet ~= "" and string.format("%s  %s:%s", snippet, loc_text, pos_text)
            or string.format("%s:%s", loc_text, pos_text)
          local label = hierarchy.unique_label(base, seen_labels)
          entries[#entries + 1] = {
            label = label,
            uri = uri,
            range = range,
            item = loc,
            direction = mode,
          }
        end
      end
    end
    return entries
  end

  for _, item in ipairs(normalize_list(result, is_single_type_item)) do
    if type(item) == "table" and type(item.uri) == "string" and item.uri ~= "" then
      local range = hierarchy.pick_range(item.selectionRange, item.range)
      local symbol_text = hierarchy.format_symbol(item)
      local loc_text = hierarchy.uri_label(item.uri, project_root)
      local pos_text = string.format("%d:%d", range.start.line + 1, range.start.character + 1)
      local label = hierarchy.unique_label(string.format("%s  %s:%s", symbol_text, loc_text, pos_text), seen_labels)
      entries[#entries + 1] = {
        label = label,
        uri = item.uri,
        range = range,
        item = item,
        direction = mode,
      }
    end
  end

  return entries
end

local function present_types(op_token, direction, origin_item, result, client, ctx)
  if not ctrl:is_op_active(op_token) then
    return
  end
  local items = normalize_list(result, is_single_type_item)
  if #items == 0 then
    ui.notify("no " .. direction .. " found for " .. (origin_item.name or "symbol"), vim.log.levels.INFO)
    ctrl:end_operation(op_token)
    return
  end

  local entries = build_entries(direction, items, ctx.project_root)
  if #entries == 0 then
    ui.notify("jdtls returned no navigable type locations", vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return
  end

  local title = (direction == "supertypes" and "Java: Supertypes — " or "Java: Subtypes — ")
    .. (origin_item.name or "symbol")
  ctrl:present_entries(op_token, entries, title, client, ctx)
end

local function present_implementations(op_token, result, client, ctx)
  if not ctrl:is_op_active(op_token) then
    return
  end
  local target_name = (type(ctx.cword) == "string" and ctx.cword ~= "") and ctx.cword or "symbol"
  local locations = normalize_list(result, is_single_location)
  if #locations == 0 then
    ui.notify("no implementations found for " .. target_name, vim.log.levels.INFO)
    ctrl:end_operation(op_token)
    return
  end

  local entries = build_entries("implementations", locations, ctx.project_root)
  if #entries == 0 then
    ui.notify("jdtls returned no navigable implementation locations", vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return
  end

  ctrl:present_entries(op_token, entries, "Java: Implementations — " .. target_name, client, ctx)
end

local function fetch_types(op_token, direction, item, client, ctx)
  local method = direction == "supertypes" and METHODS.supertypes or METHODS.subtypes
  local label = direction .. " for " .. (item.name or "symbol")
  ctrl:request(op_token, client, ctx.bufnr, method, { item = item }, label, ctx, function(result)
    present_types(op_token, direction, item, result, client, ctx)
  end)
end

local function run_direction(direction, ctx)
  local op_token = ctrl:begin_operation()
  local hierarchy_method = direction == "supertypes" and METHODS.supertypes or METHODS.subtypes
  ctrl:select_client(op_token, ctx, {
    prompt = "Java: Type Hierarchy — select JDTLS client",
    supports = function(client, bufnr)
      return supports_type_hierarchy(client, bufnr, hierarchy_method)
    end,
    unsupported_reason = "does not support type hierarchy",
    unsupported_tag = "[no typeHierarchy]",
  }, function(client)
    local params = hierarchy.build_position_params(ctx.bufnr, ctx.cursor, client)
    ctrl:request(op_token, client, ctx.bufnr, METHODS.prepare, params, "prepare " .. direction, ctx, function(items)
      ctrl:choose_prepared_item(op_token, items, ctx, {
        prompt = "Java: Type Hierarchy — select symbol",
        empty_reason = "no type hierarchy item found at the cursor",
      }, function(picked)
        fetch_types(op_token, direction, picked, client, ctx)
      end)
    end)
  end)
end

local function run_implementations(ctx)
  local op_token = ctrl:begin_operation()
  ctrl:select_client(op_token, ctx, {
    prompt = "Java: Type Hierarchy — select JDTLS client",
    supports = supports_implementations,
    unsupported_reason = "does not support implementations",
    unsupported_tag = "[no implementation]",
  }, function(client)
    local params = hierarchy.build_position_params(ctx.bufnr, ctx.cursor, client)
    ctrl:request(op_token, client, ctx.bufnr, METHODS.implementation, params, "implementations", ctx, function(result)
      present_implementations(op_token, result, client, ctx)
    end)
  end)
end

---Cancel the active type hierarchy request, if any.
---@return boolean cancelled
function M.cancel()
  return ctrl:cancel(true)
end

---Resolve supertypes for the type under the cursor.
function M.supertypes()
  local ctx = hierarchy.capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  run_direction("supertypes", ctx)
end

---Resolve subtypes (subclasses / direct implementations) for the type under the cursor.
function M.subtypes()
  local ctx = hierarchy.capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  run_direction("subtypes", ctx)
end

---Resolve implementations for the type or method under the cursor.
function M.implementations()
  local ctx = hierarchy.capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  run_implementations(ctx)
end

---Entry point of `<leader>jh`: lightweight Type Hierarchy menu.
function M.types()
  local ctx = hierarchy.capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end

  local super_ready, super_reason = ctrl:menu_availability(ctx.bufnr, function(client, b)
    return supports_type_hierarchy(client, b, METHODS.supertypes)
  end, "jdtls client does not support type hierarchy")
  local sub_ready, sub_reason = ctrl:menu_availability(ctx.bufnr, function(client, b)
    return supports_type_hierarchy(client, b, METHODS.subtypes)
  end, "jdtls client does not support type hierarchy")
  local impl_ready, impl_reason = ctrl:menu_availability(ctx.bufnr, function(client, b)
    return supports_implementations(client, b)
  end, "jdtls client does not support implementations")

  local entries = {}
  local opened_seq = ctrl:seq()
  local pending = ctrl:pending()
  local opened_pending_token = pending and pending.token or nil
  if pending then
    entries[#entries + 1] = {
      key = "cancel",
      label = "Cancel active request (" .. pending.label .. ")",
      enabled = true,
    }
  end
  entries[#entries + 1] = {
    key = "supertypes",
    label = "Supertypes…",
    enabled = super_ready,
    reason = super_reason,
  }
  entries[#entries + 1] = {
    key = "subtypes",
    label = "Subtypes…",
    enabled = sub_ready,
    reason = sub_reason,
  }
  entries[#entries + 1] = {
    key = "implementations",
    label = "Implementations…",
    enabled = impl_ready,
    reason = impl_reason,
  }

  ui.menu(entries, "Java: Type Hierarchy", function(entry)
    if ctrl:seq() ~= opened_seq then
      return
    end
    if entry.key == "cancel" then
      local cur = ctrl:pending()
      if cur and cur.token == opened_pending_token then
        M.cancel()
      end
    elseif entry.key == "supertypes" then
      run_direction("supertypes", ctx)
    elseif entry.key == "subtypes" then
      run_direction("subtypes", ctx)
    elseif entry.key == "implementations" then
      run_implementations(ctx)
    end
  end)
end

-- Exposed for deterministic tests
M._supports_type_hierarchy = supports_type_hierarchy
M._supports_implementations = supports_implementations
M._build_position_params = hierarchy.build_position_params
M._build_entries = build_entries
M._uri_label = hierarchy.uri_label
M._navigate_to = function(entry, client, ctx, op_token)
  return ctrl:navigate_to(entry, client, ctx, op_token)
end
M._pending = function()
  return ctrl:pending()
end
M._reset = function()
  ctrl:reset()
end

return M
