-- 7E: ergonomic bidirectional class <-> test navigation, module-aware resolution,
-- safe handling of missing/ambiguous counterparts, contextual defaults and
-- consistent reason messages in java_menu.tests.
--
-- Run:
--   nvim --headless -u NONE -n -c "set rtp+=." -c "set rtp+=~/.local/share/nvim/lazy/jc.nvim" \
--     -c "luafile tests/java_menu/tests_navigation_spec.lua" -c qa!

local tests_mod = require("java_menu.tests")
local fixtures = require("tests.java_menu.fixtures")

local real_notify = vim.notify
local real_select = vim.ui.select
local real_get_clients = vim.lsp.get_clients

local notices = {}
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = tostring(msg), level = level }
end
local function last_notice()
  return notices[#notices]
end
local function clear_notices()
  notices = {}
end

local captured_select = {}
local function stub_select(chooser)
  vim.ui.select = function(items, opts, on_choice)
    captured_select[#captured_select + 1] = {
      items = vim.deepcopy(items),
      prompt = opts and opts.prompt or "",
    }
    local choice = type(chooser) == "function" and chooser(items, opts) or chooser
    on_choice(choice)
  end
end

local function canonical(path)
  local norm = vim.fs.normalize(path)
  return vim.fs.normalize(vim.uv.fs_realpath(norm) or norm)
end

local function open_java_buf(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "java"
  return buf
end

local function find_line(lines, needle)
  for idx, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return idx, line
    end
  end
  return nil, nil
end

local temp_dirs = {}
local function track(dir)
  temp_dirs[#temp_dirs + 1] = dir
  return dir
end

-- ---------- 1. Single-module bidirectional & naming conventions ----------

local single_root, foo_main = fixtures.maven_project("nav-single", "com.acme", "Foo")
track(single_root)
local foo_test = single_root .. "/src/test/java/com/acme/FooTest.java"
fixtures.write(foo_test, { "package com.acme;", "", "public class FooTest {}" })

local bar_main = fixtures.java_file(single_root, "com.acme", "Bar", "")
local bar_tests = single_root .. "/src/test/java/com/acme/BarTests.java"
fixtures.write(bar_tests, { "package com.acme;", "", "public class BarTests {}" })

local baz_main = fixtures.java_file(single_root, "com.acme", "Baz", "")
local baz_it = single_root .. "/src/test/java/com/acme/BazIT.java"
fixtures.write(baz_it, { "package com.acme;", "", "public class BazIT {}" })

local qux_main = fixtures.java_file(single_root, "com.acme", "Qux", "")
local qux_test = single_root .. "/src/test/java/com/acme/TestQux.java"
fixtures.write(qux_test, { "package com.acme;", "", "public class TestQux {}" })

-- Class named TestHelper in src/main/java must still resolve to_test (not to_class)
local helper_main = fixtures.java_file(single_root, "com.acme", "TestHelper", "")

-- Default package (no package directory)
local def_main = single_root .. "/src/main/java/App.java"
local def_test = single_root .. "/src/test/java/AppTest.java"
fixtures.write(def_main, { "public class App {}" })
fixtures.write(def_test, { "public class AppTest {}" })

-- Foo <-> FooTest direct jump (no picker)
captured_select = {}
stub_select(nil)
open_java_buf(foo_main)
tests_mod._goto_counterpart(vim.api.nvim_get_current_buf(), single_root)
assert(
  canonical(vim.api.nvim_buf_get_name(0)) == canonical(foo_test),
  "Foo.java should jump directly to FooTest.java, got " .. vim.api.nvim_buf_get_name(0)
)
assert(#captured_select == 0, "unambiguous match should not open picker")

tests_mod._goto_counterpart(vim.api.nvim_get_current_buf(), single_root)
assert(
  canonical(vim.api.nvim_buf_get_name(0)) == canonical(foo_main),
  "FooTest.java should jump back to Foo.java, got " .. vim.api.nvim_buf_get_name(0)
)

-- Bar <-> BarTests, Baz <-> BazIT, Qux <-> TestQux, App <-> AppTest
for _, pair in ipairs({
  { bar_main, bar_tests, "BarTests" },
  { baz_main, baz_it, "BazIT" },
  { qux_main, qux_test, "TestQux" },
  { def_main, def_test, "AppTest" },
}) do
  open_java_buf(pair[1])
  tests_mod._goto_counterpart(0, single_root)
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(pair[2]), pair[1] .. " failed to jump to " .. pair[3])
  tests_mod._goto_counterpart(0, single_root)
  assert(
    canonical(vim.api.nvim_buf_get_name(0)) == canonical(pair[1]),
    pair[3] .. " failed to jump back to " .. pair[1]
  )
end

local helper_nav = tests_mod._resolve_counterpart(helper_main, single_root)
assert(helper_nav.direction == "to_test", "TestHelper in src/main/java should resolve to_test")
assert(helper_nav.default_name == "TestHelperTest", "TestHelper default test name should be TestHelperTest")

-- ---------- 2. Ambiguous counterpart in same module ----------

local multi_main = fixtures.java_file(single_root, "com.acme", "Multi", "")
local multi_test = single_root .. "/src/test/java/com/acme/MultiTest.java"
local multi_it = single_root .. "/src/test/java/com/acme/MultiIT.java"
fixtures.write(multi_test, { "package com.acme;", "", "public class MultiTest {}" })
fixtures.write(multi_it, { "package com.acme;", "", "public class MultiIT {}" })

local multi_nav = tests_mod._resolve_counterpart(multi_main, single_root)
assert(multi_nav.status == "ambiguous" and #multi_nav.matches == 2, "Multi.java should detect ambiguous counterparts")

-- Canceling ambiguous picker keeps current buffer
open_java_buf(multi_main)
captured_select = {}
stub_select(nil)
tests_mod._goto_counterpart(0, single_root)
assert(#captured_select == 1, "ambiguous counterpart should prompt picker")
assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(multi_main), "cancel should keep current buffer")

-- Picking MultiIT opens MultiIT.java
stub_select(function(items)
  for _, item in ipairs(items) do
    if item:find("MultiIT", 1, true) then
      return item
    end
  end
end)
tests_mod._goto_counterpart(0, single_root)
assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(multi_it), "selecting MultiIT should open MultiIT.java")

-- ---------- 3. Missing counterpart (safe non-destructive behavior) ----------

local lonely_main = fixtures.java_file(single_root, "com.lonely", "Lonely", "")
local scenario_test = single_root .. "/src/test/java/com/lonely/ScenarioTest.java"
fixtures.write(scenario_test, { "package com.lonely;", "", "public class ScenarioTest {}" })
local lonely_expected_test = single_root .. "/src/test/java/com/lonely/LonelyTest.java"

-- Cancel on missing to_test must NOT create LonelyTest.java on disk
open_java_buf(lonely_main)
captured_select = {}
stub_select(nil)
tests_mod._goto_counterpart(0, single_root)
assert(#captured_select == 1, "missing test counterpart should prompt instead of writing blindly")
assert(vim.fn.filereadable(lonely_expected_test) == 0, "canceling missing test prompt must not create LonelyTest.java")
local missing_opts = table.concat(captured_select[1].items, "\n")
assert(missing_opts:find("Create com.lonely.LonelyTest", 1, true), "picker should offer Create LonelyTest")
assert(missing_opts:find("Open com.lonely.ScenarioTest", 1, true), "picker should offer package test ScenarioTest")

-- Confirming Create writes a valid JUnit 5 test file and marks jc_new_java_file
stub_select(function(items)
  for _, item in ipairs(items) do
    if item:find("Create ", 1, true) then
      return item
    end
  end
end)
tests_mod._goto_counterpart(0, single_root)
assert(vim.fn.filereadable(lonely_expected_test) == 1, "confirming Create should write LonelyTest.java")
assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(lonely_expected_test), "buffer should be LonelyTest.java")
assert(vim.b.jc_new_java_file == true, "new test file should set vim.b.jc_new_java_file")
local created_lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(created_lines:find("package com.lonely;", 1, true), "created test should include package declaration")
assert(created_lines:find("class LonelyTest", 1, true), "created test should declare LonelyTest")

-- Another process may create the file while the picker is open. Keep it intact.
local race_main = fixtures.java_file(single_root, "com.race", "Race", "")
local race_test = single_root .. "/src/test/java/com/race/RaceTest.java"
open_java_buf(race_main)
stub_select(function(items)
  fixtures.write(race_test, { "// created by another process" })
  for _, item in ipairs(items) do
    if item:find("Create ", 1, true) then
      return item
    end
  end
end)
tests_mod._goto_counterpart(0, single_root)
assert(vim.fn.readfile(race_test)[1] == "// created by another process", "existing test must not be overwritten")

local unsaved_main = fixtures.java_file(single_root, "com.race", "Unsaved", "")
local unsaved_test = single_root .. "/src/test/java/com/race/UnsavedTest.java"
vim.cmd("edit " .. vim.fn.fnameescape(unsaved_test))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved user content" })
local unsaved_buf = vim.api.nvim_get_current_buf()
vim.cmd("hide edit " .. vim.fn.fnameescape(unsaved_main))
tests_mod._goto_counterpart(0, single_root)
assert(vim.api.nvim_get_current_buf() == unsaved_buf, "should open the existing unsaved buffer")
assert(
  vim.api.nvim_buf_get_lines(unsaved_buf, 0, 1, false)[1] == "unsaved user content",
  "must preserve unsaved content"
)
assert(vim.fn.filereadable(unsaved_test) == 0, "must not write over an unsaved buffer")
vim.bo[unsaved_buf].modified = false

-- Missing to_class must NEVER create a production class on disk
local orphan_test = single_root .. "/src/test/java/com/lonely/OrphanTest.java"
local orphan_expected_main = single_root .. "/src/main/java/com/lonely/Orphan.java"
fixtures.write(orphan_test, { "package com.lonely;", "", "public class OrphanTest {}" })
open_java_buf(orphan_test)
clear_notices()
tests_mod._goto_counterpart(0, single_root)
assert(vim.fn.filereadable(orphan_expected_main) == 0, "to_class missing must never create Orphan.java")
assert(
  last_notice() and last_notice().msg:find("no matching class in src/main/java", 1, true),
  "missing class should notify clearly: " .. tostring(last_notice() and last_notice().msg)
)

-- Helper inside src/test/java without test prefix/suffix
local test_fixture = single_root .. "/src/test/java/com/lonely/DataBuilder.java"
fixtures.write(test_fixture, { "package com.lonely;", "", "public class DataBuilder {}" })
local fixture_nav = tests_mod._resolve_counterpart(test_fixture, single_root)
assert(
  fixture_nav.status == "missing" and fixture_nav.default_fqn == nil,
  "DataBuilder without counterpart should be missing without expected FQN"
)

-- File outside src/main/java and src/test/java
local scratch_java = single_root .. "/Scratch.java"
fixtures.write(scratch_java, { "public class Scratch {}" })
local scratch_nav = tests_mod._resolve_counterpart(scratch_java, single_root)
assert(
  not scratch_nav.resolvable and scratch_nav.reason:find("src/main/java or src/test/java", 1, true),
  "Scratch.java should not be resolvable"
)
open_java_buf(scratch_java)
clear_notices()
tests_mod._goto_counterpart(0, single_root)
assert(
  vim.fn.filereadable(single_root .. "/ScratchTest.java") == 0,
  "non-source-root file must not create ScratchTest.java"
)

-- ---------- 4. Multi-module resolution & prioritization ----------

local mm_root = track(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-mm-nav"))
fixtures.write(mm_root .. "/pom.xml", {
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>com.mm</groupId>",
  "  <artifactId>root</artifactId>",
  "  <version>1.0</version>",
  "  <packaging>pom</packaging>",
  "  <modules>",
  "    <module>services/api</module>",
  "    <module>services/worker</module>",
  "    <module>integration-tests</module>",
  "  </modules>",
  "</project>",
})
for _, mod in ipairs({ "services/api", "services/worker", "integration-tests" }) do
  fixtures.write(mm_root .. "/" .. mod .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.mm</groupId>",
    "  <artifactId>" .. vim.fs.basename(mod) .. "</artifactId>",
    "  <version>1.0</version>",
    "</project>",
  })
end

local api_thing = mm_root .. "/services/api/src/main/java/com/mm/Thing.java"
local api_thing_test = mm_root .. "/services/api/src/test/java/com/mm/ThingTest.java"
local api_other_test = mm_root .. "/services/api/src/test/java/com/mm/other/OtherTest.java"
local api_unique = mm_root .. "/services/api/src/main/java/com/mm/UniqueFeature.java"

local worker_thing = mm_root .. "/services/worker/src/main/java/com/mm/Thing.java"
local worker_thing_test = mm_root .. "/services/worker/src/test/java/com/mm/ThingTest.java"

local it_unique = mm_root .. "/integration-tests/src/test/java/com/mm/UniqueFeatureIT.java"
local it_thing = mm_root .. "/integration-tests/src/test/java/com/mm/ThingIT.java"

-- Undeclared rogue module must be ignored
local rogue_test = mm_root .. "/rogue/src/test/java/com/mm/RogueTest.java"
fixtures.write(mm_root .. "/rogue/pom.xml", { "<project/>" })
fixtures.write(rogue_test, { "package com.mm;", "", "public class RogueTest {}" })

for _, p in ipairs({
  api_thing,
  api_thing_test,
  api_other_test,
  api_unique,
  worker_thing,
  worker_thing_test,
  it_unique,
  it_thing,
}) do
  fixtures.write(p, { "// " .. vim.fs.basename(p) })
end

-- Same-name class in api and worker stays module-isolated
local api_nav = tests_mod._resolve_counterpart(api_thing, mm_root)
assert(
  api_nav.status == "match" and canonical(api_nav.target) == canonical(api_thing_test),
  "api Thing should resolve to api ThingTest"
)

local worker_nav = tests_mod._resolve_counterpart(worker_thing_test, mm_root)
assert(
  worker_nav.status == "match" and canonical(worker_nav.target) == canonical(worker_thing),
  "worker ThingTest should resolve to worker Thing"
)

-- Cross-module to_class with unique match jumps directly and informs module
open_java_buf(it_unique)
clear_notices()
tests_mod._goto_counterpart(0, mm_root)
assert(
  canonical(vim.api.nvim_buf_get_name(0)) == canonical(api_unique),
  "UniqueFeatureIT should jump across modules to UniqueFeature"
)
assert(
  last_notice() and last_notice().msg:find("services/api", 1, true),
  "cross-module jump should report module: " .. tostring(last_notice() and last_notice().msg)
)

-- Cross-module to_class with multiple modules (api + worker) prompts picker
open_java_buf(it_thing)
captured_select = {}
stub_select(function(items)
  for _, item in ipairs(items) do
    if item:find("services/worker", 1, true) then
      return item
    end
  end
end)
tests_mod._goto_counterpart(0, mm_root)
assert(#captured_select == 1, "cross-module ambiguous to_class should open picker")
assert(
  canonical(vim.api.nvim_buf_get_name(0)) == canonical(worker_thing),
  "picker choice should open worker Thing.java"
)

-- Cross-module to_test offers Open from other module AND Create in current module
open_java_buf(api_unique)
captured_select = {}
stub_select(nil)
tests_mod._goto_counterpart(0, mm_root)
assert(#captured_select == 1, "cross-module to_test should prompt")
local cross_opts = table.concat(captured_select[1].items, "\n")
assert(cross_opts:find("Open integration-tests · com.mm.UniqueFeatureIT", 1, true), "should offer other-module test")
assert(
  cross_opts:find("Create services/api · com.mm.UniqueFeatureTest", 1, true),
  "should offer creating in current module"
)
assert(
  vim.fn.filereadable(mm_root .. "/services/api/src/test/java/com/mm/UniqueFeatureTest.java") == 0,
  "cancel must not create file"
)

-- Context-aware test_files: declared modules only, disambiguated labels, tier ordering
local listed = tests_mod._test_files(mm_root, api_thing)
assert(#listed == 5, "expected 5 declared test files (excluding rogue), got " .. #listed)
for _, item in ipairs(listed) do
  assert(not item.label:find("RogueTest", 1, true), "undeclared rogue module must not be listed")
end
assert(
  listed[1].label == "services/api · com.mm.ThingTest",
  "tier 1 should prioritize same module + same package: " .. listed[1].label
)
assert(
  listed[2].label == "services/api · com.mm.other.OtherTest",
  "tier 2 should prioritize same module: " .. listed[2].label
)

-- ---------- 5. Contextual <leader>jt menu, defaults & reason consistency ----------

-- Outside project: clear warning
local empty_dir = track(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-empty"))
vim.fn.mkdir(empty_dir, "p")
local empty_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(empty_buf, empty_dir .. "/Loose.java")
vim.bo[empty_buf].filetype = "java"
vim.api.nvim_set_current_buf(empty_buf)
clear_notices()
tests_mod.tests()
assert(
  last_notice() and last_notice().msg:find("no Maven/Gradle project", 1, true),
  "outside project should warn clearly"
)

-- Stub neotest, jc.test, and jdtls client for menu tests
local ran_targets = {}
package.loaded["neotest"] = {
  run = {
    run = function(args)
      ran_targets[#ran_targets + 1] = args
    end,
    run_last = function() end,
    stop = function() end,
  },
  summary = { open = function() end },
  output = { open = function() end },
}
local jc_ran = {}
package.loaded["jc"] = { config = { test = { precompile = false } } }
package.loaded["jc.test"] = {
  run_at_cursor = function()
    jc_ran[#jc_ran + 1] = "nearest"
  end,
  run_file = function()
    jc_ran[#jc_ran + 1] = "file"
  end,
  run_all = function()
    jc_ran[#jc_ran + 1] = "all"
  end,
  run_last = function() end,
  stop = function() end,
  summary = function() end,
  output = function() end,
  toggle_precompile = function() end,
  _nothing_to_run = function()
    return true
  end,
  _package_tests = function()
    return {}
  end,
}

-- (a) Non-Java file (pom.xml) with jdtls attached: Suite/Pick promoted first;
--     consistent "open a .java file" reason on nearest/file/goto_test.
vim.lsp.get_clients = function(filter)
  if filter and filter.bufnr then
    return { { id = 1, name = "jdtls" } }
  end
  return { { id = 1, name = "jdtls" } }
end

vim.cmd("edit " .. vim.fn.fnameescape(mm_root .. "/services/api/pom.xml"))
vim.bo[0].filetype = "xml"
captured_select = {}
stub_select(nil)
tests_mod.tests()
assert(#captured_select == 1, "menu should open for pom.xml")
assert(
  captured_select[1].prompt == "Java: Tests — services/api",
  "prompt should reflect module: " .. captured_select[1].prompt
)
local pom_items = captured_select[1].items
assert(
  pom_items[1]:find("^Run Test Suite  %(module: services/api%)"),
  "non-Java buffer should prioritize Run Test Suite: " .. pom_items[1]
)
assert(pom_items[2]:find("^Pick Test"), "second entry on non-Java buffer should be Pick Test: " .. pom_items[2])
local _, nearest_pom = find_line(pom_items, "Run Nearest Test")
assert(
  nearest_pom and nearest_pom:find("(unavailable: open a .java file)", 1, true),
  "nearest reason should be consistent: " .. tostring(nearest_pom)
)
local _, file_pom = find_line(pom_items, "Run Test File")
assert(
  file_pom and file_pom:find("(unavailable: open a .java file)", 1, true),
  "file reason should be consistent: " .. tostring(file_pom)
)
local _, goto_pom = find_line(pom_items, "Go to Test / Class")
assert(
  goto_pom and goto_pom:find("(unavailable: open a .java file)", 1, true),
  "goto_test reason should be consistent: " .. tostring(goto_pom)
)

-- (b) Java buffer WITHOUT jdtls attached: Go to Test/Class promoted to #1 and works!
vim.lsp.get_clients = function()
  return {}
end
open_java_buf(api_thing)
captured_select = {}
stub_select(function(items)
  return items[1]
end)
tests_mod.tests()
assert(
  captured_select[1].items[1]:find("^Go to Test  %(ThingTest%)"),
  "when jdtls is detached, Go to Test should be promoted to #1: " .. captured_select[1].items[1]
)
assert(
  canonical(vim.api.nvim_buf_get_name(0)) == canonical(api_thing_test),
  "selecting promoted #1 Go to Test should jump to ThingTest"
)

-- (c) Java buffer WITH jdtls attached: Run Nearest is #1, Go to Class is #3,
--     and Bar.java runs BarTests.java via neotest!
vim.lsp.get_clients = function()
  return { { id = 1, name = "jdtls" } }
end
open_java_buf(api_thing_test)
captured_select = {}
stub_select(nil)
tests_mod.tests()
local test_items = captured_select[1].items
assert(test_items[1]:find("^Run Nearest Test$"), "Java test buffer #1 should be Run Nearest Test: " .. test_items[1])
assert(test_items[2]:find("^Run Test File$"), "Java test buffer #2 should be Run Test File: " .. test_items[2])
assert(
  test_items[3]:find("^Go to Class  %(Thing%)$"),
  "Java test buffer #3 should be Go to Class (Thing): " .. test_items[3]
)

-- Missing source class disables Go to Class with clear reason
open_java_buf(orphan_test)
captured_select = {}
stub_select(nil)
tests_mod.tests()
local _, orphan_goto = find_line(captured_select[1].items, "Go to Class")
assert(
  orphan_goto and orphan_goto:find("(unavailable: no matching class in src/main/java (com.lonely.Orphan))", 1, true),
  "missing source class should disable Go to Class with reason: " .. tostring(orphan_goto)
)

-- Running Nearest/File on Bar.java picks up BarTests.java instead of failing
open_java_buf(bar_main)
ran_targets = {}
jc_ran = {}
stub_select(function(items)
  return items[1] -- Run Nearest Test
end)
tests_mod.tests()
assert(jc_ran[1] == "file", "Run Nearest on Bar.java should dispatch through jc's lifecycle")

-- Scratch/output buffer must not guess a project from unrelated buffers.
local scratch_out = vim.api.nvim_create_buf(false, true)
vim.bo[scratch_out].buftype = "nofile"
vim.api.nvim_set_current_buf(scratch_out)
captured_select = {}
clear_notices()
stub_select(nil)
tests_mod.tests()
assert(#captured_select == 0, "nofile context must not guess a project")
assert(
  last_notice() and last_notice().msg:find("open a project file", 1, true),
  "nofile context should explain how to proceed"
)

-- ---------- cleanup ----------

vim.notify = real_notify
vim.ui.select = real_select
vim.lsp.get_clients = real_get_clients
package.loaded["neotest"] = nil
package.loaded["jc.test"] = nil
package.loaded["jc"] = nil

for _, dir in ipairs(temp_dirs) do
  vim.fn.delete(dir, "rf")
end

print("tests_navigation_spec: OK")
vim.cmd("qa!")
