-- java_menu/create.lua
-- Project scaffolding for the Project menu: Plain Java, a minimal Maven layout
-- and a Spring Boot project downloaded from the official Spring Initializr.
-- Two layers:
--
--   * shell — the interactive flow (ui.menu / ui.pick_one / ui.ask). Cancelling
--     any step returns immediately and writes nothing.
--   * core  — pure, testable helpers (exposed as M._*): validation, the Main
--     class body, the POM, generation into a staging directory, publication
--     and rollback; plus the Spring path (URL building, metadata parsing, zip
--     listing validation, staged extraction) which never trusts the archive.
--
-- new.M.create() is NOT used for the scaffolding: it opens buffers
-- (vim.cmd.edit), writes immediately (vim.cmd.write) and works on the final
-- path — incompatible with staging, rollback and "no write before the final
-- confirmation". jc.nvim's "main" template is tried through
-- jc.templates.render (a data module without side effects) and a minimal
-- embedded body is used when jc is unavailable or when its output does not
-- match this scaffold's contract (jc 1.7.0 renders an empty main body and
-- relies on gg=G inside a buffer — here files are written straight to disk).
--
-- Nothing here changes the cwd, starts JDTLS, runs git or executes scripts.

local M = {}

local STAGE_SUFFIX = ".java-menu-stage"

-- Spring Initializr (H2): the metadata document and the project download. The
-- parameters below were verified against the live service.
local SPRING_METADATA_URL = "https://start.spring.io/metadata/client"
local SPRING_STARTER_URL = "https://start.spring.io/starter.zip"
local SPRING_METADATA_ACCEPT = "application/vnd.initializr.v2.2+json"

-- project types that build a full project (the "-build" variants only produce a
-- single build file and are filtered out of the picker)
local SPRING_PROJECT_TYPE = "^[a-z0-9%-]+%-project$"
local SPRING_PROJECT_TYPE_KOTLIN = "^[a-z0-9%-]+%-project%-kotlin$"

local BUILD_LABELS = {
  ["maven-project"] = "Maven",
  ["gradle-project"] = "Gradle (Groovy)",
  ["gradle-project-kotlin"] = "Gradle (Kotlin)",
}

-- short Java keyword list: enough to reject package segments that would not
-- compile (the full list of reserved words adds nothing here)
local KEYWORDS = {
  ["abstract"] = true,
  ["assert"] = true,
  ["boolean"] = true,
  ["break"] = true,
  ["byte"] = true,
  ["case"] = true,
  ["catch"] = true,
  ["char"] = true,
  ["class"] = true,
  ["const"] = true,
  ["continue"] = true,
  ["default"] = true,
  ["do"] = true,
  ["double"] = true,
  ["else"] = true,
  ["enum"] = true,
  ["extends"] = true,
  ["final"] = true,
  ["finally"] = true,
  ["float"] = true,
  ["for"] = true,
  ["goto"] = true,
  ["if"] = true,
  ["implements"] = true,
  ["import"] = true,
  ["instanceof"] = true,
  ["int"] = true,
  ["interface"] = true,
  ["long"] = true,
  ["native"] = true,
  ["new"] = true,
  ["package"] = true,
  ["private"] = true,
  ["protected"] = true,
  ["public"] = true,
  ["return"] = true,
  ["short"] = true,
  ["static"] = true,
  ["strictfp"] = true,
  ["super"] = true,
  ["switch"] = true,
  ["synchronized"] = true,
  ["this"] = true,
  ["throw"] = true,
  ["throws"] = true,
  ["transient"] = true,
  ["try"] = true,
  ["void"] = true,
  ["volatile"] = true,
  ["while"] = true,
}

