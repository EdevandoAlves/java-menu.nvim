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
    { "java_menu.calls", "calls" },
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
  local maven_srs = project.source_roots(maven_root)
  assert(#maven_srs == 1, "expected 1 Maven source root, got " .. tostring(#maven_srs))
  local maven_pref = project.preferred(maven_srs, maven_buf)
  assert(
    maven_pref and maven_pref.path == expected_maven_root .. "/src/main/java",
    "preferred source root mismatch: " .. tostring(maven_pref and maven_pref.path)
  )
  assert(project.package_for(maven_buf, maven_srs[1].path) == "com.smoke", "package_for existing file mismatch")

  local draft_java = vim.fs.joinpath(maven_root, "src", "main", "java", "com", "smoke", "sub", "Draft.java")
  local draft_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(draft_buf, draft_java)
  assert(
    project.root(draft_buf) == expected_maven_root,
    "draft buffer Maven root mismatch: " .. tostring(project.root(draft_buf)) .. " ~= " .. expected_maven_root
  )
  local draft_pref = project.preferred(maven_srs, draft_buf)
  assert(
    draft_pref and draft_pref.path == expected_maven_root .. "/src/main/java",
    "preferred source root mismatch for draft buffer"
  )
  assert(
    project.package_for(draft_buf, maven_srs[1].path) == "com.smoke.sub",
    "package_for draft buffer mismatch: " .. tostring(project.package_for(draft_buf, maven_srs[1].path))
  )

  local ws_id = project.workspace_id(maven_root)
  assert(type(ws_id) == "string" and #ws_id > 0, "workspace_id empty")
  assert(ws_id == project.workspace_id(expected_maven_root), "workspace_id diverged between raw and canonical root")

  local mm_root = make_temp_dir("mm-maven")
  write_lines(vim.fs.joinpath(mm_root, "pom.xml"), {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.mm</groupId>",
    "  <artifactId>mm-parent</artifactId>",
    "  <version>1.0</version>",
    "  <packaging>pom</packaging>",
    "  <modules>",
    "    <module>core-module</module>",
    "    <module>service-module</module>",
    "  </modules>",
    "</project>",
  })
  write_lines(vim.fs.joinpath(mm_root, "core-module", "pom.xml"), {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <artifactId>core-module</artifactId>",
    "</project>",
  })
  write_lines(vim.fs.joinpath(mm_root, "core-module", "src", "main", "java", "com", "mm", "core", "Core.java"), {
    "package com.mm.core;",
    "",
    "public class Core {}",
  })
  write_lines(vim.fs.joinpath(mm_root, "service-module", "pom.xml"), {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <artifactId>service-module</artifactId>",
    "</project>",
  })
  local mm_svc_java =
    vim.fs.joinpath(mm_root, "service-module", "src", "main", "java", "com", "mm", "svc", "Service.java")
  write_lines(mm_svc_java, {
    "package com.mm.svc;",
    "",
    "public class Service {}",
  })
  local expected_mm_root = vim.fs.normalize(vim.uv.fs_realpath(mm_root))
  local mm_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(mm_buf, mm_svc_java)
  assert(
    project.root(mm_buf) == expected_mm_root,
    "multi-module Maven root mismatch: " .. tostring(project.root(mm_buf)) .. " ~= " .. expected_mm_root
  )
  local mm_srs = project.source_roots(mm_root)
  local mm_pref = project.preferred(mm_srs, mm_buf)
  assert(
    mm_pref and mm_pref.path == expected_mm_root .. "/service-module/src/main/java",
    "multi-module preferred source root mismatch: " .. tostring(mm_pref and mm_pref.path)
  )

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
    preview._inside_project(
      expected_maven_root,
      vim.fs.joinpath(maven_root, "src", "main", "java", "com", "smoke", "newpkg", "New.java")
    ) == true,
    "inside_project rejected non-existent nested path under project root"
  )
  assert(
    preview._inside_project(
      maven_root,
      vim.fs.joinpath(expected_maven_root, "src", "main", "java", "com", "smoke", "newpkg", "New.java")
    ) == true,
    "inside_project rejected canonical nested path under raw project root"
  )
  assert(
    preview._inside_project(maven_root, vim.fs.joinpath(other_root, "App.java")) == false,
    "inside_project accepted sibling directory"
  )
  assert(
    preview._inside_project(expected_maven_root, vim.fs.joinpath(other_root, "newpkg", "New.java")) == false,
    "inside_project accepted non-existent path in sibling directory"
  )
  assert(
    preview._inside_project(maven_root, maven_root .. "2/src/App.java") == false,
    "inside_project accepted prefix-collision path"
  )
  assert(
    preview._inside_project(expected_maven_root, maven_root .. "2/newpkg/New.java") == false,
    "inside_project accepted non-existent prefix-collision path"
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
  assert(
    plan.files[1].diff[1] == "--- a/src/main/java/com/smoke/App.java",
    "preview.plan diff header should be relative to root, got: " .. tostring(plan.files[1].diff[1])
  )

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

  local move_src_raw = vim.fs.joinpath(maven_root, "src", "main", "java", "com", "smoke", "MoveTarget.java")
  write_lines(move_src_raw, {
    "package com.smoke;",
    "",
    "public class MoveTarget {}",
  })
  local move_src_buf = vim.fn.bufadd(move_src_raw)
  vim.fn.bufload(move_src_buf)
  local renamed_java =
    vim.fs.joinpath(expected_maven_root, "src", "main", "java", "com", "smoke", "MoveTargetRenamed.java")
  local stale_dest_buf =
    vim.fn.bufadd(vim.fs.joinpath(maven_root, "src", "main", "java", "com", "smoke", "MoveTargetRenamed.java"))
  vim.api.nvim_buf_set_lines(stale_dest_buf, 0, -1, false, { "// unsaved" })
  assert(vim.bo[stale_dest_buf].modified, "draft destination buffer was not marked modified")
  assert(
    preview._modified_buffer_for(renamed_java) == stale_dest_buf,
    "modified_buffer_for missed unsaved buffer across raw/canonical root"
  )
  vim.bo[stale_dest_buf].modified = false
  pcall(vim.api.nvim_buf_delete, stale_dest_buf, { force = true })

  local rename_plan, rename_err = preview.plan({
    documentChanges = {
      {
        textDocument = { uri = vim.uri_from_fname(renamed_java) },
        edits = {
          {
            range = {
              start = { line = 2, character = 13 },
              ["end"] = { line = 2, character = 23 },
            },
            newText = "MoveTargetRenamed",
          },
        },
      },
      {
        kind = "rename",
        oldUri = vim.uri_from_fname(move_src_raw),
        newUri = vim.uri_from_fname(renamed_java),
      },
    },
  }, { root = expected_maven_root, encoding = "utf-16" })
  assert(rename_plan ~= nil, "mixed-root rename preview.plan failed: " .. tostring(rename_err))
  assert(
    rename_plan.files[1].diff[1] == "--- a/src/main/java/com/smoke/MoveTargetRenamed.java",
    "mixed-root rename diff header mismatch: " .. tostring(rename_plan.files[1].diff[1])
  )
  local apply_res, apply_problems = preview._apply(rename_plan)
  assert(
    apply_res ~= nil and apply_res.error == nil,
    "mixed-root rename apply failed: "
      .. tostring(apply_res and apply_res.error)
      .. " / "
      .. vim.inspect(apply_problems)
  )
  assert(vim.fn.filereadable(renamed_java) == 1, "renamed file missing after apply")
  pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(renamed_java), { force = true })

  -- Pure RenameFile preserves unsaved buffer changes across raw/canonical path
  local unsaved_src_raw = vim.fs.joinpath(maven_root, "src", "main", "java", "com", "smoke", "KeepEdits.java")
  local unsaved_dst =
    vim.fs.joinpath(expected_maven_root, "src", "main", "java", "com", "smoke", "KeepEditsRenamed.java")
  write_lines(unsaved_src_raw, { "package com.smoke;", "", "public class KeepEdits {}" })
  local unsaved_buf = vim.fn.bufadd(unsaved_src_raw)
  vim.fn.bufload(unsaved_buf)
  vim.api.nvim_buf_set_lines(unsaved_buf, 0, -1, false, {
    "package com.smoke;",
    "",
    "public class KeepEdits { int keep = 42; }",
  })
  assert(vim.bo[unsaved_buf].modified, "unsaved source buffer was not marked modified")
  local keep_plan, keep_err = preview.plan({
    documentChanges = {
      {
        kind = "rename",
        oldUri = vim.uri_from_fname(unsaved_src_raw),
        newUri = vim.uri_from_fname(unsaved_dst),
      },
    },
  }, { root = expected_maven_root, encoding = "utf-16" })
  assert(keep_plan ~= nil, "pure rename preview.plan failed: " .. tostring(keep_err))
  local keep_res, keep_probs = preview._apply(keep_plan)
  assert(
    keep_res ~= nil and keep_res.error == nil,
    "pure rename apply failed: " .. tostring(keep_res and keep_res.error) .. " / " .. vim.inspect(keep_probs)
  )
  local kept_new_buf = vim.fn.bufnr(unsaved_dst)
  assert(kept_new_buf ~= -1 and vim.api.nvim_buf_is_loaded(kept_new_buf), "renamed buffer missing")
  assert(vim.bo[kept_new_buf].modified, "renamed buffer lost modified flag")
  assert(
    table.concat(vim.api.nvim_buf_get_lines(kept_new_buf, 0, -1, false), "\n"):find("int keep = 42;", 1, true) ~= nil,
    "pure rename lost unsaved buffer edits"
  )
  vim.bo[kept_new_buf].modified = false
  pcall(vim.api.nvim_buf_delete, kept_new_buf, { force = true })

  -- Out-of-project CreateFile blocked in plan and apply
  local outside_create = vim.fs.joinpath(other_root, "Escape.java")
  local blocked_plan, blocked_err = preview.plan({
    documentChanges = {
      { kind = "create", uri = vim.uri_from_fname(outside_create) },
    },
  }, { root = expected_maven_root, encoding = "utf-16" })
  assert(blocked_plan == nil, "preview.plan allowed CreateFile outside project")
  assert(type(blocked_err) == "string" and blocked_err:find("outside the project", 1, true) ~= nil)
  local blocked_apply_res, blocked_apply_probs = preview._apply({
    root = expected_maven_root,
    encoding = "utf-16",
    ops = { { kind = "create", uri = vim.uri_from_fname(outside_create), path = outside_create } },
    files = {},
  })
  assert(blocked_apply_res == nil and #blocked_apply_probs > 0, "apply allowed CreateFile outside project")
  assert(vim.fn.filereadable(outside_create) == 0, "CreateFile wrote outside project")

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
