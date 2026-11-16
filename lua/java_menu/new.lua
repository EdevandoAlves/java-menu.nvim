-- java_menu/new.lua
-- "New" flow of the <leader>j menu: central popups (Snacks) + validation + creation.
-- Uses jc.nvim public templates when available; falls back to the previous
-- generator (config/java.lua) for basic kinds when jc is not loaded.
--
-- Supports extends/implements/fields/components, extra jc templates and a
-- summary before creating. Type semantics come from JDTLS (workspace/symbol);
-- chosen types enter as FQNs, so the file does not depend on automatic imports.
-- Without JDTLS, basic creation still works and types are typed manually.

local ui = require("java_menu.ui")
local project = require("java_menu.project")
local lsp = require("java_menu.lsp")

local M = {}

---@class JavaKind
---@field label string
---@field template string jc.nvim template
---@field legacy string|nil kind accepted by the previous generator (without jc)
---@field decl string "class"|"interface"|"enum"|"record"|"annotation"
---@field abstract boolean|nil
---@field extends_slot string|nil "class" (one superclass) | "interface" (several)
---@field implements boolean|nil
---@field fields string|nil "fields"|"components"|"methods"|"elements"
---@field values boolean|nil
---@field requires string|nil "junit"|"spring"|"jpa"
---@field extra boolean|nil additional template (requires jc.nvim)

---@type JavaKind[]
M.kinds = {
  {
    label = "Class",
    template = "class",
    legacy = "class",
    decl = "class",
    extends_slot = "class",
    implements = true,
    fields = "fields",
  },
  {
    label = "Abstract Class",
    template = "class",
    legacy = "class",
    decl = "class",
    abstract = true,
    extends_slot = "class",
    implements = true,
    fields = "fields",
  },
  {
    label = "Interface",
    template = "interface",
    legacy = "interface",
    decl = "interface",
    extends_slot = "interface",
    fields = "methods",
  },
  {
    label = "Enum",
    template = "enum",
    legacy = "enum",
    decl = "enum",
    implements = true,
    fields = "fields",
    values = true,
  },
  {
    label = "Record",
    template = "record",
    legacy = "record",
    decl = "record",
    implements = true,
    fields = "components",
  },
  { label = "Annotation", template = "annotation", legacy = "annotation", decl = "annotation", fields = "elements" },

  -- additional jc.nvim templates (only those meaningful in plain Java or with
  -- the dependency detected in the build file)
  {
    label = "Exception",
    template = "exception",
    decl = "class",
    extends_slot = "class",
    implements = true,
    fields = "fields",
    extra = true,
  },
  {
    label = "Class with main",
    template = "main",
    decl = "class",
    extends_slot = "class",
    implements = true,
    fields = "fields",
    extra = true,
  },
  {
    label = "Singleton",
    template = "singleton",
    decl = "class",
    implements = true,
    fields = "fields",
    extra = true,
  },
  {
    label = "Serializable",
    template = "serializable",
    decl = "class",
    extends_slot = "class",
    implements = true,
    fields = "fields",
    extra = true,
  },
  {
    label = "JUnit 5 Test",
    template = "junit5",
    decl = "class",
    fields = "fields",
    requires = "junit",
    extra = true,
  },
  {
    label = "Spring Service",
    template = "service",
    decl = "class",
    implements = true,
    fields = "fields",
    requires = "spring",
    extra = true,
  },
  {
    label = "Spring Component",
    template = "component",
    decl = "class",
    implements = true,
    fields = "fields",
    requires = "spring",
    extra = true,
  },
  {
    label = "Spring Controller",
    template = "controller",
    decl = "class",
    implements = true,
    fields = "fields",
    requires = "spring",
    extra = true,
  },
  {
    label = "Spring Repository",
    template = "repository",
    decl = "interface",
    fields = "methods",
    requires = "jpa",
    extra = true,
  },
  {
    label = "JPA Entity",
    template = "entity",
    decl = "class",
    implements = true,
    fields = "fields",
    requires = "jpa",
    extra = true,
  },
}

local OTHER_ROOT = "(another directory…)"

-- Java reserved words and literals (list kept as a string to avoid using
-- Lua reserved words as keys)
local keywords = {}
for word in
  ([[
abstract assert boolean break byte case catch char class const continue default do double else
enum extends final finally float for goto if implements import instanceof int interface long native new
package private protected public return short static strictfp super switch synchronized this throw throws
transient try var void volatile while true false null _
]]):gmatch("%S+")
do
  keywords[word] = true
end

local function notify(msg, level)
  vim.notify("Java: " .. msg, level or vim.log.levels.INFO)
end

---Central selection (Snacks) through the shared component, with a fallback to
---native vim.ui.select. Does not replace vim.ui.select globally.
local function select(items, opts, on_choice)
  local prompt = opts and opts.prompt or "Java"
  if ui.snacks() then
    return ui.pick_one(items, prompt, on_choice)
  end
  return vim.ui.select(items, opts, on_choice)