local function is_dir(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---Realpath of the parent (the target is always built from it, so a symlinked
---parent cannot redirect the write).
---@param parent string|nil
---@return string
local function resolved_parent(parent)
  local real = vim.uv.fs_realpath(parent or "")
  return vim.fs.normalize(real or parent or "")
end

---@param parent string
---@param name string
---@return string target
local function target_of(parent, name)
  return parent .. "/" .. name
end

---@param pkg string|nil
---@return boolean
local function valid_package(pkg)
  if type(pkg) ~= "string" or pkg == "" then
    return false
  end
  if pkg:sub(1, 1) == "." or pkg:sub(-1) == "." or pkg:find("..", 1, true) then
    return false
  end
  for segment in pkg:gmatch("[^%.]+") do
    if not segment:match("^[A-Za-z_$][A-Za-z0-9_$]*$") or KEYWORDS[segment] then
      return false
    end
  end
  return true
end

---@param name string|nil
---@return boolean
local function valid_name(name)
  return type(name) == "string"
    and name ~= ""
    and name:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") ~= nil
    and name:sub(-1) ~= "."
end

---Validate the options without touching the filesystem (only reads).
---@param opts table { kind, parent, name, pkg, release, group?, artifact?, build_type?, boot_version?, packaging?, dependencies? }
---@return string|nil reason nil when the options are safe to use
function M._validate(opts)
  if type(opts) ~= "table" then
    return "invalid options"
  end
  if opts.kind ~= "plain" and opts.kind ~= "maven" and opts.kind ~= "spring" then
    return "invalid project kind: " .. tostring(opts.kind)
  end
  if not valid_name(opts.name) then
    return "invalid project name: "
      .. tostring(opts.name)
      .. " (letters, digits, '_', '-' and '.'; it cannot start or end with '.')"
  end
  if not valid_package(opts.pkg) then
    return "invalid package: " .. tostring(opts.pkg) .. " (Java identifiers separated by '.')"
  end
  if type(opts.release) ~= "string" or not opts.release:match("^[0-9]+$") then
    return "invalid Java release: " .. tostring(opts.release) .. " (expected a number)"
  end
  if opts.kind == "maven" or opts.kind == "spring" then
    if not valid_package(opts.group) then
      return "invalid groupId: " .. tostring(opts.group) .. " (Java identifiers separated by '.')"
    end
    if not valid_name(opts.artifact) then
      return "invalid artifactId: " .. tostring(opts.artifact)
    end
  end
  if opts.kind == "spring" then
    local build_type = opts.build_type
    if
      type(build_type) ~= "string"
      or not (build_type:match(SPRING_PROJECT_TYPE) or build_type:match(SPRING_PROJECT_TYPE_KOTLIN))
    then
      return "invalid Spring project type: "
        .. tostring(build_type)
        .. " (expected a project type such as maven-project, gradle-project or gradle-project-kotlin)"
    end
    if type(opts.boot_version) ~= "string" or not opts.boot_version:match("^[0-9A-Za-z._-]+$") then
      return "invalid Spring Boot version: " .. tostring(opts.boot_version)
    end
    if opts.packaging ~= "jar" and opts.packaging ~= "war" then
      return "invalid packaging: " .. tostring(opts.packaging) .. " (expected jar or war)"
    end
    if opts.dependencies ~= nil then
      if type(opts.dependencies) ~= "table" then
        return "invalid dependencies: expected a list of dependency ids"
      end
      for _, dep in ipairs(opts.dependencies) do
        if type(dep) ~= "string" or not dep:match("^[A-Za-z0-9._-]+$") then
          return "invalid dependency id: " .. tostring(dep)
        end
      end
    end
  end

  local parent = opts.parent
  if type(parent) ~= "string" or parent == "" then
    return "parent directory is required"
  end
  if parent:sub(1, 1) ~= "/" then
    return "parent directory must be absolute: " .. parent
  end
  parent = vim.fs.normalize(parent)
  local stat = vim.uv.fs_stat(parent)
  if not stat then
    return "parent directory does not exist: " .. parent
  end
  if stat.type ~= "directory" then
    return "parent is not a directory: " .. parent
  end
  if vim.fn.filewritable(parent) ~= 2 then
    return "parent directory is not writable: " .. parent
  end
  parent = resolved_parent(parent)

  local target = target_of(parent, opts.name)
  local target_stat = vim.uv.fs_lstat(target)
  if target_stat then
    if target_stat.type == "link" then
      return "target is a symlink, refusing to write through it: " .. target
    end
    if target_stat.type ~= "directory" then
      return "target exists and is not a directory: " .. target
    end
    local entries = vim.fn.readdir(target)
    if entries == nil then
      return "could not read target directory: " .. target
    end
    if #entries > 0 then
      return "target exists and is not empty: " .. target
    end
  end

  local stage = parent .. "/." .. opts.name .. STAGE_SUFFIX
  if vim.uv.fs_lstat(stage) then
    return "stale staging directory from a previous attempt: " .. stage .. " — remove it first"
  end
  return nil
end

---Source of Main.java. jc.nvim's public "main" template is used when its
---output already matches this scaffold (package + main + the greeting); the
---embedded body is the deterministic fallback and is what jc 1.7.0 ends up
---using, since its main template ships an empty body.
---@param pkg string
---@param name string
---@return string
function M._main_body(pkg, name)
  local ok, rendered = pcall(function()
    local templates = require("jc.templates")
    if type(templates.get) ~= "function" or type(templates.render) ~= "function" then
      error("jc.templates without get/render")
    end
    return templates.render("main", { name = name, package = pkg })
  end)
  if
    ok
    and type(rendered) == "string"
    and rendered ~= ""
    and rendered:find("static void main", 1, true)
    and rendered:find("package " .. pkg, 1, true)
    and rendered:find("Hello from " .. name .. "!", 1, true)
  then
    return rendered
  end

  -- fallback: minimal, deterministic and printable, so every freshly created
  -- project compiles and runs the same way
  return table.concat({
    "package " .. pkg .. ";",
    "",
    "public class Main {",
    "    public static void main(String[] args) {",
    '        System.out.println("Hello from ' .. name .. '!");',
    "    }",
    "}",
  }, "\n")
end

---Minimal deterministic pom.xml (no dependencies, no invented versions).
---@param opts table
---@return string[]
function M._pom(opts)
  return {
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<project xmlns="http://maven.apache.org/POM/4.0.0"',
    '         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
    '         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>" .. opts.group .. "</groupId>",
    "  <artifactId>" .. opts.artifact .. "</artifactId>",
    "  <version>1.0.0-SNAPSHOT</version>",
    "  <packaging>jar</packaging>",
    "  <properties>",
    "    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>",
    "    <maven.compiler.release>" .. opts.release .. "</maven.compiler.release>",
    "  </properties>",
    "</project>",
  }
end

---@param path string
---@param lines string[]
---@return boolean ok, string|nil err
local function write_lines(path, lines)
  if vim.fn.writefile(lines, path) ~= 0 then
    return false, "could not write " .. path
  end
  return true
end

---Create the project tree inside `stage` (never at the final target).
---@param opts table
---@param stage string
---@return boolean ok, string|nil err
function M._generate(opts, stage)
  local pkg_rel = opts.pkg:gsub("%.", "/")
  local dirs = { stage .. "/src/main/java/" .. pkg_rel }
  if opts.kind == "maven" then
    dirs[#dirs + 1] = stage .. "/src/main/resources"
    dirs[#dirs + 1] = stage .. "/src/test/java/" .. pkg_rel
  end
  for _, dir in ipairs(dirs) do
    vim.fn.mkdir(dir, "p")
    if not is_dir(dir) then
      return false, "could not create directory " .. dir
    end
  end

  local main_path = stage .. "/src/main/java/" .. pkg_rel .. "/Main.java"
  local ok, err = write_lines(main_path, vim.split(M._main_body(opts.pkg, opts.name), "\n", { plain = true }))
  if not ok then
    return false, err
  end
  if opts.kind == "maven" then
    ok, err = write_lines(stage .. "/pom.xml", M._pom(opts))
    if not ok then
      return false, err
    end
  end
  return true
end

---Publish the staged tree at `target`.
---A missing target is a single rename. An existing target (validated empty) is
---filled entry by entry; if a move fails, every entry created by this call is
---removed again and the rest of the staging directory is discarded. Nothing
---that existed before the operation is ever removed.
---@param stage string
---@param target string
---@return boolean ok, string|nil err, string[] moved
function M._publish(stage, target)
  local target_stat = vim.uv.fs_lstat(target)
  if not target_stat then
    local ok, err = vim.uv.fs_rename(stage, target)
    if not ok then
      return false, "could not move " .. stage .. " to " .. target .. ": " .. tostring(err), {}
    end
    return true, nil, {}
  end

  local moved = {}
  local names = vim.fn.readdir(stage) or {}
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, err = vim.uv.fs_rename(stage .. "/" .. name, target .. "/" .. name)
    if not ok then
      -- rollback: only the entries this publish created
      for i = #moved, 1, -1 do
        vim.fn.delete(target .. "/" .. moved[i], "rf")
      end
      vim.fn.delete(stage, "rf")
      return false, "could not move " .. name .. ": " .. tostring(err), moved
    end
    moved[#moved + 1] = name
  end
  vim.uv.fs_rmdir(stage)
  return true, nil, moved
end

---Validate, generate into a staging directory, publish and clean up.
---Only the offline kinds (plain, maven) are generated locally: a Spring Boot
---project comes from Spring Initializr (`M._extract_spring_zip`).
---@param opts table
---@return boolean ok, string|nil err
function M._run(opts)
  local reason = M._validate(opts)
  if reason then
    return false, reason
  end
  if opts.kind == "spring" then
    return false, "Spring Boot projects are downloaded from Spring Initializr, not generated locally"
  end

  local parent = resolved_parent(opts.parent)
  local stage = parent .. "/." .. opts.name .. STAGE_SUFFIX
  local target = target_of(parent, opts.name)

  vim.fn.mkdir(stage)
  if not is_dir(stage) then
    return false, "could not create staging directory " .. stage
  end

  local ok_call, ok_generate, gen_err = xpcall(M._generate, debug.traceback, opts, stage)
  if not ok_call or ok_generate ~= true then
    vim.fn.delete(stage, "rf")
    return false, "generation failed: " .. tostring(ok_call and gen_err or ok_generate)
  end

  local published, publish_err = M._publish(stage, target)
  if not published then
    if vim.uv.fs_lstat(stage) then
      vim.fn.delete(stage, "rf")
    end
    return false, publish_err
  end
  return true
end

---Summary shown before the final confirmation.
---@param opts table
---@return string[]
function M._summary_lines(opts)
  local parent = resolved_parent(opts.parent)
  local target = target_of(parent, opts.name)
  if opts.kind == "spring" then
    local deps = opts.dependencies or {}
    local lines = {
      "Kind: Spring Boot (" .. M._build_label(opts.build_type) .. ")",
      "Target: " .. target,
      "Spring Boot version: " .. tostring(opts.boot_version),
      "Packaging: " .. tostring(opts.packaging),
      "Java release: " .. tostring(opts.release),
      "groupId: " .. tostring(opts.group),
      "artifactId: " .. tostring(opts.artifact),
      "Package: " .. tostring(opts.pkg),
      "Dependencies: " .. (#deps > 0 and table.concat(deps, ", ") or "(none)"),
    }
    if vim.uv.fs_lstat(target) then
      lines[#lines + 1] =
        "WARNING: target already exists (empty directory) — it will be used and nothing will be removed"
    end
    return lines
  end
  local lines = {
    "Kind: " .. (opts.kind == "maven" and "Maven" or "Plain Java"),
    "Target: " .. target,
    "Package: " .. tostring(opts.pkg),
    "Java release: " .. tostring(opts.release),
  }
  if opts.kind == "maven" then
    lines[#lines + 1] = "groupId: " .. tostring(opts.group)
    lines[#lines + 1] = "artifactId: " .. tostring(opts.artifact)
  end
  if vim.uv.fs_lstat(target) then
    lines[#lines + 1] =
      "WARNING: target already exists (empty directory) — it will be used and nothing will be removed"
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Spring Boot (Spring Initializr)
--
-- The service is the only source of truth for versions, project types and
-- dependency ids; nothing is hard-coded here beyond the endpoint. The archive
-- itself is never trusted: its listing is validated (no `..`, no absolute or
-- drive paths, no symlinks/special entries) before anything is extracted, and
-- the extracted tree is checked again before it is published by rename.
-- ---------------------------------------------------------------------------

---@param text string|nil
---@return string
local function trim(text)
  return vim.trim(text or "")
end

---Split command output into lines, dropping only the trailing newline(s) so an
---internally empty line (an empty entry name) still reaches the validation.
---@param text string|nil
---@return string[]
local function listing_lines(text)
  local out = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  out = out:gsub("\n+$", "")
  if out == "" then
    return {}
  end
  return vim.split(out, "\n", { plain = true })
end

---Run an external command to completion.
---@param cmd string[]
---@param timeout integer|nil
---@return table|nil res, string|nil err
local function run_system(cmd, timeout)
  if vim.fn.executable(cmd[1]) == 0 then
    return nil, cmd[1] .. " is not available on PATH"
  end
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, timeout = timeout or 30000 }):wait()
  end)
  if not ok or type(res) ~= "table" then
    return nil, tostring(res)
  end
  return res
end

---@param res table|nil
---@param prefix string
---@return string
local function command_error(res, prefix)
  local stderr = res and trim(res.stderr) or ""
  if stderr == "" then
    return prefix .. " (exit " .. tostring(res and res.code or "unknown") .. ")"
  end
  return prefix .. ": " .. stderr
end

---Runtime prerequisites of the Spring path: an HTTP client (curl preferred,
---wget as fallback) and unzip. `has_exe` is injectable for the tests and
---defaults to `vim.fn.executable`.
---@param has_exe fun(tool: string): any|nil
---@return { ok: boolean, http: string|nil, unzip: boolean, reason: string|nil }
function M._spring_tools(has_exe)
  local exe = has_exe or vim.fn.executable
  local function has(tool)
    local found = exe(tool)
    return found == 1 or found == true
  end
  local http
  if has("curl") then
    http = "curl"
  elseif has("wget") then
    http = "wget"
  end
  local unzip = has("unzip")
  if not http and not unzip then
    return {
      ok = false,
      http = nil,
      unzip = false,
      reason = "curl (or wget) and unzip are required to download and extract a Spring Boot project",
    }
  end
  if not http then
    return {
      ok = false,
      http = nil,
      unzip = true,
      reason = "curl (or wget) is required to download a Spring Boot project",
    }
  end
  if not unzip then
    return {
      ok = false,
      http = http,
      unzip = false,
      reason = "unzip is required to extract the Spring Boot project",
    }
  end
  return { ok = true, http = http, unzip = true }
end

---Readable label of a Spring project type id.
---@param build_type string|nil
---@return string
function M._build_label(build_type)
  if type(build_type) ~= "string" or build_type == "" then
    return "Spring Boot"
  end
  return BUILD_LABELS[build_type] or build_type
end

---Percent-encode a query parameter value (unreserved characters stay as-is).
---@param str string
---@return string
function M._url_encode(str)
  return (tostring(str):gsub("[^A-Za-z0-9%-%._~]", function(char)
    return ("%%%02X"):format(char:byte())
  end))
end

---Deterministic starter.zip URL: the parameter order never depends on how the
---options table was built, and `dependencies` is omitted when empty.
---@param opts table
---@param base_url string|nil
---@return string
function M._spring_url(opts, base_url)
  local base = base_url or SPRING_STARTER_URL
  local params = {
    { "type", opts.build_type },
    { "language", "java" },
    { "bootVersion", opts.boot_version },
    { "groupId", opts.group },
    { "artifactId", opts.artifact },
    { "name", opts.name },
    { "packageName", opts.pkg },
    { "javaVersion", opts.release },
    { "packaging", opts.packaging },
  }
  local parts = {}
  for _, param in ipairs(params) do
    parts[#parts + 1] = param[1] .. "=" .. M._url_encode(param[2])
  end
  local deps = opts.dependencies or {}
  if #deps > 0 then
    local encoded = {}
    for _, dep in ipairs(deps) do
      encoded[#encoded + 1] = M._url_encode(dep)
    end
    -- the separator stays a literal comma: the service splits the list on it
    parts[#parts + 1] = "dependencies=" .. table.concat(encoded, ",")
  end
  return base .. "?" .. table.concat(parts, "&")
end

---@param section any
---@return { id: string, name: string }[]
local function select_values(section)
  local values = {}
  if type(section) == "table" and type(section.values) == "table" then
    for _, value in ipairs(section.values) do
      if type(value) == "table" and type(value.id) == "string" and value.id ~= "" then
        values[#values + 1] = {
          id = value.id,
          name = type(value.name) == "string" and value.name or value.id,
        }
      end
    end
  end
  return values
end

---Parse and normalize the Spring Initializr client metadata.
---Project types are filtered to full projects (`*-project`, `*-project-kotlin`)
---with `maven-project` first; the metadata default of each single-select
---section comes first; dependencies are flattened with their group name.
---@param json_text string
---@return table|nil meta, string|nil err
function M._parse_metadata(json_text)
  if type(json_text) ~= "string" or trim(json_text) == "" then
    return nil, "empty Spring Initializr metadata"
  end
  local ok, data = pcall(vim.json.decode, json_text)
  if not ok or type(data) ~= "table" then
    return nil, "could not parse the Spring Initializr metadata (invalid JSON)"
  end

  local types = {}
  local maven
  for _, value in ipairs(select_values(data.type)) do
    if value.id:match(SPRING_PROJECT_TYPE) or value.id:match(SPRING_PROJECT_TYPE_KOTLIN) then
      if value.id == "maven-project" then
        maven = value
      else
        types[#types + 1] = value
      end
    end
  end
  if #types == 0 and not maven then
    return nil, "Spring Initializr metadata has no project types"
  end
  if maven then
    table.insert(types, 1, maven)
  end

  local function section(key)
    local raw = data[key]
    if type(raw) ~= "table" then
      return nil, "Spring Initializr metadata is missing '" .. key .. "'"
    end
    local values = select_values(raw)
    if #values == 0 then
      return nil, "Spring Initializr metadata has no '" .. key .. "' values"
    end
    local default = trim(raw.default)
    if default ~= "" then
      local reordered = {}
      for _, value in ipairs(values) do
        if value.id == default then
          table.insert(reordered, 1, value)
        else
          reordered[#reordered + 1] = value
        end
      end
      values = reordered
    end
    return { values = values, default = default ~= "" and default or values[1].id }
  end

  local boot, boot_err = section("bootVersion")
  if not boot then
    return nil, boot_err
  end
  local packaging, packaging_err = section("packaging")
  if not packaging then
    return nil, packaging_err
  end
  local java, java_err = section("javaVersion")
  if not java then
    return nil, java_err
  end

  local groups = data.dependencies
  if type(groups) ~= "table" or type(groups.values) ~= "table" then
    return nil, "Spring Initializr metadata is missing 'dependencies'"
  end
  local dependencies = {}
  for _, group in ipairs(groups.values) do
    if type(group) == "table" and type(group.values) == "table" then
      local group_name = type(group.name) == "string" and group.name or ""
      for _, dep in ipairs(group.values) do
        if type(dep) == "table" and type(dep.id) == "string" and dep.id ~= "" then
          dependencies[#dependencies + 1] = {
            id = dep.id,
            name = type(dep.name) == "string" and dep.name or dep.id,
            group = group_name,
            description = type(dep.description) == "string" and dep.description or "",
          }
        end
      end
    end
  end
  if #dependencies == 0 then
    return nil, "Spring Initializr metadata has no dependencies"
  end

  return {
    types = types,
    boot_versions = boot.values,
    boot_default = boot.default,
    packagings = packaging.values,
    packaging_default = packaging.default,
    java_versions = java.values,
    java_default = java.default,
    dependencies = dependencies,
  }
end

---Why an archive entry path is unsafe (nil when it is acceptable).
---@param path string
---@return string|nil
local function unsafe_entry_reason(path)
  if type(path) ~= "string" or path == "" then
    return "empty entry path in the archive"
  end
  if path:find("\0", 1, true) then
    return ("archive entry %q contains a NUL byte"):format(path)
  end
  if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then
    return ("archive entry %q is an absolute path"):format(path)
  end
  if path:match("^[A-Za-z]:") then
    return ("archive entry %q is a Windows drive path"):format(path)
  end
  if path:find("\\", 1, true) then
    return ("archive entry %q contains a backslash"):format(path)
  end
  if path:find("..", 1, true) then
    for segment in path:gmatch("[^/]+") do
      if segment == ".." then
        return ("archive entry %q escapes the target directory"):format(path)
      end
    end
  end
  return nil
end

---Validate the archive listing before anything is extracted.
---@param names string[] entry paths (`unzip -Z -1`)
---@param mode_lines string[] `unzip -Z` detail lines, one per entry
---@return boolean ok, string|nil reason
function M._validate_zip_listing(names, mode_lines)
  names = names or {}
  mode_lines = mode_lines or {}
  if #names == 0 then
    return false, "empty archive: nothing to extract"
  end
  if #names ~= #mode_lines then
    return false, ("inconsistent archive listing (%d entries, %d detail lines)"):format(#names, #mode_lines)
  end
  for index, name in ipairs(names) do
    local reason = unsafe_entry_reason(name)
    if reason then
      return false, reason
    end
    local kind = tostring(mode_lines[index]):sub(1, 1)
    if kind ~= "-" and kind ~= "d" then
      return false,
        ("unsafe archive entry %q: unsupported type %q (only regular files and directories are allowed)"):format(
          name,
          kind
        )
    end
  end
  return true
end

---Read both unzip listings and validate them. Runs before any extraction.
---@param zip_path string
---@return boolean ok, string|string[]|nil result, string[]|nil modes
function M._inspect_zip(zip_path)
  if type(zip_path) ~= "string" or zip_path == "" then
    return false, "zip path is required"
  end
  local stat = vim.uv.fs_stat(zip_path)
  if not stat then
    return false, "zip file does not exist: " .. zip_path
  end
  if stat.type ~= "file" then
    return false, "zip path is not a regular file: " .. zip_path
  end

  local flat, flat_err = run_system({ "unzip", "-Z", "-1", zip_path })
  if not flat then
    return false, flat_err
  end
  if flat.code ~= 0 then
    return false, command_error(flat, "could not list the archive")
  end
  local names = listing_lines(flat.stdout)

  local detail, detail_err = run_system({ "unzip", "-Z", zip_path })
  if not detail then
    return false, detail_err
  end
  if detail.code ~= 0 then
    return false, command_error(detail, "could not read the archive details")
  end
  local modes = {}
  for _, line in ipairs(listing_lines(detail.stdout)) do
    if not line:match("^Archive:") and not line:match("^Zip file size:") and not line:match("^%d+ files?, ") then
      modes[#modes + 1] = line
    end
  end

  local ok, err = M._validate_zip_listing(names, modes)
  if not ok then
    return false, err
  end
  return true, names, modes
end

---Re-check the extracted tree: only regular files and directories are allowed,
---and the archive must have produced something.
---@param stage string
---@return boolean ok, string|nil err
function M._verify_staged_tree(stage)
  local stat = vim.uv.fs_lstat(stage)
  if not stat or stat.type ~= "directory" then
    return false, "staging directory was not created: " .. tostring(stage)
  end

  local entries = 0
  local function walk(dir)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return false, "could not read the staging directory: " .. dir
    end
    while true do
      local name = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      entries = entries + 1
      local path = dir .. "/" .. name
      local child = vim.uv.fs_lstat(path)
      if not child then
        return false, "could not stat the extracted entry: " .. path
      end
      if child.type == "directory" then
        local ok, err = walk(path)
        if not ok then
          return false, err
        end
      elseif child.type ~= "file" then
        return false,
          ("unsafe extracted entry %q: unsupported type %q (only regular files and directories are allowed)"):format(
            path,
            child.type
          )
      end
    end
    return true
  end

  local ok, err = walk(stage)
  if not ok then
    return false, err
  end
  if entries == 0 then
    return false, "the archive extracted no files"
  end
  return true
end

---Validate, then extract a downloaded starter.zip into a hidden staging
---directory next to the target, re-check the tree and publish by rename.
---Any failure removes the staging directory and leaves the parent untouched.
---@param zip_path string
---@param opts table
---@return boolean ok, string|nil err
function M._extract_spring_zip(zip_path, opts)
  local reason = M._validate(opts)
  if reason then
    return false, reason
  end
  if opts.kind ~= "spring" then
    return false, "not a Spring Boot project: " .. tostring(opts.kind)
  end

  -- the listing is validated before a staging directory is created (or any
  -- other write happens)
  local inspected, inspect_err = M._inspect_zip(zip_path)
  if not inspected then
    return false, inspect_err
  end

  local parent = resolved_parent(opts.parent)
  local stage = parent .. "/." .. opts.name .. STAGE_SUFFIX
  local target = target_of(parent, opts.name)

  vim.fn.mkdir(stage)
  if not is_dir(stage) then
    return false, "could not create staging directory " .. stage
  end

  local extracted, extract_err = run_system({ "unzip", "-qq", "-n", zip_path, "-d", stage }, 120000)
  if not extracted then
    vim.fn.delete(stage, "rf")
    return false, extract_err
  end
  if extracted.code ~= 0 then
    vim.fn.delete(stage, "rf")
    return false, command_error(extracted, "could not extract the archive")
  end

  local verified, verify_err = M._verify_staged_tree(stage)
  if not verified then
    vim.fn.delete(stage, "rf")
    return false, verify_err
  end

  local published, publish_err = M._publish(stage, target)
  if not published then
    if vim.uv.fs_lstat(stage) then
      vim.fn.delete(stage, "rf")
    end
    return false, publish_err
  end
  return true
end

---@param tools table
---@param accept string
---@return string[]
local function metadata_command(tools, accept)
  if tools.http == "wget" then
    return {
      "wget",
      "-q",
      "-O",
      "-",
      "--timeout=15",
      "--header=Accept: " .. accept,
      SPRING_METADATA_URL,
    }
  end
  return {
    "curl",
    "-sS",
    "-f",
    "-L",
    "--max-time",
    "15",
    "-H",
    "Accept: " .. accept,
    SPRING_METADATA_URL,
  }
end

---Fetch and parse the Spring Initializr metadata asynchronously.
---`on_done(meta, err)` always runs on the main loop.
---@param on_done fun(meta: table|nil, err: string|nil)
function M._fetch_spring_metadata(on_done)
  local tools = M._spring_tools()
  if not tools.http then
    vim.schedule(function()
      on_done(nil, tools.reason)
    end)
    return
  end

  local cmd = metadata_command(tools, SPRING_METADATA_ACCEPT)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        on_done(nil, command_error(res, "could not reach Spring Initializr"))
        return
      end
      local meta, err = M._parse_metadata(res.stdout)
      if not meta then
        on_done(nil, err)
        return
      end
      on_done(meta, nil)
    end)
  end)
end

---Download starter.zip for `opts` into `dest_zip` asynchronously.
---The file is removed again when the download fails or is not a zip.
---`on_done(ok, err)` always runs on the main loop.
---@param opts table
---@param dest_zip string
---@param on_done fun(ok: boolean, err: string|nil)
function M._download_spring_zip(opts, dest_zip, on_done)
  local function fail(msg)
    if vim.uv.fs_lstat(dest_zip) then
      vim.fn.delete(dest_zip)
    end
    on_done(false, msg)
  end

  local tools = M._spring_tools()
  if not tools.http then
    vim.schedule(function()
      fail(tools.reason)
    end)
    return
  end

  local url = M._spring_url(opts)
  local cmd
  if tools.http == "wget" then
    cmd = { "wget", "-q", "--timeout=30", "--header=Accept: application/zip", "-O", dest_zip, url }
  else
    cmd = { "curl", "-sS", "-f", "-L", "--max-time", "30", "-H", "Accept: application/zip", "-o", dest_zip, url }
  end

  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        fail(command_error(res, "download failed"))
        return
      end
      local stat = vim.uv.fs_stat(dest_zip)
      if not stat or stat.type ~= "file" then
        fail("download produced no file")
        return
      end
      if stat.size < 2 then
        fail("downloaded archive is empty")
        return
      end
      local fd = vim.uv.fs_open(dest_zip, "r", 438)
      if not fd then
        fail("could not read the downloaded archive")
        return
      end
      local head = vim.uv.fs_read(fd, 2, 0)
      vim.uv.fs_close(fd)
      if head ~= "PK" then
        fail("downloaded file is not a zip archive")
        return
      end
      on_done(true, nil)
    end)
  end)
end

---Build file expected for a project type (falls back to any known build file
---and finally to the generated application class).
---@param target string
---@param opts table
---@return string|nil
local function spring_entry_file(target, opts)
  local preferred = "build.gradle"
  if opts.build_type and opts.build_type:match("^maven") then
    preferred = "pom.xml"
  elseif opts.build_type and opts.build_type:match("%-kotlin$") then
    preferred = "build.gradle.kts"
  end
  for _, name in ipairs({ preferred, "pom.xml", "build.gradle", "build.gradle.kts" }) do
    local path = target .. "/" .. name
    if vim.uv.fs_stat(path) then
      return path
    end
  end
  local apps = vim.fn.glob(target .. "/src/main/java/**/*Application.java", false, true)
  if type(apps) == "table" and #apps > 0 then
    table.sort(apps)
    return apps[1]
  end
  return nil
end

---@param opts table
---@param ok boolean
---@param err string|nil
local function finish_spring(opts, ok, err)
  local ui = require("java_menu.ui")
  local target = target_of(resolved_parent(opts.parent), opts.name)
  if not ok then
    ui.notify(err or "could not create the Spring Boot project", vim.log.levels.ERROR)
    return
  end
  local path = spring_entry_file(target, opts)
  if path then
    vim.cmd.edit(vim.fn.fnameescape(path))
  end
  local hint = (opts.build_type and opts.build_type:match("^maven")) and "./mvnw spring-boot:run" or "./gradlew bootRun"
  ui.notify("created " .. target .. " — " .. hint)
end

---@param target string
---@param main_path string
---@param ok boolean
---@param err string|nil
---@param opts table
local function finish(target, main_path, ok, err, opts)
  local ui = require("java_menu.ui")
  if not ok then
    ui.notify(err or "could not create the project", vim.log.levels.ERROR)
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(main_path))
  local hint = opts.kind == "maven" and "run mvn package" or ("compile with javac --release " .. tostring(opts.release))
  ui.notify("created " .. target .. " — " .. hint)
end

---Default base package for the Spring wizard: the groupId plus a sanitized
---artifactId segment (`my-app` -> `group.myapp`).
---@param group string
---@param artifact string
---@return string
local function default_package(group, artifact)
  local segment = tostring(artifact or ""):lower():gsub("[^%w_]", "")
  if segment == "" then
    segment = "app"
  end
  if segment:match("^%d") then
    segment = "_" .. segment
  end
  if KEYWORDS[segment] then
    segment = segment .. "_app"
  end
  local group_name = trim(group)
  if group_name == "" then
    return segment
  end
  return group_name .. "." .. segment
end

---Spring Boot wizard: metadata -> prompts -> validation -> confirmation ->
---download -> extraction. Nothing is written before the confirmation, and an
---Esc/nil answer at any step ends the flow without touching the filesystem.
---The network helpers are looked up on `M` at call time so the tests can
---replace them.
---@param default_parent string
---@param tools table|nil result of M._spring_tools()
function M._spring_flow(default_parent, tools)
  local ui = require("java_menu.ui")
  if tools and not tools.ok then
    ui.notify(tools.reason or "Spring Boot project creation is unavailable", vim.log.levels.WARN)
    return
  end

  local opts = { kind = "spring", dependencies = {} }
  local meta

  -- every step is declared first so each one can call the next one
  local step_build, step_boot, step_packaging, step_java, step_parent
  local step_name, step_group, step_artifact, step_package, step_dependencies
  local step_summary, step_download

  ---@param values { id: string, name: string }[]
  ---@param preferred string|nil id placed first when present
  ---@return string[] labels, table<string, string> ids
  local function label_map(values, preferred)
    local ordered, first = {}, nil
    for _, value in ipairs(values) do
      if preferred and value.id == preferred then
        first = value
      else
        ordered[#ordered + 1] = value
      end
    end
    if first then
      table.insert(ordered, 1, first)
    end
    local labels, ids, used = {}, {}, {}
    for _, value in ipairs(ordered) do
      local label = value.name
      if used[label] then
        label = value.name .. " (" .. value.id .. ")"
      end
      used[label] = true
      labels[#labels + 1] = label
      ids[label] = value.id
    end
    return labels, ids
  end

  step_build = function()
    local labels, ids = label_map(meta.types, nil)
    ui.pick_one(labels, "Java: New Project — build tool", function(choice)
      if choice == nil or ids[choice] == nil then
        return
      end
      opts.build_type = ids[choice]
      step_boot()
    end)
  end

  step_boot = function()
    local labels, ids = label_map(meta.boot_versions, meta.boot_default)
    ui.pick_one(labels, "Java: New Project — Spring Boot version", function(choice)
      if choice == nil or ids[choice] == nil then
        return
      end
      opts.boot_version = ids[choice]
      step_packaging()
    end)
  end

  step_packaging = function()
    local labels, ids = label_map(meta.packagings, meta.packaging_default)
    ui.pick_one(labels, "Java: New Project — packaging", function(choice)
      if choice == nil or ids[choice] == nil then
        return
      end
      opts.packaging = ids[choice]
      step_java()
    end)
  end

  step_java = function()
    local preferred
    for _, value in ipairs(meta.java_versions) do
      if value.id == "21" then
        preferred = "21"
        break
      end
    end
    local labels, ids = label_map(meta.java_versions, preferred or meta.java_default)
    ui.pick_one(labels, "Java: New Project — Java version", function(choice)
      if choice == nil or ids[choice] == nil then
        return
      end
      opts.release = ids[choice]
      step_parent()
    end)
  end

  step_parent = function()
    ui.ask("Java: New Project — parent directory", default_parent, function(parent)
      if parent == nil then
        return
      end
      parent = trim(parent)
      if parent == "" then
        parent = default_parent
      end
      opts.parent = parent
      step_name()
    end)
  end

  step_name = function()
    ui.ask("Java: New Project — project name", nil, function(name)
      if name == nil then
        return
      end
      opts.name = trim(name)
      step_group()
    end)
  end

  step_group = function()
    ui.ask("Java: New Project — groupId", "com.example", function(group)
      if group == nil then
        return
      end
      opts.group = trim(group)
      step_artifact()
    end)
  end

  step_artifact = function()
    ui.ask("Java: New Project — artifactId", opts.name, function(artifact)
      if artifact == nil then
        return
      end
      opts.artifact = trim(artifact)
      step_package()
    end)
  end

  step_package = function()
    local suggested = default_package(opts.group, opts.artifact)
    ui.ask("Java: New Project — base package", suggested, function(pkg)
      if pkg == nil then
        return
      end
      opts.pkg = trim(pkg)
      if opts.pkg == "" then
        opts.pkg = suggested
      end
      step_dependencies()
    end)
  end

  step_dependencies = function()
    local items, used = {}, {}
    for _, dep in ipairs(meta.dependencies) do
      local text = dep.group ~= "" and ("[%s] %s (%s)"):format(dep.group, dep.name, dep.id)
        or ("%s (%s)"):format(dep.name, dep.id)
      if not used[text] then
        used[text] = true
        items[#items + 1] = { text = text, value = dep.id }
      end
    end
    -- dependencies are optional: an empty selection is valid, Esc cancels
    ui.pick_many(items, "Java: New Project — dependencies", function(selected)
      opts.dependencies = selected or {}
      step_summary()
    end, { fallback = false })
  end

  step_summary = function()
    local reason = M._validate(opts)
    if reason then
      ui.notify(reason, vim.log.levels.WARN)
      return
    end
    local items = { "✔ Create project" }
    vim.list_extend(items, M._summary_lines(opts))
    items[#items + 1] = "✖ Cancel"
    ui.pick_one(items, "Java: New Project — summary", function(choice)
      if choice ~= "✔ Create project" then
        return
      end
      step_download()
    end)
  end

  step_download = function()
    local zip_path = vim.fn.tempname() .. ".zip"
    local function attempt()
      M._download_spring_zip(opts, zip_path, function(ok, err)
        if not ok then
          if vim.uv.fs_lstat(zip_path) then
            vim.fn.delete(zip_path)
          end
          ui.notify("Spring Boot download failed: " .. tostring(err), vim.log.levels.ERROR)
          ui.pick_one({ "Retry", "Cancel" }, "Java: Spring Boot download failed", function(choice)
            if choice == "Retry" then
              attempt()
            end
          end)
          return
        end
        local created, create_err = M._extract_spring_zip(zip_path, opts)
        if vim.uv.fs_lstat(zip_path) then
          vim.fn.delete(zip_path)
        end
        finish_spring(opts, created, create_err)
      end)
    end
    attempt()
  end

  local fetch_metadata -- forward declaration: retry restarts the fetch only
  fetch_metadata = function()
    M._fetch_spring_metadata(function(fetched, err)
      if not fetched then
        ui.notify("Spring Initializr is unavailable: " .. tostring(err), vim.log.levels.ERROR)
        ui.pick_one({ "Retry", "Cancel" }, "Java: Spring Initializr — network error", function(choice)
          if choice == "Retry" then
            fetch_metadata()
          end
        end)
        return
      end
      meta = fetched
      step_build()
    end)
  end

  fetch_metadata()
end

---Interactive flow. Every nil/cancelled answer returns without writing
---anything; a validation error aborts with a notification (press the keymap
---again to restart) instead of looping through the wizard.
function M.create()
  local ui = require("java_menu.ui")
  local default_parent = vim.fs.normalize(vim.uv.cwd())
  local tools = M._spring_tools()

  ui.menu(
    {
      { key = "plain", label = "Plain Java", enabled = true },
      { key = "maven", label = "Maven", enabled = true },
      { key = "spring", label = "Spring Boot", enabled = tools.ok, reason = tools.reason },
    },
    "Java: New Project — kind",
    function(entry)
      if entry.key == "spring" then
        M._spring_flow(default_parent, tools)
        return
      end
      local kind = entry.key == "maven" and "maven" or "plain"

      ui.ask("Java: New Project — parent directory", default_parent, function(parent)
        if parent == nil then
          return
        end
        parent = vim.trim(parent)
        if parent == "" then
          parent = default_parent
        end

        ui.ask("Java: New Project — project name", nil, function(name)
          if name == nil then
            return
          end

          ui.ask("Java: New Project — base package", "com.example", function(pkg)
            if pkg == nil then
              return
            end

            ui.ask("Java: New Project — Java release", "21", function(release)
              if release == nil then
                return
              end

              local opts = {
                kind = kind,
                parent = parent,
                name = vim.trim(name),
                pkg = vim.trim(pkg),
                release = vim.trim(release),
              }

              local function confirm()
                local reason = M._validate(opts)
                if reason then
                  ui.notify(reason, vim.log.levels.WARN)
                  return
                end

                local items = { "✔ Create project" }
                vim.list_extend(items, M._summary_lines(opts))
                items[#items + 1] = "✖ Cancel"

                ui.pick_one(items, "Java: New Project — summary", function(choice)
                  if choice ~= "✔ Create project" then
                    return
                  end
                  local target = target_of(resolved_parent(opts.parent), opts.name)
                  local main_path = target .. "/src/main/java/" .. opts.pkg:gsub("%.", "/") .. "/Main.java"
                  local ok, err = M._run(opts)
                  finish(target, main_path, ok, err, opts)
                end)
              end

              if kind == "maven" then
                ui.ask("Java: New Project — groupId", opts.pkg, function(group)
                  if group == nil then
                    return
                  end
                  opts.group = vim.trim(group)
                  ui.ask("Java: New Project — artifactId", opts.name, function(artifact)
                    if artifact == nil then
                      return
                    end
                    opts.artifact = vim.trim(artifact)
                    confirm()
                  end)
                end)
              else
                confirm()
              end
            end)
          end)
        end)
      end)
    end
  )
end

return M
