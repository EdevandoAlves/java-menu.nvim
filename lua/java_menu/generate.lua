-- java_menu/generate.lua
-- <leader>jg: Generate menu with central multi-selection (Snacks).
-- Java code generation stays with jc.nvim/jdtls
-- (require("jc.jdtls").generate_*); this module only collects candidates,
-- presents the selection and checks duplicates.
--
-- Note: jc.nvim's field picker is a scratch-buffer split where lines are
-- deleted. Only that UI is replaced by Snacks; the public jc functions, which
-- accept an already-selected field list, are reused.

local ui = require("java_menu.ui")
local lsp = require("java_menu.lsp")
local jca = require("java_menu.jc")

local M = {}

local notify = ui.notify

-- ---------- infrastructure ----------

local function jdtls_attached(bufnr)
  return ui.jdtls_attached(bufnr)
end

---Run `fn` with the target buffer as current (jc functions use buffer 0) and
---restore focus afterwards. When `tick` is given, refuse the operation if the
---buffer changed since the menu was opened.
local function in_buffer(bufnr, fn, tick)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  if tick and vim.b[bufnr].changedtick ~= tick then
    notify("the buffer changed during the operation — run Generate again", vim.log.levels.WARN)
    return
  end

  local prev_win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_get_current_buf()
  local switched = prev_buf ~= bufnr

  if switched then
    local win = vim.fn.bufwinid(bufnr)
    if win ~= -1 then
      pcall(vim.api.nvim_set_current_win, win)
    else
      pcall(vim.api.nvim_set_current_buf, bufnr)
    end
  end

  local ok, err = pcall(fn)

  if switched and vim.api.nvim_buf_is_valid(prev_buf) then
    if vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
    if vim.api.nvim_get_current_buf() ~= prev_buf then
      pcall(vim.api.nvim_set_current_buf, prev_buf)
    end
  end

  if not ok then
    notify(tostring(err), vim.log.levels.ERROR)
  end
end

local with_indent = ui.with_indent

local function range_params(bufnr, client)
  client = client or lsp.client(bufnr)
  local encoding = lsp.encoding(client)
  return vim.lsp.util.make_range_params(0, encoding)
end

-- ---------- class data (jdtls) ----------

local CLASS_KINDS = { [5] = true, [10] = true, [11] = true, [23] = true } -- Class, Enum, Interface, Struct
local FIELD, METHOD, CONSTRUCTOR = 8, 6, 9

local function class_node(symbols)
  for _, node in ipairs(symbols or {}) do
    if CLASS_KINDS[node.kind] then
      return node
    end
  end
end

---`getNome()` -> `getNome`
local function base_name(name)
  return (name:gsub("%s*%b()$", ""))
end

local function has_method(methods, name)
  for _, method in ipairs(methods or {}) do
    if base_name(method.name) == name then
      return true
    end
  end
  return false
end

---Does the class declare a no-args constructor?
local function has_default_constructor(node, ctors)
  local class = node and node.name or ""
  for _, ctor in ipairs(ctors or {}) do
    if (ctor.name or "") == class .. "()" then
      return true
    end
  end
  return false
end

---Erase generics: Map<String, List<Long>> -> Map
local function erase_generics(t)
  local prev
  repeat
    prev = t
    t = t:gsub("<[^<>]*>", "")
  until t == prev
  return (t:gsub("%s+", ""))
end

