-- java_menu/tests.lua
-- <leader>jt: testes JUnit via neotest + adaptador do jc.nvim.
-- No custom runner: operations delegate to jc public APIs
-- (jc.test.*) e do neotest; o classpath/JDK continuam vindo do jdtls.

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

---Approximate FQN of a test file (src/test/java/<pkg>/X.java).
local function test_fqn(path)
  return path:gsub(".*[/\\]src[/\\]test[/\\]java[/\\]", ""):gsub("%.java$", ""):gsub("[/\\]", ".")
end

---Project test files (src/test/java), with approximate FQNs.
local function test_files(root)
  local files = vim.fn.glob(root .. "/**/src/test/java/**/*.java", true, true)
  local out = {}
  for _, path in ipairs(files) do
    out[#out + 1] = { label = test_fqn(path), path = path }
  end
  table.sort(out, function(a, b)
    return a.label < b.label
  end)
  return out
end

---Run a test file through neotest using the jc adapter.
local function run_file(path)
  local nt = neotest()
  if not nt then
    ui.notify("neotest is not available", vim.log.levels.ERROR)
    return
  end
  local ok_target, target = pcall(require, "jc.neotest.target")
  local args = ok_target and target.run_args(path, path) or path
  nt.run.run(args)
  pcall(function()
    nt.summary.open()
  end)
end

---Run Nearest; without a paired test, offers the package tests through Snacks
---(jc's internal fallback used vim.ui.select).
local function run_nearest()
  local jc = jc_test()
  local path = vim.fn.expand("%:p")
  local ok_cg, cg = pcall(require, "jc.class_generator")

  local counterpart
  if ok_cg and type(cg.test_counterpart) == "function" then
    local ok, result = pcall(cg.test_counterpart, path)
    counterpart = ok and result or nil
  end

  if counterpart and vim.fn.filereadable(counterpart) == 0 and jc then
    local api, api_err = jca.test_discovery_api()
    if api then
      local nothing, nothing_err = api.nothing_to_run(path)
      local package_tests, package_err = api.package_tests(path)
      if nothing_err or package_err then
        ui.notify(nothing_err or package_err, vim.log.levels.WARN)
      end
      if nothing and package_tests and #package_tests > 0 then
        local labels, by_label = {}, {}
        for _, file in ipairs(package_tests) do
          local label = test_fqn(file)
          labels[#labels + 1] = label
          by_label[label] = file
        end
        ui.pick_one(labels, "Java: Tests — no paired test (run from package)", function(choice)
          local file = by_label[choice]
          if file then
            run_file(file)
          end
        end)
        return
      end
    elseif api_err then
      -- jc version without discovery internals: continue to run_at_cursor
      ui.notify(api_err, vim.log.levels.WARN)
    end
  end

  if jc and type(jc.run_at_cursor) == "function" then
    jc.run_at_cursor()
  end
end

local function pick_test(root)
  local items = test_files(root)
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

---Entry point of `<leader>jt`.
function M.tests()
  local bufnr = vim.api.nvim_get_current_buf()
  local root = project.root(bufnr)
  if not root then
    ui.notify("no Maven/Gradle project (pom.xml, build.gradle) from this buffer", vim.log.levels.WARN)
    return
  end

  local nt = neotest()
  local jc = jc_test()
  local attached = ui.jdtls_attached(bufnr)
  local is_java = vim.bo[bufnr].filetype == "java"
  local multimodule = #project.modules(root) > 1

  if is_java and vim.bo[bufnr].modified then
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

  local goto_test_available = false
  do
    local ok, cg = pcall(require, "jc.class_generator")
    goto_test_available = ok and type(cg.goto_test) == "function"
  end

  local run_enabled = run_reason() == nil

  local entries = {
    {
      key = "nearest",
      label = "Run Nearest Test",
      enabled = run_enabled and is_java,
      reason = run_reason() or "open a test .java file",
    },
    {
      key = "file",
      label = "Run Test File",
      enabled = run_enabled and is_java,
      reason = run_reason() or "open a .java file",
    },
    {
      key = "suite",
      label = "Run Test Suite" .. (multimodule and "  (multi-module: roots at the current module)" or ""),
      enabled = run_enabled,
      reason = run_reason(),
    },
    {
      key = "pick",
      label = "Pick Test…",
      enabled = run_enabled,
      reason = run_reason(),
    },
    {
      key = "last",
      label = "Repeat Last Test",
      enabled = run_enabled,
      reason = run_reason(),
    },
    {
      key = "stop",
      label = "Stop Running Test",
      enabled = nt ~= nil,
      reason = no_neotest,
    },
    {
      key = "summary",
      label = "Show Test Summary",
      enabled = nt ~= nil,
      reason = no_neotest,
    },
    {
      key = "output",
      label = "Show Test Output",
      enabled = nt ~= nil,
      reason = no_neotest,
    },
    {
      key = "precompile",
      label = "Toggle Precompile (current: " .. (precompile and "ON — maven/gradle" or "OFF — jdtls only") .. ")",
      enabled = jc ~= nil,
      reason = no_jc,
    },
    {
      key = "goto_test",
      label = "Go to Test",
      enabled = goto_test_available and is_java,
      reason = (not goto_test_available and "jc API unavailable") or "open a .java file",
    },
  }

  ui.menu(entries, "Java: Tests", function(entry)
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
      run_nearest()
    elseif entry.key == "file" then
      jc.run_file()
    elseif entry.key == "suite" then
      if multimodule then
        ui.notify(
          "multi-module suite: jc/neotest roots at the current module — use Pick Test or Run Test File for other modules",
          vim.log.levels.WARN
        )
      end
      jc.run_all()
    elseif entry.key == "pick" then
      pick_test(root)
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
      require("jc.class_generator").goto_test()
    end
  end)
end

-- exposed for tests
M._test_files = test_files
M._run_file = run_file

return M
