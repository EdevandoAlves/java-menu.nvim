-- Integration (Issue #16): real JDTLS + JUnit Platform Console Standalone
-- end-to-end verification of the `java_menu.tests` menu action that creates
-- an explicitly failing JUnit 5 test skeleton for a method selected via
-- `textDocument/documentSymbol` after verifying JUnit 5 on the test classpath.
--
-- Covers:
--   1. Real JDTLS attachment on an isolated offline Maven fixture with
--      `org.junit.jupiter:junit-jupiter-api:5.10.2` cached in `~/.m2/repository`.
--   2. Real `java_menu.tests` menu (`tests_mod.tests()`): selecting
--      "Create JUnit 5 Test for Method…", real `textDocument/documentSymbol`
--      with `[at cursor]` on the method under the cursor, real
--      `java.project.getClasspaths` verification, name prompt, and confirmation.
--   3. New test class creation (`CalculatorTest.java`), compiling with `javac`
--      and executing via local `junit-platform-console-standalone-1.10.2.jar`,
--      confirming 1 test found, 0 skipped, 1 failed (non-zero exit).
--   4. Existing test class insertion (`CalculatorTest.java` already on disk):
--      adding a second method skeleton via the real menu, verifying no
--      duplicate imports, compiling, and executing via JUnit Console Standalone
--      (2 tests found, 0 skipped, 2 failed; plus single-method selection 1/0/1).
--   5. Strict preservation of the source production file (`Calculator.java`
--      byte-for-byte unchanged on disk and unmodified in buffer).
--
-- Run:
--   nvim --headless -u NONE -n \
--     -c "set rtp+=." \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-jdtls" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-lspconfig" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/jc.nvim" \
--     -c "lua local ok, err = pcall(dofile, 'tests/java_menu/junit_method_real_spec.lua'); if not ok then io.stderr:write(tostring(err)..'\n'); vim.cmd('cquit 1') end" \
--     -c "qa!"

local SPEC_NAME = "junit_method_real_spec"

local tests_mod = require("java_menu.tests")
local lsp = require("java_menu.lsp")
local fixtures = require("tests.java_menu.fixtures")

local real_notify = vim.notify
local real_select = vim.ui.select
local real_input = vim.ui.input

local temp_dirs = {}
local started_clients = {}
local created_bufs = {}

local function register_dir(dir)
  if dir and dir ~= "" then
    temp_dirs[#temp_dirs + 1] = dir
  end
  return dir
end

local function track_buf(buf)
  if buf and buf > 0 then
    created_bufs[#created_bufs + 1] = buf
  end
  return buf
end

local function cleanup()
  pcall(function()
    tests_mod._reset()
  end)

  vim.notify = real_notify
  vim.ui.select = real_select
  vim.ui.input = real_input

  for i = #started_clients, 1, -1 do
    local client = started_clients[i]
    if client and not client:is_stopped() then
      pcall(function()
        client:stop(true)
      end)
    end
  end

  fixtures.wait_for(10000, function()
    for _, client in ipairs(started_clients) do
      if client and not client:is_stopped() then
        return false
      end
    end
    return true
  end)

  for _, buf in ipairs(created_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  for _, dir in ipairs(temp_dirs) do
    pcall(vim.fn.delete, dir, "rf")
  end
end

local function skip(reason)
  cleanup()
  io.stdout:write(string.format("[SPEC_SKIP] %s: %s\n", SPEC_NAME, tostring(reason)))
  io.stdout:flush()
  vim.cmd("qa!")
end

-- Check runtime prerequisites honestly: skip when any external tool, plugin, or cached jar is missing.
local ok_jdtls, jdtls = pcall(require, "jdtls")
if not ok_jdtls or type(jdtls) ~= "table" or type(jdtls.start_or_attach) ~= "function" then
  return skip("nvim-jdtls plugin unavailable in runtimepath")
end

local jdtls_bin = vim.fn.exepath("jdtls")
if jdtls_bin == "" then
  local mason = vim.fn.stdpath("data") .. "/mason/bin/jdtls"
  if vim.fn.filereadable(mason) == 1 then
    jdtls_bin = mason
  end
end
if jdtls_bin == "" or vim.fn.filereadable(jdtls_bin) ~= 1 then
  return skip("local jdtls binary not found in PATH or mason/bin/jdtls")
end

if vim.fn.executable("javac") ~= 1 or vim.fn.executable("java") ~= 1 then
  return skip("JDK tools (javac/java) not found in PATH")
end

local home = vim.env.HOME or ""
local m2_repo = vim.env.M2_REPO or (home ~= "" and (home .. "/.m2/repository") or "")
if m2_repo == "" or vim.fn.isdirectory(m2_repo) ~= 1 then
  return skip("local Maven repository (~/.m2/repository) not found")
end

local junit_console_jar = m2_repo
  .. "/org/junit/platform/junit-platform-console-standalone/1.10.2/junit-platform-console-standalone-1.10.2.jar"
if vim.fn.filereadable(junit_console_jar) ~= 1 then
  return skip("local JUnit Console standalone jar not found: " .. junit_console_jar)
end

local required_cached_artifacts = {
  m2_repo .. "/org/junit/junit-bom/5.10.2/junit-bom-5.10.2.pom",
  m2_repo .. "/org/junit/jupiter/junit-jupiter-api/5.10.2/junit-jupiter-api-5.10.2.pom",
  m2_repo .. "/org/junit/jupiter/junit-jupiter-api/5.10.2/junit-jupiter-api-5.10.2.jar",
  m2_repo .. "/org/junit/platform/junit-platform-commons/1.10.2/junit-platform-commons-1.10.2.jar",
  m2_repo .. "/org/opentest4j/opentest4j/1.3.0/opentest4j-1.3.0.jar",
  m2_repo .. "/org/apiguardian/apiguardian-api/1.1.2/apiguardian-api-1.1.2.jar",
}
for _, artifact in ipairs(required_cached_artifacts) do
  if vim.fn.filereadable(artifact) ~= 1 then
    return skip("cached offline JUnit 5 Maven artifact missing: " .. artifact)
  end
end

local function read_raw(path)
  local fd = assert(vim.uv.fs_open(path, "r", 420))
  local stat = assert(vim.uv.fs_fstat(fd))
  local data = stat.size > 0 and assert(vim.uv.fs_read(fd, stat.size, 0)) or ""
  vim.uv.fs_close(fd)
  return data
end

local function open_java(path)
  path = vim.fs.normalize(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_set_current_buf(buf)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
  end
  vim.bo[buf].filetype = "java"
  return track_buf(buf)
end

local function find_line_1based(path, needle)
  local lines = vim.fn.readfile(path)
  for idx, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      local col = (line:find("%S") or 1) - 1
      return idx, col, line
    end
  end
  error(string.format("line containing '%s' not found in %s", needle, path))
end

local function lsp_request_sync(client, method, params, bufnr, timeout_ms)
  local done, res_err, res_val = false, nil, nil
  local ok, req_id = client:request(method, params, function(err, result)
    res_err = err
    res_val = result
    done = true
  end, bufnr)
  assert(ok and req_id ~= nil, string.format("client:request(%s) failed to dispatch", method))
  local finished = vim.wait(timeout_ms or 15000, function()
    return done
  end, 50)
  assert(finished, string.format("LSP request %s timed out after %dms", method, timeout_ms or 15000))
  return res_err, res_val
end

local function find_item(items, needle)
  for _, item in ipairs(items or {}) do
    if item:find(needle, 1, true) then
      return item
    end
  end
  return nil
end

local function run_cmd(argv)
  local res = vim.system(argv, { text = true }):wait()
  return res.code, (res.stdout or "") .. (res.stderr or "")
end

local function parse_junit_counts(output)
  local found = tonumber(output:match("(%d+)%s+tests?%s+found"))
  local skipped = tonumber(output:match("(%d+)%s+tests?%s+skipped"))
  local started = tonumber(output:match("(%d+)%s+tests?%s+started"))
  local aborted = tonumber(output:match("(%d+)%s+tests?%s+aborted"))
  local successful = tonumber(output:match("(%d+)%s+tests?%s+successful"))
  local failed = tonumber(output:match("(%d+)%s+tests?%s+failed"))
  return {
    found = found,
    skipped = skipped,
    started = started,
    aborted = aborted,
    successful = successful,
    failed = failed,
  }
end

local function compile_and_run_junit(main_out, test_out, calc_path, test_path, selector_args)
  vim.fn.mkdir(main_out, "p")
  vim.fn.mkdir(test_out, "p")

  local rc_main, out_main = run_cmd({ "javac", "--release", "21", "-d", main_out, calc_path })
  assert(rc_main == 0, "javac failed for production class:\n" .. out_main)

  local cp_compile = junit_console_jar .. ":" .. main_out
  local rc_test, out_test = run_cmd({ "javac", "--release", "21", "-cp", cp_compile, "-d", test_out, test_path })
  assert(rc_test == 0, "javac failed for generated test class:\n" .. out_test)

  local cp_run = test_out .. ":" .. main_out
  local argv = {
    "java",
    "-jar",
    junit_console_jar,
    "execute",
    "--disable-banner",
    "--disable-ansi-colors",
    "--class-path",
    cp_run,
  }
  for _, arg in ipairs(selector_args) do
    argv[#argv + 1] = arg
  end
  local rc_junit, out_junit = run_cmd(argv)
  return rc_junit, out_junit, parse_junit_counts(out_junit)
end

local function run_tests()
  local notices = {}
  vim.notify = function(msg, level)
    notices[#notices + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
  end

  local function assert_no_warn_or_error(phase)
    for _, n in ipairs(notices) do
      if n.level == vim.log.levels.WARN or n.level == vim.log.levels.ERROR then
        error(string.format("unexpected WARN/ERROR notice during %s: %s", phase, n.msg))
      end
    end
  end

  -- 1. Create isolated offline Maven project with JUnit 5 API test dependency.
  local raw_root = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-junit-method-real")
  vim.fn.mkdir(raw_root, "p")
  local root = vim.fs.normalize(vim.uv.fs_realpath(raw_root) or raw_root)
  register_dir(root)
  local data_dir = register_dir(root .. "-data")

  fixtures.write(root .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.java.menu.test</groupId>",
    "  <artifactId>junit-method-real</artifactId>",
    "  <version>1.0</version>",
    "  <properties>",
    "    <maven.compiler.release>21</maven.compiler.release>",
    "    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>",
    "  </properties>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>org.junit.jupiter</groupId>",
    "      <artifactId>junit-jupiter-api</artifactId>",
    "      <version>5.10.2</version>",
    "      <scope>test</scope>",
    "    </dependency>",
    "  </dependencies>",
    "</project>",
  })

  local pkg = "com.demo.junitreal"
  local rel_pkg = pkg:gsub("%.", "/")
  local calc_path = root .. "/src/main/java/" .. rel_pkg .. "/Calculator.java"
  local test_path = root .. "/src/test/java/" .. rel_pkg .. "/CalculatorTest.java"

  fixtures.write(calc_path, {
    "package " .. pkg .. ";",
    "",
    "public class Calculator {",
    "  public int add(int a, int b) {",
    "    return a + b;",
    "  }",
    "",
    "  public int subtract(int a, int b) {",
    "    return a - b;",
    "  }",
    "}",
  })
  calc_path = vim.fs.normalize(vim.uv.fs_realpath(calc_path) or calc_path)
  local original_calc_bytes = read_raw(calc_path)

  -- 2. Attach real JDTLS and wait until both documentSymbol and JUnit 5 test classpath are ready.
  local calc_buf = open_java(calc_path)
  jdtls.start_or_attach({
    cmd = { jdtls_bin, "-data", data_dir },
    root_dir = root,
    capabilities = lsp.capabilities(),
  })

  local attached = fixtures.wait_for(60000, function()
    return lsp.client(calc_buf) ~= nil
  end)
  assert(attached, "real JDTLS failed to attach within 60s")
  local client = lsp.client(calc_buf)
  started_clients[#started_clients + 1] = client

  assert(
    client.server_capabilities and client.server_capabilities.documentSymbolProvider,
    "JDTLS did not advertise documentSymbolProvider"
  )

  local doc_uri = vim.lsp.util.make_text_document_params(calc_buf).uri
  local ready_err = nil
  local jdtls_ready = vim.wait(90000, function()
    local sym_err, sym_res = lsp_request_sync(client, "textDocument/documentSymbol", {
      textDocument = { uri = doc_uri },
    }, calc_buf, 10000)
    if sym_err ~= nil or type(sym_res) ~= "table" or #sym_res == 0 then
      ready_err = "documentSymbol not ready: " .. vim.inspect(sym_err or sym_res)
      return false
    end
    local extracted = tests_mod._extract_methods_from_symbols(sym_res, { line = 4, character = 4 })
    if #extracted < 2 then
      ready_err = "expected 2 methods in documentSymbol, got " .. #extracted
      return false
    end

    local cp_err, cp_res = lsp_request_sync(client, "workspace/executeCommand", {
      command = "java.project.getClasspaths",
      arguments = { doc_uri, vim.fn.json_encode({ scope = "test" }) },
    }, calc_buf, 10000)
    if cp_err ~= nil then
      ready_err = "getClasspaths error: " .. vim.inspect(cp_err)
      return false
    end
    local info = tests_mod._inspect_junit5_classpath(cp_res)
    if info.status ~= "verified" then
      ready_err = "junit5 classpath not verified yet: " .. vim.inspect(cp_res)
      return false
    end
    return true
  end, 500)
  assert(
    jdtls_ready,
    "JDTLS did not finish indexing symbols + JUnit 5 test classpath within 90s: " .. tostring(ready_err)
  )

  -- 3. Scenario 1: Invoke real `java_menu.tests` menu on `add(int, int)` to create `CalculatorTest.java`.
  local add_row, add_col = find_line_1based(calc_path, "return a + b;")
  vim.api.nvim_set_current_buf(calc_buf)
  vim.api.nvim_win_set_cursor(0, { add_row, add_col })

  local flow1_done = false
  local flow1_prompts = {}
  local flow1_confirm_items = nil
  local flow1_method_items = nil
  local flow1_default_name = nil

  vim.ui.select = function(items, opts, on_choice)
    local prompt = opts and opts.prompt or ""
    flow1_prompts[#flow1_prompts + 1] = prompt
    if
      prompt:find("^Java: Tests — ")
      and prompt ~= "Java: Tests — select method"
      and prompt ~= "Java: Tests — confirm JUnit 5 test skeleton"
    then
      local entry = find_item(items, "Create JUnit 5 Test for Method")
      assert(entry, "main Tests menu missing 'Create JUnit 5 Test for Method': " .. vim.inspect(items))
      assert(not entry:find("unavailable:", 1, true), "Create JUnit 5 Test for Method must be enabled: " .. entry)
      on_choice(entry)
    elseif prompt == "Java: Tests — select method" then
      flow1_method_items = vim.deepcopy(items)
      local pick = find_item(items, "Calculator.add(int, int)")
      assert(pick, "documentSymbol method list missing Calculator.add(int, int): " .. vim.inspect(items))
      on_choice(pick)
    elseif prompt == "Java: Tests — confirm JUnit 5 test skeleton" then
      flow1_confirm_items = vim.deepcopy(items)
      local confirm = find_item(items, "✔ Create test file & skeleton")
      assert(confirm, "confirmation prompt missing create action: " .. vim.inspect(items))
      flow1_done = true
      on_choice(confirm)
    else
      error("unexpected vim.ui.select prompt in scenario 1: " .. prompt)
    end
  end

  vim.ui.input = function(opts, on_confirm)
    local prompt = opts and opts.prompt or ""
    assert(prompt == "Java: Tests — test method name: ", "unexpected input prompt: " .. prompt)
    flow1_default_name = opts and opts.default or ""
    on_confirm(flow1_default_name)
  end

  notices = {}
  tests_mod.tests()

  local created = fixtures.wait_for(20000, function()
    return flow1_done and vim.fn.filereadable(test_path) == 1
  end)
  assert(created, "Scenario 1 did not create CalculatorTest.java within 20s")
  assert_no_warn_or_error("scenario 1")

  assert(
    flow1_method_items
      and flow1_method_items[1]:find("Calculator.add(int, int)", 1, true)
      and flow1_method_items[1]:find("[at cursor]", 1, true),
    "expected Calculator.add(int, int) first with [at cursor], got: " .. vim.inspect(flow1_method_items)
  )
  assert(
    find_item(flow1_method_items, "Calculator.subtract(int, int)") ~= nil,
    "expected Calculator.subtract(int, int) in method list: " .. vim.inspect(flow1_method_items)
  )
  assert(
    flow1_default_name == "testAdd",
    "expected default test method name 'testAdd', got: " .. tostring(flow1_default_name)
  )
  assert(
    find_item(flow1_confirm_items, "Classpath: verified (org.junit.jupiter.api.Test on test classpath)") ~= nil,
    "confirmation must report verified JUnit 5 classpath: " .. vim.inspect(flow1_confirm_items)
  )
  assert(
    find_item(flow1_confirm_items, "Target: src/test/java/com/demo/junitreal/CalculatorTest.java  (new file)") ~= nil,
    "confirmation must report new target path: " .. vim.inspect(flow1_confirm_items)
  )
  assert(
    find_item(flow1_confirm_items, "Test method: testAdd()") ~= nil,
    "confirmation must report test method name: " .. vim.inspect(flow1_confirm_items)
  )

  -- Source production file must remain untouched on disk and unmodified in buffer.
  assert(read_raw(calc_path) == original_calc_bytes, "source file Calculator.java was modified on disk in scenario 1")
  assert(not vim.bo[calc_buf].modified, "source buffer Calculator.java became modified in scenario 1")

  local test_buf = track_buf(vim.api.nvim_get_current_buf())
  assert(
    vim.fs.normalize(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(test_buf)) or vim.api.nvim_buf_get_name(test_buf))
      == vim.fs.normalize(vim.uv.fs_realpath(test_path) or test_path),
    "expected generated CalculatorTest.java to be the active buffer"
  )
  assert(not vim.bo[test_buf].modified, "newly created test file buffer should be saved and clean")

  local test_disk_1 = read_raw(test_path)
  assert(test_disk_1:find("package com.demo.junitreal;", 1, true), "missing package declaration")
  assert(test_disk_1:find("import org.junit.jupiter.api.Test;", 1, true), "missing JUnit 5 @Test import")
  assert(test_disk_1:find("void testAdd()", 1, true), "missing void testAdd()")
  assert(
    test_disk_1:find('throw new java.lang.AssertionError("TODO: implement test for Calculator.add(int, int)', 1, true),
    "missing explicit failing TODO body"
  )
  assert(not test_disk_1:find("void test()", 1, true), "dummy empty void test() must not exist")

  -- 4. Compile & execute generated test with JUnit Platform Console Standalone 1.10.2.
  local main_out = root .. "/out/main"
  local test_out = root .. "/out/test"
  local rc1, out1, counts1 =
    compile_and_run_junit(main_out, test_out, calc_path, test_path, { "--select-class", pkg .. ".CalculatorTest" })
  assert(rc1 ~= 0, "expected non-zero exit code when generated failing skeleton executes, got 0:\n" .. out1)
  assert(
    counts1.found == 1
      and counts1.skipped == 0
      and counts1.started == 1
      and counts1.aborted == 0
      and counts1.successful == 0
      and counts1.failed == 1,
    string.format(
      "expected 1 found / 0 skipped / 1 failed in scenario 1, got %s\nOutput:\n%s",
      vim.inspect(counts1),
      out1
    )
  )
  assert(
    out1:find("TODO: implement test for Calculator.add(int, int)", 1, true),
    "JUnit failure output missing TODO skeleton message:\n" .. out1
  )

  -- 5. Scenario 2: Invoke real `java_menu.tests` menu on `subtract(int, int)` with existing `CalculatorTest.java`.
  local sub_row, sub_col = find_line_1based(calc_path, "return a - b;")
  vim.api.nvim_set_current_buf(calc_buf)
  vim.api.nvim_win_set_cursor(0, { sub_row, sub_col })

  local flow2_done = false
  local flow2_confirm_items = nil
  local flow2_method_items = nil
  local flow2_default_name = nil

  vim.ui.select = function(items, opts, on_choice)
    local prompt = opts and opts.prompt or ""
    if
      prompt:find("^Java: Tests — ")
      and prompt ~= "Java: Tests — select method"
      and prompt ~= "Java: Tests — confirm JUnit 5 test skeleton"
    then
      local entry = find_item(items, "Create JUnit 5 Test for Method")
      assert(entry and not entry:find("unavailable:", 1, true), "entry must remain enabled in scenario 2")
      on_choice(entry)
    elseif prompt == "Java: Tests — select method" then
      flow2_method_items = vim.deepcopy(items)
      local pick = find_item(items, "Calculator.subtract(int, int)")
      assert(pick, "documentSymbol method list missing Calculator.subtract(int, int)")
      on_choice(pick)
    elseif prompt == "Java: Tests — confirm JUnit 5 test skeleton" then
      flow2_confirm_items = vim.deepcopy(items)
      local confirm = find_item(items, "✔ Insert test skeleton")
      assert(confirm, "confirmation prompt missing insert action for existing class: " .. vim.inspect(items))
      flow2_done = true
      on_choice(confirm)
    else
      error("unexpected vim.ui.select prompt in scenario 2: " .. prompt)
    end
  end

  vim.ui.input = function(opts, on_confirm)
    flow2_default_name = opts and opts.default or ""
    on_confirm(flow2_default_name)
  end

  notices = {}
  tests_mod.tests()

  local inserted = fixtures.wait_for(20000, function()
    return flow2_done and vim.api.nvim_get_current_buf() == test_buf
  end)
  assert(inserted, "Scenario 2 did not insert skeleton into existing CalculatorTest.java within 20s")
  assert_no_warn_or_error("scenario 2")

  assert(
    flow2_method_items
      and flow2_method_items[1]:find("Calculator.subtract(int, int)", 1, true)
      and flow2_method_items[1]:find("[at cursor]", 1, true),
    "expected Calculator.subtract(int, int) first with [at cursor], got: " .. vim.inspect(flow2_method_items)
  )
  assert(
    flow2_default_name == "testSubtract",
    "expected default name 'testSubtract', got: " .. tostring(flow2_default_name)
  )
  assert(
    find_item(flow2_confirm_items, "Target: src/test/java/com/demo/junitreal/CalculatorTest.java  (existing file)")
      ~= nil,
    "confirmation must report existing target file: " .. vim.inspect(flow2_confirm_items)
  )
  assert(
    find_item(flow2_confirm_items, "Classpath: verified (org.junit.jupiter.api.Test on test classpath)") ~= nil,
    "confirmation must report verified JUnit 5 classpath in scenario 2"
  )

  -- Source production file must STILL be byte-for-byte identical.
  assert(read_raw(calc_path) == original_calc_bytes, "source file Calculator.java was modified on disk in scenario 2")
  assert(not vim.bo[calc_buf].modified, "source buffer Calculator.java became modified in scenario 2")

  local test_buf_lines = vim.api.nvim_buf_get_lines(test_buf, 0, -1, false)
  local test_buf_text = table.concat(test_buf_lines, "\n")
  assert(test_buf_text:find("void testAdd()", 1, true), "existing testAdd() must be preserved")
  assert(test_buf_text:find("void testSubtract()", 1, true), "new testSubtract() must be inserted")
  assert(
    test_buf_text:find(
      'throw new java.lang.AssertionError("TODO: implement test for Calculator.subtract(int, int)',
      1,
      true
    ),
    "missing explicit failing TODO body for testSubtract"
  )
  local _, test_import_count = test_buf_text:gsub("import org%.junit%.jupiter%.api%.Test;", "")
  assert(test_import_count == 1, "expected 1 @Test import, got " .. test_import_count)

  vim.api.nvim_buf_call(test_buf, function()
    vim.cmd("silent write")
  end)

  local rc2, out2, counts2 =
    compile_and_run_junit(main_out, test_out, calc_path, test_path, { "--select-class", pkg .. ".CalculatorTest" })
  assert(rc2 ~= 0, "expected non-zero exit code for existing class with 2 failing skeletons")
  assert(
    counts2.found == 2 and counts2.skipped == 0 and counts2.started == 2 and counts2.failed == 2,
    string.format(
      "expected 2 found / 0 skipped / 2 failed in scenario 2, got %s\nOutput:\n%s",
      vim.inspect(counts2),
      out2
    )
  )

  local rc2_single, out2_single, counts2_single = compile_and_run_junit(
    main_out,
    test_out,
    calc_path,
    test_path,
    { "--select-method", pkg .. ".CalculatorTest#testSubtract" }
  )
  assert(rc2_single ~= 0, "expected non-zero exit code when selecting testSubtract")
  assert(
    counts2_single.found == 1
      and counts2_single.skipped == 0
      and counts2_single.started == 1
      and counts2_single.failed == 1,
    string.format(
      "expected 1 found / 0 skipped / 1 failed for testSubtract, got %s\nOutput:\n%s",
      vim.inspect(counts2_single),
      out2_single
    )
  )

  print(
    string.format(
      "%s: OK (new class: %d found/%d skipped/%d failed; existing class: %d found/%d skipped/%d failed)",
      SPEC_NAME,
      counts1.found,
      counts1.skipped,
      counts1.failed,
      counts2.found,
      counts2.skipped,
      counts2.failed
    )
  )
end

local ok, err = xpcall(run_tests, debug.traceback)
cleanup()
if not ok then
  error(err, 0)
end
vim.cmd("qa!")
