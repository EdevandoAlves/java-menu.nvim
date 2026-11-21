-- Integration (Issue #4): real Gradle multi-module discovery, module selection,
-- real task execution through java_menu.build, failure reporting, and project
-- isolation.
--
-- Runs completely offline using Gradle's built-in `base` / `java` plugins and an
-- isolated temporary GRADLE_USER_HOME (with daemon disabled). Never touches
-- user projects, user ~/.gradle, or external processes.
--
-- Skips honestly with `[SPEC_SKIP] build_gradle_real_spec: <reason>` and exits
-- 0 when `gradle` or a JDK (`javac`) is missing from PATH/JAVA_HOME.
--
-- Run:
--   tests/java_menu/run.sh integration

local SPEC_NAME = "build_gradle_real_spec"

local temp_dirs = {}
local function new_tempdir(label)
  local dir = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-gradle-real-" .. label)
  vim.fn.mkdir(dir, "p")
  temp_dirs[#temp_dirs + 1] = dir
  return dir
end

local function cleanup_dirs()
  for _, dir in ipairs(temp_dirs) do
    pcall(vim.fn.delete, dir, "rf")
  end
end

local function skip(reason)
  cleanup_dirs()
  io.stdout:write(string.format("[SPEC_SKIP] %s: %s\n", SPEC_NAME, tostring(reason)))
  io.stdout:flush()
  vim.cmd("qa!")
end

local function has_jdk()
  if vim.fn.executable("javac") == 1 and vim.fn.executable("java") == 1 then
    return true
  end
  local home = vim.env.JAVA_HOME
  if home and home ~= "" then
    return vim.fn.executable(home .. "/bin/javac") == 1 and vim.fn.executable(home .. "/bin/java") == 1
  end
  return false
end

if vim.fn.executable("gradle") ~= 1 then
  return skip("gradle executable not found in PATH")
end
if not has_jdk() then
  return skip("JDK (javac/java) not found in PATH or JAVA_HOME")
end

local ui = require("java_menu.ui")
local project = require("java_menu.project")
local build = require("java_menu.build")
local run_config = require("java_menu.run_config")
local fixtures = require("tests.java_menu.fixtures")

local gradle_user_home = new_tempdir("gradle-home")
local run_data_dir = new_tempdir("run-data")

local prev_gradle_user_home = vim.env.GRADLE_USER_HOME
local prev_base_dir = run_config._base_dir
local prev_jc_settings = package.loaded["jc.settings"]
local real_notify = ui.notify
local real_ask = ui.ask
local real_menu = ui.menu
local real_pick_one = ui.pick_one

local function restore_env()
  if build._state.running or build._is_draining() then
    pcall(build.stop, true)
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end)
  end
  vim.env.GRADLE_USER_HOME = prev_gradle_user_home
  run_config._base_dir = prev_base_dir
  package.loaded["jc.settings"] = prev_jc_settings
  ui.notify = real_notify
  ui.ask = real_ask
  ui.menu = real_menu
  ui.pick_one = real_pick_one
  cleanup_dirs()
end

local function run_spec()
  vim.env.GRADLE_USER_HOME = gradle_user_home
  fixtures.write(gradle_user_home .. "/gradle.properties", {
    "org.gradle.daemon=false",
    "org.gradle.welcome=never",
  })

  run_config._base_dir = run_data_dir

  local jcstore = {}
  package.loaded["jc.settings"] = {
    read_project = function(name)
      return jcstore[name]
    end,
    write_project = function(name, value)
      jcstore[name] = value
    end,
  }

  local notices = {}
  local menu_entries, menu_cb
  local pick_script = {}
  local ask_script = {}
  local pick_history = {}

  ui.notify = function(msg, level)
    notices[#notices + 1] = { msg = tostring(msg), level = level }
  end
  ui.menu = function(entries, _, on_choice)
    menu_entries, menu_cb = entries, on_choice
  end
  ui.pick_one = function(items, prompt, on_choice)
    pick_history[#pick_history + 1] = { prompt = prompt, items = vim.deepcopy(items) }
    local want = table.remove(pick_script, 1)
    assert(want ~= nil, "unexpected ui.pick_one(" .. tostring(prompt) .. "): " .. vim.inspect(items))
    if want == false then
      return
    end
    for _, item in ipairs(items) do
      if item == want or item:find(want, 1, true) then
        return on_choice(item)
      end
    end
    error("stub pick_one: no item matched '" .. tostring(want) .. "' in " .. vim.inspect(items))
  end
  ui.ask = function(prompt, _, on_confirm)
    local val = table.remove(ask_script, 1)
    assert(val ~= nil, "unexpected ui.ask(" .. tostring(prompt) .. ")")
    if val == false then
      return on_confirm(nil)
    end
    return on_confirm(val)
  end

  local function entry(key)
    for _, item in ipairs(menu_entries or {}) do
      if item.key == key then
        return item
      end
    end
  end

  local function open_file(path)
    pcall(vim.cmd, "silent! only")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "java"
  end

  local function buf_text(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return ""
    end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function wait_build(timeout_ms, label)
    local finished = fixtures.wait_for(timeout_ms or 180000, function()
      return not build._state.running and not build._is_draining()
    end)
    local out = buf_text(build._state.last_output)
    assert(finished, label .. " did not finish in time; output:\n" .. out)
    return out
  end

  -- ---------- Fixtures: Project A (multi-module) and Project B (single-module) ----------

  local root_a = new_tempdir("alpha")
  fixtures.write(root_a .. "/settings.gradle", {
    "rootProject.name = 'gradle-alpha'",
    "include(':libs:core')",
    "include(':services:api')",
    "include(':services:worker')",
    "include(':custom')",
    "project(':custom').projectDir = file('libs/custom-dir')",
  })
  fixtures.write(root_a .. "/gradle.properties", {
    "org.gradle.daemon=false",
    "org.gradle.welcome=never",
  })
  fixtures.write(root_a .. "/build.gradle", {
    "plugins {",
    "  id 'base'",
    "}",
    "",
    "tasks.register('holdForStop') {",
    "  doLast {",
    "    Thread.sleep(60000)",
    "  }",
    "}",
  })
  fixtures.write(root_a .. "/libs/core/build.gradle", {
    "plugins {",
    "  id 'java'",
    "}",
  })
  fixtures.write(root_a .. "/libs/core/src/main/java/com/demo/core/Greeting.java", {
    "package com.demo.core;",
    "",
    "public class Greeting {",
    "  public static String message() {",
    '    return "hello-from-core";',
    "  }",
    "}",
  })
  fixtures.write(root_a .. "/libs/custom-dir/build.gradle", {
    "plugins {",
    "  id 'java'",
    "}",
  })
  fixtures.write(root_a .. "/libs/custom-dir/src/main/java/com/demo/custom/CustomTag.java", {
    "package com.demo.custom;",
    "",
    "public class CustomTag {",
    "  public static String tag() {",
    '    return "custom-tag";',
    "  }",
    "}",
  })
  fixtures.write(root_a .. "/services/api/build.gradle", {
    "plugins {",
    "  id 'java'",
    "}",
    "",
    "dependencies {",
    "  implementation project(':libs:core')",
    "}",
  })
  fixtures.write(root_a .. "/services/api/src/main/java/com/demo/api/ApiApp.java", {
    "package com.demo.api;",
    "",
    "import com.demo.core.Greeting;",
    "",
    "public class ApiApp {",
    "  public static String run() {",
    '    return Greeting.message() + ":api";',
    "  }",
    "}",
  })
  fixtures.write(root_a .. "/services/worker/build.gradle", {
    "plugins {",
    "  id 'java'",
    "}",
  })
  fixtures.write(root_a .. "/services/worker/src/main/java/com/demo/worker/WorkerApp.java", {
    "package com.demo.worker;",
    "",
    "public class WorkerApp {",
    "  public static String kind() {",
    '    return "worker";',
    "  }",
    "}",
  })

  local root_b = new_tempdir("beta")
  fixtures.write(root_b .. "/settings.gradle", {
    "rootProject.name = 'gradle-beta'",
  })
  fixtures.write(root_b .. "/gradle.properties", {
    "org.gradle.daemon=false",
    "org.gradle.welcome=never",
  })
  fixtures.write(root_b .. "/build.gradle", {
    "plugins {",
    "  id 'java'",
    "}",
  })
  fixtures.write(root_b .. "/src/main/java/com/demo/beta/BetaApp.java", {
    "package com.demo.beta;",
    "",
    "public class BetaApp {",
    "  public static String name() {",
    '    return "beta";',
    "  }",
    "}",
  })

  local real_root_a = vim.uv.fs_realpath(root_a)
  local real_root_b = vim.uv.fs_realpath(root_b)
  local canon_root_a = run_config.canonical(root_a)
  local canon_root_b = run_config.canonical(root_b)

  -- ---------- 1. Multi-module selection & real compileJava on :services:api ----------

  local api_main = root_a .. "/services/api/src/main/java/com/demo/api/ApiApp.java"
  open_file(api_main)
  assert(project.root(0) == real_root_a, "expected Project A root, got " .. tostring(project.root(0)))

  local tool_a = build._build_tool(real_root_a)
  assert(
    tool_a and tool_a.tool == "gradle" and tool_a.runner == "gradle",
    "expected gradle runner on PATH, got " .. vim.inspect(tool_a)
  )

  build.build()
  assert(entry("choose_goal").enabled, "Choose Goal should be enabled for Gradle")
  assert(entry("clean").enabled, "Clean should be enabled for Gradle")
  assert(entry("repeat").enabled == false, "Repeat should be disabled before first build in Project A")

  ask_script = { "compileJava --offline --no-daemon" }
  pick_script = { "services/api" }
  menu_cb(entry("choose_goal"))

  assert(build._state.running, "Gradle build did not start for :services:api")
  assert(build._state.cwd == real_root_a, "Gradle build cwd diverged from Project A root")
  assert(
    vim.deep_equal(build._state.cmd, { "gradle", ":services:api:compileJava", "--offline", "--no-daemon" }),
    "unexpected scoped Gradle command: " .. vim.inspect(build._state.cmd)
  )

  local last_pick = pick_history[#pick_history]
  assert(last_pick and last_pick.prompt == "Java: Build — module", "expected module picker prompt")
  assert(
    last_pick.items[1] == "services/api  (current module)",
    "expected current module first in picker, got " .. vim.inspect(last_pick.items)
  )
  assert(vim.tbl_contains(last_pick.items, "entire project"), "missing 'entire project' in picker")
  assert(vim.tbl_contains(last_pick.items, "libs/core"), "missing 'libs/core' in picker")
  assert(vim.tbl_contains(last_pick.items, "libs/custom-dir"), "missing 'libs/custom-dir' in picker")
  assert(vim.tbl_contains(last_pick.items, "services/worker"), "missing 'services/worker' in picker")

  local out_api = wait_build(180000, ":services:api:compileJava")
  assert(build._state.status == "success", ":services:api:compileJava failed:\n" .. out_api)
  assert(
    out_api:find("$ gradle :services:api:compileJava --offline --no-daemon", 1, true),
    "output buffer missing executed Gradle command:\n" .. out_api
  )
  assert(
    vim.fn.filereadable(root_a .. "/services/api/build/classes/java/main/com/demo/api/ApiApp.class") == 1,
    "ApiApp.class was not compiled by real Gradle"
  )
  assert(
    vim.fn.filereadable(root_a .. "/libs/core/build/classes/java/main/com/demo/core/Greeting.class") == 1,
    "Greeting.class dependency (:libs:core) was not compiled by real Gradle"
  )
  assert(
    vim.fn.isdirectory(root_a .. "/services/worker/build") == 0,
    "unrelated module :services:worker should not be built when scoped to :services:api"
  )
  assert(
    vim.fn.isdirectory(root_a .. "/libs/custom-dir/build") == 0,
    "unrelated module :custom should not be built when scoped to :services:api"
  )
  assert(
    #vim.fn.readdir(gradle_user_home) > 1,
    "isolated GRADLE_USER_HOME was not used by Gradle: " .. vim.inspect(vim.fn.readdir(gradle_user_home))
  )

  -- ---------- 2. Custom projectDir logical mapping (:custom -> libs/custom-dir) ----------

  build.build()
  assert(entry("repeat").enabled == true, "Repeat should be enabled after first build in Project A")
  ask_script = { "classes --offline --no-daemon" }
  pick_script = { "libs/custom-dir" }
  menu_cb(entry("choose_goal"))

  assert(
    vim.deep_equal(build._last_runs[canon_root_a].cmd, { "gradle", ":custom:classes", "--offline", "--no-daemon" }),
    "projectDir module should map to logical :custom task, got " .. vim.inspect(build._last_runs[canon_root_a].cmd)
  )
  local out_custom = wait_build(180000, ":custom:classes")
  assert(build._state.status == "success", ":custom:classes failed:\n" .. out_custom)
  assert(
    vim.fn.filereadable(root_a .. "/libs/custom-dir/build/classes/java/main/com/demo/custom/CustomTag.class") == 1,
    "CustomTag.class was not compiled via logical path :custom"
  )
  assert(
    vim.fn.isdirectory(root_a .. "/services/worker/build") == 0,
    "unrelated module :services:worker should still be unbuilt"
  )

  -- ---------- 3. Cross-project Repeat & Output isolation (Project B vs Project A) ----------

  local beta_main = root_b .. "/src/main/java/com/demo/beta/BetaApp.java"
  open_file(beta_main)
  assert(project.root(0) == real_root_b, "expected Project B root, got " .. tostring(project.root(0)))

  build.build()
  local repeat_b = entry("repeat")
  assert(repeat_b.enabled == false, "Repeat should be disabled in Project B despite Project A history")
  assert(
    repeat_b.reason:find("no previous build", 1, true),
    "unexpected Repeat reason in Project B: " .. repeat_b.reason
  )
  assert(
    entry("output").label:find(vim.fs.basename(real_root_a), 1, true),
    "Show Last Output should still identify Project A: " .. entry("output").label
  )

  local picks_before_b = #pick_history
  ask_script = { "jar --offline --no-daemon" }
  menu_cb(entry("choose_goal"))
  assert(#pick_history == picks_before_b, "single-module Project B should not prompt for module selection")

  local out_beta = wait_build(180000, "Project B jar")
  assert(build._state.status == "success", "Project B jar failed:\n" .. out_beta)
  local jars = vim.fn.glob(real_root_b .. "/build/libs/*.jar", false, true)
  assert(type(jars) == "table" and #jars >= 1, "Project B jar artifact missing under build/libs")
  assert(
    vim.deep_equal(build._last_runs[canon_root_b].cmd, { "gradle", "jar", "--offline", "--no-daemon" }),
    "Project B last run diverged: " .. vim.inspect(build._last_runs[canon_root_b].cmd)
  )

  open_file(api_main)
  build.build()
  assert(
    entry("output").label:find(vim.fs.basename(real_root_b), 1, true),
    "Show Last Output should identify Project B before Repeat: " .. entry("output").label
  )
  menu_cb(entry("repeat"))
  assert(build._state.cwd == real_root_a, "Repeat in Project A ran in wrong cwd")
  assert(
    vim.deep_equal(build._last_runs[canon_root_a].cmd, { "gradle", ":custom:classes", "--offline", "--no-daemon" }),
    "Repeat in Project A used wrong args: " .. vim.inspect(build._last_runs[canon_root_a].cmd)
  )
  local out_repeat = wait_build(180000, "Project A Repeat")
  assert(build._state.status == "success", "Project A Repeat failed:\n" .. out_repeat)

  -- ---------- 4. Built-in Clean menu action on entire Project A ----------

  build.build()
  pick_script = { "entire project" }
  menu_cb(entry("clean"))
  assert(
    vim.deep_equal(build._last_runs[canon_root_a].cmd, { "gradle", "clean" }),
    "Clean menu action produced unexpected cmd: " .. vim.inspect(build._last_runs[canon_root_a].cmd)
  )
  local out_clean = wait_build(180000, "Project A clean")
  assert(build._state.status == "success", "Project A clean failed:\n" .. out_clean)
  assert(vim.fn.isdirectory(root_a .. "/services/api/build") == 0, "services/api/build survived clean")
  assert(vim.fn.isdirectory(root_a .. "/libs/core/build") == 0, "libs/core/build survived clean")
  assert(vim.fn.isdirectory(root_a .. "/libs/custom-dir/build") == 0, "libs/custom-dir/build survived clean")

  -- ---------- 5. Real Gradle compilation failure + quickfix population ----------

  fixtures.write(root_b .. "/src/main/java/com/demo/beta/Broken.java", {
    "package com.demo.beta;",
    "",
    "public class Broken {",
    '  int bad = "not-an-int";',
    "}",
  })
  open_file(beta_main)
  build.build()
  ask_script = { "compileJava --offline --no-daemon" }
  menu_cb(entry("choose_goal"))

  local out_fail = wait_build(180000, "Project B compilation failure")
  assert(build._state.status == "failed", "expected failed status for Broken.java, got " .. build._state.status)
  assert(out_fail:find("falha", 1, true), "output buffer missing failure footer:\n" .. out_fail)
  local qf = vim.fn.getqflist()
  local found_broken_qf = false
  for _, item in ipairs(qf) do
    local fname = item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr) or ""
    if fname:find("Broken.java", 1, true) then
      found_broken_qf = true
      break
    end
  end
  assert(found_broken_qf, "quickfix list did not capture Broken.java error: " .. vim.inspect(qf))

  -- ---------- 6. Cross-project Stop isolation with real running Gradle task ----------

  open_file(api_main)
  build.build()
  ask_script = { "holdForStop --offline --no-daemon" }
  pick_script = { "entire project" }
  menu_cb(entry("choose_goal"))
  assert(build._state.running and build._state.pid ~= nil, "holdForStop Gradle task did not start")

  open_file(beta_main)
  build.build()
  local stop_entry = entry("stop")
  assert(stop_entry.enabled, "Stop should be enabled when Project A process is running")
  assert(
    stop_entry.label:find(vim.fs.basename(real_root_a), 1, true),
    "Stop label should name Project A: " .. stop_entry.label
  )
  assert(stop_entry.reason:find("another project", 1, true), "Stop reason should warn about another project")

  pick_script = { "No" }
  menu_cb(stop_entry)
  assert(build._state.running, "Project A Gradle process was stopped despite choosing No")

  build.build()
  pick_script = { "Yes" }
  menu_cb(entry("stop"))
  local stopped = fixtures.wait_for(15000, function()
    return not build._state.running and not build._is_draining()
  end)
  assert(stopped, "Project A Gradle process did not stop after choosing Yes")
end

local ok, err = xpcall(run_spec, debug.traceback)
restore_env()
if not ok then
  error(err, 0)
end

print(
  SPEC_NAME .. ": OK (multi-module Gradle selection, :services:api, :custom projectDir, clean, repeat, failure, stop)"
)
vim.cmd("qa!")
