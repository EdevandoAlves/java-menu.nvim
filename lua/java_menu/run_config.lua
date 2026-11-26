-- java_menu/run_config.lua
-- Per-project run configuration (profiles, JVM/app args), contextual Spring
-- profile discovery, optional .env parsing without execution, and secret
-- redaction for logs/notifications/command displays.
--
-- Persistence uses per-root JSON files under stdpath("data")/java_menu/run/
-- keyed by a SHA-256 digest of the canonical root (`settings-<sha256>.json` and
-- `build-<sha256>.json`) and checks the stored canonical `root` owner before
-- loading. Legacy `project.workspace_id(root)` files without ownership proof
-- are ignored (neither imported nor deleted) because `workspace_id` can
-- collide across distinct canonical paths such as `/a%/b` and `/a/%b`.
-- `jc.settings` is intentionally NOT used here because it keys by cwd project
-- basename rather than canonical buffer root and reads only a single line.
--
-- Secrets loaded from `.env` are NEVER persisted, logged, notified, or stored
-- in command strings / restart records.

local project = require("java_menu.project")

local M = {}

---Optional override for tests (nil = stdpath("data")/java_menu/run).
M._base_dir = nil

---@param path string
---@return string
function M.canonical(path)
  local real = vim.uv.fs_realpath(path) or path
  return vim.fs.normalize(real)
end

---@return string
local function base_dir()
  if M._base_dir and M._base_dir ~= "" then
    return M._base_dir
  end
  return vim.fs.joinpath(vim.fn.stdpath("data"), "java_menu", "run")
end

---@param root string
---@return string
function M.storage_path(root)
  local canon = M.canonical(root)
  return vim.fs.joinpath(base_dir(), "settings-" .. vim.fn.sha256(canon) .. ".json")
end

---@return table
function M.defaults()
  return {
    version = 2,
    profile = "",
    jvm_args = "",
    app_args = "",
    use_env = true,
  }
end

local function sanitize(raw)
  local cfg = M.defaults()
  if type(raw) ~= "table" then
    return cfg
  end
  if type(raw.profile) == "string" then
    cfg.profile = raw.profile
  end
  if type(raw.jvm_args) == "string" then
    cfg.jvm_args = raw.jvm_args
  end
  if type(raw.app_args) == "string" then
    cfg.app_args = raw.app_args
  end
  if type(raw.use_env) == "boolean" then
    cfg.use_env = raw.use_env
  end
  return cfg
end

local CFG_FIELDS = { "profile", "jvm_args", "app_args" }

local function parse_field_tokens(val)
  if type(val) ~= "string" or vim.trim(val) == "" then
    return {}
  end
  local parsed = M.split_args(val)
  if parsed then
    return parsed
  end
  return vim.split(vim.trim(val), "%s+", { trimempty = true })
end

