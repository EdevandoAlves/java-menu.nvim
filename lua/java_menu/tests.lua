-- java_menu/tests.lua
-- <leader>jt: JUnit tests via neotest + jc.nvim adapter and bidirectional
-- class <-> test navigation.
-- No custom runner: test execution delegates to jc public APIs (jc.test.*)
-- and neotest; classpath and JDK continue to come from jdtls.

local ui = require("java_menu.ui")
local project = require("java_menu.project")
local lsp = require("java_menu.lsp")
local jca = require("java_menu.jc")

local M = {}

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

---Run a test file through neotest using the jc adapter.
local function run_file(path)
  local jc = jc_test()
  if not jc or type(jc.run_file) ~= "function" then
    ui.notify("jc test runner is not available", vim.log.levels.ERROR)
    return
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local ok, err = pcall(vim.api.nvim_buf_call, buf, jc.run_file)
  if not ok then
    ui.notify("could not run test: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function pick_and_run_matches(matches, prompt)
  local labels, by_label = {}, {}
  for _, m in ipairs(matches) do
    local label = m.module_label .. " · " .. m.fqn
    labels[#labels + 1] = label
    by_label[label] = m.path
  end
  ui.pick_one(labels, prompt, function(choice)
    if by_label[choice] then
      run_file(by_label[choice])
    end
  end)
end

---Run Nearest (or Test File when `file_only` is true), honoring module-aware
---counterparts (*Test, *Tests, *IT, Test*) and Snacks package-test fallback.
local function run_contextual(bufnr, root, file_only)
  local jc = jc_test()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local nav = resolve_counterpart(bufnr, root)

  if nav.resolvable and nav.direction == "to_test" then
    if nav.status == "match" then
      local ok_cg, cg = pcall(require, "jc.class_generator")
      local jc_target
      if ok_cg and type(cg.test_counterpart) == "function" then
        local ok_tc, target_path = pcall(cg.test_counterpart, path)
        if ok_tc then
          jc_target = canonical(target_path)
        end
      end
      if jc_target == nav.target and jc then
        local fn = file_only and jc.run_file or jc.run_at_cursor
        if type(fn) == "function" then
          fn()
          return
        end
      end
      run_file(nav.target)
      return
    end

    if nav.status == "ambiguous" then
      pick_and_run_matches(nav.matches, "Java: Tests — multiple paired tests")
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
          run_file(by_label[choice])
        end
      end)
      return
    end

    if nav.status == "cross_module" then
      pick_and_run_matches(nav.matches, "Java: Tests — run from another module")
      return
    end
  end

  if jc then
    local fn = file_only and jc.run_file or jc.run_at_cursor
    if type(fn) == "function" then
      fn()
    end
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
      run_file(item.path)
    end
  end)
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
  local mods = project.modules(root)
  local multimodule = #mods > 1
  local ctx_path = is_java and vim.api.nvim_buf_get_name(cur) or vim.api.nvim_buf_get_name(ctx_buf)
  local cur_mod = ctx_path ~= "" and owning_module(ctx_path, mods) or nil
  local mod_desc = cur_mod and module_label(root, cur_mod) or vim.fs.basename(root)
  local nav = is_java and resolve_counterpart(cur, root) or nil

  if is_java and vim.bo[cur].modified then
    ui.notify(
      "this buffer has unsaved changes: test discovery reads the file from disk, so new test names may not appear until you save",
      vim.log.levels.WARN
    )
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
  end

  local precompile = false
  local ok_jc, jc_mod = pcall(require, "jc")
  if ok_jc and jc_mod.config and jc_mod.config.test then
    precompile = jc_mod.config.test.precompile == true
  end

  local run_enabled = run_reason() == nil
  local java_reason = run_reason() or "open a .java file"

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
      label = "Run Test Suite" .. (multimodule and ("  (module: " .. mod_desc .. ")") or ""),
      enabled = run_enabled,
      reason = run_reason(),
    },
    pick = {
      key = "pick",
      label = "Pick Test…",
      enabled = run_enabled,
      reason = run_reason(),
    },
    last = {
      key = "last",
      label = "Repeat Last Test",
      enabled = run_enabled,
      reason = run_reason(),
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
  }

  local order
  if not is_java then
    order = { "suite", "pick", "last", "stop", "summary", "output", "precompile", "nearest", "file", "goto_test" }
  elseif not run_enabled and by_key.goto_test.enabled then
    order = { "goto_test", "nearest", "file", "suite", "pick", "last", "stop", "summary", "output", "precompile" }
  else
    order = { "nearest", "file", "goto_test", "suite", "pick", "last", "stop", "summary", "output", "precompile" }
  end

  local entries = {}
  for _, key in ipairs(order) do
    entries[#entries + 1] = by_key[key]
  end

  local prompt = multimodule and cur_mod and ("Java: Tests — " .. mod_desc)
    or ("Java: Tests — " .. vim.fs.basename(root))

  ui.menu(entries, prompt, function(entry)
    -- runs use jc/neotest classpath/commands, which resolve the client
    -- globally; stop/summary/output/goto_test do not start a client request
    local run_keys = { nearest = true, file = true, suite = true, pick = true, last = true }
    if run_keys[entry.key] then
      local jc_guard = lsp.jc_global_reason("Tests")
      if jc_guard then
        ui.notify(jc_guard, vim.log.levels.WARN)
        return
      end
    end
    if entry.key == "nearest" then
      run_contextual(cur, root, false)
    elseif entry.key == "file" then
      run_contextual(cur, root, true)
    elseif entry.key == "suite" then
      if multimodule then
        ui.notify(
          "multi-module suite: jc/neotest roots at the current module — use Pick Test or Run Test File for other modules",
          vim.log.levels.WARN
        )
      end
      jc.run_all()
    elseif entry.key == "pick" then
      pick_test(root, is_java and cur or ctx_buf)
    elseif entry.key == "last" then
      jc.run_last()
    elseif entry.key == "stop" then
      jc.stop()
    elseif entry.key == "summary" then
      jc.summary()
    elseif entry.key == "output" then
      jc.output()
    elseif entry.key == "precompile" then
      jc.toggle_precompile()
    elseif entry.key == "goto_test" then
      goto_counterpart(cur, root)
    end
  end)
end

-- exposed for tests
M._test_files = test_files
M._run_file = run_file
M._resolve_counterpart = resolve_counterpart
M._goto_counterpart = goto_counterpart
M._owning_module = owning_module

return M
