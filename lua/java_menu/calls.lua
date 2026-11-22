-- java_menu/calls.lua
-- <leader>jc: JDTLS Call Hierarchy (Incoming Calls / Outgoing Calls).
--
-- Delegates shared operation/cancellation lifecycle, multi-client selection,
-- encoding-aware position handling, and safe `file://` / canonical `jdt://`
-- navigation to java_menu.hierarchy.

local ui = require("java_menu.ui")
local hierarchy = require("java_menu.hierarchy")

local M = {}

local METHODS = {
  prepare = "textDocument/prepareCallHierarchy",
  incoming = "callHierarchy/incomingCalls",
  outgoing = "callHierarchy/outgoingCalls",
}

local ctrl = hierarchy.new_controller({ feature_label = "call hierarchy" })

local function supports_call_hierarchy(client, bufnr, hierarchy_method)
  return hierarchy.supports_method(client, METHODS.prepare, bufnr, "callHierarchyProvider")
    and hierarchy.supports_method(client, hierarchy_method or METHODS.incoming, bufnr, "callHierarchyProvider")
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
        local symbol_text = hierarchy.format_symbol(item)
        local loc_text = hierarchy.uri_label(item.uri, project_root)

        if direction == "incoming" then
          local emitted = 0
          if type(call.fromRanges) == "table" then
            for _, range in ipairs(call.fromRanges) do
              if hierarchy.is_valid_range(range) then
                emitted = emitted + 1
                local pos_text = string.format("%d:%d", range.start.line + 1, range.start.character + 1)
                local label =
                  hierarchy.unique_label(string.format("%s  %s:%s", symbol_text, loc_text, pos_text), seen_labels)
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
            local range = hierarchy.pick_range(item.selectionRange, item.range)
            local pos_text = string.format("%d:%d", range.start.line + 1, range.start.character + 1)
            local label =
              hierarchy.unique_label(string.format("%s  %s:%s", symbol_text, loc_text, pos_text), seen_labels)
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
          local range = hierarchy.pick_range(item.selectionRange, item.range)
          local pos_text = string.format("%d:%d", range.start.line + 1, range.start.character + 1)
          local callsite_lines = {}
          if type(call.fromRanges) == "table" then
            for _, r in ipairs(call.fromRanges) do
              if hierarchy.is_valid_range(r) then
                callsite_lines[#callsite_lines + 1] = "L" .. tostring(r.start.line + 1)
              end
            end
          end
          local suffix = #callsite_lines > 0 and ("  (from " .. table.concat(callsite_lines, ", ") .. ")") or ""
          local label =
            hierarchy.unique_label(string.format("%s  %s:%s%s", symbol_text, loc_text, pos_text, suffix), seen_labels)
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

local function present_calls(op_token, direction, origin_item, calls, client, ctx)
  if not ctrl:is_op_active(op_token) then
    return
  end
  if type(calls) ~= "table" or #calls == 0 then
    local empty_kind = direction == "incoming" and "incoming calls" or "outgoing calls"
    ui.notify("no " .. empty_kind .. " found for " .. (origin_item.name or "symbol"), vim.log.levels.INFO)
    ctrl:end_operation(op_token)
    return
  end

  local entries = build_entries(direction, calls, ctx.project_root)
  if #entries == 0 then
    ui.notify("jdtls returned no navigable call locations", vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return
  end

  local title = direction == "incoming" and ("Java: Incoming Calls — " .. (origin_item.name or "symbol"))
    or ("Java: Outgoing Calls — " .. (origin_item.name or "symbol"))
  ctrl:present_entries(op_token, entries, title, client, ctx)
end

local function fetch_calls(op_token, direction, item, client, ctx)
  local method = direction == "incoming" and METHODS.incoming or METHODS.outgoing
  local label = (direction == "incoming" and "incoming calls" or "outgoing calls") .. " for " .. (item.name or "symbol")
  ctrl:request(op_token, client, ctx.bufnr, method, { item = item }, label, ctx, function(result)
    present_calls(op_token, direction, item, result, client, ctx)
  end)
end

local function run_direction(direction, ctx)
  local op_token = ctrl:begin_operation()
  local hierarchy_method = direction == "incoming" and METHODS.incoming or METHODS.outgoing
  ctrl:select_client(op_token, ctx, {
    prompt = "Java: Call Hierarchy — select JDTLS client",
    supports = function(client, bufnr)
      return supports_call_hierarchy(client, bufnr, hierarchy_method)
    end,
    unsupported_reason = "does not support call hierarchy",
    unsupported_tag = "[no callHierarchy]",
  }, function(client)
    local params = hierarchy.build_position_params(ctx.bufnr, ctx.cursor, client)
    ctrl:request(
      op_token,
      client,
      ctx.bufnr,
      METHODS.prepare,
      params,
      "prepare " .. direction .. " calls",
      ctx,
      function(items)
        ctrl:choose_prepared_item(op_token, items, ctx, {
          prompt = "Java: Call Hierarchy — select symbol",
          empty_reason = "no call hierarchy item found at the cursor",
        }, function(picked)
          fetch_calls(op_token, direction, picked, client, ctx)
        end)
      end
    )
  end)
end

local function menu_availability(bufnr, hierarchy_method)
  return ctrl:menu_availability(bufnr, function(client, b)
    return supports_call_hierarchy(client, b, hierarchy_method)
  end, "jdtls client does not support call hierarchy")
end

---Cancel the active call hierarchy request, if any.
---@return boolean cancelled
function M.cancel()
  return ctrl:cancel(true)
end

---Resolve incoming calls (callers) for the symbol under the cursor.
function M.incoming()
  local ctx = hierarchy.capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  run_direction("incoming", ctx)
end

---Resolve outgoing calls (callees) for the symbol under the cursor.
function M.outgoing()
  local ctx = hierarchy.capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  run_direction("outgoing", ctx)
end

---Entry point of `<leader>jc`: lightweight Call Hierarchy menu.
function M.calls()
  local ctx = hierarchy.capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end

  local incoming_ready, incoming_reason = menu_availability(ctx.bufnr, METHODS.incoming)
  local outgoing_ready, outgoing_reason = menu_availability(ctx.bufnr, METHODS.outgoing)
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
    if ctrl:seq() ~= opened_seq then
      return
    end
    if entry.key == "cancel" then
      local cur = ctrl:pending()
      if cur and cur.token == opened_pending_token then
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
