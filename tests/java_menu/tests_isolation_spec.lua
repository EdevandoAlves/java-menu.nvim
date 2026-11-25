-- Reliability and project/module isolation for java_menu.tests:
--   1. Per-(project, module) Repeat Last Test isolation (including same-basename projects)
--   2. Multi-client JDTLS blocking in menu availability and _run_file
--   3. Buffer-drift protection for Run Nearest / Run Test File
--   4. Accurate Maven vs Gradle multi-module suite scope labels & warnings
--   5. Result reliability inspection (verified JUnit XML failures vs synthetic
--      no-report / neotest missing-position failures) and strict module isolation

local tests_mod = require("java_menu.tests")
local fixtures = require("tests.java_menu.fixtures")
local report = require("jc.neotest.report")

local real_notify = vim.notify
local real_select = vim.ui.select
local real_get_clients = vim.lsp.get_clients

local notices = {}
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = tostring(msg), level = level }
end
local function clear_notices()
  notices = {}
end
local function has_notice(needle)
  for _, n in ipairs(notices) do
    if n.msg:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local captured_select = {}
local function stub_select(chooser)
  vim.ui.select = function(items, opts, on_choice)
    captured_select[#captured_select + 1] = {
      items = vim.deepcopy(items),
      prompt = opts and opts.prompt or "",
    }
    local choice = type(chooser) == "function" and chooser(items, opts) or chooser
    if choice ~= nil then
      on_choice(choice)
    end
  end
end

local function find_item(items, needle)
  for _, item in ipairs(items or {}) do
    if item:find(needle, 1, true) then
      return item
    end
  end
  return nil
end

