-- java_menu/jc.lua
-- Thin adapter for the jc.nvim surfaces used by the Java Menu.
--
-- jc.nvim is a required dependency; stable public APIs (jc.jdtls
-- generate_*/organize_*, jc.refactor.extract_*, jc.test.run_*,
-- jc.neotest_adapter...) continue to be called directly from the modules.
-- Only these live here: (1) the internal (underscore) functions actually used,
-- with availability checks and validated contracts; (2) jc.settings and
-- jc.import_style with checked contracts; (3) clear messages when the installed
-- jc diverges from what is expected. No monkey patching; jc.nvim is neither
-- modified nor copied.

local M = {}

---Load a jc module with a clear error.
---@param name string
---@return table|nil mod, string|nil err
local function jc_module(name)
  local ok, mod = pcall(require, name)
  if not ok or type(mod) ~= "table" then
    return nil, ('jc.nvim unavailable or incompatible: module "%s" did not load (%s)'):format(name, tostring(mod))
  end
  return mod
end

local function mod_fn(mod, name)
  return type(mod) == "table" and type(mod[name]) == "function" and mod[name] or nil
end

-- ---------- Replace Import (jc.jdtls internals) ----------

---Validated Replace Import API. Wraps the four jc.jdtls internals used by the
---menu (`_filter_type_symbols`, `_prioritize_types`, `_set_import`,
---`_remember_regular`). Returns nil + reason when the installed jc does not
---expose them (incompatible version) — the menu then falls back to jc's native
---flow (JCimportsReplace), guarded against multiple global clients.
---@return table|nil api, string|nil err
function M.replace_import_api()
  local mod, err = jc_module("jc.jdtls")
  if not mod then
    return nil, err
  end
  local parts = {}
  for _, name in ipairs({ "_filter_type_symbols", "_prioritize_types", "_set_import", "_remember_regular" }) do
    local f = mod_fn(mod, name)
    if not f then
      return nil, ("jc.nvim has no jc.jdtls.%s (internal API changed in this version)"):format(name)
    end
    parts[name] = f
  end

  return {
    ---workspace/symbol → list of importable FQNs.
    ---@return string[]|nil fqns, string|nil err
    filter_type_symbols = function(result, name)
      local ok, fqns = pcall(parts._filter_type_symbols, result, name, true)
      if not ok then
        return nil, ("jc._filter_type_symbols failed: %s"):format(tostring(fqns))
      end
      if type(fqns) ~= "table" then
        return nil, "jc._filter_type_symbols returned an unexpected type (expected a list of FQNs)"
      end
      return fqns
    end,
    ---Order FQNs according to jc preferences.
    ---@return string[]|nil fqns, string|nil err
    prioritize_types = function(fqns, bufnr)
      local ok, ordered = pcall(parts._prioritize_types, fqns, bufnr)
      if not ok then
        return nil, ("jc._prioritize_types failed: %s"):format(tostring(ordered))
      end
      if type(ordered) ~= "table" then
        return nil, "jc._prioritize_types returned an unexpected type (expected a list)"
      end
      return ordered
    end,
    ---Insert the import into the buffer (without saving).
    ---@return boolean ok, string|nil err
    set_import = function(bufnr, name, fqn)
      local ok, e = pcall(parts._set_import, bufnr, name, fqn)
      if not ok then
        return false, ("jc._set_import failed: %s"):format(tostring(e))
      end
      return true
    end,
    ---Remember the choice as a regular jc preference.
    ---@return boolean ok, string|nil err
    remember_regular = function(name, fqn)
      local ok, e = pcall(parts._remember_regular, name, fqn)
      if not ok then
        return false, ("jc._remember_regular failed: %s"):format(tostring(e))
      end
      return true
    end,
  }
end

-- build-last is the same state as jc's JCbuildLast; the project key is
-- resolved by cwd (a jc.settings implementation detail).
---Arguments of the last build persisted by jc (string or nil).
---@return string|nil value, string|nil err
function M.read_build_last()
  local mod, err = jc_module("jc.settings")
  if not mod then
    return nil, err
  end
  local read = mod_fn(mod, "read_project")
  if not read then
    return nil, "jc.nvim has no jc.settings.read_project"
  end
  local ok, value = pcall(read, "build-last")
  if not ok then
    return nil, ("jc.settings.read_project failed: %s"):format(tostring(value))
  end
  if value ~= nil and type(value) ~= "string" then
    return nil, "jc.settings returned an unexpected build-last value (expected a string)"
  end
  return value
