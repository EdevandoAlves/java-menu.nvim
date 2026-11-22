-- java_menu/project.lua
-- Java project detection from build files (Maven/Gradle).
-- .git is NOT considered a Java project marker.

local M = {}

M.markers = {
  "pom.xml",
  "build.gradle",
  "build.gradle.kts",
  "settings.gradle",
  "settings.gradle.kts",
}

-- files that characterize a module (settings.* exists only at the root)
M.build_files = { "pom.xml", "build.gradle", "build.gradle.kts" }

---Forward declarations: defined in the modules section below.
local topmost_aggregator
local gradle_modules

local function isfile(path)
  return vim.fn.filereadable(path) == 1
end

local function isdir(path)
  return vim.fn.isdirectory(path) == 1
end

local function has_any(dir, list)
  for _, file in ipairs(list) do
    if isfile(dir .. "/" .. file) then
      return true
    end
  end
  return false
end

---Canonical path (realpath + normalized) or nil when it does not exist.
local function canonical(path)
  local real = vim.uv.fs_realpath(path)
  return real and vim.fs.normalize(real) or nil
end

---Resolve `candidate` to its canonical path if it exists, or otherwise normalize
---lexically while canonicalizing its deepest existing ancestor so non-existent
---paths outside `root` (or through outward symlinks / Windows short paths)
---still resolve consistently.
local function resolve_lexical_or_canonical(candidate)
  local canon = canonical(candidate)
  if canon then
    return canon, true
  end
  local norm = vim.fs.normalize(candidate)
  local cur, tail = norm, ""
  while cur and cur ~= "" and cur ~= "/" do
    local c = canonical(cur)
    if c then
      return (tail == "" and c or (c:gsub("/+$", "") .. "/" .. tail)), false
    end
    local parent = vim.fs.dirname(cur)
    local base = vim.fs.basename(cur)
    if not parent or parent == cur then
      break
    end
    tail = tail == "" and base or (base .. "/" .. tail)
    cur = parent
  end
  return norm, false
end