local function open_java_buf(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "java"
  return buf
end

local function canonical(path)
  local norm = vim.fs.normalize(path)
  return vim.fs.normalize(vim.uv.fs_realpath(norm) or norm)
end

local temp_dirs = {}
local function track(dir)
  temp_dirs[#temp_dirs + 1] = dir
  return dir
end

-- Helper: build a synthetic neotest.Tree-compatible object for inspect_results tests
local function make_tree(root_path, test_nodes)
  local nodes = {
    {
      data = function()
        return { id = root_path, type = "dir", path = root_path }
      end,
    },
  }
  for _, t in ipairs(test_nodes) do
    nodes[#nodes + 1] = {
      data = function()
        return { id = t.id, type = "test", path = t.path, name = t.name }
      end,
    }
  end
  return {
    iter_nodes = function()
      local i = 0
      return function()
        i = i + 1
        if nodes[i] then
          return i, nodes[i]
        end
      end
    end,
  }
end

local function make_mm_maven(base_name)
  local base = track(vim.fs.normalize(vim.fn.tempname() .. "/" .. base_name))
  local root = base .. "/my-app"
  fixtures.write(root .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.iso</groupId>",
    "  <artifactId>my-app</artifactId>",
    "  <version>1.0</version>",
    "  <packaging>pom</packaging>",
    "  <modules>",
    "    <module>a</module>",
    "    <module>b</module>",
    "  </modules>",
    "</project>",
  })
  for _, m in ipairs({ "a", "b" }) do
    fixtures.write(root .. "/" .. m .. "/pom.xml", {
      '<project xmlns="http://maven.apache.org/POM/4.0.0">',
      "  <modelVersion>4.0.0</modelVersion>",
      "  <groupId>com.iso</groupId>",
      "  <artifactId>" .. m .. "</artifactId>",
      "  <version>1.0</version>",
      "</project>",
    })
  end
  local test_a = root .. "/a/src/test/java/com/iso/a/CalcATest.java"
  local test_b = root .. "/b/src/test/java/com/iso/b/CalcBTest.java"
  fixtures.write(test_a, {
    "package com.iso.a;",
    "public class CalcATest {",
    "  @Test void passA() {}",
    "  @Test void failA() {}",
    "  @Test void skipA() {}",
    "}",
  })
  fixtures.write(test_b, {
    "package com.iso.b;",
    "public class CalcBTest {",
    "  @Test void passB() {}",
    "  @Test void failB() {}",
    "}",
  })
  return {
    root = canonical(root),
    mod_a = canonical(root .. "/a"),
    mod_b = canonical(root .. "/b"),
    test_a = canonical(test_a),
    test_b = canonical(test_b),
  }
end

local ws1 = make_mm_maven("iso-ws1")
local ws2 = make_mm_maven("iso-ws2")

-- Stub neotest and jc.test to observe exact dispatched buffer/paths
local jc_calls = {}
local nt_last_pos = nil

package.loaded["neotest"] = {
  run = {
    get_last_run = function()
      return nt_last_pos, nil
    end,
    stop = function()
      jc_calls[#jc_calls + 1] = { op = "nt_stop" }
    end,
  },
  summary = { open = function() end, toggle = function() end },
  output = { open = function() end },
}
package.loaded["jc"] = { config = { test = { precompile = false } } }
package.loaded["jc.test"] = {
  run_at_cursor = function()
    local p = canonical(vim.api.nvim_buf_get_name(0))
    jc_calls[#jc_calls + 1] = { op = "nearest", path = p }
    nt_last_pos = p .. "::Calc::method"
  end,
  run_file = function()
    local p = canonical(vim.api.nvim_buf_get_name(0))
    jc_calls[#jc_calls + 1] = { op = "file", path = p }
    nt_last_pos = p
  end,
  run_all = function()
    local p = canonical(vim.api.nvim_buf_get_name(0))
    jc_calls[#jc_calls + 1] = { op = "suite", path = p }
    nt_last_pos = vim.fs.dirname(p)
  end,
  run_last = function()
    jc_calls[#jc_calls + 1] =
      { op = "jc_run_last", nt_last_pos = nt_last_pos, buf = canonical(vim.api.nvim_buf_get_name(0)) }
  end,
  stop = function()
    jc_calls[#jc_calls + 1] = { op = "stop", path = canonical(vim.api.nvim_buf_get_name(0)) }
  end,
  summary = function() end,
  output = function()
    jc_calls[#jc_calls + 1] = { op = "output", path = canonical(vim.api.nvim_buf_get_name(0)) }
  end,
  toggle_precompile = function() end,
  _nothing_to_run = function()
    return false
  end,
  _package_tests = function()
    return {}
  end,
}

-- ---------- 1. Multi-client JDTLS blocking ----------
vim.lsp.get_clients = function(filter)
  if filter and filter.bufnr then
    return { { id = 1, name = "jdtls" } }
  end
  return { { id = 1, name = "jdtls" }, { id = 2, name = "jdtls" } }
end

open_java_buf(ws1.test_a)
captured_select = {}
stub_select(nil)
tests_mod.tests()
assert(#captured_select == 1, "menu should still open with 2 clients")
for _, needle in ipairs({ "Run Nearest Test", "Run Test File", "Run Test Suite", "Pick Test", "Repeat Last Test" }) do
  local item = find_item(captured_select[1].items, needle)
  assert(
    item and item:find("unavailable: jc.nvim operation unavailable with 2 Java projects open", 1, true),
    needle .. " should be disabled with 2 clients: " .. tostring(item)
  )
end

clear_notices()
jc_calls = {}
tests_mod._run_file(ws1.test_a)
assert(#jc_calls == 0, "_run_file must refuse when 2 JDTLS clients exist")
assert(has_notice("2 Java projects open"), "_run_file should explain 2-client refusal")

-- ---------- 2. Repeat Last Test isolation across modules and same-basename projects ----------
vim.lsp.get_clients = function()
  return { { id = 1, name = "jdtls" } }
end
tests_mod._reset()
nt_last_pos = nil
jc_calls = {}

-- Initially Repeat Last Test is disabled in ws1/a
open_java_buf(ws1.test_a)
captured_select = {}
stub_select(nil)
tests_mod.tests()
local init_last = find_item(captured_select[1].items, "Repeat Last Test")
assert(
  init_last and init_last:find("no previous test run in this project/module", 1, true),
  "initial Repeat Last Test should be disabled: " .. tostring(init_last)
)

-- Run Test File in ws1/a
stub_select(function(items)
  return find_item(items, "Run Test File")
end)
tests_mod.tests()
assert(
  #jc_calls == 1 and jc_calls[1].op == "file" and jc_calls[1].path == ws1.test_a,
  "Run Test File should run ws1/a CalcATest"
)

-- Switch to ws1/b: Repeat Last Test must NOT inherit ws1/a's run
open_java_buf(ws1.test_b)
captured_select = {}
stub_select(nil)
tests_mod.tests()
local b_last = find_item(captured_select[1].items, "Repeat Last Test")
assert(
  b_last and b_last:find("belongs to another project or module", 1, true),
  "ws1/b should reject ws1/a's global neotest last_run: " .. tostring(b_last)
)

-- Switch to ws2/a (same basename 'my-app', same module name 'a'): must NOT inherit ws1/a!
open_java_buf(ws2.test_a)
captured_select = {}
stub_select(nil)
tests_mod.tests()
local ws2_last = find_item(captured_select[1].items, "Repeat Last Test")
assert(
  ws2_last and ws2_last:find("belongs to another project or module", 1, true),
  "ws2/a should reject ws1/a's last_run despite identical basename: " .. tostring(ws2_last)
)

-- Run Test File in ws1/b, then switch back to ws1/a: ws1/a repeats ws1/a (NOT ws1/b!)
open_java_buf(ws1.test_b)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Run Test File")
end)
tests_mod.tests()
assert(jc_calls[1].path == ws1.test_b)

open_java_buf(ws1.test_a)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Repeat Last Test")
end)
tests_mod.tests()
assert(
  #jc_calls == 1 and jc_calls[1].op == "file" and jc_calls[1].path == ws1.test_a,
  "Repeat Last Test in ws1/a must re-run ws1/a even after ws1/b ran: " .. vim.inspect(jc_calls)
)

-- Cold client without target-preservation APIs must refuse Run Nearest Test
-- instead of falling back to async jc.run_at_cursor (which can drift)
tests_mod._reset()
nt_last_pos = nil
open_java_buf(ws1.test_a)
jc_calls = {}
clear_notices()
stub_select(function(items)
  return find_item(items, "Run Nearest Test")
end)
tests_mod.tests()
assert(#jc_calls == 0, "cold client without target preservation must refuse instead of calling jc.run_at_cursor")
assert(has_notice("cold neotest client"), "cold client refusal should explain why: " .. vim.inspect(notices))

-- Direct :JCtestNearest (without java-menu record) without verified jc adapter
-- or neotest.run.run must NOT fall back to global jc.run_last()
tests_mod._reset()
nt_last_pos = ws1.test_a .. "::CalcATest::passA"
open_java_buf(ws1.test_a)
captured_select = {}
jc_calls = {}
stub_select(nil)
tests_mod.tests()
local unverified_direct = find_item(captured_select[1].items, "Repeat Last Test")
assert(
  unverified_direct and unverified_direct:find("no verified jc adapter", 1, true),
  "unverified direct neotest run (nil args/adapter) must not call jc.run_last: " .. tostring(unverified_direct)
)
for _, call in ipairs(jc_calls) do
  assert(call.op ~= "jc_run_last", "must never invoke global jc.run_last")
end

open_java_buf(ws1.test_b)
captured_select = {}
stub_select(nil)
tests_mod.tests()
local blocked_direct = find_item(captured_select[1].items, "Repeat Last Test")
assert(
  blocked_direct and blocked_direct:find("belongs to another project or module", 1, true),
  "cross-module direct neotest run must be blocked: " .. tostring(blocked_direct)
)

-- ---------- 3. Suite scope accuracy (Maven vs Gradle without submodule build.gradle) ----------
open_java_buf(ws1.test_a)
captured_select = {}
jc_calls = {}
clear_notices()
stub_select(function(items)
  return find_item(items, "Run Test Suite")
end)
tests_mod.tests()
assert(
  find_item(captured_select[1].items, "Run Test Suite  (module: a)"),
  "Maven submodule should label suite with module: a"
)
assert(#jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == ws1.test_a)
assert(has_notice("roots at module a"), "Maven submodule suite should warn about module root")

-- Repeating suite uses jc.run_all (not jc.run_last), even after another module ran
open_java_buf(ws1.test_b)
stub_select(function(items)
  return find_item(items, "Run Test File")
end)
tests_mod.tests()

open_java_buf(ws1.test_a)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Repeat Last Test")
end)
tests_mod.tests()
assert(
  #jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == ws1.test_a,
  "Repeat Last Test after suite should re-run suite via jc.run_all"
)

-- Gradle multi-module where subproject has NO local build.gradle
local gr_root = track(vim.fs.normalize(vim.fn.tempname() .. "/iso-gradle"))
fixtures.write(gr_root .. "/settings.gradle", { "include ':core', ':web'" })
fixtures.write(gr_root .. "/build.gradle", { "subprojects {}" })
local gr_core_test = gr_root .. "/core/src/test/java/com/gr/CoreTest.java"
fixtures.write(gr_core_test, { "package com.gr;", "public class CoreTest { @Test void ok() {} }" })

open_java_buf(gr_core_test)
captured_select = {}
clear_notices()
stub_select(function(items)
  return find_item(items, "Run Test Suite")
end)
tests_mod.tests()
assert(
  find_item(captured_select[1].items, "Run Test Suite  (all modules)"),
  "Gradle subproject without local build.gradle runs all modules: " .. vim.inspect(captured_select[1].items)
)
assert(
  has_notice("running all modules in one neotest tree"),
  "all-modules suite should warn about cross-module no-report pollution"
)

-- ---------- 4. Buffer-drift protection ----------
open_java_buf(ws1.test_a)
jc_calls = {}
vim.ui.select = function(items, _, on_choice)
  open_java_buf(ws1.test_b) -- user switched buffer before choosing!
  on_choice(find_item(items, "Run Nearest Test"))
end
tests_mod.tests()
assert(#jc_calls == 0, "buffer drift before Run Nearest Test must abort instead of running ws1/b")

-- ---------- 5. Result reliability & module isolation (inspect_results + real jc report parser) ----------
local xml_a = [[
<testsuite name="com.iso.a.CalcATest" tests="3" failures="1" errors="0" skipped="1">
  <testcase name="passA()" classname="com.iso.a.CalcATest" time="0.01"/>
  <testcase name="failA()" classname="com.iso.a.CalcATest" time="0.02">
    <failure message="expected: &lt;1&gt; but was: &lt;5&gt;">org.opentest4j.AssertionFailedError: expected: &lt;1&gt; but was: &lt;5&gt;
      at com.iso.a.CalcATest.failA(CalcATest.java:10)
    </failure>
  </testcase>
  <testcase name="skipA()" classname="com.iso.a.CalcATest" time="0.00">
    <skipped message="disabled"/>
  </testcase>
</testsuite>
]]
local parsed_a = report.index(report.parse(xml_a))
local case_fail_a = parsed_a[report.key("com.iso.a.CalcATest", "failA")]
assert(case_fail_a and case_fail_a.status == "failed" and case_fail_a.failure and case_fail_a.failure.line == 10)

local id_a_pass = ws1.test_a .. "::CalcATest::passA"
local id_a_fail = ws1.test_a .. "::CalcATest::failA"
local id_a_skip = ws1.test_a .. "::CalcATest::skipA"
local id_b_pass = ws1.test_b .. "::CalcBTest::passB"
local id_b_fail = ws1.test_b .. "::CalcBTest::failB"
local id_ws2_fail = ws2.test_a .. "::CalcATest::failA"

local tree_ws1 = make_tree(ws1.root, {
  { id = id_a_pass, path = ws1.test_a, name = "passA" },
  { id = id_a_fail, path = ws1.test_a, name = "failA" },
  { id = id_a_skip, path = ws1.test_a, name = "skipA" },
  { id = id_b_pass, path = ws1.test_b, name = "passB" },
  { id = id_b_fail, path = ws1.test_b, name = "failB" },
})
local tree_ws2 = make_tree(ws2.root, {
  { id = id_ws2_fail, path = ws2.test_a, name = "failA" },
})

local results_by_adapter = {
  ["jc:" .. ws1.root] = {
    [id_a_pass] = { status = "passed", output = "/tmp/out-a" },
    [id_a_fail] = {
      status = "failed",
      short = case_fail_a.message,
      errors = { { message = case_fail_a.message, line = case_fail_a.failure.line - 1 } },
      output = "/tmp/out-a",
    },
    [id_a_skip] = { status = "skipped", output = "/tmp/out-a" },
    -- Module b suffered jc runner_failed (no XML report) and neotest missing-position fill
    [id_b_pass] = {
      status = "failed",
      short = "test runner produced no report (exit 1) - see :JCtestOutput",
      output = "/tmp/out-b",
    },
    [id_b_fail] = {
      status = "failed",
      errors = {},
      output = "/tmp/out-a",
    },
  },
  ["jc:" .. ws2.root] = {
    [id_ws2_fail] = {
      status = "failed",
      short = "jdtls could not resolve the test classpath. - see :JCtestOutput",
      output = "/tmp/out-ws2",
    },
  },
}

local mock_client = {
  _started = true,
  _adapters = {
    ["jc:" .. ws1.root] = {},
    ["jc:" .. ws2.root] = {},
  },
  _state = {
    positions = function(_, ad_id)
      if ad_id == "jc:" .. ws1.root then
        return tree_ws1
      end
      if ad_id == "jc:" .. ws2.root then
        return tree_ws2
      end
    end,
  },
  get_results = function(_, ad_id)
    return results_by_adapter[ad_id] or {}
  end,
}

-- 5a. Module a in ws1 sees ONLY module a's verified results
local rep_a = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = mock_client,
  jdtls_count = 1,
})
assert(rep_a.reliable == true, "module a with XML results should be reliable: " .. vim.inspect(rep_a.reasons))
assert(
  rep_a.counts.total == 3
    and rep_a.counts.passed == 1
    and rep_a.counts.verified_failed == 1
    and rep_a.counts.synthetic_failed == 0
    and rep_a.counts.skipped == 1,
  "module a counts diverged: " .. vim.inspect(rep_a.counts)
)
assert(vim.deep_equal(rep_a.verified_failed_ids, { id_a_fail }))
assert(rep_a.rerun_failed_supported == false, "rerun_failed_supported must remain false")

-- 5b. Module b in ws1 detects synthetic failures (both jc runner_failed and neotest empty errors={})
local rep_b = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_b,
  client = mock_client,
  jdtls_count = 1,
})
assert(rep_b.reliable == false, "module b without XML report must be unreliable")
assert(
  rep_b.counts.total == 2 and rep_b.counts.synthetic_failed == 2 and rep_b.counts.verified_failed == 0,
  "module b synthetic failures diverged: " .. vim.inspect(rep_b.counts)
)
assert(vim.tbl_contains(rep_b.reasons, "no_report_or_runner_failure"))

-- 5c. Multi-client ambiguity taints even module a
local rep_ambig = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = mock_client,
  jdtls_count = 2,
})
assert(rep_ambig.reliable == false and vim.tbl_contains(rep_ambig.reasons, "ambiguous_jdtls_clients"))

-- 5d. Missing consumer client reports no_consumer_client without crashing
local rep_nocons = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = false,
  jdtls_count = 1,
})
assert(rep_nocons.reliable == false and vim.tbl_contains(rep_nocons.reasons, "no_consumer_client"))

-- 5e. Opening menu in module b warns when neotest/jc marked tests failed without XML report
package.loaded["jc.neotest.consumer"] = { client = mock_client }
open_java_buf(ws1.test_b)
clear_notices()
stub_select(nil)
tests_mod.tests()
assert(
  has_notice("without a JUnit XML report"),
  "Tests menu should warn when neotest/jc marked tests failed without XML report: " .. vim.inspect(notices)
)

-- Opening menu in module a (only verified XML failure) does NOT emit the synthetic-failure warning
open_java_buf(ws1.test_a)
clear_notices()
stub_select(nil)
tests_mod.tests()
assert(
  not has_notice("without a JUnit XML report"),
  "module a with verified XML results should not emit synthetic-failure warning"
)

-- ---------- 6. Regression: jc.run_at_cursor deferred refresh & buffer/cursor safety ----------
-- 6a. Refuses _run_contextual(..., false) when target buffer is not current
local buf_a = open_java_buf(ws1.test_a)
open_java_buf(ws1.test_b)
jc_calls = {}
clear_notices()
tests_mod._run_contextual(buf_a, ws1.root, false)
assert(#jc_calls == 0, "nearest run on non-current buffer must be refused instead of nvim_buf_call")
assert(has_notice("no longer active"), "non-current nearest run should explain refusal")

-- 6b. Preserves exact (file, row) across async jc.neotest.refresh even if user switches buffer/cursor
tests_mod._reset()
local real_jc_target = require("jc.neotest.target")
assert(type(real_jc_target.run_args) == "function", "real jc.neotest.target expected")
local file_tree_a = make_tree(ws1.test_a, {
  { id = id_a_pass, path = ws1.test_a, name = "passA" },
  { id = id_a_fail, path = ws1.test_a, name = "failA" },
})
local nt_runs = {}
local saved_neotest = package.loaded["neotest"]
local saved_jc_test = package.loaded["jc.test"]
local saved_jc = package.loaded["jc"]

package.loaded["neotest"] = {
  run = {
    run = function(args)
      nt_runs[#nt_runs + 1] = args
    end,
    get_last_run = function()
      return nt_last_pos, nil
    end,
    stop = function() end,
  },
  summary = { open = function() end, expand = function() end, toggle = function() end },
  output = { open = function() end },
}
package.loaded["neotest.lib"] = {
  files = {
    path = {
      real = function(p)
        return canonical(p)
      end,
    },
  },
  positions = {
    nearest = function(_, row0)
      local wanted_id = row0 >= 3 and id_a_fail or id_a_pass
      return {
        data = function()
          return { id = wanted_id, type = "test", path = ws1.test_a }
        end,
      }
    end,
  },
}
local refresh_client = {
  _started = true,
  _adapters = { ["jc:" .. ws1.root] = { name = "jc" } },
  _state = {
    positions = function(_, ad_id, pos_id)
      if
        ad_id == "jc:" .. ws1.root
        and (pos_id == nil or pos_id == ws1.test_a or pos_id == id_a_pass or pos_id == id_a_fail)
      then
        return file_tree_a
      end
      return nil
    end,
  },
}
package.loaded["jc.neotest.consumer"] = { client = refresh_client, suppressed = true }
package.loaded["jc.neotest"] = { clear_precompile_cache = function() end }
package.loaded["jc.neotest.refresh"] = {
  before_run = function(_, done)
    vim.schedule(done)
  end,
}
package.loaded["jc"] = { config = { test = { precompile = false, open_summary = false } } }
package.loaded["jc.test"] = {
  _nothing_to_run = function()
    return false
  end,
  run_at_cursor = function()
    error("raw jc.run_at_cursor must not be used when started client has async refresh")
  end,
  run_file = saved_jc_test.run_file,
  run_all = saved_jc_test.run_all,
  run_last = saved_jc_test.run_last,
  stop = saved_jc_test.stop,
  summary = saved_jc_test.summary,
  output = saved_jc_test.output,
  toggle_precompile = saved_jc_test.toggle_precompile,
}

open_java_buf(ws1.test_a)
vim.api.nvim_win_set_cursor(0, { 5, 2 }) -- failA line (row0 == 4)
nt_runs = {}
stub_select(function(items)
  return find_item(items, "Run Nearest Test")
end)
tests_mod.tests()
-- User switches buffer & cursor BEFORE async refresh fires!
open_java_buf(ws1.test_b)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(
  vim.wait(500, function()
    return #nt_runs == 1
  end, 10),
  "deferred nearest run should complete"
)
assert(nt_runs[1][1] == id_a_fail, "exact test position must survive buffer/cursor drift: " .. vim.inspect(nt_runs))
assert(nt_runs[1].adapter == "jc:" .. ws1.root, "pinned jc adapter must be preserved: " .. vim.inspect(nt_runs))

-- Repeat Last Test from ws1/a replays exact pos_id even after running ws1/b
open_java_buf(ws1.test_b)
stub_select(function(items)
  return find_item(items, "Run Test File")
end)
tests_mod.tests()

open_java_buf(ws1.test_a)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
nt_runs = {}
stub_select(function(items)
  return find_item(items, "Repeat Last Test")
end)
tests_mod.tests()
assert(
  vim.wait(500, function()
    return #nt_runs == 1
  end, 10),
  "Repeat Last Test for pinned nearest position should run"
)
assert(nt_runs[1][1] == id_a_fail, "Repeat Last Test should replay exact pinned position: " .. vim.inspect(nt_runs))

-- 6c. Unresolved position tree + buffer drift during async refresh MUST refuse instead of running wrong buffer
refresh_client._state.positions = function()
  return nil
end
open_java_buf(ws1.test_a)
vim.api.nvim_win_set_cursor(0, { 5, 2 })
nt_runs = {}
clear_notices()
stub_select(function(items)
  return find_item(items, "Run Nearest Test")
end)
tests_mod.tests()
open_java_buf(ws1.test_b)
vim.wait(50, function()
  return has_notice("buffer or cursor changed")
end, 5)
assert(#nt_runs == 0, "unresolved position tree with buffer drift must refuse instead of running ws1/b")
assert(has_notice("buffer or cursor changed"), "buffer drift during async refresh should warn")

-- Restore simpler jc.test / neotest mocks for remaining sections
package.loaded["neotest"] = saved_neotest
package.loaded["neotest.lib"] = nil
package.loaded["jc.neotest.refresh"] = nil
package.loaded["jc.neotest"] = nil
package.loaded["jc.neotest.consumer"] = { client = mock_client }
package.loaded["jc"] = saved_jc
package.loaded["jc.test"] = saved_jc_test

-- ---------- 7. Regression: pos_belongs_to_scope isolates root tests vs module tests ----------
local mm_root_dir = track(vim.fs.normalize(vim.fn.tempname() .. "/iso-mm-with-root"))
fixtures.write(mm_root_dir .. "/pom.xml", {
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>com.mmr</groupId>",
  "  <artifactId>mmr</artifactId>",
  "  <version>1.0</version>",
  "  <packaging>pom</packaging>",
  "  <modules>",
  "    <module>sub</module>",
  "  </modules>",
  "</project>",
})
fixtures.write(mm_root_dir .. "/sub/pom.xml", {
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>com.mmr</groupId>",
  "  <artifactId>sub</artifactId>",
  "  <version>1.0</version>",
  "</project>",
})
local root_test_file = canonical(mm_root_dir .. "/src/test/java/com/mmr/RootTest.java")
local sub_test_file = canonical(mm_root_dir .. "/sub/src/test/java/com/mmr/SubTest.java")
fixtures.write(root_test_file, { "package com.mmr;", "public class RootTest { @Test void ok() {} }" })
fixtures.write(sub_test_file, { "package com.mmr;", "public class SubTest { @Test void ok() {} }" })
local c_mm_root = canonical(mm_root_dir)
local c_mm_sub = canonical(mm_root_dir .. "/sub")
local mm_mods = { c_mm_sub }

assert(
  tests_mod._pos_belongs_to_scope(root_test_file .. "::RootTest::ok", c_mm_root, c_mm_root, mm_mods) == true,
  "root test belongs to root scope"
)
assert(
  tests_mod._pos_belongs_to_scope(sub_test_file .. "::SubTest::ok", c_mm_root, c_mm_root, mm_mods) == false,
  "submodule test must NOT belong to root scope"
)
assert(
  tests_mod._pos_belongs_to_scope(root_test_file .. "::RootTest::ok", c_mm_root, c_mm_sub, mm_mods) == false,
  "root test must NOT belong to submodule scope"
)
assert(
  tests_mod._pos_belongs_to_scope(sub_test_file .. "::SubTest::ok", c_mm_root, c_mm_sub, mm_mods) == true,
  "submodule test belongs to submodule scope"
)

tests_mod._reset()
nt_last_pos = sub_test_file .. "::SubTest::ok"
open_java_buf(root_test_file)
captured_select = {}
stub_select(nil)
tests_mod.tests()
local root_last = find_item(captured_select[1].items, "Repeat Last Test")
assert(
  root_last and root_last:find("belongs to another project or module", 1, true),
  "root menu Repeat Last Test must reject submodule neotest last_run: " .. tostring(root_last)
)

-- ---------- 8. Regression: Suite replay preserves original module/target without recalculating from current buffer ----------
tests_mod._reset()
nt_last_pos = nil
open_java_buf(ws1.test_a)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Run Test Suite")
end)
tests_mod.tests()
assert(#jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == ws1.test_a)

-- Switch to another test file in the SAME module (ws1/a): Repeat Last Test replays original target ws1.test_a
local other_a_test = canonical(ws1.mod_a .. "/src/test/java/com/iso/a/OtherATest.java")
fixtures.write(other_a_test, { "package com.iso.a;", "public class OtherATest { @Test void ok() {} }" })

open_java_buf(other_a_test)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Repeat Last Test")
end)
tests_mod.tests()
assert(
  #jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == ws1.test_a,
  "suite replay must target original ws1.test_a, not current buffer OtherATest: " .. vim.inspect(jc_calls)
)

-- If original file's suite_target_dir changes (e.g. a nested pom.xml is added around it),
-- suite replay falls back to the original module's marker file so jc.run_all still targets ws1.mod_a
local sub_a_test = canonical(ws1.mod_a .. "/sub/src/test/java/com/iso/a/SubATest.java")
fixtures.write(sub_a_test, { "package com.iso.a;", "public class SubATest { @Test void ok() {} }" })
tests_mod._reset()
open_java_buf(sub_a_test)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Run Test Suite")
end)
tests_mod.tests()
assert(#jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == sub_a_test)

fixtures.write(ws1.mod_a .. "/sub/pom.xml", { "<project/>" })
open_java_buf(other_a_test)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Repeat Last Test")
end)
tests_mod.tests()
assert(
  #jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == canonical(ws1.mod_a .. "/pom.xml"),
  "suite replay must fall back to ws1.mod_a/pom.xml instead of sub/ or current buffer: " .. vim.inspect(jc_calls)
)

-- Gradle all-modules suite from core stays isolated from web and replays gr_core_test -> gr_root
tests_mod._reset()
nt_last_pos = nil
local gr_web_test = gr_root .. "/web/src/test/java/com/gr/WebTest.java"
fixtures.write(gr_web_test, { "package com.gr;", "public class WebTest { @Test void ok() {} }" })

open_java_buf(gr_core_test)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Run Test Suite")
end)
tests_mod.tests()
assert(#jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == canonical(gr_core_test))

-- web module must NOT inherit core's suite run
open_java_buf(gr_web_test)
captured_select = {}
stub_select(nil)
tests_mod.tests()
local web_last = find_item(captured_select[1].items, "Repeat Last Test")
assert(
  web_last and web_last:find("unavailable:", 1, true),
  "Gradle web module must remain isolated from core's suite run: " .. tostring(web_last)
)

-- Replay from another file in core still replays original target gr_core_test
local gr_core_other = canonical(gr_root .. "/core/src/test/java/com/gr/CoreOtherTest.java")
fixtures.write(gr_core_other, { "package com.gr;", "public class CoreOtherTest { @Test void ok() {} }" })
open_java_buf(gr_core_other)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Repeat Last Test")
end)
tests_mod.tests()
assert(
  #jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == canonical(gr_core_test),
  "Gradle suite replay must target original gr_core_test, not current buffer: " .. vim.inspect(jc_calls)
)

-- If gr_core_test is deleted, replay falls back to gr_root/settings.gradle (still targeting gr_root)
vim.fn.delete(gr_core_test)
jc_calls = {}
stub_select(function(items)
  return find_item(items, "Repeat Last Test")
end)
tests_mod.tests()
assert(
  #jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == canonical(gr_root .. "/settings.gradle"),
  "Gradle suite replay must fall back to gr_root/settings.gradle when gr_core_test is deleted: "
    .. vim.inspect(jc_calls)
)

-- ---------- 9. Regression: Missing/failed tree, adapters, or get_results => reliable = false ----------
local r_no_adapters = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = {
    _started = true,
    _adapters = {},
    _state = { positions = function() end },
    get_results = function()
      return {}
    end,
  },
  jdtls_count = 1,
})
assert(
  r_no_adapters.reliable == false and vim.tbl_contains(r_no_adapters.reasons, "no_jc_adapter"),
  "empty adapters must be unreliable: " .. vim.inspect(r_no_adapters)
)

