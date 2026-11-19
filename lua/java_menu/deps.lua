-- java_menu/deps.lua
-- <leader>jp → Dependencies: inspect declared dependencies and add one to a
-- Maven pom.xml with surgical, byte-preserving edits.
--
-- Two layers, like create.lua:
--
--   * core  — pure, testable helpers exposed as M._*: comment-aware POM
--     scanning, dependencyManagement/BOM awareness, indentation detection,
--     insertion that preserves every byte outside the insertion point,
--     version-catalog/Gradle static parsing and the Maven Central helpers.
--   * shell — the read-only report and the interactive add flow. Cancelling
--     any step writes nothing; the write happens only after the final
--     confirmation and only for Maven.
--
-- Nothing here runs Maven/Gradle to edit files, installs anything, parses XML
-- with a real parser (comments are masked and byte offsets are kept, so the
-- original text is never re-serialized) or edits Gradle build files (read-only
-- MVP). The JDTLS re-import is the LSP request validated against nvim-jdtls
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
  runtimeOnly = true,
  annotationProcessor = true,
  testImplementation = true,
  testCompileOnly = true,
  testRuntimeOnly = true,
  classpath = true,
}

local MAVEN_SEARCH_BASE = "https://search.maven.org/solrsearch/select?q="

local NO_PROJECT_REASON = "no Maven/Gradle project from this directory"
local GRADLE_EDIT_REASON = "Gradle build file editing is not supported (read-only MVP) — use Open build file"
local NO_CLIENT_REASON = "jdtls is not attached to this buffer"

-- ---------- small helpers ----------

local function trim(value)
  return vim.trim(value or "")
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
  local data = ""
  if stat.size > 0 then
    local chunk, read_err = vim.uv.fs_read(fd, stat.size, 0)
    if not chunk then
      vim.uv.fs_close(fd)
      return nil, "could not read " .. path .. (read_err and (": " .. read_err) or "")
    end
    data = chunk
  end
  vim.uv.fs_close(fd)
  return data
end

---Loaded buffer whose real path is `path` (nil when it is not open).
---@param path string
---@return integer|nil
local function loaded_buffer(path)
  local target = vim.fs.normalize(vim.uv.fs_realpath(path) or path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.api.nvim_buf_is_loaded(buf) then
      local candidate = vim.fs.normalize(vim.uv.fs_realpath(name) or name)
      if candidate == target then
        return buf
      end
    end
  end
  return nil
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
  if tool == "maven" then
    build_file = module .. "/pom.xml"
  elseif vim.fn.filereadable(module .. "/build.gradle") == 1 then
    build_file = module .. "/build.gradle"
  elseif vim.fn.filereadable(module .. "/build.gradle.kts") == 1 then
    build_file = module .. "/build.gradle.kts"
    is_kotlin_dsl = true
  elseif vim.fn.filereadable(root .. "/build.gradle") == 1 then
    build_file = root .. "/build.gradle"
  elseif vim.fn.filereadable(root .. "/build.gradle.kts") == 1 then
    build_file = root .. "/build.gradle.kts"
    is_kotlin_dsl = true
  else
    build_file = module .. "/build.gradle"
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

---Mask whole `<tag ...>...</tag>` sections with equal-length spaces.
---@param text string
---@param tags string[]
---@return string
local function mask_blocks(text, tags)
  local out = text
  for _, tag in ipairs(tags) do
    local open_pattern = "<" .. tag .. "[%s>]"
    local close_tag = "</" .. tag .. ">"
    local init = 1
    while true do
      local open_s, open_e = out:find(open_pattern, init)
      if not open_s then
        break
      end
      local _, close_e = out:find(close_tag, open_e + 1, true)
      local stop = close_e or #out
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

---Fields of one `<dependency>` block (comments already masked).
---@param block string
---@return table
local function dependency_fields(block)
  local clean = block:gsub("<exclusions[^>]*>.-</exclusions>", function(match)
    return (match:gsub("[^\n]", " "))
  end)
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
    optional = field("optional"),
  }
end