local function field_subset_overlaps_env(cfg, indices, env_map)
  local raw_parts = {}
  local argv_tokens = {}
  for _, idx in ipairs(indices) do
    local val = cfg[CFG_FIELDS[idx]]
    if type(val) ~= "string" or val == "" then
      return false
    end
    raw_parts[#raw_parts + 1] = val
    for _, tok in ipairs(parse_field_tokens(val)) do
      argv_tokens[#argv_tokens + 1] = tok
    end
  end

  if #indices == 1 then
    if indices[1] == 1 and M.overlaps_env({ raw_parts[1] }, env_map) then
      return true
    end
    return M.overlaps_env(raw_parts[1], env_map) or (#argv_tokens > 0 and M.overlaps_env(argv_tokens, env_map))
  end

  if #argv_tokens > 0 and M.overlaps_env(argv_tokens, env_map) then
    return true
  end
  local raw_joined_space = table.concat(raw_parts, " ")
  if M.overlaps_env(raw_joined_space, env_map) then
    return true
  end
  local argv_joined_tight = table.concat(argv_tokens, "")
  if argv_joined_tight ~= "" and M.overlaps_env(argv_joined_tight, env_map) then
    return true
  end
  local raw_joined_tight = table.concat(raw_parts, "")
  if raw_joined_tight ~= raw_joined_space and M.overlaps_env(raw_joined_tight, env_map) then
    return true
  end
  return false
end

local CFG_SUBSETS = {
  { 1 },
  { 2 },
  { 3 },
  { 1, 2 },
  { 1, 3 },
  { 2, 3 },
  { 1, 2, 3 },
}

local function cfg_overlaps_env(cfg, env_map)
  if type(env_map) ~= "table" or next(env_map) == nil then
    return false
  end
  for _, subset in ipairs(CFG_SUBSETS) do
    if field_subset_overlaps_env(cfg, subset, env_map) then
      return true
    end
  end
  return false
end

---Clear only the minimal affected fields in `cfg` whose raw values or parsed
---argv combinations overlap `.env` values (never leaking secret values).
---@param cfg table
---@param env_map table<string, string>|nil
---@return boolean cleared
local function clear_overlapping_cfg_fields(cfg, env_map)
  if type(env_map) ~= "table" or next(env_map) == nil then
    return false
  end
  local marked = {}
  -- Check size 1 first, then size 2 among remaining, then size 3 if all remain.
  for idx = 1, #CFG_FIELDS do
    if field_subset_overlaps_env(cfg, { idx }, env_map) then
      marked[idx] = true
    end
  end
  local rem = {}
  for idx = 1, #CFG_FIELDS do
    if not marked[idx] then
      rem[#rem + 1] = idx
    end
  end
  if #rem >= 2 then
    local pair_marked = {}
    for i = 1, #rem - 1 do
      for j = i + 1, #rem do
        if field_subset_overlaps_env(cfg, { rem[i], rem[j] }, env_map) then
          pair_marked[rem[i]] = true
          pair_marked[rem[j]] = true
        end
      end
    end
    for idx, flag in pairs(pair_marked) do
      if flag then
        marked[idx] = true
      end
    end
  end
  if next(marked) == nil and field_subset_overlaps_env(cfg, { 1, 2, 3 }, env_map) then
    marked[1], marked[2], marked[3] = true, true, true
  end

  local cleared = false
  for idx, flag in pairs(marked) do
    if flag then
      cfg[CFG_FIELDS[idx]] = ""
      cleared = true
    end
  end
  return cleared
end

---Load persisted non-secret run settings for `root`.
---@param root string
---@return table cfg, string|nil err
function M.load(root)
  local canon = M.canonical(root)
  local path = M.storage_path(canon)
  if vim.fn.filereadable(path) ~= 1 then
    return M.defaults(), nil
  end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read or type(lines) ~= "table" then
    return M.defaults(), ("could not read run settings at %s"):format(path)
  end
  local raw_text = table.concat(lines, "\n")
  if vim.trim(raw_text) == "" then
    return M.defaults(), nil
  end
  local ok_json, decoded = pcall(vim.json.decode, raw_text)
  if not ok_json or type(decoded) ~= "table" then
    return M.defaults(), ("invalid run settings JSON at %s (using defaults)"):format(path)
  end
  if decoded.root ~= canon then
    return M.defaults(), ("run settings at %s do not belong to %s (ignored)"):format(path, canon)
  end
  local cfg = sanitize(decoded)
  local env_res = M.load_env(canon)
  if env_res.exists and clear_overlapping_cfg_fields(cfg, env_res.env) then
    return cfg, "persisted run settings overlapped with .env values (including short substrings) and were cleared"
  end
  return cfg, nil
end

---@param path string
---@param payload table
---@param label string
---@return boolean ok, string|nil err
local function write_private_json(path, payload, label)
  local dir = vim.fs.dirname(path)
  local ok_mkdir = pcall(vim.fn.mkdir, dir, "p")
  if not ok_mkdir or vim.fn.isdirectory(dir) ~= 1 then
    return false, ("could not create %s directory: %s"):format(label, dir)
  end

  local ok_enc, encoded = pcall(vim.json.encode, payload)
  if not ok_enc or type(encoded) ~= "string" then
    return false, ("could not encode %s"):format(label)
  end

  local fd, open_err = vim.uv.fs_open(path, "w", 384) -- 0600 owner read/write
  if not fd then
    return false, ("could not open %s file: %s"):format(label, tostring(open_err))
  end
  local ok_write, write_err = vim.uv.fs_write(fd, encoded .. "\n", 0)
  vim.uv.fs_close(fd)
  if not ok_write then
    return false, ("could not write %s file: %s"):format(label, tostring(write_err))
  end
  return true, nil
end

---Persist non-secret run settings for `root`. Never writes env vars or secrets.
---@param root string
---@param cfg table
---@return boolean ok, string|nil err
function M.save(root, cfg)
  local canon = M.canonical(root)
  local payload = sanitize(cfg)
  payload.version = 2
  payload.root = canon
  local env_res = M.load_env(canon)
  if env_res.exists and cfg_overlaps_env(payload, env_res.env) then
    return false, "run settings overlap with .env values (including short substrings) and were not persisted"
  end

  return write_private_json(M.storage_path(canon), payload, "run settings")
end

---@param root string
---@return string
function M.last_build_path(root)
  local canon = M.canonical(root)
  return vim.fs.joinpath(base_dir(), "build-" .. vim.fn.sha256(canon) .. ".json")
end

---Load persisted non-secret last build argv for `root`.
---@param root string
---@return string[]|nil argv, string|nil err
function M.load_last_build(root)
  local path = M.last_build_path(root)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, nil
  end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read or type(lines) ~= "table" then
    return nil, ("could not read last build record at %s"):format(path)
  end
  local raw_text = table.concat(lines, "\n")
  if vim.trim(raw_text) == "" then
    return nil, nil
  end
  local ok_json, decoded = pcall(vim.json.decode, raw_text)
  if
    not ok_json
    or type(decoded) ~= "table"
    or decoded.root ~= M.canonical(root)
    or type(decoded.args) ~= "table"
    or #decoded.args == 0
  then
    return nil, ("invalid last build JSON at %s (ignored)"):format(path)
  end
  local argv = {}
  for _, item in ipairs(decoded.args) do
    if type(item) ~= "string" then
      return nil, ("invalid last build entry at %s (ignored)"):format(path)
    end
    argv[#argv + 1] = item
  end
  local env_res = M.load_env(root)
  if env_res.exists and M.overlaps_env(argv, env_res.env) then
    return nil, "persisted last build overlapped with .env values (including short substrings) and was ignored"
  end
  return argv, nil
end

---Persist non-secret last build argv for `root`.
---@param root string
---@param argv string[]
---@return boolean ok, string|nil err
function M.save_last_build(root, argv)
  if type(argv) ~= "table" or #argv == 0 then
    return false, "last build requires non-empty arguments"
  end
  local clean = {}
  for _, item in ipairs(argv) do
    clean[#clean + 1] = tostring(item)
  end
  local env_res = M.load_env(root)
  if env_res.exists and M.overlaps_env(clean, env_res.env) then
    return false, "build arguments overlap with .env values (including short substrings) and were not persisted"
  end
  return write_private_json(
    M.last_build_path(root),
    { version = 2, root = M.canonical(root), args = clean },
    "last build"
  )
end

---Remove persisted run settings for `root`.
---@param root string
---@return boolean ok, string|nil err
function M.reset(root)
  local path = M.storage_path(root)
  if vim.fn.filereadable(path) ~= 1 then
    return true, nil
  end
  local ok, err = vim.uv.fs_unlink(path)
  if not ok then
    return false, ("could not remove run settings file: %s"):format(tostring(err))
  end
  return true, nil
end

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

---@param file_dir string
---@param base string
---@return boolean
local function has_nested_build_marker(file_dir, base)
  local dir = file_dir
  while dir and dir ~= "" and dir ~= base and is_subtree(base, dir) do
    for _, marker in ipairs(project.markers) do
      if vim.fn.filereadable(dir .. "/" .. marker) == 1 then
        return true
      end
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end
  return false
end

---@param name string
---@return { is_default: boolean, profile: string|nil, ext: string }|nil
local function classify_spring_config_name(name)
  local ext = name:match("^application%.(properties)$") or name:match("^application%.(ya?ml)$")
  if ext then
    return { is_default = true, profile = nil, ext = ext }
  end
  local profile, pext = name:match("^application%-([%w%-%_%.]+)%.(properties)$")
  if not profile then
    profile, pext = name:match("^application%-([%w%-%_%.]+)%.(ya?ml)$")
  end
  if profile and profile ~= "" and pext then
    return { is_default = false, profile = profile, ext = pext }
  end
  local other_ext = name:match("^application.*%.(properties)$") or name:match("^application.*%.(ya?ml)$")
  if other_ext then
    return { is_default = false, profile = nil, ext = other_ext }
  end
  return nil
end

---Textual scan of `src/main/resources/application*.{yml,yaml,properties}`
---(and `src/main/resources/config/`) for Spring Boot profile names and
---configuration files within project/module boundaries.
---@param root string
---@param module string|nil
---@return { profiles: string[], has_default: boolean, files: table[] }
function M.scan_profiles(root, module)
  if type(root) ~= "string" or root == "" then
    return { profiles = {}, has_default = false, files = {} }
  end
  local real_root = vim.uv.fs_realpath(root)
  if not real_root or vim.fn.isdirectory(real_root) ~= 1 then
    return { profiles = {}, has_default = false, files = {} }
  end
  local canon_root = vim.fs.normalize(real_root)

  local declared_mods, declared_set = {}, {}
  for _, mod in ipairs(project.modules(canon_root)) do
    local rm = vim.uv.fs_realpath(mod)
    if rm then
      local cm = vim.fs.normalize(rm)
      if is_subtree(canon_root, cm) and not declared_set[cm] then
        declared_set[cm] = true
        declared_mods[#declared_mods + 1] = cm
      end
    end
  end
  if not declared_set[canon_root] then
    declared_set[canon_root] = true
    table.insert(declared_mods, 1, canon_root)
  end

  local bases, seen_base = {}, {}
  local function add_base(dir)
    if type(dir) ~= "string" or dir == "" then
      return
    end
    local rm = vim.uv.fs_realpath(dir)
    if not rm or vim.fn.isdirectory(rm) ~= 1 then
      return
    end
    local cm = vim.fs.normalize(rm)
    if is_subtree(canon_root, cm) and declared_set[cm] and not seen_base[cm] then
      seen_base[cm] = true
      bases[#bases + 1] = cm
    end
  end

  if module and module ~= "" then
    add_base(module)
    add_base(canon_root)
  else
    add_base(canon_root)
    for _, mod in ipairs(declared_mods) do
      add_base(mod)
    end
  end

  local function owner_module(path)
    local best, best_len = nil, -1
    for _, mod in ipairs(declared_mods) do
      if is_subtree(mod, path) and #mod > best_len then
        best = mod
        best_len = #mod
      end
    end
    return best
  end

  local seen_profile, profiles = {}, {}
  local seen_file, files = {}, {}
  local has_default = false

  local function scan_dir(base, res_dir, location)
    local real_res = vim.uv.fs_realpath(res_dir)
    if not real_res then
      return
    end
    real_res = vim.fs.normalize(real_res)
    local res_stat = vim.uv.fs_stat(real_res)
    if not res_stat or res_stat.type ~= "directory" then
      return
    end
    if
      not is_subtree(canon_root, real_res)
      or not is_subtree(base, real_res)
      or owner_module(real_res) ~= base
      or has_nested_build_marker(real_res, base)
    then
      return
    end

    local handle = vim.uv.fs_scandir(real_res)
    if not handle then
      return
    end
    while true do
      local name = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local spec = classify_spring_config_name(name)
      if spec then
        local real_file = vim.uv.fs_realpath(res_dir .. "/" .. name)
        if real_file then
          real_file = vim.fs.normalize(real_file)
          local st = vim.uv.fs_stat(real_file)
          if
            st
            and st.type == "file"
            and is_subtree(canon_root, real_file)
            and is_subtree(base, real_file)
            and owner_module(real_file) == base
            and not has_nested_build_marker(vim.fs.dirname(real_file), base)
            and vim.fn.filereadable(real_file) == 1
          then
            if spec.is_default then
              has_default = true
            elseif spec.profile and not seen_profile[spec.profile] then
              seen_profile[spec.profile] = true
              profiles[#profiles + 1] = spec.profile
            end
            if not seen_file[real_file] then
              seen_file[real_file] = true
              local mod_rel = base == canon_root and "root"
                or (vim.fs.relpath(canon_root, base) or vim.fs.basename(base))
              files[#files + 1] = {
                path = real_file,
                relpath = vim.fs.relpath(canon_root, real_file) or real_file,
                module = base,
                module_rel = mod_rel,
                location = location,
                name = name,
                ext = spec.ext,
                profile = spec.profile,
                is_default = spec.is_default,
              }
            end
          end
        end
      end
    end
  end

  for _, base in ipairs(bases) do
    scan_dir(base, base .. "/src/main/resources", "resources")
    scan_dir(base, base .. "/src/main/resources/config", "config")
  end

  table.sort(profiles)
  table.sort(files, function(a, b)
    return a.relpath < b.relpath
  end)
  return {
    profiles = profiles,
    has_default = has_default,
    files = files,
  }
end

---Parse simple `KEY=VALUE` lines without shell execution.
---Unsupported constructs (e.g. `export `, malformed lines, NUL bytes) are
---skipped with line-number-only warnings (never containing raw line values).
---@param lines string[]
---@return { env: table<string, string>, keys: string[], warnings: string[] }
function M.parse_env_lines(lines)
  local env, warnings = {}, {}
  for idx, raw_line in ipairs(lines or {}) do
    local line = raw_line:gsub("\r$", "")
    if not line:match("^%s*$") and not line:match("^%s*#") then
      if line:match("^%s*export%s+") then
        warnings[#warnings + 1] = (".env line %d: 'export' prefix is not supported (ignored)"):format(idx)
      else
        local key, raw_val = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=(.*)$")
        if not key then
          warnings[#warnings + 1] = (".env line %d: invalid KEY=VALUE syntax (ignored)"):format(idx)
        else
          local val = raw_val:match("^%s*(.-)%s*$")
          if #val >= 2 then
            local first, last = val:sub(1, 1), val:sub(-1)
            if (first == '"' and last == '"') or (first == "'" and last == "'") then
              val = val:sub(2, -2)
            end
          end
          if val:find("\0", 1, true) then
            warnings[#warnings + 1] = (".env line %d: NUL byte not allowed (ignored)"):format(idx)
          elseif val:find("\n", 1, true) then
            warnings[#warnings + 1] = (".env line %d: newline not allowed in value (ignored)"):format(idx)
          else
            env[key] = val
          end
        end
      end
    end
  end

  local keys = {}
  for k in pairs(env) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return {
    env = env,
    keys = keys,
    warnings = warnings,
  }
end

---Read and parse optional `root/.env` without executing it.
---@param root string
---@return { exists: boolean, path: string, env: table<string, string>, keys: string[], warnings: string[] }
function M.load_env(root)
  local path = M.canonical(root) .. "/.env"
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" then
    return {
      exists = false,
      path = path,
      env = {},
      keys = {},
      warnings = {},
    }
  end
  local fd = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return {
      exists = true,
      path = path,
      env = {},
      keys = {},
      warnings = { ".env could not be read (ignored)" },
    }
  end
  local chunks = {}
  local offset = 0
  while true do
    local chunk = vim.uv.fs_read(fd, 65536, offset)
    if type(chunk) ~= "string" then
      vim.uv.fs_close(fd)
      return {
        exists = true,
        path = path,
        env = {},
        keys = {},
        warnings = { ".env could not be read (ignored)" },
      }
    end
    if chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
    offset = offset + #chunk
  end
  vim.uv.fs_close(fd)
  local raw = table.concat(chunks)
  if raw:sub(1, 3) == "\239\187\191" then
    raw = raw:sub(4)
  end
  local lines = raw == "" and {} or vim.split(raw, "\n", { plain = true })
  local parsed = M.parse_env_lines(lines)
  return {
    exists = true,
    path = path,
    env = parsed.env,
    keys = parsed.keys,
    warnings = parsed.warnings,
  }
end

local MIN_DERIVED_REDACTION_LEN = 6

---Weak-keyed map from `collect_redactions(env_map)` return list to its derived
---Lua patterns (for mixed-case percent-encoded escapes with case-sensitive
---plain surrounding bytes). Keeps `collect_redactions`'s return value a pure `string[]`.
local derived_patterns = setmetatable({}, { __mode = "k" })

local function percent_encode(str, lower_hex)
  local fmt = lower_hex and "%%%02x" or "%%%02X"
  return (str:gsub("[^A-Za-z0-9._~-]", function(ch)
    return fmt:format(string.byte(ch))
  end))
end

---Build a single non-backtracking Lua pattern matching full RFC 3986
---percent-encoding of `str`: each `%XX` escape matches case-insensitively per
---hex digit, while plain unreserved bytes (`[A-Za-z0-9._~-]`) stay case-sensitive.
---@param str string
---@return string
local function percent_encode_lua_pattern(str)
  return (
    str:gsub(".", function(ch)
      if ch == "." or ch == "-" then
        return "%" .. ch
      end
      if ch:match("^[A-Za-z0-9_~]$") then
        return ch
      end
      local hx = ("%02X"):format(string.byte(ch))
      local h1 = hx:sub(1, 1)
      local h2 = hx:sub(2, 2)
      if h1 >= "A" and h1 <= "F" then
        h1 = "[" .. h1:lower() .. h1 .. "]"
      end
      if h2 >= "A" and h2 <= "F" then
        h2 = "[" .. h2:lower() .. h2 .. "]"
      end
      return "%%" .. h1 .. h2
    end)
  )
end

local function json_escape(str)
  return (
    str:gsub('[\\"\b\f\n\r\t]', {
      ["\\"] = "\\\\",
      ['"'] = '\\"',
      ["\b"] = "\\b",
      ["\f"] = "\\f",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
    })
  )
end

---@param env_map table<string, string>|nil
---@return { literals: string[], patterns: string[] }
local function collect_redaction_specs(env_map)
  if type(env_map) ~= "table" then
    return { literals = {}, patterns = {} }
  end
  local seen, list = {}, {}
  local seen_pat, patterns = {}, {}
  local function add(s)
    if type(s) == "string" and s ~= "" and not seen[s] then
      seen[s] = true
      list[#list + 1] = s
    end
  end
  for _, val in pairs(env_map) do
    if type(val) == "string" and val ~= "" then
      add(val)
      if #val >= MIN_DERIVED_REDACTION_LEN then
        local pct_upper = percent_encode(val, false)
        local pct_lower = percent_encode(val, true)
        add(pct_upper)
        add(pct_lower)
        if pct_upper ~= pct_lower then
          local pat = percent_encode_lua_pattern(val)
          if not seen_pat[pat] then
            seen_pat[pat] = true
            patterns[#patterns + 1] = pat
          end
        end
        add(json_escape(val))
      end
    end
  end
  table.sort(list, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  return { literals = list, patterns = patterns }
end

---Collect sorted secret values from an env table for redaction.
---For values with length >= 6, also includes RFC 3986 percent-encoded (upper/lower
---literals, plus a non-combinatoric per-escape case-insensitive matcher used by
---`redact`/`overlaps_env` with case-sensitive plain bytes) and standard JSON-escaped
---variants (`\\`, `\"`, `\b`, `\f`, `\n`, `\r`, `\t`).
---Limits: values < 6 bytes only match literally; partial percent-encoding (some
---reserved chars unencoded or unreserved `[A-Za-z0-9._~-]` chars encoded),
---`application/x-www-form-urlencoded` `+` spaces, double-encoding, and JSON `\uXXXX`
---escapes are not matched.
---@param env_map table<string, string>|nil
---@return string[]
function M.collect_redactions(env_map)
  local specs = collect_redaction_specs(env_map)
  derived_patterns[specs.literals] = specs.patterns
  return specs.literals
end

local function find_merged_spans(text, secrets)
  local spans = {}
  local function collect_spans(needle, plain)
    if type(needle) ~= "string" or needle == "" then
      return
    end
    local pos = 1
    while pos <= #text do
      local a, b = text:find(needle, pos, plain)
      if not a then
        break
      end
      spans[#spans + 1] = { a, b }
      pos = a + 1
    end
  end
  for _, secret in ipairs(secrets) do
    collect_spans(secret, true)
  end
  local patterns = derived_patterns[secrets]
  if patterns then
    for _, pat in ipairs(patterns) do
      collect_spans(pat, false)
    end
  end
  if #spans == 0 then
    return nil
  end
  table.sort(spans, function(x, y)
    if x[1] ~= y[1] then
      return x[1] < y[1]
    end
    return x[2] > y[2]
  end)

  local merged = { spans[1] }
  for i = 2, #spans do
    local cur = merged[#merged]
    local nxt = spans[i]
    if nxt[1] <= cur[2] then
      if nxt[2] > cur[2] then
        cur[2] = nxt[2]
      end
    else
      merged[#merged + 1] = nxt
    end
  end
  return merged
end

local function render_redacted(text, secrets, limit)
  local merged = find_merged_spans(text, secrets)
  if not merged then
    return limit < #text and text:sub(1, limit) or text
  end
  local parts = {}
  local pos = 1
  for _, span in ipairs(merged) do
    if span[1] > limit then
      break
    end
    if span[1] > pos then
      parts[#parts + 1] = text:sub(pos, span[1] - 1)
    end
    parts[#parts + 1] = "[REDACTED]"
    pos = span[2] + 1
    if span[2] >= limit then
      break
    end
  end
  if pos <= limit then
    parts[#parts + 1] = text:sub(pos, limit)
  end
  return table.concat(parts)
end

---Replace occurrences of any secret in `text` with `[REDACTED]`.
---Matches all literal entries in `secrets` and, when `secrets` was returned by
---`collect_redactions`, mixed-case percent-encoded escapes for values >= 6 bytes
---(with case-sensitive plain surrounding bytes).
---Overlapping matches (across distinct secrets or self-overlapping occurrences)
---are merged so no trailing fragment of an overlapped secret can leak.
---Operates per string/line; secrets split across newlines or streams are not matched.
---@param text string
---@param secrets string[]|nil
---@return string
function M.redact(text, secrets)
  if type(text) ~= "string" or text == "" or type(secrets) ~= "table" or #secrets == 0 then
    return text
  end
  return render_redacted(text, secrets, #text)
end

---Redact `text` while truncating output to at most original byte index `prefix_len`.
---`text` may include lookahead bytes past `prefix_len`; any secret starting at or
---before `prefix_len` and crossing `prefix_len` is replaced wholesale with
---`[REDACTED]` and nothing after that span (or after `prefix_len`) is emitted,
---so partial secret fragments can never leak at a truncation boundary.
---@param text string
---@param secrets string[]|nil
---@param prefix_len integer
---@return string
function M.redact_prefix(text, secrets, prefix_len)
  if type(text) ~= "string" then
    return text
  end
  local limit = math.max(0, math.min(#text, math.floor(tonumber(prefix_len) or 0)))
  -- If the cut falls inside a UTF-8 sequence, omit the entire character.
  if limit < #text then
    while limit > 0 do
      local next_byte = text:byte(limit + 1)
      if not next_byte or next_byte < 128 or next_byte >= 192 then
        break
      end
      limit = limit - 1
    end
  end
  if limit == 0 then
    return ""
  end
  if type(secrets) ~= "table" or #secrets == 0 then
    return text:sub(1, limit)
  end
  return render_redacted(text, secrets, limit)
end

---Redact a list of lines.
---@param lines string[]
---@param secrets string[]|nil
---@return string[]
function M.redact_lines(lines, secrets)
  if type(secrets) ~= "table" or #secrets == 0 then
    return lines
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = M.redact(line, secrets)
  end
  return out
end

---Split argument string on whitespace while preserving single/double quoted segments.
---Does not perform shell expansion or execution.
---@param text string|nil
---@return string[]|nil args, string|nil err
function M.split_args(text)
  if not text or vim.trim(text) == "" then
    return {}, nil
  end
  local s = vim.trim(text)
  local args = {}
  local cur = {}
  local quote = nil
  local in_token = false

  for i = 1, #s do
    local ch = s:sub(i, i)
    if quote then
      if ch == quote then
        quote = nil
      else
        cur[#cur + 1] = ch
      end
    else
      if ch == "'" or ch == '"' then
        quote = ch
        in_token = true
      elseif ch:match("%s") then
        if in_token then
          args[#args + 1] = table.concat(cur)
          cur = {}
          in_token = false
        end
      else
        cur[#cur + 1] = ch
        in_token = true
      end
    end
  end

  if quote ~= nil then
    return nil, "unclosed quote in arguments"
  end
  if in_token then
    args[#args + 1] = table.concat(cur)
  end
  return args, nil
end

---Format an argv list into a single-line string that roundtrips through `split_args`.
---@param argv string[]|nil
---@return string
function M.format_args(argv)
  if type(argv) ~= "table" then
    return ""
  end
  local out = {}
  for _, raw in ipairs(argv) do
    local arg = tostring(raw)
    if arg == "" then
      out[#out + 1] = '""'
    elseif not arg:find("[%s'\"]") then
      out[#out + 1] = arg
    elseif not arg:find('"', 1, true) then
      out[#out + 1] = '"' .. arg .. '"'
    elseif not arg:find("'", 1, true) then
      out[#out + 1] = "'" .. arg .. "'"
    else
      local parts = {}
      local pos = 1
      while pos <= #arg do
        local q = arg:find('"', pos, true)
        if not q then
          parts[#parts + 1] = '"' .. arg:sub(pos) .. '"'
          break
        end
        if q > pos then
          parts[#parts + 1] = '"' .. arg:sub(pos, q - 1) .. '"'
        end
        parts[#parts + 1] = "'\"'"
        pos = q + 1
      end
      out[#out + 1] = table.concat(parts)
    end
  end
  return table.concat(out, " ")
end

---Format an argv list for `jc.settings` (`build-last`) ONLY when `jc.nvim`'s
---whitespace-only parser (`vim.split(args, "%s+", { trimempty = true })` and
---single-line `file:read()`) can faithfully replay the exact argv list.
---Returns nil when any argument is empty or contains whitespace or quotes.
---@param argv string[]|nil
---@return string|nil
function M.format_jc_args(argv)
  if type(argv) ~= "table" or #argv == 0 then
    return nil
  end
  local out = {}
  for _, raw in ipairs(argv) do
    local arg = tostring(raw)
    if arg == "" or arg:find("[%s'\"]") then
      return nil
    end
    out[#out + 1] = arg
  end
  return table.concat(out, " ")
end

local function text_matches_parsed(text, needle, plain)
  local sub_args = M.split_args(text)
  if not sub_args then
    return false
  end
  for _, sub in ipairs(sub_args) do
    if sub:find(needle, 1, plain) then
      return true
    end
  end
  local sub_joined = table.concat(sub_args, " ")
  return sub_joined ~= "" and sub_joined:find(needle, 1, plain) ~= nil
end

local function token_overlaps_secret(token, secret, is_pattern)
  if type(token) ~= "string" or token == "" or type(secret) ~= "string" or secret == "" then
    return false
  end
  local plain = not is_pattern
  if token:find(secret, 1, plain) then
    return true
  end
  if text_matches_parsed(token, secret, plain) then
    return true
  end
  local rhs = token:match("^[^=]+=(.+)$")
  if rhs and text_matches_parsed(rhs, secret, plain) then
    return true
  end
  return false
end

---Return true when `input` (argument string or argv list) overlaps a `.env` value.
---Checks parsed tokens, the space-joined parsed token string, raw string input,
---and `KEY=VALUE` right-hand sides against literal `.env` values and (for values
--->= 6 bytes) RFC 3986 percent-encoded (per-escape case-insensitive hex digits
---with case-sensitive plain surrounding bytes) and standard JSON-escaped forms.
---Protects even short `.env` substrings (length >= 1) in user arguments/settings/history,
---accepting possible false positives to prevent leaking `.env` values.
---@param input string|string[]|nil
---@param env_map table<string, string>|nil
---@return boolean
function M.overlaps_env(input, env_map)
  if type(env_map) ~= "table" or next(env_map) == nil then
    return false
  end

  local tokens
  local raw_input = nil
  if type(input) == "table" then
    tokens = input
  elseif type(input) == "string" then
    if vim.trim(input) == "" then
      return false
    end
    raw_input = input
    local parsed = M.split_args(input)
    if parsed then
      tokens = parsed
    else
      tokens = vim.split(vim.trim(input), "%s+", { trimempty = true })
    end
  else
    return false
  end

  local specs = collect_redaction_specs(env_map)
  local joined_tokens = table.concat(tokens, " ")

  local function matches(needle, is_pattern)
    local plain = not is_pattern
    for _, tok in ipairs(tokens) do
      if token_overlaps_secret(tok, needle, is_pattern) then
        return true
      end
    end
    if joined_tokens ~= "" and joined_tokens:find(needle, 1, plain) then
      return true
    end
    if raw_input and raw_input ~= "" and raw_input ~= joined_tokens and raw_input:find(needle, 1, plain) then
      return true
    end
    return false
  end

  for _, secret in ipairs(specs.literals) do
    if matches(secret, false) then
      return true
    end
  end
  for _, pat in ipairs(specs.patterns) do
    if matches(pat, true) then
      return true
    end
  end
  return false
end

return M
