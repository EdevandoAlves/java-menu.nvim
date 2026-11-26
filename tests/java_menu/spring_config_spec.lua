-- Open Spring Configuration (spring_config.lua + run_config.scan_profiles + menus).
-- Covers:
--   1. Single-module discovery (application*.{properties,yml,yaml} under
--      src/main/resources and src/main/resources/config) and non-matching filter
--   2. Path/profile/module disambiguation and deterministic ordering
--   3. No Spring execution and no active-value inference
--   4. Multi-module Maven contextual priority, colliding basenames, rogue exclusion
--   5. Multi-module Gradle static discovery and menu availability
--   6. Project boundary enforcement (outward file/dir symlinks, broken symlinks,
--      symlinks into undeclared subprojects, target/build/test exclusions)
--   7. Menu integration (project_menu + build), file open, cancellation, dirty
--      buffer handling, empty project, and non-project / nofile buffers

local jm = require("java_menu")
local run_config = require("java_menu.run_config")
local spring_config = require("java_menu.spring_config")
local project_menu = require("java_menu.project_menu")
local build = require("java_menu.build")
local ui = require("java_menu.ui")
local fixtures = require("tests.java_menu.fixtures")

local temp_dirs = {}
local function tracked(dir)
  temp_dirs[#temp_dirs + 1] = dir
  return dir
end

local data_dir = tracked(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-springcfg-data"))
vim.fn.mkdir(data_dir, "p")
run_config._base_dir = data_dir

local real_notify = ui.notify
local real_pick_one = ui.pick_one
local real_menu = ui.menu
local real_select = vim.ui.select
local real_system = vim.system
local real_jobstart = vim.fn.jobstart

local notices = {}
local picks = {}
local pick_handler = nil
local captured_menu = nil
local captured_menu_cb = nil

ui.notify = function(msg, level)
  notices[#notices + 1] = { msg = tostring(msg), level = level }
end

ui.pick_one = function(items, prompt, on_choice)
  picks[#picks + 1] = { items = vim.deepcopy(items), prompt = prompt }
  local choice = pick_handler and pick_handler(items, prompt) or nil
  on_choice(choice)
end

local function clear_state()
  notices = {}
  picks = {}
  pick_handler = nil
end

local function last_notice()
  return notices[#notices]
end

local function open_buf(path, ft)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, path)
  if ft then
    vim.bo[buf].filetype = ft
  end
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local function canon(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

local function find_menu_entry(entries, key)
  for _, e in ipairs(entries or {}) do
    if e.key == key then
      return e
    end
  end
end

-- ---------- 1. Single-module discovery, filtering & disambiguation ----------

do
  local root, main_path = fixtures.maven_project("springcfg-single", "com.demo", "App")
  tracked(root)

  fixtures.write(root .. "/src/main/resources/application.yml", {
    "spring:",
    "  profiles:",
    "    active: prod",
  })
  fixtures.write(root .. "/src/main/resources/application.properties", { "server.port=8080" })
  fixtures.write(root .. "/src/main/resources/config/application.yaml", { "server:", "  port: 8081" })
  fixtures.write(root .. "/src/main/resources/application-dev.properties", { "debug=true" })
  fixtures.write(root .. "/src/main/resources/application-dev.yml", { "debug: true" })
  fixtures.write(root .. "/src/main/resources/config/application-dev.yaml", { "debug: true" })
  fixtures.write(root .. "/src/main/resources/application_extra.yml", { "extra: true" })

  -- Must NOT be matched
  fixtures.write(root .. "/src/main/resources/bootstrap.yml", { "spring: {}" })
  fixtures.write(root .. "/src/main/resources/application.yml.bak", { "backup: true" })
  fixtures.write(root .. "/src/test/resources/application.yml", { "test: true" })
  fixtures.write(root .. "/target/classes/application.yml", { "compiled: true" })
  fixtures.write(root .. "/src/main/resources/config/nested/application.yml", { "nested: true" })
  vim.fn.mkdir(root .. "/src/main/resources/application-dir.yml", "p")

  -- Persist a saved profile in run_config to prove discover/open does not infer active values
  assert(run_config.save(root, { profile = "dev", jvm_args = "", app_args = "", use_env = true }))

  local exec_calls = 0
  vim.system = function(...)
    exec_calls = exec_calls + 1
    return real_system(...)
  end
  vim.fn.jobstart = function(...)
    exec_calls = exec_calls + 1
    return real_jobstart(...)
  end

  local scan = run_config.scan_profiles(root)
  assert(scan.has_default == true, "expected has_default = true")
  assert(vim.deep_equal(scan.profiles, { "dev" }), "expected only dev profile, got " .. vim.inspect(scan.profiles))
  assert(#scan.files == 7, "expected exactly 7 Spring config files, got " .. #scan.files)

  local buf = open_buf(main_path, "java")
  local disc, disc_err = spring_config.discover(buf)
  assert(disc and disc_err == nil, "discover failed: " .. tostring(disc_err))
  assert(#disc.files == 7, "discover file count mismatch: " .. #disc.files)
  assert(exec_calls == 0, "discover must not execute Spring or external commands")

  local seen_labels = {}
  local labels = {}
  for _, f in ipairs(disc.files) do
    assert(not seen_labels[f.label], "duplicate label: " .. f.label)
    seen_labels[f.label] = true
    assert(not f.label:lower():find("active", 1, true), "must not infer active value in label: " .. f.label)
    assert(not f.label:lower():find("saved", 1, true), "must not mark saved value as active: " .. f.label)
    assert(not f.label:find("prod", 1, true), "must not infer spring.profiles.active=prod: " .. f.label)
    labels[#labels + 1] = f.label
  end

  -- Ordering: defaults (resources before config) -> profile: dev (resources before config) -> other
  assert(
    labels[1] == "default  ·  src/main/resources/application.properties",
    "unexpected first label: " .. tostring(labels[1])
  )
  assert(
    labels[2] == "default  ·  src/main/resources/application.yml",
    "unexpected second label: " .. tostring(labels[2])
  )
  assert(
    labels[3] == "default  ·  src/main/resources/config/application.yaml",
    "unexpected third label: " .. tostring(labels[3])
  )
  assert(
    labels[4] == "profile: dev  ·  src/main/resources/application-dev.properties",
    "unexpected fourth label: " .. tostring(labels[4])
  )
  assert(
    labels[5] == "profile: dev  ·  src/main/resources/application-dev.yml",
    "unexpected fifth label: " .. tostring(labels[5])
  )
  assert(
    labels[6] == "profile: dev  ·  src/main/resources/config/application-dev.yaml",
    "unexpected sixth label: " .. tostring(labels[6])
  )
  assert(
    labels[7] == "other  ·  src/main/resources/application_extra.yml",
    "unexpected seventh label: " .. tostring(labels[7])
  )

  -- Cancel in picker keeps current buffer untouched
  clear_state()
  pick_handler = function()
    return nil
  end
  spring_config.open(buf)
  assert(#picks == 1, "expected 1 picker call")
  assert(picks[1].prompt:find("Spring Configuration", 1, true), "unexpected prompt: " .. tostring(picks[1].prompt))
  assert(vim.api.nvim_get_current_buf() == buf, "cancel must not switch buffer")
  assert(exec_calls == 0, "open/cancel must not execute Spring")

  -- Pick config/application-dev.yaml and open it
  clear_state()
  pick_handler = function(items)
    for _, item in ipairs(items) do
      if item:find("config/application-dev.yaml", 1, true) then
        return item
      end
    end
  end
  spring_config.open(buf)
  assert(
    canon(vim.api.nvim_buf_get_name(0)) == canon(root .. "/src/main/resources/config/application-dev.yaml"),
    "did not open chosen Spring config file: " .. vim.api.nvim_buf_get_name(0)
  )

  vim.system = real_system
  vim.fn.jobstart = real_jobstart
end

-- ---------- 2. Multi-module Maven contextual priority & colliding basenames ----------

do
  local root, mods = fixtures.maven_nested("springcfg-mm")
  tracked(root)

  fixtures.write(root .. "/src/main/resources/application.yml", { "root: true" })
  fixtures.write(mods.api .. "/src/main/resources/application.yml", { "api: true" })
  fixtures.write(mods.api .. "/src/main/resources/config/application-dev.properties", { "api.dev=1" })
  fixtures.write(mods.worker .. "/src/main/resources/application-prod.yaml", { "worker: true" })
  fixtures.write(root .. "/rogue/src/main/resources/application-rogue.yml", { "rogue: true" })

  -- From services/api Java file -> services/api comes first with (current)
  local api_buf = open_buf(mods.api .. "/src/main/java/com/nest/api/Thing.java", "java")
  local disc = assert(spring_config.discover(api_buf))
  assert(disc.multi_module == true, "expected multi_module = true")
  assert(#disc.files == 4, "rogue module must be excluded; got " .. #disc.files)
  assert(
    disc.files[1].label == "services/api (current)  ·  default  ·  services/api/src/main/resources/application.yml",
    "api default should be first: " .. tostring(disc.files[1].label)
  )
  assert(
    disc.files[2].label
      == "services/api (current)  ·  profile: dev  ·  services/api/src/main/resources/config/application-dev.properties",
    "api dev should be second: " .. tostring(disc.files[2].label)
  )
  assert(
    disc.files[3].label == "root  ·  default  ·  src/main/resources/application.yml",
    "root should follow current module: " .. tostring(disc.files[3].label)
  )
  assert(
    disc.files[4].label
      == "services/worker  ·  profile: prod  ·  services/worker/src/main/resources/application-prod.yaml",
    "worker should follow root: " .. tostring(disc.files[4].label)
  )

  -- Switch context to services/worker/pom.xml -> services/worker moves to top
  local worker_pom_buf = open_buf(mods.worker .. "/pom.xml", "xml")
  local w_disc = assert(spring_config.discover(worker_pom_buf))
  assert(
    w_disc.files[1].label
      == "services/worker (current)  ·  profile: prod  ·  services/worker/src/main/resources/application-prod.yaml",
    "worker should be prioritized when editing worker/pom.xml: " .. tostring(w_disc.files[1].label)
  )
  assert(not w_disc.files[3].label:find("(current)", 1, true), "api must no longer be marked current")

  -- From rogue/pom.xml (undeclared subproject) -> rogue is its own isolated project
  local rogue_buf = open_buf(root .. "/rogue/pom.xml", "xml")
  local r_disc = assert(spring_config.discover(rogue_buf))
  assert(#r_disc.files == 1, "rogue project should only see its own file, got " .. #r_disc.files)
  assert(
    r_disc.files[1].label == "profile: rogue  ·  src/main/resources/application-rogue.yml",
    "unexpected rogue label: " .. tostring(r_disc.files[1].label)
  )

  -- Colliding module basenames (`a/api` vs `b/api`) disambiguate cleanly
  local collide_root = tracked(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-springcfg-collide"))
  fixtures.write(collide_root .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.collide</groupId>",
    "  <artifactId>root</artifactId>",
    "  <version>1.0</version>",
    "  <packaging>pom</packaging>",
    "  <modules>",
    "    <module>a/api</module>",
    "    <module>b/api</module>",
    "  </modules>",
    "</project>",
  })
  for _, sub in ipairs({ "a/api", "b/api" }) do
    fixtures.write(collide_root .. "/" .. sub .. "/pom.xml", {
      '<project xmlns="http://maven.apache.org/POM/4.0.0">',
      "  <modelVersion>4.0.0</modelVersion>",
      "  <groupId>com.collide</groupId>",
      "  <artifactId>api</artifactId>",
      "  <version>1.0</version>",
      "</project>",
    })
    fixtures.write(collide_root .. "/" .. sub .. "/src/main/resources/application.yml", { "name: " .. sub })
  end
  local a_buf = open_buf(collide_root .. "/a/api/pom.xml", "xml")
  local c_disc = assert(spring_config.discover(a_buf))
  assert(#c_disc.files == 2)
  assert(
    c_disc.files[1].label == "a/api (current)  ·  default  ·  a/api/src/main/resources/application.yml",
    "expected a/api label: " .. tostring(c_disc.files[1].label)
  )
  assert(
    c_disc.files[2].label == "b/api  ·  default  ·  b/api/src/main/resources/application.yml",
    "expected b/api label: " .. tostring(c_disc.files[2].label)
  )
end

-- ---------- 3. Gradle multi-module + Project & Build menu integration ----------

do
  local g_root = fixtures.gradle_project("springcfg-gradle", {
    "include(':app', ':worker')",
  }, {
    src_dirs = { "app/src/main/java", "worker/src/main/java" },
  })
  tracked(g_root)
  fixtures.write(g_root .. "/app/build.gradle", { "// app" })
  fixtures.write(g_root .. "/worker/build.gradle", { "// worker" })
  fixtures.write(g_root .. "/app/src/main/resources/application.yaml", { "app: true" })
  fixtures.write(g_root .. "/worker/src/main/resources/config/application-local.properties", { "worker=1" })

  local g_buf = open_buf(g_root .. "/app/build.gradle", "groovy")

  ui.menu = function(entries, _, on_choice)
    captured_menu = entries
    captured_menu_cb = on_choice
  end

  -- Project menu (<leader>jp)
  project_menu.project()
  local p_entry = find_menu_entry(captured_menu, "spring_config")
  assert(p_entry and p_entry.enabled == true, "Project menu should enable Open Spring Configuration for Gradle")

  -- Build menu (<leader>jb)
  build.build()
  local b_entry = find_menu_entry(captured_menu, "spring_config")
  assert(b_entry and b_entry.enabled == true, "Build menu should enable Open Spring Configuration for Gradle")
  local run_spring_entry = find_menu_entry(captured_menu, "run_spring")
  assert(run_spring_entry and run_spring_entry.enabled == false, "Run Spring Boot stays disabled on Gradle")

  clear_state()
  pick_handler = function(items)
    assert(
      items[1] == "app (current)  ·  default  ·  app/src/main/resources/application.yaml",
      "Gradle contextual ordering failed: " .. tostring(items[1])
    )
    return items[2]
  end
  captured_menu_cb(b_entry)
  assert(
    canon(vim.api.nvim_buf_get_name(0))
      == canon(g_root .. "/worker/src/main/resources/config/application-local.properties"),
    "Build menu Open Spring Configuration did not open target file"
  )

  ui.menu = real_menu
end

-- ---------- 4. Project boundary enforcement (symlinks) & stale file guard ----------

do
  local outside = tracked(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-springcfg-outside"))
  fixtures.write(outside .. "/application-secret.yml", { "secret: true" })
  fixtures.write(outside .. "/application-dir.properties", { "dir=leak" })

  local root, main_path = fixtures.maven_project("springcfg-bounds", "com.bounds", "App")
  tracked(root)
  fixtures.write(root .. "/src/main/resources/application.yml", { "ok: true" })
  fixtures.write(root .. "/rogue/pom.xml", { "<project/>" })
  fixtures.write(root .. "/rogue/src/main/resources/application-rogue.yml", { "rogue: true" })

  -- Outward file symlink, broken symlink, symlink into undeclared rogue project, and outward config dir symlink
  vim.uv.fs_symlink(outside .. "/application-secret.yml", root .. "/src/main/resources/application-secret.yml")
  vim.uv.fs_symlink(outside .. "/does-not-exist.yml", root .. "/src/main/resources/application-broken.yml")
  vim.uv.fs_symlink(
    root .. "/rogue/src/main/resources/application-rogue.yml",
    root .. "/src/main/resources/application-rogue.yml"
  )
  vim.uv.fs_symlink(outside, root .. "/src/main/resources/config")

  local buf = open_buf(main_path, "java")
  local scan = run_config.scan_profiles(root)
  assert(
    #scan.files == 1 and scan.files[1].name == "application.yml",
    "symlinks outside project or into rogue subproject must be excluded: " .. vim.inspect(scan.files)
  )
  assert(#scan.profiles == 0, "outward profile symlinks must not populate profiles: " .. vim.inspect(scan.profiles))

  clear_state()
  local other = vim.api.nvim_create_buf(true, false)
  pick_handler = function(items)
    vim.api.nvim_set_current_buf(other)
    return items[1]
  end
  spring_config.open(buf)
  assert(vim.api.nvim_get_current_buf() == other, "stale picker must not replace another buffer")
  vim.api.nvim_set_current_buf(buf)

  clear_state()
  pick_handler = function(items)
    local path = root .. "/src/main/resources/application.yml"
    vim.fn.delete(path)
    assert(vim.uv.fs_symlink(root .. "/rogue/src/main/resources/application-rogue.yml", path))
    return items[1]
  end
  spring_config.open(buf)
  assert(vim.api.nvim_get_current_buf() == buf, "changed symlink must not cross module boundaries")
  vim.fn.delete(root .. "/src/main/resources/application.yml")
  fixtures.write(root .. "/src/main/resources/application.yml", { "ok: true" })

  -- Stale deletion between pick and open notifies safely instead of opening a nonexistent file
  clear_state()
  pick_handler = function(items)
    vim.fn.delete(root .. "/src/main/resources/application.yml")
    return items[1]
  end
  spring_config.open(buf)
  assert(vim.api.nvim_get_current_buf() == buf, "stale deleted file must not switch buffer")
  assert(
    last_notice() and last_notice().msg:find("no longer exists", 1, true),
    "expected stale warning: " .. tostring(last_notice() and last_notice().msg)
  )
end

-- ---------- 5. Dirty buffer safety, empty project, and non-project / nofile buffers ----------

do
  local root, main_path = fixtures.maven_project("springcfg-dirty", "com.dirty", "App")
  tracked(root)
  fixtures.write(root .. "/src/main/resources/application.yml", { "ok: true" })

  local dirty_buf = open_buf(main_path, "java")
  vim.api.nvim_buf_set_lines(dirty_buf, 0, 1, false, { "// unsaved change" })
  local prev_hidden = vim.o.hidden
  vim.o.hidden = false
  clear_state()
  pick_handler = function(items)
    return items[1]
  end
  local ok_call = pcall(spring_config.open, dirty_buf)
  vim.o.hidden = prev_hidden
  assert(ok_call, "dirty buffer must not throw")
  assert(vim.api.nvim_get_current_buf() == dirty_buf, "dirty buffer must remain active when edit fails")
  assert(
    last_notice() and last_notice().msg:find("could not open", 1, true),
    "expected safe open warning: " .. tostring(last_notice() and last_notice().msg)
  )
  vim.bo[dirty_buf].modified = false

  -- nofile scratch buffer while cwd is the Spring project must NOT guess project from cwd
  local prev_cwd = vim.uv.cwd()
  vim.cmd.cd(vim.fn.fnameescape(root))
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.api.nvim_set_current_buf(scratch)

  local avail_scratch, reason_scratch = spring_config.available(scratch)
  assert(avail_scratch == false and reason_scratch:find("no Maven/Gradle project", 1, true))
  clear_state()
  spring_config.open(scratch)
  assert(#picks == 0, "nofile scratch buffer must not open picker")
  assert(last_notice() and last_notice().msg:find("no Maven/Gradle project", 1, true))
  ui.menu = function(entries)
    captured_menu = entries
  end
  project_menu.project()
  assert(not find_menu_entry(captured_menu, "spring_config").enabled, "project menu must not guess a project")
  ui.menu = real_menu

  -- File outside any project while cwd is a Spring project must stay isolated
  local outside_dir = tracked(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-springcfg-plain-file"))
  fixtures.write(outside_dir .. "/Notes.txt", { "hello" })
  local outside_buf = open_buf(outside_dir .. "/Notes.txt")
  local avail_out, reason_out = spring_config.available(outside_buf)
  assert(avail_out == false and reason_out:find("no Maven/Gradle project", 1, true))
  clear_state()
  spring_config.open(outside_buf)
  assert(#picks == 0, "non-project file must not open picker")

  vim.cmd.cd(vim.fn.fnameescape(prev_cwd))

  -- Project without any Spring configuration files -> disabled in menus + safe direct open
  local empty_proj, empty_main = fixtures.maven_project("springcfg-empty", "com.empty", "App")
  tracked(empty_proj)
  local empty_buf = open_buf(empty_main, "java")
  local avail_empty, reason_empty = spring_config.available(empty_buf)
  assert(
    avail_empty == false and reason_empty:find("no Spring configuration files", 1, true),
    "unexpected empty reason: " .. tostring(reason_empty)
  )

  ui.menu = function(entries)
    captured_menu = entries
  end
  project_menu.project()
  local pm_empty = find_menu_entry(captured_menu, "spring_config")
  assert(pm_empty and pm_empty.enabled == false and pm_empty.reason:find("no Spring configuration files", 1, true))

  build.build()
  local bm_empty = find_menu_entry(captured_menu, "spring_config")
  assert(bm_empty and bm_empty.enabled == false and bm_empty.reason:find("no Spring configuration files", 1, true))
  ui.menu = real_menu

  clear_state()
  spring_config.open(empty_buf)
  assert(#picks == 0, "empty project must not open picker")
  assert(last_notice() and last_notice().msg:find("no Spring configuration files", 1, true))
end

-- ---------- cleanup ----------

ui.notify = real_notify
ui.pick_one = real_pick_one
ui.menu = real_menu
vim.ui.select = real_select
vim.system = real_system
vim.fn.jobstart = real_jobstart

for _, dir in ipairs(temp_dirs) do
  vim.fn.delete(dir, "rf")
end

print("spring_config_spec: OK")
vim.cmd("qa!")