local r_not_started = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = {
    _started = false,
    _adapters = { ["jc:" .. ws1.root] = {} },
    _state = {
      positions = function()
        return tree_ws1
      end,
    },
    get_results = function()
      return {}
    end,
  },
  jdtls_count = 1,
})
assert(
  r_not_started.reliable == false and vim.tbl_contains(r_not_started.reasons, "client_not_started"),
  "unstarted client must be unreliable: " .. vim.inspect(r_not_started)
)

local r_missing_tree = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = {
    _started = true,
    _adapters = { ["jc:" .. ws1.root] = {} },
    _state = {
      positions = function()
        return nil
      end,
    },
    get_results = function()
      return {}
    end,
  },
  jdtls_count = 1,
})
assert(
  r_missing_tree.reliable == false and vim.tbl_contains(r_missing_tree.reasons, "missing_position_tree"),
  "missing position tree must be unreliable: " .. vim.inspect(r_missing_tree)
)

local r_tree_err = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = {
    _started = true,
    _adapters = { ["jc:" .. ws1.root] = {} },
    _state = {
      positions = function()
        error("tree boom")
      end,
    },
    get_results = function()
      return {}
    end,
  },
  jdtls_count = 1,
})
assert(
  r_tree_err.reliable == false and vim.tbl_contains(r_tree_err.reasons, "position_tree_read_failed"),
  "errored position tree read must be unreliable: " .. vim.inspect(r_tree_err)
)

