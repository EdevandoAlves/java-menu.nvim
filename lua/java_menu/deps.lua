-- java_menu/deps.lua
-- <leader>jp → Dependencies: inspect declared dependencies and add one to
-- Maven (pom.xml) or supported static Gradle (build.gradle / build.gradle.kts)
-- build files with surgical, byte-preserving edits.
--
-- Two layers, like create.lua:
--
--   * core  — pure, testable helpers exposed as M._*: comment-aware POM and
--     Gradle (Groovy/Kotlin) scanning, dependencyManagement/BOM/platform
--     awareness, indentation & style detection, surgical insertion that
--     preserves every byte outside the insertion point, version-catalog static
--     parsing (read-only) and the Maven Central helpers.
--   * shell — the read-only report and the interactive add flow. Cancelling
--     any step writes nothing; the write happens only after the final
--     confirmation and refuses symlinks, unsaved buffers and ambiguous/dynamic
--     Gradle constructs.
--
-- Nothing here runs Maven/Gradle to edit files, installs anything, parses XML
-- with a real parser (comments are masked and byte offsets are kept, so the
-- original text is never re-serialized) or executes Groovy/Kotlin scripts.
-- The JDTLS re-import is the LSP request validated against nvim-jdtls
-- (`java/projectConfigurationUpdate`), issued per buffer on the attached
-- client; no other client is touched.

local M = {}

local VALID_SCOPES = {
  compile = true,
  provided = true,
  runtime = true,
  test = true,
  system = true,
  import = true,
}

-- Gradle configurations whose string/catalog coordinates can be read
-- statically. Anything else is reported as partial coverage.
local GRADLE_CONFIGS = {
  implementation = true,
  api = true,
  compileOnly = true,
  compileOnlyApi = true,
  runtimeOnly = true,
  annotationProcessor = true,
  testImplementation = true,
  testCompileOnly = true,
  testRuntimeOnly = true,
  testAnnotationProcessor = true,
  developmentOnly = true,
  testAndDevelopmentOnly = true,
  classpath = true,
}

local GRADLE_EDIT_CONFIGS = {
  implementation = true,
  api = true,
  compileOnly = true,
  compileOnlyApi = true,
  runtimeOnly = true,
  annotationProcessor = true,
  testImplementation = true,
  testCompileOnly = true,
  testRuntimeOnly = true,
  testAnnotationProcessor = true,
  developmentOnly = true,
  testAndDevelopmentOnly = true,
}

local MAVEN_SEARCH_BASE = "https://search.maven.org/solrsearch/select?q="

local NO_PROJECT_REASON = "no Maven/Gradle project from this directory"
local GRADLE_EDIT_REASON = "Gradle build file uses unsupported or dynamic constructs — use Open build file"
local NO_CLIENT_REASON = "jdtls is not attached to this buffer"

-- ---------- small helpers ----------

local function trim(value)
  return vim.trim(value or "")
end

---Read all bytes from an already-open file descriptor starting at offset 0.
---@param fd integer
---@param path string
---@return string|nil data, string|nil err
local function read_fd_all(fd, path)
  local chunks = {}
  local offset = 0
  while true do
    local chunk, read_err = vim.uv.fs_read(fd, 65536, offset)
    if not chunk then
      return nil, "could not read " .. path .. (read_err and (": " .. read_err) or "")
    end
    if chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
    offset = offset + #chunk
  end
  return table.concat(chunks)
end

---Raw file contents (bytes preserved, unlike readfile + concat).
---@param path string
---@return string|nil data, string|nil err
local function read_file(path)
  local fd, open_err = vim.uv.fs_open(path, "r", 420)
  if not fd then
    return nil, "could not open " .. path .. (open_err and (": " .. open_err) or "")
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return nil, "could not stat " .. path
  end
  if stat.type ~= "file" then
    vim.uv.fs_close(fd)
    return nil, path .. " is not a regular file"
  end
  local data, read_err = read_fd_all(fd, path)
  vim.uv.fs_close(fd)
  return data, read_err
end

---@param a table|nil
---@param b table|nil
---@return boolean
local function stat_matches(a, b)
  if not a or not b then
    return false
  end
  if a.type ~= "file" or b.type ~= "file" or a.dev == nil or a.ino == nil then
    return false
  end
  if a.dev ~= b.dev or a.ino ~= b.ino or a.size ~= b.size or a.mode ~= b.mode then
    return false
  end
  local am, bm = a.mtime, b.mtime
  if (am == nil) ~= (bm == nil) then
    return false
  end
  if am and bm and (am.sec ~= bm.sec or am.nsec ~= bm.nsec) then
    return false
  end
  local ac, bc = a.ctime, b.ctime
  if (ac == nil) ~= (bc == nil) then
    return false
  end
  if ac and bc and (ac.sec ~= bc.sec or ac.nsec ~= bc.nsec) then
    return false
  end
  return true
end

---Read a regular non-symlink file, verifying the opened fd matches `fs_lstat`
---before and after reading.
---@param path string
---@return string|nil data, string|nil err, table|nil stat
local function read_regular_file(path)
  local name = vim.fs.basename(path)
  local lstat = vim.uv.fs_lstat(path)
  if not lstat then
    return nil, name .. " does not exist"
  end
  if lstat.type == "link" then
    return nil, name .. " is a symlink — refusing to modify"
  end
  if lstat.type ~= "file" then
    return nil, name .. " is not a regular file"
  end
  if lstat.dev == nil or lstat.ino == nil then
    return nil, "could not establish ownership of " .. name
  end
  local fd, open_err = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil, "could not open " .. name .. (open_err and (": " .. open_err) or "")
  end
  local fstat = vim.uv.fs_fstat(fd)
  if not stat_matches(fstat, lstat) then
    vim.uv.fs_close(fd)
    return nil, name .. " changed or became a symlink while reading"
  end
  local data, read_err = read_fd_all(fd, path)
  local post_fstat = vim.uv.fs_fstat(fd)
  vim.uv.fs_close(fd)
  if not data then
    return nil, read_err
  end
  if not stat_matches(post_fstat, fstat) then
    return nil, name .. " changed while reading"
  end
  return data, nil, post_fstat
end