local function is_abs_path(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\"
end

---Reference path of the buffer (file, netrw directory or cwd), canonicalized
---when its file or an ancestor directory exists on disk.
---@param buf number|nil
---@return string
function M.start_path(buf)
  buf = buf and buf > 0 and buf or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local raw = name ~= "" and name or vim.uv.cwd() or "."
  local lstat = vim.uv.fs_lstat(raw)
  if lstat and lstat.type == "link" and not isdir(raw) then
    local dir = resolve_lexical_or_canonical(vim.fs.dirname(raw))
    return dir:gsub("/+$", "") .. "/" .. vim.fs.basename(raw)
  end
  local resolved = resolve_lexical_or_canonical(raw)
  return resolved
end

---Is `path` inside the subtree of `parent` (both canonical)?
local function subtree(parent, path)
  local sep = parent:sub(-1) == "/" and "" or "/"
  return parent == path or path:sub(1, #parent + #sep) == parent .. sep
end

---Does `parent` declare `child` as a module (Maven <module> / Gradle include)?
---@param parent string
---@param child string
---@return boolean
local function declares_module(parent, child)
  local pom = parent .. "/pom.xml"
  if isfile(pom) then
    -- read the whole file: multiple <module> entries may share a line
    local text = table.concat(vim.fn.readfile(pom), "\n")
    for mod in text:gmatch("<module%s*>%s*([^<%s]+)%s*</module>") do
      mod = mod:gsub("/+$", "")
      if vim.fs.basename(mod) == child then
        return true
      end
    end
    return false
  end

  -- Gradle: match against statically declared modules in settings.gradle(.kts)
  local canon_parent = canonical(parent)
  local canon_child = canonical(parent .. "/" .. child)
  if
    canon_parent
    and canon_child
    and (isfile(canon_parent .. "/settings.gradle") or isfile(canon_parent .. "/settings.gradle.kts"))
  then
    for _, mod in ipairs(gradle_modules(canon_parent)) do
      if mod == canon_child then
        return true
      end
    end
  end
  return false
end

---Walk up to the directory containing a build file.
---In a multi-module project, walk up to the aggregator (the parent declaring the module).
---@param buf number|nil
---@return string|nil
function M.root(buf)
  local start = M.start_path(buf)
  local dir = isdir(start) and start or vim.fs.dirname(start)
  local found

  while dir and dir ~= "" do
    if has_any(dir, M.markers) then
      found = dir
      local parent = vim.fs.dirname(dir)
      if not parent or parent == dir then
        return canonical(found) or found
      end
      if has_any(parent, M.markers) and declares_module(parent, vim.fs.basename(dir)) then
        dir = parent -- aggregates; the preferred source root is resolved later
      else
        -- a higher aggregator may declare this module with a relative path
        -- aninhado (<module>libraries/core</module> / :libraries:core)
        local ancestor = topmost_aggregator(dir)
        return ancestor or canonical(found) or found
      end
    else
      local parent = vim.fs.dirname(dir)
      if not parent or parent == dir then
        return nil
      end
      dir = parent
    end
  end
  return found and (canonical(found) or found) or nil
end

---@param buf number|nil
---@return boolean
function M.is_java_project(buf)
  return M.root(buf) ~= nil
end

-- ---------- modules (aggregators with nested modules) ----------

---`<module>` declarations from a POM's `<modules>` sections (Maven aggregation).
---Inheritance (`<parent>`) is not aggregation and is not considered here.
---Returned paths are relative to the directory of the declaring POM.
---@param pom string
---@return string[]
local function pom_module_decls(pom)
  local text = table.concat(vim.fn.readfile(pom), "\n")
  local decls = {}
  for block in text:gmatch("<modules>(.-)</modules>") do
    for mod in block:gmatch("<module%s*>([^<]+)</module>") do
      mod = vim.trim(mod):gsub("/+$", "")
      if mod ~= "" then
        decls[#decls + 1] = mod
      end
    end
  end
  return decls
end

---Maven modules declared recursively from the `root` aggregator.
---Each path is resolved relative to its declaring POM, then canonicalized;
---modules outside the aggregator subtree, outward symlinks, cycles, duplicates
---and undeclared folders with pom.xml are left out.
---@param root string canonical aggregator root
---@param seen table<string, boolean> canonical paths already visited
---@param depth integer
---@return string[]
local function maven_modules(root, seen, depth)
  depth = depth or 0
  if depth >= 16 then
    return {}
  end
  local out = {}
  for _, decl in ipairs(pom_module_decls(root .. "/pom.xml")) do
    local candidate = is_abs_path(decl) and decl or (root .. "/" .. decl)
    local dir = canonical(candidate)
    if dir and dir ~= root and subtree(root, dir) and not seen[dir] then
      seen[dir] = true
      if isfile(dir .. "/pom.xml") then
        out[#out + 1] = dir
        vim.list_extend(out, maven_modules(dir, seen, depth + 1))
      end
    end
  end
  return out
end

local STATIC_GRADLE_BASE_DIRS = {
  rootDir = true,
  settingsDir = true,
  ["rootProject.projectDir"] = true,
  ["settings.settingsDir"] = true,
  ["settings.rootDir"] = true,
}

local SLASHY_PRECEDING_KEYWORDS = {
  ["return"] = true,
  ["case"] = true,
  ["throw"] = true,
  ["assert"] = true,
  ["else"] = true,
  ["yield"] = true,
}

local SLASHY_PRECEDING_CHARS = {
  ["("] = true,
  ["["] = true,
  ["{"] = true,
  [","] = true,
  [";"] = true,
  [":"] = true,
  ["="] = true,
  ["?"] = true,
  ["+"] = true,
  ["-"] = true,
  ["*"] = true,
  ["%"] = true,
  ["!"] = true,
  ["&"] = true,
  ["|"] = true,
  ["^"] = true,
  ["~"] = true,
  ["<"] = true,
  [">"] = true,
  ["\n"] = true,
  ["\r"] = true,
}

local function can_start_slashy_tail(tail)
  local stripped = tail:gsub("[ \t]+$", "")
  if stripped == "" then
    return true
  end
  local last = stripped:sub(-1)
  if (last == "+" and stripped:sub(-2) == "++") or (last == "-" and stripped:sub(-2) == "--") then
    return false
  end
  if SLASHY_PRECEDING_CHARS[last] then
    return true
  end
  local word = stripped:match("([%w_$]+)$")
  return word ~= nil and SLASHY_PRECEDING_KEYWORDS[word] == true
end

local function tail_from_chunks(chunks)
  local parts, total = {}, 0
  for idx = #chunks, 1, -1 do
    local s = chunks[idx]
    parts[#parts + 1] = s
    total = total + #s
    if total >= 64 then
      break
    end
  end
  for l = 1, math.floor(#parts / 2) do
    parts[l], parts[#parts - l + 1] = parts[#parts - l + 1], parts[l]
  end
  return table.concat(parts)
end

---If `text` at index `i` starts a string literal (`'`, `"`, `'''`, `"""`,
---or Groovy `/.../` and `$/.../$` when `is_groovy` is true), return the index
---of its closing character (or `#text` if unclosed) and an unclosed kind tag.
---@param text string
---@param i integer
---@param is_groovy boolean|nil
---@param slashy_tail string|nil
---@return integer|nil end_idx, string|nil unclosed_kind
local function scan_string_end(text, i, is_groovy, slashy_tail)
  local three = text:sub(i, i + 2)
  if three == '"""' or three == "'''" then
    local j = text:find(three, i + 3, true)
    if j then
      return j + 2, nil
    end
    return #text, "quoted"
  end

  if is_groovy and text:sub(i, i + 1) == "$/" then
    local j, n = i + 2, #text
    while j <= n do
      local two = text:sub(j, j + 1)
      if two == "$$" or two == "$/" then
        j = j + 2
      elseif two == "/$" then
        return j + 1, nil
      else
        j = j + 1
      end
    end
    return n, "dollar_slashy"
  end

  local ch = text:sub(i, i)
  if is_groovy and ch == "/" then
    local next_ch = text:sub(i + 1, i + 1)
    if next_ch ~= "/" and next_ch ~= "*" and next_ch ~= "=" and next_ch ~= "" then
      local tail = slashy_tail or text:sub(math.max(1, i - 64), i - 1)
      if can_start_slashy_tail(tail) then
        local j, n = i + 1, #text
        while j <= n do
          local c = text:sub(j, j)
          if c == "\\" then
            j = j + 2
          elseif c == "/" then
            return j, nil
          else
            j = j + 1
          end
        end
        return n, "slashy"
      end
    end
  end

  if ch ~= '"' and ch ~= "'" then
    return nil, nil
  end
  local j, n = i + 1, #text
  while j <= n do
    local c = text:sub(j, j)
    if c == "\\" then
      j = j + 2
    elseif c == ch then
      return j, nil
    elseif c == "\n" or c == "\r" then
      return j - 1, "quoted"
    else
      j = j + 1
    end
  end
  return n, "quoted"
end

---Strip `//` and `/* ... */` comments outside string literals, keeping newlines.
---@param text string
---@param is_groovy boolean|nil
---@return string stripped, string|nil unclosed_kind
local function strip_gradle_comments(text, is_groovy)
  local out = {}
  local unclosed_kind
  local i, n = 1, #text
  while i <= n do
    local slashy_tail = (is_groovy and text:sub(i, i) == "/") and tail_from_chunks(out) or nil
    local str_end, unclosed = scan_string_end(text, i, is_groovy, slashy_tail)
    if str_end then
      if unclosed and not unclosed_kind then
        unclosed_kind = unclosed
      end
      out[#out + 1] = text:sub(i, str_end)
      i = str_end + 1
    elseif text:sub(i, i + 1) == "//" then
      local nl = text:find("\n", i + 2, true)
      if nl then
        out[#out + 1] = "\n"
        i = nl + 1
      else
        break
      end
    elseif text:sub(i, i + 1) == "/*" then
      local close = text:find("*/", i + 2, true)
      local block = close and text:sub(i + 2, close - 1) or text:sub(i + 2)
      local _, nl_count = block:gsub("\n", "\n")
      out[#out + 1] = nl_count > 0 and string.rep("\n", nl_count) or " "
      if close then
        i = close + 2
      else
        break
      end
    else
      out[#out + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out), unclosed_kind
end

---Replace string literals with `""` so keyword checks ignore text inside quotes.
---@param text string
---@param is_groovy boolean|nil
---@return string
local function strip_string_literals(text, is_groovy)
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local str_end = scan_string_end(text, i, is_groovy)
    if str_end then
      out[#out + 1] = '""'
      i = str_end + 1
    else
      out[#out + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

---If `expr` is a single pure `'...'` or `"..."` literal, return its inner text.
---@param expr string
---@return string|nil
local function unquote_literal(expr)
  expr = vim.trim(expr)
  if #expr < 2 or expr:sub(1, 3) == '"""' or expr:sub(1, 3) == "'''" then
    return nil
  end
  local q = expr:sub(1, 1)
  if q ~= "'" and q ~= '"' then
    return nil
  end
  local end_idx = scan_string_end(expr, 1, false)
  if end_idx ~= #expr or expr:sub(end_idx, end_idx) ~= q then
    return nil
  end
  return (expr:sub(2, end_idx - 1):gsub("\\(.)", "%1"))
end

---Split comment-stripped Gradle script text into top-level statements.
---@param text string
---@param is_groovy boolean|nil
---@return string[]
local function split_gradle_statements(text, is_groovy)
  local stmts, buf = {}, {}
  local paren, bracket, brace = 0, 0, 0
  local i, n = 1, #text

  local function flush()
    local s = vim.trim(table.concat(buf))
    buf = {}
    if s ~= "" then
      stmts[#stmts + 1] = s
    end
  end

  local function continues_line(cur, rest)
    local tail = cur:sub(-1)
    if tail == "," or tail == "=" or tail == "." or tail == "+" then
      return true
    end
    local next_ch = rest:match("^%s*(%S)")
    if next_ch == "." then
      return true
    end
    if
      cur:match("^if%s*%b()$")
      or cur:match("^else%s+if%s*%b()$")
      or cur:match("^else$")
      or cur:match("^for%s*%b()$")
      or cur:match("^while%s*%b()$")
      or cur:match("^try$")
      or cur:match("^catch%s*%b()$")
      or cur:match("^finally$")
    then
      return true
    end
    if
      next_ch == "{"
      and (
        cur:match("^project%s*%b()$")
        or cur:match("^findProject%s*%b()$")
        or cur:match("%.apply$")
        or cur:match("%.with$")
        or cur:match("%.let$")
        or cur:match("%.also$")
        or cur:match("%.run$")
        or cur:match("%.configure$")
        or cur:match("^when%s*%b()$")
        or cur == "when"
        or cur:match("^apply$")
        or cur:match("^with%s*%b()$")
      )
    then
      return true
    end
    return false
  end

  while i <= n do
    local str_end = scan_string_end(text, i, is_groovy)
    if str_end then
      buf[#buf + 1] = text:sub(i, str_end)
      i = str_end + 1
    else
      local ch = text:sub(i, i)
      if ch == "(" then
        paren = paren + 1
      elseif ch == ")" and paren > 0 then
        paren = paren - 1
      elseif ch == "[" then
        bracket = bracket + 1
      elseif ch == "]" and bracket > 0 then
        bracket = bracket - 1
      elseif ch == "{" then
        brace = brace + 1
      elseif ch == "}" and brace > 0 then
        brace = brace - 1
      end

      if paren == 0 and bracket == 0 and brace == 0 and ch == ";" then
        flush()
      elseif paren == 0 and bracket == 0 and brace == 0 and (ch == "\n" or ch == "\r") then
        local cur = vim.trim(table.concat(buf))
        if cur == "" then
          buf = {}
        elseif continues_line(cur, text:sub(i + 1)) then
          buf[#buf + 1] = " "
        else
          flush()
        end
      else
        buf[#buf + 1] = ch
      end
      i = i + 1
    end
  end
  flush()
  return stmts
end

---Split comma-separated arguments at nesting depth 0, respecting quotes.
---@param args_text string
---@param is_groovy boolean|nil
---@return string[]
local function split_top_level_args(args_text, is_groovy)
  local args = {}
  local start = 1
  local paren, bracket, brace = 0, 0, 0
  local i, n = 1, #args_text
  while i <= n do
    local str_end = scan_string_end(args_text, i, is_groovy)
    if str_end then
      i = str_end + 1
    else
      local ch = args_text:sub(i, i)
      if ch == "(" then
        paren = paren + 1
      elseif ch == ")" and paren > 0 then
        paren = paren - 1
      elseif ch == "[" then
        bracket = bracket + 1
      elseif ch == "]" and bracket > 0 then
        bracket = bracket - 1
      elseif ch == "{" then
        brace = brace + 1
      elseif ch == "}" and brace > 0 then
        brace = brace - 1
      elseif ch == "," and paren == 0 and bracket == 0 and brace == 0 then
        local item = vim.trim(args_text:sub(start, i - 1))
        if item ~= "" then
          args[#args + 1] = item
        end
        start = i + 1
      end
      i = i + 1
    end
  end
  local tail = vim.trim(args_text:sub(start))
  if tail ~= "" then
    args[#args + 1] = tail
  end
  return args
end

local function is_slashy_literal(expr, is_groovy)
  if not is_groovy then
    return false
  end
  expr = vim.trim(expr)
  return expr:sub(1, 2) == "$/" or (expr:sub(1, 1) == "/" and #expr >= 2 and expr:sub(-1) == "/")
end

---Validate a quoted directory literal (reject `$` interpolation and empty strings).
---@param expr string
---@param is_groovy boolean|nil
---@return string|nil val, string|nil reason
local function validate_dir_literal(expr, is_groovy)
  if is_slashy_literal(expr, is_groovy) then
    return nil, "unsupported Groovy slashy/dollar-slashy string in projectDir"
  end
  local lit = unquote_literal(expr)
  if not lit then
    return nil, "dynamic projectDir not interpreted"
  end
  if lit:find("$", 1, true) then
    return nil, "projectDir with unevaluated interpolation: " .. lit
  end
  if vim.trim(lit) == "" then
    return nil, "dynamic projectDir not interpreted"
  end
  return lit, nil
end

---Parse static literal `projectDir` RHS expressions without executing scripts:
---  file("dir"), file 'dir', new File("dir"), File("dir"),
---  new File(rootDir|settingsDir|rootProject.projectDir, "dir"),
---  File(rootDir|settingsDir|rootProject.projectDir, "dir"),
---  rootDir.resolve("dir"), settingsDir.resolve("dir").
---@param expr string
---@param depth integer|nil
---@param is_groovy boolean|nil
---@return string|nil dir_val, boolean is_abs, string|nil reason
local function parse_static_project_dir(expr, depth, is_groovy)
  depth = depth or 0
  expr = vim.trim(expr)

  local file_parens = expr:match("^file%s*(%b())$")
  if file_parens then
    local args = split_top_level_args(file_parens:sub(2, -2), is_groovy)
    if #args == 1 then
      if is_slashy_literal(args[1], is_groovy) then
        return nil, false, "unsupported Groovy slashy/dollar-slashy string in projectDir"
      end
      local lit = unquote_literal(args[1])
      if lit then
        local val, reason = validate_dir_literal(args[1], is_groovy)
        return val, (val ~= nil and is_abs_path(val)), reason
      end
      if depth == 0 then
        return parse_static_project_dir(args[1], 1, is_groovy)
      end
    end
    return nil, false, "dynamic projectDir not interpreted"
  end

  local file_bare = expr:match("^file%s+(.+)$")
  if file_bare then
    local val, reason = validate_dir_literal(file_bare, is_groovy)
    return val, (val ~= nil and is_abs_path(val)), reason
  end

  local file_ctor_args = expr:match("^new%s+java%.io%.File%s*(%b())$")
    or expr:match("^java%.io%.File%s*(%b())$")
    or expr:match("^new%s+File%s*(%b())$")
    or expr:match("^File%s*(%b())$")
  if file_ctor_args then
    local args = split_top_level_args(file_ctor_args:sub(2, -2), is_groovy)
    if #args == 1 then
      local val, reason = validate_dir_literal(args[1], is_groovy)
      return val, (val ~= nil and is_abs_path(val)), reason
    elseif #args == 2 then
      local base = args[1]:gsub("%s+", "")
      if STATIC_GRADLE_BASE_DIRS[base] then
        local val, reason = validate_dir_literal(args[2], is_groovy)
        if val then
          return (val:gsub("^/+", "")), false, nil
        end
        return nil, false, reason
      end
    end
    return nil, false, "dynamic projectDir not interpreted"
  end

  local base_raw, resolve_args = expr:match("^([%w_%.%s]+)%.resolve%s*(%b())$")
  if base_raw and resolve_args then
    local base = base_raw:gsub("%s+", "")
    local args = split_top_level_args(resolve_args:sub(2, -2), is_groovy)
    if STATIC_GRADLE_BASE_DIRS[base] and #args == 1 then
      local val, reason = validate_dir_literal(args[1], is_groovy)
      if val then
        if is_abs_path(val) then
          return val, true, nil
        end
        return val, false, nil
      end
      return nil, false, reason
    end
    return nil, false, "dynamic projectDir not interpreted"
  end

  for _, val in ipairs(split_top_level_args(expr, is_groovy)) do
    if is_slashy_literal(val, is_groovy) then
      return nil, false, "unsupported Groovy slashy/dollar-slashy string in projectDir"
    end
    local lit = unquote_literal(val)
    if lit and lit:find("$", 1, true) then
      return nil, false, "projectDir with unevaluated interpolation: " .. lit
    end
  end
  return nil, false, "dynamic projectDir not interpreted"
end

---Normalize a logical Gradle path (`:services:api`, `services:api`) to
---`services/api`. Returns nil when it is not a simple declaration
---(`$` interpolation, unexpected characters, `.` / `..` / empty segments).
---@param logical string
---@return string|nil rel, string|nil reason
local function normalize_gradle_logical(logical)
  if logical:find("$", 1, true) then
    return nil, "unevaluated interpolation: " .. logical
  end
  local rel = vim.trim(logical):gsub("^:+", ""):gsub(":+$", "")
  if rel == "" then
    return nil
  end
  if rel:find("::", 1, true) or rel:find("//", 1, true) or not rel:match("^[%w%-%_%.%:/]+$") then
    return nil, "non-simple declaration: " .. logical
  end
  local path_rel = rel:gsub(":", "/")
  for seg in path_rel:gmatch("[^/]+") do
    if seg == "." or seg == ".." then
      return nil, "non-simple declaration: " .. logical
    end
  end
  return path_rel
end

---Does `code_only` (literals already stripped) look like a conditional or loop?
local function is_gradle_control_flow(code_only)
  return code_only:match("^if%s*%(") ~= nil
    or code_only:match("^else%f[^%w_]") ~= nil
    or code_only:match("^for%s*%(") ~= nil
    or code_only:match("^while%s*%(") ~= nil
    or code_only:match("^when%f[^%w_]") ~= nil
    or code_only:match("^try%f[^%w_]") ~= nil
    or code_only:match("^catch%f[^%w_]") ~= nil
    or code_only:match("^finally%f[^%w_]") ~= nil
    or code_only:match("%.forEach%f[^%w_]") ~= nil
    or code_only:match("%.each%f[^%w_]") ~= nil
    or code_only:match("%.eachDir%f[^%w_]") ~= nil
    or code_only:match("%.eachFile%f[^%w_]") ~= nil
    or code_only:match("%.map%f[^%w_]") ~= nil
end

local function has_project_dir_assignment(code_only)
  for eq in code_only:gmatch("%f[%w_]projectDir%s*(=+)") do
    if eq == "=" then
      return true
    end
  end
  return false
end

local function has_set_project_dir(code_only)
  return code_only:match("%f[%w_]setProjectDir%f[^%w_]") ~= nil
end

local function has_set_property_project_dir(code_only, raw_stmt)
  return code_only:match("%f[%w_]setProperty%f[^%w_]") ~= nil and raw_stmt:find("projectDir", 1, true) ~= nil
end

---Detect `apply(from = ...)`, `apply(from: ...)`, `apply from: ...`,
---`apply { from(...) }`, or `apply(mapOf("from" to ...))` outside string literals.
local function has_apply_from(raw, code_only)
  if
    code_only:match("%f[%w_]apply%s*%(.-%f[%w_]from%s*[=:]")
    or code_only:match("%f[%w_]apply%s+from%s*:")
    or code_only:match("%f[%w_]apply%s*%b()%s*%f[%w_]from")
  then
    return true
  end
  for block in code_only:gmatch("%f[%w_]apply%s*(%b{})") do
    if block:match("%f[%w_]from%s*[=(]") or block:match('%f[%w_]from%s+"') then
      return true
    end
  end
  if code_only:match("%f[%w_]apply%s*%(") and raw:match("apply%s*%(%s*mapOf%s*%([^%)]*[\"']from[\"']%s+to") then
    return true
  end
  if code_only:match("%f[%w_]apply%s*%[") and code_only:match("%f[%w_]from%s*:") then
    return true
  end
  return false
end

---Skip `(` ... `)` starting at `open_idx` while respecting string literals.
local function skip_paren_group(text, open_idx, is_groovy)
  local depth, i, n = 0, open_idx, #text
  while i <= n do
    local str_end = scan_string_end(text, i, is_groovy)
    if str_end then
      i = str_end + 1
    else
      local ch = text:sub(i, i)
      if ch == "(" then
        depth = depth + 1
      elseif ch == ")" then
        depth = depth - 1
        if depth == 0 then
          return i
        end
      end
      i = i + 1
    end
  end
  return n
end

---Strip `if (...)`, `else if (...)`, `for (...)`, `while (...)`, `catch (...)`
---condition headers so condition reads like `if (project(':a').projectDir.exists())`
---do not look like branch-body overrides.
local function strip_control_headers(stmt, is_groovy)
  local out = {}
  local i, n = 1, #stmt
  while i <= n do
    local str_end = scan_string_end(stmt, i, is_groovy)
    if str_end then
      out[#out + 1] = stmt:sub(i, str_end)
      i = str_end + 1
    else
      local prefix_ok = (i == 1) or not stmt:sub(i - 1, i - 1):match("[%w_]")
      local kw_end
      if prefix_ok then
        kw_end = stmt:match("^else%s+if%s*%(()", i)
          or stmt:match("^if%s*%(()", i)
          or stmt:match("^for%s*%(()", i)
          or stmt:match("^while%s*%(()", i)
          or stmt:match("^catch%s*%(()", i)
      end
      if kw_end then
        out[#out + 1] = " "
        i = skip_paren_group(stmt, kw_end - 1, is_groovy) + 1
      else
        out[#out + 1] = stmt:sub(i, i)
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

---Extract `project(...)` / `findProject(...)` call arguments from `stmt`,
---respecting string literals.
local function extract_project_calls(stmt, is_groovy)
  local calls = {}
  local i, n = 1, #stmt
  while i <= n do
    local str_end = scan_string_end(stmt, i, is_groovy)
    if str_end then
      i = str_end + 1
    else
      local prefix_ok = (i == 1) or not stmt:sub(i - 1, i - 1):match("[%w_]")
      local open_idx, is_find
      if prefix_ok then
        open_idx = stmt:match("^findProject%s*%(()", i)
        if open_idx then
          is_find = true
        else
          open_idx = stmt:match("^project%s*%(()", i)
          is_find = false
        end
      end
      if open_idx then
        local paren_idx = open_idx - 1
        local close_idx = skip_paren_group(stmt, paren_idx, is_groovy)
        calls[#calls + 1] = {
          arg = stmt:sub(paren_idx + 1, close_idx - 1),
          is_find = is_find,
        }
        i = close_idx + 1
      else
        i = i + 1
      end
    end
  end
  return calls
end

---Gradle modules declared statically in settings.gradle(.kts).
---The script is NOT evaluated: only includes and projectDir with literals.
---With a dynamic declaration, returns what can be interpreted plus a partial
---discovery note (future integration: official Gradle tools).
---@param root string canonical root
---@return string[] dirs, string|nil note, table<string,string> logical_by_dir
function gradle_modules(root)
  root = canonical(root) or vim.fs.normalize(root)
  local settings = root .. "/settings.gradle"
  local kts = root .. "/settings.gradle.kts"
  local path = isfile(settings) and settings or (isfile(kts) and kts or nil)
  if not path then
    return {}, nil, {}
  end

  local is_groovy = (path == settings)
  local text, unclosed_kind = strip_gradle_comments(table.concat(vim.fn.readfile(path), "\n"), is_groovy)
  local order, seen_rel = {}, {}
  local descriptors = {}
  local var_to_rel = {}
  local has_untargeted_dir_override = false
  local notes, seen_notes = {}, {}

  local function add_note(msg)
    if msg and not seen_notes[msg] then
      seen_notes[msg] = true
      notes[#notes + 1] = msg
    end
  end

  if unclosed_kind == "slashy" or unclosed_kind == "dollar_slashy" then
    add_note("unclosed Groovy slashy/dollar-slashy string not evaluated")
  elseif unclosed_kind == "quoted" then
    add_note("unclosed string literal not evaluated")
  end

  local function ensure_descriptor(rel)
    local prefixes = {}
    local idx = 1
    for seg in rel:gmatch("[^/]+") do
      local prev = prefixes[idx - 1]
      prefixes[idx] = prev and (prev .. "/" .. seg) or seg
      idx = idx + 1
    end
    for i, p in ipairs(prefixes) do
      if descriptors[p] == nil then
        local parent_p = i > 1 and prefixes[i - 1] or nil
        if not parent_p then
          descriptors[p] = {
            dir = root .. "/" .. p,
            tainted_self = false,
            tainted_from_parent = false,
          }
        else
          local parent_desc = descriptors[parent_p]
          if parent_desc.tainted_self or parent_desc.tainted_from_parent or not parent_desc.dir then
            descriptors[p] = {
              dir = nil,
              tainted_self = false,
              tainted_from_parent = true,
            }
          else
            local seg = p:sub(#parent_p + 2)
            descriptors[p] = {
              dir = parent_desc.dir:gsub("/+$", "") .. "/" .. seg,
              tainted_self = false,
              tainted_from_parent = false,
            }
          end
        end
      end
    end
  end

  local function add_logical(raw)
    local rel, reason = normalize_gradle_logical(raw)
    if reason then
      add_note(reason)
    end
    if rel then
      ensure_descriptor(rel)
      if not seen_rel[rel] then
        seen_rel[rel] = true
        order[#order + 1] = rel
      end
    end
    return rel
  end

  local function taint_rel(rel)
    if not rel then
      return
    end
    local desc = descriptors[rel]
    if not desc then
      descriptors[rel] = {
        dir = nil,
        tainted_self = true,
        tainted_from_parent = false,
      }
    else
      desc.dir = nil
      desc.tainted_self = true
    end
  end

  local function taint_from_arg(arg_text, only_if_included)
    local lit = unquote_literal(arg_text)
    if not lit then
      has_untargeted_dir_override = true
      if is_slashy_literal(arg_text, is_groovy) then
        add_note("unsupported Groovy slashy/dollar-slashy string in project")
      end
      return
    end
    local rel, reason = normalize_gradle_logical(lit)
    if reason then
      add_note(reason)
    end
    if not rel then
      return
    end
    if only_if_included and not descriptors[rel] then
      return
    end
    taint_rel(rel)
  end

  local function handle_include_args(raw_args)
    local args = split_top_level_args(raw_args, is_groovy)
    if #args == 0 then
      return
    end
    for _, arg in ipairs(args) do
      local lit = unquote_literal(arg)
      if lit then
        add_logical(lit)
      elseif is_slashy_literal(arg, is_groovy) then
        add_note("unsupported Groovy slashy/dollar-slashy string in include")
      else
        -- literal alone inside concatenation/expression must never invent a module
        add_note("dynamic include not interpreted")
      end
    end
  end

  local function handle_include_flat_args(raw_args)
    local args = split_top_level_args(raw_args, is_groovy)
    if #args == 0 then
      return
    end
    for _, arg in ipairs(args) do
      local lit = unquote_literal(arg)
      if lit then
        local rel = normalize_gradle_logical(lit)
        add_note("includeFlat outside the aggregator: " .. (rel or lit))
      elseif is_slashy_literal(arg, is_groovy) then
        add_note("unsupported Groovy slashy/dollar-slashy string in includeFlat")
      else
        add_note("dynamic includeFlat not interpreted")
      end
    end
  end

  local function handle_project_dir(proj_call, rhs, only_if_included)
    local raw_arg = proj_call:sub(2, -2)
    local proj_lit = unquote_literal(raw_arg)
    if not proj_lit then
      has_untargeted_dir_override = true
      if is_slashy_literal(raw_arg, is_groovy) then
        add_note("unsupported Groovy slashy/dollar-slashy string in project")
      else
        add_note("dynamic projectDir not interpreted")
      end
      return
    end
    local rel, proj_reason = normalize_gradle_logical(proj_lit)
    if proj_reason then
      add_note(proj_reason)
    end
    if not rel then
      if vim.trim(proj_lit) == ":" or vim.trim(proj_lit) == "" then
        has_untargeted_dir_override = true
        add_note("root projectDir override not supported")
      end
      return
    end
    if not descriptors[rel] then
      if only_if_included then
        return
      end
      add_note("projectDir on unincluded project not evaluated: :" .. (rel:gsub("/", ":")))
      taint_rel(rel)
      return
    end

    local dir_val, is_abs, dir_reason = parse_static_project_dir(rhs, 0, is_groovy)
    if dir_val then
      local desc = descriptors[rel]
      if desc and not desc.tainted_self then
        desc.dir = is_abs and dir_val or (root .. "/" .. dir_val)
        desc.tainted_from_parent = false
      end
    else
      -- never fall back to default root/rel when projectDir was overridden dynamically
      taint_rel(rel)
      add_note(dir_reason or "dynamic projectDir not interpreted")
    end
  end

  local function handle_project_block(proj_call, body, only_if_included)
    local raw_arg = proj_call:sub(2, -2)
    local proj_lit = unquote_literal(raw_arg)
    if not proj_lit then
      has_untargeted_dir_override = true
      add_note("dynamic projectDir not interpreted")
      return
    end
    local block_rel, proj_reason = normalize_gradle_logical(proj_lit)
    if proj_reason then
      add_note(proj_reason)
    end
    if not block_rel then
      return
    end
    if only_if_included and not descriptors[block_rel] then
      return
    end
    for _, sub in ipairs(split_gradle_statements(body:sub(2, -2), is_groovy)) do
      local code_only = strip_string_literals(sub, is_groovy)
      local rhs = sub:match("^this%s*%.%s*projectDir%s*=%s*(.+)$") or sub:match("^projectDir%s*=%s*(.+)$")
      if rhs and not is_gradle_control_flow(code_only) then
        handle_project_dir(proj_call, rhs, only_if_included)
      elseif
        is_gradle_control_flow(code_only)
        and (
          has_project_dir_assignment(code_only)
          or has_set_project_dir(code_only)
          or has_set_property_project_dir(code_only, sub)
          or code_only:match("^[%w_%.]+%s*=[^=]")
          or code_only:match("%f[%w_]set[%u][%w_]*%f[^%w_]")
        )
      then
        add_note("dynamic/conditional Gradle declaration not evaluated")
        taint_rel(block_rel)
      elseif has_set_project_dir(code_only) then
        add_note("unsupported setProjectDir not evaluated")
        taint_rel(block_rel)
      elseif has_project_dir_assignment(code_only) or has_set_property_project_dir(code_only, sub) then
        add_note("dynamic projectDir not interpreted")
        taint_rel(block_rel)
      elseif
        code_only:match("^%s*[%w_%.]+%s*=[^=]")
        or code_only:match("^%s*[%w_%.]+%s*=$")
        or code_only:match("%f[%w_]set[%u][%w_]*%s*[%(%s\"']")
        or code_only:match("^%s*[%w_]+%s*%b{}")
      then
        add_note("unsupported project setter not evaluated")
        taint_rel(block_rel)
      end
    end
  end

  local function record_project_var_alias(stmt)
    local var_name, rhs_expr = stmt:match("^def%s+([%w_]+)%s*=%s*(.+)$")
    if not var_name then
      var_name, rhs_expr = stmt:match("^val%s+([%w_]+)%s*=%s*(.+)$")
    end
    if not var_name then
      var_name, rhs_expr = stmt:match("^var%s+([%w_]+)%s*=%s*(.+)$")
    end
    if not var_name then
      var_name, rhs_expr = stmt:match("^final%s+([%w_]+)%s*=%s*(.+)$")
    end
    if not var_name then
      var_name, rhs_expr = stmt:match("^([%w_]+)%s*=%s*(.+)$")
    end
    if not var_name or var_name == "rootProject" or not rhs_expr then
      return false
    end
    rhs_expr = vim.trim(rhs_expr):gsub("^settings%s*%.%s*", "")
    local call_args = rhs_expr:match("^project%s*(%b())$") or rhs_expr:match("^findProject%s*(%b())$")
    if not call_args then
      return false
    end
    local lit = unquote_literal(call_args:sub(2, -2))
    local rel = lit and normalize_gradle_logical(lit) or nil
    var_to_rel[var_name] = rel or false
    return true
  end

  local function taint_receiver_or_untargeted(stmt)
    local recv = stmt:match("^([%w_]+)%s*%??%.")
    if recv and var_to_rel[recv] then
      taint_rel(var_to_rel[recv])
    else
      has_untargeted_dir_override = true
    end
  end

  for _, stmt in ipairs(split_gradle_statements(text, is_groovy)) do
    local s = stmt
      :gsub("^settings%s*%.%s*(includeFlat%f[^%w_])", "%1")
      :gsub("^settings%s*%.%s*(include%f[^%w_])", "%1")
      :gsub("^settings%s*%.%s*(project%s*%()", "%1")
      :gsub("^settings%s*%.%s*(findProject%s*%()", "%1")
      :gsub("^settings%s*%.%s*(apply%f[^%w_])", "%1")
    local code_only = strip_string_literals(s, is_groovy)

    if is_gradle_control_flow(code_only) then
      local body_only = strip_control_headers(s, is_groovy)
      local body_code = strip_string_literals(body_only, is_groovy)
      local body_calls = extract_project_calls(body_only, is_groovy)
      local body_has_mutation = body_code:match("=") ~= nil
        or body_code:match("{") ~= nil
        or body_code:match("%f[%w_]set[%u][%w_]*%f[^%w_]") ~= nil
      local mutates_dir = has_project_dir_assignment(body_code)
        or has_set_project_dir(body_code)
        or has_set_property_project_dir(body_code, body_only)
        or (#body_calls > 0 and body_has_mutation)
      if has_apply_from(body_only, body_code) then
        add_note("external Gradle script (apply from) not evaluated")
        has_untargeted_dir_override = true
      end
      if code_only:match("%f[%w_]include%f[^%w_]") or code_only:match("%f[%w_]includeFlat%f[^%w_]") or mutates_dir then
        add_note("dynamic/conditional Gradle declaration not evaluated")
        if mutates_dir then
          if #body_calls > 0 then
            for _, call in ipairs(body_calls) do
              taint_from_arg(call.arg, call.is_find)
            end
          else
            -- Check for variable-based overrides like `if (cond) { p.projectDir = ... }`
            local tainted_var = false
            for var_name, rel in pairs(var_to_rel) do
              if body_code:match("%f[%w_]" .. var_name .. "%s*%??%.") then
                if rel then
                  taint_rel(rel)
                else
                  has_untargeted_dir_override = true
                end
                tainted_var = true
              end
            end
            if not tainted_var then
              has_untargeted_dir_override = true
            end
          end
        end
      end
    elseif has_apply_from(s, code_only) then
      add_note("external Gradle script (apply from) not evaluated")
      has_untargeted_dir_override = true
    elseif not record_project_var_alias(s) then
      local inc_parens = s:match("^include%s*(%b())$")
      local inc_bare = not inc_parens and s:match("^include%s+(.+)$")
      local flat_parens = s:match("^includeFlat%s*(%b())$")
      local flat_bare = not flat_parens and s:match("^includeFlat%s+(.+)$")

      if inc_parens then
        handle_include_args(inc_parens:sub(2, -2))
      elseif inc_bare and not inc_bare:match("^=") then
        handle_include_args(inc_bare)
      elseif flat_parens then
        handle_include_flat_args(flat_parens:sub(2, -2))
      elseif flat_bare and not flat_bare:match("^=") then
        handle_include_flat_args(flat_bare)
      else
        local proj_call, rhs = s:match("^project%s*(%b())%s*%.%s*projectDir%s*=%s*(.+)$")
        local find_call, find_rhs = s:match("^findProject%s*(%b())%s*%??%.%s*projectDir%s*=%s*(.+)$")
        local blk_call, blk_body = s:match("^project%s*(%b())%s*%.%s*apply%s*(%b{})$")
        local blk_is_find = false
        if not blk_call then
          blk_call, blk_body = s:match("^project%s*(%b())%s*(%b{})$")
        end
        if not blk_call then
          blk_call, blk_body = s:match("^findProject%s*(%b())%s*%??%.%s*apply%s*(%b{})$")
          if not blk_call then
            blk_call, blk_body = s:match("^findProject%s*(%b())%s*(%b{})$")
          end
          blk_is_find = blk_call ~= nil
        end
        local with_arg, with_body = s:match("^with%s*(%b())%s*(%b{})$")
        local with_inner = with_arg and vim.trim(with_arg:sub(2, -2)):gsub("^settings%s*%.%s*", "") or nil
        local with_proj = with_inner and with_inner:match("^project%s*(%b())$") or nil
        local with_find = with_inner and not with_proj and with_inner:match("^findProject%s*(%b())$") or nil

        if proj_call and rhs then
          handle_project_dir(proj_call, rhs, false)
        elseif find_call and find_rhs then
          handle_project_dir(find_call, find_rhs, true)
        elseif blk_call and blk_body then
          handle_project_block(blk_call, blk_body, blk_is_find)
        elseif with_proj and with_body then
          handle_project_block(with_proj, with_body, false)
        elseif with_find and with_body then
          handle_project_block(with_find, with_body, true)
        else
          local raw_call, safe_nav, rest = s:match("^project%s*(%b())%s*(%??)%s*%.%s*(.+)$")
          local call_is_find = false
          if not raw_call then
            raw_call, safe_nav, rest = s:match("^findProject%s*(%b())%s*(%??)%s*%.%s*(.+)$")
            call_is_find = raw_call ~= nil
          end
          if raw_call and rest then
            local rest_code = strip_string_literals(rest, is_groovy)
            local only_if_inc = call_is_find and safe_nav == "?"
            if has_set_project_dir(rest_code) then
              add_note("unsupported setProjectDir not evaluated")
              taint_from_arg(raw_call:sub(2, -2), only_if_inc)
            elseif
              rest_code:match("^[%w_]+%s*%b{}")
              or rest_code:match("^[%w_]+%s*%b()%s*%b{}")
              or rest_code:match("^set[%u][%w_]*%f[^%w_]")
              or rest_code:match("^[%w_]+%s*=[^=]")
              or rest_code:match("^[%w_]+%s*=$")
            then
              add_note("unsupported project setter not evaluated")
              taint_from_arg(raw_call:sub(2, -2), only_if_inc)
            end
          else
            if code_only:match("%f[%w_]include%f[^%w_]%s*%(") or code_only:match("%f[%w_]include%s+[%w_%$\"']") then
              add_note("dynamic include not interpreted")
            end
            if code_only:match("%f[%w_]includeFlat%f[^%w_]") then
              add_note("dynamic includeFlat not interpreted")
            end
            if has_set_project_dir(code_only) then
              add_note("unsupported setProjectDir not evaluated")
              taint_receiver_or_untargeted(s)
            elseif has_project_dir_assignment(code_only) then
              add_note("dynamic projectDir not interpreted")
              taint_receiver_or_untargeted(s)
            elseif has_set_property_project_dir(code_only, s) then
              add_note("unsupported project setter not evaluated")
              taint_receiver_or_untargeted(s)
            end
          end
        end
      end
    end
  end

  local dirs, seen_dir, logical_by_dir = {}, {}, {}
  if not has_untargeted_dir_override then
    for _, rel in ipairs(order) do
      local desc = descriptors[rel]
      if desc and not desc.tainted_self and not desc.tainted_from_parent and desc.dir then
        local resolved, exists = resolve_lexical_or_canonical(desc.dir)
        if not subtree(root, resolved) then
          add_note("projectDir/include outside the aggregator: " .. rel)
        elseif exists and resolved ~= root and isdir(resolved) and not seen_dir[resolved] then
          seen_dir[resolved] = true
          dirs[#dirs + 1] = resolved
          logical_by_dir[resolved] = ":" .. (rel:gsub("/", ":"))
        end
      end
    end
  end
  table.sort(dirs)

  local note
  if #notes > 0 then
    note = ("partial Gradle module discovery (%s) — future integration with official Gradle tools"):format(
      table.concat(notes, "; ")
    )
  end
  return dirs, note, logical_by_dir
end

---Higher aggregator whose reactor declares `dir` as a module (directly or
---transitively). Needed for nested paths declared with the full path from the
---top (<module>libraries/core</module>).
---@param dir string
---@return string|nil
function topmost_aggregator(dir)
  local target = canonical(dir)
  if not target then
    return nil
  end
  local top, depth = nil, 0
  local cur = vim.fs.dirname(target)
  while cur and cur ~= "" and cur ~= vim.fs.dirname(cur) and depth < 16 do
    depth = depth + 1
    local declared
    if isfile(cur .. "/pom.xml") then
      declared = maven_modules(cur, {})
    elseif isfile(cur .. "/settings.gradle") or isfile(cur .. "/settings.gradle.kts") then
      declared = gradle_modules(cur)
    end
    if declared then
      for _, mod in ipairs(declared) do
        if mod == target then
          top = cur
          break
        end
      end
    end
    cur = vim.fs.dirname(cur)
  end
  return top
end

---Project modules: the root plus modules declared in the build
---(Maven: aggregator <modules>, recursive; Gradle: static includes from
---settings.gradle(.kts)). Without declarations: only the root (single-module).
---Undeclared folders with pom.xml are not reactor modules.
---@param root string
---@return string[]
local function modules(root)
  root = canonical(root) or vim.fs.normalize(root)
  local list = { root }
  if isfile(root .. "/pom.xml") then
    vim.list_extend(list, maven_modules(root, { [root] = true }, 0))
  else
    local declared = gradle_modules(root)
    vim.list_extend(list, declared)
  end
  return list
end

---Project modules (root + declared submodules, recursive).
---@param root string
---@return string[]
function M.modules(root)
  return modules(root)
end

---Module discovery limitation (nil when discovery is complete).
---Currently only happens with dynamic Gradle (the script is not evaluated).
---@param root string
---@return string|nil note
function M.discovery_limitation(root)
  root = canonical(root) or vim.fs.normalize(root)
  if isfile(root .. "/pom.xml") then
    return nil
  end
  local _, note = gradle_modules(root)
  return note
end

---Logical Gradle path of the module (`:services:api`), for tasks
---(`:services:api:build`). With static projectDir, the logical path comes from
---settings (`:custom` even with physical dir `libs/custom-dir`). Fallback: relative.
---@param root string
---@param dir string
---@return string
function M.gradle_path(root, dir)
  root = canonical(root) or vim.fs.normalize(root)
  dir = canonical(dir) or vim.fs.normalize(dir)
  local _, _, logical_by_dir = gradle_modules(root)
  if logical_by_dir[dir] then
    return logical_by_dir[dir]
  end
  local rel = vim.fs.relpath(root, dir)
  if rel and rel ~= "." and not rel:match("^%.%.") then
    return ":" .. (rel:gsub("/", ":"))
  end
  return ":" .. vim.fs.basename(dir)
end

---Existing source roots (src/main/java, src/test/java) of each module.
---@param root string
---@return table[] { path, module, set, label }
function M.source_roots(root)
  local canon_root = canonical(root) or vim.fs.normalize(root)
  local out = {}
  for _, mod in ipairs(modules(root)) do
    for _, set in ipairs({ "main", "test" }) do
      local path = mod .. "/src/" .. set .. "/java"
      if isdir(path) then
        local name = vim.fs.basename(mod)
        out[#out + 1] = {
          path = path,
          module = name,
          set = set,
          -- short label; the project root does not repeat the module name
          label = (mod == canon_root and "" or (name .. " · ")) .. "src/" .. set .. "/java",
        }
      end
    end
  end
  return out
end

---Source root containing the buffer, preferring src/main/java.
---@param roots table[]
---@param buf number|nil
---@return table|nil
function M.preferred(roots, buf)
  local name = M.start_path(buf)
  for _, r in ipairs(roots) do
    local rp = resolve_lexical_or_canonical(r.path)
    if r.set == "main" and subtree(rp, name) then
      return r
    end
  end
  for _, r in ipairs(roots) do
    if r.set == "main" then
      return r
    end
  end
  return roots[1]
end

---Existing packages under a source root (for suggestions).
---@param source_root string
---@param limit integer|nil
---@return string[]
function M.packages(source_root, limit)
  source_root = resolve_lexical_or_canonical(source_root)
  local seen, out = {}, {}
  local files = vim.fs.find(function(name)
    return name:sub(-5) == ".java"
  end, { path = source_root, type = "file", limit = 500 })

  for _, file in ipairs(files) do
    local rel = vim.fs.relpath(source_root, vim.fs.dirname(file))
    if rel and rel ~= "" and rel ~= "." and not rel:match("^%.%.") then
      local pkg = rel:gsub("/", ".")
      if not seen[pkg] then
        seen[pkg] = true
        out[#out + 1] = pkg
      end
    end
  end

  table.sort(out)
  if limit and #out > limit then
    return vim.list_slice(out, 1, limit)
  end
  return out
end

---Suggested package for a buffer inside a source root.
---Also works for directories (netrw).
---@param buf number|nil
---@param source_root string
---@return string
function M.package_for(buf, source_root)
  buf = buf and buf > 0 and buf or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return ""
  end

  if not isdir(name) and vim.bo[buf].filetype == "java" then
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, 30, false)) do
      local pkg = line:match("^%s*package%s+([%w_%.]+)%s*;")
      if pkg then
        return pkg
      end
    end
  end

  local dir = isdir(name) and name or vim.fs.dirname(name)
  local canon_sr = resolve_lexical_or_canonical(source_root)
  local canon_dir = resolve_lexical_or_canonical(dir)
  local rel = vim.fs.relpath(canon_sr, canon_dir)
  if rel and rel ~= "" and rel ~= "." and not rel:match("^%.%.") then
    return (rel:gsub("/", "."))
  end
  return ""
end

-- ---------- project-exclusive JDTLS workspace ----------

---Stable JDTLS workspace identifier derived from the full canonical root path.
---The escape is injective (`%` → `%%`, `/` → `%`), so different projects never
---collide — even with the same basename — and the same project always yields
---the same identifier (deterministic across processes, no hash). E.g.
---`/tmp/a/proj` → `%tmp%a%proj`.
---After changing from basename to full identifier, JDTLS creates a new
---workspace on first use; the old directory (`<data>/jdtls/<basename>`) is not
---deleted or migrated automatically.
---@param root string
---@return string
function M.workspace_id(root)
  local canonical_root = resolve_lexical_or_canonical(root)
  return (canonical_root:gsub("%%", "%%%%"):gsub("/", "%%"))
end

---Project-exclusive `-data` directory (JDTLS creates it when missing).
---@param root string
---@return string
function M.workspace_dir(root)
  return vim.fs.joinpath(vim.fn.stdpath("data"), "jdtls", M.workspace_id(root))
end

---`-data` directory used by the active JDTLS client, read from its cmd.
---@param client vim.lsp.Client|nil
---@return string|nil
function M.client_workspace_dir(client)
  local cmd = client and client.config and client.config.cmd
  if type(cmd) ~= "table" then
    return nil
  end
  for i, arg in ipairs(cmd) do
    if arg == "-data" and cmd[i + 1] then
      return cmd[i + 1]
    end
  end
  return nil
end

return M
