-- java_menu/tests.lua
-- <leader>jt: JUnit tests via neotest + jc.nvim adapter and bidirectional
-- class <-> test navigation.
-- No custom runner: test execution delegates to jc public APIs (jc.test.*)
-- and neotest; classpath and JDK continue to come from jdtls.

local ui = require("java_menu.ui")
local project = require("java_menu.project")
local lsp = require("java_menu.lsp")
local jca = require("java_menu.jc")
local hierarchy = require("java_menu.hierarchy")

local M = {}

local skeleton_ctrl = hierarchy.new_controller({ feature_label = "test skeleton" })

local function neotest()
  local ok, nt = pcall(require, "neotest")
  if ok then
    return nt
  end
end

local function jc_test()
  local ok, mod = pcall(require, "jc.test")
  if ok then
    return mod
  end
end

---Use the active buffer as context; never guess a project from another buffer.
---@return integer
local function context_buf()
  return vim.api.nvim_get_current_buf()
end

---Canonical path (handles unsaved files by canonicalizing their parent dir).
---@param path string|nil
---@return string|nil
local function canonical(path)
  if not path or path == "" then
    return nil
  end
  local norm = vim.fs.normalize(path)
  local real = vim.uv.fs_realpath(norm)
  if real then
    return vim.fs.normalize(real)
  end
  local dir = vim.fs.dirname(norm)
  local base = vim.fs.basename(norm)
  local real_dir = dir and vim.uv.fs_realpath(dir)
  if real_dir then
    return vim.fs.normalize(real_dir .. "/" .. base)
  end
  return norm
end

---Approximate FQN of a Java source or test file.
---@param path string
---@return string
local function test_fqn(path)
  local rel = path:match(".*[/\\]src[/\\]test[/\\]java[/\\](.+)%.java$")
    or path:match(".*[/\\]src[/\\]main[/\\]java[/\\](.+)%.java$")
  if rel then
    return (rel:gsub("[/\\]", "."))
  end
  return vim.fn.fnamemodify(path, ":t:r")
end

---Short module label relative to `root`.
---@param root string|nil
---@param mod string
---@return string
local function module_label(root, mod)
  local croot = canonical(root)
  local cmod = canonical(mod) or mod
  if not croot then
    return vim.fs.basename(cmod)
  end
  if cmod == croot then
    return "(root)"
  end
  return vim.fs.relpath(croot, cmod) or vim.fs.basename(cmod)
end

