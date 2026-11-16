-- java_menu/signature.lua
-- Change Method Signature over the jdtls API:
--   java/getChangeSignatureInfo  -> current signature
--   java/getRefactorEdit (command="changeSignature", 8 arguments)
-- The returned edit goes to java_menu.preview (nothing is applied here).

local ui = require("java_menu.ui")
local lsp = require("java_menu.lsp")

local M = {}

local INDEX_FOR_ADDED = -1

local function copy_params(list)
  local out = {}
  for _, p in ipairs(list or {}) do
    out[#out + 1] =
      { type = p.type, name = p.name, defaultValue = p.defaultValue or "", originalIndex = p.originalIndex }
  end
  return out
end

local function signature_text(state)
  local parts = {}
  for _, p in ipairs(state.params) do
    parts[#parts + 1] = p.type .. " " .. p.name
  end
  local mod = state.modifier ~= "" and (state.modifier .. " ") or ""
  return ("%s%s(%s) → %s"):format(mod, state.method_name, table.concat(parts, ", "), state.return_type)
end

local function params_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i].type ~= b[i].type or a[i].name ~= b[i].name or a[i].originalIndex ~= b[i].originalIndex then
      return false
    end
  end
  return true
end

local function changed(state)
  local info = state.info
  if
    state.method_name ~= info.methodName
    or state.return_type ~= info.returnType
    or state.modifier ~= info.modifier
  then
    return true
  end
  return not params_equal(state.params, copy_params(info.parameters))
end

---Suggested value for existing calls when a parameter is added.
local function suggested_default(typ)
  if typ == "boolean" then
    return "false"
  end
  if typ == "byte" or typ == "short" or typ == "int" or typ == "long" then
    return "0"
  end
  if typ == "double" or typ == "float" then
    return "0.0"
  end
  if typ == "char" then
    return "' '"
  end
  return "null"
end

local function valid_name(name)
  return name ~= "" and name:match("^[%a_$][%w_$]*$") ~= nil
end

---Send the new signature to jdtls and return the WorkspaceEdit (without applying).
local function request_edit(state, bufnr, on_edit)
  local client, client_reason = lsp.client_or_reason(bufnr)
  if not client then
    ui.notify(client_reason or "jdtls is not attached to this buffer", vim.log.levels.ERROR)
    return
  end
  if not ui.same_buffer(bufnr) then
    return
  end
  if state.tick and vim.b[bufnr].changedtick ~= state.tick then
    ui.notify("the buffer changed while editing the signature — run the operation again", vim.log.levels.WARN)
    return
  end

  local params = {}
  for _, p in ipairs(state.params) do
    params[#params + 1] = {
      type = p.type,
      name = p.name,
      defaultValue = p.defaultValue or "",
      originalIndex = p.originalIndex,
    }
  end

  local args = {
    state.info.methodIdentifier,
    state.delegate,
    state.method_name,
    state.modifier,
    state.return_type,
    params,
    state.info.exceptions or {},
    false, -- change annotations
  }

  client:request("java/getRefactorEdit", {
    command = "changeSignature",
    commandArguments = args,
    context = state.context,
    options = { tabSize = vim.lsp.util.get_effective_tabstop(), insertSpaces = vim.bo[bufnr].expandtab },
  }, function(err, result)
    vim.schedule(function()
      if err then
        ui.notify("change signature refused: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
        return
      end
      if not (result and result.edit) then
        ui.notify("jdtls returned no changes for this signature", vim.log.levels.WARN)
        return
      end
      on_edit(result.edit)
    end)
  end, bufnr)
end

local function ask_param(state, on_done)
  local entries = {}
  for i, p in ipairs(state.params) do
    entries[#entries + 1] = { label = ("%d. %s %s"):format(i, p.type, p.name), key = tostring(i) }
  end
  ui.menu(entries, "Java: Signature — parameter", on_done)
end

local function edit_param(state, index, reopen)
  local p = state.params[index]
  local entries = {
    { label = ("Rename (current: %s)"):format(p.name), key = "rename" },
    { label = ("Change type (current: %s)"):format(p.type), key = "type" },
    { label = "Move up", key = "up", enabled = index > 1, reason = "already first" },
    { label = "Move down", key = "down", enabled = index < #state.params, reason = "already last" },
    { label = "Remove", key = "remove" },
  }
  ui.menu(entries, ("Java: Signature — %s %s"):format(p.type, p.name), function(entry)
    if entry.key == "rename" then
      ui.ask("Java: Signature — new parameter name: ", p.name, function(name)
        if name == nil then
          return reopen()
        end
        name = vim.trim(name)
        if not valid_name(name) then
          ui.notify("invalid name: " .. name, vim.log.levels.WARN)
          return reopen()
        end
        for i, other in ipairs(state.params) do
          if i ~= index and other.name == name then
            ui.notify("a parameter named " .. name .. " already exists", vim.log.levels.WARN)
            return reopen()
          end
        end
        p.name = name
        reopen()
      end)
    elseif entry.key == "type" then
      ui.ask("Java: Signature — new type: ", p.type, function(typ)
        if typ == nil then
          return reopen()
        end
        typ = vim.trim(typ)
        if typ == "" then
          ui.notify("empty type", vim.log.levels.WARN)
          return reopen()
        end
        p.type = typ
        reopen()
      end)
    elseif entry.key == "up" then
      state.params[index], state.params[index - 1] = state.params[index - 1], state.params[index]
      reopen()
    elseif entry.key == "down" then
      state.params[index], state.params[index + 1] = state.params[index + 1], state.params[index]
      reopen()
    elseif entry.key == "remove" then
      table.remove(state.params, index)
      reopen()
    end
  end)
end

local function open_menu(state, bufnr, on_edit)
  local entries = {
    { label = "Edit parameter…", key = "param", enabled = #state.params > 0, reason = "method has no parameters" },
    { label = "Add parameter…", key = "add" },
    { label = "Rename method…", key = "method_name" },
    { label = "Change return type…", key = "return_type" },
    { label = "Change visibility…", key = "visibility" },
    {
      label = "Delegate old signature (@Deprecated): " .. (state.delegate and "yes" or "no"),
      key = "delegate",
    },
    {
      label = "✔ Apply signature change",
      key = "apply",
      enabled = changed(state),
      reason = "signature unchanged",
    },
    { label = "✖ Cancel", key = "cancel" },
  }

  ui.menu(entries, "Java: Signature — " .. signature_text(state), function(entry)
    local reopen = function()
      open_menu(state, bufnr, on_edit)
    end

    if entry.key == "param" then
      ask_param(state, function(picked)
        local index = tonumber(picked.key)
        if index then
          edit_param(state, index, reopen)
        end
      end)
    elseif entry.key == "add" then
      ui.ask("Java: Signature — new parameter (type name): ", "", function(value)
        if value == nil then
          return reopen()
        end
        local typ, name = vim.trim(value):match("^(.-)%s+([%w_$]+)$")
        if not typ or typ == "" or not valid_name(name) then
          ui.notify("use the format: type name", vim.log.levels.WARN)
          return reopen()
        end
        for _, other in ipairs(state.params) do
          if other.name == name then
            ui.notify("a parameter named " .. name .. " already exists", vim.log.levels.WARN)
            return reopen()
          end
        end
        ui.ask("Java: Signature — value in existing calls: ", suggested_default(typ), function(def)
          if def == nil then
            return reopen()
          end
          def = vim.trim(def)
          if def == "" then
            def = suggested_default(typ)
          end
          state.params[#state.params + 1] = {
            type = typ,
            name = name,
            defaultValue = def,
            originalIndex = INDEX_FOR_ADDED,
          }
          reopen()
        end)
      end)
    elseif entry.key == "method_name" then
      ui.ask("Java: Signature — new method name: ", state.method_name, function(name)
        if name == nil then
          return reopen()
        end
        name = vim.trim(name)
        if not valid_name(name) then
          ui.notify("invalid name: " .. name, vim.log.levels.WARN)
          return reopen()
        end
        state.method_name = name
        reopen()
      end)
    elseif entry.key == "return_type" then
      ui.ask("Java: Signature — new return type: ", state.return_type, function(typ)
        if typ == nil then
          return reopen()
        end
        typ = vim.trim(typ)
        if typ == "" then
          ui.notify("empty type", vim.log.levels.WARN)
          return reopen()
        end
        state.return_type = typ
        reopen()
      end)
    elseif entry.key == "visibility" then
      ui.pick_one({ "public", "protected", "private", "(default)" }, "Java: Signature — visibility", function(choice)
        state.modifier = choice == "(default)" and "" or choice
        reopen()
      end)
    elseif entry.key == "delegate" then
      state.delegate = not state.delegate
      reopen()
    elseif entry.key == "apply" then
      request_edit(state, bufnr, on_edit)
    end
  end)
end

---Full flow: info -> edit menu -> java/getRefactorEdit -> on_edit(edit).
---@param bufnr number
---@param on_edit fun(edit: table)
function M.change_signature(bufnr, on_edit)
  local client, client_reason = lsp.client_or_reason(bufnr)
  if not client then
    ui.notify(client_reason or "jdtls is not attached to this buffer", vim.log.levels.ERROR)
    return
  end
  if not ui.same_buffer(bufnr) then
    return
  end

  local tick = vim.b[bufnr].changedtick
  local context = vim.lsp.util.make_range_params(0, client.offset_encoding)
  context.context = { diagnostics = {} }

  client:request("java/getChangeSignatureInfo", context, function(err, info)
    vim.schedule(function()
      if err then
        ui.notify("could not read the signature: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
        return
      end
      if not info or info.errorMessage then
        ui.notify(
          "change signature unavailable: " .. tostring(info and info.errorMessage or "no method at the cursor"),
          vim.log.levels.WARN
        )
        return
      end
      if not ui.same_buffer(bufnr) then
        return
      end
      if vim.b[bufnr].changedtick ~= tick then
        ui.notify("the buffer changed since the menu was opened — run Change Signature again", vim.log.levels.WARN)
        return
      end

      local state = {
        info = info,
        context = context,
        tick = tick,
        params = copy_params(info.parameters),
        method_name = info.methodName,
        modifier = info.modifier,
        return_type = info.returnType,
        delegate = false,
      }

      open_menu(state, bufnr, on_edit)
    end)
  end, bufnr)
end

-- exposed for tests
M._changed = changed
M._signature_text = signature_text

return M