end

---Persist the project's build-last value (string). Never throws.
---@param args string
---@return boolean ok, string|nil err
function M.write_build_last(args)
  if type(args) ~= "string" then
    return false, "build-last should be a string, got " .. type(args)
  end
  local mod, err = jc_module("jc.settings")
  if not mod then
    return false, err
  end
  local write = mod_fn(mod, "write_project")
  if not write then
    return false, "jc.nvim has no jc.settings.write_project"
  end
  local ok, e = pcall(write, "build-last", args)
  if not ok then
    return false, ("jc.settings.write_project failed: %s"):format(tostring(e))
  end
  return true
end

---jc import style (order/load/save/no_wildcards) with a checked contract.
---@return table|nil style, string|nil err
function M.import_style()
  local mod, err = jc_module("jc.import_style")
  if not mod then
    return nil, err
  end
  local order = mod.order
  if type(order) ~= "table" or #order == 0 then
    return nil, "unexpected jc.import_style.order (expected a preset list)"
  end
  for _, name in ipairs(order) do
    if type(name) ~= "string" then
      return nil, "jc.import_style.order contains non-string names"
    end
  end
  local load_fn, save_fn, nw_fn = mod_fn(mod, "load"), mod_fn(mod, "save"), mod_fn(mod, "no_wildcards")
  if not (load_fn and save_fn and nw_fn) then
    return nil, "jc.nvim has no jc.import_style.load/save/no_wildcards"
  end
  return {
    order = order,
    load = function()
      local ok, current = pcall(load_fn)
      if not ok then
        error("jc.import_style.load failed: " .. tostring(current), 0)
      end
      if current ~= nil and type(current) ~= "string" then
        error("jc.import_style.load returned an unexpected style", 0)
      end
      return current
    end,
    save = function(name, no_wildcards)
      local ok, e = pcall(save_fn, name, no_wildcards)
      if not ok then
        error("jc.import_style.save failed: " .. tostring(e), 0)
      end
    end,
    no_wildcards = function()
      local ok, v = pcall(nw_fn)
      if not ok then
        error("jc.import_style.no_wildcards failed: " .. tostring(v), 0)
      end
      return v == true
    end,
  }
end

---jc.test discovery internals used by Run Nearest (package tests when there
---is no paired test). nil + reason when the jc version does not expose them —
---the menu then continues to jc.test.run_at_cursor.
---@return table|nil api, string|nil err
function M.test_discovery_api()
  local mod, err = jc_module("jc.test")
  if not mod then
    return nil, err
  end
  local ntr, pt = mod_fn(mod, "_nothing_to_run"), mod_fn(mod, "_package_tests")
  if not (ntr and pt) then
    return nil, "jc.nvim has no jc.test._nothing_to_run/_package_tests (internal API changed in this version)"
  end
  return {
    ---true when the file has no runnable test (paired/package).
    ---@return boolean nothing, string|nil err
    nothing_to_run = function(path)
      local ok, v = pcall(ntr, path)
      if not ok then
        return false, ("jc._nothing_to_run failed: %s"):format(tostring(v))
      end
      return v == true
    end,
    ---Test classes in the package of `path` (same module).
    ---@return string[]|nil files, string|nil err
    package_tests = function(path)
      local ok, files = pcall(pt, path)
      if not ok then
        return nil, ("jc._package_tests failed: %s"):format(tostring(files))
      end
      if files == nil then
        return {}, nil
      end
      if type(files) ~= "table" then
        return nil, "jc._package_tests returned an unexpected type (expected a file list)"
      end
      return files
    end,
  }
end

---jc is in the middle of a long operation (enables Abstract Methods).
---A missing/erroring jc.lsp counts as "not busy" (preserved behavior).
---@return boolean
function M.jdtls_busy()
  local mod = jc_module("jc.lsp")
  local busy = mod and mod_fn(mod, "jdtls_busy")
  if not busy then
    return false
  end
  local ok, v = pcall(busy)
  return ok and v == true
end

return M