end

---Central text input through the shared component (vim.ui.input fallback).
local function input(opts, on_confirm)
  return ui.ask(opts.prompt, opts.default, on_confirm)
end

---@param name string
---@return boolean
local function is_identifier(name)
  return name:match("^[%a_$][%w_$]*$") ~= nil and not keywords[name]
end

---@param pkg string
---@return boolean
local function is_package(pkg)
  if pkg == "" then
    return true
  end
  for segment in pkg:gmatch("[^%.]+") do
    if not is_identifier(segment) then
      return false
    end
  end
  return not pkg:match("^%.") and not pkg:match("%.$") and not pkg:match("%.%.")
end

local primitives = {
  boolean = true,
  byte = true,
  short = true,
  int = true,
  long = true,
  char = true,
  float = true,
  double = true,
}

---Validate a type expression (primitive, FQN, generics, arrays).
---Not a full parser: rejects what is clearly invalid.
---@param value string
---@param allow_void boolean|nil
---@return boolean
local function is_type(value, allow_void)
  if value == "" then
    return false
  end
  if value == "void" then
    return allow_void == true
  end
  if keywords[value] and not primitives[value] then
    return false
  end
  if not value:match("^[%w_$%.,%s%<%>%?%[%]&]+$") then
    return false
  end
  if value:match("%.%.") or value:match("^%.") or value:match("%.$") then
    return false
  end
  local depth = 0
  local brackets = 0
  for i = 1, #value do
    local c = value:sub(i, i)
    if c == "<" then
      depth = depth + 1
    elseif c == ">" then
      depth = depth - 1
      if depth < 0 then
        return false
      end
    elseif c == "[" then
      brackets = brackets + 1
    elseif c == "]" then
      brackets = brackets - 1
      if brackets < 0 then
        return false
      end
    end
  end
  return depth == 0 and brackets == 0
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

-- ---------- project dependencies ----------