local r_res_err = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = {
    _started = true,
    _adapters = { ["jc:" .. ws1.root] = {} },
    _state = {
      positions = function()
        return tree_ws1
      end,
    },
    get_results = function()
      error("results boom")
    end,
  },
  jdtls_count = 1,
})
assert(
  r_res_err.reliable == false and vim.tbl_contains(r_res_err.reasons, "results_read_failed"),
  "errored get_results must be unreliable: " .. vim.inspect(r_res_err)
)

local r_res_nil = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = {
    _started = true,
    _adapters = { ["jc:" .. ws1.root] = {} },
    _state = {
      positions = function()
        return tree_ws1
      end,
    },
    get_results = function()
      return nil
    end,
  },
  jdtls_count = 1,
})
assert(
  r_res_nil.reliable == false and vim.tbl_contains(r_res_nil.reasons, "results_read_failed"),
  "non-table get_results return must be unreliable: " .. vim.inspect(r_res_nil)
)

-- nt.state.adapter_ids throwing when _adapters is missing must be unreliable
local prev_nt = package.loaded["neotest"]
package.loaded["neotest"] = {
  state = {
    adapter_ids = function()
      error("state consumer unavailable")
    end,
  },
}
local r_ad_err = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = {
    _started = true,
    get_results = function()
      return {}
    end,
  },
  jdtls_count = 1,
})
assert(
  r_ad_err.reliable == false and vim.tbl_contains(r_ad_err.reasons, "adapter_discovery_failed"),
  "errored adapter_ids discovery must be unreliable: " .. vim.inspect(r_ad_err)
)
package.loaded["neotest"] = prev_nt

