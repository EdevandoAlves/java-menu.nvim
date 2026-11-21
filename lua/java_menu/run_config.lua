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

local function cfg_overlaps_env(cfg, env_map)
  if type(env_map) ~= "table" or next(env_map) == nil then
    return false
  end
  return M.overlaps_env({ cfg.profile }, env_map)
    or M.overlaps_env(cfg.jvm_args, env_map)
    or M.overlaps_env(cfg.app_args, env_map)
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
  if env_res.exists and next(env_res.env) ~= nil then
    local cleared = false
    if M.overlaps_env({ cfg.profile }, env_res.env) then
      cfg.profile = ""
      cleared = true
    end
    if M.overlaps_env(cfg.jvm_args, env_res.env) then
      cfg.jvm_args = ""
      cleared = true
    end
    if M.overlaps_env(cfg.app_args, env_res.env) then
      cfg.app_args = ""
      cleared = true
    end
    if cleared then
      return cfg, "persisted run settings overlapped with .env values (including short substrings) and were cleared"
    end
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

---Textual scan of `src/main/resources/application*.{yml,yaml,properties}`
---(and `src/main/resources/config/`) for Spring Boot profile names.
---@param root string
---@param module string|nil
---@return { profiles: string[], has_default: boolean }
function M.scan_profiles(root, module)
  local bases = {}
  local seen_base = {}
  local function add_base(dir)
    if type(dir) ~= "string" or dir == "" then
      return
    end
    local canon = M.canonical(dir)
    if not seen_base[canon] then
      seen_base[canon] = true
      bases[#bases + 1] = canon
    end
  end

  if module and module ~= "" then
    add_base(module)
    add_base(root)
  else
    add_base(root)
    for _, mod in ipairs(project.modules(root)) do
      add_base(mod)
    end
  end

  local seen_profile, profiles = {}, {}
  local has_default = false

  local function scan_dir(res_dir)
    if vim.fn.isdirectory(res_dir) ~= 1 then
      return
    end
    local handle = vim.uv.fs_scandir(res_dir)
    if not handle then
      return
    end
    while true do
      local name, typ = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if typ == "file" or typ == nil then
        if name:match("^application%.properties$") or name:match("^application%.ya?ml$") then
          has_default = true
        else
          local profile = name:match("^application%-([%w%-%_%.]+)%.properties$")
            or name:match("^application%-([%w%-%_%.]+)%.ya?ml$")
          if profile and profile ~= "" and not seen_profile[profile] then
            seen_profile[profile] = true
            profiles[#profiles + 1] = profile
          end
        end
      end
    end
  end

  for _, base in ipairs(bases) do
    scan_dir(base .. "/src/main/resources")
    scan_dir(base .. "/src/main/resources/config")
  end

  table.sort(profiles)
  return {
    profiles = profiles,
    has_default = has_default,
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
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return {
      exists = true,
      path = path,
      env = {},
      keys = {},
      warnings = { ".env could not be read (ignored)" },
    }
  end
  local parsed = M.parse_env_lines(lines)
  return {
    exists = true,
    path = path,
    env = parsed.env,
    keys = parsed.keys,
    warnings = parsed.warnings,
  }
end

---Collect sorted secret values from an env table for literal redaction.
---@param env_map table<string, string>|nil
---@return string[]
function M.collect_redactions(env_map)
  if type(env_map) ~= "table" then
    return {}
  end
  local seen, list = {}, {}
  for _, val in pairs(env_map) do
    if type(val) == "string" and val ~= "" and not seen[val] then
      seen[val] = true
      list[#list + 1] = val
    end
  end
  table.sort(list, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  return list
end

---Replace literal occurrences of any secret in `text` with `[REDACTED]`.
---@param text string
---@param secrets string[]|nil
---@return string
function M.redact(text, secrets)
  if type(text) ~= "string" or text == "" or type(secrets) ~= "table" or #secrets == 0 then
    return text
  end
  local parts, pos = {}, 1
  while pos <= #text do
    local first, last
    for _, secret in ipairs(secrets) do
      if type(secret) == "string" and secret ~= "" then
        local a, b = text:find(secret, pos, true)
        if a and (not first or a < first or (a == first and b > last)) then
          first, last = a, b
        end
      end
    end
    if not first then
      parts[#parts + 1] = text:sub(pos)
      break
    end
    parts[#parts + 1] = text:sub(pos, first - 1)
    parts[#parts + 1] = "[REDACTED]"
    pos = last + 1
  end
  return table.concat(parts)
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

local function token_overlaps_secret(token, secret)
  if type(token) ~= "string" or token == "" or type(secret) ~= "string" or secret == "" then
    return false
  end
  if token:find(secret, 1, true) then
    return true
  end
  local rhs = token:match("^[^=]+=(.+)$")
  if rhs then
    local sub_args = M.split_args(rhs)
    if sub_args then
      for _, sub in ipairs(sub_args) do
        if sub:find(secret, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

---Return true when `input` (argument string or argv list) overlaps a `.env` value.
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
  if type(input) == "table" then
    tokens = input
  elseif type(input) == "string" then
    if vim.trim(input) == "" then
      return false
    end
    local parsed = M.split_args(input)
    if parsed then
      tokens = parsed
    else
      tokens = vim.split(vim.trim(input), "%s+", { trimempty = true })
    end
  else
    return false
  end

  local secrets = M.collect_redactions(env_map)
  for _, secret in ipairs(secrets) do
    for _, tok in ipairs(tokens) do
      if token_overlaps_secret(tok, secret) then
        return true
      end
    end
    if type(input) == "string" and input:find(secret, 1, true) then
      return true
    end
  end
  return false
end

return M