---Does a constructor with the same types (in order) already exist?
local function constructor_exists(node, ctors, fields)
  local types = {}
  for _, field in ipairs(fields) do
    types[#types + 1] = erase_generics(field.type or "?")
  end
  local want = erase_generics((node and node.name or "") .. "(" .. table.concat(types, ", ") .. ")")
  for _, ctor in ipairs(ctors or {}) do
    if erase_generics(ctor.name or "") == want then
      return true
    end
  end
  return false
end

---"pending" (an abstract method must be implemented), "none" (diagnostics
---published and nothing pending) or "unknown" (jdtls has not published yet).
local function abstract_state(bufnr)
  local diagnostics = vim.diagnostic.get(bufnr)
  if #diagnostics == 0 then
    return "unknown"
  end
  for _, diag in ipairs(diagnostics) do
    if
      tostring(diag.code) == "67109264"
      or (
        diag.message and (diag.message:find("must implement", 1, true) or diag.message:find("must override", 1, true))
      )
    then
      return "pending"
    end
  end
  return "none"
end

---Collect symbols, pending accessors and constructor status.
---@param bufnr number
---@param cb fun(state: table)
local function load_state(bufnr, cb)
  local state = {
    bufnr = bufnr,
    tick = vim.b[bufnr].changedtick,
    fields = {},
    field_nodes = {},
    methods = {},
    ctors = {},
    accessors = {},
    ctor_fields = {},
    constructors = {},
  }
  local client, reason = lsp.client_or_reason(bufnr)
  if not client then
    notify(reason or "jdtls is not attached to this buffer", vim.log.levels.WARN)
    cb(state)
    return
  end
  state.client = client

  local pending = 3
  local function done()
    pending = pending - 1
    if pending == 0 then
      cb(state)
    end
  end

  client:request(
    "textDocument/documentSymbol",
    { textDocument = vim.lsp.util.make_text_document_params(bufnr) },
    function(err, resp)
      if resp then
        state.node = class_node(resp)
        for _, child in ipairs(state.node and state.node.children or {}) do
          if child.kind == METHOD then
            state.methods[#state.methods + 1] = child
          elseif child.kind == CONSTRUCTOR then
            state.ctors[#state.ctors + 1] = child
          elseif child.kind == FIELD then
            state.fields[#state.fields + 1] = { name = child.name }
            state.field_nodes[child.name] = child
          end
        end
      else
        state.error = err
      end
      done()
    end,
    bufnr
  )

  in_buffer(bufnr, function()
    local params = range_params(bufnr, client)
    params.kind = 2
    client:request("java/resolveUnimplementedAccessors", params, function(err, resp)
      if resp then
        vim.list_extend(state.accessors, resp)
      else
        state.error = state.error or err
      end
      done()
    end, bufnr)

    client:request("java/checkConstructorsStatus", range_params(bufnr, client), function(err, resp)
      if resp then
        state.ctor_fields = resp.fields or {}
        state.constructors = resp.constructors or {}
      else
        state.error = state.error or err
      end
      done()
    end, bufnr)
  end)
end

-- ---------- selection (Snacks) ----------

---Central multi-choice selection (Space/Tab toggle; Enter without a
---selection uses the item under the cursor). Delegates to the shared component.
---@param items table[] { text, data, idx }
---@param opts { title: string, allow_empty: boolean|nil }
---@param on_confirm fun(selected: table[])
local function pick_multi(items, opts, on_confirm)
  local entries = {}
  for _, item in ipairs(items) do
    entries[#entries + 1] = { text = item.text, value = item }
  end
  ui.pick_many(entries, opts.title, on_confirm, { fallback = true })
end

local pick_one = ui.pick_one

local function confirm_replace(what, on_yes)
  pick_one({ "Replace " .. what, "Cancel" }, "Java: Generate — " .. what .. " already exists", function(choice)
    if choice == "Replace " .. what then
      on_yes()
    end
  end)
end

-- ---------- operations ----------

local function field_items(fields, suffix)
  local items = {}
  for i, field in ipairs(fields) do
    local text = (field.type or "?") .. " " .. field.name
    if suffix then
      text = text .. suffix(field)
    end
    items[#items + 1] = { text = text, data = field, idx = i }
  end
  return items
end

---Constructor-eligible fields, in the order returned by jdtls.
---@param state table
---@return table[]
local function constructor_fields(state)
  return vim.tbl_filter(function(field)
    return field.isStatic ~= true
  end, state.ctor_fields or {})
end

---Final fields without an initializer must be assigned by every constructor;
---an empty No-Args constructor would break compilation. The jdtls status lists
---only those fields (initialized ones are left out), so we recognize `final`
---in the field declaration.
---@param state table
---@return boolean
local function has_pending_final_field(state)
  local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
  for _, field in ipairs(constructor_fields(state)) do
    local node = state.field_nodes and state.field_nodes[field.name]
    local range = node and (node.selectionRange or node.range)
    if range then
      local line = lines[range.start.line + 1] or ""
      local prefix = line:sub(1, range.start.character)
      if prefix:match("%f[%w]final%f[%W]") then
        return true
      end
    end
  end
  return false
end

local function generate_constructor(state, fields)
  in_buffer(state.bufnr, function()
    with_indent(state.bufnr, function()
      require("jc.jdtls").generate_constructor(fields, {
        default_constructor = false,
        constructors = state.constructors,
      })
    end)
  end, state.tick)
end

---@param mode string "select"|"all"|"none"
local function constructor(state, mode)
  local bufnr = state.bufnr
  if mode == "none" then
    if has_pending_final_field(state) then
      notify("there is a final field without an initializer; use a constructor with parameters", vim.log.levels.WARN)
      return
    end
    in_buffer(bufnr, function()
      with_indent(bufnr, function()
        require("jc.jdtls").generate_constructor({}, { default_constructor = true, constructors = state.constructors })
      end)
    end, state.tick)
    return
  end

  local fields = constructor_fields(state)
  if #fields == 0 then
    notify("the class has no fields for a constructor", vim.log.levels.WARN)
    return
  end

  if mode == "all" then
    if constructor_exists(state.node, state.ctors, fields) then
      notify("a constructor with all these parameters already exists", vim.log.levels.WARN)
      return
    end
    generate_constructor(state, fields)
    return
  end

  pick_multi(field_items(fields), { title = "Java: Generate — Constructor (select fields)" }, function(selected)
    if #selected == 0 then
      return
    end
    local chosen = {}
    for _, item in ipairs(selected) do
      chosen[#chosen + 1] = item.data
    end
    if constructor_exists(state.node, state.ctors, chosen) then
      notify("a constructor with these parameters already exists", vim.log.levels.WARN)
      return
    end
    generate_constructor(state, chosen)
  end)
end

---@param mode string "get"|"set"|"both"
local function accessors(state, mode)
  local bufnr = state.bufnr
  local items = {}

  for i, entry in ipairs(state.accessors or {}) do
    local can_get = entry.generateGetter
    local can_set = entry.generateSetter
    local text = (entry.typeName or "?") .. " " .. entry.fieldName
    if entry.isStatic then
      text = text .. "  (static)"
    end

    local available = (mode == "get" and can_get)
      or (mode == "set" and can_set)
      or (mode == "both" and (can_get or can_set))
    if available then
      items[#items + 1] = {
        text = text,
        idx = i,
        data = {
          fieldName = entry.fieldName,
          generateGetter = mode ~= "set" and can_get,
          generateSetter = mode ~= "get" and can_set,
        },
      }
    elseif mode == "set" and not can_set then
      items[#items + 1] = { text = text .. "  (unavailable: final field or existing setter)", idx = i, disabled = true }
    elseif mode == "get" and not can_get then
      items[#items + 1] = { text = text .. "  (unavailable: existing getter)", idx = i, disabled = true }
    end
  end

  local available = vim.tbl_filter(function(item)
    return not item.disabled
  end, items)

  if #available == 0 then
    notify("no fields available for " .. (mode == "both" and "getter/setter" or mode), vim.log.levels.WARN)
    return
  end

  local title = "Java: Generate — "
    .. (mode == "both" and "Getter + Setter" or (mode == "get" and "Getter" or "Setter"))

  pick_multi(items, { title = title .. " (select fields)" }, function(selected)
    local chosen = {}
    for _, item in ipairs(selected) do
      if item.disabled then
        notify("selected field has no available accessor", vim.log.levels.WARN)
      else
        chosen[#chosen + 1] = item.data
      end
    end
    if #chosen == 0 then
      return
    end
    in_buffer(bufnr, function()
      with_indent(bufnr, function()
        require("jc.jdtls").generate_accessors(chosen)
      end)
    end, state.tick)
  end)
end

local TOSTRING_STYLES = {
  "STRING_CONCATENATION",
  "STRING_BUILDER",
  "STRING_BUILDER_CHAINED",
  "STRING_FORMAT",
}

local function tostring_op(state)
  local bufnr = state.bufnr
  local client = state.client
  if not client then
    notify("jdtls is not attached to this buffer", vim.log.levels.WARN)
    return
  end
  in_buffer(bufnr, function()
    client:request("java/checkToStringStatus", range_params(bufnr, client), function(err, resp)
      if not resp then
        notify("checkToStringStatus failed: " .. vim.inspect(err), vim.log.levels.WARN)
        return
      end

      local fields = vim.tbl_filter(function(field)
        return field.isField
      end, resp.fields or {})

      if #fields == 0 then
        notify("the class has no fields for toString()", vim.log.levels.WARN)
        return
      end

      pick_multi(field_items(fields), { title = "Java: Generate — toString() (select fields)" }, function(selected)
        if #selected == 0 then
          return
        end
        local chosen = {}
        for _, item in ipairs(selected) do
          chosen[#chosen + 1] = item.data
        end
        pick_one(TOSTRING_STYLES, ":toString() style", function(style)
          in_buffer(bufnr, function()
            with_indent(bufnr, function()
              require("jc.jdtls").generate_toString(chosen, { code_style = style })
            end)
          end, state.tick)
        end)
      end)
    end)
  end)
end

local function equals_hashcode(state)
  local bufnr = state.bufnr
  local client = state.client
  if not client then
    notify("jdtls is not attached to this buffer", vim.log.levels.WARN)
    return
  end
  in_buffer(bufnr, function()
    client:request("java/checkHashCodeEqualsStatus", range_params(bufnr, client), function(err, resp)
      if not resp then
        notify("checkHashCodeEqualsStatus failed: " .. vim.inspect(err), vim.log.levels.WARN)
        return
      end

      local fields = vim.tbl_filter(function(field)
        return field.isField
      end, resp.fields or {})

      if #fields == 0 then
        notify("the class has no fields for equals()/hashCode()", vim.log.levels.WARN)
        return
      end

      local function choose()
        pick_multi(
          field_items(fields),
          { title = "Java: Generate — equals() + hashCode() (select fields)" },
          function(selected)
            if #selected == 0 then
              return
            end
            local chosen = {}
            for _, item in ipairs(selected) do
              chosen[#chosen + 1] = item.data
            end
            in_buffer(bufnr, function()
              with_indent(bufnr, function()
                require("jc.jdtls").generate_hashCodeAndEquals(chosen)
              end)
            end, state.tick)
          end
        )
      end

      if has_method(state.methods, "hashCode") or has_method(state.methods, "equals") then
        confirm_replace("equals()/hashCode()", choose)
      else
        choose()
      end
    end)
  end)
end

local function abstract_methods(state)
  in_buffer(state.bufnr, function()
    with_indent(state.bufnr, function()
      require("jc.jdtls").generate_abstractMethods(true)
    end)
  end, state.tick)
end

-- ---------- menu ----------

local function operations(state)
  local methods = state.methods or {}
  local can = jdtls_attached(state.bufnr) and state.node ~= nil
  local fields = constructor_fields(state)
  local has_fields = #fields > 0
  local full_constructor = has_fields and constructor_exists(state.node, state.ctors, fields)
  local has_any_field = #(state.fields or {}) > 0
  local final_field_pending = has_pending_final_field(state)

  local getter, setter, both = false, false, false
  for _, entry in ipairs(state.accessors or {}) do
    if entry.generateGetter then
      getter = true
    end
    if entry.generateSetter then
      setter = true
    end
    if entry.generateGetter or entry.generateSetter then
      both = true
    end
  end

  local function reason(extra)
    if not jdtls_attached(state.bufnr) then
      return "jdtls is not attached to this buffer"
    end
    if not state.node then
      return "no recognized Java class in the buffer"
    end
    return extra or "unavailable"
  end

  return {
    {
      key = "constructor",
      label = "Constructor (Select Fields)",
      enabled = can and has_fields,
      reason = reason("class has no fields for a constructor"),
    },
    {
      key = "all_args",
      label = "All-Args Constructor",
      enabled = can and has_fields and not full_constructor,
      reason = full_constructor and "a constructor with all these parameters already exists"
        or reason("class has no fields for a constructor"),
    },
    {
      key = "no_args",
      label = "No-Args Constructor",
      enabled = can and not has_default_constructor(state.node, state.ctors) and not final_field_pending,
      reason = has_default_constructor(state.node, state.ctors) and "a no-args constructor already exists"
        or (final_field_pending and "there is a final field without an initializer; use a constructor with parameters")
        or reason("unavailable"),
    },
    { key = "getter", label = "Getter", enabled = can and getter, reason = reason("no field without a getter") },
    {
      key = "setter",
      label = "Setter",
      enabled = can and setter,
      reason = reason("no field without a setter (final or already present)"),
    },
    { key = "both", label = "Getter + Setter", enabled = can and both, reason = reason("no fields available") },
    {
      key = "tostring",
      label = "toString()",
      enabled = can and has_any_field and not has_method(methods, "toString"),
      reason = has_method(methods, "toString") and "toString() already exists in the class"
        or reason("class has no fields"),
    },
    {
      key = "equals_hashcode",
      label = "equals() + hashCode()",
      enabled = can and has_any_field,
      reason = reason("class has no fields"),
    },
    {
      key = "abstract_methods",
      label = "Implement Abstract Methods",
      -- diagnostics arrive in waves: only report "nothing pending" when jdtls
      -- is idle; otherwise let the attempt run (jc warns when there is nothing
      -- to implement)
      enabled = can and (abstract_state(state.bufnr) ~= "none" or jca.jdtls_busy()),
      reason = can and "no pending abstract methods" or reason("unavailable"),
    },
  }
end

local RUNNERS = {
  constructor = function(state)
    constructor(state, "select")
  end,
  all_args = function(state)
    constructor(state, "all")
  end,
  no_args = function(state)
    constructor(state, "none")
  end,
  getter = function(state)
    accessors(state, "get")
  end,
  setter = function(state)
    accessors(state, "set")
  end,
  both = function(state)
    accessors(state, "both")
  end,
  tostring = tostring_op,
  equals_hashcode = equals_hashcode,
  abstract_methods = abstract_methods,
}

---Entry point of `<leader>jg`.
function M.generate()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "java" then
    notify("Generate requires a Java class buffer", vim.log.levels.WARN)
    return
  end

  load_state(bufnr, function(state)
    if not ui.same_buffer(bufnr) then
      return
    end
    local jc_guard = lsp.jc_global_reason("Generate")
    if jc_guard then
      notify(jc_guard, vim.log.levels.WARN)
      return
    end
    if not jdtls_attached(bufnr) then
      notify("jdtls is not attached to this buffer — generation disabled", vim.log.levels.WARN)
    end

    ui.menu(operations(state), "Java: Generate", function(entry)
      local runner = RUNNERS[entry.key]
      if runner then
        runner(state)
      end
    end)
  end)
end

-- exposed for tests
M._operations = operations
M._load_state = load_state
M._constructor_fields = constructor_fields
M._has_pending_final_field = has_pending_final_field

return M