-- ---------- 10. Regression: Filter ONLY the matching jc adapter (ignore other adapters on same file) ----------
local mixed_client = {
  _started = true,
  _adapters = {
    ["jc:" .. ws1.root] = { name = "jc" },
    ["neotest-java:" .. ws1.root] = { name = "neotest-java" },
    ["jc:" .. ws2.root] = { name = "jc" },
  },
  _state = {
    positions = function(_, ad_id)
      if ad_id == "jc:" .. ws1.root or ad_id == "neotest-java:" .. ws1.root then
        return tree_ws1
      end
      return nil
    end,
  },
  get_results = function(_, ad_id)
    if ad_id == "jc:" .. ws1.root then
      return results_by_adapter["jc:" .. ws1.root]
    end
    if ad_id == "neotest-java:" .. ws1.root then
      -- Conflicting results on the exact same test IDs from another adapter
      return {
        [id_a_pass] = { status = "failed", errors = {} },
        [id_a_fail] = { status = "failed", errors = {} },
        [id_b_pass] = { status = "passed" },
        [id_b_fail] = { status = "passed" },
      }
    end
    error("must not query unrelated adapter: " .. tostring(ad_id))
  end,
}

local mixed_a = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = mixed_client,
  jdtls_count = 1,
})
assert(
  mixed_a.reliable == true and mixed_a.counts.synthetic_failed == 0 and mixed_a.counts.verified_failed == 1,
  "other adapter synthetic failures must not pollute jc results for mod_a: " .. vim.inspect(mixed_a)
)

local mixed_b = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_b,
  client = mixed_client,
  jdtls_count = 1,
})
assert(
  mixed_b.reliable == false and mixed_b.counts.synthetic_failed == 2,
  "other adapter passed results must not mask jc synthetic failures for mod_b: " .. vim.inspect(mixed_b)
)

-- Non-jc adapter alone (or spoofed name) must not pass as jc
local only_other = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = {
    _started = true,
    _adapters = { ["neotest-java:" .. ws1.root] = { name = "neotest-java" } },
    _state = {
      positions = function()
        return tree_ws1
      end,
    },
    get_results = function()
      return { [id_a_pass] = { status = "passed" } }
    end,
  },
  jdtls_count = 1,
})
assert(
  only_other.reliable == false
    and vim.tbl_contains(only_other.reasons, "no_jc_adapter")
    and only_other.counts.total == 0,
  "non-jc adapter must be excluded: " .. vim.inspect(only_other)
)

-- Per-module jc adapter (real jc.project.root behavior in Maven multi-module) stays module-isolated
local tree_mod_a = make_tree(ws1.mod_a, {
  { id = id_a_pass, path = ws1.test_a, name = "passA" },
  { id = id_a_fail, path = ws1.test_a, name = "failA" },
  { id = id_a_skip, path = ws1.test_a, name = "skipA" },
})
local per_mod_client = {
  _started = true,
  _adapters = {
    ["jc:" .. ws1.mod_a] = { name = "jc" },
    ["jc:" .. ws1.mod_b] = { name = "jc" },
  },
  _state = {
    positions = function(_, ad_id)
      if ad_id == "jc:" .. ws1.mod_a then
        return tree_mod_a
      end
      error("must not read mod_b tree when inspecting mod_a: " .. tostring(ad_id))
    end,
  },
  get_results = function(_, ad_id)
    if ad_id == "jc:" .. ws1.mod_a then
      return results_by_adapter["jc:" .. ws1.root]
    end
    error("must not read mod_b results when inspecting mod_a: " .. tostring(ad_id))
  end,
}
local per_mod_rep = tests_mod.inspect_results({
  root = ws1.root,
  module = ws1.mod_a,
  client = per_mod_client,
  jdtls_count = 1,
})
assert(
  per_mod_rep.reliable == true and per_mod_rep.counts.total == 3 and per_mod_rep.counts.verified_failed == 1,
  "per-module jc adapter should inspect only mod_a: " .. vim.inspect(per_mod_rep)
)