---Deepest declared module containing `path`.
---@param path string|nil
---@param modules string[]
---@return string|nil
local function owning_module(path, modules)
  local cpath = canonical(path)
  if not cpath then
    return nil
  end
  local best, best_len = nil, -1
  for _, mod in ipairs(modules or {}) do
    local cmod = canonical(mod)
    if cmod and (cpath == cmod or cpath:sub(1, #cmod + 1) == cmod .. "/") and #cmod > best_len then
      best = cmod
      best_len = #cmod
    end
  end
  return best
end

---Is `path` inside `parent` (both canonical)?
---@param parent string|nil
---@param path string|nil
---@return boolean
local function subtree(parent, path)
  if not parent or not path then
    return false
  end
  local sep = parent:sub(-1) == "/" and "" or "/"
  return parent == path or path:sub(1, #parent + #sep) == parent .. sep
end

---Canonicalized list of declared project modules.
---@param root string|nil
---@return string[]
local function canonical_modules(root)
  local raw = root and project.modules(root) or {}
  local out, seen = {}, {}
  for _, m in ipairs(raw) do
    local cm = canonical(m)
    if cm and not seen[cm] then
      seen[cm] = true
      out[#out + 1] = cm
    end
  end
  return out
end

local function canonical_modules_set(root, mods)
  local set = {}
  local croot = canonical(root)
  if croot then
    set[croot] = true
  end
  for _, m in ipairs(mods or (croot and canonical_modules(croot) or {})) do
    local cm = canonical(m)
    if cm then
      set[cm] = true
    end
  end
  return set
end

---True when `cpath` sits inside an independent nested project or checkout
---strictly below `croot` (nested `.git`, `settings.gradle(.kts)`, or an
---undeclared `pom.xml`/`build.gradle(.kts)`).
---@param cpath string
---@param croot string
---@param mods_set table<string, boolean>|nil
---@return boolean
local function has_nested_project_boundary(cpath, croot, mods_set)
  local dir = vim.fn.isdirectory(cpath) == 1 and cpath or vim.fs.dirname(cpath)
  while dir and dir ~= "" and subtree(croot, dir) and dir ~= croot do
    if vim.uv.fs_stat(dir .. "/.git") ~= nil then
      return true
    end
    if
      vim.fn.filereadable(dir .. "/settings.gradle") == 1
      or vim.fn.filereadable(dir .. "/settings.gradle.kts") == 1
    then
      return true
    end
    if
      (
        vim.fn.filereadable(dir .. "/pom.xml") == 1
        or vim.fn.filereadable(dir .. "/build.gradle") == 1
        or vim.fn.filereadable(dir .. "/build.gradle.kts") == 1
      ) and not (mods_set and mods_set[dir])
    then
      return true
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end
  return false
end

---Whether `adapter_id` identifies the `jc` neotest adapter owning `root`
---(and `target_mod` when scoped to a module), excluding other adapters and
---other projects.
---@param adapter_id string
---@param adapter_obj table|nil
---@param root string
---@param target_mod string|nil
---@param mods string[]|nil
---@return boolean
local function is_jc_adapter_for_scope(adapter_id, adapter_obj, root, target_mod, mods)
  if type(adapter_id) ~= "string" then
    return false
  end
  local ad_root = adapter_id:match("^jc:(.+)$")
  if not ad_root then
    return false
  end
  if type(adapter_obj) == "table" and adapter_obj.name ~= nil and adapter_obj.name ~= "jc" then
    return false
  end
  local cad = canonical(ad_root)
  if not cad then
    return false
  end
  if cad == root then
    return true
  end
  if target_mod then
    return cad == target_mod or (subtree(root, cad) and subtree(cad, target_mod))
  end
  if not subtree(root, cad) then
    return false
  end
  for _, m in ipairs(mods or {}) do
    if cad == m then
      return true
    end
  end
  return false
end

---Per-(project, module) Repeat Last Test history, isolated from jc.test's and
---neotest's global last-run state.
local last_runs = {}
local run_seq = 0
local resolve_suite_replay_path
local pos_belongs_to_scope

local function run_in_nio(nio, body_fn, on_finish)
  local settled = false
  local function settle(ok, err)
    if not settled then
      settled = true
      on_finish(ok, err)
    end
  end
  local ok_nio, nio_err = pcall(nio.run, function()
    local ok_body, body_err = xpcall(body_fn, debug.traceback)
    if not ok_body then
      settle(false, body_err)
      return
    end
    settle(true, nil)
  end, function(task_ok, task_err)
    settle(task_ok == true, not task_ok and task_err or nil)
  end)
  if not ok_nio then
    settle(false, nio_err)
    return false, nio_err
  end
  return true, nil
end

local function scope_key(root, mod_dir)
  local croot = canonical(root) or ""
  local cmod = canonical(mod_dir) or croot
  return croot .. "::" .. cmod
end

local function record_last_run(kind, path, root, mod_dir, suite_dir, pos_id, adapter_id)
  local croot = canonical(root)
  if not croot then
    return
  end
  local cmod = canonical(mod_dir) or croot
  local cpath = canonical(path) or path
  local csuite = suite_dir and (canonical(suite_dir) or suite_dir) or nil
  run_seq = run_seq + 1
  last_runs[scope_key(croot, cmod)] = {
    kind = kind,
    path = cpath,
    root = croot,
    module = cmod,
    suite_dir = csuite,
    pos_id = pos_id,
    adapter_id = adapter_id,
    seq = run_seq,
  }
end

pos_belongs_to_scope = function(pos_id, root, mod_dir, mods)
  if type(pos_id) ~= "string" or pos_id == "" then
    return false
  end
  local raw_path = pos_id:match("^(.-)::") or pos_id
  local cpath = canonical(raw_path)
  local croot = canonical(root)
  if not cpath or not croot or not subtree(croot, cpath) then
    return false
  end
  local eff_mods = mods or canonical_modules(croot)
  local mods_set = canonical_modules_set(croot, eff_mods)
  if has_nested_project_boundary(cpath, croot, mods_set) then
    return false
  end
  local cmod = canonical(mod_dir) or croot
  if eff_mods and #eff_mods > 0 then
    local pos_mod = owning_module(cpath, eff_mods) or croot
    return pos_mod == cmod
  end
  if cmod ~= croot then
    return subtree(cmod, cpath)
  end
  return true
end

local function neotest_last_run(nt)
  if not (nt and nt.run and type(nt.run.get_last_run) == "function") then
    return nil, nil
  end
  local ok, pos_id, args = pcall(nt.run.get_last_run)
  if not ok then
    return nil, nil
  end
  return pos_id, args
end

local function neotest_pinned_runner_apis(nt)
  local ok_ref, refresh = pcall(require, "jc.neotest.refresh")
  local ok_tgt, target_mod = pcall(require, "jc.neotest.target")
  local ok_cons, cons = pcall(require, "jc.neotest.consumer")
  if
    not (
      nt
      and type(nt.run) == "table"
      and type(nt.run.run) == "function"
      and ok_ref
      and type(refresh) == "table"
      and type(refresh.before_run) == "function"
      and ok_tgt
      and type(target_mod) == "table"
      and type(target_mod.run_args) == "function"
    )
  then
    return nil
  end
  return {
    refresh = refresh,
    target_mod = target_mod,
    cons = ok_cons and type(cons) == "table" and cons or nil,
  }
end

local function verified_jc_adapter_for_scope(ad_id, cons, path, croot, cmod, mods, target_mod)
  local candidate = type(ad_id) == "string" and ad_id ~= "" and ad_id or nil
  if
    not candidate
    and target_mod
    and type(target_mod.adapter_id) == "function"
    and type(path) == "string"
    and path ~= ""
  then
    local ok_a, aid = pcall(target_mod.adapter_id, path)
    if ok_a and type(aid) == "string" and aid ~= "" then
      candidate = aid
    end
  end
  if not candidate then
    return nil
  end
  local ad_obj = cons and cons.client and type(cons.client._adapters) == "table" and cons.client._adapters[candidate]
    or nil
  if not is_jc_adapter_for_scope(candidate, ad_obj, croot, cmod, mods) then
    return nil
  end
  return candidate
end

local function last_run_state(root, mod_dir, mods, nt)
  local croot = canonical(root)
  local cmod = canonical(mod_dir) or croot
  local rec = croot and last_runs[scope_key(croot, cmod)] or nil
  local nt_pos, nt_args = neotest_last_run(nt)
  local ok_cons, cons = pcall(require, "jc.neotest.consumer")
  local cons_tbl = ok_cons and type(cons) == "table" and cons or nil

  if rec then
    if rec.kind == "file" then
      if not rec.path or vim.fn.filereadable(rec.path) ~= 1 then
        return {
          available = false,
          reason = "last test file no longer exists on disk",
        }
      end
      return {
        available = true,
        rec = rec,
        detail = vim.fs.basename(rec.path),
      }
    end
    if rec.kind == "suite" then
      local replay_path, target_suite = resolve_suite_replay_path(rec)
      if not replay_path or not target_suite then
        return {
          available = false,
          reason = "original suite target no longer matches or exists",
        }
      end
      local detail = target_suite ~= croot and ("suite: " .. module_label(croot, target_suite))
        or (mods and #mods > 1 and "suite: all modules" or "suite")
      return {
        available = true,
        rec = rec,
        detail = detail,
      }
    end
    -- rec.kind == "nearest": never fall back to global jc.run_last without a fixed safe target
    if type(rec.pos_id) ~= "string" or rec.pos_id == "" then
      return {
        available = false,
        reason = "last nearest-test run has no pinned test position",
      }
    end
    if not pos_belongs_to_scope(rec.pos_id, croot, cmod, mods) then
      return {
        available = false,
        reason = "last nearest-test run is outside this project or module",
      }
    end
    if not rec.path or vim.fn.filereadable(rec.path) ~= 1 then
      return {
        available = false,
        reason = "last test file no longer exists on disk",
      }
    end
    local apis = neotest_pinned_runner_apis(nt)
    if not apis then
      return {
        available = false,
        reason = "cannot replay nearest test safely without neotest/jc target APIs",
      }
    end
    local ad_id = verified_jc_adapter_for_scope(rec.adapter_id, cons_tbl, rec.path, croot, cmod, mods, apis.target_mod)
    if not ad_id then
      return {
        available = false,
        reason = "last nearest-test run has no verified jc adapter for this scope",
      }
    end
    return {
      available = true,
      rec = rec,
      adapter_id = ad_id,
      detail = vim.fs.basename(rec.path),
    }
  end

  if nt_pos ~= nil then
    if not pos_belongs_to_scope(nt_pos, croot, cmod, mods) then
      return {
        available = false,
        reason = "last neotest run belongs to another project or module",
      }
    end
    local nt_adapter = type(nt_args) == "table" and nt_args.adapter or nil
    local ad_obj = nt_adapter
        and cons_tbl
        and cons_tbl.client
        and type(cons_tbl.client._adapters) == "table"
        and cons_tbl.client._adapters[nt_adapter]
      or nil
    if not (type(nt_adapter) == "string" and is_jc_adapter_for_scope(nt_adapter, ad_obj, croot, cmod, mods)) then
      return {
        available = false,
        reason = "last neotest run has no verified jc adapter for this scope",
      }
    end
    local apis = neotest_pinned_runner_apis(nt)
    if not apis then
      return {
        available = false,
        reason = "cannot replay neotest run safely without neotest/jc target APIs",
      }
    end
    local raw_path = nt_pos:match("^(.-)::") or nt_pos
    local cpath = canonical(raw_path)
    if not cpath or (vim.fn.filereadable(cpath) ~= 1 and vim.fn.isdirectory(cpath) ~= 1) then
      return {
        available = false,
        reason = "last neotest target no longer exists on disk",
      }
    end
    return {
      available = true,
      pinned = {
        pos_id = nt_pos,
        path = cpath,
        root = croot,
        module = cmod,
        adapter_id = nt_adapter,
      },
      detail = vim.fs.basename(cpath),
    }
  end

  return {
    available = false,
    reason = "no previous test run in this project/module",
  }
end

---Parse a Java file under `.../src/(main|test)/java/<pkg>/<Name>.java`.
---@param path string|nil
---@return table|nil
local function parse_java_source(path)
  local norm = canonical(path)
  if not norm then
    return nil
  end
  local before, set, rel = norm:match("^(.*)[/\\]src[/\\](main)[/\\]java[/\\](.+%.java)$")
  if not before then
    before, set, rel = norm:match("^(.*)[/\\]src[/\\](test)[/\\]java[/\\](.+%.java)$")
  end
  if not before or not set or not rel then
    return nil
  end
  local rel_dir = vim.fs.dirname(rel)
  if rel_dir == "." then
    rel_dir = ""
  end
  local stem = vim.fn.fnamemodify(rel, ":t:r")
  local pkg = rel_dir ~= "" and (rel_dir:gsub("[/\\]", ".")) or ""
  local fqn = (pkg ~= "" and (pkg .. ".") or "") .. stem
  return {
    path = norm,
    module_dir = canonical(before) or before,
    set = set,
    rel = rel,
    rel_dir = rel_dir,
    stem = stem,
    pkg = pkg,
    fqn = fqn,
  }
end

---Candidate counterpart class names in priority order.
---@param parsed table
---@return string direction, string target_set, string[] names, string|nil default_name
local function counterpart_spec(parsed)
  local stem = parsed.stem
  if parsed.set == "main" then
    local names, seen = {}, {}
    for _, name in ipairs({ stem .. "Test", stem .. "Tests", stem .. "IT", "Test" .. stem }) do
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    return "to_test", "test", names, stem .. "Test"
  end

  local names, seen = {}, {}
  local function add(name)
    if name and name ~= "" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end

  if #stem > 5 and stem:match("Tests$") then
    add(stem:gsub("Tests$", ""))
  elseif #stem > 4 and stem:match("Test$") then
    add(stem:gsub("Test$", ""))
  elseif #stem > 2 and stem:match("IT$") then
    add(stem:gsub("IT$", ""))
  elseif stem:match("^Test(.+)$") then
    add(stem:match("^Test(.+)$"))
  end

  local default_name = names[1]
  if not default_name then
    -- Test-folder helper without a test suffix: still check for an identically
    -- named class in src/main/java, without pretending a specific name is expected.
    add(stem)
  end
  return "to_class", "main", names, default_name
end

local function build_target_path(mod_dir, set, rel_dir, class_name)
  local sub = rel_dir ~= "" and (rel_dir .. "/") or ""
  return mod_dir .. "/src/" .. set .. "/java/" .. sub .. class_name .. ".java"
end

local function find_matches_in_module(mod_dir, target_set, rel_dir, pkg, names, root)
  local matches = {}
  for _, name in ipairs(names) do
    local candidate = build_target_path(mod_dir, target_set, rel_dir, name)
    if vim.fn.filereadable(candidate) == 1 then
      matches[#matches + 1] = {
        path = candidate,
        name = name,
        fqn = (pkg ~= "" and (pkg .. ".") or "") .. name,
        module = mod_dir,
        module_label = module_label(root, mod_dir),
      }
    end
  end
  return matches
end

---Resolve the counterpart (class <-> test) for a buffer or file path,
---preferring the owning module and reporting missing/ambiguous states safely.
---@param buf_or_path integer|string|nil
---@param root string|nil
---@return table
local function resolve_counterpart(buf_or_path, root)
  local bufnr = type(buf_or_path) == "number" and buf_or_path or nil
  local path = type(buf_or_path) == "string" and buf_or_path
    or vim.api.nvim_buf_get_name(bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf())

  local parsed = parse_java_source(path)
  if not parsed then
    return {
      resolvable = false,
      path = path,
      reason = "open a .java file under src/main/java or src/test/java",
    }
  end

  root = root or project.root(bufnr)
  local raw_mods = root and project.modules(root) or { parsed.module_dir }
  local mods, seen_mod = {}, {}
  for _, m in ipairs(raw_mods) do
    local cm = canonical(m)
    if cm and not seen_mod[cm] then
      seen_mod[cm] = true
      mods[#mods + 1] = cm
    end
  end

  local current_mod = parsed.module_dir
  local cur_label = module_label(root, current_mod)
  local direction, target_set, names, default_name = counterpart_spec(parsed)
  local default_target = default_name and build_target_path(current_mod, target_set, parsed.rel_dir, default_name)
    or nil
  local default_fqn = default_name and ((parsed.pkg ~= "" and (parsed.pkg .. ".") or "") .. default_name) or nil
  local multimodule = #mods > 1

  local base = {
    resolvable = true,
    path = parsed.path,
    source_name = parsed.stem,
    source_fqn = parsed.fqn,
    pkg = parsed.pkg,
    rel_dir = parsed.rel_dir,
    direction = direction,
    module = current_mod,
    module_label = cur_label,
    multimodule = multimodule,
    default_target = default_target,
    default_name = default_name,
    default_fqn = default_fqn,
  }

  local same_matches = find_matches_in_module(current_mod, target_set, parsed.rel_dir, parsed.pkg, names, root)
  if #same_matches == 1 then
    base.status = "match"
    base.target = same_matches[1].path
    base.match = same_matches[1]
    base.matches = same_matches
    return base
  end
  if #same_matches > 1 then
    base.status = "ambiguous"
    base.matches = same_matches
    return base
  end

  local other_matches = {}
  for _, mod in ipairs(mods) do
    if mod ~= current_mod then
      vim.list_extend(other_matches, find_matches_in_module(mod, target_set, parsed.rel_dir, parsed.pkg, names, root))
    end
  end
  if #other_matches > 0 then
    base.status = "cross_module"
    base.matches = other_matches
    return base
  end

  base.status = "missing"
  base.matches = {}
  return base
end

---Project test files across declared modules (src/test/java), prioritizing the
---current module and package when `context_path` is provided.
---@param root string
---@param context_path string|nil
---@return table[]
local function test_files(root, context_path)
  local mods = project.modules(root)
  if #mods == 0 then
    mods = { root }
  end
  local multimodule = #mods > 1
  local cur_parsed = context_path and parse_java_source(context_path) or nil
  local cur_mod = context_path and owning_module(context_path, mods) or (cur_parsed and cur_parsed.module_dir)
  local cur_pkg = cur_parsed and cur_parsed.pkg or nil

  local out, seen = {}, {}
  for _, mod in ipairs(mods) do
    local cmod = canonical(mod) or mod
    local mod_lbl = module_label(root, cmod)
    local files = vim.fn.glob(cmod .. "/src/test/java/**/*.java", true, true)
    for _, path in ipairs(files) do
      local cpath = canonical(path) or path
      if not seen[cpath] then
        seen[cpath] = true
        local fqn = test_fqn(cpath)
        local pkg = fqn:match("^(.+)%.[^%.]+$") or ""
        local tier = 3
        if cur_mod and cmod == cur_mod then
          tier = (cur_pkg and pkg == cur_pkg) and 1 or 2
        end
        out[#out + 1] = {
          label = multimodule and (mod_lbl .. " · " .. fqn) or fqn,
          path = cpath,
          module = cmod,
          tier = tier,
        }
      end
    end
  end

  table.sort(out, function(a, b)
    if a.tier ~= b.tier then
      return a.tier < b.tier
    end
    return a.label < b.label
  end)
  return out
end

---Open a file safely without throwing on unsaved-buffer errors.
---@param path string
---@return boolean
local function open_file(path)
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    ui.notify("could not open " .. vim.fs.basename(path) .. ": " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

---Render a JUnit 5 test class using jc.templates when available.
---@param class_name string
---@param pkg string|nil
---@return string
local function render_junit5(class_name, pkg)
  local ok_tpl, templates = pcall(require, "jc.templates")
  if ok_tpl and type(templates.render) == "function" then
    local ok, rendered = pcall(templates.render, "junit5", {
      name = class_name,
      package = pkg or "",
      fields = {},
    })
    if ok and type(rendered) == "string" and rendered ~= "" then
      return rendered
    end
  end
  local pkg_line = (pkg and pkg ~= "") and ("package " .. pkg .. ";\n\n") or ""
  return pkg_line
    .. "import org.junit.jupiter.api.Test;\n"
    .. "import static org.junit.jupiter.api.Assertions.*;\n\n"
    .. "public class "
    .. class_name
    .. " {\n  @Test\n  void test() {\n  }\n}\n"
end

---Create a missing test file without overwriting an existing one.
---@param target_path string
---@param class_name string
---@param pkg string|nil
---@return boolean
local function create_test_file(target_path, class_name, pkg)
  local existing = vim.fn.bufnr(target_path)
  if existing > 0 and vim.api.nvim_buf_is_loaded(existing) and vim.bo[existing].modified then
    return open_file(target_path)
  end
  if vim.fn.filereadable(target_path) == 1 then
    return open_file(target_path)
  end
  vim.fn.mkdir(vim.fs.dirname(target_path), "p")
  local rendered = render_junit5(class_name, pkg)
  -- Exclusive creation prevents a file appearing after the picker opened
  -- from being overwritten, including a dangling symlink at the target.
  local fd, err = vim.uv.fs_open(target_path, "wx", 438)
  if not fd then
    ui.notify("could not create test: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  local written, write_err = vim.uv.fs_write(fd, rendered, 0)
  local closed, close_err = vim.uv.fs_close(fd)
  if written ~= #rendered or not closed then
    ui.notify(
      "could not finish writing test: " .. tostring(write_err or close_err or "short write"),
      vim.log.levels.ERROR
    )
    return false
  end
  if not open_file(target_path) then
    return false
  end
  vim.b.jc_new_java_file = true
  return true
end

---Same-module package tests for a production class.
---@param nav table
---@return string[]
local function package_tests_for(nav)
  local api, api_err = jca.test_discovery_api()
  if api then
    local nothing, nothing_err = api.nothing_to_run(nav.path)
    local package_tests, package_err = api.package_tests(nav.path)
    if nothing_err or package_err then
      ui.notify(nothing_err or package_err, vim.log.levels.WARN)
    end
    if nothing and package_tests and #package_tests > 0 then
      return package_tests
    end
    return {}
  elseif api_err then
    ui.notify(api_err, vim.log.levels.WARN)
  end

  local sub = nav.rel_dir ~= "" and (nav.rel_dir .. "/") or ""
  local dir = nav.module .. "/src/test/java/" .. sub
  local files = vim.fn.glob(dir .. "*.java", true, true)
  table.sort(files)
  return files
end

---Navigate bidirectionally between a class and its test, prompting on
---ambiguous matches or missing test creation instead of silently guessing.
---@param buf_or_path integer|string|nil
---@param root string|nil
local function goto_counterpart(buf_or_path, root)
  local nav = resolve_counterpart(buf_or_path, root)
  if not nav.resolvable then
    ui.notify(nav.reason, vim.log.levels.WARN)
    return
  end

  if nav.direction == "to_class" then
    if nav.status == "match" then
      open_file(nav.target)
      return
    end
    if nav.status == "cross_module" then
      if #nav.matches == 1 then
        if open_file(nav.matches[1].path) then
          ui.notify("opened from module " .. nav.matches[1].module_label, vim.log.levels.INFO)
        end
        return
      end
      local labels, by_label = {}, {}
      for _, m in ipairs(nav.matches) do
        local label = m.module_label .. " · " .. m.fqn
        labels[#labels + 1] = label
        by_label[label] = m.path
      end
      ui.pick_one(labels, "Java: Tests — multiple matching classes", function(choice)
        if by_label[choice] then
          open_file(by_label[choice])
        end
      end)
      return
    end
    ui.notify(
      nav.default_fqn and ("no matching class in src/main/java (" .. nav.default_fqn .. ")")
        or "no matching class in src/main/java",
      vim.log.levels.WARN
    )
    return
  end

  -- direction == "to_test"
  if nav.status == "match" then
    open_file(nav.target)
    return
  end

  if nav.status == "ambiguous" then
    local labels, by_label = {}, {}
    for _, m in ipairs(nav.matches) do
      local label = nav.multimodule and (m.module_label .. " · " .. m.fqn) or m.fqn
      labels[#labels + 1] = label
      by_label[label] = m.path
    end
    ui.pick_one(labels, "Java: Tests — multiple paired tests", function(choice)
      if by_label[choice] then
        open_file(by_label[choice])
      end
    end)
    return
  end

  local labels, actions = {}, {}
  if nav.status == "cross_module" then
    for _, m in ipairs(nav.matches) do
      local label = "Open " .. m.module_label .. " · " .. m.fqn
      labels[#labels + 1] = label
      actions[label] = function()
        open_file(m.path)
      end
    end
  end

  local create_target = "Create " .. (nav.multimodule and (nav.module_label .. " · ") or "") .. nav.default_fqn
  labels[#labels + 1] = create_target
  actions[create_target] = function()
    create_test_file(nav.default_target, nav.default_name, nav.pkg)
  end

  if nav.status == "missing" then
    for _, file in ipairs(package_tests_for(nav)) do
      local label = "Open " .. test_fqn(file)
      if not actions[label] then
        labels[#labels + 1] = label
        actions[label] = function()
          open_file(file)
        end
      end
    end
  end

  local prompt = nav.status == "cross_module" and ("Java: Tests — no paired test in " .. nav.module_label)
    or ("Java: Tests — no paired test for " .. nav.source_name)
  ui.pick_one(labels, prompt, function(choice)
    if actions[choice] then
      actions[choice]()
    end
  end)
end

local SUITE_BUILD_MARKERS = {
  "settings.gradle",
  "settings.gradle.kts",
  "pom.xml",
  "build.gradle",
  "build.gradle.kts",
}

local JC_SUITE_MARKERS = {
  "settings.gradle",
  "settings.gradle.kts",
  "pom.xml",
  "build.gradle",
  "build.gradle.kts",
  ".git",
}

---Effective root directory `jc.test.run_all()` resolves from `buf_or_path`.
---@param buf_or_path integer|string
---@return string
local function effective_jc_suite_target(buf_or_path)
  local found = vim.fs.root(buf_or_path, JC_SUITE_MARKERS)
  if found and found ~= "" then
    return canonical(found) or found
  end
  local cwd = vim.fn.getcwd()
  return canonical(cwd) or cwd
end

---Directory `jc.test.run_all()` will actually target from `cur_buf` / `cur_path`,
---or nil when `jc.test.run_all()` resolves outside `root`.
---@param cur_path string|nil
---@param root string
---@param cur_buf integer|nil
---@return string|nil suite_dir, boolean valid
local function suite_target_dir(cur_path, root, cur_buf)
  local croot = canonical(root) or root
  local probe = (cur_buf and vim.api.nvim_buf_is_valid(cur_buf)) and cur_buf or cur_path
  if probe and probe ~= "" then
    local eff = effective_jc_suite_target(probe)
    if eff and subtree(croot, eff) then
      return eff, true
    end
  end
  return nil, false
end

local function maybe_open_jc_summary(nt, target_path)
  local ok_jc, jc_mod = pcall(require, "jc")
  local t = ok_jc and type(jc_mod) == "table" and jc_mod.config and jc_mod.config.test
  if t and t.open_summary == false then
    return
  end
  if nt and nt.summary and type(nt.summary.open) == "function" then
    pcall(nt.summary.open)
  end
  if target_path and nt and nt.summary and type(nt.summary.expand) == "function" then
    vim.defer_fn(function()
      pcall(function()
        nt.summary:expand(target_path, true)
      end)
    end, 300)
  end
end

local function launch_nt_run(opts)
  local nt = opts.nt
  local nio = opts.nio
  local err_prefix = opts.err_prefix or "could not run test: "
  local use_nio = nio ~= nil and type(nio) == "table" and type(nio.run) == "function"

  if use_nio then
    local ok_nio_call, nio_err = run_in_nio(nio, function()
      local ok_run, run_err = pcall(nt.run.run, opts.args)
      if not ok_run then
        error(run_err)
      end
    end, function(ok, err)
      if not ok and err then
        vim.schedule(function()
          ui.notify(err_prefix .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    end)
    if not ok_nio_call then
      ui.notify(err_prefix .. tostring(nio_err), vim.log.levels.ERROR)
      return false
    end
  else
    local ok_run, run_err = pcall(nt.run.run, opts.args)
    if not ok_run then
      ui.notify(err_prefix .. tostring(run_err), vim.log.levels.ERROR)
      return false
    end
  end

  maybe_open_jc_summary(nt, opts.summary_path)
  if opts.on_started then
    opts.on_started()
  end
  return true
end

local function dispatch_test_file(bufnr, path, root, is_test, mod, jc)
  if type(jc.run_file) ~= "function" then
    ui.notify("jc test runner is not available", vim.log.levels.ERROR)
    return
  end
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, jc.run_file)
  if not ok then
    ui.notify("could not run test: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if is_test and root then
    record_last_run("file", path, root, mod)
  end
end

---Run a test file through neotest using the jc adapter.
local function run_file(path, root_hint)
  local jc_guard = lsp.jc_global_reason("Tests")
  if jc_guard then
    ui.notify(jc_guard, vim.log.levels.WARN)
    return
  end
  local jc = jc_test()
  if not jc or type(jc.run_file) ~= "function" then
    ui.notify("jc test runner is not available", vim.log.levels.ERROR)
    return
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local cpath = canonical(path) or path
  local troot = canonical(root_hint or project.root(buf))
  local tmod = nil
  if troot then
    local mods = canonical_modules(troot)
    tmod = owning_module(cpath, mods) or troot
  end
  dispatch_test_file(buf, cpath, troot, true, tmod, jc)
end

local function pick_and_run_matches(matches, prompt, root)
  local labels, by_label = {}, {}
  for _, m in ipairs(matches) do
    local label = m.module_label .. " · " .. m.fqn
    labels[#labels + 1] = label
    by_label[label] = m.path
  end
  ui.pick_one(labels, prompt, function(choice)
    if by_label[choice] then
      run_file(by_label[choice], root)
    end
  end)
end

local function find_nearest_pos_id(cons, nt_lib, target_path, raw_path, row0, root, mod, target_mod)
  if not (cons and cons.client and cons.client._state and type(cons.client._state.positions) == "function") then
    return nil, nil
  end
  if not (nt_lib and nt_lib.positions and type(nt_lib.positions.nearest) == "function") then
    return nil, nil
  end
  local real_path = (nt_lib.files and nt_lib.files.path and type(nt_lib.files.path.real) == "function")
      and (nt_lib.files.path.real(target_path) or target_path)
    or target_path
  local candidate_adapters = {}
  local seen_ad = {}
  local function add_ad(id)
    if type(id) == "string" and id ~= "" and not seen_ad[id] then
      seen_ad[id] = true
      candidate_adapters[#candidate_adapters + 1] = id
    end
  end
  if target_mod and type(target_mod.adapter_id) == "function" then
    local ok_a, aid1 = pcall(target_mod.adapter_id, real_path)
    if ok_a then
      add_ad(aid1)
    end
    local ok_b, aid2 = pcall(target_mod.adapter_id, raw_path)
    if ok_b then
      add_ad(aid2)
    end
  end
  if type(cons.client._adapters) == "table" then
    local croot = canonical(root)
    local mods = croot and canonical_modules(croot) or {}
    for id, obj in pairs(cons.client._adapters) do
      if croot and is_jc_adapter_for_scope(id, obj, croot, mod, mods) then
        add_ad(id)
      end
    end
  end
  for _, ad_id in ipairs(candidate_adapters) do
    for _, key in ipairs({ real_path, target_path, raw_path }) do
      if type(key) == "string" and key ~= "" then
        local ok_tree, file_tree = pcall(cons.client._state.positions, cons.client._state, ad_id, key)
        if ok_tree and file_tree and type(file_tree.iter_nodes) == "function" then
          local ok_n, nearest = pcall(nt_lib.positions.nearest, file_tree, row0)
          if ok_n and nearest and type(nearest.data) == "function" then
            local ok_d, data = pcall(nearest.data, nearest)
            if ok_d and type(data) == "table" and type(data.id) == "string" and data.id ~= "" then
              return data.id, ad_id
            end
          end
        end
      end
    end
  end
  return nil, nil
end

local function build_pinned_run_args(target_mod, cons, pos_id, path, matched_ad)
  local args = target_mod.run_args(pos_id, path)
  if type(args) == "table" and not args.adapter and matched_ad and type(target_mod._pinnable) == "function" then
    local ok_p, pinnable = pcall(target_mod._pinnable, cons.client, matched_ad, pos_id)
    if ok_p and pinnable then
      args.adapter = matched_ad
    end
  end
  return args
end

local function run_nearest_in_buffer(bufnr, path, root, is_test, mod, jc)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    ui.notify("the buffer changed — cannot run test at cursor", vim.log.levels.WARN)
    return
  end
  local cpath = canonical(path) or path
  local croot = canonical(root) or root
  local row0 = vim.api.nvim_win_get_cursor(0)[1] - 1

  local nt = neotest()
  local ok_ref, refresh = pcall(require, "jc.neotest.refresh")
  local ok_tgt, target_mod = pcall(require, "jc.neotest.target")
  local ok_cons, cons = pcall(require, "jc.neotest.consumer")
  local ok_lib, nt_lib = pcall(require, "neotest.lib")
  local ok_nio, nio = pcall(require, "nio")
  local ok_jcnt, jc_nt = pcall(require, "jc.neotest")

  local nothing_to_run = type(jc._nothing_to_run) == "function" and select(2, pcall(jc._nothing_to_run, path)) == true
  if nothing_to_run then
    if type(jc._package_tests) == "function" then
      local ok, files = pcall(jc._package_tests, path)
      local labels, targets = {}, {}
      local mods = canonical_modules(croot)
      if ok and type(files) == "table" then
        for _, file in ipairs(files) do
          if type(file) == "string" and pos_belongs_to_scope(file, croot, mod, mods) then
            local label = test_fqn(file)
            labels[#labels + 1] = label
            targets[label] = file
          end
        end
      end
      if #labels > 0 then
        ui.pick_one(labels, "Java: Tests — run from package", function(choice)
          if targets[choice] then
            run_file(targets[choice], root)
          end
        end)
        return
      end
    end
    ui.notify("no tests in " .. vim.fs.basename(path), vim.log.levels.WARN)
    return
  end

  local has_started_client = ok_cons and type(cons) == "table" and cons.client and cons.client._started == true
  local has_nt_run = nt ~= nil and type(nt.run) == "table" and type(nt.run.run) == "function"
  local has_refresh = ok_ref and type(refresh) == "table" and type(refresh.before_run) == "function"
  local has_target = ok_tgt and type(target_mod) == "table" and type(target_mod.run_args) == "function"
  local mods = croot and canonical_modules(croot) or {}

  local function launch_pinned(pos_id, matched_ad)
    local cons_tbl = ok_cons and type(cons) == "table" and cons or {}
    local args = build_pinned_run_args(target_mod, cons_tbl, pos_id, cpath, matched_ad)
    local eff_ad = (type(args) == "table" and args.adapter) or matched_ad
    launch_nt_run({
      nt = nt,
      nio = ok_nio and nio or nil,
      args = args,
      summary_path = cpath,
      err_prefix = "could not run test: ",
      on_started = function()
        if is_test then
          record_last_run("nearest", cpath, root, mod, nil, pos_id, eff_ad)
        end
      end,
    })
  end

  if has_started_client then
    if not (has_nt_run and has_refresh and has_target) then
      ui.notify("cannot preserve nearest test target across async refresh", vim.log.levels.WARN)
      return
    end
    -- Preserve exact (file, row) across jc.neotest.refresh's async nio/vim.schedule
    -- callback instead of letting jc.run_at_cursor re-read current buffer/cursor later.
    pcall(function()
      cons.suppressed = false
    end)
    pcall(function()
      require("jc.neotest").clear_precompile_cache()
    end)
    local adapter_id = type(target_mod.adapter_id) == "function" and select(2, pcall(target_mod.adapter_id, cpath))
      or nil
    local ok_ref_call, ref_err = pcall(refresh.before_run, { cpath }, function()
      local pos_id, matched_ad = find_nearest_pos_id(cons, nt_lib, cpath, path, row0, root, mod, target_mod)
      if pos_id then
        launch_pinned(pos_id, matched_ad)
        return
      end

      if vim.api.nvim_get_current_buf() ~= bufnr or (vim.api.nvim_win_get_cursor(0)[1] - 1) ~= row0 then
        ui.notify("buffer or cursor changed during test refresh — run again", vim.log.levels.WARN)
        return
      end
      ui.notify(
        "could not resolve nearest test position at cursor — save test file or check cursor position",
        vim.log.levels.WARN
      )
    end, adapter_id)
    if not ok_ref_call then
      ui.notify("could not run test: " .. tostring(ref_err), vim.log.levels.ERROR)
    end
    return
  end

  -- Cold client: preserve exact (cpath, row0) via real neotest/jc discovery APIs
  -- instead of calling async jc.run_at_cursor() (which re-reads buffer/cursor after yield).
  local can_client_nearest = ok_cons
    and type(cons) == "table"
    and type(cons.client) == "table"
    and type(cons.client.get_nearest) == "function"
  local can_discover_nearest = ok_jcnt
    and type(jc_nt) == "table"
    and type(jc_nt.discover_positions) == "function"
    and ok_lib
    and type(nt_lib) == "table"
    and type(nt_lib.positions) == "table"
    and type(nt_lib.positions.nearest) == "function"
  local has_nio_run = ok_nio and type(nio) == "table" and type(nio.run) == "function"

  if not (has_nt_run and has_target and has_nio_run and (can_client_nearest or can_discover_nearest)) then
    ui.notify(
      "cannot preserve nearest test target on cold neotest client — run test file or start neotest first",
      vim.log.levels.WARN
    )
    return
  end

  pcall(function()
    if ok_cons and type(cons) == "table" then
      cons.suppressed = false
    end
  end)
  pcall(function()
    require("jc.neotest").clear_precompile_cache()
  end)
  local adapter_id = type(target_mod.adapter_id) == "function" and select(2, pcall(target_mod.adapter_id, cpath)) or nil

  local function run_cold_resolve()
    local pos_id, matched_ad
    local ok_nio_call = run_in_nio(nio, function()
      if can_client_nearest then
        if type(cons.client._ensure_started) == "function" then
          pcall(cons.client._ensure_started, cons.client)
        end
        if
          adapter_id
          and type(cons.client._adapters) == "table"
          and not cons.client._adapters[adapter_id]
          and type(cons.client._update_adapters) == "function"
        then
          pcall(cons.client._update_adapters, cons.client, croot or vim.fs.dirname(cpath))
          if not cons.client._adapters[adapter_id] then
            pcall(cons.client._update_adapters, cons.client, vim.fs.dirname(cpath))
          end
        end
        local ad_opt = (adapter_id and type(cons.client._adapters) == "table" and cons.client._adapters[adapter_id])
            and { adapter = adapter_id }
          or nil
        local ok_gn, nearest, ad_id = pcall(cons.client.get_nearest, cons.client, cpath, row0, ad_opt)
        if (not ok_gn or not nearest) and type(cons.client._update_positions) == "function" then
          pcall(cons.client._update_positions, cons.client, cpath, ad_opt)
          ok_gn, nearest, ad_id = pcall(cons.client.get_nearest, cons.client, cpath, row0, ad_opt)
        end
        if ok_gn and nearest and type(nearest.data) == "function" then
          local ok_d, d = pcall(nearest.data, nearest)
          if ok_d and type(d) == "table" and type(d.id) == "string" and d.id ~= "" then
            pos_id = d.id
            matched_ad = ad_id
          end
        end
      elseif can_discover_nearest then
        local ok_dp, file_tree = pcall(jc_nt.discover_positions, cpath)
        if ok_dp and file_tree and type(file_tree.iter_nodes) == "function" then
          local ok_n, nearest = pcall(nt_lib.positions.nearest, file_tree, row0)
          if ok_n and nearest and type(nearest.data) == "function" then
            local ok_d, d = pcall(nearest.data, nearest)
            if ok_d and type(d) == "table" and type(d.id) == "string" and d.id ~= "" then
              pos_id = d.id
            end
          end
        end
      end
    end, function(ok, err)
      if not ok then
        vim.schedule(function()
          ui.notify("could not run test: " .. tostring(err), vim.log.levels.ERROR)
        end)
        return
      end
      vim.schedule(function()
        if not pos_id or pos_id == "" then
          ui.notify(
            "could not resolve nearest test position on cold neotest client — run test file or check cursor position",
            vim.log.levels.WARN
          )
          return
        end
        local chosen_ad = matched_ad or adapter_id
        if chosen_ad then
          local ad_obj = ok_cons
              and type(cons) == "table"
              and cons.client
              and type(cons.client._adapters) == "table"
              and cons.client._adapters[chosen_ad]
            or nil
          if croot and not is_jc_adapter_for_scope(chosen_ad, ad_obj, croot, mod, mods) then
            ui.notify("nearest test resolved to non-jc adapter — refusing to run", vim.log.levels.WARN)
            return
          end
        end
        launch_pinned(pos_id, chosen_ad)
      end)
    end)
    if not ok_nio_call then
      return
    end
  end

  if has_refresh then
    local ok_ref_call, ref_err = pcall(refresh.before_run, { cpath }, run_cold_resolve, adapter_id)
    if not ok_ref_call then
      ui.notify("could not run test: " .. tostring(ref_err), vim.log.levels.ERROR)
    end
  else
    run_cold_resolve()
  end
end

---Run Nearest (or Test File when `file_only` is true), honoring module-aware
---counterparts (*Test, *Tests, *IT, Test*) and Snacks package-test fallback.
local function run_contextual(bufnr, root, file_only)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  if not file_only and vim.api.nvim_get_current_buf() ~= bufnr then
    ui.notify("the target buffer is no longer active — run test at cursor again", vim.log.levels.WARN)
    return
  end
  local jc = jc_test()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local nav = resolve_counterpart(bufnr, root)

  if nav.resolvable and nav.direction == "to_test" then
    if nav.status == "match" then
      run_file(nav.target, root)
      return
    end

    if nav.status == "ambiguous" then
      pick_and_run_matches(nav.matches, "Java: Tests — multiple paired tests", root)
      return
    end

    local pkg_tests = package_tests_for(nav)
    if #pkg_tests > 0 then
      local labels, by_label = {}, {}
      for _, file in ipairs(pkg_tests) do
        local label = test_fqn(file)
        labels[#labels + 1] = label
        by_label[label] = file
      end
      ui.pick_one(labels, "Java: Tests — no paired test (run from package)", function(choice)
        if by_label[choice] then
          run_file(by_label[choice], root)
        end
      end)
      return
    end

    if nav.status == "cross_module" then
      pick_and_run_matches(nav.matches, "Java: Tests — run from another module", root)
      return
    end
  end

  if jc then
    local is_test = (nav.resolvable and nav.direction == "to_class")
      or (not (nav.resolvable and nav.direction == "to_test") and path:find("[/\\]src[/\\]test[/\\]") ~= nil)
    local mods = canonical_modules(root)
    local mod = (nav.resolvable and nav.module) or owning_module(path, mods) or root
    if not file_only then
      run_nearest_in_buffer(bufnr, path, root, is_test, mod, jc)
      return
    end
    dispatch_test_file(bufnr, path, root, is_test, mod, jc)
  end
end

local function pick_test(root, bufnr)
  local context_path = bufnr and vim.api.nvim_buf_get_name(bufnr) or nil
  local items = test_files(root, context_path)
  if #items == 0 then
    ui.notify("no test class in src/test/java", vim.log.levels.WARN)
    return
  end

  local labels, by_label = {}, {}
  for _, item in ipairs(items) do
    labels[#labels + 1] = item.label
    by_label[item.label] = item
  end

  ui.pick_one(labels, "Java: Tests — run test", function(choice)
    local item = by_label[choice]
    if item then
      run_file(item.path, root)
    end
  end)
end

local function run_suite(cur, root, suite_dir, multimodule, scope_mod)
  if not vim.api.nvim_buf_is_valid(cur) then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  local jc = jc_test()
  if not jc or type(jc.run_all) ~= "function" then
    ui.notify("jc test runner is not available", vim.log.levels.ERROR)
    return
  end
  local croot = canonical(root) or root
  local csuite = suite_dir and canonical(suite_dir) or nil
  local eff = effective_jc_suite_target(cur)
  if not csuite or not eff or not subtree(croot, eff) or eff ~= csuite then
    ui.notify(
      "cannot run test suite: jc.test.run_all effective target does not match project/module scope",
      vim.log.levels.WARN
    )
    return
  end
  local cmod = canonical(scope_mod) or csuite
  if multimodule or csuite ~= croot then
    if csuite ~= croot then
      ui.notify(
        "multi-module suite: jc/neotest roots at module "
          .. module_label(croot, csuite)
          .. " — use Pick Test or Run Test File for other modules",
        vim.log.levels.WARN
      )
    else
      ui.notify(
        "multi-module suite: running all modules in one neotest tree — if one module fails to produce a report, neotest/jc can mark tests in other modules failed too",
        vim.log.levels.WARN
      )
    end
  end
  local cur_name = vim.api.nvim_buf_get_name(cur)
  local cur_path = cur_name ~= "" and cur_name or nil
  local ok, err = pcall(vim.api.nvim_buf_call, cur, jc.run_all)
  if not ok then
    ui.notify("could not run test suite: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  record_last_run("suite", cur_path, croot, cmod, csuite)
end

resolve_suite_replay_path = function(rec)
  local target_suite = canonical(rec.suite_dir or rec.module) or canonical(rec.root)
  local croot = canonical(rec.root)
  if not target_suite or not croot or not subtree(croot, target_suite) then
    return nil, nil
  end
  if
    type(rec.path) == "string"
    and rec.path ~= ""
    and (vim.fn.filereadable(rec.path) == 1 or vim.uv.fs_stat(rec.path) ~= nil)
    and effective_jc_suite_target(rec.path) == target_suite
  then
    return rec.path, target_suite
  end
  for _, marker in ipairs(SUITE_BUILD_MARKERS) do
    local mpath = target_suite .. "/" .. marker
    if vim.fn.filereadable(mpath) == 1 and effective_jc_suite_target(mpath) == target_suite then
      return mpath, target_suite
    end
  end
  local git_path = target_suite .. "/.git"
  if vim.uv.fs_stat(git_path) ~= nil and effective_jc_suite_target(git_path) == target_suite then
    return git_path, target_suite
  end
  return nil, nil
end

local function replay_pinned_nearest(nt, apis, pos_id, path, root, mod, adapter_id)
  pcall(function()
    if apis.cons then
      apis.cons.suppressed = false
    end
  end)
  pcall(function()
    require("jc.neotest").clear_precompile_cache()
  end)
  local ok_ref_call, ref_err = pcall(apis.refresh.before_run, { path }, function()
    local cons_tbl = apis.cons or {}
    local args = build_pinned_run_args(apis.target_mod, cons_tbl, pos_id, path, adapter_id)
    if
      type(args) == "table"
      and not args.adapter
      and cons_tbl.client
      and cons_tbl.client._started == true
      and type(apis.target_mod._pinnable) == "function"
    then
      ui.notify("last test position no longer exists in neotest tree", vim.log.levels.WARN)
      return
    end
    local eff_ad = (type(args) == "table" and args.adapter) or adapter_id
    local ok_nio, nio = pcall(require, "nio")
    launch_nt_run({
      nt = nt,
      nio = ok_nio and nio or nil,
      args = args,
      summary_path = path,
      err_prefix = "could not repeat last test: ",
      on_started = function()
        record_last_run("nearest", path, root, mod, nil, pos_id, eff_ad)
      end,
    })
  end, adapter_id)
  if not ok_ref_call then
    ui.notify("could not repeat last test: " .. tostring(ref_err), vim.log.levels.ERROR)
  end
end

local function repeat_last(cur, root, cur_mod, mods, nt)
  local jc = jc_test()
  if not jc then
    ui.notify("jc test runner is not available", vim.log.levels.ERROR)
    return
  end
  local state = last_run_state(root, cur_mod, mods, nt)
  if not state.available then
    ui.notify(state.reason or "no previous test run in this project/module", vim.log.levels.WARN)
    return
  end
  local rec = state.rec
  if rec then
    if rec.kind == "file" then
      run_file(rec.path, rec.root)
      return
    end
    if rec.kind == "suite" then
      local replay_path, target_suite = resolve_suite_replay_path(rec)
      if not replay_path or not target_suite then
        ui.notify("original suite target no longer matches or exists", vim.log.levels.WARN)
        return
      end
      local buf = vim.fn.bufadd(replay_path)
      vim.fn.bufload(buf)
      run_suite(buf, rec.root, target_suite, #canonical_modules(rec.root) > 1, rec.module)
      return
    end
    if rec.kind == "nearest" then
      local apis = neotest_pinned_runner_apis(nt)
      if not apis or type(rec.pos_id) ~= "string" or rec.pos_id == "" then
        ui.notify("last nearest-test run has no fixed safe target", vim.log.levels.WARN)
        return
      end
      replay_pinned_nearest(nt, apis, rec.pos_id, rec.path, rec.root, rec.module, state.adapter_id or rec.adapter_id)
      return
    end
  end
  if state.pinned then
    local apis = neotest_pinned_runner_apis(nt)
    if not apis then
      ui.notify("cannot replay neotest run safely without neotest/jc target APIs", vim.log.levels.WARN)
      return
    end
    local p = state.pinned
    replay_pinned_nearest(nt, apis, p.pos_id, p.path, p.root, p.module, p.adapter_id)
    return
  end
  ui.notify("no safe previous test target to repeat", vim.log.levels.WARN)
end

local function goto_entry(is_java, nav)
  if not is_java then
    return {
      key = "goto_test",
      label = "Go to Test / Class",
      enabled = false,
      reason = "open a .java file",
    }
  end
  if not nav or not nav.resolvable then
    return {
      key = "goto_test",
      label = "Go to Test / Class",
      enabled = false,
      reason = (nav and nav.reason) or "open a .java file under src/main/java or src/test/java",
    }
  end
  if nav.direction == "to_test" then
    local suffix = ""
    if nav.status == "match" then
      suffix = "  (" .. nav.match.name .. ")"
    elseif nav.status == "ambiguous" then
      suffix = "  (" .. #nav.matches .. " matches…)"
    elseif nav.status == "cross_module" then
      suffix = "  (other module / create…)"
    elseif nav.status == "missing" then
      suffix = "  (create " .. nav.default_name .. "…)"
    end
    return {
      key = "goto_test",
      label = "Go to Test" .. suffix,
      enabled = true,
    }
  end

  -- direction == "to_class"
  if nav.status == "match" then
    return {
      key = "goto_test",
      label = "Go to Class  (" .. nav.match.name .. ")",
      enabled = true,
    }
  elseif nav.status == "cross_module" then
    local suffix = #nav.matches == 1 and ("  (" .. nav.matches[1].module_label .. " · " .. nav.matches[1].name .. ")")
      or ("  (" .. #nav.matches .. " modules…)")
    return {
      key = "goto_test",
      label = "Go to Class" .. suffix,
      enabled = true,
    }
  end
  return {
    key = "goto_test",
    label = "Go to Class",
    enabled = false,
    reason = nav.default_fqn and ("no matching class in src/main/java (" .. nav.default_fqn .. ")")
      or "no matching class in src/main/java",
  }
end

-- ---------- JUnit 5 test skeleton for selected method (Issue #16) ----------

local TYPE_KINDS = { [5] = true, [10] = true, [11] = true, [23] = true } -- Class, Enum, Interface, Struct
local METHOD_KIND = 6

local JAVA_KEYWORDS = {}
for word in
  ([[
abstract assert boolean break byte case catch char class const continue default do double else
enum extends final finally float for goto if implements import instanceof int interface long native new
package private protected public return short static strictfp super switch synchronized this throw throws
transient try void volatile while true false null _
]]):gmatch("%S+")
do
  JAVA_KEYWORDS[word] = true
end

---@param name string|nil
---@return boolean
local function is_java_identifier(name)
  return type(name) == "string" and name:match("^[%a_$][%w_$]*$") ~= nil and not JAVA_KEYWORDS[name]
end

local function supports_document_symbol(client, bufnr)
  return hierarchy.supports_method(client, "textDocument/documentSymbol", bufnr, "documentSymbolProvider")
end

local function supports_command(client, bufnr, cmd_name)
  if hierarchy.client_stopped(client) then
    return false
  end
  if not hierarchy.supports_method(client, "workspace/executeCommand", bufnr, "executeCommandProvider") then
    return false
  end
  local cap = type(client.server_capabilities) == "table" and client.server_capabilities.executeCommandProvider or nil
  if type(cap) == "table" and type(cap.commands) == "table" then
    for _, c in ipairs(cap.commands) do
      if c == cmd_name then
        return true
      end
    end
    return false
  end
  return true
end

local function read_u16_le(s, pos)
  local b1, b2 = s:byte(pos, pos + 1)
  if not b1 or not b2 then
    return nil
  end
  return b1 + b2 * 256
end

local function read_u32_le(s, pos)
  local b1, b2, b3, b4 = s:byte(pos, pos + 3)
  if not b1 or not b2 or not b3 or not b4 then
    return nil
  end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

---Check whether a .jar/.zip file on disk actually contains `entry_name`
---by scanning its ZIP central directory.
---@param jar_path string
---@param entry_name string
---@return boolean
local function jar_contains_entry(jar_path, entry_name)
  local fd = vim.uv.fs_open(jar_path, "r", 0)
  if not fd then
    return false
  end
  local st = vim.uv.fs_fstat(fd)
  if not st or st.type ~= "file" or (st.size or 0) < 22 then
    vim.uv.fs_close(fd)
    return false
  end

  local tail_len = math.min(st.size, 65557)
  local tail_off = st.size - tail_len
  local tail = vim.uv.fs_read(fd, tail_len, tail_off)
  if type(tail) ~= "string" or #tail < 22 then
    vim.uv.fs_close(fd)
    return false
  end

  local eocd_sig = string.char(0x50, 0x4b, 0x05, 0x06)
  local eocd_pos = nil
  for i = #tail - 21, 1, -1 do
    if tail:sub(i, i + 3) == eocd_sig then
      local comment_len = read_u16_le(tail, i + 20)
      if comment_len and i + 21 + comment_len == #tail then
        eocd_pos = i
        break
      end
    end
  end
  if not eocd_pos then
    vim.uv.fs_close(fd)
    return false
  end

  local cd_size = read_u32_le(tail, eocd_pos + 12)
  local cd_offset = read_u32_le(tail, eocd_pos + 16)
  if not cd_size or not cd_offset or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF then
    vim.uv.fs_close(fd)
    return false
  end
  if cd_offset + cd_size > st.size then
    vim.uv.fs_close(fd)
    return false
  end

  local cd = vim.uv.fs_read(fd, cd_size, cd_offset)
  vim.uv.fs_close(fd)
  if type(cd) ~= "string" or #cd < cd_size then
    return false
  end

  local cd_sig = string.char(0x50, 0x4b, 0x01, 0x02)
  local pos = 1
  local target_len = #entry_name
  while pos + 45 <= #cd do
    if cd:sub(pos, pos + 3) ~= cd_sig then
      break
    end
    local name_len = read_u16_le(cd, pos + 28)
    local extra_len = read_u16_le(cd, pos + 30)
    local comment_len = read_u16_le(cd, pos + 32)
    if not name_len or not extra_len or not comment_len then
      break
    end
    local next_pos = pos + 46 + name_len + extra_len + comment_len
    if next_pos - 1 > #cd then
      break
    end
    if name_len == target_len and cd:sub(pos + 46, pos + 45 + name_len) == entry_name then
      return true
    end
    pos = next_pos
  end
  return false
end

local function is_jupiter_api_artifact_name(lower_path)
  local base = vim.fs.basename(lower_path)
  if base:match("^junit%-jupiter%-api%-%d") or base == "junit-jupiter-api.jar" then
    return true
  end
  if base:match("^junit%-jupiter%-%d") then
    return true
  end
  return false
end

local function is_jupiter_engine_name(lower_path)
  local base = vim.fs.basename(lower_path)
  return base:find("junit-jupiter-engine", 1, true) ~= nil
end

---Verify whether JUnit 5 API (`org.junit.jupiter.api.Test`) is present on the
---resolved test classpath with real class evidence where entries exist on disk.
---@param result table|nil
---@param mod_label string|nil
---@return table
local function inspect_junit5_classpath(result, mod_label)
  if type(result) ~= "table" or type(result.classpaths) ~= "table" then
    return { status = "invalid" }
  end
  local entries = {}
  for _, p in ipairs(result.classpaths) do
    if type(p) == "string" then
      entries[#entries + 1] = p
    end
  end
  if type(result.modulepaths) == "table" then
    for _, p in ipairs(result.modulepaths) do
      if type(p) == "string" then
        entries[#entries + 1] = p
      end
    end
  end

  local mod_desc = (mod_label and mod_label ~= "") and (mod_label .. " ") or ""
  local saw_junit4 = false
  local saw_engine = false
  local saw_unverified_api_entry = false
  local api_rel = "org/junit/jupiter/api/Test.class"

  for _, raw in ipairs(entries) do
    local lower = raw:lower():gsub("\\", "/")
    local st = vim.uv.fs_stat(raw)
    if st then
      if st.type == "directory" then
        local cls_st = vim.uv.fs_stat(raw:gsub("[/\\]+$", "") .. "/" .. api_rel)
        if cls_st and cls_st.type == "file" then
          return {
            status = "verified",
            summary = "verified (org.junit.jupiter.api.Test on " .. mod_desc .. "test classpath)",
          }
        end
      elseif st.type == "file" and (lower:match("%.jar$") or lower:match("%.zip$")) then
        if jar_contains_entry(raw, api_rel) then
          return {
            status = "verified",
            summary = "verified (org.junit.jupiter.api.Test on " .. mod_desc .. "test classpath)",
          }
        end
      end
      if is_jupiter_engine_name(lower) then
        saw_engine = true
      end
    else
      if is_jupiter_api_artifact_name(lower) then
        saw_unverified_api_entry = true
      elseif is_jupiter_engine_name(lower) then
        saw_engine = true
      end
    end

    if lower:find("junit-4.", 1, true) or lower:find("junit-3.", 1, true) or lower:find("/junit/junit/", 1, true) then
      saw_junit4 = true
    end
  end

  if saw_unverified_api_entry then
    return {
      status = "unverified",
      summary = "UNVERIFIED (JUnit 5 API jar listed on "
        .. mod_desc
        .. "classpath, but org.junit.jupiter.api.Test could not be verified on disk)",
    }
  end

  return {
    status = "missing",
    saw_engine_only = saw_engine,
    saw_junit4 = saw_junit4,
  }
end

local function split_param_types(params_inner)
  local inner = vim.trim(params_inner or "")
  if inner == "" then
    return {}
  end
  local out = {}
  local depth_angle, depth_paren, depth_bracket = 0, 0, 0
  local start = 1
  for i = 1, #inner do
    local c = inner:sub(i, i)
    if c == "<" then
      depth_angle = depth_angle + 1
    elseif c == ">" and depth_angle > 0 then
      depth_angle = depth_angle - 1
    elseif c == "(" then
      depth_paren = depth_paren + 1
    elseif c == ")" and depth_paren > 0 then
      depth_paren = depth_paren - 1
    elseif c == "[" then
      depth_bracket = depth_bracket + 1
    elseif c == "]" and depth_bracket > 0 then
      depth_bracket = depth_bracket - 1
    elseif c == "," and depth_angle == 0 and depth_paren == 0 and depth_bracket == 0 then
      local part = vim.trim(inner:sub(start, i - 1))
      if part ~= "" then
        out[#out + 1] = part
      end
      start = i + 1
    end
  end
  local tail = vim.trim(inner:sub(start))
  if tail ~= "" then
    out[#out + 1] = tail
  end
  return out
end

local function clean_type_name(raw)
  local s = vim.trim(raw or "")
  local no_generics = s:gsub("%b<>", "")
  return vim.trim(no_generics)
end

local function parse_method_symbol(node)
  local raw_name = vim.trim(type(node.name) == "string" and node.name or "")
  local raw_detail = vim.trim(type(node.detail) == "string" and node.detail or "")

  local base_name = raw_name
  local params_paren = nil
  local ret_part = ""

  local open_idx = raw_name:find("(", 1, true)
  if open_idx then
    base_name = vim.trim(raw_name:sub(1, open_idx - 1))
    local rest = raw_name:sub(open_idx)
    local parens, after = rest:match("^(%b())(.*)$")
    if parens then
      params_paren = parens
      ret_part = vim.trim(after or "")
    else
      params_paren = rest
    end
  elseif raw_detail:sub(1, 1) == "(" then
    local parens, after = raw_detail:match("^(%b())(.*)$")
    if parens then
      params_paren = parens
      ret_part = vim.trim(after or "")
    end
  end

  if ret_part == "" and raw_detail ~= "" and raw_detail:sub(1, 1) ~= "(" then
    ret_part = raw_detail
  end
  if ret_part:sub(1, 1) == ":" then
    ret_part = vim.trim(ret_part:sub(2))
  end

  base_name = base_name:gsub("%b<>", "")
  base_name = vim.trim(base_name)
  local params = params_paren and split_param_types(params_paren:sub(2, -2)) or {}
  local signature = base_name .. (params_paren or "()")
  local display_sig = ret_part ~= "" and (signature .. " : " .. ret_part) or signature

  return {
    name = base_name,
    params = params,
    params_text = params_paren or "()",
    return_type = ret_part,
    signature = signature,
    display_signature = display_sig,
  }
end

local function pos_in_range(pos, range)
  if not (pos and hierarchy.is_valid_range(range) and type(range["end"]) == "table") then
    return false
  end
  local s, e = range.start, range["end"]
  if pos.line < s.line or (pos.line == s.line and pos.character < s.character) then
    return false
  end
  if pos.line > e.line or (pos.line == e.line and pos.character > e.character) then
    return false
  end
  return true
end

local function range_contains(outer, inner)
  if not (hierarchy.is_valid_range(outer) and hierarchy.is_valid_range(inner)) then
    return false
  end
  return pos_in_range(inner.start, outer) and pos_in_range(inner["end"], outer)
end

local function range_span_score(range)
  if not (hierarchy.is_valid_range(range) and type(range["end"]) == "table") then
    return math.huge
  end
  local dl = math.max(0, (range["end"].line or 0) - (range.start.line or 0))
  local dc = math.max(0, (range["end"].character or 0) - (range.start.character or 0))
  return dl * 100000 + dc
end

---Extract methods from JDTLS `textDocument/documentSymbol` response, preserving
---enclosing type hierarchy, overload signatures, and cursor containment.
---@param resp table[]|nil
---@param cursor_pos table|nil
---@return table[]
local function extract_methods_from_symbols(resp, cursor_pos)
  if type(resp) ~= "table" or #resp == 0 then
    return {}
  end

  local methods = {}
  local is_symbol_info = false
  for _, item in ipairs(resp) do
    if type(item) == "table" and type(item.location) == "table" and item.range == nil then
      is_symbol_info = true
      break
    end
  end

  if is_symbol_info then
    local types = {}
    local raw_methods = {}
    for _, item in ipairs(resp) do
      if type(item) == "table" then
        if TYPE_KINDS[item.kind] then
          types[#types + 1] = item
        elseif item.kind == METHOD_KIND then
          raw_methods[#raw_methods + 1] = item
        end
      end
    end
    for _, m in ipairs(raw_methods) do
      local m_range = m.location and m.location.range or nil
      local enclosing = {}
      if hierarchy.is_valid_range(m_range) then
        for _, t in ipairs(types) do
          local t_range = t.location and t.location.range or nil
          if hierarchy.is_valid_range(t_range) and range_contains(t_range, m_range) then
            enclosing[#enclosing + 1] = t
          end
        end
        table.sort(enclosing, function(a, b)
          return range_span_score(a.location.range) > range_span_score(b.location.range)
        end)
      end
      local type_path = {}
      for _, t in ipairs(enclosing) do
        local tn = clean_type_name(t.name)
        if tn ~= "" then
          type_path[#type_path + 1] = tn
        end
      end
      if #type_path == 0 and type(m.containerName) == "string" and m.containerName ~= "" then
        type_path[1] = clean_type_name(m.containerName)
      end
      local parsed = parse_method_symbol(m)
      if parsed.name ~= "" then
        methods[#methods + 1] = {
          name = parsed.name,
          params = parsed.params,
          params_text = parsed.params_text,
          return_type = parsed.return_type,
          signature = parsed.signature,
          display_signature = parsed.display_signature,
          type_path = type_path,
          qualified_type = table.concat(type_path, "."),
          range = m_range,
          selection_range = m_range,
        }
      end
    end
  else
    local function walk(nodes, type_stack, inside_method)
      for _, node in ipairs(nodes or {}) do
        if type(node) == "table" then
          if TYPE_KINDS[node.kind] then
            if not inside_method then
              local next_stack = vim.list_extend({}, type_stack)
              local tn = clean_type_name(node.name)
              if tn ~= "" then
                next_stack[#next_stack + 1] = tn
              end
              walk(node.children, next_stack, false)
            end
          elseif node.kind == METHOD_KIND then
            local parsed = parse_method_symbol(node)
            if parsed.name ~= "" then
              local type_path = vim.list_extend({}, type_stack)
              methods[#methods + 1] = {
                name = parsed.name,
                params = parsed.params,
                params_text = parsed.params_text,
                return_type = parsed.return_type,
                signature = parsed.signature,
                display_signature = parsed.display_signature,
                type_path = type_path,
                qualified_type = table.concat(type_path, "."),
                range = hierarchy.pick_range(node.range, node.selectionRange),
                selection_range = hierarchy.pick_range(node.selectionRange, node.range),
              }
            end
            walk(node.children, type_stack, true)
          else
            walk(node.children, type_stack, inside_method)
          end
        end
      end
    end
    walk(resp, {}, false)
  end

  local by_type_name = {}
  local by_global_name = {}
  for _, m in ipairs(methods) do
    local key = m.qualified_type .. "\0" .. m.name
    by_type_name[key] = (by_type_name[key] or 0) + 1
    by_global_name[m.name] = (by_global_name[m.name] or 0) + 1
  end

  local best_cursor_idx = nil
  local best_cursor_span = math.huge
  for idx, m in ipairs(methods) do
    local key = m.qualified_type .. "\0" .. m.name
    m.is_overloaded = (by_type_name[key] or 0) > 1
    m.has_name_collision = (by_global_name[m.name] or 0) > 1
    m.at_cursor = false
    local check_range = hierarchy.is_valid_range(m.range) and m.range or m.selection_range
    if cursor_pos and pos_in_range(cursor_pos, check_range) then
      local span = range_span_score(check_range)
      if span < best_cursor_span then
        best_cursor_span = span
        best_cursor_idx = idx
      end
    end
  end
  if best_cursor_idx then
    methods[best_cursor_idx].at_cursor = true
  end

  return methods
end

local function capitalize_ident(s)
  if s == "" then
    return ""
  end
  return s:sub(1, 1):upper() .. s:sub(2)
end

local function sanitize_param_token(param_type)
  local t = vim.trim(param_type or "")
  if t == "" then
    return "Arg"
  end
  local is_varargs = t:sub(-3) == "..."
  if is_varargs then
    t = vim.trim(t:sub(1, -4))
  end
  local array_dims = 0
  while t:sub(-2) == "[]" do
    array_dims = array_dims + 1
    t = vim.trim(t:sub(1, -3))
  end
  -- Drop parameter names if present (e.g. "String name" -> "String")
  local no_generics = t:gsub("%b<>", "")
  no_generics = vim.trim(no_generics)
  local first_token = no_generics:match("^([%w_.$]+)") or no_generics
  local simple = first_token:match("([^.]+)$") or first_token
  simple = simple:gsub("[^%w_$]", "")
  if simple == "" then
    simple = "Arg"
  end
  if array_dims > 0 then
    simple = simple .. (array_dims == 1 and "Array" or ("Array" .. tostring(array_dims)))
  end
  if is_varargs then
    simple = simple .. "Varargs"
  end
  return simple
end

---Build a valid, collision-free JUnit 5 test method name for `method`.
---@param method table
---@param existing_methods table<string, boolean>|nil
---@return string
local function default_test_method_name(method, existing_methods)
  local parts = { "test" }
  if type(method.type_path) == "table" and #method.type_path > 1 then
    local inner = {}
    for i = 2, #method.type_path do
      local seg = method.type_path[i]:gsub("[^%w_$]", "")
      if seg ~= "" then
        inner[#inner + 1] = capitalize_ident(seg)
      end
    end
    if #inner > 0 then
      parts[#parts + 1] = table.concat(inner, "_") .. "_"
    end
  end

  local raw_method = (method.name or "method"):gsub("[^%w_$]", "")
  if raw_method == "" then
    raw_method = "method"
  end
  if #parts == 1 then
    parts[#parts + 1] = capitalize_ident(raw_method)
  else
    parts[#parts + 1] = raw_method
  end

  local base = table.concat(parts)
  if method.is_overloaded then
    if type(method.params) == "table" and #method.params > 0 then
      local p_tokens = {}
      for _, p in ipairs(method.params) do
        p_tokens[#p_tokens + 1] = sanitize_param_token(p)
      end
      base = base .. "_" .. table.concat(p_tokens, "_")
    else
      base = base .. "_noArgs"
    end
  end

  base = base:gsub("[^%w_$]", "_")
  if not is_java_identifier(base) then
    base = "test_" .. base
  end
  if not is_java_identifier(base) then
    base = "testMethod"
  end

  local taken = existing_methods or {}
  if not taken[base] then
    return base
  end
  local n = 2
  while taken[base .. "_" .. n] do
    n = n + 1
  end
  return base .. "_" .. n
end

---Locate all valid buffers pointing to `path` (via canonical comparison).
---@param path string
---@return integer[]
local function find_buffers_for_path(path)
  local target = canonical(path)
  local seen = {}
  local out = {}
  local direct = vim.fn.bufnr(path)
  if direct ~= -1 and vim.api.nvim_buf_is_valid(direct) then
    local name = vim.api.nvim_buf_get_name(direct)
    if (target and canonical(name) == target) or name == path then
      seen[direct] = true
      out[#out + 1] = direct
    end
  end
  if target then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and canonical(name) == target then
          seen[buf] = true
          out[#out + 1] = buf
        end
      end
    end
  end
  return out
end

---Refuse modifying or overwriting a dirty or non-modifiable target buffer.
---@param path string
---@return integer|nil clean_loaded_buf, string|nil err, integer[]|nil all_loaded_bufs
local function inspect_target_buffer(path)
  local bufs = find_buffers_for_path(path)
  local loaded_bufs = {}
  for _, buf in ipairs(bufs) do
    if vim.bo[buf].modified then
      return nil, "target test buffer (" .. vim.fs.basename(path) .. ") has unsaved changes — save or discard first"
    end
    if vim.api.nvim_buf_is_loaded(buf) then
      if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
        return nil, "target test buffer (" .. vim.fs.basename(path) .. ") is read-only or not modifiable"
      end
      loaded_bufs[#loaded_bufs + 1] = buf
    end
  end
  return loaded_bufs[1], nil, loaded_bufs
end

local function utf8_next_cp(s, idx)
  local b1 = s:byte(idx)
  if not b1 then
    return nil, idx
  end
  if b1 < 0x80 then
    return b1, idx + 1
  elseif b1 >= 0xC2 and b1 <= 0xDF then
    local b2 = s:byte(idx + 1)
    if b2 and b2 >= 0x80 and b2 <= 0xBF then
      return (b1 - 0xC0) * 64 + (b2 - 0x80), idx + 2
    end
  elseif b1 >= 0xE0 and b1 <= 0xEF then
    local b2, b3 = s:byte(idx + 1, idx + 2)
    if b2 and b3 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
      return (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80), idx + 3
    end
  elseif b1 >= 0xF0 and b1 <= 0xF4 then
    local b2, b3, b4 = s:byte(idx + 1, idx + 3)
    if b2 and b3 and b4 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
      return (b1 - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80), idx + 4
    end
  end
  return nil, idx + 1
end

local function encode_utf16(text, le)
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local cp, nxt = utf8_next_cp(text, i)
    if not cp then
      return nil, "invalid UTF-8 in buffer"
    end
    i = nxt
    if cp <= 0xFFFF then
      local hi, lo = math.floor(cp / 256), cp % 256
      out[#out + 1] = le and string.char(lo, hi) or string.char(hi, lo)
    else
      local v = cp - 0x10000
      local w1 = 0xD800 + math.floor(v / 1024)
      local w2 = 0xDC00 + (v % 1024)
      for _, w in ipairs({ w1, w2 }) do
        local hi, lo = math.floor(w / 256), w % 256
        out[#out + 1] = le and string.char(lo, hi) or string.char(hi, lo)
      end
    end
  end
  return table.concat(out), nil
end

local function encode_utf32(text, le)
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local cp, nxt = utf8_next_cp(text, i)
    if not cp then
      return nil, "invalid UTF-8 in buffer"
    end
    i = nxt
    local b1 = cp % 256
    local b2 = math.floor(cp / 256) % 256
    local b3 = math.floor(cp / 65536) % 256
    local b4 = math.floor(cp / 16777216) % 256
    out[#out + 1] = le and string.char(b1, b2, b3, b4) or string.char(b4, b3, b2, b1)
  end
  return table.concat(out), nil
end

---Reconstruct exact disk bytes for a clean loaded buffer, honoring
---`fileformat`, `eol`, `bomb`, and `fileencoding`.
---@param buf integer
---@return string|nil bytes, string|nil err
local function buffer_to_disk_bytes(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ff = vim.bo[buf].fileformat
  local eol = vim.bo[buf].eol
  local bomb = vim.bo[buf].bomb
  local fenc = vim.bo[buf].fileencoding
  if not fenc or fenc == "" then
    fenc = vim.o.encoding
  end
  if not fenc or fenc == "" then
    fenc = "utf-8"
  end
  fenc = fenc:lower()

  local eol_str = (ff == "dos" and "\r\n") or (ff == "mac" and "\r") or "\n"
  local text
  if #lines == 1 and lines[1] == "" then
    text = ""
  else
    local parts = {}
    for idx, l in ipairs(lines) do
      parts[idx] = l:gsub("\n", "\0")
    end
    text = table.concat(parts, eol_str)
    if eol then
      text = text .. eol_str
    end
  end

  if fenc == "utf-8" or fenc == "utf8" then
    return (bomb and "\xef\xbb\xbf" or "") .. text, nil
  elseif fenc == "utf-16le" or fenc == "ucs-2le" then
    local encoded, err = encode_utf16(text, true)
    if not encoded then
      return nil, err
    end
    return (bomb and "\xff\xfe" or "") .. encoded, nil
  elseif fenc == "utf-16" or fenc == "utf-16be" or fenc == "ucs-2" or fenc == "ucs-2be" then
    local encoded, err = encode_utf16(text, false)
    if not encoded then
      return nil, err
    end
    return (bomb and "\xfe\xff" or "") .. encoded, nil
  elseif fenc == "utf-32le" or fenc == "ucs-4le" then
    local encoded, err = encode_utf32(text, true)
    if not encoded then
      return nil, err
    end
    return (bomb and "\xff\xfe\x00\x00" or "") .. encoded, nil
  elseif fenc == "utf-32" or fenc == "utf-32be" or fenc == "ucs-4" or fenc == "ucs-4be" then
    local encoded, err = encode_utf32(text, false)
    if not encoded then
      return nil, err
    end
    return (bomb and "\x00\x00\xfe\xff" or "") .. encoded, nil
  end

  local ok, conv = pcall(vim.iconv, text, "utf-8", fenc)
  if not ok or type(conv) ~= "string" then
    return nil, "unsupported fileencoding: " .. fenc
  end
  local ok_back, roundtrip = pcall(vim.iconv, conv, fenc, "utf-8")
  if not ok_back or roundtrip ~= text then
    return nil, "buffer text does not round-trip in fileencoding: " .. fenc
  end
  return conv, nil
end

local function verify_loaded_buffers_match_disk(loaded_bufs, disk_data, path)
  local name = vim.fs.basename(path)
  for _, buf in ipairs(loaded_bufs or {}) do
    local buf_bytes, conv_err = buffer_to_disk_bytes(buf)
    if not buf_bytes then
      return false, "could not verify buffer bytes for " .. name .. ": " .. tostring(conv_err)
    end
    if buf_bytes ~= disk_data then
      return false,
        "target test buffer (" .. name .. ") differs from file on disk — reload or reconcile before inserting test"
    end
  end
  return true, nil
end

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

local function read_regular_file(path)
  local name = vim.fs.basename(path)
  local lstat = vim.uv.fs_lstat(path)
  if not lstat then
    return nil, name .. " does not exist", nil
  end
  if lstat.type == "link" then
    return nil, name .. " is a symlink — refusing to modify", nil
  end
  if lstat.type ~= "file" then
    return nil, name .. " is not a regular file", nil
  end
  local fd, open_err = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil, "could not open " .. name .. (open_err and (": " .. open_err) or ""), nil
  end
  local fstat = vim.uv.fs_fstat(fd)
  if not stat_matches(fstat, lstat) then
    vim.uv.fs_close(fd)
    return nil, name .. " changed or became a symlink while reading", nil
  end
  local chunks, offset = {}, 0
  while true do
    local chunk, read_err = vim.uv.fs_read(fd, 65536, offset)
    if not chunk then
      vim.uv.fs_close(fd)
      return nil, "could not read " .. name .. (read_err and (": " .. read_err) or ""), nil
    end
    if chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
    offset = offset + #chunk
  end
  vim.uv.fs_close(fd)
  return table.concat(chunks), nil, fstat
end

---Mask Java comments (`//`, `/* */`) and string/char/text-block literals with
---spaces while preserving `\n`, so line numbers remain exact.
---@param text string
---@return string masked, string|nil unclosed_err
local function mask_java_comments_and_strings(text)
  local out = {}
  local unclosed_err = nil
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    local two = text:sub(i, i + 1)
    if two == "//" then
      while i <= n do
        local ch = text:sub(i, i)
        if ch == "\n" or ch == "\r" then
          out[#out + 1] = ch
          i = i + 1
          break
        end
        out[#out + 1] = " "
        i = i + 1
      end
    elseif two == "/*" then
      out[#out + 1] = "  "
      i = i + 2
      local closed = false
      while i <= n do
        if text:sub(i, i + 1) == "*/" then
          out[#out + 1] = "  "
          i = i + 2
          closed = true
          break
        end
        local ch = text:sub(i, i)
        out[#out + 1] = (ch == "\n" or ch == "\r") and ch or " "
        i = i + 1
      end
      if not closed and not unclosed_err then
        unclosed_err = "unclosed block comment"
      end
    elseif text:sub(i, i + 2) == '"""' then
      out[#out + 1] = "   "
      i = i + 3
      local closed = false
      while i <= n do
        local ch = text:sub(i, i)
        if ch == "\\" then
          out[#out + 1] = " "
          if i + 1 <= n then
            local nxt = text:sub(i + 1, i + 1)
            out[#out + 1] = (nxt == "\n" or nxt == "\r") and nxt or " "
          end
          i = i + 2
        elseif text:sub(i, i + 2) == '"""' then
          out[#out + 1] = "   "
          i = i + 3
          closed = true
          break
        else
          out[#out + 1] = (ch == "\n" or ch == "\r") and ch or " "
          i = i + 1
        end
      end
      if not closed and not unclosed_err then
        unclosed_err = "unclosed text block literal"
      end
    elseif c == '"' or c == "'" then
      local q = c
      out[#out + 1] = " "
      i = i + 1
      local closed = false
      while i <= n do
        local ch = text:sub(i, i)
        if ch == "\\" then
          out[#out + 1] = " "
          if i + 1 <= n then
            local nxt = text:sub(i + 1, i + 1)
            out[#out + 1] = (nxt == "\n" or nxt == "\r") and nxt or " "
          end
          i = i + 2
        elseif ch == q then
          out[#out + 1] = " "
          i = i + 1
          closed = true
          break
        elseif ch == "\n" or ch == "\r" then
          out[#out + 1] = ch
          i = i + 1
          break
        else
          out[#out + 1] = " "
          i = i + 1
        end
      end
      if not closed and not unclosed_err then
        unclosed_err = "unclosed string or character literal"
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out), unclosed_err
end

local function detect_indent_unit(lines)
  for i = 1, math.min(#lines, 200) do
    local line = lines[i]
    local tab = line:match("^(\t+)%S")
    if tab then
      return "\t"
    end
    local spaces = line:match("^( +)%S")
    if spaces then
      return string.rep(" ", #spaces)
    end
  end
  return "  "
end

local function line_tail_needs_split(raw_tail, masked_tail)
  if masked_tail:match("%S") ~= nil then
    return true
  end
  local i, n = 1, #raw_tail
  while i <= n do
    local two = raw_tail:sub(i, i + 1)
    if two == "//" then
      return false
    elseif two == "/*" then
      local close = raw_tail:find("*/", i + 2, true)
      if not close then
        return true
      end
      i = close + 2
    else
      i = i + 1
    end
  end
  return false
end

---Analyze an existing Java test file for package, imports, import conflicts,
---existing method names, and exact closing brace of the target test class.
---@param lines string[]
---@param target_class_name string|nil
---@return table
local function analyze_test_file(lines, target_class_name)
  local raw = table.concat(lines, "\n")
  local masked, unclosed_err = mask_java_comments_and_strings(raw)
  local masked_lines = vim.split(masked, "\n", { plain = true })

  local pkg_stmt = nil
  local last_import_stmt = nil
  local last_static_import_line = nil
  local has_exact_junit5_test = false
  local has_wildcard_junit5_test = false
  local conflicting_test_import = false
  local conflicting_wildcard_test = false
  local has_static_fail = false
  local conflicting_fail_import = false
  local has_assertions_class = false
  local conflicting_assertions_import = false
  local local_test_type = false
  local malformed_reason = unclosed_err

  local existing_methods = {}
  local scope_stack = {}
  local target_found = false
  local target_open_line, target_close_line, target_close_col = nil, nil, nil
  local first_type_decl_line = nil
  local seen_first_type = false

  -- Tokenize braces, punctuation, and identifiers on masked text while tracking line/col.
  local line_no = 1
  local col_no = 0
  local tokens = {}
  local i, n = 1, #masked
  while i <= n do
    local ch = masked:sub(i, i)
    if ch == "\n" then
      line_no = line_no + 1
      col_no = 0
      i = i + 1
    elseif ch:match("[%a_$]") then
      local start_col = col_no + 1
      local j = i + 1
      while j <= n and masked:sub(j, j):match("[%w_$]") do
        j = j + 1
      end
      local word = masked:sub(i, j - 1)
      tokens[#tokens + 1] = { kind = "id", val = word, line = line_no, col = start_col }
      col_no = col_no + (j - i)
      i = j
    elseif
      ch == "{"
      or ch == "}"
      or ch == "("
      or ch == ")"
      or ch == ";"
      or ch == "="
      or ch == "."
      or ch == ":"
      or ch == "*"
      or ch == "@"
    then
      col_no = col_no + 1
      tokens[#tokens + 1] = { kind = ch, val = ch, line = line_no, col = col_no }
      i = i + 1
    elseif masked:sub(i, i + 1) == "->" then
      tokens[#tokens + 1] = { kind = "->", val = "->", line = line_no, col = col_no + 1 }
      col_no = col_no + 2
      i = i + 2
    else
      col_no = col_no + 1
      i = i + 1
    end
  end

  local ti = 1
  local tn = #tokens
  local paren_depth = 0

  while ti <= tn do
    local tok = tokens[ti]
    local prev = tokens[ti - 1]
    if
      #scope_stack == 0
      and not seen_first_type
      and tok.kind == "id"
      and (tok.val == "package" or tok.val == "import")
      and not (prev and (prev.kind == "." or prev.kind == "@"))
    then
      local is_pkg = tok.val == "package"
      local j = ti + 1
      local is_static = false
      if not is_pkg and tokens[j] and tokens[j].kind == "id" and tokens[j].val == "static" then
        is_static = true
        j = j + 1
      end
      local parts = {}
      local semi_tok = nil
      while j <= tn do
        local nt = tokens[j]
        if nt.kind == ";" then
          semi_tok = nt
          break
        elseif nt.kind == "{" or nt.kind == "}" then
          break
        elseif nt.kind == "id" or nt.kind == "." or (not is_pkg and nt.kind == "*") then
          parts[#parts + 1] = nt.val
        else
          parts = {}
          break
        end
        j = j + 1
      end
      if semi_tok and #parts > 0 then
        local stmt = {
          start_line = tok.line,
          start_col = tok.col,
          end_line = semi_tok.line,
          end_col = semi_tok.col,
          name = table.concat(parts),
        }
        if is_pkg then
          pkg_stmt = pkg_stmt or stmt
        else
          local imp_target = table.concat(parts)
          last_import_stmt = stmt
          if is_static then
            last_static_import_line = semi_tok.line
            if
              imp_target == "org.junit.jupiter.api.Assertions.fail"
              or imp_target == "org.junit.jupiter.api.Assertions.*"
            then
              has_static_fail = true
            elseif imp_target:match("%.fail$") or imp_target == "org.junit.Assert.*" then
              conflicting_fail_import = true
            end
          else
            if imp_target == "org.junit.jupiter.api.Test" then
              has_exact_junit5_test = true
            elseif imp_target == "org.junit.jupiter.api.*" then
              has_wildcard_junit5_test = true
            elseif imp_target:match("%.Test$") then
              conflicting_test_import = true
            elseif imp_target == "org.junit.*" or imp_target == "org.testng.annotations.*" then
              conflicting_wildcard_test = true
            end
            if imp_target == "org.junit.jupiter.api.Assertions" or imp_target == "org.junit.jupiter.api.*" then
              has_assertions_class = true
            elseif imp_target:match("%.Assertions$") then
              conflicting_assertions_import = true
            end
          end
        end
        ti = j + 1
      else
        malformed_reason = malformed_reason or ("malformed " .. tok.val .. " declaration")
        ti = ti + 1
      end
    elseif tok.kind == "(" then
      paren_depth = paren_depth + 1
      ti = ti + 1
    elseif tok.kind == ")" and paren_depth > 0 then
      paren_depth = paren_depth - 1
      ti = ti + 1
    elseif tok.kind == "{" then
      local top = scope_stack[#scope_stack]
      local is_class_open = false
      local type_kw = nil
      local class_name = nil
      local is_annotation_type = false

      local back = ti - 1
      local bp = 0
      local saw_throws_or_close_paren = false
      local paren_close_idx = nil
      local saw_non_method_op = false
      while back >= 1 do
        local bt = tokens[back]
        if bt.kind == ")" then
          if bp == 0 and not saw_throws_or_close_paren then
            paren_close_idx = back
            saw_throws_or_close_paren = true
          end
          bp = bp + 1
        elseif bt.kind == "(" then
          bp = bp - 1
        elseif bp == 0 and (bt.kind == ";" or bt.kind == "{" or bt.kind == "}") then
          break
        elseif bp == 0 and (bt.kind == "=" or bt.kind == "->") then
          saw_non_method_op = true
          break
        elseif bp == 0 and bt.kind == "id" then
          if bt.val == "class" or bt.val == "interface" or bt.val == "enum" or bt.val == "record" then
            local before_kw = tokens[back - 1]
            if not (before_kw and before_kw.kind == ".") then
              if tokens[back + 1] and tokens[back + 1].kind == "id" then
                is_class_open = true
                type_kw = bt.val
                is_annotation_type = (bt.val == "interface" and before_kw and before_kw.kind == "@") == true
                class_name = tokens[back + 1].val
                first_type_decl_line = first_type_decl_line or tok.line
              end
              break
            end
          end
        end
        back = back - 1
      end

      if is_class_open and (#scope_stack == 0 or top == "class" or top == "target_class") then
        if class_name == "Test" then
          local_test_type = true
        end
        if #scope_stack == 0 then
          seen_first_type = true
        end
        local is_exact_target = #scope_stack == 0
          and type_kw == "class"
          and not is_annotation_type
          and type(target_class_name) == "string"
          and target_class_name ~= ""
          and class_name == target_class_name
        if is_exact_target and not target_found then
          target_found = true
          target_open_line = tok.line
          scope_stack[#scope_stack + 1] = "target_class"
        else
          scope_stack[#scope_stack + 1] = "class"
        end
      elseif (top == "class" or top == "target_class") and paren_close_idx and not saw_non_method_op then
        local p = paren_close_idx - 1
        local d = 1
        while p >= 1 and d > 0 do
          if tokens[p].kind == ")" then
            d = d + 1
          elseif tokens[p].kind == "(" then
            d = d - 1
          end
          p = p - 1
        end
        local name_tok = tokens[p]
        local prev_tok = tokens[p - 1]
        if
          name_tok
          and name_tok.kind == "id"
          and not JAVA_KEYWORDS[name_tok.val]
          and not (prev_tok and prev_tok.kind == "id" and prev_tok.val == "new")
          and not (prev_tok and (prev_tok.kind == "." or prev_tok.kind == ":" or prev_tok.kind == "="))
        then
          if top == "target_class" then
            existing_methods[name_tok.val] = true
          end
          scope_stack[#scope_stack + 1] = "method"
        else
          scope_stack[#scope_stack + 1] = "other"
        end
      else
        scope_stack[#scope_stack + 1] = "other"
      end
      ti = ti + 1
    elseif tok.kind == "}" then
      if #scope_stack == 0 then
        malformed_reason = malformed_reason or "unbalanced braces in test file"
      else
        local popped = table.remove(scope_stack)
        if popped == "target_class" then
          target_close_line = tok.line
          target_close_col = tok.col
        end
      end
      ti = ti + 1
    else
      ti = ti + 1
    end
  end

  if #scope_stack > 0 then
    malformed_reason = malformed_reason or "unclosed brace in test file"
    target_found = false
    target_close_line = nil
    target_close_col = nil
  end

  if existing_methods["fail"] then
    conflicting_fail_import = true
  end

  local has_junit5_test = has_exact_junit5_test or (has_wildcard_junit5_test and not conflicting_wildcard_test)
  if conflicting_wildcard_test or local_test_type then
    conflicting_test_import = true
  end

  return {
    pkg_stmt = pkg_stmt,
    pkg_line = pkg_stmt and pkg_stmt.end_line or nil,
    last_import_stmt = last_import_stmt,
    last_import_line = last_import_stmt and last_import_stmt.end_line or nil,
    last_static_import_line = last_static_import_line,
    first_type_decl_line = first_type_decl_line,
    has_junit5_test = has_junit5_test,
    conflicting_test_import = conflicting_test_import,
    has_static_fail = has_static_fail,
    conflicting_fail_import = conflicting_fail_import,
    has_assertions_class = has_assertions_class,
    conflicting_assertions_import = conflicting_assertions_import,
    local_test_type = local_test_type,
    existing_methods = existing_methods,
    target_found = target_found,
    target_open_line = target_open_line,
    target_close_line = target_close_line,
    target_close_col = target_close_col,
    malformed_reason = malformed_reason,
    masked_lines = masked_lines,
    indent = detect_indent_unit(lines),
  }
end

local function java_string_escape(s)
  return tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n")
end

---Choose safe JUnit 5 `@Test` annotation and needed imports for a target file.
---@param analysis table
---@return string test_annotation, string[] imports_to_add
local function safe_junit5_syntax(analysis)
  local imports_to_add = {}
  local test_ann = "@Test"
  if analysis.conflicting_test_import then
    test_ann = "@org.junit.jupiter.api.Test"
  elseif not analysis.has_junit5_test then
    imports_to_add[#imports_to_add + 1] = "import org.junit.jupiter.api.Test;"
  end
  return test_ann, imports_to_add
end

local plan_existing_test_edit

local function built_in_junit5_template(class_name, pkg)
  local pkg_line = (pkg and pkg ~= "") and ("package " .. pkg .. ";\n\n") or ""
  return pkg_line .. "import org.junit.jupiter.api.Test;\n\n" .. "public class " .. class_name .. " {\n}\n"
end

local function strip_dummy_junit5_test(rendered)
  return (rendered:gsub("@[%w_.]*Test%s+[^;\n{}]*void%s+test%s*%(%s*%)%s*{%s*}", "", 1))
end

local function apply_plan_to_lines(base_lines, plan)
  local be = plan.body_edit
  for _ = 1, (be.end_row0 - be.start_row0) do
    table.remove(base_lines, be.start_row0 + 1)
  end
  for k, line in ipairs(be.lines) do
    table.insert(base_lines, be.start_row0 + k, line)
  end
  if plan.import_edit then
    local ie = plan.import_edit
    for _ = 1, (ie.end_row0 - ie.start_row0) do
      table.remove(base_lines, ie.start_row0 + 1)
    end
    for k, line in ipairs(ie.lines) do
      table.insert(base_lines, ie.start_row0 + k, line)
    end
  end
  return base_lines
end

local function reindent_java_lines(base_lines, indent)
  local raw = table.concat(base_lines, "\n")
  local masked = mask_java_comments_and_strings(raw)
  local masked_lines = vim.split(masked, "\n", { plain = true })

  local formatted = {}
  local depth = 0
  for idx, line in ipairs(base_lines) do
    local trimmed = vim.trim(line)
    if trimmed == "" then
      if #formatted > 0 and formatted[#formatted] ~= "" then
        formatted[#formatted + 1] = ""
      end
    else
      local mline = vim.trim(masked_lines[idx] or "")
      local leading_close = 0
      for c in mline:gmatch(".") do
        if c == "}" then
          leading_close = leading_close + 1
        elseif c ~= " " and c ~= "\t" then
          break
        end
      end
      local line_depth = math.max(0, depth - leading_close)
      formatted[#formatted + 1] = string.rep(indent, line_depth) .. trimmed
      local opens = 0
      for _ in mline:gmatch("{") do
        opens = opens + 1
      end
      local closes = 0
      for _ in mline:gmatch("}") do
        closes = closes + 1
      end
      depth = math.max(0, depth + opens - closes)
    end
  end
  while #formatted > 0 and formatted[#formatted] == "" do
    table.remove(formatted)
  end
  return formatted
end

local function validate_rendered_method_test(formatted_lines, class_name, test_method_name)
  local final_text = table.concat(formatted_lines, "\n") .. "\n"
  local check = analyze_test_file(formatted_lines, class_name)
  if check.malformed_reason or not check.target_found or not check.target_close_line then
    return nil, "rendered test class is malformed or missing target class '" .. class_name .. "'"
  end
  if not check.existing_methods[test_method_name] then
    return nil, "rendered test class does not contain method '" .. test_method_name .. "'"
  end
  if
    not final_text:find("TODO: implement test for", 1, true)
    or not final_text:find("java.lang.AssertionError", 1, true)
  then
    return nil, "rendered test class does not contain explicit pending failure skeleton"
  end
  return final_text, nil
end

---Render a brand-new JUnit 5 test class using `jc.templates` (when installed)
---with an explicitly pending/failing skeleton for the chosen method.
---Refuses incompatible `jc.templates` output instead of writing a skeleton-less file.
---@param class_name string
---@param pkg string|nil
---@param test_method_name string
---@param method_label string
---@param indent string|nil
---@return string|nil rendered, string|nil err
local function render_junit5_for_method(class_name, pkg, test_method_name, method_label, indent)
  indent = indent or "  "
  local base_rendered
  local ok_tpl, templates = pcall(require, "jc.templates")
  if ok_tpl then
    if type(templates) ~= "table" or type(templates.render) ~= "function" then
      return nil, "incompatible jc.templates module (missing render function)"
    end
    local ok_r, rendered = pcall(templates.render, "junit5", {
      name = class_name,
      package = pkg or "",
      fields = {},
    })
    if not ok_r or type(rendered) ~= "string" or vim.trim(rendered) == "" then
      return nil, "incompatible jc.templates 'junit5' template (render failed or returned empty)"
    end
    base_rendered = rendered
  else
    base_rendered = built_in_junit5_template(class_name, pkg)
  end

  local stripped = strip_dummy_junit5_test(base_rendered)
  local base_lines = vim.split(stripped:gsub("\r\n", "\n"), "\n", { plain = true })
  local rendered_package = analyze_test_file(base_lines, class_name).pkg_stmt
  if (rendered_package and rendered_package.name or "") ~= (pkg or "") then
    return nil, "incompatible JUnit 5 template: package does not match target"
  end
  local plan, plan_err = plan_existing_test_edit(base_lines, class_name, test_method_name, method_label, indent)
  if not plan then
    local prefix = ok_tpl and "incompatible jc.templates 'junit5' template: " or "failed to build JUnit 5 template: "
    return nil, prefix .. tostring(plan_err or "cannot insert test skeleton")
  end

  apply_plan_to_lines(base_lines, plan)
  local formatted = reindent_java_lines(base_lines, indent)
  return validate_rendered_method_test(formatted, class_name, test_method_name)
end

local function build_import_lines(anchor_is_pkg, imports_to_add, tail_nonblank)
  local imp_lines = {}
  if anchor_is_pkg then
    imp_lines[#imp_lines + 1] = ""
  end
  vim.list_extend(imp_lines, imports_to_add)
  if tail_nonblank then
    imp_lines[#imp_lines + 1] = ""
  end
  return imp_lines
end

---Plan surgical buffer edits for inserting a test skeleton into an existing test file.
---@param lines string[]
---@param target_class_name string|nil
---@param test_method_name string
---@param method_label string
---@param indent_override string|nil
---@return table|nil plan, string|nil err
plan_existing_test_edit = function(lines, target_class_name, test_method_name, method_label, indent_override)
  local analysis = analyze_test_file(lines, target_class_name)
  if analysis.malformed_reason then
    return nil, analysis.malformed_reason .. " — refusing to modify"
  end
  if not analysis.target_found or not analysis.target_close_line or not analysis.target_close_col then
    local target_desc = (type(target_class_name) == "string" and target_class_name ~= "")
        and ("class '" .. target_class_name .. "'")
      or "test class"
    return nil, "could not locate " .. target_desc .. " — refusing to modify"
  end
  if analysis.existing_methods[test_method_name] then
    return nil, "method '" .. test_method_name .. "' already exists in test class"
  end

  local indent = indent_override or analysis.indent or "  "
  local test_ann, imports_to_add = safe_junit5_syntax(analysis)
  local todo_msg = java_string_escape("TODO: implement test for " .. method_label)
  local method_lines = {
    indent .. test_ann,
    indent .. "void " .. test_method_name .. "() {",
    indent .. indent .. 'throw new java.lang.AssertionError("' .. todo_msg .. '");',
    indent .. "}",
  }

  local close_idx = analysis.target_close_line
  local close_col = analysis.target_close_col
  local close_line = lines[close_idx] or ""
  local before_brace = close_line:sub(1, close_col - 1)
  local after_brace = close_line:sub(close_col + 1)

  local anchor = analysis.last_import_stmt or analysis.pkg_stmt
  local anchor_is_pkg = analysis.last_import_stmt == nil and analysis.pkg_stmt ~= nil
  local anchor_needs_split = false
  if #imports_to_add > 0 and anchor then
    local raw_tail = (lines[anchor.end_line] or ""):sub(anchor.end_col + 1)
    local masked_tail = (analysis.masked_lines[anchor.end_line] or ""):sub(anchor.end_col + 1)
    anchor_needs_split = line_tail_needs_split(raw_tail, masked_tail)
  end

  -- When imports must be inserted onto the same line that holds the target class
  -- closing brace (e.g. `package p; public class FooTest {}`), build one combined
  -- surgical replacement so body and import edits never collide on the same row.
  if #imports_to_add > 0 and anchor and anchor_needs_split and anchor.end_line == close_idx then
    if anchor.end_col >= close_col then
      return nil, "inline package/import layout conflicts with class closing brace — refusing to modify"
    end
    local before_anchor = close_line:sub(1, anchor.end_col)
    local between = close_line:sub(anchor.end_col + 1, close_col - 1):gsub("^%s+", ""):gsub("%s+$", "")
    local combined = { before_anchor }
    vim.list_extend(combined, build_import_lines(anchor_is_pkg, imports_to_add, true))
    combined[#combined + 1] = between
    combined[#combined + 1] = ""
    vim.list_extend(combined, method_lines)
    local fail_offset = #combined - 1
    combined[#combined + 1] = "}" .. after_brace
    return {
      body_edit = {
        start_row0 = close_idx - 1,
        end_row0 = close_idx,
        lines = combined,
        cursor_offset_in_insert = fail_offset,
      },
      import_edit = nil,
    },
      nil
  end

  local body_edit
  if before_brace:match("^%s*$") then
    local insert_lines = {}
    local prev_line = close_idx > 1 and lines[close_idx - 1] or ""
    if vim.trim(prev_line) ~= "" and not prev_line:match("{%s*$") then
      insert_lines[#insert_lines + 1] = ""
    end
    vim.list_extend(insert_lines, method_lines)
    body_edit = {
      start_row0 = close_idx - 1,
      end_row0 = close_idx - 1,
      lines = insert_lines,
      cursor_offset_in_insert = #insert_lines - 1,
    }
  else
    local replacement = { before_brace:gsub("%s+$", ""), "" }
    vim.list_extend(replacement, method_lines)
    local fail_offset = #replacement - 1
    replacement[#replacement + 1] = "}" .. after_brace
    body_edit = {
      start_row0 = close_idx - 1,
      end_row0 = close_idx,
      lines = replacement,
      cursor_offset_in_insert = fail_offset,
    }
  end

  local import_edit = nil
  if #imports_to_add > 0 then
    if anchor and anchor_needs_split then
      local anchor_line = lines[anchor.end_line] or ""
      local before_anchor = anchor_line:sub(1, anchor.end_col)
      local after_anchor = anchor_line:sub(anchor.end_col + 1):gsub("^%s+", "")
      local split_lines = { before_anchor }
      vim.list_extend(split_lines, build_import_lines(anchor_is_pkg, imports_to_add, after_anchor ~= ""))
      if after_anchor ~= "" then
        split_lines[#split_lines + 1] = after_anchor
      end
      import_edit = {
        start_row0 = anchor.end_line - 1,
        end_row0 = anchor.end_line,
        lines = split_lines,
      }
    elseif anchor then
      local next_line = lines[anchor.end_line + 1]
      local needs_trailing_blank = anchor_is_pkg and next_line ~= nil and vim.trim(next_line) ~= ""
      import_edit = {
        start_row0 = anchor.end_line,
        end_row0 = anchor.end_line,
        lines = build_import_lines(anchor_is_pkg, imports_to_add, needs_trailing_blank),
      }
    else
      local needs_trailing_blank = lines[1] ~= nil and vim.trim(lines[1]) ~= ""
      import_edit = {
        start_row0 = 0,
        end_row0 = 0,
        lines = build_import_lines(false, imports_to_add, needs_trailing_blank),
      }
    end
  end

  return {
    body_edit = body_edit,
    import_edit = import_edit,
  }, nil
end

local function find_fail_cursor_line(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for idx, line in ipairs(lines) do
    if line:find("TODO: implement test for", 1, true) then
      local col = (line:find("%S") or 1) - 1
      return idx, col
    end
  end
  return 1, 0
end

local function check_existing_target(path, expected_class_name)
  local loaded_buf, buf_err, loaded_bufs = inspect_target_buffer(path)
  if buf_err then
    return nil, buf_err
  end
  local disk_data, read_err, disk_stat = read_regular_file(path)
  if not disk_data then
    return nil, read_err or "could not read target test file"
  end
  local ok_bytes, bytes_err = verify_loaded_buffers_match_disk(loaded_bufs, disk_data, path)
  if not ok_bytes then
    return nil, bytes_err
  end

  local lines
  if loaded_buf then
    lines = vim.api.nvim_buf_get_lines(loaded_buf, 0, -1, false)
  else
    local normalized = disk_data:gsub("^\xef\xbb\xbf", ""):gsub("\r\n", "\n")
    lines = vim.split(normalized, "\n", { plain = true })
  end
  local analysis = analyze_test_file(lines, expected_class_name)
  if analysis.malformed_reason then
    return nil, analysis.malformed_reason .. " — refusing to modify"
  end
  if not analysis.target_found or not analysis.target_close_line or not analysis.target_close_col then
    local target_desc = (type(expected_class_name) == "string" and expected_class_name ~= "")
        and ("class '" .. expected_class_name .. "'")
      or "test class"
    return nil, "could not locate " .. target_desc .. " — refusing to modify"
  end

  return {
    loaded_buf = loaded_buf,
    loaded_bufs = loaded_bufs,
    tick = loaded_buf and vim.b[loaded_buf].changedtick or nil,
    disk_data = disk_data,
    disk_stat = disk_stat,
    analysis = analysis,
  },
    nil
end

local function create_new_test_file_for_method(target_path, class_name, pkg, test_method_name, method_label, src_indent)
  local _, buf_err, loaded_bufs = inspect_target_buffer(target_path)
  if buf_err then
    ui.notify(buf_err, vim.log.levels.WARN)
    return false
  end
  for _, buf in ipairs(loaded_bufs or {}) do
    local b_bytes = buffer_to_disk_bytes(buf)
    if b_bytes ~= "" then
      ui.notify(
        "target test buffer (" .. vim.fs.basename(target_path) .. ") has content not on disk — save or close first",
        vim.log.levels.WARN
      )
      return false
    end
  end
  local existing_lstat = vim.uv.fs_lstat(target_path)
  if existing_lstat then
    ui.notify("target test file already exists on disk — refusing to overwrite: " .. target_path, vim.log.levels.WARN)
    return false
  end

  local rendered, render_err = render_junit5_for_method(class_name, pkg, test_method_name, method_label, src_indent)
  if not rendered then
    ui.notify(render_err or "could not render JUnit 5 test file", vim.log.levels.ERROR)
    return false
  end

  vim.fn.mkdir(vim.fs.dirname(target_path), "p")

  -- Exclusive creation (`O_CREAT | O_EXCL`) prevents overwriting a file or
  -- dangling symlink that appeared after confirmation.
  local fd, open_err = vim.uv.fs_open(target_path, "wx", 438)
  if not fd then
    ui.notify("could not create test file: " .. tostring(open_err), vim.log.levels.WARN)
    return false
  end
  local written, write_err = vim.uv.fs_write(fd, rendered, 0)
  local closed, close_err = vim.uv.fs_close(fd)
  if written ~= #rendered or not closed then
    pcall(vim.uv.fs_unlink, target_path)
    ui.notify(
      "could not finish writing test file: " .. tostring(write_err or close_err or "short write"),
      vim.log.levels.ERROR
    )
    return false
  end

  if not open_file(target_path) then
    return false
  end
  vim.b.jc_new_java_file = true
  local cur_buf = vim.api.nvim_get_current_buf()
  local row, col = find_fail_cursor_line(cur_buf)
  pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
  return true
end

local function apply_existing_test_skeleton(target_path, target_class_name, test_method_name, method_label, snapshot)
  local cur_snap, check_err = check_existing_target(target_path, target_class_name)
  if not cur_snap then
    ui.notify(check_err or "could not verify target test file", vim.log.levels.WARN)
    return false
  end
  if snapshot.loaded_buf then
    if
      not vim.api.nvim_buf_is_valid(snapshot.loaded_buf) or vim.b[snapshot.loaded_buf].changedtick ~= snapshot.tick
    then
      ui.notify("target test buffer changed while waiting for confirmation — run again", vim.log.levels.WARN)
      return false
    end
  end
  if not stat_matches(cur_snap.disk_stat, snapshot.disk_stat) or cur_snap.disk_data ~= snapshot.disk_data then
    ui.notify("target test file changed on disk while waiting for confirmation — run again", vim.log.levels.WARN)
    return false
  end

  if cur_snap.loaded_buf then
    vim.api.nvim_set_current_buf(cur_snap.loaded_buf)
  elseif not open_file(target_path) then
    return false
  end

  local target_buf = vim.api.nvim_get_current_buf()
  if vim.bo[target_buf].modified then
    ui.notify("target test buffer has unsaved changes — refusing to modify", vim.log.levels.WARN)
    return false
  end
  if not vim.bo[target_buf].modifiable or vim.bo[target_buf].readonly then
    ui.notify("target test buffer is read-only or not modifiable", vim.log.levels.WARN)
    return false
  end

  local lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
  local plan, plan_err = plan_existing_test_edit(lines, target_class_name, test_method_name, method_label)
  if not plan then
    ui.notify(plan_err or "could not plan test insertion", vim.log.levels.WARN)
    return false
  end

  -- Apply bottom-up so body line numbers stay valid before inserting imports.
  local be = plan.body_edit
  vim.api.nvim_buf_set_lines(target_buf, be.start_row0, be.end_row0, false, be.lines)
  local import_shift = 0
  if plan.import_edit then
    local ie = plan.import_edit
    pcall(vim.cmd, "undojoin")
    vim.api.nvim_buf_set_lines(target_buf, ie.start_row0, ie.end_row0, false, ie.lines)
    import_shift = #ie.lines - (ie.end_row0 - ie.start_row0)
  end

  local target_row = be.start_row0 + import_shift + be.cursor_offset_in_insert
  local target_line = vim.api.nvim_buf_get_lines(target_buf, target_row - 1, target_row, false)[1] or ""
  local target_col = (target_line:find("%S") or 1) - 1
  pcall(vim.api.nvim_win_set_cursor, 0, { target_row, target_col })
  return true
end

local function method_display_label(method)
  local prefix = (method.qualified_type and method.qualified_type ~= "") and (method.qualified_type .. ".") or ""
  return prefix .. method.display_signature
end

local function path_under_root(root_dir, path)
  local croot = canonical(root_dir)
  local cpath = canonical(path)
  if not croot or not cpath then
    return false
  end
  return cpath == croot or cpath:sub(1, #croot + 1) == croot .. "/"
end

local function inspect_new_template_methods(class_name, pkg)
  local ok_tpl, templates = pcall(require, "jc.templates")
  if not ok_tpl then
    return {}, nil
  end
  if type(templates) ~= "table" or type(templates.render) ~= "function" then
    return nil, "incompatible jc.templates module (missing render function)"
  end
  local ok_r, rendered = pcall(templates.render, "junit5", {
    name = class_name,
    package = pkg or "",
    fields = {},
  })
  if not ok_r or type(rendered) ~= "string" or vim.trim(rendered) == "" then
    return nil, "incompatible jc.templates 'junit5' template (render failed or returned empty)"
  end
  local stripped = strip_dummy_junit5_test(rendered)
  local base_lines = vim.split(stripped:gsub("\r\n", "\n"), "\n", { plain = true })
  local analysis = analyze_test_file(base_lines, class_name)
  if analysis.malformed_reason or not analysis.target_found or not analysis.target_close_line then
    return nil,
      "incompatible jc.templates 'junit5' template: " .. tostring(
        analysis.malformed_reason or ("missing class '" .. class_name .. "'")
      )
  end
  return analysis.existing_methods, nil
end

local function run_method_test_flow(ctx, nav)
  local op_token = skeleton_ctrl:begin_operation()

  local function abort_if_stale()
    if not skeleton_ctrl:is_op_active(op_token) then
      return true
    end
    if not skeleton_ctrl:context_still_valid(ctx, true, true) then
      skeleton_ctrl:end_operation(op_token)
      return true
    end
    return false
  end

  if nav.status == "match" then
    local _, pre_err = check_existing_target(nav.target, nav.match.name)
    if pre_err then
      ui.notify(pre_err, vim.log.levels.WARN)
      skeleton_ctrl:end_operation(op_token)
      return
    end
  end

  local function finish_confirm(dest, chosen_method, test_method_name, classpath_info, snapshot)
    if abort_if_stale() then
      return
    end
    local method_label = method_display_label(chosen_method)
    local rel_target = ctx.project_root and vim.fs.relpath(ctx.project_root, dest.path) or dest.path
    local confirm_label = dest.is_new and "✔ Create test file & skeleton" or "✔ Insert test skeleton"
    local cancel_label = "✖ Cancel"
    local items = {
      confirm_label,
      cancel_label,
      "Method: " .. method_label,
      "Test method: " .. test_method_name .. "()",
      "Target: " .. (rel_target or dest.path) .. (dest.is_new and "  (new file)" or "  (existing file)"),
      "Classpath: " .. classpath_info.summary,
    }

    ui.pick_one(items, "Java: Tests — confirm JUnit 5 test skeleton", function(choice)
      if abort_if_stale() then
        return
      end
      if choice == nil or choice == cancel_label then
        skeleton_ctrl:end_operation(op_token)
        return
      end
      if choice ~= confirm_label then
        finish_confirm(dest, chosen_method, test_method_name, classpath_info, snapshot)
        return
      end
      if dest.is_new then
        local src_lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, 200, false)
        local src_indent = detect_indent_unit(src_lines)
        create_new_test_file_for_method(
          dest.path,
          dest.class_name,
          dest.pkg,
          test_method_name,
          method_label,
          src_indent
        )
      else
        apply_existing_test_skeleton(dest.path, dest.class_name, test_method_name, method_label, snapshot)
      end
      skeleton_ctrl:end_operation(op_token)
    end)
  end

  local function ask_test_name(dest, chosen_method, classpath_info, snapshot, existing_methods, suggested_name)
    if abort_if_stale() then
      return
    end
    ui.ask("Java: Tests — test method name: ", suggested_name, function(input_name)
      if abort_if_stale() then
        return
      end
      if input_name == nil then
        skeleton_ctrl:end_operation(op_token)
        return
      end
      local trimmed = vim.trim(input_name)
      if not is_java_identifier(trimmed) then
        ui.notify("invalid Java method identifier: " .. (trimmed == "" and "(empty)" or trimmed), vim.log.levels.WARN)
        ask_test_name(dest, chosen_method, classpath_info, snapshot, existing_methods, suggested_name)
        return
      end
      if existing_methods[trimmed] then
        ui.notify(
          "method '" .. trimmed .. "' already exists in " .. vim.fs.basename(dest.path) .. " — choose another name",
          vim.log.levels.WARN
        )
        ask_test_name(dest, chosen_method, classpath_info, snapshot, existing_methods, suggested_name)
        return
      end
      finish_confirm(dest, chosen_method, trimmed, classpath_info, snapshot)
    end)
  end

  local function prepare_target_and_ask_name(dest, chosen_method, classpath_info)
    if abort_if_stale() then
      return
    end

    if dest.is_new then
      local _, buf_err, loaded_bufs = inspect_target_buffer(dest.path)
      if buf_err then
        ui.notify(buf_err, vim.log.levels.WARN)
        skeleton_ctrl:end_operation(op_token)
        return
      end
      for _, buf in ipairs(loaded_bufs or {}) do
        local b_bytes = buffer_to_disk_bytes(buf)
        if b_bytes ~= "" then
          ui.notify(
            "target test buffer (" .. vim.fs.basename(dest.path) .. ") has content not on disk — save or close first",
            vim.log.levels.WARN
          )
          skeleton_ctrl:end_operation(op_token)
          return
        end
      end
      if vim.uv.fs_lstat(dest.path) then
        ui.notify(
          "target test file already exists on disk — refusing to overwrite: " .. dest.path,
          vim.log.levels.WARN
        )
        skeleton_ctrl:end_operation(op_token)
        return
      end
      local tpl_methods, tpl_err = inspect_new_template_methods(dest.class_name, dest.pkg)
      if not tpl_methods then
        ui.notify(tpl_err or "incompatible jc.templates 'junit5' template", vim.log.levels.ERROR)
        skeleton_ctrl:end_operation(op_token)
        return
      end
      local suggested = default_test_method_name(chosen_method, tpl_methods)
      ask_test_name(dest, chosen_method, classpath_info, nil, tpl_methods, suggested)
      return
    end

    local snapshot, check_err = check_existing_target(dest.path, dest.class_name)
    if not snapshot then
      ui.notify(check_err or "could not verify target test file", vim.log.levels.WARN)
      skeleton_ctrl:end_operation(op_token)
      return
    end

    local existing_methods = snapshot.analysis.existing_methods
    local suggested = default_test_method_name(chosen_method, existing_methods)
    ask_test_name(dest, chosen_method, classpath_info, snapshot, existing_methods, suggested)
  end

  local function verify_target_classpath(client, dest, chosen_method)
    if abort_if_stale() then
      return
    end
    local target_mod = dest.module or nav.module
    local target_lbl = dest.module_label or nav.module_label
    local is_other_module = target_mod ~= nav.module

    if
      is_other_module
      and type(client.root_dir) == "string"
      and client.root_dir ~= ""
      and not path_under_root(client.root_dir, dest.path)
    then
      ui.notify(
        "cannot verify JUnit 5 on test classpath for module "
          .. tostring(target_lbl)
          .. " (selected jdtls client is rooted at another directory) — confirm carefully before writing",
        vim.log.levels.WARN
      )
      prepare_target_and_ask_name(dest, chosen_method, {
        status = "unverified",
        summary = "UNVERIFIED (target module " .. tostring(target_lbl) .. " outside jdtls client root)",
      })
      return
    end

    if not supports_command(client, ctx.bufnr, "java.project.getClasspaths") then
      local msg = is_other_module
          and ("cannot verify JUnit 5 on test classpath for module " .. tostring(target_lbl) .. " (jdtls client does not advertise java.project.getClasspaths) — confirm carefully before writing")
        or "cannot verify JUnit 5 on test classpath (jdtls client does not advertise java.project.getClasspaths) — confirm carefully before writing"
      ui.notify(msg, vim.log.levels.WARN)
      prepare_target_and_ask_name(dest, chosen_method, {
        status = "unverified",
        summary = is_other_module and ("UNVERIFIED (jdtls lacks java.project.getClasspaths for " .. tostring(
          target_lbl
        ) .. ")") or "UNVERIFIED (jdtls lacks java.project.getClasspaths)",
      })
      return
    end

    local query_uri = is_other_module and vim.uri_from_fname(dest.path)
      or vim.lsp.util.make_text_document_params(ctx.bufnr).uri

    if hierarchy.client_stopped(client) then
      ui.notify("jdtls client stopped during " .. skeleton_ctrl.feature_label, vim.log.levels.WARN)
      skeleton_ctrl:end_operation(op_token)
      return
    end
    local req_token = skeleton_ctrl:begin_request(op_token, client, ctx.bufnr, "verify JUnit 5 test classpath")
    if not req_token then
      return
    end

    local ok, req_id = client:request("workspace/executeCommand", {
      command = "java.project.getClasspaths",
      arguments = { query_uri, vim.fn.json_encode({ scope = "test" }) },
    }, function(err, cp_result)
      vim.schedule(function()
        if not skeleton_ctrl:is_request_current(op_token, req_token) then
          return
        end
        skeleton_ctrl:clear_pending(req_token)
        if hierarchy.client_stopped(client) then
          ui.notify("jdtls client stopped during " .. skeleton_ctrl.feature_label, vim.log.levels.WARN)
          skeleton_ctrl:end_operation(op_token)
          return
        end
        if abort_if_stale() then
          return
        end
        if err then
          if type(err) == "table" and err.code == hierarchy.REQUEST_CANCELLED_CODE then
            skeleton_ctrl:handle_request_error(err, "workspace/executeCommand")
            skeleton_ctrl:end_operation(op_token)
            return
          end
          if is_other_module then
            ui.notify(
              "could not verify JUnit 5 on test classpath for module "
                .. tostring(target_lbl)
                .. " — confirm carefully before writing",
              vim.log.levels.WARN
            )
            prepare_target_and_ask_name(dest, chosen_method, {
              status = "unverified",
              summary = "UNVERIFIED (could not query classpath for " .. tostring(target_lbl) .. ")",
            })
            return
          end
          skeleton_ctrl:handle_request_error(err, "workspace/executeCommand")
          skeleton_ctrl:end_operation(op_token)
          return
        end

        local info = inspect_junit5_classpath(cp_result, is_other_module and target_lbl or nil)
        if info.status == "invalid" then
          if is_other_module then
            ui.notify(
              "could not verify JUnit 5 on test classpath for module "
                .. tostring(target_lbl)
                .. " (unexpected java.project.getClasspaths response) — confirm carefully before writing",
              vim.log.levels.WARN
            )
            prepare_target_and_ask_name(dest, chosen_method, {
              status = "unverified",
              summary = "UNVERIFIED (unexpected classpath response for " .. tostring(target_lbl) .. ")",
            })
            return
          end
          ui.notify(
            "could not verify JUnit 5 on test classpath (unexpected java.project.getClasspaths response)",
            vim.log.levels.WARN
          )
          skeleton_ctrl:end_operation(op_token)
          return
        end
        if info.status == "missing" then
          local reason
          if info.saw_engine_only then
            reason = "JUnit 5 API (org.junit.jupiter.api.Test) was not found on the JDTLS test classpath for "
              .. tostring(target_lbl)
              .. " (junit-jupiter-engine alone does not provide the API) — add junit-jupiter-api to your build and sync JDTLS"
          elseif info.saw_junit4 then
            reason =
              "JUnit 5 (org.junit.jupiter.api.Test) is not on the JDTLS test classpath (only JUnit 3/4 found) — add junit-jupiter-api to your build and sync JDTLS"
          else
            reason = "JUnit 5 (org.junit.jupiter.api.Test) was not found on the JDTLS test classpath for "
              .. tostring(target_lbl)
              .. " — add junit-jupiter-api to your build file and sync JDTLS"
          end
          ui.notify(reason, vim.log.levels.WARN)
          skeleton_ctrl:end_operation(op_token)
          return
        end
        if info.status == "unverified" then
          ui.notify(info.summary .. " — confirm carefully before writing", vim.log.levels.WARN)
        end
        prepare_target_and_ask_name(dest, chosen_method, info)
      end)
    end, ctx.bufnr)

    if not skeleton_ctrl:attach_request_id(op_token, req_token, ok, req_id) then
      ui.notify("failed to send workspace/executeCommand request to jdtls", vim.log.levels.ERROR)
    end
  end

  local function resolve_destination(client, chosen_method)
    if abort_if_stale() then
      return
    end
    if nav.status == "match" then
      verify_target_classpath(client, {
        path = nav.target,
        class_name = nav.match.name,
        pkg = nav.pkg,
        module = nav.module,
        module_label = nav.module_label,
        is_new = false,
      }, chosen_method)
      return
    end

    if nav.status == "missing" then
      verify_target_classpath(client, {
        path = nav.default_target,
        class_name = nav.default_name,
        pkg = nav.pkg,
        module = nav.module,
        module_label = nav.module_label,
        is_new = true,
      }, chosen_method)
      return
    end

    if nav.status == "ambiguous" then
      local labels, by_label = {}, {}
      for _, m in ipairs(nav.matches) do
        local label = nav.multimodule and (m.module_label .. " · " .. m.fqn) or m.fqn
        labels[#labels + 1] = label
        by_label[label] = {
          path = m.path,
          class_name = m.name,
          pkg = nav.pkg,
          module = m.module,
          module_label = m.module_label,
          is_new = false,
        }
      end
      ui.pick_one(labels, "Java: Tests — select target test class", function(choice)
        if abort_if_stale() then
          return
        end
        local dest = by_label[choice]
        if not dest then
          skeleton_ctrl:end_operation(op_token)
          return
        end
        verify_target_classpath(client, dest, chosen_method)
      end)
      return
    end

    -- cross_module
    local labels, by_label = {}, {}
    for _, m in ipairs(nav.matches) do
      local label = "Use " .. m.module_label .. " · " .. m.fqn
      labels[#labels + 1] = label
      by_label[label] = {
        path = m.path,
        class_name = m.name,
        pkg = nav.pkg,
        module = m.module,
        module_label = m.module_label,
        is_new = false,
      }
    end
    local create_label = "Create " .. (nav.multimodule and (nav.module_label .. " · ") or "") .. nav.default_fqn
    labels[#labels + 1] = create_label
    by_label[create_label] = {
      path = nav.default_target,
      class_name = nav.default_name,
      pkg = nav.pkg,
      module = nav.module,
      module_label = nav.module_label,
      is_new = true,
    }
    ui.pick_one(labels, "Java: Tests — select destination test class", function(choice)
      if abort_if_stale() then
        return
      end
      local dest = by_label[choice]
      if not dest then
        skeleton_ctrl:end_operation(op_token)
        return
      end
      verify_target_classpath(client, dest, chosen_method)
    end)
  end

  local function select_method(client, methods)
    if abort_if_stale() then
      return
    end
    local ordered = {}
    for _, m in ipairs(methods) do
      if m.at_cursor then
        ordered[#ordered + 1] = m
      end
    end
    for _, m in ipairs(methods) do
      if not m.at_cursor then
        ordered[#ordered + 1] = m
      end
    end

    local labels, by_label, seen = {}, {}, {}
    for _, m in ipairs(ordered) do
      local base_label = method_display_label(m) .. (m.at_cursor and "  [at cursor]" or "")
      local label = hierarchy.unique_label(base_label, seen)
      labels[#labels + 1] = label
      by_label[label] = m
    end

    ui.pick_one(labels, "Java: Tests — select method", function(choice)
      if abort_if_stale() then
        return
      end
      local picked = by_label[choice]
      if not picked then
        skeleton_ctrl:end_operation(op_token)
        return
      end
      resolve_destination(client, picked)
    end)
  end

  skeleton_ctrl:select_client(op_token, ctx, {
    prompt = "Java: Tests — select JDTLS client",
    supports = supports_document_symbol,
    unsupported_reason = "does not support textDocument/documentSymbol",
    unsupported_tag = "[no documentSymbol]",
  }, function(client)
    local pos_params = hierarchy.build_position_params(ctx.bufnr, ctx.cursor, client)
    skeleton_ctrl:request(
      op_token,
      client,
      ctx.bufnr,
      "textDocument/documentSymbol",
      { textDocument = pos_params.textDocument },
      "list methods (documentSymbol)",
      ctx,
      function(resp)
        local methods = extract_methods_from_symbols(resp, pos_params.position)
        if #methods == 0 then
          ui.notify("no methods found in this Java file", vim.log.levels.WARN)
          skeleton_ctrl:end_operation(op_token)
          return
        end
        select_method(client, methods)
      end
    )
  end)
end

local function method_test_entry(bufnr, is_java, nav)
  local label = "Create JUnit 5 Test for Method…"
  if not is_java then
    return {
      key = "create_method_test",
      label = label,
      enabled = false,
      reason = "open a .java file",
    }
  end
  if not nav or not nav.resolvable then
    return {
      key = "create_method_test",
      label = label,
      enabled = false,
      reason = (nav and nav.reason) or "open a .java file under src/main/java",
    }
  end
  if nav.direction ~= "to_test" then
    return {
      key = "create_method_test",
      label = label,
      enabled = false,
      reason = "open a .java source file under src/main/java",
    }
  end
  local ready, reason = skeleton_ctrl:menu_availability(
    bufnr,
    supports_document_symbol,
    "jdtls client does not support textDocument/documentSymbol"
  )
  return {
    key = "create_method_test",
    label = label,
    enabled = ready,
    reason = reason,
  }
end

---Cancel the active test-skeleton LSP request/flow, if any.
---@return boolean cancelled
function M.cancel()
  return skeleton_ctrl:cancel(true)
end

---Create an explicitly pending/failing JUnit 5 test skeleton for a method
---selected from JDTLS `textDocument/documentSymbol`.
function M.create_method_test()
  local ctx = hierarchy.capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end
  if vim.bo[ctx.bufnr].buftype ~= "" or vim.bo[ctx.bufnr].filetype ~= "java" then
    ui.notify("open a .java file under src/main/java", vim.log.levels.WARN)
    return
  end
  local root = ctx.project_root
  if not root then
    ui.notify("no Maven/Gradle project (pom.xml, build.gradle) from this buffer", vim.log.levels.WARN)
    return
  end
  local nav = resolve_counterpart(ctx.bufnr, root)
  if not nav.resolvable or nav.direction ~= "to_test" then
    ui.notify(
      (not nav.resolvable and nav.reason) or "open a .java source file under src/main/java",
      vim.log.levels.WARN
    )
    return
  end
  run_method_test_flow(ctx, nav)
end

local function collect_jc_adapters(client, nt, root, target_mod, mods)
  local seen, raw_ids = {}, {}
  local discovery_failed = false
  local adapter_objs = nil
  if client._adapters ~= nil then
    if type(client._adapters) == "table" then
      adapter_objs = client._adapters
    else
      discovery_failed = true
    end
  end
  local had_source = adapter_objs ~= nil

  if adapter_objs then
    for id, obj in pairs(adapter_objs) do
      if type(id) ~= "string" or (obj ~= nil and type(obj) ~= "table") then
        discovery_failed = true
      elseif not seen[id] then
        seen[id] = true
        raw_ids[#raw_ids + 1] = id
      end
    end
  end

  if #raw_ids == 0 and nt and nt.state and type(nt.state.adapter_ids) == "function" then
    had_source = true
    local ok, list = pcall(nt.state.adapter_ids)
    if not ok or type(list) ~= "table" then
      discovery_failed = true
    else
      for _, id in ipairs(list) do
        if type(id) ~= "string" then
          discovery_failed = true
        elseif not seen[id] then
          seen[id] = true
          raw_ids[#raw_ids + 1] = id
        end
      end
    end
  end

  local matching = {}
  for _, id in ipairs(raw_ids) do
    local obj = adapter_objs and adapter_objs[id] or nil
    if is_jc_adapter_for_scope(id, obj, root, target_mod, mods) then
      matching[#matching + 1] = id
    end
  end
  table.sort(matching)
  return matching, had_source, discovery_failed
end

local function adapter_tree(client, adapter_id, nt)
  local saw_error = false
  local saw_invalid = false

  if client._state and type(client._state.positions) == "function" then
    local ok, tree = pcall(client._state.positions, client._state, adapter_id)
    if not ok then
      saw_error = true
    elseif tree ~= nil then
      if type(tree) == "table" and type(tree.iter_nodes) == "function" then
        return tree, nil
      end
      saw_invalid = true
    end
  end
  if nt and nt.state and type(nt.state.positions) == "function" then
    local ok, tree = pcall(nt.state.positions, adapter_id)
    if not ok then
      saw_error = true
    elseif tree ~= nil then
      if type(tree) == "table" and type(tree.iter_nodes) == "function" then
        return tree, nil
      end
      saw_invalid = true
    end
  end
  if client._started ~= false and type(client.get_position) == "function" then
    local ok, tree = pcall(client.get_position, client, nil, { adapter = adapter_id })
    if not ok then
      saw_error = true
    elseif tree ~= nil then
      if type(tree) == "table" and type(tree.iter_nodes) == "function" then
        return tree, nil
      end
      saw_invalid = true
    end
  end
  if saw_error or saw_invalid then
    return nil, "position_tree_read_failed"
  end
  return nil, "missing_position_tree"
end

local function has_valid_failure_errors(errors)
  if type(errors) ~= "table" or #errors == 0 then
    return false
  end
  local count = 0
  for k, e in pairs(errors) do
    if type(k) ~= "number" or k < 1 or k > #errors or math.floor(k) ~= k or type(e) ~= "table" then
      return false
    end
    local has_msg = type(e.message) == "string" and e.message ~= ""
    local has_line = type(e.line) == "number"
    if not has_msg and not has_line then
      return false
    end
    count = count + 1
  end
  return count > 0
end

local function is_synthetic_failure(res)
  if type(res) ~= "table" or res.status ~= "failed" then
    return false
  end
  -- jc.neotest only attaches a non-empty `errors` array when a JUnit XML
  -- <testcase> failure/error was parsed; no-report `runner_failed` leaves
  -- `errors == nil` and neotest's missing-position fill sets `errors = {}`.
  return not has_valid_failure_errors(res.errors)
end

local function classify_result(res)
  if res == nil then
    return "unrun", nil
  end
  if type(res) ~= "table" then
    return "invalid", "invalid_test_result"
  end
  if res.status == "passed" then
    return "passed", nil
  end
  if res.status == "skipped" then
    return "skipped", nil
  end
  if res.status == "failed" then
    if res.errors ~= nil and type(res.errors) ~= "table" then
      return "synthetic_failed", "invalid_test_result"
    end
    if type(res.errors) == "table" and #res.errors > 0 and not has_valid_failure_errors(res.errors) then
      return "synthetic_failed", "invalid_test_result"
    end
    if is_synthetic_failure(res) then
      return "synthetic_failed", "no_report_or_runner_failure"
    end
    return "verified_failed", nil
  end
  return "unknown_status", "unknown_result_status"
end

---Inspect neotest/jc results isolated to a single project and (optionally)
---module, separating verified JUnit XML failures from synthetic no-report /
---runner failures. Never modifies or monkey-patches jc.nvim.
---@param opts table|nil { bufnr?, root?, module?, client?, jdtls_count?, nt? }
---@return table report
function M.inspect_results(opts)
  opts = opts or {}
  local bufnr = opts.bufnr and opts.bufnr > 0 and opts.bufnr or context_buf()
  local root = canonical(opts.root or project.root(bufnr))
  local counts = {
    total = 0,
    passed = 0,
    verified_failed = 0,
    synthetic_failed = 0,
    skipped = 0,
    unrun = 0,
  }
  local reasons, seen_reasons = {}, {}
  local function add_reason(r)
    if r and not seen_reasons[r] then
      seen_reasons[r] = true
      reasons[#reasons + 1] = r
    end
  end

  if not root then
    add_reason("no_project")
    return {
      root = nil,
      module = nil,
      reliable = false,
      reasons = reasons,
      counts = counts,
      passed_ids = {},
      verified_failed_ids = {},
      synthetic_failed_ids = {},
      skipped_ids = {},
      unrun_ids = {},
      rerun_failed_supported = false,
    }
  end

  local mods = canonical_modules(root)
  local mods_set = canonical_modules_set(root, mods)
  local target_mod
  if opts.module then
    local cm = canonical(opts.module)
    if not cm or not subtree(root, cm) or (cm ~= root and not mods_set[cm]) then
      add_reason("invalid_module_scope")
    elseif cm ~= root and #mods > 1 then
      target_mod = cm
    end
  elseif not opts.root and vim.api.nvim_buf_is_valid(bufnr) then
    local bpath = vim.api.nvim_buf_get_name(bufnr)
    local m = bpath ~= "" and owning_module(bpath, mods) or nil
    if m and m ~= root and #mods > 1 then
      target_mod = m
    end
  end

  local jdtls_count = opts.jdtls_count ~= nil and opts.jdtls_count or lsp.global_count()
  if jdtls_count > 1 then
    add_reason("ambiguous_jdtls_clients")
  end

  local client = opts.client
  if client == nil then
    local ok_c, cons = pcall(require, "jc.neotest.consumer")
    client = (ok_c and type(cons) == "table") and cons.client or nil
  end
  if not client or type(client.get_results) ~= "function" then
    add_reason("no_consumer_client")
    return {
      root = root,
      module = target_mod,
      reliable = false,
      reasons = reasons,
      counts = counts,
      passed_ids = {},
      verified_failed_ids = {},
      synthetic_failed_ids = {},
      skipped_ids = {},
      unrun_ids = {},
      rerun_failed_supported = false,
    }
  end

  local nt = opts.nt ~= nil and opts.nt or neotest()
  if client._started ~= true then
    add_reason("client_not_started")
  end
  local adapter_ids, had_adapter_source, adapter_discovery_failed =
    collect_jc_adapters(client, nt, root, target_mod, mods)
  if adapter_discovery_failed then
    add_reason("adapter_discovery_failed")
  elseif not had_adapter_source or #adapter_ids == 0 then
    add_reason("no_jc_adapter")
  end

  local pos_by_id = {}
  for _, adapter_id in ipairs(adapter_ids) do
    local tree, tree_err = adapter_tree(client, adapter_id, nt)
    if not tree then
      add_reason(tree_err or "missing_position_tree")
    else
      local ok_res, results_map = pcall(client.get_results, client, adapter_id)
      if not ok_res or type(results_map) ~= "table" then
        add_reason("results_read_failed")
        results_map = {}
      end
      local ok_iter = pcall(function()
        for _, node in tree:iter_nodes() do
          if type(node) ~= "table" then
            add_reason("invalid_position_node")
          else
            local ok_d, d
            if type(node.data) == "function" then
              ok_d, d = pcall(node.data, node)
            elseif node.data == nil then
              ok_d, d = true, node
            else
              ok_d, d = false, nil
            end
            if not ok_d then
              add_reason("position_tree_read_failed")
            elseif type(d) ~= "table" or type(d.type) ~= "string" or d.type == "" then
              add_reason("invalid_position_node")
            elseif d.type == "test" then
              local valid_id = type(d.id) == "string" and vim.trim(d.id) ~= ""
              local valid_path = type(d.path) == "string" and vim.trim(d.path) ~= ""
              local cpath = valid_path and canonical(d.path) or nil
              if not valid_id or not valid_path or not cpath then
                add_reason("invalid_test_position")
              elseif subtree(root, cpath) and not has_nested_project_boundary(cpath, root, mods_set) then
                local pos_mod = owning_module(cpath, mods) or root
                if not target_mod or pos_mod == target_mod then
                  local res = results_map[d.id]
                  local kind, r_reason = classify_result(res)
                  if r_reason then
                    add_reason(r_reason)
                  end
                  local prev = pos_by_id[d.id]
                  if prev and prev.res ~= nil and res ~= nil then
                    if prev.kind ~= kind then
                      add_reason("conflicting_adapter_results")
                    elseif prev.adapter_id ~= adapter_id then
                      add_reason("ambiguous_adapter_results")
                    end
                  end
                  if not prev or (prev.res == nil and res ~= nil) then
                    pos_by_id[d.id] = {
                      id = d.id,
                      path = cpath,
                      module = pos_mod,
                      adapter_id = adapter_id,
                      res = res,
                      kind = kind,
                    }
                  end
                end
              end
            elseif d.type == "dir" or d.type == "file" or d.type == "namespace" then
              if
                (d.id ~= nil and (type(d.id) ~= "string" or vim.trim(d.id) == ""))
                or (d.path ~= nil and (type(d.path) ~= "string" or vim.trim(d.path) == ""))
              then
                add_reason("invalid_position_node")
              end
            else
              add_reason("invalid_position_node")
            end
          end
        end
      end)
      if not ok_iter then
        add_reason("position_tree_read_failed")
      end
    end
  end

  local sorted_ids = {}
  for id in pairs(pos_by_id) do
    sorted_ids[#sorted_ids + 1] = id
  end
  table.sort(sorted_ids)

  local passed_ids, verified_failed_ids, synthetic_failed_ids, skipped_ids, unrun_ids = {}, {}, {}, {}, {}
  for _, id in ipairs(sorted_ids) do
    counts.total = counts.total + 1
    local entry = pos_by_id[id]
    local kind = entry.kind
    if kind == "passed" then
      counts.passed = counts.passed + 1
      passed_ids[#passed_ids + 1] = id
    elseif kind == "skipped" then
      counts.skipped = counts.skipped + 1
      skipped_ids[#skipped_ids + 1] = id
    elseif kind == "verified_failed" then
      counts.verified_failed = counts.verified_failed + 1
      verified_failed_ids[#verified_failed_ids + 1] = id
    elseif kind == "synthetic_failed" then
      counts.synthetic_failed = counts.synthetic_failed + 1
      synthetic_failed_ids[#synthetic_failed_ids + 1] = id
    else
      counts.unrun = counts.unrun + 1
      unrun_ids[#unrun_ids + 1] = id
    end
  end

  if counts.synthetic_failed > 0 then
    add_reason("no_report_or_runner_failure")
  end

  return {
    root = root,
    module = target_mod,
    reliable = #reasons == 0,
    reasons = reasons,
    counts = counts,
    passed_ids = passed_ids,
    verified_failed_ids = verified_failed_ids,
    synthetic_failed_ids = synthetic_failed_ids,
    skipped_ids = skipped_ids,
    unrun_ids = unrun_ids,
    rerun_failed_supported = false,
  }
end

---Entry point of `<leader>jt`.
function M.tests()
  local cur = vim.api.nvim_get_current_buf()
  local ctx_buf = context_buf()
  if vim.bo[ctx_buf].buftype ~= "" then
    ui.notify("open a project file before using the Tests menu", vim.log.levels.WARN)
    return
  end
  local root = project.root(ctx_buf)
  if not root then
    ui.notify("no Maven/Gradle project (pom.xml, build.gradle) from this buffer", vim.log.levels.WARN)
    return
  end

  local nt = neotest()
  local jc = jc_test()
  local attached = ui.jdtls_attached(ctx_buf)
  local is_java = vim.bo[cur].buftype == "" and vim.bo[cur].filetype == "java"
  local croot = canonical(root) or root
  local mods = canonical_modules(root)
  local multimodule = #mods > 1
  local ctx_path = is_java and vim.api.nvim_buf_get_name(cur) or vim.api.nvim_buf_get_name(ctx_buf)
  local cur_mod = ctx_path ~= "" and owning_module(ctx_path, mods) or nil
  local mod_desc = cur_mod and module_label(root, cur_mod) or vim.fs.basename(root)
  local suite_dir, suite_valid = suite_target_dir(ctx_path, root, cur)
  local suite_desc = (suite_dir and suite_dir ~= croot) and ("module: " .. module_label(root, suite_dir))
    or "all modules"
  local nav = is_java and resolve_counterpart(cur, root) or nil
  local ctx = hierarchy.capture_context()
  local opened_seq = skeleton_ctrl:seq()
  local pending = skeleton_ctrl:pending()
  local opened_pending_token = pending and pending.token or nil

  if is_java and vim.bo[cur].modified then
    ui.notify(
      "this buffer has unsaved changes: test discovery reads the file from disk, so new test names may not appear until you save",
      vim.log.levels.WARN
    )
  end

  if nt then
    local ok_rep, rep = pcall(M.inspect_results, { bufnr = cur, root = root, module = cur_mod })
    if ok_rep and rep and rep.counts and rep.counts.synthetic_failed > 0 then
      ui.notify(
        ("neotest/jc marked %d test(s) failed in %s without a JUnit XML report (build/classpath/runner failure, not per-test failures) — check Show Test Output"):format(
          rep.counts.synthetic_failed,
          mod_desc
        ),
        vim.log.levels.WARN
      )
    end
  end

  local no_neotest = "neotest is not installed"
  local no_jdtls = "jdtls is not attached (test classpath comes from jdtls)"
  local no_jc = "jc.nvim is not loaded"

  local function run_reason()
    if not nt then
      return no_neotest
    end
    if not jc then
      return no_jc
    end
    if not attached then
      return no_jdtls
    end
    local jc_guard = lsp.jc_global_reason("Tests")
    if jc_guard then
      return jc_guard
    end
  end

  local precompile = false
  local ok_jc, jc_mod = pcall(require, "jc")
  if ok_jc and jc_mod.config and jc_mod.config.test then
    precompile = jc_mod.config.test.precompile == true
  end

  local run_enabled = run_reason() == nil
  local java_reason = run_reason() or "open a .java file"
  local last_state = last_run_state(root, cur_mod, mods, nt)

  local by_key = {
    nearest = {
      key = "nearest",
      label = "Run Nearest Test",
      enabled = run_enabled and is_java,
      reason = java_reason,
    },
    file = {
      key = "file",
      label = "Run Test File",
      enabled = run_enabled and is_java,
      reason = java_reason,
    },
    suite = {
      key = "suite",
      label = "Run Test Suite"
        .. ((multimodule or (suite_dir and suite_dir ~= croot)) and ("  (" .. suite_desc .. ")") or ""),
      enabled = run_enabled and suite_valid,
      reason = (not run_enabled and run_reason())
        or (not suite_valid and "jc.test.run_all target resolves outside this project")
        or nil,
    },
    pick = {
      key = "pick",
      label = "Pick Test…",
      enabled = run_enabled,
      reason = run_reason(),
    },
    last = {
      key = "last",
      label = "Repeat Last Test" .. (last_state.detail and ("  (" .. last_state.detail .. ")") or ""),
      enabled = run_enabled and last_state.available,
      reason = (not run_enabled and run_reason()) or last_state.reason,
    },
    stop = {
      key = "stop",
      label = "Stop Running Test",
      enabled = nt ~= nil,
      reason = no_neotest,
    },
    summary = {
      key = "summary",
      label = "Show Test Summary",
      enabled = nt ~= nil,
      reason = no_neotest,
    },
    output = {
      key = "output",
      label = "Show Test Output",
      enabled = nt ~= nil,
      reason = no_neotest,
    },
    precompile = {
      key = "precompile",
      label = "Toggle Precompile (current: " .. (precompile and "ON — maven/gradle" or "OFF — jdtls only") .. ")",
      enabled = jc ~= nil,
      reason = no_jc,
    },
    goto_test = goto_entry(is_java, nav),
    create_method_test = method_test_entry(cur, is_java, nav),
  }

  local order
  if not is_java then
    order = {
      "suite",
      "pick",
      "last",
      "stop",
      "summary",
      "output",
      "precompile",
      "nearest",
      "file",
      "goto_test",
      "create_method_test",
    }
  elseif not run_enabled and by_key.goto_test.enabled then
    order = {
      "goto_test",
      "create_method_test",
      "nearest",
      "file",
      "suite",
      "pick",
      "last",
      "stop",
      "summary",
      "output",
      "precompile",
    }
  else
    order = {
      "nearest",
      "file",
      "goto_test",
      "create_method_test",
      "suite",
      "pick",
      "last",
      "stop",
      "summary",
      "output",
      "precompile",
    }
  end

  local entries = {}
  if pending then
    entries[#entries + 1] = {
      key = "cancel",
      label = "Cancel active request (" .. pending.label .. ")",
      enabled = true,
    }
  end
  for _, key in ipairs(order) do
    entries[#entries + 1] = by_key[key]
  end

  local prompt = multimodule and cur_mod and ("Java: Tests — " .. mod_desc)
    or ("Java: Tests — " .. vim.fs.basename(root))

  ui.menu(entries, prompt, function(entry)
    if entry.key == "cancel" then
      if skeleton_ctrl:seq() ~= opened_seq then
        return
      end
      local cur_pending = skeleton_ctrl:pending()
      if cur_pending and cur_pending.token == opened_pending_token then
        M.cancel()
      end
      return
    end
    -- runs use jc/neotest classpath/commands, which resolve the client
    -- globally; stop/summary/output/goto_test/create_method_test do not
    local run_keys = { nearest = true, file = true, suite = true, pick = true, last = true }
    if run_keys[entry.key] then
      local jc_guard = lsp.jc_global_reason("Tests")
      if jc_guard then
        ui.notify(jc_guard, vim.log.levels.WARN)
        return
      end
    end
    if entry.key == "nearest" then
      if not ui.same_buffer(cur) then
        return
      end
      run_contextual(cur, root, false)
    elseif entry.key == "file" then
      if not ui.same_buffer(cur) then
        return
      end
      run_contextual(cur, root, true)
    elseif entry.key == "suite" then
      run_suite(cur, root, suite_dir, multimodule, cur_mod)
    elseif entry.key == "pick" then
      pick_test(root, is_java and cur or ctx_buf)
    elseif entry.key == "last" then
      repeat_last(cur, root, cur_mod, mods, nt)
    elseif entry.key == "stop" then
      if vim.api.nvim_buf_is_valid(cur) then
        vim.api.nvim_buf_call(cur, jc.stop)
      else
        jc.stop()
      end
    elseif entry.key == "summary" then
      jc.summary()
    elseif entry.key == "output" then
      if vim.api.nvim_buf_is_valid(cur) then
        vim.api.nvim_buf_call(cur, jc.output)
      else
        jc.output()
      end
    elseif entry.key == "precompile" then
      jc.toggle_precompile()
    elseif entry.key == "goto_test" then
      goto_counterpart(cur, root)
    elseif entry.key == "create_method_test" then
      if skeleton_ctrl:seq() ~= opened_seq then
        return
      end
      if not skeleton_ctrl:context_still_valid(ctx, true, true) then
        return
      end
      run_method_test_flow(ctx, nav)
    end
  end)
end

-- exposed for tests
M._test_files = test_files
M._run_file = run_file
M._run_contextual = run_contextual
M._resolve_counterpart = resolve_counterpart
M._goto_counterpart = goto_counterpart
M._owning_module = owning_module
M._extract_methods_from_symbols = extract_methods_from_symbols
M._default_test_method_name = default_test_method_name
M._analyze_test_file = analyze_test_file
M._plan_existing_test_edit = plan_existing_test_edit
M._render_junit5_for_method = render_junit5_for_method
M._inspect_junit5_classpath = inspect_junit5_classpath
M._is_synthetic_failure = is_synthetic_failure
M._pos_belongs_to_scope = pos_belongs_to_scope
M._effective_jc_suite_target = effective_jc_suite_target
M._resolve_suite_replay_path = resolve_suite_replay_path
M._reset = function()
  skeleton_ctrl:reset()
  last_runs = {}
  run_seq = 0
end

return M