---Lowercase text of the root and direct-module build files.
---Used to enable/disable templates and decide javax vs jakarta.
---@param root string
---@return string
local function build_text(root)
  local parts = {}
  for _, dir in ipairs(project.modules(root)) do
    for _, name in ipairs({ "pom.xml", "build.gradle", "build.gradle.kts" }) do
      local path = dir .. "/" .. name
      if vim.fn.filereadable(path) == 1 then
        parts[#parts + 1] = table.concat(vim.fn.readfile(path), "\n")
      end
    end
  end
  return table.concat(parts, "\n"):lower()
end

local function has_junit(deps)
  return deps:find("junit", 1, true) ~= nil
end

local function has_spring(deps)
  return deps:find("org.springframework", 1, true) ~= nil
    or deps:find("spring-boot", 1, true) ~= nil
    or deps:find("spring-context", 1, true) ~= nil
    or deps:find("spring-web", 1, true) ~= nil
end

local function has_jpa(deps)
  return deps:find("spring-boot-starter-data-jpa", 1, true) ~= nil
    or deps:find("spring-data-jpa", 1, true) ~= nil
    or deps:find("jakarta.persistence", 1, true) ~= nil
    or deps:find("javax.persistence", 1, true) ~= nil
    or deps:find("hibernate-core", 1, true) ~= nil
    or deps:find("eclipselink", 1, true) ~= nil
end

---Project persistence namespace ("jakarta" or "javax").
---@param deps string
---@return string|nil
local function persistence_namespace(deps)
  if deps:find("jakarta", 1, true) then
    return "jakarta"
  end
  if deps:find("javax", 1, true) then
    return "javax"
  end
  -- spring-boot-starter-parent 3.x => jakarta, 2.x => javax
  local version = deps:match("spring%-boot%-starter%-parent.-<version>%s*([%d]+)")
  if version then
    return version == "3" and "jakarta" or "javax"
  end
  return nil
end

-- ---------- jc.nvim templates ----------

---jc.nvim public templates (data module, does not start a server).
local function jc_templates()
  local ok, templates = pcall(require, "jc.templates")
  if ok and type(templates.render) == "function" then
    return templates
  end
end

local FIXED_IMPORTS = {
  service = { "org.springframework.stereotype.Service" },
  component = { "org.springframework.stereotype.Component" },
  controller = {
    "org.springframework.web.bind.annotation.RestController",
    "org.springframework.web.bind.annotation.RequestMapping",
  },
  repository = { "org.springframework.data.jpa.repository.JpaRepository" },
}

---Imports the template does not declare itself (jc annotations are resolved
---by organize-imports in the original flow; here we declare the detected
---namespace so an ambiguous import is never generated).
---@param kind JavaKind
---@param deps string
---@return string[]|nil
local function template_imports(kind, deps)
  if kind.template == "entity" then
    local ns = persistence_namespace(deps or "")
    if not ns then
      return nil
    end
    return {
      ns .. ".persistence.Entity",
      ns .. ".persistence.Id",
      ns .. ".persistence.GeneratedValue",
      ns .. ".persistence.GenerationType",
      ns .. ".persistence.Column",
    }
  end
  return FIXED_IMPORTS[kind.template]
end

---@param kind JavaKind
---@param deps string
---@return boolean, string|nil
local function kind_availability(kind, deps)
  if kind.requires == "junit" and not has_junit(deps) then
    return false, "project has no JUnit dependency in pom/build.gradle"
  end
  if kind.requires == "spring" and not has_spring(deps) then
    return false, "project has no Spring dependency in pom/build.gradle"
  end
  if kind.requires == "jpa" then
    if not has_jpa(deps) then
      return false, "project has no JPA (spring-data-jpa / jakarta.persistence)"
    end
    if kind.template == "entity" and not persistence_namespace(deps) then
      return false, "could not decide between jakarta.persistence and javax.persistence"
    end
  end
  if kind.extra then
    local templates = jc_templates()
    if not templates then
      return false, "jc.nvim is not loaded"
    end
    if type(templates.get) ~= "function" or templates.get(kind.template) == nil then
      return false, "template '" .. kind.template .. "' does not exist in this jc.nvim"
    end
  end
  return true
end

---@return boolean
local function jdtls_attached(bufnr)
  return lsp.client(bufnr) ~= nil
end

---Render the kind with the jc.nvim template.
---@param kind JavaKind
---@param pkg string
---@param name string
---@param opts table|nil
---@return string|nil
local function render_jc(kind, pkg, name, opts)
  local templates = jc_templates()
  if not templates then
    return nil
  end
  opts = vim.deepcopy(opts or {})
  opts.name = name
  opts.package = pkg
  local ok, body = pcall(templates.render, kind.template, opts)
  if not ok or type(body) ~= "string" or vim.trim(body) == "" then
    return nil
  end
  if kind.abstract then
    body = body:gsub("public class ", "public abstract class ", 1)
  end
  -- jc.nvim templates expect a :normal! gg=G afterwards; without a Java parser
  -- we normalize here to remove extra blank lines
  body = body:gsub("\n\n\n+", "\n\n")
  return body
end

---Create the requested kind file. Never overwrites.
---@param kind JavaKind
---@param source_root string
---@param pkg string
---@param name string
---@param opts table|nil extends/implements/fields/values/imports
---@return string|nil file
function M.create(kind, source_root, pkg, name, opts)
  local dir = source_root
  if pkg ~= "" then
    dir = dir .. "/" .. pkg:gsub("%.", "/")
  end
  local file = dir .. "/" .. name .. ".java"
  local root = project.root() or source_root
  local rel = vim.fs.relpath(root, file) or file

  if vim.fn.filereadable(file) == 1 then
    notify("already exists, nothing was overwritten: " .. rel, vim.log.levels.WARN)
    vim.cmd.edit(vim.fn.fnameescape(file))
    return file
  end

  pcall(vim.fn.mkdir, dir, "p")
  if vim.fn.isdirectory(dir) == 0 then
    notify("could not create directory " .. dir, vim.log.levels.ERROR)
    return nil
  end
  if vim.fn.filewritable(dir) ~= 2 then
    notify("directory is not writable: " .. dir, vim.log.levels.ERROR)
    return nil
  end

  local body = render_jc(kind, pkg, name, opts)
  if body then
    -- :edit triggers BufNewFile, so jc marks the file as new and
    -- updates the jdtls build path on first write
    vim.cmd.edit(vim.fn.fnameescape(file))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(body:gsub("\n+$", ""), "\n", { plain = true }))
    -- jc templates rely on the same post-step as its generator
    vim.cmd("silent! normal! gg=G")
    vim.cmd.write()
    notify("created " .. rel)
    return file
  end

  if kind.extra then
    notify("template '" .. kind.template .. "' requires jc.nvim to be loaded", vim.log.levels.ERROR)
    return nil
  end

  -- fallback: previous generator (basic kinds only)
  local has_options = opts
    and (
      (opts.extends and opts.extends ~= "")
      or (opts.implements and opts.implements ~= "")
      or (opts.fields and #opts.fields > 0)
      or (opts.values and #opts.values > 0)
    )
  if has_options then
    notify("jc.nvim is not loaded — extends/implements/fields will not be applied", vim.log.levels.WARN)
  end
  local ok, legacy = pcall(require, "config.java")
  if not ok or type(legacy.create) ~= "function" then
    notify("jc.nvim is not loaded and the previous generator is unavailable", vim.log.levels.ERROR)
    return nil
  end

  local created = legacy.create({ package = pkg, name = name, kind = kind.legacy, root = source_root })
  if created and kind.abstract then
    local line = vim.fn.search("^public class ", "nw")
    if line > 0 then
      vim.api.nvim_buf_set_lines(0, line - 1, line, false, { "public abstract class " .. name .. " {" })
      vim.cmd.write()
    end
  end
  return created
end

-- ---------- type search in JDTLS ----------

local TYPE_KINDS = {
  -- LSP SymbolKind: 5 class, 10 enum, 11 interface, 23 struct (record in jdtls)
  class = { [5] = true },
  interface = { [11] = true },
  all = { [5] = true, [10] = true, [11] = true, [23] = true },
}

---workspace/symbol on the JDTLS client of the source buffer.
---@param query string
---@param allowed table<number, boolean>
---@param client vim.lsp.Client|nil
---@return string[]|nil
local function search_types(query, allowed, client)
  if not client then
    return nil
  end

  local response
  local ok = pcall(function()
    if type(client.request_sync) == "function" then
      response = client:request_sync("workspace/symbol", { query = query }, 3000)
    else
      local results = vim.lsp.buf_request_sync(0, "workspace/symbol", { query = query }, 3000)
      for _, result in pairs(results or {}) do
        response = result
        break
      end
    end
  end)
  if not ok or type(response) ~= "table" or response.err then
    return nil
  end

  local result = response.result
  if type(result) ~= "table" then
    return nil
  end

  local out, seen = {}, {}
  local root = project.root()
  for _, sym in ipairs(result) do
    local uri = sym.location and sym.location.uri or ""
    -- nested types are not importable by simple name (and here enter
    -- as FQN, but jdtls indexes $Inner: avoid polluting the list)
    local enclosing = sym.containerName and sym.containerName:match("[^.]+$")
    local nested = uri:find("%$") ~= nil or (enclosing ~= nil and enclosing:match("^%u") ~= nil)
    -- the index covers the whole workspace: accepts types from the current
    -- project and classpath dependencies (jdt://), ignoring other open projects
    local from_project = false
    if uri:match("^file:") and root then
      local path = vim.uri_to_fname(uri)
      from_project = path:sub(1, #root + 1) == root .. "/"
    end
    local importable = uri:match("^jdt:") ~= nil or from_project
    local container = sym.containerName or ""
    local fqn = container ~= "" and (container .. "." .. sym.name) or sym.name
    if allowed[sym.kind] and importable and not nested and not seen[fqn] then
      seen[fqn] = true
      out[#out + 1] = fqn
    end
  end
  table.sort(out)
  return out
end

---Ask for a type (JDTLS search or manual FQN).
---@param slot string label ("Superclass", "Interfaces"…)
---@param allowed table<number, boolean>
---@param multi boolean
---@param on_done fun(types: string[])
---@param on_cancel fun()|nil returns to the previous step
---@param bufnr number|nil source buffer for the JDTLS client
local function ask_type(slot, allowed, multi, on_done, on_cancel, bufnr)
  on_cancel = on_cancel or function() end
  local title = "Java: New — " .. slot

  local function manual()
    input({ prompt = "Java: New — " .. slot .. ": FQN (e.g. java.util.ArrayList): " }, function(value)
      if value == nil then
        return on_cancel()
      end
      value = vim.trim(value)
      if not is_type(value, false) or (not multi and value:find(",", 1, true) ~= nil) then
        notify("invalid Java type: " .. (value == "" and "(empty)" or value), vim.log.levels.WARN)
        return manual()
      end
      on_done({ value })
    end)
  end

  local client = lsp.client(bufnr)
  if not client then
    notify("jdtls is not attached — enter the type by FQN", vim.log.levels.WARN)
    return manual()
  end

  input({ prompt = "Java: New — " .. slot .. ": search type in jdtls (empty = enter FQN): " }, function(query)
    if query == nil then
      return on_cancel()
    end
    query = vim.trim(query)
    if query == "" then
      return manual()
    end
    local found = search_types(query, allowed, client)
    if not found or #found == 0 then
      notify("no type found for '" .. query .. "' — enter the FQN", vim.log.levels.WARN)
      return manual()
    end
    if multi then
      ui.pick_many(found, title, function(chosen)
        if chosen == nil then
          return on_cancel()
        end
        on_done(chosen)
      end)
    else
      select(found, { prompt = title }, function(choice)
        if choice == nil then
          return on_cancel()
        end
        on_done({ choice })
      end)
    end
  end)
end

-- ---------- flow: options ----------

local ask_options
local show_summary

local function ask_extends(state)
  local slot = state.kind.extends_slot
  ask_type("Superclass", TYPE_KINDS[slot], false, function(chosen)
    if not chosen or #chosen == 0 then
      return
    end
    state.extends = chosen[1]
    ask_options(state)
  end, function()
    ask_options(state)
  end, state.bufnr)
end

local function ask_parents(state)
  ask_type("Parent interfaces", TYPE_KINDS.interface, true, function(chosen)
    if not chosen or #chosen == 0 then
      return ask_options(state)
    end
    for _, type_name in ipairs(chosen) do
      if type_name ~= state.name and not contains(state.parents, type_name) then
        state.parents[#state.parents + 1] = type_name
      end
    end
    ask_options(state)
  end, function()
    ask_options(state)
  end, state.bufnr)
end

local function ask_implements(state)
  ask_type("Interfaces", TYPE_KINDS.interface, true, function(chosen)
    if not chosen or #chosen == 0 then
      return ask_options(state)
    end
    for _, type_name in ipairs(chosen) do
      if type_name ~= state.name and not contains(state.implements, type_name) then
        state.implements[#state.implements + 1] = type_name
      end
    end
    ask_options(state)
  end, function()
    ask_options(state)
  end, state.bufnr)
end

local FIELD_MODIFIERS = {
  { label = "private", value = "private" },
  { label = "private static", value = "private static" },
  { label = "protected", value = "protected" },
  { label = "protected static", value = "protected static" },
  { label = "public", value = "public" },
  { label = "public static", value = "public static" },
  { label = "static", value = "static" },
}

local function choose_modifier(on_done, current)
  local labels = {}
  local by_label = {}
  for _, modifier in ipairs(FIELD_MODIFIERS) do
    local label = modifier.label
    if current == modifier.value then
      label = label .. "  (current)"
    end
    labels[#labels + 1] = label
    by_label[label] = modifier.value
  end
  select(labels, { prompt = "Java: New — field modifier" }, function(choice)
    if choice == nil then
      return
    end
    on_done(by_label[choice] or "private")
  end)
end

local function field_noun(kind)
  if kind.fields == "components" then
    return "component"
  elseif kind.fields == "methods" then
    return "method"
  elseif kind.fields == "elements" then
    return "element"
  end
  return "field"
end

local function field_text(kind, field)
  if kind.fields == "components" then
    return field.type .. " " .. field.name
  elseif kind.fields == "methods" or kind.fields == "elements" then
    return field.type .. " " .. field.name .. "()"
  end
  return field.mod .. " " .. field.type .. " " .. field.name
end

---@param state table
---@param edit_index number|nil absent = add; present = edit in place
local function ask_fields(state, edit_index)
  local kind = state.kind
  local is_component = kind.fields == "components"
  local is_member = kind.fields == "methods" or kind.fields == "elements"
  local target = edit_index and state.fields[edit_index] or nil
  -- copy: cancelling mid-edit does not change already-confirmed state
  local field = target and vim.deepcopy(target) or { type = "", name = "", mod = "private" }

  local ask_one
  local ask_more

  local more_prompt = is_component and "Java: New — components"
    or kind.fields == "methods" and "Java: New — methods"
    or kind.fields == "elements" and "Java: New — elements"
    or "Java: New — fields"

  local function back()
    ask_options(state)
  end

  local function finish()
    if target then
      state.fields[edit_index] = field
      return ask_options(state)
    end
    state.fields[#state.fields + 1] = field
    ask_more()
  end

  ask_more = function()
    select({ "Add another", "Back to options" }, { prompt = more_prompt }, function(choice)
      if choice == nil then
        return back()
      end
      if choice == "Add another" then
        field = { type = "", name = "", mod = "private" }
        return ask_one()
      end
      ask_options(state)
    end)
  end

  ask_one = function()
    local type_prompt = is_component and "Java: New — component type: "
      or is_member and "Java: New — return type: "
      or "Java: New — field type (FQN or primitive): "
    input({ prompt = type_prompt, default = field.type }, function(type_text)
      if type_text == nil then
        return back()
      end
      type_text = vim.trim(type_text)
      if not is_type(type_text, kind.fields == "methods") then
        notify("invalid Java type: " .. (type_text == "" and "(empty)" or type_text), vim.log.levels.WARN)
        return ask_one()
      end
      field.type = type_text

      local name_prompt = is_component and "Java: New — component name: "
        or kind.fields == "methods" and "Java: New — method name: "
        or kind.fields == "elements" and "Java: New — element name: "
        or "Java: New — field name: "
      input({ prompt = name_prompt, default = field.name }, function(field_name)
        if field_name == nil then
          return back()
        end
        field_name = vim.trim(field_name)
        if not is_identifier(field_name) then
          notify("invalid Java identifier: " .. (field_name == "" and "(empty)" or field_name), vim.log.levels.WARN)
          return ask_one()
        end
        for index, existing in ipairs(state.fields) do
          if index ~= edit_index and existing.name == field_name then
            notify("a field/component with this name already exists: " .. field_name, vim.log.levels.WARN)
            return ask_one()
          end
        end
        field.name = field_name

        if is_component or is_member then
          field.mod = "private"
          return finish()
        end

        choose_modifier(function(mod)
          if mod == nil then
            return back()
          end
          field.mod = mod
          finish()
        end, target and target.mod or nil)
      end)
    end)
  end

  ask_one()
end

local function ask_values(state)
  input({ prompt = "Java: New — enum constant (empty = finish): ", default = "" }, function(value)
    if value == nil then
      return ask_options(state)
    end
    value = vim.trim(value)
    if value == "" then
      return ask_options(state)
    end
    if not is_identifier(value) then
      notify("invalid Java identifier: " .. value, vim.log.levels.WARN)
      return ask_values(state)
    end
    if contains(state.values, value) then
      notify("duplicate constant: " .. value, vim.log.levels.WARN)
      return ask_values(state)
    end
    state.values[#state.values + 1] = value
    ask_values(state)
  end)
end

---@param state table
local function field_label(kind)
  if kind.fields == "components" then
    return "Record components"
  elseif kind.fields == "methods" then
    return "Methods"
  elseif kind.fields == "elements" then
    return "Annotation elements"
  end
  return "Fields"
end

---Ask for (or edit) package and name while preserving the other choices.
---@param state table
---@param on_done fun()
local function ask_identity(state, on_done)
  local editing = state.name ~= nil

  local function cancel()
    if editing then
      return ask_options(state)
    end
  end

  local function ask_name(pkg_value)
    input({ prompt = "Java: New — type name: ", default = state.name or "" }, function(name)
      if name == nil then
        return cancel()
      end
      name = vim.trim(name)
      if not is_identifier(name) then
        notify("invalid Java identifier: " .. (name == "" and "(empty)" or name), vim.log.levels.WARN)
        return ask_name(pkg_value)
      end
      state.pkg = pkg_value
      state.name = name
      on_done()
    end)
  end

  input({ prompt = "Java: New — package (empty = default): ", default = state.pkg or "" }, function(pkg)
    if pkg == nil then
      return cancel()
    end
    pkg = vim.trim(pkg)
    if not is_package(pkg) then
      notify("invalid Java package: " .. pkg, vim.log.levels.WARN)
      return ask_identity(state, on_done)
    end
    ask_name(pkg)
  end)
end

local function remove_from_list(list, prompt, on_done)
  local labels = {}
  for index, item in ipairs(list) do
    labels[index] = index .. ". " .. item
  end
  select(labels, { prompt = prompt }, function(choice)
    if choice == nil then
      return
    end
    local index = tonumber(choice:match("^(%d+)"))
    if index and list[index] then
      table.remove(list, index)
      on_done()
    end
  end)
end

local function pick_field(state, prompt, on_pick)
  local labels = {}
  for index, field in ipairs(state.fields) do
    labels[index] = index .. ". " .. field_text(state.kind, field)
  end
  select(labels, { prompt = prompt }, function(choice)
    if choice == nil then
      return
    end
    local index = tonumber(choice:match("^(%d+)"))
    if index and state.fields[index] then
      on_pick(index)
    end
  end)
end

ask_options = function(state)
  local kind = state.kind
  local items = { "(review and create)" }
  local handlers = {}

  local function add(label, fn)
    items[#items + 1] = label
    handlers[label] = fn
  end

  if kind.extends_slot == "class" then
    add("Superclass (extends)" .. (state.extends and (": " .. state.extends) or ""), function()
      ask_extends(state)
    end)
  elseif kind.extends_slot == "interface" then
    local suffix = #state.parents > 0 and (": " .. table.concat(state.parents, ", ")) or ""
    add("Parent interfaces (extends)" .. suffix, function()
      ask_parents(state)
    end)
  end

  if kind.implements then
    local suffix = #state.implements > 0 and (" (" .. #state.implements .. ")") or ""
    add("Interfaces (implements)" .. suffix, function()
      ask_implements(state)
    end)
  end

  if kind.fields then
    local suffix = #state.fields > 0 and (" (" .. #state.fields .. ")") or ""
    add(field_label(kind) .. suffix, function()
      ask_fields(state)
    end)
  end

  if kind.values then
    local suffix = #state.values > 0 and (" (" .. #state.values .. ")") or ""
    add("Enum constants" .. suffix, function()
      ask_values(state)
    end)
  end

  local noun = field_noun(kind)
  if kind.implements and #state.implements > 0 then
    add("Remove interface…", function()
      remove_from_list(state.implements, "Java: New — remove interface", function()
        ask_options(state)
      end)
    end)
  end
  if kind.extends_slot == "interface" and #state.parents > 0 then
    add("Remove parent interface…", function()
      remove_from_list(state.parents, "Java: New — remove parent interface", function()
        ask_options(state)
      end)
    end)
  end
  if kind.fields and #state.fields > 0 then
    add("Edit " .. noun .. "…", function()
      pick_field(state, "Java: New — edit " .. noun, function(index)
        ask_fields(state, index)
      end)
    end)
    add("Remove " .. noun .. "…", function()
      pick_field(state, "Java: New — remove " .. noun, function(index)
        table.remove(state.fields, index)
        ask_options(state)
      end)
    end)
  end
  if kind.values and #state.values > 0 then
    add("Remove constant…", function()
      remove_from_list(state.values, "Java: New — remove constant", function()
        ask_options(state)
      end)
    end)
  end
  add("Edit name/package…", function()
    ask_identity(state, function()
      ask_options(state)
    end)
  end)

  select(items, { prompt = "Java: New — options (Enter reviews · Esc cancels)" }, function(choice)
    if choice == nil then
      return -- cancelled: nothing was created
    end
    if choice == "(review and create)" then
      return show_summary(state)
    end
    local handler = handlers[choice]
    if handler then
      handler()
    end
  end)
end

-- ---------- summary and creation ----------

local function file_path(source_root, pkg, name)
  local dir = source_root
  if pkg ~= "" then
    dir = dir .. "/" .. pkg:gsub("%.", "/")
  end
  return dir .. "/" .. name .. ".java"
end

---Implemented interfaces, including the template default (deduplicated:
---the serializable template already declares Serializable).
---@param state table
---@return string[]
local function effective_implements(state)
  local out = {}
  local implicit_serializable = state.kind.template == "serializable"
  if implicit_serializable then
    out[#out + 1] = "Serializable"
  end
  for _, type_name in ipairs(state.implements) do
    local redundant = implicit_serializable
      and (type_name == "Serializable" or type_name:match("%.Serializable$") ~= nil)
    if not redundant then
      out[#out + 1] = type_name
    end
  end
  return out
end

---@param state table
---@return table opts
local function build_opts(state)
  local opts = { imports = template_imports(state.kind, state.deps) }
  local interfaces = {}

  if state.kind.extends_slot == "interface" then
    for _, type_name in ipairs(state.parents) do
      interfaces[#interfaces + 1] = type_name
    end
    if #interfaces > 0 then
      opts.extends = table.concat(interfaces, ", ")
    end
  else
    if state.extends then
      opts.extends = state.extends
    end
    local effective = effective_implements(state)
    if #effective > 0 then
      opts.implements = table.concat(effective, ", ")
    end
  end

  if #state.fields > 0 then
    opts.fields = state.fields
  end
  if #state.values > 0 then
    opts.values = state.values
  end
  return opts
end

---@param state table
local function summary_lines(state)
  local kind = state.kind
  local root = project.root() or state.root
  local file = file_path(state.root, state.pkg, state.name)
  local rel = vim.fs.relpath(root, file) or file
  local lines = {
    "Type: " .. kind.label .. " (" .. kind.decl .. ")",
    "Name: " .. state.name,
    "Package: " .. (state.pkg == "" and "(default)" or state.pkg),
    "Source root: " .. state.root,
    "File: " .. rel,
  }

  if vim.fn.filereadable(file) == 1 then
    lines[#lines + 1] = "WARNING: the file already exists — nothing will be overwritten"
  end

  if state.extends then
    lines[#lines + 1] = "Extends: " .. state.extends
  elseif kind.template == "exception" then
    lines[#lines + 1] = "Extends: Exception (template default)"
  end
  if state.kind.extends_slot == "interface" and #state.parents > 0 then
    lines[#lines + 1] = "Extends: " .. table.concat(state.parents, ", ")
  elseif kind.template == "repository" then
    local entity = state.name:gsub("Repository$", ""):gsub("Repo$", "")
    if entity == "" then
      entity = "Entity"
    end
    lines[#lines + 1] = "Extends: JpaRepository<" .. entity .. ", Long> (template default)"
  end
  local implemented = effective_implements(state)
  if #implemented > 0 then
    lines[#lines + 1] = "Implements: " .. table.concat(implemented, ", ")
  end

  local opts = build_opts(state)
  if opts.imports and #opts.imports > 0 then
    lines[#lines + 1] = "Imports: " .. table.concat(opts.imports, ", ")
  end

  if #state.fields > 0 then
    if kind.fields == "components" then
      local parts = {}
      for _, field in ipairs(state.fields) do
        parts[#parts + 1] = field.type .. " " .. field.name
      end
      lines[#lines + 1] = "Components: " .. table.concat(parts, ", ")
    elseif kind.fields == "methods" or kind.fields == "elements" then
      local parts = {}
      for _, field in ipairs(state.fields) do
        parts[#parts + 1] = field.type .. " " .. field.name .. "();"
      end
      lines[#lines + 1] = (kind.fields == "methods" and "Methods: " or "Elements: ") .. table.concat(parts, " ")
    else
      local parts = {}
      for _, field in ipairs(state.fields) do
        parts[#parts + 1] = field.mod .. " " .. field.type .. " " .. field.name .. ";"
      end
      lines[#lines + 1] = "Fields: " .. table.concat(parts, " ")
    end
  end

  if #state.values > 0 then
    lines[#lines + 1] = "Constants: " .. table.concat(state.values, ", ")
  end

  return lines
end

---Show the summary and create only after "Create".
---@param state table
show_summary = function(state)
  local lines = summary_lines(state)
  local create_label = "✔ Create"
  local back_label = "← Back to options"
  local cancel_label = "✖ Cancel"
  local items = { create_label, back_label, cancel_label }
  vim.list_extend(items, lines)

  select(items, { prompt = "Java: New — summary (Enter creates · Esc cancels)" }, function(choice)
    if choice == nil then
      return -- cancelado
    end
    if choice == back_label then
      return ask_options(state)
    end
    if choice == cancel_label then
      return
    end
    if choice ~= create_label then
      -- informational summary line: reopen so it is not cancelled by accident
      return show_summary(state)
    end
    if state.done then
      return
    end
    state.done = true
    M.create(state.kind, state.root, state.pkg, state.name, build_opts(state))
  end)
end

M._summary = show_summary

-- ---------- entradas ----------

---Start the wizard with the state from previous steps.
---@param kind JavaKind
---@param source_root string
---@param suggested_pkg string
---@param deps string
---@param bufnr number source buffer (for type search in JDTLS)
local function start(kind, source_root, suggested_pkg, deps, bufnr)
  local state = {
    kind = kind,
    root = source_root,
    pkg = suggested_pkg,
    name = nil,
    deps = deps,
    extends = nil,
    parents = {},
    implements = {},
    fields = {},
    values = {},
    done = false,
    bufnr = bufnr,
  }
  ask_identity(state, function()
    ask_options(state)
  end)
end

---Source-root choice (with an option to type another one).
---@param kind JavaKind
---@param roots table[]
---@param deps string
---@param bufnr number source buffer (for type search in JDTLS)
local function pick_root(kind, roots, deps, bufnr)
  local preferred = project.preferred(roots)
  local ordered = { preferred }
  for _, r in ipairs(roots) do
    if r ~= preferred then
      ordered[#ordered + 1] = r
    end
  end

  local items = {}
  for _, r in ipairs(ordered) do
    items[#items + 1] = r.label
  end
  items[#items + 1] = OTHER_ROOT

  select(items, { prompt = "Java: New — source root" }, function(choice)
    if choice == nil then
      return -- cancelado
    end
    if choice == OTHER_ROOT then
      input({ prompt = "Java: New — source root: ", default = preferred.path }, function(path)
        if path == nil then
          return
        end
        path = vim.fs.normalize(vim.trim(path))
        if vim.fn.isdirectory(path) == 0 then
          notify("directory does not exist: " .. path, vim.log.levels.ERROR)
          return
        end
        start(kind, path, project.package_for(0, path), deps, bufnr)
      end)
      return
    end
    for _, r in ipairs(ordered) do
      if r.label == choice then
        return start(kind, r.path, project.package_for(0, r.path), deps, bufnr)
      end
    end
  end)
end

---Entry point of `<leader>jn`.
function M.new()
  local bufnr = vim.api.nvim_get_current_buf()
  local root = project.root(bufnr)
  if not root then
    notify("no Maven/Gradle project (pom.xml, build.gradle) found from this buffer", vim.log.levels.WARN)
    return
  end

  local roots = project.source_roots(root)
  if #roots == 0 then
    notify("project has no source root (src/main/java) in " .. root, vim.log.levels.WARN)
    return
  end

  if not jdtls_attached(bufnr) then
    notify(
      "jdtls is not attached — the file will be created, but type completion, automatic imports and code actions stay limited until the project is opened in a Java buffer",
      vim.log.levels.WARN
    )
  end

  local deps = build_text(root)

  local labels = {}
  local by_label = {}
  for _, kind in ipairs(M.kinds) do
    local available, reason = kind_availability(kind, deps)
    local label = kind.label
    if not available then
      label = label .. "  (unavailable: " .. reason .. ")"
    end
    labels[#labels + 1] = label
    by_label[label] = { kind = kind, available = available, reason = reason }
  end

  select(labels, { prompt = "Java: New — type" }, function(label)
    if label == nil then
      return -- cancelado
    end
    local entry = by_label[label]
    if not entry then
      return
    end
    if not entry.available then
      notify(entry.reason, vim.log.levels.WARN)
      return
    end
    pick_root(entry.kind, roots, deps, bufnr)
  end)
end

return M