-- ---------- 11. Regression: Repeat Last Test never calls jc.run_last on unpinned/wrong-adapter nearest ----------
do
  tests_mod._reset()
  local cur_nt_runs = {}
  local cur_jc_last_called = false
  local prev_nt_mod = package.loaded["neotest"]
  local prev_jct_mod = package.loaded["jc.test"]
  local prev_cons_mod = package.loaded["jc.neotest.consumer"]
  local prev_ref_mod = package.loaded["jc.neotest.refresh"]

  local last_pos_val = id_a_pass
  local last_args_val = { adapter = "neotest-java:" .. ws1.root }

  package.loaded["neotest"] = {
    run = {
      run = function(args)
        cur_nt_runs[#cur_nt_runs + 1] = args
      end,
      get_last_run = function()
        return last_pos_val, last_args_val
      end,
      stop = function() end,
    },
    summary = { open = function() end, expand = function() end, toggle = function() end },
    output = { open = function() end },
  }
  package.loaded["jc.neotest.consumer"] = {
    client = {
      _started = true,
      _adapters = {
        ["jc:" .. ws1.root] = { name = "jc" },
        ["neotest-java:" .. ws1.root] = { name = "neotest-java" },
      },
      _state = {
        positions = function(_, ad_id, pos_id)
          if ad_id == "jc:" .. ws1.root and (pos_id == nil or pos_id == id_a_pass or pos_id == ws1.test_a) then
            return tree_ws1
          end
          return nil
        end,
      },
    },
  }
  package.loaded["jc.neotest.refresh"] = {
    before_run = function(_, done)
      done()
    end,
  }
  package.loaded["jc.test"] = vim.tbl_extend("force", prev_jct_mod, {
    run_last = function()
      cur_jc_last_called = true
      error("jc.run_last must NEVER be called")
    end,
  })

  -- 11a. Direct neotest last_run belonging to non-jc adapter must be refused
  open_java_buf(ws1.test_a)
  captured_select = {}
  stub_select(nil)
  tests_mod.tests()
  local wrong_ad = find_item(captured_select[1].items, "Repeat Last Test")
  assert(
    wrong_ad and wrong_ad:find("no verified jc adapter", 1, true),
    "wrong-adapter neotest last_run must be refused: " .. tostring(wrong_ad)
  )
  assert(not cur_jc_last_called, "jc.run_last must not be called")

  -- 11b. Direct neotest last_run with verified jc adapter replays pinned pos_id via nt.run.run (never jc.run_last)
  last_args_val = { adapter = "jc:" .. ws1.root }
  cur_nt_runs = {}
  stub_select(function(items)
    return find_item(items, "Repeat Last Test")
  end)
  tests_mod.tests()
  assert(
    #cur_nt_runs == 1 and cur_nt_runs[1][1] == id_a_pass and cur_nt_runs[1].adapter == "jc:" .. ws1.root,
    "verified direct neotest last_run must replay via pinned nt.run.run: " .. vim.inspect(cur_nt_runs)
  )
  assert(not cur_jc_last_called, "jc.run_last must not be called for verified replay")

  -- 11c. If nt.run.run disappears after a pinned nearest run, Repeat Last Test refuses instead of calling jc.run_last
  package.loaded["neotest"].run.run = nil
  captured_select = {}
  clear_notices()
  stub_select(nil)
  tests_mod.tests()
  local missing_api = find_item(captured_select[1].items, "Repeat Last Test")
  assert(
    missing_api and missing_api:find("cannot replay nearest test safely", 1, true),
    "Repeat Last Test must refuse when pinned runner APIs vanish: " .. tostring(missing_api)
  )
  assert(not cur_jc_last_called, "jc.run_last must not be called when nt.run.run is unavailable")

  package.loaded["neotest"] = prev_nt_mod
  package.loaded["jc.test"] = prev_jct_mod
  package.loaded["jc.neotest.consumer"] = prev_cons_mod
  package.loaded["jc.neotest.refresh"] = prev_ref_mod
end

-- ---------- 12. Regression: Cold client preserves nearest target via real APIs or refuses without drift ----------
do
  tests_mod._reset()
  local prev_nt_mod = package.loaded["neotest"]
  local prev_jct_mod = package.loaded["jc.test"]
  local prev_cons_mod = package.loaded["jc.neotest.consumer"]
  local prev_ref_mod = package.loaded["jc.neotest.refresh"]
  local prev_jcnt_mod = package.loaded["jc.neotest"]
  local prev_lib_mod = package.loaded["neotest.lib"]
  local prev_nio_mod = package.loaded["nio"]
  local prev_jc_mod = package.loaded["jc"]

  local cold_nt_runs = {}
  local raw_cursor_called = false
  local cold_ad_id = "jc:" .. ws1.mod_a
  local cold_client
  cold_client = {
    _started = false,
    _adapters = {},
    _ensure_started = function(self)
      self._started = true
    end,
    _update_adapters = function(self, _)
      self._adapters[cold_ad_id] = { name = "jc" }
    end,
    _state = {
      positions = function(_, ad_id, pos_id)
        if cold_client._started and ad_id == cold_ad_id and (pos_id == id_a_fail or pos_id == ws1.test_a) then
          return tree_ws1
        end
        return nil
      end,
    },
    get_nearest = function(self, file_path, row, args)
      assert(self._started == true, "get_nearest should run on started client")
      assert(file_path == ws1.test_a, "cold client get_nearest must use captured path, got " .. tostring(file_path))
      assert(row == 4, "cold client get_nearest must use captured row0=4, got " .. tostring(row))
      assert(args and args.adapter == cold_ad_id, "cold client should pass jc adapter: " .. vim.inspect(args))
      return {
        data = function()
          return { id = id_a_fail, type = "test", path = ws1.test_a }
        end,
      },
        cold_ad_id
    end,
  }

  package.loaded["nio"] = {
    run = function(fn)
      fn()
    end,
  }
  package.loaded["neotest"] = {
    run = {
      run = function(args)
        cold_nt_runs[#cold_nt_runs + 1] = args
      end,
      get_last_run = function()
        return nil, nil
      end,
      stop = function() end,
    },
    summary = { open = function() end, expand = function() end, toggle = function() end },
    output = { open = function() end },
  }
  package.loaded["jc.neotest.consumer"] = { client = cold_client, suppressed = true }
  package.loaded["jc.neotest"] = { clear_precompile_cache = function() end }
  package.loaded["jc.neotest.refresh"] = {
    before_run = function(_, done)
      done()
    end,
  }
  package.loaded["jc"] = { config = { test = { precompile = false, open_summary = false } } }
  package.loaded["jc.test"] = vim.tbl_extend("force", prev_jct_mod, {
    _nothing_to_run = function()
      return false
    end,
    run_at_cursor = function()
      raw_cursor_called = true
      error("jc.run_at_cursor must NEVER be called on cold client")
    end,
  })

  -- 12a. Cold client preserves exact (cpath, row0) across immediate buffer/cursor switch
  open_java_buf(ws1.test_a)
  vim.api.nvim_win_set_cursor(0, { 5, 2 })
  cold_nt_runs = {}
  stub_select(function(items)
    return find_item(items, "Run Nearest Test")
  end)
  tests_mod.tests()
  open_java_buf(ws1.test_b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert(
    vim.wait(500, function()
      return #cold_nt_runs == 1
    end, 10),
    "cold client pinned nearest run should complete"
  )
  assert(not raw_cursor_called, "cold client must not call jc.run_at_cursor")
  assert(
    cold_nt_runs[1][1] == id_a_fail and cold_nt_runs[1].adapter == cold_ad_id,
    "cold client must preserve exact pos_id and adapter despite drift: " .. vim.inspect(cold_nt_runs)
  )

  -- Repeat Last Test after cold-client nearest run replays exact pos_id
  open_java_buf(ws1.test_a)
  cold_nt_runs = {}
  stub_select(function(items)
    return find_item(items, "Repeat Last Test")
  end)
  tests_mod.tests()
  assert(
    vim.wait(500, function()
      return #cold_nt_runs == 1
    end, 10),
    "Repeat Last Test after cold-client run should execute"
  )
  assert(cold_nt_runs[1][1] == id_a_fail, "Repeat Last Test must replay pos_id from cold-client run")

  -- 12b. Cold client without consumer (nil client) uses real jc.neotest.discover_positions + neotest.lib.positions.nearest
  tests_mod._reset()
  cold_nt_runs = {}
  package.loaded["jc.neotest.consumer"] = { client = nil }
  package.loaded["neotest.lib"] = {
    positions = {
      nearest = function(_, row)
        assert(row == 4, "discover fallback must receive captured row0=4")
        return {
          data = function()
            return { id = id_a_fail, type = "test", path = ws1.test_a }
          end,
        }
      end,
    },
  }
  package.loaded["jc.neotest"] = {
    clear_precompile_cache = function() end,
    discover_positions = function(file_path)
      assert(file_path == ws1.test_a, "discover_positions must use captured file path")
      return tree_ws1
    end,
  }
  open_java_buf(ws1.test_a)
  vim.api.nvim_win_set_cursor(0, { 5, 2 })
  stub_select(function(items)
    return find_item(items, "Run Nearest Test")
  end)
  tests_mod.tests()
  open_java_buf(ws1.test_b)
  assert(
    vim.wait(500, function()
      return #cold_nt_runs == 1
    end, 10),
    "cold discover_positions run should complete"
  )
  assert(not raw_cursor_called, "discover_positions path must not call jc.run_at_cursor")
  assert(cold_nt_runs[1][1] == id_a_fail, "discover_positions must pin pos_id despite drift")

  -- 12c. Cold client where position cannot be resolved refuses with explanation instead of calling jc.run_at_cursor or nt.run.run(nil)
  tests_mod._reset()
  cold_nt_runs = {}
  clear_notices()
  package.loaded["jc.neotest"].discover_positions = function()
    return nil
  end
  open_java_buf(ws1.test_a)
  vim.api.nvim_win_set_cursor(0, { 5, 2 })
  stub_select(function(items)
    return find_item(items, "Run Nearest Test")
  end)
  tests_mod.tests()
  assert(
    vim.wait(500, function()
      return has_notice("could not resolve nearest test position")
    end, 10),
    "unresolved cold client must explain refusal: " .. vim.inspect(notices)
  )
  assert(#cold_nt_runs == 0 and not raw_cursor_called, "unresolved cold client must not run unpinned")

  package.loaded["neotest"] = prev_nt_mod
  package.loaded["jc.test"] = prev_jct_mod
  package.loaded["jc.neotest.consumer"] = prev_cons_mod
  package.loaded["jc.neotest.refresh"] = prev_ref_mod
  package.loaded["jc.neotest"] = prev_jcnt_mod
  package.loaded["neotest.lib"] = prev_lib_mod
  package.loaded["nio"] = prev_nio_mod
  package.loaded["jc"] = prev_jc_mod
end

-- ---------- 13. Regression: inspect_results excludes independent nested projects & rejects invalid/unknown data ----------
do
  local outer = track(vim.fs.normalize(vim.fn.tempname() .. "/iso-nested-outer"))
  fixtures.write(outer .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.outer</groupId>",
    "  <artifactId>outer</artifactId>",
    "  <version>1.0</version>",
    "  <packaging>pom</packaging>",
    "  <modules><module>mod</module></modules>",
    "</project>",
  })
  fixtures.write(outer .. "/mod/pom.xml", { "<project/>" })
  local outer_test = canonical(outer .. "/mod/src/test/java/com/outer/OuterTest.java")
  local indep_maven = canonical(outer .. "/examples/indep-maven/src/test/java/com/indep/IndepMavenTest.java")
  local indep_git = canonical(outer .. "/worktrees/wt1/src/test/java/com/wt/WtTest.java")
  local indep_in_mod = canonical(outer .. "/mod/nested-gradle/src/test/java/com/ng/NestedGradleTest.java")
  fixtures.write(outer .. "/examples/indep-maven/pom.xml", { "<project/>" })
  vim.fn.mkdir(outer .. "/worktrees/wt1/.git", "p")
  fixtures.write(outer .. "/mod/nested-gradle/build.gradle", { "plugins { id 'java' }" })
  fixtures.write(outer_test, { "package com.outer;", "public class OuterTest { @Test void ok() {} }" })
  fixtures.write(indep_maven, { "package com.indep;", "public class IndepMavenTest { @Test void fail() {} }" })
  fixtures.write(indep_git, { "package com.wt;", "public class WtTest { @Test void fail() {} }" })
  fixtures.write(indep_in_mod, { "package com.ng;", "public class NestedGradleTest { @Test void fail() {} }" })

  local c_outer = canonical(outer)
  local c_mod = canonical(outer .. "/mod")
  local id_outer_ok = outer_test .. "::OuterTest::ok"
  local id_indep_mvn = indep_maven .. "::IndepMavenTest::fail"
  local id_indep_git = indep_git .. "::WtTest::fail"
  local id_indep_mod = indep_in_mod .. "::NestedGradleTest::fail"

  local outer_tree = make_tree(c_outer, {
    { id = id_outer_ok, path = outer_test, name = "ok" },
    { id = id_indep_mvn, path = indep_maven, name = "fail" },
    { id = id_indep_git, path = indep_git, name = "fail" },
    { id = id_indep_mod, path = indep_in_mod, name = "fail" },
  })
  local outer_client = {
    _started = true,
    _adapters = { ["jc:" .. c_outer] = { name = "jc" } },
    _state = {
      positions = function()
        return outer_tree
      end,
    },
    get_results = function()
      return {
        [id_outer_ok] = { status = "passed" },
        [id_indep_mvn] = { status = "failed", errors = {} },
        [id_indep_git] = { status = "failed", errors = {} },
        [id_indep_mod] = { status = "failed", errors = {} },
      }
    end,
  }

  local rep_outer = tests_mod.inspect_results({ root = c_outer, client = outer_client, jdtls_count = 1 })
  assert(
    rep_outer.reliable == true and rep_outer.counts.total == 1 and rep_outer.counts.passed == 1,
    "root inspect_results must exclude nested independent projects: " .. vim.inspect(rep_outer)
  )

  local rep_mod = tests_mod.inspect_results({ root = c_outer, module = c_mod, client = outer_client, jdtls_count = 1 })
  assert(
    rep_mod.reliable == true and rep_mod.counts.total == 1 and rep_mod.counts.passed == 1,
    "module inspect_results must exclude nested independent projects inside module: " .. vim.inspect(rep_mod)
  )

  -- (5) Test without valid id/path, unknown status, and partially invalid data => reliable = false
  local bad_id_tree = make_tree(c_outer, {
    { id = id_outer_ok, path = outer_test, name = "ok" },
    { id = "", path = outer_test, name = "emptyId" },
  })
  local r_bad_id = tests_mod.inspect_results({
    root = c_outer,
    client = {
      _started = true,
      _adapters = { ["jc:" .. c_outer] = { name = "jc" } },
      _state = {
        positions = function()
          return bad_id_tree
        end,
      },
      get_results = function()
        return { [id_outer_ok] = { status = "passed" } }
      end,
    },
    jdtls_count = 1,
  })
  assert(
    r_bad_id.reliable == false and vim.tbl_contains(r_bad_id.reasons, "invalid_test_position"),
    "test without valid id must yield reliable=false: " .. vim.inspect(r_bad_id)
  )

  local bad_path_tree = make_tree(c_outer, {
    { id = id_outer_ok, path = outer_test, name = "ok" },
    { id = "some::id", path = nil, name = "noPath" },
  })
  local r_bad_path = tests_mod.inspect_results({
    root = c_outer,
    client = {
      _started = true,
      _adapters = { ["jc:" .. c_outer] = { name = "jc" } },
      _state = {
        positions = function()
          return bad_path_tree
        end,
      },
      get_results = function()
        return { [id_outer_ok] = { status = "passed" } }
      end,
    },
    jdtls_count = 1,
  })
  assert(
    r_bad_path.reliable == false and vim.tbl_contains(r_bad_path.reasons, "invalid_test_position"),
    "test without valid path must yield reliable=false: " .. vim.inspect(r_bad_path)
  )

  local r_unknown_status = tests_mod.inspect_results({
    root = c_outer,
    client = {
      _started = true,
      _adapters = { ["jc:" .. c_outer] = { name = "jc" } },
      _state = {
        positions = function()
          return make_tree(c_outer, { { id = id_outer_ok, path = outer_test, name = "ok" } })
        end,
      },
      get_results = function()
        return { [id_outer_ok] = { status = "running" } }
      end,
    },
    jdtls_count = 1,
  })
  assert(
    r_unknown_status.reliable == false and vim.tbl_contains(r_unknown_status.reasons, "unknown_result_status"),
    "unknown result status must yield reliable=false: " .. vim.inspect(r_unknown_status)
  )

  local r_corrupt_result = tests_mod.inspect_results({
    root = c_outer,
    client = {
      _started = true,
      _adapters = { ["jc:" .. c_outer] = { name = "jc" } },
      _state = {
        positions = function()
          return make_tree(c_outer, { { id = id_outer_ok, path = outer_test, name = "ok" } })
        end,
      },
      get_results = function()
        return { [id_outer_ok] = "passed" }
      end,
    },
    jdtls_count = 1,
  })
  assert(
    r_corrupt_result.reliable == false and vim.tbl_contains(r_corrupt_result.reasons, "invalid_test_result"),
    "non-table result must yield reliable=false: " .. vim.inspect(r_corrupt_result)
  )

  local r_bad_errors = tests_mod.inspect_results({
    root = c_outer,
    client = {
      _started = true,
      _adapters = { ["jc:" .. c_outer] = { name = "jc" } },
      _state = {
        positions = function()
          return make_tree(c_outer, { { id = id_outer_ok, path = outer_test, name = "ok" } })
        end,
      },
      get_results = function()
        return { [id_outer_ok] = { status = "failed", errors = { {} } } }
      end,
    },
    jdtls_count = 1,
  })
  assert(
    r_bad_errors.reliable == false and vim.tbl_contains(r_bad_errors.reasons, "invalid_test_result"),
    "malformed errors entry must yield reliable=false: " .. vim.inspect(r_bad_errors)
  )

  local partial_bad_tree = {
    iter_nodes = function()
      local step = 0
      return function()
        step = step + 1
        if step == 1 then
          return 1,
            {
              data = function()
                return { id = id_outer_ok, type = "test", path = outer_test }
              end,
            }
        elseif step == 2 then
          return 2, {
            data = function()
              return "bad_node"
            end,
          }
        end
      end
    end,
  }
  local r_partial_tree = tests_mod.inspect_results({
    root = c_outer,
    client = {
      _started = true,
      _adapters = { ["jc:" .. c_outer] = { name = "jc" } },
      _state = {
        positions = function()
          return partial_bad_tree
        end,
      },
      get_results = function()
        return { [id_outer_ok] = { status = "passed" } }
      end,
    },
    jdtls_count = 1,
  })
  assert(
    r_partial_tree.reliable == false and vim.tbl_contains(r_partial_tree.reasons, "invalid_position_node"),
    "partially invalid position node must yield reliable=false: " .. vim.inspect(r_partial_tree)
  )
end

-- ---------- 14. Regression: Suite .git marker detection and exact-scope replay ----------
do
  tests_mod._reset()
  local mm_git = make_mm_maven("iso-mm-git")
  vim.fn.mkdir(mm_git.mod_a .. "/.git", "p")
  open_java_buf(mm_git.test_a)
  jc_calls = {}
  stub_select(function(items)
    return find_item(items, "Run Test Suite")
  end)
  tests_mod.tests()
  assert(#jc_calls == 1 and jc_calls[1].op == "suite" and jc_calls[1].path == mm_git.test_a)

  -- If mod_a/pom.xml is removed even with mod_a/.git present, jc.test.run_all on
  -- mod_a/.git climbs to root/pom.xml (pom.xml precedes .git in flat vim.fs.root),
  -- so resolve_suite_replay_path and Repeat Last Test refuse instead of expanding to root!
  vim.fn.delete(mm_git.mod_a .. "/pom.xml")
  local rp_expanded = tests_mod._resolve_suite_replay_path({
    path = mm_git.test_a,
    root = mm_git.root,
    module = mm_git.mod_a,
    suite_dir = mm_git.mod_a,
  })
  assert(
    rp_expanded == nil,
    "resolve_suite_replay_path must refuse when mod_a/pom.xml is gone: " .. tostring(rp_expanded)
  )
  local mod_a_other = canonical(mm_git.mod_a .. "/src/test/java/com/iso/a/OtherATest.java")
  fixtures.write(mod_a_other, { "package com.iso.a;", "public class OtherATest { @Test void ok() {} }" })
  open_java_buf(mod_a_other)
  captured_select = {}
  jc_calls = {}
  stub_select(nil)
  tests_mod.tests()
  local expanded_suite = find_item(captured_select[1].items, "Repeat Last Test")
  assert(
    expanded_suite and expanded_suite:find("unavailable:", 1, true),
    "suite replay must be disabled when mod_a/pom.xml is gone: " .. tostring(expanded_suite)
  )

  -- If effective jc.test.run_all target drifts before clicking Run Test Suite
  -- (e.g., buffer becomes unnamed under an external .git repo), run_suite MUST refuse!
  tests_mod._reset()
  local ext_git = track(vim.fs.normalize(vim.fn.tempname() .. "/iso-ext-git"))
  vim.fn.mkdir(ext_git .. "/.git", "p")
  local saved_cwd = vim.fn.getcwd()
  open_java_buf(mm_git.test_b)
  jc_calls = {}
  clear_notices()
  vim.ui.select = function(items, _, on_choice)
    vim.cmd("cd " .. vim.fn.fnameescape(ext_git))
    vim.api.nvim_buf_set_name(0, "")
    on_choice(find_item(items, "Run Test Suite"))
  end
  tests_mod.tests()
  vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))
  assert(#jc_calls == 0, "run_suite must refuse when effective jc.test.run_all target resolves to external .git")
  assert(
    has_notice("effective target does not match"),
    "run_suite mismatch should explain why: " .. vim.inspect(notices)
  )

  -- Also verify effective target check includes .git marker directly
  local git_only = track(vim.fs.normalize(vim.fn.tempname() .. "/iso-git-only"))
  vim.fn.mkdir(git_only .. "/.git", "p")
  local git_only_file = git_only .. "/src/test/java/AppTest.java"
  fixtures.write(git_only_file, { "public class AppTest {}" })
  assert(
    tests_mod._effective_jc_suite_target(git_only_file) == canonical(git_only),
    "effective jc suite target must recognize .git marker"
  )
end

-- ---------- cleanup ----------
vim.notify = real_notify
vim.ui.select = real_select
vim.lsp.get_clients = real_get_clients
package.loaded["neotest"] = nil
package.loaded["neotest.lib"] = nil
package.loaded["nio"] = nil
package.loaded["jc"] = nil
package.loaded["jc.test"] = nil
package.loaded["jc.neotest"] = nil
package.loaded["jc.neotest.refresh"] = nil
package.loaded["jc.neotest.target"] = nil
package.loaded["jc.neotest.consumer"] = nil
tests_mod._reset()

for _, dir in ipairs(temp_dirs) do
  vim.fn.delete(dir, "rf")
end

print("tests_isolation_spec: OK")
vim.cmd("qa!")
