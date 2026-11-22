-- Controlled pure portable smoke checks (issue #8).
-- Covers pure Lua/Neovim/jc.nvim contracts and normalized filesystem project
-- detection without bash-only paths, chmod, symlinks, /tmp, or external
-- processes. Fails hard via cquit 1 on any assertion failure; never skips.
--
-- Passing this spec verifies ONLY the controlled portable smoke scope and
-- explicitly reports surfaces not covered or unsupported on non-Linux hosts.

local temp_dirs = {}

local function track_dir(path)
  temp_dirs[#temp_dirs + 1] = path
  return path
end

local function cleanup()
  for _, dir in ipairs(temp_dirs) do
    pcall(vim.fn.delete, dir, "rf")
  end
end

local function write_lines(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function make_temp_dir(label)
  local dir = vim.fs.normalize(vim.fn.tempname() .. "-jm-" .. label)
  vim.fn.mkdir(dir, "p")
  return track_dir(dir)
end

local function run_smoke()
  -- ---------- 1. Explicit OS / runtime reporting ----------
  local uname = vim.uv.os_uname()
  local ver = vim.version()
  local nvim_ver = string.format("%d.%d.%d", ver.major, ver.minor, ver.patch)
  local is_win = vim.fn.has("win32") == 1
  local is_mac = vim.fn.has("mac") == 1

  print(
    string.format(
      "[portable_smoke_spec] OS=%s machine=%s nvim=%s win32=%d mac=%d",
      tostring(uname.sysname),
      tostring(uname.machine),
      nvim_ver,
      is_win and 1 or 0,
      is_mac and 1 or 0
    )
  )

  local expected_os = vim.env.JAVA_MENU_EXPECTED_OS
  if expected_os == "macOS" then
    assert(is_mac and uname.sysname == "Darwin", "expected macOS runner, got " .. tostring(uname.sysname))
  elseif expected_os == "Windows" then
    assert(
      is_win and tostring(uname.sysname):match("^Windows") ~= nil,
      "expected Windows runner, got " .. tostring(uname.sysname)
    )
  end

  -- ---------- 2. Required jc.nvim dependency (no silent skip) ----------
  local ok_jc, jc_jdtls = pcall(require, "jc.jdtls")
  assert(ok_jc and type(jc_jdtls) == "table", "required dependency jc.nvim failed to load: " .. tostring(jc_jdtls))

  local jca = require("java_menu.jc")
  local import_api, import_err = jca.replace_import_api()
  assert(import_api ~= nil, "jc.replace_import_api failed: " .. tostring(import_err))
  local style, style_err = jca.import_style()
  assert(
    style ~= nil and type(style.order) == "table" and #style.order > 0,
    "jc.import_style failed: " .. tostring(style_err)
  )
  local disco, disco_err = jca.test_discovery_api()
  assert(disco ~= nil, "jc.test_discovery_api failed: " .. tostring(disco_err))
  local busy = jca.jdtls_busy()
  assert(type(busy) == "boolean", "jc.jdtls_busy must return boolean")

  -- ---------- 3. All plugin modules load cleanly ----------
  local expected_modules = {
    { "java_menu", "setup" },
    { "java_menu.new", "new" },
    { "java_menu.generate", "generate" },
    { "java_menu.refactor", "refactor" },
    { "java_menu.imports", "imports" },
    { "java_menu.build", "build" },
    { "java_menu.tests", "tests" },
    { "java_menu.debug", "debug" },
    { "java_menu.signature", "change_signature" },
    { "java_menu.ui", "menu" },
    { "java_menu.lsp", "capabilities" },
    { "java_menu.preview", "plan" },
    { "java_menu.project", "root" },
    { "java_menu.project_menu", "project" },
    { "java_menu.create", "create" },
    { "java_menu.deps", "menu" },
    { "java_menu.diagnostics", "report" },
    { "java_menu.run_config", "load" },
  }
  for _, spec in ipairs(expected_modules) do
    local mod = require(spec[1])
    assert(type(mod) == "table", spec[1] .. " did not return a table")
    assert(type(mod[spec[2]]) == "function", spec[1] .. "." .. spec[2] .. " is missing or not a function")
  end

  -- ---------- 4. Public setup() + lazy loading + :JavaMenu ----------
  local jm = require("java_menu")
  jm.setup({ prefix = "<leader>j" })
  assert(vim.fn.exists(":JavaMenu") == 2, ":JavaMenu user command was not registered")
  local ok_unknown = pcall(jm.trigger, "nonexistent_action")
  assert(not ok_unknown, "jm.trigger should fail on unknown action")

  -- ---------- 5. Pure LSP capabilities (no HOME env dependency) ----------
  local lsp = require("java_menu.lsp")
  local native_caps = lsp.capabilities()
  assert(type(native_caps) == "table" and type(native_caps.textDocument) == "table", "native capabilities invalid")

  -- ---------- 6. Pure portable project detection (Maven & static Gradle) ----------
  local project = require("java_menu.project")

  local maven_root = make_temp_dir("maven")
  local maven_java = vim.fs.joinpath(maven_root, "src", "main", "java", "com", "smoke", "App.java")
  write_lines(vim.fs.joinpath(maven_root, "pom.xml"), {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.smoke</groupId>",
    "  <artifactId>smoke-app</artifactId>",
    "  <version>1.0</version>",
    "</project>",
  })
  write_lines(maven_java, {
    "package com.smoke;",
    "",
    "public class App {}",
  })

  local maven_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(maven_buf, maven_java)
  vim.api.nvim_set_current_buf(maven_buf)

  local expected_maven_root = vim.fs.normalize(vim.uv.fs_realpath(maven_root))
  assert(project.is_java_project(maven_buf) == true, "Maven project not detected")
  assert(
    project.root(maven_buf) == expected_maven_root,
    "Maven root mismatch: " .. tostring(project.root(maven_buf)) .. " ~= " .. expected_maven_root
  )
  local maven_mods = project.modules(maven_root)
  assert(#maven_mods == 1, "expected 1 Maven module, got " .. tostring(#maven_mods))
  local ws_id = project.workspace_id(maven_root)
  assert(type(ws_id) == "string" and #ws_id > 0, "workspace_id empty")

  local gradle_root = make_temp_dir("gradle")
  write_lines(vim.fs.joinpath(gradle_root, "settings.gradle"), {
    "rootProject.name = 'smoke'",
    "include(':app')",
  })
  write_lines(vim.fs.joinpath(gradle_root, "build.gradle"), { "// smoke" })
  local gradle_keep = vim.fs.joinpath(gradle_root, "app", "src", "main", "java", ".keep")
  write_lines(gradle_keep, {})

  local gradle_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(gradle_buf, gradle_keep)
  vim.api.nvim_set_current_buf(gradle_buf)

  local expected_gradle_root = vim.fs.normalize(vim.uv.fs_realpath(gradle_root))
  assert(
    project.root(gradle_buf) == expected_gradle_root,
    "Gradle root mismatch: " .. tostring(project.root(gradle_buf)) .. " ~= " .. expected_gradle_root
  )
  local gradle_mods = project.modules(gradle_root)
  assert(#gradle_mods == 2, "expected 2 Gradle modules (root + :app), got " .. tostring(#gradle_mods))
  assert(project.discovery_limitation(gradle_root) == nil, "static Gradle settings should have no discovery limitation")

  local empty_dir = make_temp_dir("empty")
  local prev_cwd = vim.uv.cwd()
  vim.cmd("cd " .. vim.fn.fnameescape(empty_dir))
  local empty_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(empty_buf)
  local empty_ok, empty_err = pcall(function()
    assert(project.root(empty_buf) == nil, "empty directory should have no project root")
    assert(project.is_java_project(empty_buf) == false, "empty directory should not be a Java project")
  end)
  vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
  assert(empty_ok, empty_err)

  -- ---------- 7. Pure portable WorkspaceEdit preview (no symlinks) ----------
  local preview = require("java_menu.preview")
  local other_root = make_temp_dir("other")
  assert(preview._inside_project(maven_root, maven_java) == true, "inside_project rejected valid path")
  assert(
    preview._inside_project(maven_root, vim.fs.joinpath(other_root, "App.java")) == false,
    "inside_project accepted sibling directory"
  )
  assert(
    preview._inside_project(maven_root, maven_root .. "2/src/App.java") == false,
    "inside_project accepted prefix-collision path"
  )

  local plan, plan_err = preview.plan({
    changes = {
      [vim.uri_from_fname(maven_java)] = {
        {
          range = {
            start = { line = 2, character = 0 },
            ["end"] = { line = 2, character = 18 },
          },
          newText = "public final class App {}",
        },
      },
    },
  }, { root = expected_maven_root, encoding = "utf-16" })
  assert(plan ~= nil, "preview.plan failed: " .. tostring(plan_err))
  assert(#plan.files == 1 and plan.files[1].added == 1, "preview.plan diff count unexpected")

  local ui = require("java_menu.ui")
  local orig_menu = ui.menu
  ui.menu = function(_, _, on_choice)
    on_choice({ key = "cancel" })
  end
  local cancelled = false
  local review_ok, review_err = pcall(function()
    preview.review(plan, function(applied)
      assert(applied == false, "cancelled preview reported applied=true")
      cancelled = true
    end)
  end)
  ui.menu = orig_menu
  assert(review_ok, review_err)
  assert(cancelled == true, "preview.review cancel callback did not run")

  -- ---------- 8. Honest portability summary ----------
  print(
    "[portable_smoke_spec] SUPPORTED_SMOKE: "
      .. "setup, modules, jc.nvim_contract, lsp.capabilities, "
      .. "project_discovery(maven+gradle_static), preview_plan_boundary"
  )
  print(
    "[portable_smoke_spec] UNSUPPORTED_OR_NOT_TESTED: "
      .. "jdtls_server, maven_gradle_processes, build_wrappers, chmod, symlinks, spring_zip_extraction"
  )
  print("[portable_smoke_spec] OK")
end

local ok, err = xpcall(run_smoke, debug.traceback)
cleanup()
if not ok then
  io.stderr:write("[portable_smoke_spec] FAIL\n" .. tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