---All loaded buffers whose real path is `path`.
---@param path string
---@return integer[]
local function loaded_buffers(path)
  local target = vim.fs.normalize(vim.uv.fs_realpath(path) or path)
  local matches = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.api.nvim_buf_is_loaded(buf) then
      local candidate = vim.fs.normalize(vim.uv.fs_realpath(name) or name)
      if candidate == target then
        matches[#matches + 1] = buf
      end
    end
  end
  return matches
end

local function relpath(root, path)
  local rel = vim.fs.relpath(root, path)
  if not rel or rel == "" then
    return path
  end
  return rel
end

-- ---------- availability and target resolution ----------

---Can dependency management run for this buffer?
---@param bufnr integer|nil
---@return boolean available
---@return string|nil reason
function M.available(bufnr)
  if require("java_menu.project").root(bufnr) ~= nil then
    return true
  end
  return false, NO_PROJECT_REASON
end

-- Compatibility for existing callers of the former internal helper.
M._available = M.available

---Resolve everything the menus/report need for the buffer.
---@param bufnr integer|nil
---@param module_dir string|nil explicit module (multi-module menu)
---@return table|nil target { root, tool, modules, module, build_file, is_kotlin_dsl, catalog_file }
function M._resolve_target(bufnr, module_dir)
  local project = require("java_menu.project")
  local root = project.root(bufnr)
  if not root then
    return nil
  end
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)

  local tool = vim.fn.filereadable(root .. "/pom.xml") == 1 and "maven" or "gradle"

  local modules = {}
  for _, mod in ipairs(project.modules(root)) do
    modules[#modules + 1] = vim.fs.normalize(vim.uv.fs_realpath(mod) or mod)
  end

  local start = project.start_path(bufnr)
  start = vim.fs.normalize(vim.uv.fs_realpath(start) or start)
  local module = root
  if module_dir then
    local wanted = vim.fs.normalize(vim.uv.fs_realpath(module_dir) or module_dir)
    for _, mod in ipairs(modules) do
      if mod == wanted then
        module = mod
        break
      end
    end
  else
    local best = -1
    for _, mod in ipairs(modules) do
      local inside = start == mod or start:sub(1, #mod + 1) == mod .. "/"
      if inside and #mod > best then
        best = #mod
        module = mod
      end
    end
  end

  local build_file
  local is_kotlin_dsl = false
  local ambiguous_build_files = false
  local missing_module_build_file = false
  if tool == "maven" then
    build_file = module .. "/pom.xml"
  else
    local mod_groovy = vim.uv.fs_lstat(module .. "/build.gradle") ~= nil
    local mod_kts = vim.uv.fs_lstat(module .. "/build.gradle.kts") ~= nil
    if mod_groovy and mod_kts then
      ambiguous_build_files = true
    end
    if vim.fn.filereadable(module .. "/build.gradle") == 1 then
      build_file = module .. "/build.gradle"
    elseif vim.fn.filereadable(module .. "/build.gradle.kts") == 1 then
      build_file = module .. "/build.gradle.kts"
      is_kotlin_dsl = true
    else
      if module ~= root and not mod_groovy and not mod_kts then
        missing_module_build_file = true
      end
      local root_groovy = vim.uv.fs_lstat(root .. "/build.gradle") ~= nil
      local root_kts = vim.uv.fs_lstat(root .. "/build.gradle.kts") ~= nil
      if root_groovy and root_kts and not mod_groovy and not mod_kts then
        ambiguous_build_files = true
      end
      if vim.fn.filereadable(root .. "/build.gradle") == 1 then
        build_file = root .. "/build.gradle"
      elseif vim.fn.filereadable(root .. "/build.gradle.kts") == 1 then
        build_file = root .. "/build.gradle.kts"
        is_kotlin_dsl = true
      else
        build_file = module .. "/build.gradle"
      end
    end
  end

  local catalog_file
  if vim.fn.filereadable(root .. "/gradle/libs.versions.toml") == 1 then
    catalog_file = root .. "/gradle/libs.versions.toml"
  end

  return {
    root = root,
    tool = tool,
    modules = modules,
    module = module,
    build_file = build_file,
    is_kotlin_dsl = is_kotlin_dsl,
    ambiguous_build_files = ambiguous_build_files,
    missing_module_build_file = missing_module_build_file,
    catalog_file = catalog_file,
  }
end

-- ---------- comment-safe masking ----------

---Shadow copy of `text` with XML comments replaced by spaces. The result has
---exactly the same byte length (newlines preserved), so offsets are shared
---with the original text.
---@param text string
---@return string
function M._mask_xml(text)
  text = text or ""
  local masked = text:gsub("<!%-%-.-%-%->", function(block)
    return (block:gsub("[^\n]", " "))
  end)
  -- unterminated comment: mask up to the end (never invent a closing marker)
  local open = masked:find("<!--", 1, true)
  if open then
    masked = masked:sub(1, open - 1) .. masked:sub(open):gsub("[^\n]", " ")
  end
  return masked
end

---Find the next `<tag ...>...</tag>` (or self-closing `<tag .../>`) element in
---comment-masked XML.
---@param text string
---@param tag string
---@param init integer|nil
---@return integer|nil elem_start
---@return integer|nil elem_end
---@return integer|nil body_start
---@return integer|nil body_end
local function find_element(text, tag, init)
  local open_s, open_e = text:find("<" .. tag .. "[%s>/]", init or 1)
  if not open_s then
    return nil
  end
  local tag_end
  if text:sub(open_e, open_e) == ">" then
    tag_end = open_e
  else
    tag_end = text:find(">", open_e, true)
    if not tag_end then
      return open_s, #text, nil, nil
    end
  end
  if text:sub(tag_end - 1, tag_end) == "/>" then
    return open_s, tag_end, nil, nil
  end
  local close_s, close_e = text:find("</" .. tag .. "%s*>", tag_end + 1)
  if not close_s then
    return open_s, #text, tag_end + 1, #text
  end
  return open_s, close_e, tag_end + 1, close_s - 1
end

---Mask whole `<tag ...>...</tag>` sections with equal-length spaces.
---@param text string
---@param tags string[]
---@return string
local function mask_blocks(text, tags)
  local out = text
  for _, tag in ipairs(tags) do
    local init = 1
    while true do
      local open_s, stop = find_element(out, tag, init)
      if not open_s or not stop then
        break
      end
      out = out:sub(1, open_s - 1) .. out:sub(open_s, stop):gsub("[^\n]", " ") .. out:sub(stop + 1)
      if stop >= #out then
        break
      end
      init = stop + 1
    end
  end
  return out
end

---Shadow copy that also masks dependencyManagement/build/reporting/profiles.
---Only the project-level `<dependencies>` and `</project>` stay visible, so a
---match can never hit a comment, plugin, profile or dependencyManagement.
---@param text string
---@return string
function M._mask_non_project_deps(text)
  return mask_blocks(M._mask_xml(text), { "dependencyManagement", "build", "reporting", "profiles" })
end

-- ---------- POM reading (pure) ----------

---Fields of one `<dependency>` (or `<parent>`) block (comments already masked).
---@param block string
---@return table
local function dependency_fields(block)
  local clean = mask_blocks(block, { "exclusions" })
  local function field(tag)
    local value = clean:match("<" .. tag .. "%s*>([^<]*)</" .. tag .. "%s*>")
    value = value and trim(value) or nil
    if value == "" then
      return nil
    end
    return value
  end
  return {
    groupId = field("groupId"),
    artifactId = field("artifactId"),
    version = field("version"),
    scope = field("scope"),
    type = field("type"),
    classifier = field("classifier"),
    optional = field("optional"),
  }
end

---Collect `<dependency>` entries between two byte offsets of `text`.
---@param text string POM or POM slice
---@param from_pos integer
---@param to_pos integer
---@return table[]
local function collect_dependencies(text, from_pos, to_pos)
  local slice = text:sub(from_pos, to_pos)
  local masked = M._mask_xml(slice)
  local out = {}
  local init = 1
  while true do
    local _, elem_end, body_s, body_e = find_element(masked, "dependency", init)
    if not elem_end then
      break
    end
    if body_s and body_e and body_e >= body_s then
      local fields = dependency_fields(masked:sub(body_s, body_e))
      if fields.groupId and fields.artifactId then
        out[#out + 1] = fields
      end
    end
    init = elem_end + 1
  end
  return out
end

---Collect `<dependencyManagement>` entries and BOM imports from a masked slice.
---@param masked_slice string
---@return table[] managed, table[] bom_imports, boolean has_bom
local function collect_managed_entries(masked_slice)
  local managed = {}
  local bom_imports = {}
  local init = 1
  while true do
    local _, dm_end, dm_body_s, dm_body_e = find_element(masked_slice, "dependencyManagement", init)
    if not dm_end then
      break
    end
    if dm_body_s and dm_body_e and dm_body_e >= dm_body_s then
      local dm_slice = masked_slice:sub(dm_body_s, dm_body_e)
      local dep_init = 1
      while true do
        local _, deps_end, deps_body_s, deps_body_e = find_element(dm_slice, "dependencies", dep_init)
        if not deps_end then
          break
        end
        if deps_body_s and deps_body_e and deps_body_e >= deps_body_s then
          for _, entry in ipairs(collect_dependencies(dm_slice, deps_body_s, deps_body_e)) do
            local item = {
              groupId = entry.groupId,
              artifactId = entry.artifactId,
              version = entry.version,
              type = entry.type,
              classifier = entry.classifier,
              scope = entry.scope,
            }
            managed[#managed + 1] = item
            if item.type == "pom" and item.scope == "import" then
              bom_imports[#bom_imports + 1] = item
            end
          end
        end
        dep_init = deps_end + 1
      end
    end
    init = dm_end + 1
  end
  return managed, bom_imports, #bom_imports > 0
end

---Collect direct `<dependencies>` entries from a masked slice (caller must
---already have masked `<dependencyManagement>`, `<build>`, `<reporting>`).
---@param masked_slice string
---@return table[]
local function collect_direct_dependencies(masked_slice)
  local deps = {}
  local init = 1
  while true do
    local _, deps_end, body_s, body_e = find_element(masked_slice, "dependencies", init)
    if not deps_end then
      break
    end
    if body_s and body_e and body_e >= body_s then
      for _, entry in ipairs(collect_dependencies(masked_slice, body_s, body_e)) do
        deps[#deps + 1] = entry
      end
    end
    init = deps_end + 1
  end
  return deps
end

---Extract `<parent>` coordinates from top-level masked POM.
---@param masked_top string
---@return table|nil
local function parse_parent(masked_top)
  local _, p_end, body_s, body_e = find_element(masked_top, "parent", 1)
  if not p_end then
    return nil
  end
  if not body_s or not body_e or body_e < body_s then
    return {}
  end
  local body = masked_top:sub(body_s, body_e)
  local fields = dependency_fields(body)
  local rel_path = body:match("<relativePath%s*>([^<]*)</relativePath%s*>")
  rel_path = rel_path and trim(rel_path) or nil
  if rel_path == "" then
    rel_path = nil
  end
  return {
    groupId = fields.groupId,
    artifactId = fields.artifactId,
    version = fields.version,
    relativePath = rel_path,
  }
end

---Extract declared `<activation>` metadata without evaluating conditions.
---@param activation_slice string
---@return table
local function parse_activation(activation_slice)
  local active_raw = activation_slice:match("<activeByDefault%s*>([^<]*)</activeByDefault%s*>")
  local active_by_default
  if active_raw then
    local val = trim(active_raw):lower()
    if val == "true" then
      active_by_default = true
    elseif val == "false" then
      active_by_default = false
    end
  end
  local triggers = {}
  for _, tag in ipairs({ "jdk", "os", "property", "file" }) do
    if find_element(activation_slice, tag, 1) then
      triggers[#triggers + 1] = tag
    end
  end
  return {
    active_by_default = active_by_default,
    triggers = triggers,
  }
end

---Extract `<profiles>` declarations from POM with comments/build/reporting masked.
---@param no_build string
---@return boolean has_profiles, table[] profiles
local function parse_profiles(no_build)
  local has_profiles = false
  local profiles = {}
  local outer_init = 1
  while true do
    local _, outer_end, outer_s, outer_e = find_element(no_build, "profiles", outer_init)
    if not outer_end then
      break
    end
    has_profiles = true
    if outer_s and outer_e and outer_e >= outer_s then
      local profiles_slice = no_build:sub(outer_s, outer_e)
      local prof_init = 1
      while true do
        local _, prof_end, body_s, body_e = find_element(profiles_slice, "profile", prof_init)
        if not prof_end then
          break
        end
        if body_s and body_e and body_e >= body_s then
          local p_slice = profiles_slice:sub(body_s, body_e)
          local id_slice = mask_blocks(p_slice, {
            "activation",
            "properties",
            "dependencies",
            "dependencyManagement",
            "repositories",
            "pluginRepositories",
            "distributionManagement",
            "modules",
          })
          local id = id_slice:match("<id%s*>([^<]*)</id%s*>")
          id = id and trim(id) or nil
          if id == "" then
            id = nil
          end

          local activation
          local _, act_end, act_s, act_e = find_element(p_slice, "activation", 1)
          if act_end then
            activation = (act_s and act_e and act_e >= act_s) and parse_activation(p_slice:sub(act_s, act_e))
              or { triggers = {} }
          end

          local managed, bom_imports, has_bom = collect_managed_entries(p_slice)
          local p_no_dm = mask_blocks(p_slice, { "dependencyManagement" })
          local deps = collect_direct_dependencies(p_no_dm)

          profiles[#profiles + 1] = {
            id = id,
            activation = activation,
            deps = deps,
            managed = managed,
            bom_imports = bom_imports,
            has_bom = has_bom,
          }
        else
          profiles[#profiles + 1] = {
            id = nil,
            activation = nil,
            deps = {},
            managed = {},
            bom_imports = {},
            has_bom = false,
          }
        end
        prof_init = prof_end + 1
      end
    end
    outer_init = outer_end + 1
  end
  return has_profiles, profiles
end

---Parse the parts of a POM that matter for dependency inspection and insertion. Pure.
---@param text string
---@return table
function M._parse_pom(text)
  text = text or ""
  local masked = M._mask_xml(text)
  local no_build = mask_blocks(masked, { "build", "reporting" })
  local no_profiles = mask_blocks(no_build, { "profiles" })
  local no_project = mask_blocks(no_profiles, { "dependencyManagement" })
  local masked_top = mask_blocks(no_project, { "dependencies" })

  local deps = collect_direct_dependencies(no_project)
  local managed, bom_imports, has_bom = collect_managed_entries(no_profiles)
  local parent = parse_parent(masked_top)
  local has_profiles, profiles = parse_profiles(no_build)

  return {
    deps = deps,
    managed = managed,
    bom_imports = bom_imports,
    parent = parent,
    has_parent = parent ~= nil,
    has_bom = has_bom,
    has_profiles = has_profiles,
    profiles = profiles,
  }
end

---@param value string|nil
---@return string
local function normalized_type(value)
  if value == nil or value == "" then
    return "jar"
  end
  return value
end

---@param value string|nil
---@return string
local function normalized_classifier(value)
  if value == nil then
    return ""
  end
  return value
end

---@param entry table
---@param groupId string
---@param artifactId string
---@param dep_type string|nil
---@param classifier string|nil
---@return boolean
local function managed_entry_matches(entry, groupId, artifactId, dep_type, classifier)
  return entry.groupId == groupId
    and entry.artifactId == artifactId
    and normalized_type(entry.type) == normalized_type(dep_type)
    and normalized_classifier(entry.classifier) == normalized_classifier(classifier)
end

---First exact (non-BOM-import) entry in a dependencyManagement list matching G:A:type:classifier.
---@param managed_list table[]|nil
---@param groupId string
---@param artifactId string
---@param dep_type string|nil
---@param classifier string|nil
---@return table|nil
local function find_exact_managed_entry(managed_list, groupId, artifactId, dep_type, classifier)
  for _, entry in ipairs(managed_list or {}) do
    if managed_entry_matches(entry, groupId, artifactId, dep_type, classifier) then
      local bom_import = entry.type == "pom" and entry.scope == "import"
      if not bom_import then
        return entry
      end
    end
  end
  return nil
end

---Is groupId:artifactId[:type[:classifier]] literally declared with a version
---in project dependencyManagement (a BOM import itself does not count)? This is
---the only textual proof that the artifact's version is managed.
---@param parsed table|nil result of _parse_pom
---@param groupId string
---@param artifactId string
---@param dep_type string|nil
---@param classifier string|nil
---@return boolean
function M._is_exact_managed(parsed, groupId, artifactId, dep_type, classifier)
  local entry = find_exact_managed_entry(parsed and parsed.managed, groupId, artifactId, dep_type, classifier)
  return entry ~= nil and entry.version ~= nil and entry.version ~= ""
end

---@param parsed table
---@param groupId string
---@param artifactId string
---@param dep_type string|nil
---@param classifier string|nil
---@return table
local function build_bom_info(parsed, groupId, artifactId, dep_type, classifier)
  local has_profile_bom = false
  local has_profile_dm = false
  for _, prof in ipairs((parsed and parsed.profiles) or {}) do
    if prof.has_bom then
      has_profile_bom = true
    end
    local entry = find_exact_managed_entry(prof.managed, groupId, artifactId, dep_type, classifier)
    if entry and entry.version and entry.version ~= "" then
      has_profile_dm = true
    end
  end
  return {
    exact_managed = M._is_exact_managed(parsed, groupId, artifactId, dep_type, classifier),
    has_parent = parsed.has_parent,
    has_bom = parsed.has_bom,
    has_profile_bom = has_profile_bom,
    has_profile_dm = has_profile_dm,
  }
end

---Literal groupId:artifactId duplicate among the project dependencies.
---@param parsed table|nil result of _parse_pom
---@param groupId string
---@param artifactId string
---@return table|nil
function M._find_duplicate(parsed, groupId, artifactId)
  for _, entry in ipairs((parsed and parsed.deps) or {}) do
    if entry.groupId == groupId and entry.artifactId == artifactId then
      return entry
    end
  end
  return nil
end

-- ---------- dependency validation ----------

---@param value any
---@return boolean invalid
local function invalid_xml_value(value)
  if type(value) ~= "string" or value == "" then
    return true
  end
  return value:find("[<>\"'&%s]") ~= nil
end

---Validate a dependency before insertion.
---@param dep table { groupId, artifactId, version?, scope?, type?, classifier? }
---@param bom_info { exact_managed: boolean, has_parent: boolean, has_bom: boolean, has_profile_bom?: boolean, has_profile_dm?: boolean }|nil
---@return boolean|nil ok, string|nil err
function M._validate_dep(dep, bom_info)
  if type(dep) ~= "table" then
    return nil, "dependency must be a table"
  end
  if invalid_xml_value(dep.groupId) then
    return nil, "invalid groupId: " .. tostring(dep.groupId)
  end
  if invalid_xml_value(dep.artifactId) then
    return nil, "invalid artifactId: " .. tostring(dep.artifactId)
  end

  local version = dep.version
  if version ~= nil and version ~= "" then
    if invalid_xml_value(version) then
      return nil, "invalid version: " .. tostring(version)
    end
  elseif not (bom_info and (bom_info.exact_managed or bom_info.has_bom or bom_info.has_parent)) then
    if bom_info and (bom_info.has_profile_bom or bom_info.has_profile_dm) then
      return nil,
        ("a <version> is required: no unconditional <parent>, project dependencyManagement entry or project BOM import for %s:%s was found in pom.xml (profile declarations are conditional)"):format(
          dep.groupId,
          dep.artifactId
        )
    end
    return nil,
      ("a <version> is required: no <parent>, dependencyManagement entry or BOM import for %s:%s was found in pom.xml"):format(
        dep.groupId,
        dep.artifactId
      )
  end

  local dep_type = dep.type
  if dep_type ~= nil and dep_type ~= "" and invalid_xml_value(dep_type) then
    return nil, "invalid type: " .. tostring(dep_type)
  end

  local classifier = dep.classifier
  if classifier ~= nil and classifier ~= "" and invalid_xml_value(classifier) then
    return nil, "invalid classifier: " .. tostring(classifier)
  end

  local scope = dep.scope
  if scope ~= nil and scope ~= "" and not VALID_SCOPES[scope] then
    return nil, "invalid scope: " .. tostring(scope) .. " (expected compile, provided, runtime, test, system or import)"
  end
  return true, nil
end

-- ---------- indentation and insertion ----------

---Detect the file's indentation from what already exists.
---@param text string
---@return string unit one indentation level ("  ", "    " or "\t")
---@return string section indent of a child element of <project>
---@return string dep indent of an existing <dependency> sibling
function M._detect_indent(text)
  local masked = M._mask_non_project_deps(text)

  -- Collect lines after the first where leading whitespace before `<` matches
  -- the unmasked text, so a leading `<!-- comment -->` masked to spaces never
  -- masquerades as indentation.
  local lines = {}
  local pos = masked:find("\n", 1, true)
  while pos do
    local line_start = pos + 1
    local next_nl = masked:find("\n", line_start, true)
    local line_end = next_nl and (next_nl - 1) or #masked
    local mline = masked:sub(line_start, line_end)
    local m_lead = mline:match("^([ \t]*)<")
    if m_lead and m_lead == text:sub(line_start, line_end):match("^([ \t]*)<") then
      lines[#lines + 1] = mline
    end
    pos = next_nl
  end

  local unit
  if masked:find("\n\t") then
    unit = "\t"
  else
    local min_spaces
    for _, line in ipairs(lines) do
      local spaces = line:match("^( +)<")
      if spaces and (min_spaces == nil or #spaces < min_spaces) then
        min_spaces = #spaces
      end
    end
    unit = min_spaces and string.rep(" ", min_spaces) or "  "
  end

  local section
  for _, line in ipairs(lines) do
    local indent = line:match("^(%s*)<modelVersion[%s>]")
      or line:match("^(%s*)<properties[%s>/]")
      or line:match("^(%s*)<properties$")
      or line:match("^(%s*)<dependencies[%s>/]")
      or line:match("^(%s*)<dependencies$")
    if indent and indent ~= "" then
      section = indent
      break
    end
  end
  section = section or unit

  local dep
  for _, line in ipairs(lines) do
    local indent = line:match("^(%s*)<dependency[%s>]")
    if indent then
      dep = indent
      break
    end
  end
  dep = dep or (section .. unit)

  return unit, section, dep
end

---@param text string
---@param pos integer
---@return integer line_start, string lead
local function line_lead(text, pos)
  local prefix = text:sub(1, pos - 1)
  local nl = prefix:match(".*()\n")
  local line_start = (nl and nl + 1) or 1
  return line_start, text:sub(line_start, pos - 1)
end

---Insert `block` (already indented, no trailing newline) before the line that
---contains byte `pos` of `text`. Every other byte is preserved.
---@param text string
---@param pos integer byte offset inside `text`
---@param block string
---@param eol string
---@param close_indent string indent used when the target tag is inline
---@return string
local function insert_before_line(text, pos, block, eol, close_indent)
  local line_start, lead = line_lead(text, pos)
  if lead:match("^[ \t]*$") then
    return text:sub(1, line_start - 1) .. block .. eol .. text:sub(line_start)
  end
  -- closing tag shares its line with content: give the block its own line
  return text:sub(1, pos - 1) .. eol .. block .. eol .. close_indent .. text:sub(pos)
end

---@param dep table
---@param entry_indent string
---@param unit string
---@param eol string
---@return string
local function build_dependency_block(dep, entry_indent, unit, eol)
  local version_omitted = dep.version == nil or dep.version == ""
  local dep_type = dep.type ~= "" and dep.type or nil
  local classifier = dep.classifier ~= "" and dep.classifier or nil
  local scope = dep.scope ~= "" and dep.scope or nil

  local inner = entry_indent .. unit
  local element = {
    entry_indent .. "<dependency>",
    inner .. "<groupId>" .. dep.groupId .. "</groupId>",
    inner .. "<artifactId>" .. dep.artifactId .. "</artifactId>",
  }
  if not version_omitted then
    element[#element + 1] = inner .. "<version>" .. dep.version .. "</version>"
  end
  if dep_type and dep_type ~= "jar" then
    element[#element + 1] = inner .. "<type>" .. dep_type .. "</type>"
  end
  if classifier then
    element[#element + 1] = inner .. "<classifier>" .. classifier .. "</classifier>"
  end
  if scope and scope ~= "compile" then
    element[#element + 1] = inner .. "<scope>" .. scope .. "</scope>"
  end
  element[#element + 1] = entry_indent .. "</dependency>"
  return table.concat(element, eol)
end

---Expand a self-closing project-level `<dependencies/>` tag around one new
---dependency entry, preserving every byte outside `[open_s, elem_end]`.
---@param text string
---@param open_s integer
---@param elem_end integer
---@param dep table
---@param unit string
---@param section string
---@param sibling string
---@param eol string
---@return string
local function expand_self_closing_dependencies(text, open_s, elem_end, dep, unit, section, sibling, eol)
  local _, lead = line_lead(text, open_s)
  local close_indent, entry_indent
  if lead:match("^[ \t]*$") then
    close_indent = lead
    entry_indent = lead .. unit
  else
    local line_indent = lead:match("^([ \t]+)")
    close_indent = line_indent or section
    entry_indent = line_indent and (line_indent .. unit) or sibling
  end
  local block = build_dependency_block(dep, entry_indent, unit, eol)
  local open_tag = text:sub(open_s, elem_end):gsub("%s*/>$", ">")
  local expanded = open_tag .. eol .. block .. eol .. close_indent .. "</dependencies>"
  return text:sub(1, open_s - 1) .. expanded .. text:sub(elem_end + 1)
end

---Insert one dependency into a POM text, preserving bytes and comments.
---@param text string
---@param dep table { groupId, artifactId, version?, scope?, type?, classifier? }
---@return string|nil new_text, table|nil meta, string|nil err
function M._insert_maven_dependency(text, dep)
  local parsed = M._parse_pom(text)
  local bom_info = build_bom_info(parsed, dep.groupId, dep.artifactId, dep.type, dep.classifier)

  local ok, err = M._validate_dep(dep, bom_info)
  if not ok then
    return nil, nil, err
  end

  if M._find_duplicate(parsed, dep.groupId, dep.artifactId) then
    return nil, nil, ("%s:%s is already declared in pom.xml"):format(dep.groupId, dep.artifactId)
  end

  local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
  local unit, section, sibling = M._detect_indent(text)

  local version_omitted = dep.version == nil or dep.version == ""

  local meta = { created_section = false, version_omitted = version_omitted, bom_note = nil }
  if version_omitted and not bom_info.exact_managed then
    if bom_info.has_bom then
      meta.bom_note =
        "a BOM import was detected in dependencyManagement, but textual inspection cannot prove it manages this artifact"
    elseif bom_info.has_parent then
      meta.bom_note =
        "<version> omitted: inherited from <parent>, but textual inspection cannot prove the parent manages this artifact"
    end
  end

  local masked = M._mask_non_project_deps(text)
  local new_text
  local open_s, elem_end, body_s, body_e = find_element(masked, "dependencies", 1)
  if open_s then
    if body_s == nil then
      if masked:sub(elem_end - 1, elem_end) ~= "/>" then
        return nil, nil, "could not find the closing </dependencies> of the project dependencies in pom.xml"
      end
      new_text = expand_self_closing_dependencies(text, open_s, elem_end, dep, unit, section, sibling, eol)
    else
      local close_s = body_e + 1
      if close_s > #masked then
        return nil, nil, "could not find the closing </dependencies> of the project dependencies in pom.xml"
      end
      local block = build_dependency_block(dep, sibling, unit, eol)
      new_text = insert_before_line(text, close_s, block, eol, section)
    end
  else
    local project_close = masked:find("</project>", 1, true)
    if not project_close then
      return nil, nil, "could not find </project> in pom.xml"
    end
    local block = build_dependency_block(dep, sibling, unit, eol)
    local new_section = table.concat({
      section .. "<dependencies>",
      block,
      section .. "</dependencies>",
    }, eol)
    new_text = insert_before_line(text, project_close, new_section, eol, section)
    meta.created_section = true
  end

  return new_text, meta, nil
end

---Write a build file by temp-file + rename, refusing symlinks, unsaved buffer
---changes, and concurrent/stale disk modifications while preserving file mode.
---Note: Neovim's `vim.uv` exposes path-based `fs_rename`/`fs_open`/`fs_unlink`
---without `O_NOFOLLOW`, `openat`/`unlinkat`, or `renameat2`, so a narrow TOCTOU
---window remains between the final pre-rename checks and `fs_rename` against an
---uncooperative external writer.
---@param build_path string
---@param new_text string
---@param opts { expected_text?: string }|nil
---@return boolean|nil ok, string|nil err
function M._write_build_file(build_path, new_text, opts)
  if type(build_path) ~= "string" or build_path == "" or type(new_text) ~= "string" then
    return nil, "build file path and content are required"
  end
  opts = opts or {}
  local expected_text = opts.expected_text
  if expected_text ~= nil and type(expected_text) ~= "string" then
    return nil, "expected_text must be a string"
  end

  local name = vim.fs.basename(build_path)
  local current_bytes, read_err, orig_fstat = read_regular_file(build_path)
  if not current_bytes or not orig_fstat or type(orig_fstat.mode) ~= "number" then
    return nil, read_err or ("could not verify " .. name)
  end
  if expected_text ~= nil and current_bytes ~= expected_text then
    return nil, name .. " changed on disk since it was read — aborting write without overwriting"
  end

  for _, buf in ipairs(loaded_buffers(build_path)) do
    if vim.bo[buf].modified then
      return nil, name .. " has unsaved changes — save or discard them first"
    end
  end

  local orig_perm = orig_fstat.mode % 512
  local dir = vim.fs.dirname(build_path)
  local prefix = name:sub(1, 64)
  local tmp_fd, tmp_path, mk_err = vim.uv.fs_mkstemp(dir .. "/." .. prefix .. ".java-menu-XXXXXX")
  if not tmp_fd or not tmp_path then
    return nil, "could not create a temporary file next to " .. build_path .. (mk_err and (": " .. mk_err) or "")
  end

  local tmp_stat = vim.uv.fs_fstat(tmp_fd)
  if not tmp_stat or tmp_stat.type ~= "file" or tmp_stat.dev == nil or tmp_stat.ino == nil then
    -- Fail closed: ownership cannot be established, so never unlink `tmp_path`.
    pcall(vim.uv.fs_close, tmp_fd)
    return nil, "could not establish ownership of temporary file for " .. name
  end

  local function verify_tmp_owned()
    local st = tmp_path and vim.uv.fs_lstat(tmp_path) or nil
    if not st then
      return false, "temporary file for " .. name .. " disappeared"
    end
    if st.type == "link" then
      return false, "temporary file for " .. name .. " became a symlink — aborting"
    end
    if st.type ~= "file" then
      return false, "temporary path for " .. name .. " is not a regular file — aborting"
    end
    if st.dev ~= tmp_stat.dev or st.ino ~= tmp_stat.ino then
      return false, "temporary file for " .. name .. " was replaced — aborting"
    end
    return true, nil
  end

  local function cleanup_tmp()
    -- Recheck lstat against recorded dev/ino while `tmp_fd` is still open so we
    -- never unlink a symlink or foreign file that replaced `tmp_path`.
    if tmp_path then
      local ok_owned, owned = pcall(verify_tmp_owned)
      if ok_owned and owned then
        pcall(vim.uv.fs_unlink, tmp_path)
      end
      tmp_path = nil
    end
    if tmp_fd then
      pcall(vim.uv.fs_close, tmp_fd)
      tmp_fd = nil
    end
  end

  local initial_tmp_ok, initial_tmp_err = verify_tmp_owned()
  if not initial_tmp_ok then
    cleanup_tmp()
    return nil, initial_tmp_err
  end

  local offset = 0
  local total = #new_text
  while offset < total do
    local chunk = offset == 0 and new_text or new_text:sub(offset + 1)
    local written, write_err = vim.uv.fs_write(tmp_fd, chunk, offset)
    if not written or written <= 0 then
      cleanup_tmp()
      return nil, "could not write the build file content" .. (write_err and (": " .. write_err) or "")
    end
    offset = offset + written
  end

  local chmod_ok, chmod_err = vim.uv.fs_fchmod(tmp_fd, orig_perm)
  if not chmod_ok then
    cleanup_tmp()
    return nil, "could not preserve permissions on " .. name .. (chmod_err and (": " .. chmod_err) or "")
  end

  local sync_ok, sync_err = vim.uv.fs_fsync(tmp_fd)
  if not sync_ok and sync_err and not sync_err:find("EINVAL", 1, true) then
    cleanup_tmp()
    return nil, "could not flush temporary file for " .. name .. ": " .. sync_err
  end

  for _, buf in ipairs(loaded_buffers(build_path)) do
    if vim.bo[buf].modified then
      cleanup_tmp()
      return nil, name .. " has unsaved changes — save or discard them first"
    end
  end

  local pre_bytes, pre_err, pre_fstat = read_regular_file(build_path)
  if not pre_bytes or not pre_fstat then
    cleanup_tmp()
    return nil, pre_err or (name .. " changed or disappeared before replace — aborting")
  end
  if
    not stat_matches(pre_fstat, orig_fstat)
    or pre_bytes ~= current_bytes
    or (expected_text ~= nil and pre_bytes ~= expected_text)
  then
    cleanup_tmp()
    return nil, name .. " changed concurrently on disk — aborting write without overwriting"
  end

  local tmp_ok, tmp_err = verify_tmp_owned()
  if not tmp_ok then
    cleanup_tmp()
    return nil, tmp_err
  end
  local tmp_fstat_now = vim.uv.fs_fstat(tmp_fd)
  if
    not tmp_fstat_now
    or tmp_fstat_now.type ~= "file"
    or tmp_fstat_now.dev ~= tmp_stat.dev
    or tmp_fstat_now.ino ~= tmp_stat.ino
    or tmp_fstat_now.size ~= total
    or type(tmp_fstat_now.mode) ~= "number"
    or (tmp_fstat_now.mode % 512) ~= orig_perm
  then
    cleanup_tmp()
    return nil, "temporary file state changed before replace for " .. name
  end

  -- Keep `tmp_fd` open through `fs_rename` so the temp inode cannot be recycled
  -- before rename or before `cleanup_tmp()` verifies ownership.
  local renamed, rename_err = vim.uv.fs_rename(tmp_path, build_path)
  if not renamed then
    cleanup_tmp()
    return nil, "could not replace " .. name .. (rename_err and (": " .. rename_err) or "")
  end

  pcall(vim.uv.fs_close, tmp_fd)
  tmp_fd = nil
  tmp_path = nil

  for _, buf in ipairs(loaded_buffers(build_path)) do
    if vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent edit!")
      end)
    end
  end
  return true, nil
end

M._write_pom = M._write_build_file

-- ---------- Maven Central (optional, async) ----------

---HTTP client available for the lookup.
---@param has_exe fun(exe: string): boolean|nil injected for tests
---@return string|nil "curl" | "wget" | nil
function M._http_tool(has_exe)
  has_exe = has_exe or function(exe)
    return vim.fn.exepath(exe) ~= ""
  end
  if has_exe("curl") then
    return "curl"
  end
  if has_exe("wget") then
    return "wget"
  end
  return nil
end

---@param str string
---@return string
local function url_encode(str)
  return (
    tostring(str):gsub("[^%w%-%._~]", function(char)
      if char == " " then
        return "+"
      end
      return ("%%%02X"):format(char:byte())
    end)
  )
end

---search.maven.org URL for a free-text query or for g/a coordinates.
---@param query string
---@param opts { gav: boolean|nil }|nil
---@return string
function M._maven_search_url(query, opts)
  opts = opts or {}
  local url = MAVEN_SEARCH_BASE .. url_encode(query)
  if opts.gav then
    url = url .. "&core=gav&rows=20"
  else
    url = url .. "&rows=15"
  end
  return url .. "&wt=json"
end

---Parse a solrsearch response into results.
---@param json_text string|nil
---@return table|nil results, string|nil err
function M._parse_maven_search(json_text)
  if type(json_text) ~= "string" or trim(json_text) == "" then
    return nil, "empty response from Maven Central"
  end
  local ok, decoded = pcall(vim.json.decode, json_text)
  if not ok or type(decoded) ~= "table" then
    return nil, "invalid response from Maven Central (not JSON)"
  end
  local response = decoded.response
  if type(response) ~= "table" or type(response.docs) ~= "table" then
    return nil, "unexpected response from Maven Central (missing response.docs)"
  end
  local results = {}
  for _, doc in ipairs(response.docs) do
    if type(doc) == "table" then
      local group = doc.g
      local artifact = doc.a
      if group and artifact then
        results[#results + 1] = {
          groupId = group,
          artifactId = artifact,
          version = doc.latestVersion or doc.v,
          packaging = doc.p,
        }
      end
    end
  end
  return results, nil
end

---@param url string
---@return string[]|nil
local function http_command(url)
  local tool = M._http_tool()
  if tool == "curl" then
    return { "curl", "-sS", "-f", "-L", "--max-time", "10", url }
  end
  if tool == "wget" then
    return { "wget", "-q", "-O", "-", "--timeout=10", url }
  end
  return nil
end

---@param res table
---@return string
local function command_error(res)
  local detail = trim((res.stderr or ""):gsub("%s+", " "))
  if detail == "" then
    detail = trim((res.stdout or ""):gsub("%s+", " "))
  end
  if #detail > 160 then
    detail = detail:sub(1, 160) .. "…"
  end
  return ("Maven Central request failed (exit %s)%s"):format(
    tostring(res.code),
    detail ~= "" and (": " .. detail) or ""
  )
end

---Search Maven Central asynchronously. `on_done` always runs on the main loop.
---@param query string
---@param on_done fun(results: table[]|nil, err: string|nil)
function M._search_maven(query, on_done)
  local url = M._maven_search_url(query)
  local cmd = http_command(url)
  if not cmd then
    vim.schedule(function()
      on_done(nil, "curl or wget is required for Maven Central search")
    end)
    return
  end
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        on_done(nil, command_error(res))
        return
      end
      on_done(M._parse_maven_search(res.stdout))
    end)
  end)
end

---Known versions for groupId:artifactId (`core=gav`).
---@param groupId string
---@param artifactId string
---@param on_done fun(results: table[]|nil, err: string|nil)
function M._fetch_versions(groupId, artifactId, on_done)
  local query = ("g:%s AND a:%s"):format(groupId, artifactId)
  local url = M._maven_search_url(query, { gav = true })
  local cmd = http_command(url)
  if not cmd then
    vim.schedule(function()
      on_done(nil, "curl or wget is required for Maven Central search")
    end)
    return
  end
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        on_done(nil, command_error(res))
        return
      end
      on_done(M._parse_maven_search(res.stdout))
    end)
  end)
end

-- ---------- Gradle (read-only MVP) ----------

---Remove a `#` comment from a TOML line, respecting quoted strings.
---@param line string
---@return string
local function strip_toml_comment(line)
  local out, i, quote = {}, 1, nil
  while i <= #line do
    local char = line:sub(i, i)
    if quote then
      if char == "\\" then
        out[#out + 1] = line:sub(i, i + 1)
        i = i + 2
      else
        if char == quote then
          quote = nil
        end
        out[#out + 1] = char
        i = i + 1
      end
    elseif char == '"' or char == "'" then
      quote = char
      out[#out + 1] = char
      i = i + 1
    elseif char == "#" then
      break
    else
      out[#out + 1] = char
      i = i + 1
    end
  end
  return trim(table.concat(out))
end

---Remove a `//` comment from a Groovy line, respecting quoted strings.
---@param line string
---@return string
local function strip_groovy_line_comment(line)
  local out, i, quote = {}, 1, nil
  while i <= #line do
    local char = line:sub(i, i)
    if quote then
      if char == "\\" then
        out[#out + 1] = line:sub(i, i + 1)
        i = i + 2
      else
        if char == quote then
          quote = nil
        end
        out[#out + 1] = char
        i = i + 1
      end
    elseif char == '"' or char == "'" then
      quote = char
      out[#out + 1] = char
      i = i + 1
    elseif char == "/" and line:sub(i + 1, i + 1) == "/" then
      break
    else
      out[#out + 1] = char
      i = i + 1
    end
  end
  return table.concat(out)
end

---@param coord string
---@return table|nil
local function split_coordinate(coord)
  if type(coord) ~= "string" or coord == "" or coord:find("%s") then
    return nil
  end
  local raw = coord:gsub("@[^:@]+$", "")
  local parts = vim.split(raw, ":", { plain = true })
  if #parts < 2 or #parts > 4 then
    return nil
  end
  local group, artifact, version = parts[1], parts[2], parts[3]
  if group == "" or artifact == "" then
    return nil
  end
  if version == "" then
    version = nil
  end
  return { groupId = group, artifactId = artifact, version = version }
end

---Parse a single-line TOML inline table `{ k = v, ... }` into typed entries.
---@param text string
---@return table<string, table>|nil
local function parse_toml_inline_table(text)
  local trimmed = trim(text)
  if trimmed:sub(1, 1) ~= "{" or trimmed:sub(-1, -1) ~= "}" then
    return nil
  end
  local inner = trimmed:sub(2, -2)
  local parts = {}
  local start_idx = 1
  local quote = nil
  local brace, bracket = 0, 0
  local i = 1
  local n = #inner
  while i <= n do
    local ch = inner:sub(i, i)
    if quote then
      if quote == '"' and ch == "\\" then
        i = i + 2
      else
        if ch == quote then
          quote = nil
        end
        i = i + 1
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
      i = i + 1
    elseif ch == "{" then
      brace = brace + 1
      i = i + 1
    elseif ch == "}" then
      brace = brace - 1
      if brace < 0 then
        return nil
      end
      i = i + 1
    elseif ch == "[" then
      bracket = bracket + 1
      i = i + 1
    elseif ch == "]" then
      bracket = bracket - 1
      if bracket < 0 then
        return nil
      end
      i = i + 1
    elseif ch == "," and brace == 0 and bracket == 0 then
      parts[#parts + 1] = trim(inner:sub(start_idx, i - 1))
      start_idx = i + 1
      i = i + 1
    else
      i = i + 1
    end
  end
  if quote or brace ~= 0 or bracket ~= 0 then
    return nil
  end
  local last_part = trim(inner:sub(start_idx))
  if #parts > 0 or last_part ~= "" then
    parts[#parts + 1] = last_part
  end

  local entries = {}
  for _, part in ipairs(parts) do
    if part == "" then
      return nil
    end
    local eq = part:find("=", 1, true)
    if not eq then
      return nil
    end
    local raw_key = trim(part:sub(1, eq - 1))
    local norm_key = raw_key:gsub("%s*%.%s*", ".")
    if norm_key == "" or not norm_key:match("^[%w_%-%.]+$") then
      return nil
    end
    local val_str = trim(part:sub(eq + 1))
    if val_str == "" then
      return nil
    end
    local first = val_str:sub(1, 1)
    if first == '"' then
      local j = 2
      local out = {}
      local closed = false
      while j <= #val_str do
        local c = val_str:sub(j, j)
        if c == "\\" then
          local nxt = val_str:sub(j + 1, j + 1)
          if nxt == "" then
            return nil
          end
          out[#out + 1] = nxt
          j = j + 2
        elseif c == '"' then
          closed = true
          j = j + 1
          break
        else
          out[#out + 1] = c
          j = j + 1
        end
      end
      if not closed or j <= #val_str then
        return nil
      end
      entries[norm_key] = { kind = "string", value = table.concat(out) }
    elseif first == "'" then
      local close_q = val_str:find("'", 2, true)
      if not close_q or close_q ~= #val_str then
        return nil
      end
      entries[norm_key] = { kind = "string", value = val_str:sub(2, -2) }
    elseif first == "{" then
      local sub = parse_toml_inline_table(val_str)
      if not sub then
        return nil
      end
      entries[norm_key] = { kind = "table", entries = sub }
    else
      entries[norm_key] = { kind = "other", raw = val_str }
    end
  end
  return entries
end

---Resolve a `[libraries]` inline table's version / version.* entries safely.
---@param lib table
---@param entries table<string, table>
---@param module_version string|nil
---@param versions table<string, string>
local function apply_catalog_version(lib, entries, module_version, versions)
  local version_keys = {}
  for k in pairs(entries) do
    if k == "version" or k:sub(1, 8) == "version." then
      version_keys[#version_keys + 1] = k
    end
  end

  if #version_keys == 0 then
    if module_version then
      lib.version = module_version
    end
    return
  end

  if #version_keys == 1 and entries["version"] then
    local v = entries["version"]
    if v.kind == "string" then
      if v.value ~= "" then
        lib.version = v.value
      else
        lib.note = "rich or empty version constraint not resolved"
      end
    elseif v.kind == "table" then
      local t = v.entries
      local count = 0
      for _ in pairs(t) do
        count = count + 1
      end
      if count == 1 and t.ref and t.ref.kind == "string" and t.ref.value ~= "" then
        local ref = t.ref.value
        if versions[ref] then
          lib.version = versions[ref]
        else
          lib.note = "unresolved version.ref: " .. ref
        end
      else
        lib.note = "rich version constraint not resolved"
      end
    else
      lib.note = "unsupported version in catalog"
    end
    return
  end

  if #version_keys == 1 and entries["version.ref"] then
    local v = entries["version.ref"]
    if v.kind == "string" and v.value ~= "" then
      local ref = v.value
      if versions[ref] then
        lib.version = versions[ref]
      else
        lib.note = "unresolved version.ref: " .. ref
      end
    else
      lib.note = "unsupported version.ref in catalog"
    end
    return
  end

  lib.note = "rich version constraint not resolved"
end

---Static parse of gradle/libs.versions.toml ([versions] and [libraries]).
---@param toml_text string
---@return { versions: table<string,string>, libraries: table[], by_alias: table<string,table>, notes: string[] }
function M._parse_version_catalog(toml_text)
  local versions, libraries, by_alias, notes = {}, {}, {}, {}
  local section

  for raw in (toml_text or ""):gmatch("[^\r\n]+") do
    local line = strip_toml_comment(raw)
    if line ~= "" then
      local header = line:match("^%[([^%]]+)%]$")
      if header then
        section = trim(header)
      elseif section == "versions" then
        local key, value = line:match('^([%w%._%-]+)%s*=%s*"(.-)"$')
        if not key then
          key, value = line:match("^([%w%._%-]+)%s*=%s*'(.-)'$")
        end
        if key then
          versions[key] = value
        elseif line:find("=", 1, true) then
          notes[#notes + 1] = "versions entry not understood: " .. line
        end
      elseif section == "libraries" then
        local alias, rest = line:match("^([%w%._%-]+)%s*=%s*(.+)$")
        if alias then
          local lib
          local coord = rest:match('^"(.-)"$') or rest:match("^'(.-)'$")
          if coord then
            lib = split_coordinate(coord)
            if lib then
              lib.alias = alias
            else
              lib = { alias = alias, note = "unsupported coordinate: " .. coord }
            end
          elseif rest:find("^%b{}") then
            local entries = parse_toml_inline_table(rest)
            if entries then
              local module = entries.module and entries.module.kind == "string" and entries.module.value or nil
              local group = entries.group and entries.group.kind == "string" and entries.group.value or nil
              local name = entries.name and entries.name.kind == "string" and entries.name.value or nil
              local group_id, artifact_id, module_version = group, name, nil
              if module then
                local parsed = split_coordinate(module)
                if parsed then
                  group_id, artifact_id, module_version = parsed.groupId, parsed.artifactId, parsed.version
                end
              end
              if group_id and artifact_id then
                lib = { alias = alias, groupId = group_id, artifactId = artifact_id }
                apply_catalog_version(lib, entries, module_version, versions)
              else
                lib = { alias = alias, note = "libraries entry not understood: " .. line }
              end
            else
              lib = { alias = alias, note = "libraries entry not understood: " .. line }
            end
          else
            lib = { alias = alias, note = "libraries entry not understood: " .. line }
          end
          libraries[#libraries + 1] = lib
          by_alias[alias] = lib
        end
      end
    end
  end

  local by_normalized = {}
  for alias in pairs(by_alias) do
    local norm = alias:gsub("[%-_%.]", ".")
    local list = by_normalized[norm]
    if not list then
      list = {}
      by_normalized[norm] = list
    end
    list[#list + 1] = alias
  end
  local ambiguous_norms = {}
  for norm, aliases in pairs(by_normalized) do
    if #aliases > 1 then
      table.sort(aliases)
      ambiguous_norms[#ambiguous_norms + 1] = { norm = norm, aliases = aliases }
    end
  end
  table.sort(ambiguous_norms, function(a, b)
    return a.norm < b.norm
  end)
  for _, item in ipairs(ambiguous_norms) do
    notes[#notes + 1] = ("ambiguous catalog accessor libs.%s (aliases: %s)"):format(
      item.norm,
      table.concat(item.aliases, ", ")
    )
  end

  return { versions = versions, libraries = libraries, by_alias = by_alias, notes = notes }
end

---Resolve a `libs.foo.bar` accessor against a parsed catalog.
---@param catalog table|nil
---@param accessor string
---@return table|nil lib
---@return string[]|nil ambiguous_aliases sorted list when multiple aliases share the Gradle normalized accessor
local function catalog_library(catalog, accessor)
  if not catalog or not catalog.by_alias then
    return nil, nil
  end
  local name = accessor:gsub("^libs%.", ""):gsub("^libs$", "")
  local normalized = name:gsub("[%-_%.]", ".")
  if normalized == "" then
    return nil, nil
  end
  local matches = {}
  for alias, lib in pairs(catalog.by_alias) do
    if alias:gsub("[%-_%.]", ".") == normalized then
      matches[#matches + 1] = { alias = alias, lib = lib }
    end
  end
  if #matches == 0 then
    return nil, nil
  end
  if #matches > 1 then
    local aliases = {}
    for _, match in ipairs(matches) do
      aliases[#aliases + 1] = match.alias
    end
    table.sort(aliases)
    return nil, aliases
  end
  return matches[1].lib, nil
end

---Resolve a `libs.*` dependency accessor into a dependency entry or notes.
---@param conf string
---@param accessor string
---@param catalog table|nil
---@return table|nil dep
---@return string[] notes
local function resolve_catalog_dep(conf, accessor, catalog)
  local lib, ambiguous = catalog_library(catalog, accessor)
  if ambiguous then
    return nil,
      {
        ("ambiguous catalog alias %s (matches: %s)"):format(accessor, table.concat(ambiguous, ", ")),
      }
  end
  if lib and lib.groupId then
    local extra_notes = {}
    if lib.note then
      extra_notes[#extra_notes + 1] = accessor .. ": " .. lib.note
    end
    return {
      configuration = conf,
      groupId = lib.groupId,
      artifactId = lib.artifactId,
      version = lib.version,
      note = lib.note,
    },
      extra_notes
  end
  return nil, { "catalog alias not resolved (no libs.versions.toml entry): " .. accessor }
end

local DYNAMIC_MARKERS = {
  { pattern = "project%s*%(", note = "project dependency not resolved" },
  { pattern = "platform%s*%(", note = "platform/BOM dependency not resolved" },
  { pattern = "enforcedPlatform%s*%(", note = "platform/BOM dependency not resolved" },
  { pattern = "files%s*%(", note = "file dependency not resolved" },
  { pattern = "fileTree%s*%(", note = "file-tree dependency not resolved" },
}

---Static parse of a Groovy build.gradle dependency block(s). Never executes
---Gradle. Unsupported forms are reported as notes instead of being guessed.
---@param text string
---@param catalog table|nil result of _parse_version_catalog
---@return table[] deps, string[] notes
function M._parse_gradle_dependencies(text, catalog)
  local deps, notes = {}, {}

  local without_blocks = (text or ""):gsub("/%*.-%*/", function(match)
    return (match:gsub("[^\n]", " "))
  end)

  for raw in without_blocks:gmatch("[^\r\n]+") do
    local line = trim(strip_groovy_line_comment(raw))
    local conf = line:match("^(%a[%w_]*)")
    if conf and GRADLE_CONFIGS[conf] then
      local rest = line:sub(#conf + 1)

      -- string coordinates: conf('g:a:v'), conf "g:a:v"
      local coord = rest:match("^%s*%(%s*'([^']*)'%s*%)%s*$")
        or rest:match('^%s*%(%s*"([^"]*)"%s*%)%s*$')
        or rest:match("^%s+'([^']*)'%s*$")
        or rest:match('^%s+"([^"]*)"%s*$')
      if coord then
        if coord:find("%$") then
          notes[#notes + 1] = "dynamic version or variable not resolved: " .. coord
        else
          local parsed = split_coordinate(coord)
          if parsed then
            parsed.configuration = conf
            deps[#deps + 1] = parsed
          else
            notes[#notes + 1] = "unsupported coordinate: " .. coord
          end
        end
      else
        -- catalog alias: conf(libs.foo.bar) or conf libs.foo.bar
        local accessor = rest:match("^%s*%(%s*(libs[%w%._%-]*)%s*%)%s*$") or rest:match("^%s+(libs[%w%._%-]*)%s*$")
        if accessor then
          local dep, extra_notes = resolve_catalog_dep(conf, accessor, catalog)
          if dep then
            deps[#deps + 1] = dep
          end
          for _, extra in ipairs(extra_notes) do
            notes[#notes + 1] = extra
          end
        else
          local matched = false
          for _, marker in ipairs(DYNAMIC_MARKERS) do
            if rest:find(marker.pattern) then
              notes[#notes + 1] = marker.note .. ": " .. line
              matched = true
              break
            end
          end
          if not matched and rest:find("%$") then
            notes[#notes + 1] = "dynamic version or variable not resolved: " .. line
            matched = true
          end
          if not matched and rest:find("^%s*%(") then
            notes[#notes + 1] = "unsupported dependency notation: " .. line
          end
        end
      end
    end
  end

  return deps, notes
end

-- ---------- Gradle Kotlin DSL (read-only static parse) ----------

local KOTLIN_CONTROL_KEYWORDS = {
  ["if"] = true,
  ["else"] = true,
  ["for"] = true,
  ["while"] = true,
  when = true,
  try = true,
  catch = true,
  finally = true,
}

local KOTLIN_UNSUPPORTED_DECL_KEYWORDS = {
  val = true,
  var = true,
}

local KOTLIN_NON_DEP_BLOCKS = {
  constraints = true,
  modules = true,
  components = true,
  attributesSchema = true,
  artifactTypes = true,
}

---Shadow copy of `text` with C-like line (`//`) and block (`/* ... */`)
---comments replaced by spaces. Preserves byte length and line endings while
---respecting string and char literals.
---@param text string
---@param opts { nested_comments: boolean, triple_single: boolean, groovy_slashy?: boolean }
---@return string masked
---@return boolean has_unterminated_comment
---@return boolean has_slashy
local function mask_c_like_comments(text, opts)
  text = text or ""
  local n = #text
  local out = {}
  local i = 1
  local unterminated = false
  local has_slashy = false
  local special_pat = opts.groovy_slashy and "[\"'/$]" or "[\"'/]"

  while i <= n do
    local ch = text:sub(i, i)
    if ch == '"' then
      if text:sub(i, i + 2) == '"""' then
        local close_s = text:find('"""', i + 3, true)
        local stop = close_s and (close_s + 2) or n
        out[#out + 1] = text:sub(i, stop)
        i = stop + 1
      else
        local j = i + 1
        while j <= n do
          local c = text:sub(j, j)
          if c == "\\" then
            j = j + 2
          elseif c == '"' then
            j = j + 1
            break
          elseif c == "\n" or c == "\r" then
            break
          else
            j = j + 1
          end
        end
        out[#out + 1] = text:sub(i, j - 1)
        i = j
      end
    elseif ch == "'" then
      if opts.triple_single and text:sub(i, i + 2) == "'''" then
        local close_s = text:find("'''", i + 3, true)
        local stop = close_s and (close_s + 2) or n
        out[#out + 1] = text:sub(i, stop)
        i = stop + 1
      else
        local j = i + 1
        while j <= n do
          local c = text:sub(j, j)
          if c == "\\" then
            j = j + 2
          elseif c == "'" then
            j = j + 1
            break
          elseif c == "\n" or c == "\r" then
            break
          else
            j = j + 1
          end
        end
        out[#out + 1] = text:sub(i, j - 1)
        i = j
      end
    elseif opts.groovy_slashy and ch == "$" and text:sub(i + 1, i + 1) == "/" then
      has_slashy = true
      local j = i + 2
      local closed = false
      while j <= n do
        local pair = text:sub(j, j + 1)
        if pair == "$$" or pair == "$/" then
          j = j + 2
        elseif pair == "/$" then
          closed = true
          j = j + 2
          break
        else
          j = j + 1
        end
      end
      if not closed then
        unterminated = true
      end
      out[#out + 1] = text:sub(i, j - 1)
      i = j
    elseif ch == "/" and text:sub(i + 1, i + 1) == "/" then
      local nl = text:find("\n", i + 2, true)
      local stop = nl and (nl - 1) or n
      out[#out + 1] = (text:sub(i, stop):gsub("[^\r\n]", " "))
      i = stop + 1
    elseif ch == "/" and text:sub(i + 1, i + 1) == "*" then
      local depth = 1
      local j = i + 2
      while j <= n and depth > 0 do
        local pair = text:sub(j, j + 1)
        if opts.nested_comments and pair == "/*" then
          depth = depth + 1
          j = j + 2
        elseif pair == "*/" then
          depth = depth - 1
          j = j + 2
        else
          j = j + 1
        end
      end
      if depth > 0 then
        unterminated = true
      end
      out[#out + 1] = (text:sub(i, j - 1):gsub("[^\r\n]", " "))
      i = j
    elseif opts.groovy_slashy and ch == "/" then
      has_slashy = true
      out[#out + 1] = ch
      i = i + 1
    else
      local next_special = text:find(special_pat, i + 1)
      local stop = next_special and (next_special - 1) or n
      out[#out + 1] = text:sub(i, stop)
      i = stop + 1
    end
  end

  return table.concat(out), unterminated, has_slashy
end

---Shadow copy of `text` with Kotlin line (`//`) and nested block (`/* ... */`)
---comments replaced by spaces. Preserves byte length and line endings while
---respecting string (`"..."`, `"""..."""`) and char (`'...'`) literals.
---@param text string
---@return string masked
---@return boolean has_unterminated_comment
function M._mask_kotlin(text)
  local masked, unterminated = mask_c_like_comments(text, { nested_comments = true, triple_single = false })
  return masked, unterminated
end

---Shadow copy of `text` with Groovy line (`//`) and block (`/* ... */`)
---comments replaced by spaces. Preserves byte length and line endings while
---respecting Groovy single/double/triple-quoted strings and flagging slashy/dollar-slashy constructs.
---@param text string
---@return string masked
---@return boolean has_unterminated_comment
---@return boolean has_slashy
function M._mask_groovy(text)
  return mask_c_like_comments(text, { nested_comments = false, triple_single = true, groovy_slashy = true })
end

---@param masked string
---@param i integer
---@param quote_char string
---@param check_interp boolean
---@return table token, integer next_pos
local function scan_quoted_string(masked, i, quote_char, check_interp)
  local n = #masked
  local j = i + 1
  local decoded = {}
  local interpolated = false
  local closed = false
  while j <= n do
    local c = masked:sub(j, j)
    if c == "\\" then
      if j + 1 <= n then
        local nxt = masked:sub(j + 1, j + 1)
        if nxt == "n" then
          decoded[#decoded + 1] = "\n"
        elseif nxt == "r" then
          decoded[#decoded + 1] = "\r"
        elseif nxt == "t" then
          decoded[#decoded + 1] = "\t"
        else
          decoded[#decoded + 1] = nxt
        end
        j = j + 2
      else
        j = j + 1
        break
      end
    elseif c == quote_char then
      closed = true
      j = j + 1
      break
    elseif c == "\n" or c == "\r" then
      break
    else
      if check_interp and c == "$" and j + 1 <= n and masked:sub(j + 1, j + 1):match("[%a_{]") then
        interpolated = true
      end
      decoded[#decoded + 1] = c
      j = j + 1
    end
  end
  return {
    kind = "string",
    quote = quote_char,
    value = table.concat(decoded),
    interpolated = interpolated,
    unterminated = not closed,
    start_pos = i,
    end_pos = j - 1,
  },
    j
end

---Tokenize a comment-masked Gradle DSL string (Kotlin or Groovy) into a flat token list.
---@param masked string
---@param is_kotlin_dsl boolean
---@return table[]
local function tokenize_gradle(masked, is_kotlin_dsl)
  local n = #masked
  local tokens = {}
  local i = 1

  while i <= n do
    local ch = masked:sub(i, i)
    if ch == " " or ch == "\t" or ch == "\r" then
      i = i + 1
    elseif ch == "\n" then
      tokens[#tokens + 1] = { kind = "newline", value = "\n", start_pos = i, end_pos = i }
      i = i + 1
    elseif ch == '"' then
      if masked:sub(i, i + 2) == '"""' then
        local close_s = masked:find('"""', i + 3, true)
        local stop = close_s and (close_s + 2) or n
        local content = close_s and masked:sub(i + 3, close_s - 1) or masked:sub(i + 3)
        tokens[#tokens + 1] = {
          kind = "string",
          quote = '"',
          value = content,
          interpolated = content:find("%$[%a_{]") ~= nil,
          unterminated = close_s == nil,
          start_pos = i,
          end_pos = stop,
        }
        i = stop + 1
      else
        local tok, nxt = scan_quoted_string(masked, i, '"', true)
        tokens[#tokens + 1] = tok
        i = nxt
      end
    elseif ch == "'" then
      if not is_kotlin_dsl and masked:sub(i, i + 2) == "'''" then
        local close_s = masked:find("'''", i + 3, true)
        local stop = close_s and (close_s + 2) or n
        local content = close_s and masked:sub(i + 3, close_s - 1) or masked:sub(i + 3)
        tokens[#tokens + 1] = {
          kind = "string",
          quote = "'",
          value = content,
          interpolated = false,
          unterminated = close_s == nil,
          start_pos = i,
          end_pos = stop,
        }
        i = stop + 1
      elseif not is_kotlin_dsl then
        local tok, nxt = scan_quoted_string(masked, i, "'", false)
        tokens[#tokens + 1] = tok
        i = nxt
      else
        local j = i + 1
        local closed = false
        while j <= n do
          local c = masked:sub(j, j)
          if c == "\\" then
            j = j + 2
          elseif c == "'" then
            closed = true
            j = j + 1
            break
          elseif c == "\n" or c == "\r" then
            break
          else
            j = j + 1
          end
        end
        tokens[#tokens + 1] = {
          kind = "char",
          value = masked:sub(i, j - 1),
          unterminated = not closed,
          start_pos = i,
          end_pos = j - 1,
        }
        i = j
      end
    elseif ch == "`" and is_kotlin_dsl then
      local close_s = masked:find("`", i + 1, true)
      local nl = masked:find("[\r\n]", i + 1)
      local stop
      local inner
      if close_s and (not nl or close_s < nl) then
        inner = masked:sub(i + 1, close_s - 1)
        stop = close_s
      else
        stop = nl and (nl - 1) or n
        inner = masked:sub(i + 1, stop)
      end
      tokens[#tokens + 1] = {
        kind = "ident",
        value = inner,
        start_pos = i,
        end_pos = stop,
      }
      i = stop + 1
    elseif ch:match("[%a_]") then
      local _, word_e = masked:find("^[%a_][%w_]*", i)
      local word = masked:sub(i, word_e)
      tokens[#tokens + 1] = {
        kind = "ident",
        value = word,
        start_pos = i,
        end_pos = word_e,
      }
      i = word_e + 1
    elseif ch:match("%d") then
      local _, num_e = masked:find("^%d[%w_]*", i)
      tokens[#tokens + 1] = {
        kind = "number",
        value = masked:sub(i, num_e),
        start_pos = i,
        end_pos = num_e,
      }
      i = num_e + 1
    else
      tokens[#tokens + 1] = {
        kind = "punct",
        value = ch,
        start_pos = i,
        end_pos = i,
      }
      i = i + 1
    end
  end

  return tokens
end

---Tokenize a comment-masked Kotlin DSL string into a flat token list.
---@param masked string
---@return table[]
local function tokenize_kotlin(masked)
  return tokenize_gradle(masked, true)
end

---@param masked string
---@param stmt_tokens table[]
---@return string
local function kotlin_snippet(masked, stmt_tokens)
  if #stmt_tokens == 0 then
    return ""
  end
  local first_pos = stmt_tokens[1].start_pos
  local last_pos = stmt_tokens[#stmt_tokens].end_pos
  local text = trim(masked:sub(first_pos, last_pos):gsub("%s+", " "))
  if #text > 120 then
    return text:sub(1, 117) .. "..."
  end
  return text
end

---@param tokens table[]
---@param open_idx integer index of `(` or `{`
---@param open_char string
---@param close_char string
---@return integer|nil close_idx
local function find_matching_delim(tokens, open_idx, open_char, close_char)
  local depth = 0
  for i = open_idx, #tokens do
    local tok = tokens[i]
    if tok.kind == "punct" then
      if tok.value == open_char then
        depth = depth + 1
      elseif tok.value == close_char then
        depth = depth - 1
        if depth == 0 then
          return i
        end
      end
    end
  end
  return nil
end

---@param arg_tokens table[]
---@return string|nil accessor
local function kotlin_libs_accessor(arg_tokens)
  if #arg_tokens < 3 or #arg_tokens % 2 == 0 then
    return nil
  end
  if arg_tokens[1].kind ~= "ident" or arg_tokens[1].value ~= "libs" then
    return nil
  end
  local parts = { "libs" }
  for i = 2, #arg_tokens, 2 do
    local dot = arg_tokens[i]
    local seg = arg_tokens[i + 1]
    if dot.kind ~= "punct" or dot.value ~= "." or not seg or seg.kind ~= "ident" then
      return nil
    end
    parts[#parts + 1] = seg.value
  end
  return table.concat(parts, ".")
end

---@param arg_tokens table[]
---@return boolean
local function has_interpolated_or_dynamic(arg_tokens)
  for _, tok in ipairs(arg_tokens) do
    if tok.kind == "string" and tok.interpolated then
      return true
    end
    if tok.kind == "punct" and tok.value == "+" then
      return true
    end
  end
  return #arg_tokens == 1 and arg_tokens[1].kind == "ident"
end

---@param args_slice table[]
---@return table[]|nil arg_list
local function split_kotlin_call_args(args_slice)
  if #args_slice > 0 and args_slice[#args_slice].kind == "punct" and args_slice[#args_slice].value == "," then
    table.remove(args_slice)
  end
  if #args_slice == 0 then
    return nil
  end
  local arg_list = {}
  local current = {}
  local paren, bracket, brace = 0, 0, 0
  for _, tok in ipairs(args_slice) do
    local is_comma_sep = tok.kind == "punct" and tok.value == "," and paren == 0 and bracket == 0 and brace == 0
    if is_comma_sep then
      if #current == 0 then
        return nil
      end
      arg_list[#arg_list + 1] = current
      current = {}
    else
      if tok.kind == "punct" then
        if tok.value == "(" then
          paren = paren + 1
        elseif tok.value == ")" then
          paren = math.max(0, paren - 1)
        elseif tok.value == "[" then
          bracket = bracket + 1
        elseif tok.value == "]" then
          bracket = math.max(0, bracket - 1)
        elseif tok.value == "{" then
          brace = brace + 1
        elseif tok.value == "}" then
          brace = math.max(0, brace - 1)
        end
      end
      current[#current + 1] = tok
    end
  end
  if #current == 0 then
    return nil
  end
  arg_list[#arg_list + 1] = current
  return arg_list
end

local KOTLIN_NAMED_DEP_PARAMS = { "group", "name", "version", "configuration", "classifier", "ext" }
local KOTLIN_ALLOWED_DEP_PARAMS = {
  group = true,
  name = true,
  version = true,
  configuration = true,
  classifier = true,
  ext = true,
}

---@param ctx table
---@param dep table
---@param has_config_lambda boolean
---@param snippet string
local function record_kotlin_dep(ctx, dep, has_config_lambda, snippet)
  if has_config_lambda then
    if dep.version then
      dep.declared_version = dep.version
      dep.version = nil
    end
    dep.has_configuration_lambda = true
    ctx.notes[#ctx.notes + 1] = "dependency configuration lambda not evaluated (effective version/constraints may differ): "
      .. snippet
  end
  ctx.deps[#ctx.deps + 1] = dep
end

---@param conf string
---@param arg_list table[]
---@param snippet string
---@param ctx table
---@param has_config_lambda boolean
local function parse_kotlin_multi_arg_dep(conf, arg_list, snippet, ctx, has_config_lambda)
  local values = {}
  local seen_named = false
  for idx, arg in ipairs(arg_list) do
    local key, val_tokens
    if #arg >= 3 and arg[1].kind == "ident" and arg[2].kind == "punct" and arg[2].value == "=" then
      seen_named = true
      key = arg[1].value
      if not KOTLIN_ALLOWED_DEP_PARAMS[key] then
        ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
        return
      end
      val_tokens = vim.list_slice(arg, 3)
    elseif seen_named then
      ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
      return
    else
      key = KOTLIN_NAMED_DEP_PARAMS[idx]
      if not key then
        ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
        return
      end
      val_tokens = arg
    end

    if #val_tokens == 1 and val_tokens[1].kind == "string" then
      local tok = val_tokens[1]
      if tok.unterminated then
        ctx.notes[#ctx.notes + 1] = "unterminated string in dependency declaration: " .. snippet
        return
      end
      if tok.interpolated then
        ctx.notes[#ctx.notes + 1] = "dynamic version or variable not resolved: " .. snippet
        return
      end
      if tok.value == "" or tok.value:find("%s") or tok.value:find(":", 1, true) then
        ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
        return
      end
      values[key] = tok.value
    elseif #val_tokens == 1 and val_tokens[1].kind == "ident" and val_tokens[1].value == "null" then
      values[key] = false
    else
      if has_interpolated_or_dynamic(val_tokens) or key == "version" or key == "group" or key == "name" then
        ctx.notes[#ctx.notes + 1] = "dynamic version or variable not resolved: " .. snippet
      else
        ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
      end
      return
    end
  end

  if type(values.group) == "string" and type(values.name) == "string" then
    local dep = {
      configuration = conf,
      groupId = values.group,
      artifactId = values.name,
    }
    if type(values.version) == "string" then
      dep.version = values.version
    end
    record_kotlin_dep(ctx, dep, has_config_lambda, snippet)
  else
    ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
  end
end

---@param arg table[]
---@param snippet string
---@return string|nil note
local function kotlin_dynamic_arg_note(arg, snippet)
  if #arg >= 2 and arg[1].kind == "ident" then
    local head = arg[1].value
    local second = arg[2]
    if second.kind == "punct" and second.value == "(" then
      if head == "project" then
        return "project dependency not resolved: " .. snippet
      elseif head == "platform" or head == "enforcedPlatform" then
        return "platform/BOM dependency not resolved: " .. snippet
      elseif head == "testFixtures" then
        return "testFixtures dependency not resolved: " .. snippet
      elseif head == "files" then
        return "file dependency not resolved: " .. snippet
      elseif head == "fileTree" then
        return "file-tree dependency not resolved: " .. snippet
      elseif head == "kotlin" then
        return "kotlin() dependency helper not resolved: " .. snippet
      end
    elseif head == "projects" and second.kind == "punct" and second.value == "." then
      return "project dependency not resolved: " .. snippet
    end
  end
  if has_interpolated_or_dynamic(arg) then
    return "dynamic version or variable not resolved: " .. snippet
  end
  return "unsupported dependency notation: " .. snippet
end

---@param stmt_tokens table[]
---@param ctx table
local function parse_kotlin_dep_statement(stmt_tokens, ctx)
  if #stmt_tokens == 0 then
    return
  end
  local first = stmt_tokens[1]
  local snippet = kotlin_snippet(ctx.masked, stmt_tokens)

  if first.kind == "ident" then
    if KOTLIN_UNSUPPORTED_DECL_KEYWORDS[first.value] then
      ctx.notes[#ctx.notes + 1] = "unsupported declaration in dependencies not resolved: " .. snippet
      return
    end
    if KOTLIN_CONTROL_KEYWORDS[first.value] then
      ctx.notes[#ctx.notes + 1] = "conditional or loop block in dependencies not resolved: " .. snippet
      return
    end
    if KOTLIN_NON_DEP_BLOCKS[first.value] then
      ctx.notes[#ctx.notes + 1] = ("dependency %s block not resolved"):format(first.value)
      return
    end
  end

  if first.kind ~= "ident" or not GRADLE_CONFIGS[first.value] then
    ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
    return
  end

  local conf = first.value
  local open_tok = stmt_tokens[2]
  if not open_tok or open_tok.kind ~= "punct" or open_tok.value ~= "(" then
    ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
    return
  end

  local close_paren = find_matching_delim(stmt_tokens, 2, "(", ")")
  if not close_paren then
    ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
    return
  end

  local has_config_lambda = false
  -- Only nothing or a trailing configuration lambda `{ ... }` may follow `(...)`.
  if close_paren < #stmt_tokens then
    local after = stmt_tokens[close_paren + 1]
    local close_brace = after.kind == "punct"
      and after.value == "{"
      and find_matching_delim(stmt_tokens, close_paren + 1, "{", "}")
    if close_brace ~= #stmt_tokens then
      ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
      return
    end
    has_config_lambda = true
  end

  local args_slice = {}
  for i = 3, close_paren - 1 do
    args_slice[#args_slice + 1] = stmt_tokens[i]
  end
  local arg_list = split_kotlin_call_args(args_slice)
  if not arg_list then
    ctx.notes[#ctx.notes + 1] = "unsupported dependency notation: " .. snippet
    return
  end

  if #arg_list == 1 then
    local arg = arg_list[1]
    local is_named = #arg >= 3 and arg[1].kind == "ident" and arg[2].kind == "punct" and arg[2].value == "="
    if is_named then
      parse_kotlin_multi_arg_dep(conf, arg_list, snippet, ctx, has_config_lambda)
      return
    end
    if #arg == 1 and arg[1].kind == "string" then
      local str_tok = arg[1]
      if str_tok.unterminated then
        ctx.notes[#ctx.notes + 1] = "unterminated string in dependency declaration: " .. snippet
      elseif str_tok.interpolated then
        ctx.notes[#ctx.notes + 1] = "dynamic version or variable not resolved: " .. str_tok.value
      else
        local parsed = split_coordinate(str_tok.value)
        if parsed then
          parsed.configuration = conf
          record_kotlin_dep(ctx, parsed, has_config_lambda, snippet)
        else
          ctx.notes[#ctx.notes + 1] = "unsupported coordinate: " .. str_tok.value
        end
      end
      return
    end

    local accessor = kotlin_libs_accessor(arg)
    if accessor then
      if accessor:match("^libs%.bundles%.") then
        ctx.notes[#ctx.notes + 1] = "catalog bundle not resolved: " .. accessor
      elseif accessor:match("^libs%.versions%.") or accessor:match("^libs%.plugins%.") then
        ctx.notes[#ctx.notes + 1] = "unsupported catalog accessor: " .. accessor
      else
        local dep, extra_notes = resolve_catalog_dep(conf, accessor, ctx.catalog)
        if dep then
          record_kotlin_dep(ctx, dep, has_config_lambda, snippet)
        end
        for _, extra in ipairs(extra_notes) do
          ctx.notes[#ctx.notes + 1] = extra
        end
      end
      return
    end

    ctx.notes[#ctx.notes + 1] = kotlin_dynamic_arg_note(arg, snippet)
    return
  end

  parse_kotlin_multi_arg_dep(conf, arg_list, snippet, ctx, has_config_lambda)
end

---@param tokens table[]
---@param i integer
---@return table|nil
local function next_non_newline(tokens, i)
  while i <= #tokens do
    if tokens[i].kind ~= "newline" then
      return tokens[i]
    end
    i = i + 1
  end
  return nil
end

local KOTLIN_CONTINUATION_PUNCT = {
  ["="] = true,
  ["+"] = true,
  ["."] = true,
  [","] = true,
}

---Parse all statements inside one `dependencies { ... }` block starting at `start_idx`.
---@param tokens table[]
---@param start_idx integer
---@param ctx table
---@return integer next_idx
local function parse_kotlin_dependencies_block(tokens, start_idx, ctx)
  local i = start_idx
  local n = #tokens
  while i <= n do
    while i <= n and (tokens[i].kind == "newline" or (tokens[i].kind == "punct" and tokens[i].value == ";")) do
      i = i + 1
    end
    if i > n then
      ctx.notes[#ctx.notes + 1] = "unterminated dependencies block in build.gradle.kts"
      return i
    end
    if tokens[i].kind == "punct" and tokens[i].value == "}" then
      return i + 1
    end

    local stmt = {}
    local paren, bracket, brace = 0, 0, 0
    local closed_outer = false
    while i <= n do
      local tok = tokens[i]
      if tok.kind == "punct" then
        if tok.value == "(" then
          paren = paren + 1
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == ")" then
          paren = math.max(0, paren - 1)
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == "[" then
          bracket = bracket + 1
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == "]" then
          bracket = math.max(0, bracket - 1)
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == "{" then
          brace = brace + 1
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == "}" then
          if paren == 0 and bracket == 0 and brace == 0 then
            closed_outer = true
            break
          end
          brace = brace - 1
          stmt[#stmt + 1] = tok
          i = i + 1
          if paren == 0 and bracket == 0 and brace == 0 then
            local nxt = next_non_newline(tokens, i)
            local keep = nxt
              and ((nxt.kind == "ident" and nxt.value == "else") or (nxt.kind == "punct" and nxt.value == "."))
            if not keep then
              break
            end
          end
        elseif tok.value == ";" and paren == 0 and bracket == 0 and brace == 0 then
          i = i + 1
          break
        else
          stmt[#stmt + 1] = tok
          i = i + 1
        end
      elseif tok.kind == "newline" then
        if paren == 0 and bracket == 0 and brace == 0 then
          local prev = stmt[#stmt]
          local nxt = next_non_newline(tokens, i + 1)
          local cont_prev = prev and prev.kind == "punct" and KOTLIN_CONTINUATION_PUNCT[prev.value]
          local cont_next = nxt and nxt.kind == "punct" and (nxt.value == "{" or nxt.value == ".")
          if not cont_prev and not cont_next then
            i = i + 1
            break
          end
        end
        i = i + 1
      else
        stmt[#stmt + 1] = tok
        i = i + 1
      end
    end

    parse_kotlin_dep_statement(stmt, ctx)
    if closed_outer then
      return i + 1
    end
    if i > n then
      ctx.notes[#ctx.notes + 1] = "unterminated dependencies block in build.gradle.kts"
      return i
    end
  end
  return i
end

---@param stmt_tokens table[]
---@return "unqualified"|"qualified"|"unsupported"|nil
local function classify_dependencies_header(stmt_tokens)
  if #stmt_tokens == 0 then
    return nil
  end
  local last = stmt_tokens[#stmt_tokens]
  if last.kind ~= "ident" or last.value ~= "dependencies" then
    return nil
  end
  if #stmt_tokens == 1 then
    return "unqualified"
  end
  local prev = stmt_tokens[#stmt_tokens - 1]
  if prev.kind == "punct" and prev.value == "." then
    return "qualified"
  end
  return "unsupported"
end

---@param stmt_tokens table[]
---@param name string
---@return boolean
local function stmt_has_ident(stmt_tokens, name)
  for _, tok in ipairs(stmt_tokens) do
    if tok.kind == "ident" and tok.value == name then
      return true
    end
  end
  return false
end

---@param stmt_tokens table[]
---@return boolean
local function is_kotlin_apply_from_stmt(stmt_tokens)
  for k = 1, #stmt_tokens - 1 do
    local tok = stmt_tokens[k]
    local nxt = stmt_tokens[k + 1]
    if tok.kind == "ident" and tok.value == "apply" and nxt.kind == "punct" and nxt.value == "(" then
      local close_p = find_matching_delim(stmt_tokens, k + 1, "(", ")")
      local stop = close_p and (close_p - 1) or #stmt_tokens
      for j = k + 2, stop - 1 do
        local arg_tok = stmt_tokens[j]
        local after_tok = stmt_tokens[j + 1]
        if
          arg_tok.kind == "ident"
          and arg_tok.value == "from"
          and after_tok.kind == "punct"
          and after_tok.value == "="
        then
          return true
        end
        if
          arg_tok.kind == "string"
          and arg_tok.value == "from"
          and after_tok.kind == "ident"
          and after_tok.value == "to"
        then
          return true
        end
      end
    end
  end
  return false
end

---@param tokens table[]
---@param open_brace_idx integer
---@param close_brace_idx integer|nil
---@return boolean
local function block_has_apply_from(tokens, open_brace_idx, close_brace_idx)
  local stop = close_brace_idx and (close_brace_idx - 1) or #tokens
  for k = open_brace_idx + 1, stop do
    local tok = tokens[k]
    if tok.kind == "ident" and tok.value == "from" then
      local nxt = next_non_newline(tokens, k + 1)
      if nxt and nxt.kind == "punct" and (nxt.value == "(" or nxt.value == "=") then
        return true
      end
    end
  end
  return false
end

---@param tokens table[]
---@param start_idx integer
---@param block_stack string[]
---@param ctx table
---@return integer next_idx
local function scan_kotlin_blocks(tokens, start_idx, block_stack, ctx)
  local i = start_idx
  local n = #tokens
  local stmt = {}
  local paren, bracket = 0, 0

  local function flush_top_statement()
    if #stmt == 0 then
      return
    end
    if
      #stmt >= 3
      and stmt[1].kind == "ident"
      and stmt[1].value == "dependencies"
      and stmt[2].kind == "punct"
      and stmt[2].value == "."
    then
      if #block_stack == 0 or (#block_stack == 1 and block_stack[1] == "buildscript") then
        parse_kotlin_dep_statement(vim.list_slice(stmt, 3), ctx)
      else
        ctx.notes[#ctx.notes + 1] = ("scoped or conditional dependencies block not resolved (%s)"):format(
          table.concat(block_stack, " > ")
        )
      end
    else
      local matched = false
      for k = 2, #stmt - 1 do
        local tok = stmt[k]
        local nxt = stmt[k + 1]
        if tok.kind == "ident" and tok.value == "dependencies" and nxt.kind == "punct" and nxt.value == "." then
          local prev = stmt[k - 1]
          if prev.kind == "punct" and prev.value == "." then
            ctx.notes[#ctx.notes + 1] = "scoped dependencies receiver not resolved: "
              .. kotlin_snippet(ctx.masked, stmt)
          else
            ctx.notes[#ctx.notes + 1] = "unsupported declaration in dependencies not resolved: "
              .. kotlin_snippet(ctx.masked, stmt)
          end
          matched = true
          break
        end
      end
      if not matched then
        if stmt_has_ident(stmt, "dependencies") then
          ctx.notes[#ctx.notes + 1] = "unsupported dependencies block not resolved: "
            .. kotlin_snippet(ctx.masked, stmt)
        elseif is_kotlin_apply_from_stmt(stmt) then
          ctx.notes[#ctx.notes + 1] = "external script apply(from = ...) not resolved: "
            .. kotlin_snippet(ctx.masked, stmt)
        end
      end
    end
    stmt = {}
  end

  while i <= n do
    local tok = tokens[i]
    if tok.kind == "punct" then
      if tok.value == "(" then
        paren = paren + 1
        stmt[#stmt + 1] = tok
        i = i + 1
      elseif tok.value == ")" then
        paren = math.max(0, paren - 1)
        stmt[#stmt + 1] = tok
        i = i + 1
      elseif tok.value == "[" then
        bracket = bracket + 1
        stmt[#stmt + 1] = tok
        i = i + 1
      elseif tok.value == "]" then
        bracket = math.max(0, bracket - 1)
        stmt[#stmt + 1] = tok
        i = i + 1
      elseif tok.value == "{" and paren == 0 and bracket == 0 then
        local header_kind = classify_dependencies_header(stmt)
        if header_kind == "unqualified" then
          stmt = {}
          if #block_stack == 0 or (#block_stack == 1 and block_stack[1] == "buildscript") then
            i = parse_kotlin_dependencies_block(tokens, i + 1, ctx)
          else
            ctx.notes[#ctx.notes + 1] = ("scoped or conditional dependencies block not resolved (%s)"):format(
              table.concat(block_stack, " > ")
            )
            local close_brace = find_matching_delim(tokens, i, "{", "}")
            i = close_brace and (close_brace + 1) or (n + 1)
          end
        elseif header_kind == "qualified" then
          ctx.notes[#ctx.notes + 1] = "scoped dependencies receiver not resolved: " .. kotlin_snippet(ctx.masked, stmt)
          stmt = {}
          local close_brace = find_matching_delim(tokens, i, "{", "}")
          i = close_brace and (close_brace + 1) or (n + 1)
        elseif header_kind == "unsupported" or stmt_has_ident(stmt, "dependencies") then
          ctx.notes[#ctx.notes + 1] = "unsupported dependencies block not resolved: "
            .. kotlin_snippet(ctx.masked, stmt)
          stmt = {}
          local close_brace = find_matching_delim(tokens, i, "{", "}")
          i = close_brace and (close_brace + 1) or (n + 1)
        elseif #stmt >= 1 and stmt[#stmt].kind == "ident" and stmt[#stmt].value == "apply" then
          local close_brace = find_matching_delim(tokens, i, "{", "}")
          if block_has_apply_from(tokens, i, close_brace) then
            local end_tok = tokens[close_brace or n]
            ctx.notes[#ctx.notes + 1] = "external script apply(from = ...) not resolved: "
              .. kotlin_snippet(ctx.masked, { stmt[1], end_tok })
            stmt = {}
            i = close_brace and (close_brace + 1) or (n + 1)
          else
            local label = stmt[1].kind == "ident" and stmt[1].value or "block"
            stmt = {}
            block_stack[#block_stack + 1] = label
            i = scan_kotlin_blocks(tokens, i + 1, block_stack, ctx)
            block_stack[#block_stack] = nil
          end
        else
          local label = (#stmt > 0 and stmt[1].kind == "ident") and stmt[1].value or "block"
          stmt = {}
          block_stack[#block_stack + 1] = label
          i = scan_kotlin_blocks(tokens, i + 1, block_stack, ctx)
          block_stack[#block_stack] = nil
        end
      elseif tok.value == "}" and paren == 0 and bracket == 0 then
        flush_top_statement()
        if #block_stack > 0 then
          return i + 1
        end
        i = i + 1
      elseif tok.value == ";" and paren == 0 and bracket == 0 then
        flush_top_statement()
        i = i + 1
      else
        stmt[#stmt + 1] = tok
        i = i + 1
      end
    elseif tok.kind == "newline" then
      if paren == 0 and bracket == 0 then
        local prev = stmt[#stmt]
        local nxt = next_non_newline(tokens, i + 1)
        local cont_prev = prev and prev.kind == "punct" and (prev.value == "." or prev.value == "=")
        local cont_next = nxt and nxt.kind == "punct" and (nxt.value == "{" or nxt.value == ".")
        if not cont_prev and not cont_next then
          flush_top_statement()
        end
      end
      i = i + 1
    else
      stmt[#stmt + 1] = tok
      i = i + 1
    end
  end

  flush_top_statement()
  return i
end

---Static read-only parse of a Kotlin DSL build.gradle.kts file. Never executes
---Gradle. Unsupported, interpolated, dynamic, or scoped forms are reported as
---partial notes instead of being guessed.
---@param text string
---@param catalog table|nil result of _parse_version_catalog
---@return table[] deps, string[] notes
function M._parse_kotlin_gradle_dependencies(text, catalog)
  local masked, has_unterminated = M._mask_kotlin(text or "")
  local deps, notes = {}, {}
  if has_unterminated then
    notes[#notes + 1] = "unterminated block comment in build.gradle.kts"
  end

  local tokens = tokenize_kotlin(masked)
  local ctx = {
    masked = masked,
    deps = deps,
    notes = notes,
    catalog = catalog,
  }
  scan_kotlin_blocks(tokens, 1, {}, ctx)
  return deps, notes
end

-- ---------- Gradle safe static analysis & surgical editing ----------

local GRADLE_EDIT_KEYWORDS = {
  ["if"] = true,
  ["else"] = true,
  ["for"] = true,
  ["while"] = true,
  when = true,
  switch = true,
  try = true,
  catch = true,
  finally = true,
  val = true,
  var = true,
  def = true,
  final = true,
  ["return"] = true,
}

---@param value any
---@return boolean
local function invalid_gradle_value(value)
  if type(value) ~= "string" or value == "" then
    return true
  end
  return value:find("[%s\"'%$:\\%c]") ~= nil
end

---@param tokens table[]
---@return boolean
local function check_balanced_delimiters(tokens)
  local stack = {}
  local closing = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
  for _, tok in ipairs(tokens) do
    if tok.kind == "punct" then
      if tok.value == "(" or tok.value == "[" or tok.value == "{" then
        stack[#stack + 1] = tok.value
      elseif closing[tok.value] then
        if #stack == 0 or stack[#stack] ~= closing[tok.value] then
          return false
        end
        stack[#stack] = nil
      end
    end
  end
  return #stack == 0
end

---@param stmt_tokens table[]
---@return boolean
local function is_gradle_apply_from_stmt(stmt_tokens)
  if is_kotlin_apply_from_stmt(stmt_tokens) then
    return true
  end
  for k = 1, #stmt_tokens - 2 do
    if stmt_tokens[k].kind == "ident" and stmt_tokens[k].value == "apply" then
      for j = k + 1, #stmt_tokens - 1 do
        local cur = stmt_tokens[j]
        local nxt = stmt_tokens[j + 1]
        if
          cur.kind == "ident"
          and cur.value == "from"
          and nxt.kind == "punct"
          and (nxt.value == ":" or nxt.value == "=")
        then
          return true
        end
      end
    end
  end
  return false
end

---@param tokens table[]
---@param open_brace_idx integer
---@param close_brace_idx integer|nil
---@return boolean
local function gradle_block_has_apply_from(tokens, open_brace_idx, close_brace_idx)
  if block_has_apply_from(tokens, open_brace_idx, close_brace_idx) then
    return true
  end
  local stop = close_brace_idx and (close_brace_idx - 1) or #tokens
  for k = open_brace_idx + 1, stop do
    local tok = tokens[k]
    if tok.kind == "ident" and tok.value == "from" then
      local nxt = next_non_newline(tokens, k + 1)
      if nxt and (nxt.kind == "string" or (nxt.kind == "punct" and nxt.value == ":")) then
        return true
      end
    end
  end
  return false
end

---@param masked string
---@return string
local function detect_gradle_indent_unit(masked)
  if masked:find("\n\t", 1, true) then
    return "\t"
  end
  local min_spaces
  local pos = masked:find("\n", 1, true)
  while pos do
    local line_start = pos + 1
    local next_nl = masked:find("\n", line_start, true)
    local line_end = next_nl and (next_nl - 1) or #masked
    local line = masked:sub(line_start, line_end)
    local spaces = line:match("^( +)%S")
    if spaces and (min_spaces == nil or #spaces < min_spaces) then
      min_spaces = #spaces
    end
    pos = next_nl
  end
  return min_spaces and string.rep(" ", min_spaces) or "  "
end

---@param arg_tokens table[]
---@return boolean
local function is_static_project_arg(arg_tokens)
  if #arg_tokens >= 3 and arg_tokens[1].kind == "ident" and arg_tokens[1].value == "projects" then
    for i = 2, #arg_tokens, 2 do
      local dot = arg_tokens[i]
      local seg = arg_tokens[i + 1]
      if not dot or dot.kind ~= "punct" or dot.value ~= "." or not seg or seg.kind ~= "ident" then
        return false
      end
    end
    return #arg_tokens % 2 == 1
  end
  if
    #arg_tokens >= 4
    and arg_tokens[1].kind == "ident"
    and arg_tokens[1].value == "project"
    and arg_tokens[2].kind == "punct"
    and arg_tokens[2].value == "("
    and find_matching_delim(arg_tokens, 2, "(", ")") == #arg_tokens
  then
    local inner = vim.list_slice(arg_tokens, 3, #arg_tokens - 1)
    if #inner == 1 and inner[1].kind == "string" and not inner[1].interpolated and not inner[1].value:find("%$") then
      return inner[1].value ~= ""
    end
    if
      #inner == 3
      and inner[1].kind == "ident"
      and inner[1].value == "path"
      and inner[2].kind == "punct"
      and (inner[2].value == "=" or inner[2].value == ":")
      and inner[3].kind == "string"
      and not inner[3].interpolated
      and not inner[3].value:find("%$")
    then
      return inner[3].value ~= ""
    end
  end
  return false
end

---@param conf string
---@param arg_list table[]
---@param snippet string
---@param state table
---@param parens boolean
local function parse_edit_multi_arg_dep(conf, arg_list, snippet, state, parens)
  local values = {}
  local seen_named = false
  local first_quote

  for idx, arg in ipairs(arg_list) do
    local key, val_tokens
    local sep = arg[2] and arg[2].kind == "punct" and arg[2].value or nil
    local is_named = #arg >= 3
      and arg[1].kind == "ident"
      and ((state.is_kotlin_dsl and sep == "=") or (not state.is_kotlin_dsl and sep == ":"))

    if is_named then
      seen_named = true
      key = arg[1].value
      if not KOTLIN_ALLOWED_DEP_PARAMS[key] then
        state.unsupported_reason = "unsupported dependency notation: " .. snippet
        return
      end
      val_tokens = vim.list_slice(arg, 3)
    elseif seen_named or not state.is_kotlin_dsl then
      state.unsupported_reason = "unsupported dependency notation: " .. snippet
      return
    else
      key = KOTLIN_NAMED_DEP_PARAMS[idx]
      if not key then
        state.unsupported_reason = "unsupported dependency notation: " .. snippet
        return
      end
      val_tokens = arg
    end

    if #val_tokens == 1 and val_tokens[1].kind == "string" then
      local tok = val_tokens[1]
      if tok.interpolated or tok.value:find("%$") then
        state.unsupported_reason = "dynamic version or variable not resolved: " .. snippet
        return
      end
      if tok.value == "" or tok.value:find("%s") or tok.value:find(":", 1, true) then
        state.unsupported_reason = "unsupported dependency notation: " .. snippet
        return
      end
      values[key] = tok.value
      first_quote = first_quote or tok.quote
    elseif
      state.is_kotlin_dsl
      and #val_tokens == 1
      and val_tokens[1].kind == "ident"
      and val_tokens[1].value == "null"
    then
      values[key] = false
    else
      state.unsupported_reason = "dynamic or unsupported dependency argument: " .. snippet
      return
    end
  end

  if type(values.group) == "string" and type(values.name) == "string" then
    state.deps[#state.deps + 1] = {
      configuration = conf,
      groupId = values.group,
      artifactId = values.name,
      version = type(values.version) == "string" and values.version or nil,
    }
    if not state.style then
      state.style = {
        parens = parens,
        quote = state.is_kotlin_dsl and '"' or (first_quote or "'"),
      }
    end
  else
    state.unsupported_reason = "unsupported dependency notation: " .. snippet
  end
end

---@param conf string
---@param arg table[]
---@param snippet string
---@param state table
---@param parens boolean
---@param allow_special boolean
---@param is_platform boolean
local function parse_edit_single_arg(conf, arg, snippet, state, parens, allow_special, is_platform)
  if #arg == 1 and arg[1].kind == "string" then
    local tok = arg[1]
    if tok.interpolated or tok.value:find("%$") then
      state.unsupported_reason = "dynamic version or variable not resolved: " .. snippet
      return
    end
    local parsed = split_coordinate(tok.value)
    if not parsed then
      state.unsupported_reason = "unsupported coordinate: " .. tok.value
      return
    end
    parsed.configuration = conf
    parsed.is_platform = is_platform or nil
    state.deps[#state.deps + 1] = parsed
    if is_platform then
      state.has_bom = true
    elseif not state.style then
      state.style = { parens = parens, quote = state.is_kotlin_dsl and '"' or (tok.quote or "'") }
    end
    return
  end

  local accessor = kotlin_libs_accessor(arg)
  if accessor then
    if
      accessor:match("^libs%.bundles%.")
      or accessor:match("^libs%.versions%.")
      or accessor:match("^libs%.plugins%.")
    then
      state.unsupported_reason = "catalog bundle or non-library accessor is not supported for safe editing: "
        .. accessor
      return
    end
    local dep, extra_notes = resolve_catalog_dep(conf, accessor, state.catalog)
    if not dep then
      state.unsupported_reason = extra_notes[1] or ("catalog alias not resolved: " .. accessor)
      return
    end
    dep.catalog_accessor = accessor
    dep.is_platform = is_platform or nil
    state.deps[#state.deps + 1] = dep
    if is_platform then
      state.has_bom = true
    elseif not state.style then
      state.style = { parens = parens, quote = state.is_kotlin_dsl and '"' or "'" }
    end
    return
  end

  if allow_special then
    if is_static_project_arg(arg) then
      return
    end
    if
      #arg >= 4
      and arg[1].kind == "ident"
      and (arg[1].value == "platform" or arg[1].value == "enforcedPlatform")
      and arg[2].kind == "punct"
      and arg[2].value == "("
      and find_matching_delim(arg, 2, "(", ")") == #arg
    then
      local inner = vim.list_slice(arg, 3, #arg - 1)
      parse_edit_single_arg(conf, inner, snippet, state, parens, false, true)
      return
    end
  end

  state.unsupported_reason = "dynamic or unsupported dependency notation: " .. snippet
end

---@param stmt_tokens table[]
---@param state table
local function parse_edit_dep_statement(stmt_tokens, state)
  if #stmt_tokens == 0 or state.unsupported_reason then
    return
  end
  local first = stmt_tokens[1]
  local snippet = kotlin_snippet(state.masked, stmt_tokens)

  if first.kind == "ident" then
    if GRADLE_EDIT_KEYWORDS[first.value] then
      state.unsupported_reason = "dynamic or conditional construct in dependencies block: " .. snippet
      return
    end
    if KOTLIN_NON_DEP_BLOCKS[first.value] then
      state.unsupported_reason = ("dependency %s block is not supported for safe editing"):format(first.value)
      return
    end
  end

  if first.kind ~= "ident" or not GRADLE_EDIT_CONFIGS[first.value] then
    state.unsupported_reason = "unsupported dependency configuration or statement: " .. snippet
    return
  end

  local conf = first.value
  if not state.entry_indent then
    local _, lead = line_lead(state.text, first.start_pos)
    if lead:match("^[ \t]*$") then
      state.entry_indent = lead
    end
  end

  local parens = false
  local args_slice
  local open_tok = stmt_tokens[2]
  if open_tok and open_tok.kind == "punct" and open_tok.value == "(" then
    parens = true
    local close_paren = find_matching_delim(stmt_tokens, 2, "(", ")")
    if not close_paren then
      state.unsupported_reason = "unbalanced parentheses in dependency declaration: " .. snippet
      return
    end
    if close_paren < #stmt_tokens then
      local after = stmt_tokens[close_paren + 1]
      local close_brace = after.kind == "punct"
        and after.value == "{"
        and find_matching_delim(stmt_tokens, close_paren + 1, "{", "}")
      if close_brace ~= #stmt_tokens then
        state.unsupported_reason = "unsupported dependency notation: " .. snippet
        return
      end
    end
    args_slice = vim.list_slice(stmt_tokens, 3, close_paren - 1)
  else
    if state.is_kotlin_dsl then
      state.unsupported_reason = "unsupported dependency notation: " .. snippet
      return
    end
    local stop_idx = #stmt_tokens
    if stmt_tokens[stop_idx].kind == "punct" and stmt_tokens[stop_idx].value == "}" then
      local p, b, br = 0, 0, 0
      local trail_open
      for k = 2, stop_idx do
        local t = stmt_tokens[k]
        if t.kind == "punct" then
          if t.value == "(" then
            p = p + 1
          elseif t.value == ")" then
            p = math.max(0, p - 1)
          elseif t.value == "[" then
            b = b + 1
          elseif t.value == "]" then
            b = math.max(0, b - 1)
          elseif t.value == "{" then
            if p == 0 and b == 0 and br == 0 then
              trail_open = k
            end
            br = br + 1
          elseif t.value == "}" then
            br = math.max(0, br - 1)
          end
        end
      end
      if not trail_open or find_matching_delim(stmt_tokens, trail_open, "{", "}") ~= stop_idx then
        state.unsupported_reason = "unsupported dependency notation: " .. snippet
        return
      end
      stop_idx = trail_open - 1
      if stop_idx >= 2 and stmt_tokens[stop_idx].kind == "punct" and stmt_tokens[stop_idx].value == "," then
        stop_idx = stop_idx - 1
      end
    end
    args_slice = vim.list_slice(stmt_tokens, 2, stop_idx)
  end

  local arg_list = split_kotlin_call_args(args_slice)
  if not arg_list then
    state.unsupported_reason = "unsupported dependency notation: " .. snippet
    return
  end

  if #arg_list == 1 then
    local arg = arg_list[1]
    local sep = arg[2] and arg[2].kind == "punct" and arg[2].value or nil
    local is_named = #arg >= 3
      and arg[1].kind == "ident"
      and ((state.is_kotlin_dsl and sep == "=") or (not state.is_kotlin_dsl and sep == ":"))
    if is_named then
      parse_edit_multi_arg_dep(conf, arg_list, snippet, state, parens)
      return
    end
    parse_edit_single_arg(conf, arg, snippet, state, parens, true, false)
    return
  end

  parse_edit_multi_arg_dep(conf, arg_list, snippet, state, parens)
end

---@param tokens table[]
---@param start_idx integer
---@param close_brace_idx integer
---@param state table
local function parse_edit_dependencies_block(tokens, start_idx, close_brace_idx, state)
  local i = start_idx
  local stop = close_brace_idx - 1
  while i <= stop and not state.unsupported_reason do
    while i <= stop and (tokens[i].kind == "newline" or (tokens[i].kind == "punct" and tokens[i].value == ";")) do
      i = i + 1
    end
    if i > stop then
      break
    end

    local stmt = {}
    local paren, bracket, brace = 0, 0, 0
    while i <= stop do
      local tok = tokens[i]
      if tok.kind == "punct" then
        if tok.value == "(" then
          paren = paren + 1
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == ")" then
          paren = math.max(0, paren - 1)
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == "[" then
          bracket = bracket + 1
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == "]" then
          bracket = math.max(0, bracket - 1)
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == "{" then
          brace = brace + 1
          stmt[#stmt + 1] = tok
          i = i + 1
        elseif tok.value == "}" then
          brace = brace - 1
          stmt[#stmt + 1] = tok
          i = i + 1
          if paren == 0 and bracket == 0 and brace == 0 then
            local nxt = next_non_newline(tokens, i)
            local keep = nxt
              and ((nxt.kind == "ident" and nxt.value == "else") or (nxt.kind == "punct" and nxt.value == "."))
            if not keep then
              break
            end
          end
        elseif tok.value == ";" and paren == 0 and bracket == 0 and brace == 0 then
          i = i + 1
          break
        else
          stmt[#stmt + 1] = tok
          i = i + 1
        end
      elseif tok.kind == "newline" then
        if paren == 0 and bracket == 0 and brace == 0 then
          local prev = stmt[#stmt]
          local nxt = next_non_newline(tokens, i + 1)
          local cont_prev = prev
            and prev.kind == "punct"
            and (KOTLIN_CONTINUATION_PUNCT[prev.value] or (not state.is_kotlin_dsl and prev.value == ":"))
          local cont_next = nxt and nxt.kind == "punct" and (nxt.value == "{" or nxt.value == ".")
          if not cont_prev and not cont_next then
            i = i + 1
            break
          end
        end
        i = i + 1
      else
        stmt[#stmt + 1] = tok
        i = i + 1
      end
    end

    parse_edit_dep_statement(stmt, state)
  end
end

---@param tokens table[]
---@param start_idx integer
---@param block_stack string[]
---@param state table
---@return integer next_idx
local function scan_edit_gradle_blocks(tokens, start_idx, block_stack, state)
  local i = start_idx
  local n = #tokens
  local stmt = {}
  local paren, bracket = 0, 0

  local function flush_top_statement()
    if #stmt == 0 or state.unsupported_reason then
      stmt = {}
      return
    end
    if is_gradle_apply_from_stmt(stmt) then
      state.unsupported_reason = "external script apply(from = ...) is not supported for safe editing"
    elseif stmt_has_ident(stmt, "dependencies") then
      state.unsupported_reason = "unsupported dependencies statement is not supported for safe editing"
    end
    stmt = {}
  end

  while i <= n and not state.unsupported_reason do
    local tok = tokens[i]
    if tok.kind == "punct" then
      if tok.value == "(" then
        paren = paren + 1
        stmt[#stmt + 1] = tok
        i = i + 1
      elseif tok.value == ")" then
        paren = math.max(0, paren - 1)
        stmt[#stmt + 1] = tok
        i = i + 1
      elseif tok.value == "[" then
        bracket = bracket + 1
        stmt[#stmt + 1] = tok
        i = i + 1
      elseif tok.value == "]" then
        bracket = math.max(0, bracket - 1)
        stmt[#stmt + 1] = tok
        i = i + 1
      elseif tok.value == "{" and paren == 0 and bracket == 0 then
        local header_kind = classify_dependencies_header(stmt)
        local close_brace = find_matching_delim(tokens, i, "{", "}")
        if not close_brace then
          state.unsupported_reason = "unbalanced braces in build file"
          return n + 1
        end

        if header_kind == "unqualified" then
          stmt = {}
          if #block_stack == 0 then
            if state.dependencies_block then
              state.unsupported_reason = "multiple top-level dependencies blocks found — ambiguous insertion target"
              return n + 1
            end
            local _, open_lead = line_lead(state.text, tok.start_pos)
            state.dependencies_block = {
              open_brace_pos = tok.start_pos,
              close_brace_pos = tokens[close_brace].start_pos,
              block_indent = open_lead:match("^([ \t]*)") or "",
            }
            parse_edit_dependencies_block(tokens, i + 1, close_brace, state)
            i = close_brace + 1
          elseif #block_stack == 1 and block_stack[1] == "buildscript" then
            i = close_brace + 1
          else
            state.unsupported_reason = ("scoped or conditional dependencies block (%s) is not supported for safe editing"):format(
              table.concat(block_stack, " > ")
            )
            return n + 1
          end
        elseif header_kind == "qualified" or header_kind == "unsupported" or stmt_has_ident(stmt, "dependencies") then
          state.unsupported_reason = "unsupported or scoped dependencies block is not supported for safe editing"
          return n + 1
        elseif #stmt >= 1 and stmt[#stmt].kind == "ident" and stmt[#stmt].value == "apply" then
          if gradle_block_has_apply_from(tokens, i, close_brace) then
            state.unsupported_reason = "external script apply(from = ...) is not supported for safe editing"
            return n + 1
          end
          stmt = {}
          block_stack[#block_stack + 1] = "apply"
          i = scan_edit_gradle_blocks(tokens, i + 1, block_stack, state)
          block_stack[#block_stack] = nil
        else
          local label = (#stmt > 0 and stmt[1].kind == "ident") and stmt[1].value or "block"
          stmt = {}
          block_stack[#block_stack + 1] = label
          i = scan_edit_gradle_blocks(tokens, i + 1, block_stack, state)
          block_stack[#block_stack] = nil
        end
      elseif tok.value == "}" and paren == 0 and bracket == 0 then
        flush_top_statement()
        if #block_stack > 0 then
          return i + 1
        end
        i = i + 1
      elseif tok.value == ";" and paren == 0 and bracket == 0 then
        flush_top_statement()
        i = i + 1
      else
        stmt[#stmt + 1] = tok
        i = i + 1
      end
    elseif tok.kind == "newline" then
      if paren == 0 and bracket == 0 then
        local prev = stmt[#stmt]
        local nxt = next_non_newline(tokens, i + 1)
        local cont_prev = prev
          and prev.kind == "punct"
          and (prev.value == "." or prev.value == "=" or (not state.is_kotlin_dsl and prev.value == ":"))
        local cont_next = nxt and nxt.kind == "punct" and (nxt.value == "{" or nxt.value == ".")
        if not cont_prev and not cont_next then
          flush_top_statement()
        end
      end
      i = i + 1
    else
      stmt[#stmt + 1] = tok
      i = i + 1
    end
  end

  flush_top_statement()
  return i
end

---Analyze a Gradle build file (Groovy or Kotlin DSL) for safe bounded editing.
---Never executes Gradle; refuses ambiguous, dynamic, or broken syntax.
---@param text string
---@param is_kotlin_dsl boolean
---@param catalog table|nil
---@return table analysis
function M._analyze_gradle(text, is_kotlin_dsl, catalog)
  text = text or ""
  local masked, has_unterminated, has_slashy
  if is_kotlin_dsl then
    masked, has_unterminated = M._mask_kotlin(text)
  else
    masked, has_unterminated, has_slashy = M._mask_groovy(text)
  end

  local unit = detect_gradle_indent_unit(masked)
  if has_slashy then
    return {
      deps = {},
      has_bom = false,
      unit = unit,
      unsupported_reason = "Groovy slashy or dollar-slashy strings are not supported for safe editing",
    }
  end
  if has_unterminated then
    return {
      deps = {},
      has_bom = false,
      unit = unit,
      unsupported_reason = "unterminated block comment in build file",
    }
  end

  local tokens = tokenize_gradle(masked, is_kotlin_dsl)
  for _, tok in ipairs(tokens) do
    if tok.unterminated then
      return {
        deps = {},
        has_bom = false,
        unit = unit,
        unsupported_reason = "unterminated string literal in build file",
      }
    end
  end

  if not check_balanced_delimiters(tokens) then
    return {
      deps = {},
      has_bom = false,
      unit = unit,
      unsupported_reason = "unbalanced delimiters in build file",
    }
  end

  local state = {
    text = text,
    masked = masked,
    is_kotlin_dsl = is_kotlin_dsl == true,
    catalog = catalog,
    deps = {},
    has_bom = false,
    unit = unit,
  }
  scan_edit_gradle_blocks(tokens, 1, {}, state)

  if state.dependencies_block then
    state.dependencies_block.entry_indent = state.entry_indent
    state.dependencies_block.style = state.style
  end

  return {
    deps = state.deps,
    has_bom = state.has_bom,
    dependencies_block = state.dependencies_block,
    unit = unit,
    unsupported_reason = state.unsupported_reason,
  }
end

---@param catalog table|nil
---@param groupId string
---@param artifactId string
---@return string|nil accessor
local function find_catalog_accessor(catalog, groupId, artifactId)
  if not catalog or not catalog.libraries then
    return nil
  end
  local found_norm
  for _, lib in ipairs(catalog.libraries) do
    if lib.groupId == groupId and lib.artifactId == artifactId and not lib.note then
      local norm = lib.alias:gsub("[%-_%.]", ".")
      local resolved, ambiguous = catalog_library(catalog, "libs." .. norm)
      if resolved and not ambiguous then
        if found_norm and found_norm ~= norm then
          return nil
        end
        found_norm = norm
      end
    end
  end
  return found_norm and ("libs." .. found_norm) or nil
end

---@param dep table
---@param entry_indent string
---@param is_kotlin_dsl boolean
---@param style table|nil
---@return string
local function format_gradle_dependency_line(dep, entry_indent, is_kotlin_dsl, style)
  local conf = (dep.configuration and dep.configuration ~= "") and dep.configuration or "implementation"
  local coord = dep.groupId .. ":" .. dep.artifactId
  if dep.version and dep.version ~= "" then
    coord = coord .. ":" .. dep.version
  end
  if is_kotlin_dsl then
    return ('%s%s("%s")'):format(entry_indent, conf, coord)
  end
  local parens = style and style.parens or false
  local quote = (style and style.quote) or "'"
  if parens then
    return ("%s%s(%s%s%s)"):format(entry_indent, conf, quote, coord, quote)
  end
  return ("%s%s %s%s%s"):format(entry_indent, conf, quote, coord, quote)
end

---Insert one dependency into a Gradle build.gradle / build.gradle.kts text,
---preserving bytes, comments, style, indentation, and line endings.
---@param text string
---@param dep table { groupId, artifactId, version?, configuration? }
---@param opts { is_kotlin_dsl?: boolean, catalog?: table|nil, build_file?: string|nil }|nil
---@return string|nil new_text, table|nil meta, string|nil err
function M._insert_gradle_dependency(text, dep, opts)
  opts = opts or {}
  local is_kotlin_dsl = opts.is_kotlin_dsl == true
  local build_name = opts.build_file or (is_kotlin_dsl and "build.gradle.kts" or "build.gradle")

  if type(dep) ~= "table" then
    return nil, nil, "dependency must be a table"
  end
  if invalid_gradle_value(dep.groupId) then
    return nil, nil, "invalid groupId: " .. tostring(dep.groupId)
  end
  if invalid_gradle_value(dep.artifactId) then
    return nil, nil, "invalid artifactId: " .. tostring(dep.artifactId)
  end

  local conf = (dep.configuration ~= nil and dep.configuration ~= "") and dep.configuration or "implementation"
  if not GRADLE_EDIT_CONFIGS[conf] then
    return nil, nil, "unsupported Gradle configuration: " .. tostring(conf)
  end

  local version = (dep.version ~= nil and dep.version ~= "") and dep.version or nil
  if version and invalid_gradle_value(version) then
    return nil, nil, "invalid version: " .. tostring(version)
  end

  local analysis = M._analyze_gradle(text or "", is_kotlin_dsl, opts.catalog)
  if analysis.unsupported_reason then
    return nil, nil, analysis.unsupported_reason
  end

  if not version and not analysis.has_bom then
    return nil,
      nil,
      ("a version is required: no platform/BOM declaration for %s:%s was found in %s"):format(
        dep.groupId,
        dep.artifactId,
        build_name
      )
  end

  for _, existing in ipairs(analysis.deps) do
    if existing.groupId == dep.groupId and existing.artifactId == dep.artifactId then
      local via = existing.catalog_accessor and (" (via " .. existing.catalog_accessor .. ")") or ""
      return nil, nil, ("%s:%s is already declared in %s%s"):format(dep.groupId, dep.artifactId, build_name, via)
    end
  end

  local eol = (text or ""):find("\r\n", 1, true) and "\r\n" or "\n"
  local normalized_dep = {
    groupId = dep.groupId,
    artifactId = dep.artifactId,
    version = version,
    configuration = conf,
  }

  local meta = {
    created_section = false,
    version_omitted = version == nil,
    configuration = conf,
    bom_note = nil,
    catalog_note = nil,
    rendered_line = nil,
  }
  if meta.version_omitted then
    meta.bom_note =
      "a platform/BOM declaration was detected, but textual inspection cannot prove it manages this artifact"
  end

  local catalog_accessor = find_catalog_accessor(opts.catalog, dep.groupId, dep.artifactId)
  if catalog_accessor then
    meta.catalog_note = ("catalog alias %s exists in gradle/libs.versions.toml (inserting literal coordinate; catalog is read-only)"):format(
      catalog_accessor
    )
  end

  local new_text
  local block_info = analysis.dependencies_block
  if block_info then
    local entry_indent = block_info.entry_indent or (block_info.block_indent .. analysis.unit)
    local line = format_gradle_dependency_line(normalized_dep, entry_indent, is_kotlin_dsl, block_info.style)
    meta.rendered_line = line

    local line_start, lead = line_lead(text, block_info.close_brace_pos)
    local inner = text:sub(block_info.open_brace_pos + 1, block_info.close_brace_pos - 1)
    if lead:match("^[ \t]*$") and not inner:match("^[ \t]*$") then
      new_text = text:sub(1, line_start - 1) .. line .. eol .. text:sub(line_start)
    else
      new_text = text:sub(1, block_info.close_brace_pos - 1)
        .. eol
        .. line
        .. eol
        .. block_info.block_indent
        .. text:sub(block_info.close_brace_pos)
    end
  else
    meta.created_section = true
    local line = format_gradle_dependency_line(normalized_dep, analysis.unit, is_kotlin_dsl, nil)
    meta.rendered_line = line
    local section = table.concat({
      "dependencies {",
      line,
      "}",
    }, eol)
    if text == "" then
      new_text = section .. eol
    elseif text:sub(-#eol) == eol then
      if text:sub(-(#eol * 2)) == eol .. eol then
        new_text = text .. section .. eol
      else
        new_text = text .. eol .. section .. eol
      end
    else
      new_text = text .. eol .. eol .. section
    end
  end

  return new_text, meta, nil
end

---Check whether `target` can be safely edited by `deps.lua`.
---@param target table|nil result of _resolve_target
---@return boolean can_edit, string|nil reason, table|nil analysis, string|nil text, table|nil catalog
function M._can_edit_target(target)
  if not target or not target.build_file then
    return false, NO_PROJECT_REASON
  end

  if target.tool == "maven" then
    local stat = vim.uv.fs_lstat(target.build_file)
    if not stat then
      return false, "pom.xml does not exist"
    end
    if stat.type == "link" then
      return false, "pom.xml is a symlink — refusing to modify"
    end
    if stat.type ~= "file" then
      return false, "pom.xml is not a regular file"
    end
    return true, nil
  end

  if target.ambiguous_build_files then
    return false, "both build.gradle and build.gradle.kts exist — ambiguous build file"
  end
  if target.missing_module_build_file then
    return false, "selected module has no build.gradle or build.gradle.kts"
  end

  for _, fname in ipairs({ "build.gradle", "build.gradle.kts" }) do
    local mod_stat = vim.uv.fs_lstat(target.module .. "/" .. fname)
    if mod_stat and mod_stat.type == "link" then
      return false, fname .. " is a symlink — refusing to modify"
    end
  end

  local name = vim.fs.basename(target.build_file)
  local stat = vim.uv.fs_lstat(target.build_file)
  if not stat then
    return false, name .. " does not exist"
  end
  if stat.type == "link" then
    return false, name .. " is a symlink — refusing to modify"
  end
  if stat.type ~= "file" then
    return false, name .. " is not a regular file"
  end

  local text, read_err = read_regular_file(target.build_file)
  if not text then
    return false, read_err or ("could not read " .. target.build_file)
  end

  local catalog
  if target.catalog_file then
    catalog = M._parse_version_catalog(read_file(target.catalog_file) or "")
  end

  local analysis = M._analyze_gradle(text, target.is_kotlin_dsl, catalog)
  if analysis.unsupported_reason then
    return false, analysis.unsupported_reason, analysis, text, catalog
  end
  return true, nil, analysis, text, catalog
end

-- ---------- JDTLS sync (H1: java/projectConfigurationUpdate) ----------

---eclipse.jdt.ls >= 1.63 declares the `java/projectConfigurationUpdate` handler
---as `void` (it starts an async job and returns). LSP4J then answers the LSP
---*request* with an "Internal error" whose data carries "Local endpoint returned
---null from its request method", even though the configuration job did start
---(the "Updating project configurations" progress is emitted). Older servers
---declare it as a CompletableFuture request and answer with no error. This
---framing artifact is not a failed re-import.
---@param err table|nil
---@return boolean
local function void_handler_reframe(err)
  if type(err) ~= "table" or err.message ~= "Internal error." then
    return false
  end
  local data = err.data
  if type(data) == "table" then
    data = vim.inspect(data)
  end
  return type(data) == "string" and data:find("Local endpoint returned null from its request method", 1, true) ~= nil
end

---Ask the JDTLS client attached to `bufnr` to re-import the build file.
---Without a client the request is never issued.
---@param bufnr integer
---@param build_file string
---@param on_done fun(ok: boolean, err: string|nil)|nil
---@return boolean started, string|nil reason
function M._sync_jdtls(bufnr, build_file, on_done)
  local client = require("java_menu.lsp").client(bufnr)
  if not client then
    if on_done then
      pcall(on_done, false, NO_CLIENT_REASON)
    end
    return false, NO_CLIENT_REASON
  end

  client:request("java/projectConfigurationUpdate", { uri = vim.uri_from_fname(build_file) }, function(err)
    vim.schedule(function()
      if not on_done then
        return
      end
      if void_handler_reframe(err) then
        on_done(true, nil)
        return
      end
      on_done(err == nil, err and err.message or nil)
    end)
  end, bufnr)

  return true, nil
end

-- ---------- report ----------

---@param dep table
---@return string
local function dependency_label(dep)
  local label = ("%s:%s"):format(dep.groupId, dep.artifactId)
  if dep.version then
    label = label .. ":" .. dep.version
  end
  return label
end

---@param profile table
---@return string
local function profile_label(profile)
  return (profile and profile.id and profile.id ~= "") and profile.id or "(unnamed)"
end

---@param activation table|nil
---@return string
local function profile_activation_label(activation)
  if not activation then
    return "no <activation> declared"
  end
  local parts = {}
  if activation.active_by_default ~= nil then
    parts[#parts + 1] = "activeByDefault=" .. tostring(activation.active_by_default)
  end
  for _, trig in ipairs(activation.triggers or {}) do
    parts[#parts + 1] = trig
  end
  if #parts == 0 then
    parts[#parts + 1] = "declared"
  end
  return "activation: " .. table.concat(parts, ", ") .. " — not evaluated"
end

---@param parsed table
---@return string
local function format_parent_line(parsed)
  if not parsed.has_parent then
    return "Parent: none"
  end
  local p = parsed.parent
  if p and p.groupId and p.artifactId then
    local coord = p.groupId .. ":" .. p.artifactId .. (p.version and (":" .. p.version) or "")
    local extra = p.relativePath and ("; relativePath=" .. p.relativePath) or ""
    return ("Parent: %s (declared in pom.xml%s — inherited dependencies and dependencyManagement are not resolved)"):format(
      coord,
      extra
    )
  end
  return "Parent: declared (<parent> in pom.xml; coordinates incomplete — inherited dependencies and dependencyManagement are not resolved)"
end

---@param parsed table
---@return string
local function format_bom_line(parsed)
  local profile_boms = {}
  for _, prof in ipairs(parsed.profiles or {}) do
    if prof.has_bom then
      profile_boms[#profile_boms + 1] = profile_label(prof)
    end
  end
  if parsed.has_bom then
    local extra = #profile_boms > 0 and ("; also in profile(s): " .. table.concat(profile_boms, ", ")) or ""
    return ("BOM: import detected (%d in project <dependencyManagement> — imported POMs are not resolved; textual inspection cannot prove per-artifact coverage%s)"):format(
      #(parsed.bom_imports or {}),
      extra
    )
  end
  if #profile_boms > 0 then
    return ("BOM: none at project level (import detected in profile %s — conditional; imported POMs are not resolved; textual inspection cannot prove per-artifact coverage)"):format(
      table.concat(profile_boms, ", ")
    )
  end
  return "BOM: none"
end

---@param parsed table
---@return string
local function format_profiles_line(parsed)
  if not parsed.has_profiles then
    return "Profiles: none"
  end
  local count = #(parsed.profiles or {})
  if count == 0 then
    return "Profiles: present (0 declared — empty or commented-only <profiles> section)"
  end
  return ("Profiles: present (%d declared — conditional; activation is not evaluated)"):format(count)
end

---@param parsed table
---@param current_profile table|nil
---@return string[] all_boms, string[] other_boms
local function profile_bom_labels(parsed, current_profile)
  local all_boms, other_boms = {}, {}
  for _, prof in ipairs(parsed.profiles or {}) do
    if prof.has_bom then
      if prof == current_profile then
        all_boms[#all_boms + 1] = ("profile %q BOM import(s)"):format(profile_label(prof))
      else
        local label = ("profile %q BOM import(s) (conditional)"):format(profile_label(prof))
        all_boms[#all_boms + 1] = label
        other_boms[#other_boms + 1] = label
      end
    end
  end
  return all_boms, other_boms
end

---@param parsed table
---@param profile table|nil
---@return string[]
local function unverified_sources_for(parsed, profile)
  local unverified = {}
  if parsed.has_parent then
    unverified[#unverified + 1] = "<parent>"
  end
  if parsed.has_bom then
    unverified[#unverified + 1] = "project BOM import(s)"
  end
  for _, label in ipairs(profile_bom_labels(parsed, profile)) do
    unverified[#unverified + 1] = label
  end
  return unverified
end

---@param parsed table
---@param dep table
---@param current_profile table|nil
---@return table[]
local function collect_other_profile_dms(parsed, dep, current_profile)
  local matches = {}
  for _, prof in ipairs(parsed.profiles or {}) do
    if prof ~= current_profile then
      local entry = find_exact_managed_entry(prof.managed, dep.groupId, dep.artifactId, dep.type, dep.classifier)
      if entry then
        matches[#matches + 1] = { profile = prof, entry = entry }
      end
    end
  end
  return matches
end

---@param matches table[]
---@return string
local function format_profile_dm_candidates(matches)
  local parts = {}
  for _, match in ipairs(matches) do
    parts[#parts + 1] = ("%q (%s)"):format(profile_label(match.profile), match.entry.version or "no <version>")
  end
  return table.concat(parts, ", ")
end

---@param matches table[]
---@param base_version string
---@return boolean
local function has_overriding_profile_dm(matches, base_version)
  for _, match in ipairs(matches) do
    local ver = match.entry.version
    if ver and ver ~= "" and ver ~= base_version then
      return true
    end
  end
  return false
end

---@param parsed table
---@param dep table
---@param profile table|nil
---@return string[]
local function maven_dependency_detail(parsed, dep, profile)
  local detail = {}
  if dep.scope then
    detail[#detail + 1] = "scope=" .. dep.scope
  end
  if dep.type then
    detail[#detail + 1] = "type=" .. dep.type
  end
  if dep.classifier then
    detail[#detail + 1] = "classifier=" .. dep.classifier
  end
  if dep.optional then
    detail[#detail + 1] = "optional=" .. dep.optional
  end

  local proj_dm = find_exact_managed_entry(parsed.managed, dep.groupId, dep.artifactId, dep.type, dep.classifier)
  local own_prof_dm = profile
      and find_exact_managed_entry(profile.managed, dep.groupId, dep.artifactId, dep.type, dep.classifier)
    or nil
  local other_profile_dms = collect_other_profile_dms(parsed, dep, profile)

  if dep.version then
    if dep.version:match("%${.-}") then
      detail[#detail + 1] = "version property not evaluated"
    end
    local primary_dm = (own_prof_dm and own_prof_dm.version) and own_prof_dm or proj_dm
    local primary_source = (own_prof_dm and own_prof_dm.version)
        and ("profile %q <dependencyManagement>"):format(profile_label(profile))
      or "project <dependencyManagement>"
    if primary_dm and primary_dm.version then
      if primary_dm.version ~= dep.version then
        detail[#detail + 1] = ("explicit <version>; %s declares %s"):format(primary_source, primary_dm.version)
      else
        detail[#detail + 1] = ("explicit <version>; also declared in %s"):format(primary_source)
      end
    end
    return detail
  end

  local all_profile_boms, other_profile_boms = profile_bom_labels(parsed, profile)

  if own_prof_dm and own_prof_dm.version then
    local uncertain = #other_profile_boms > 0 or has_overriding_profile_dm(other_profile_dms, own_prof_dm.version)
    local msg
    if uncertain then
      msg = ("managed candidate in profile %q <dependencyManagement>: %s (conditional"):format(
        profile_label(profile),
        own_prof_dm.version
      )
      if proj_dm and proj_dm.version and proj_dm.version ~= own_prof_dm.version then
        msg = msg .. ("; overrides project <dependencyManagement> %s"):format(proj_dm.version)
      end
      msg = msg .. ")"
      if #other_profile_dms > 0 then
        msg = msg
          .. "; other active profile(s) may also manage/override: "
          .. format_profile_dm_candidates(other_profile_dms)
      end
      if #other_profile_boms > 0 then
        msg = msg .. "; unverified: " .. table.concat(other_profile_boms, ", ") .. " not resolved"
      end
      msg = msg .. " — effective version not proven"
    else
      msg = ("version=%s, managed by profile %q <dependencyManagement>; conditional"):format(
        own_prof_dm.version,
        profile_label(profile)
      )
      if proj_dm and proj_dm.version and proj_dm.version ~= own_prof_dm.version then
        msg = msg .. ("; overrides project <dependencyManagement> %s"):format(proj_dm.version)
      end
      if #other_profile_dms > 0 then
        msg = msg
          .. "; also matched in profile <dependencyManagement>: "
          .. format_profile_dm_candidates(other_profile_dms)
      end
    end
    if own_prof_dm.version:match("%${.-}") then
      msg = msg .. "; version property not evaluated"
    end
    detail[#detail + 1] = msg
    return detail
  end

  if proj_dm and proj_dm.version then
    local own_no_ver = own_prof_dm
        and ("profile %q <dependencyManagement> matched without <version>"):format(profile_label(profile))
      or nil
    local uncertain = #all_profile_boms > 0 or has_overriding_profile_dm(other_profile_dms, proj_dm.version)
    local msg
    if uncertain then
      msg = ("managed candidate in project <dependencyManagement>: %s"):format(proj_dm.version)
      if own_no_ver then
        msg = msg .. "; " .. own_no_ver
      end
      if #other_profile_dms > 0 then
        msg = msg
          .. "; conditional override in profile <dependencyManagement>: "
          .. format_profile_dm_candidates(other_profile_dms)
          .. " (activation not evaluated)"
      end
      if #all_profile_boms > 0 then
        msg = msg .. "; unverified: " .. table.concat(all_profile_boms, ", ") .. " not resolved"
      end
      msg = msg .. " — effective version not proven"
    else
      msg = ("version=%s, managed by project <dependencyManagement>"):format(proj_dm.version)
      if own_no_ver then
        msg = msg .. "; " .. own_no_ver
      end
      if #other_profile_dms > 0 then
        msg = msg
          .. "; also matched in profile <dependencyManagement>: "
          .. format_profile_dm_candidates(other_profile_dms)
          .. " (activation not evaluated)"
      end
    end
    if proj_dm.version:match("%${.-}") then
      msg = msg .. "; version property not evaluated"
    end
    detail[#detail + 1] = msg
    return detail
  end

  local unverified = unverified_sources_for(parsed, profile)
  local matched_no_ver_source
  if own_prof_dm then
    matched_no_ver_source = ("profile %q <dependencyManagement>"):format(profile_label(profile))
  elseif proj_dm then
    matched_no_ver_source = "project <dependencyManagement>"
  end

  if matched_no_ver_source then
    if #unverified > 0 or #other_profile_dms > 0 then
      local msg = ("version unspecified locally; matched in %s without <version>"):format(matched_no_ver_source)
      if #unverified > 0 then
        msg = msg .. "; unverified: " .. table.concat(unverified, ", ") .. " not resolved"
      end
      if #other_profile_dms > 0 then
        msg = msg
          .. "; conditional match in profile <dependencyManagement>: "
          .. format_profile_dm_candidates(other_profile_dms)
          .. " (activation not evaluated)"
      end
      detail[#detail + 1] = msg
    else
      detail[#detail + 1] = ("version missing; matched in %s without <version> and no BOM import or <parent> in pom.xml"):format(
        matched_no_ver_source
      )
    end
    return detail
  end

  if #unverified > 0 then
    local msg = ("version unspecified locally; unverified: %s not resolved"):format(table.concat(unverified, ", "))
    if #other_profile_dms > 0 then
      msg = msg
        .. "; conditional match in profile <dependencyManagement>: "
        .. format_profile_dm_candidates(other_profile_dms)
        .. " (activation not evaluated)"
    end
    detail[#detail + 1] = msg
  elseif #other_profile_dms > 0 then
    local scope_desc = profile and ("in profile %q and project"):format(profile_label(profile)) or "at project level"
    detail[#detail + 1] = ("version missing %s; conditional match in profile <dependencyManagement>: %s (activation not evaluated)"):format(
      scope_desc,
      format_profile_dm_candidates(other_profile_dms)
    )
  else
    detail[#detail + 1] =
      "version missing (no <version>, exact <dependencyManagement>, BOM import, or <parent> in pom.xml)"
  end
  return detail
end

---@param lines string[]
---@param indent string
---@param parsed table
---@param deps_list table[]
---@param profile table|nil
local function append_maven_deps_lines(lines, indent, parsed, deps_list, profile)
  if #deps_list == 0 then
    lines[#lines + 1] = indent .. "(none)"
    return
  end
  for _, dep in ipairs(deps_list) do
    local detail = maven_dependency_detail(parsed, dep, profile)
    lines[#lines + 1] = indent
      .. "- "
      .. dependency_label(dep)
      .. (#detail > 0 and ("  (" .. table.concat(detail, ", ") .. ")") or "")
  end
end

---@param lines string[]
---@param indent string
---@param entries table[]
---@param provenance_label string
---@param project_managed table[]|nil
local function append_maven_managed_lines(lines, indent, entries, provenance_label, project_managed)
  for _, entry in ipairs(entries) do
    local detail = {}
    if entry.type then
      detail[#detail + 1] = "type=" .. entry.type
    end
    if entry.classifier then
      detail[#detail + 1] = "classifier=" .. entry.classifier
    end
    if entry.scope then
      detail[#detail + 1] = "scope=" .. entry.scope
    end
    local is_bom = entry.type == "pom" and entry.scope == "import"
    if is_bom then
      detail[#detail + 1] = "BOM import — managed artifacts not resolved"
    elseif entry.version then
      detail[#detail + 1] = "provenance: " .. provenance_label
      if entry.version:match("%${.-}") then
        detail[#detail + 1] = "version property not evaluated"
      end
      if project_managed then
        local proj_entry =
          find_exact_managed_entry(project_managed, entry.groupId, entry.artifactId, entry.type, entry.classifier)
        if proj_entry and proj_entry.version and proj_entry.version ~= entry.version then
          detail[#detail + 1] = "overrides project <dependencyManagement> " .. proj_entry.version .. " when active"
        end
      end
    else
      detail[#detail + 1] = "no <version> declared in " .. provenance_label
    end
    lines[#lines + 1] = indent
      .. "- "
      .. dependency_label(entry)
      .. (#detail > 0 and ("  (" .. table.concat(detail, ", ") .. ")") or "")
  end
end

---Read-only Dependencies report lines. Pure: only reads the build files.
---@param target table result of _resolve_target
---@return string[]
function M._report_lines(target)
  local lines = {
    "Root: " .. target.root,
    "Module: " .. relpath(target.root, target.module),
    "Build file: " .. relpath(target.root, target.build_file),
  }

  if target.tool == "maven" then
    local text = read_file(target.build_file) or ""
    local parsed = M._parse_pom(text)

    lines[#lines + 1] = format_parent_line(parsed)
    local managed_count = #parsed.managed
    lines[#lines + 1] = ("Dependency management: %d entr%s"):format(managed_count, managed_count == 1 and "y" or "ies")
    lines[#lines + 1] = format_bom_line(parsed)
    lines[#lines + 1] = format_profiles_line(parsed)

    lines[#lines + 1] = ("Dependencies: %d"):format(#parsed.deps)
    append_maven_deps_lines(lines, "  ", parsed, parsed.deps, nil)

    if managed_count > 0 then
      lines[#lines + 1] = "Managed entries:"
      append_maven_managed_lines(lines, "  ", parsed.managed, "project <dependencyManagement>", nil)
    end

    if #(parsed.profiles or {}) > 0 then
      lines[#lines + 1] = "Profile declarations (conditional — activation not evaluated):"
      for _, prof in ipairs(parsed.profiles) do
        local label = profile_label(prof)
        lines[#lines + 1] = ("  - Profile: %s  (%s)"):format(label, profile_activation_label(prof.activation))
        if prof.has_bom then
          lines[#lines + 1] = ("    BOM: import detected (%d in profile %q <dependencyManagement> — imported POMs are not resolved; textual inspection cannot prove per-artifact coverage)"):format(
            #(prof.bom_imports or {}),
            label
          )
        end
        if #prof.managed > 0 then
          lines[#lines + 1] = ("    Dependency management: %d entr%s"):format(
            #prof.managed,
            #prof.managed == 1 and "y" or "ies"
          )
          append_maven_managed_lines(
            lines,
            "      ",
            prof.managed,
            ("profile %q <dependencyManagement>"):format(label),
            parsed.managed
          )
        end
        lines[#lines + 1] = ("    Dependencies: %d"):format(#prof.deps)
        append_maven_deps_lines(lines, "      ", parsed, prof.deps, prof)
      end
    end
    return lines
  end

  -- Gradle: read-only static parse, honest about coverage.
  local catalog
  if target.catalog_file then
    catalog = M._parse_version_catalog(read_file(target.catalog_file) or "")
    lines[#lines + 1] = ("Version catalog: %s (%d librar%s)"):format(
      relpath(target.root, target.catalog_file),
      #catalog.libraries,
      #catalog.libraries == 1 and "y" or "ies"
    )
  else
    lines[#lines + 1] = "Version catalog: none"
  end

  local text = read_file(target.build_file) or ""
  local deps, notes
  if target.is_kotlin_dsl then
    deps, notes = M._parse_kotlin_gradle_dependencies(text, catalog)
  else
    deps, notes = M._parse_gradle_dependencies(text, catalog)
  end
  local kind_label = target.is_kotlin_dsl and "build.gradle.kts" or "build.gradle"
  lines[#lines + 1] = ("Dependencies: %d (static parse of %s)"):format(#deps, kind_label)
  if #deps == 0 then
    lines[#lines + 1] = "  (none found in the statically parsed configurations)"
  else
    for _, dep in ipairs(deps) do
      local detail = {}
      if dep.declared_version then
        detail[#detail + 1] = "declared version=" .. dep.declared_version
      end
      if dep.has_configuration_lambda then
        detail[#detail + 1] = "configuration lambda not evaluated"
      end
      if dep.note then
        detail[#detail + 1] = dep.note
      end
      lines[#lines + 1] = "  - "
        .. dep.configuration
        .. " "
        .. dependency_label(dep)
        .. (#detail > 0 and ("  (" .. table.concat(detail, ", ") .. ")") or "")
    end
  end
  local has_catalog_notes = catalog and catalog.notes and #catalog.notes > 0
  if #notes > 0 or has_catalog_notes then
    local flavor = target.is_kotlin_dsl and "Kotlin DSL" or "Gradle"
    lines[#lines + 1] = ("Coverage: partial (dynamic/unsupported %s forms noted below)"):format(flavor)
  end
  for _, note in ipairs(notes) do
    lines[#lines + 1] = "Note: " .. note
  end

  if catalog and #catalog.libraries > 0 then
    lines[#lines + 1] = "Catalog libraries:"
    for _, lib in ipairs(catalog.libraries) do
      if lib.groupId then
        local suffix = lib.note and ("  (" .. lib.note .. ")") or ""
        lines[#lines + 1] = "  - " .. lib.alias .. " " .. dependency_label(lib) .. suffix
      else
        lines[#lines + 1] = "  - " .. lib.alias .. " (" .. (lib.note or "unresolved") .. ")"
      end
    end
  end
  for _, note in ipairs(catalog and catalog.notes or {}) do
    lines[#lines + 1] = "Note: " .. note
  end

  return lines
end

---Open the read-only Dependencies report (closed with `q`).
---@param bufnr integer|nil
---@param target table|nil pre-resolved target (multi-module menu)
function M.list(bufnr, target)
  local ui = require("java_menu.ui")
  target = target or M._resolve_target(bufnr)
  if not target then
    ui.notify(NO_PROJECT_REASON, vim.log.levels.WARN)
    return
  end

  local lines = M._report_lines(target)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.b[buf].java_deps_title = "Dependencies"

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local height = math.min(#lines + 2, math.max(6, vim.o.lines - 4))
  vim.api.nvim_win_set_height(win, height)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, nowait = true })
  return buf
end

-- ---------- interactive add (Maven & bounded Gradle) ----------

---@param bom_info table
---@return string
local function version_hint(bom_info)
  if bom_info.exact_managed then
    return "optional — the artifact is declared in <dependencyManagement>"
  end
  if bom_info.has_bom then
    return "optional — a BOM import was detected (coverage cannot be verified textually)"
  end
  if bom_info.has_parent then
    return "optional — a <parent> is declared (coverage cannot be verified textually)"
  end
  if bom_info.has_profile_bom or bom_info.has_profile_dm then
    return "required — no unconditional parent, project BOM or project dependencyManagement entry (profile declarations are conditional)"
  end
  return "required — no parent, BOM or dependencyManagement entry for this artifact"
end

---@param analysis table
---@param build_label string
---@return string
local function gradle_version_hint(analysis, build_label)
  if analysis and analysis.has_bom then
    return "optional — a platform/BOM declaration was detected (coverage cannot be verified textually)"
  end
  return "required — no platform/BOM declaration in " .. build_label
end

local GRADLE_SCOPE_CHOICES = {
  "implementation (default)",
  "api",
  "testImplementation",
  "runtimeOnly",
  "compileOnly",
  "testCompileOnly",
  "testRuntimeOnly",
  "annotationProcessor",
  "testAnnotationProcessor",
  "Cancel",
}

local MAVEN_SCOPE_CHOICES = {
  "compile (default)",
  "test",
  "runtime",
  "provided",
  "Cancel",
}

---Interactive "Add dependency…" flow. Esc/nil at any step writes nothing.
---@param bufnr integer|nil
---@param target table|nil pre-resolved target
function M.add(bufnr, target)
  local ui = require("java_menu.ui")
  bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
  target = target or M._resolve_target(bufnr)
  if not target then
    ui.notify(NO_PROJECT_REASON, vim.log.levels.WARN)
    return
  end

  local can_edit, edit_reason, analysis, gradle_text, catalog = M._can_edit_target(target)
  if not can_edit then
    ui.notify(edit_reason or GRADLE_EDIT_REASON, vim.log.levels.WARN)
    return
  end

  local name = vim.fs.basename(target.build_file)
  for _, buf in ipairs(loaded_buffers(target.build_file)) do
    if vim.bo[buf].modified then
      ui.notify(name .. " has unsaved changes — save or discard them first", vim.log.levels.WARN)
      return
    end
  end

  local is_maven = target.tool == "maven"
  local text, parsed
  if is_maven then
    local read_err
    text, read_err = read_regular_file(target.build_file)
    if not text then
      ui.notify(read_err or ("could not read " .. target.build_file), vim.log.levels.ERROR)
      return
    end
    parsed = M._parse_pom(text)
  else
    text = gradle_text
  end

  local build_label = relpath(target.root, target.build_file)

  local function bom_info_of(group, artifact, dep_type, classifier)
    return build_bom_info(parsed, group, artifact, dep_type, classifier)
  end

  local step_confirm, step_scope, manual, search

  step_confirm = function(group, artifact, version, scope_or_conf)
    local ver = (version ~= nil and version ~= "") and version or nil
    local new_text, meta, err
    if is_maven then
      new_text, meta, err = M._insert_maven_dependency(text, {
        groupId = group,
        artifactId = artifact,
        version = ver,
        scope = (scope_or_conf ~= nil and scope_or_conf ~= "") and scope_or_conf or nil,
      })
    else
      new_text, meta, err = M._insert_gradle_dependency(text, {
        groupId = group,
        artifactId = artifact,
        version = ver,
        configuration = (scope_or_conf ~= nil and scope_or_conf ~= "") and scope_or_conf or "implementation",
      }, {
        is_kotlin_dsl = target.is_kotlin_dsl,
        catalog = catalog,
        build_file = build_label,
      })
    end
    if not new_text then
      ui.notify(err or "could not add the dependency", vim.log.levels.ERROR)
      return
    end

    local items = { "✔ Add dependency" }
    local no_ver_label = is_maven and " (no <version>)" or " (no version)"
    items[#items + 1] = "  " .. group .. ":" .. artifact .. (ver and (":" .. ver) or no_ver_label)
    if is_maven then
      if scope_or_conf and scope_or_conf ~= "" then
        items[#items + 1] = "  scope: " .. scope_or_conf
      end
      if meta.created_section then
        items[#items + 1] = "  a new <dependencies> section will be created"
      end
    else
      items[#items + 1] = "  configuration: " .. meta.configuration
      items[#items + 1] = "  preview: " .. trim(meta.rendered_line)
      items[#items + 1] = "  target: " .. build_label
      if meta.created_section then
        items[#items + 1] = "  a new dependencies { ... } section will be created"
      end
    end
    if meta.bom_note then
      items[#items + 1] = "  note: " .. meta.bom_note
    end
    if meta.catalog_note then
      items[#items + 1] = "  note: " .. meta.catalog_note
    end
    items[#items + 1] = "✖ Cancel"

    ui.pick_one(items, "Java: Dependencies — summary", function(choice)
      if choice ~= "✔ Add dependency" then
        return
      end
      local ok, write_err = M._write_build_file(target.build_file, new_text, { expected_text = text })
      if not ok then
        ui.notify(write_err or ("could not write " .. build_label), vim.log.levels.ERROR)
        return
      end

      local message = ("added %s:%s%s to %s"):format(group, artifact, ver and (":" .. ver) or "", build_label)
      if meta.bom_note then
        message = message .. " — " .. meta.bom_note
      end
      ui.notify(message)

      -- re-import only when a client is attached to this buffer (never start one)
      if require("java_menu.lsp").client(bufnr) then
        local started, sync_err = M._sync_jdtls(bufnr, target.build_file, function(synced, sync_reason)
          if not synced then
            ui.notify("JDTLS re-import failed: " .. tostring(sync_reason), vim.log.levels.WARN)
          end
        end)
        if not started then
          ui.notify("JDTLS re-import not started: " .. tostring(sync_err), vim.log.levels.WARN)
        end
      end
    end)
  end

  step_scope = function(group, artifact, version)
    local choices = is_maven and MAVEN_SCOPE_CHOICES or GRADLE_SCOPE_CHOICES
    local prompt = is_maven and "Java: Dependencies — scope" or "Java: Dependencies — configuration"
    ui.pick_one(choices, prompt, function(choice)
      if choice == nil or choice == "Cancel" then
        return
      end
      local chosen = trim((choice:gsub("%s*%b()", "")))
      if is_maven and chosen == "compile" then
        chosen = ""
      end
      step_confirm(group, artifact, version, chosen)
    end)
  end

  manual = function()
    ui.ask("Java: Dependencies — groupId", nil, function(group)
      if group == nil then
        return
      end
      group = trim(group)
      if group == "" then
        ui.notify("groupId is required", vim.log.levels.WARN)
        return
      end
      ui.ask("Java: Dependencies — artifactId", nil, function(artifact)
        if artifact == nil then
          return
        end
        artifact = trim(artifact)
        if artifact == "" then
          ui.notify("artifactId is required", vim.log.levels.WARN)
          return
        end
        local hint = is_maven and version_hint(bom_info_of(group, artifact))
          or gradle_version_hint(analysis, build_label)
        ui.ask("Java: Dependencies — version (" .. hint .. ")", nil, function(version)
          if version == nil then
            return
          end
          step_scope(group, artifact, trim(version))
        end)
      end)
    end)
  end

  search = function()
    ui.ask("Java: Dependencies — Maven Central search (groupId/artifactId)", nil, function(query)
      if query == nil then
        return
      end
      query = trim(query)
      if query == "" then
        return
      end
      M._search_maven(query, function(results, err)
        if err then
          ui.notify("Maven Central search failed: " .. tostring(err), vim.log.levels.ERROR)
          ui.pick_one({ "Enter manually", "Cancel" }, "Java: Dependencies — search failed", function(choice)
            if choice == "Enter manually" then
              manual()
            end
          end)
          return
        end
        if not results or #results == 0 then
          ui.notify("no results for '" .. query .. "' on Maven Central", vim.log.levels.WARN)
          ui.pick_one({ "Enter manually", "Cancel" }, "Java: Dependencies — no results", function(choice)
            if choice == "Enter manually" then
              manual()
            end
          end)
          return
        end

        local labels, by_label = {}, {}
        for _, result in ipairs(results) do
          local label = ("%s:%s:%s"):format(result.groupId, result.artifactId, result.version or "?")
          if result.packaging and result.packaging ~= "jar" then
            label = label .. " (" .. result.packaging .. ")"
          end
          labels[#labels + 1] = label
          by_label[label] = result
        end
        ui.pick_one(labels, "Java: Dependencies — Maven Central results", function(choice)
          local result = choice and by_label[choice]
          if not result then
            return
          end
          step_scope(result.groupId, result.artifactId, trim(result.version or ""))
        end)
      end)
    end)
  end

  local http_tool = M._http_tool()
  ui.menu(
    {
      {
        key = "search",
        label = "Search Maven Central…",
        enabled = http_tool ~= nil,
        reason = "curl or wget is required for Maven Central search",
      },
      { key = "manual", label = "Enter coordinates manually…", enabled = true },
    },
    "Java: Dependencies — add",
    function(entry)
      if entry.key == "search" then
        search()
      elseif entry.key == "manual" then
        manual()
      end
    end
  )
end

-- ---------- menu ----------

---@param bufnr integer
---@param target table
local function menu_for(bufnr, target)
  local ui = require("java_menu.ui")
  local client = require("java_menu.lsp").client(bufnr)

  local open_label = "Open build file"
  if target.tool == "maven" then
    open_label = "Open pom.xml"
  elseif target.is_kotlin_dsl then
    open_label = "Open build.gradle.kts"
  else
    open_label = "Open build.gradle"
  end

  local can_edit, edit_reason = M._can_edit_target(target)
  local entries = {
    { key = "list", label = "List dependencies…", enabled = true },
    {
      key = "add",
      label = "Add dependency…",
      enabled = can_edit,
      reason = edit_reason or GRADLE_EDIT_REASON,
    },
    { key = "open", label = open_label, enabled = true },
    { key = "sync", label = "Sync JDTLS", enabled = client ~= nil, reason = NO_CLIENT_REASON },
  }

  ui.menu(entries, "Java: Dependencies", function(entry)
    if entry.key == "list" then
      M.list(bufnr, target)
    elseif entry.key == "add" then
      M.add(bufnr, target)
    elseif entry.key == "open" then
      vim.cmd.edit(vim.fn.fnameescape(target.build_file))
    elseif entry.key == "sync" then
      local started, err = M._sync_jdtls(bufnr, target.build_file, function(synced, sync_reason)
        if synced then
          ui.notify("JDTLS project configuration updated")
        else
          ui.notify("JDTLS re-import failed: " .. tostring(sync_reason), vim.log.levels.WARN)
        end
      end)
      if not started then
        ui.notify(err or "could not request the JDTLS re-import", vim.log.levels.WARN)
      end
    end
  end)
end

---Run the Dependencies menu. In a multi-module project the module is chosen
---first (current module first); a single-module project goes straight to the
---entries.
---@param bufnr integer|nil
function M.menu(bufnr)
  local ui = require("java_menu.ui")
  bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()

  local target = M._resolve_target(bufnr)
  if not target then
    ui.notify(NO_PROJECT_REASON, vim.log.levels.WARN)
    return
  end

  if #target.modules > 1 then
    local ordered = { target.module }
    for _, mod in ipairs(target.modules) do
      if mod ~= target.module then
        ordered[#ordered + 1] = mod
      end
    end
    local labels, by_label = {}, {}
    for _, mod in ipairs(ordered) do
      local rel = relpath(target.root, mod)
      local label = (rel == "." or rel == mod) and "root" or rel
      if mod == target.module then
        label = label .. " (current)"
      end
      labels[#labels + 1] = label
      by_label[label] = mod
    end
    ui.pick_one(labels, "Java: Dependencies — module", function(choice)
      local mod = choice and by_label[choice]
      if not mod then
        return
      end
      local chosen = M._resolve_target(bufnr, mod)
      if chosen then
        menu_for(bufnr, chosen)
      end
    end)
    return
  end

  menu_for(bufnr, target)
end

return M