---Collect `<dependency>` entries between two byte offsets of `text`.
---@param text string original POM
---@param from_pos integer
---@param to_pos integer
---@return table[]
local function collect_dependencies(text, from_pos, to_pos)
  local slice = text:sub(from_pos, to_pos)
  local masked = M._mask_xml(slice)
  local out = {}
  local init = 1
  while true do
    local _, open_e = masked:find("<dependency%s*>", init)
    if not open_e then
      break
    end
    local _, close_e = masked:find("</dependency>", open_e + 1, true)
    if not close_e then
      break
    end
    local fields = dependency_fields(slice:sub(open_e + 1, close_e - #"</dependency>"))
    if fields.groupId and fields.artifactId then
      out[#out + 1] = fields
    end
    init = close_e + 1
  end
  return out
end

---Parse the parts of a POM that matter for dependency insertion. Pure.
---@param text string
---@return { deps: table[], managed: table[], has_parent: boolean, has_bom: boolean, has_profiles: boolean }
function M._parse_pom(text)
  text = text or ""
  local masked = M._mask_xml(text)
  local no_profiles = mask_blocks(masked, { "build", "reporting", "profiles" })
  local no_project = mask_blocks(no_profiles, { "dependencyManagement" })

  -- project-level <dependencies>
  local deps = {}
  local open_s, open_e = no_project:find("<dependencies[^>]*>")
  if open_s then
    local close_s = no_project:find("</dependencies>", open_e + 1, true)
    if close_s then
      deps = collect_dependencies(text, open_e + 1, close_s - 1)
    end
  end

  -- dependencyManagement entries (build/reporting/profiles already masked)
  local managed = {}
  local init = 1
  while true do
    local _, dm_open_e = no_profiles:find("<dependencyManagement[^>]*>", init)
    if not dm_open_e then
      break
    end
    local dm_close_s, dm_close_e = no_profiles:find("</dependencyManagement>", dm_open_e + 1, true)
    if not dm_close_s then
      break
    end
    local inner_open_s, inner_open_e = no_profiles:find("<dependencies[^>]*>", dm_open_e + 1)
    if inner_open_s and inner_open_s < dm_close_s then
      local inner_close_s = no_profiles:find("</dependencies>", inner_open_e + 1, true)
      if inner_close_s and inner_close_s <= dm_close_s then
        for _, entry in ipairs(collect_dependencies(text, inner_open_e + 1, inner_close_s - 1)) do
          managed[#managed + 1] = {
            groupId = entry.groupId,
            artifactId = entry.artifactId,
            version = entry.version,
            type = entry.type,
            scope = entry.scope,
          }
        end
      end
    end
    init = dm_close_e + 1
  end

  local has_bom = false
  for _, entry in ipairs(managed) do
    if entry.type == "pom" and entry.scope == "import" then
      has_bom = true
      break
    end
  end

  return {
    deps = deps,
    managed = managed,
    has_parent = masked:find("<parent[%s>]") ~= nil,
    has_bom = has_bom,
    has_profiles = masked:find("<profiles[%s>]") ~= nil,
  }
end

---Is groupId:artifactId literally declared in dependencyManagement (a BOM
---import itself does not count)? This is the only textual proof that the
---artifact's version is managed.
---@param parsed table|nil result of _parse_pom
---@param groupId string
---@param artifactId string
---@return boolean
function M._is_exact_managed(parsed, groupId, artifactId)
  for _, entry in ipairs((parsed and parsed.managed) or {}) do
    if entry.groupId == groupId and entry.artifactId == artifactId then
      local bom_import = entry.type == "pom" and entry.scope == "import"
      if not bom_import then
        return true
      end
    end
  end
  return false
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
---@param dep table { groupId, artifactId, version?, scope? }
---@param bom_info { exact_managed: boolean, has_parent: boolean, has_bom: boolean }|nil
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
    return nil,
      ("a <version> is required: no <parent>, dependencyManagement entry or BOM import for %s:%s was found in pom.xml"):format(
        dep.groupId,
        dep.artifactId
      )
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

  local unit
  if masked:find("\n\t") then
    unit = "\t"
  else
    local min_spaces
    for line in masked:gmatch("\n([^\n]*)") do
      local spaces = line:match("^( +)<")
      if spaces and (min_spaces == nil or #spaces < min_spaces) then
        min_spaces = #spaces
      end
    end
    unit = min_spaces and string.rep(" ", min_spaces) or "  "
  end

  local section
  for line in masked:gmatch("\n([^\n]*)") do
    local indent = line:match("^(%s*)<modelVersion[%s>]")
      or line:match("^(%s*)<properties[%s>]")
      or line:match("^(%s*)<dependencies[%s>]")
    if indent and indent ~= "" then
      section = indent
      break
    end
  end
  section = section or unit

  local dep
  for line in masked:gmatch("\n([^\n]*)") do
    local indent = line:match("^(%s*)<dependency[%s>]")
    if indent then
      dep = indent
      break
    end
  end
  dep = dep or (section .. unit)

  return unit, section, dep
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
  local prefix = text:sub(1, pos - 1)
  local nl = prefix:match(".*()\n")
  local line_start = (nl and nl + 1) or 1
  local lead = text:sub(line_start, pos - 1)
  if lead:match("^[ \t]*$") then
    return text:sub(1, line_start - 1) .. block .. eol .. text:sub(line_start)
  end
  -- closing tag shares its line with content: give the block its own line
  return text:sub(1, pos - 1) .. eol .. block .. eol .. close_indent .. text:sub(pos)
end

---Insert one dependency into a POM text, preserving bytes and comments.
---@param text string
---@param dep table { groupId, artifactId, version?, scope? }
---@return string|nil new_text, table|nil meta, string|nil err
function M._insert_maven_dependency(text, dep)
  local parsed = M._parse_pom(text)
  local bom_info = {
    exact_managed = M._is_exact_managed(parsed, dep.groupId, dep.artifactId),
    has_parent = parsed.has_parent,
    has_bom = parsed.has_bom,
  }

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
  local scope = dep.scope
  if scope == "" then
    scope = nil
  end

  local inner = sibling .. unit
  local element = {
    sibling .. "<dependency>",
    inner .. "<groupId>" .. dep.groupId .. "</groupId>",
    inner .. "<artifactId>" .. dep.artifactId .. "</artifactId>",
  }
  if not version_omitted then
    element[#element + 1] = inner .. "<version>" .. dep.version .. "</version>"
  end
  if scope and scope ~= "compile" then
    element[#element + 1] = inner .. "<scope>" .. scope .. "</scope>"
  end
  element[#element + 1] = sibling .. "</dependency>"
  local block = table.concat(element, eol)

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
  local open_s, open_e = masked:find("<dependencies[^>]*>")
  if open_s then
    local close_s = masked:find("</dependencies>", open_e + 1, true)
    if not close_s then
      return nil, nil, "could not find the closing </dependencies> of the project dependencies in pom.xml"
    end
    new_text = insert_before_line(text, close_s, block, eol, section)
  else
    local project_close = masked:find("</project>", 1, true)
    if not project_close then
      return nil, nil, "could not find </project> in pom.xml"
    end
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

---Write a POM atomically, refusing to clobber unsaved buffer changes.
---@param pom_path string
---@param new_text string
---@return boolean|nil ok, string|nil err
function M._write_pom(pom_path, new_text)
  if type(pom_path) ~= "string" or pom_path == "" or type(new_text) ~= "string" then
    return nil, "pom path and content are required"
  end

  local buf = loaded_buffer(pom_path)
  if buf and vim.bo[buf].modified then
    return nil, "pom.xml has unsaved changes — save or discard them first"
  end

  local tmp = pom_path .. ".java-menu-tmp"
  local fd, open_err = vim.uv.fs_open(tmp, "w", 420)
  if not fd then
    return nil, "could not write a temporary file next to " .. pom_path .. (open_err and (": " .. open_err) or "")
  end
  local written, write_err = vim.uv.fs_write(fd, new_text, 0)
  vim.uv.fs_close(fd)
  if not written then
    vim.uv.fs_unlink(tmp)
    return nil, "could not write the POM content" .. (write_err and (": " .. write_err) or "")
  end

  local renamed, rename_err = vim.uv.fs_rename(tmp, pom_path)
  if not renamed then
    vim.uv.fs_unlink(tmp)
    return nil, "could not replace pom.xml" .. (rename_err and (": " .. rename_err) or "")
  end

  if buf and vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent edit!")
    end)
  end
  return true, nil
end

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
  local parts = {}
  for part in tostring(coord):gmatch("[^:]+") do
    parts[#parts + 1] = part
  end
  if #parts >= 3 then
    return { groupId = parts[1], artifactId = parts[2], version = parts[3] }
  end
  if #parts == 2 then
    return { groupId = parts[1], artifactId = parts[2] }
  end
  return nil
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
        if key then
          versions[key] = value
        elseif line:find("=", 1, true) then
          notes[#notes + 1] = "versions entry not understood: " .. line
        end
      elseif section == "libraries" then
        local alias, rest = line:match("^([%w%._%-]+)%s*=%s*(.+)$")
        if alias then
          local lib
          local coord = rest:match('^"(.-)"$')
          if coord then
            lib = split_coordinate(coord)
            if lib then
              lib.alias = alias
            else
              lib = { alias = alias, note = "unsupported coordinate: " .. coord }
            end
          elseif rest:find("^%b{}") then
            local module = rest:match('module%s*=%s*"([^"]+)"')
            local group = rest:match('group%s*=%s*"([^"]+)"')
            local name = rest:match('name%s*=%s*"([^"]+)"')
            local version = rest:match('version%s*=%s*"([^"]+)"')
            local ref = rest:match('version%s*%.%s*ref%s*=%s*"([^"]+)"')
            local group_id, artifact_id = group, name
            if module then
              local parsed = split_coordinate(module)
              if parsed then
                group_id, artifact_id = parsed.groupId, parsed.artifactId
                version = version or parsed.version
              end
            end
            if group_id and artifact_id then
              lib = { alias = alias, groupId = group_id, artifactId = artifact_id }
              if ref then
                if versions[ref] then
                  lib.version = versions[ref]
                else
                  lib.note = "unresolved version.ref: " .. ref
                end
              elseif version then
                lib.version = version
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

  return { versions = versions, libraries = libraries, by_alias = by_alias, notes = notes }
end

---Resolve a `libs.foo.bar` accessor against a parsed catalog.
---@param catalog table|nil
---@param accessor string
---@return table|nil
local function catalog_library(catalog, accessor)
  if not catalog or not catalog.by_alias then
    return nil
  end
  local name = accessor:gsub("^libs%.", ""):gsub("^libs$", "")
  local candidates = { name, (name:gsub("%.", "-")), (name:gsub("%.", "_")) }
  for _, candidate in ipairs(candidates) do
    if catalog.by_alias[candidate] then
      return catalog.by_alias[candidate]
    end
  end
  return nil
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
          local lib = catalog_library(catalog, accessor)
          if lib and lib.groupId then
            deps[#deps + 1] = {
              configuration = conf,
              groupId = lib.groupId,
              artifactId = lib.artifactId,
              version = lib.version,
              note = lib.note,
            }
            if lib.note then
              notes[#notes + 1] = accessor .. ": " .. lib.note
            end
          else
            notes[#notes + 1] = "catalog alias not resolved (no libs.versions.toml entry): " .. accessor
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

    lines[#lines + 1] = "Parent: " .. (parsed.has_parent and "declared (<parent> in pom.xml)" or "none")
    local managed_count = #parsed.managed
    lines[#lines + 1] = ("Dependency management: %d entr%s"):format(managed_count, managed_count == 1 and "y" or "ies")
    if parsed.has_bom then
      lines[#lines + 1] = "BOM: import detected — textual inspection cannot prove per-artifact coverage"
    end
    if parsed.has_profiles then
      lines[#lines + 1] = "Profiles: present (dependencies declared inside profiles are not listed)"
    end

    lines[#lines + 1] = ("Dependencies: %d"):format(#parsed.deps)
    if #parsed.deps == 0 then
      lines[#lines + 1] = "  (none)"
    else
      for _, dep in ipairs(parsed.deps) do
        local detail = {}
        if dep.scope then
          detail[#detail + 1] = "scope=" .. dep.scope
        end
        if dep.optional then
          detail[#detail + 1] = "optional=" .. dep.optional
        end
        lines[#lines + 1] = "  - "
          .. dependency_label(dep)
          .. (#detail > 0 and ("  (" .. table.concat(detail, ", ") .. ")") or "")
      end
    end

    if managed_count > 0 then
      lines[#lines + 1] = "Managed entries:"
      for _, entry in ipairs(parsed.managed) do
        local detail = {}
        if entry.type then
          detail[#detail + 1] = "type=" .. entry.type
        end
        if entry.scope then
          detail[#detail + 1] = "scope=" .. entry.scope
        end
        lines[#lines + 1] = "  - "
          .. dependency_label(entry)
          .. (#detail > 0 and ("  (" .. table.concat(detail, ", ") .. ")") or "")
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

  if target.is_kotlin_dsl then
    lines[#lines + 1] =
      "Kotlin DSL: static parsing of build.gradle.kts is not supported (deferred) — open the build file to inspect dependencies"
  else
    local deps, notes = M._parse_gradle_dependencies(read_file(target.build_file) or "", catalog)
    lines[#lines + 1] = ("Dependencies: %d (static parse of build.gradle)"):format(#deps)
    if #deps == 0 then
      lines[#lines + 1] = "  (none found in the statically parsed configurations)"
    else
      for _, dep in ipairs(deps) do
        lines[#lines + 1] = "  - " .. dep.configuration .. " " .. dependency_label(dep)
      end
    end
    for _, note in ipairs(notes) do
      lines[#lines + 1] = "Note: " .. note
    end
  end

  if catalog and #catalog.libraries > 0 then
    lines[#lines + 1] = "Catalog libraries:"
    for _, lib in ipairs(catalog.libraries) do
      if lib.groupId then
        lines[#lines + 1] = "  - " .. lib.alias .. " " .. dependency_label(lib)
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

-- ---------- interactive add (Maven only) ----------

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
  return "required — no parent, BOM or dependencyManagement entry for this artifact"
end

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
  if target.tool ~= "maven" then
    ui.notify(GRADLE_EDIT_REASON, vim.log.levels.WARN)
    return
  end

  local text, read_err = read_file(target.build_file)
  if not text then
    ui.notify(read_err or ("could not read " .. target.build_file), vim.log.levels.ERROR)
    return
  end
  local parsed = M._parse_pom(text)

  local function bom_info_of(group, artifact)
    return {
      exact_managed = M._is_exact_managed(parsed, group, artifact),
      has_parent = parsed.has_parent,
      has_bom = parsed.has_bom,
    }
  end

  local step_confirm, step_scope, manual, search

  step_confirm = function(group, artifact, version, scope)
    local dep = {
      groupId = group,
      artifactId = artifact,
      version = (version ~= nil and version ~= "") and version or nil,
      scope = (scope ~= nil and scope ~= "") and scope or nil,
    }
    local new_text, meta, err = M._insert_maven_dependency(text, dep)
    if not new_text then
      ui.notify(err or "could not add the dependency", vim.log.levels.ERROR)
      return
    end

    local items = { "✔ Add dependency" }
    items[#items + 1] = "  " .. group .. ":" .. artifact .. (dep.version and (":" .. dep.version) or " (no <version>)")
    if dep.scope then
      items[#items + 1] = "  scope: " .. dep.scope
    end
    if meta.created_section then
      items[#items + 1] = "  a new <dependencies> section will be created"
    end
    if meta.bom_note then
      items[#items + 1] = "  note: " .. meta.bom_note
    end
    items[#items + 1] = "✖ Cancel"

    ui.pick_one(items, "Java: Dependencies — summary", function(choice)
      if choice ~= "✔ Add dependency" then
        return
      end
      local ok, write_err = M._write_pom(target.build_file, new_text)
      if not ok then
        ui.notify(write_err or "could not write pom.xml", vim.log.levels.ERROR)
        return
      end

      local message = ("added %s:%s%s to %s"):format(
        group,
        artifact,
        dep.version and (":" .. dep.version) or "",
        relpath(target.root, target.build_file)
      )
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
    ui.pick_one(
      { "compile (default)", "test", "runtime", "provided", "Cancel" },
      "Java: Dependencies — scope",
      function(choice)
        if choice == nil or choice == "Cancel" then
          return
        end
        local scope = trim((choice:gsub("%s*%b()", "")))
        if scope == "compile" then
          scope = ""
        end
        step_confirm(group, artifact, version, scope)
      end
    )
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
        local hint = version_hint(bom_info_of(group, artifact))
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

  local entries = {
    { key = "list", label = "List dependencies…", enabled = true },
    {
      key = "add",
      label = "Add dependency…",
      enabled = target.tool == "maven",
      reason = GRADLE_EDIT_REASON,
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
