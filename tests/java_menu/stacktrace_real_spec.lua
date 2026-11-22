-- Integration (Issue #15): real JDTLS `workspace/executeCommand` with
-- `java.project.resolveStackTraceLocation` against multi-module and isolated
-- Maven projects.
--
-- Verifies real JDTLS protocol behavior via `java_menu.lsp` + Neovim LSP APIs:
--   1. `workspace/executeCommand` with command `java.project.resolveStackTraceLocation`
--      and `arguments = { full_line }` or `{ full_line, { project_names... } }`,
--      returning a URI string or `nil`.
--   2. Multi-module Maven aggregator (`api` + `service`) compiling offline and
--      producing a real JVM stacktrace whose frames resolve across modules.
--   3. Cursor line handling: reading a stacktrace frame line at the cursor,
--      extracting its line number, resolving the target URI, opening the target
--      buffer, and positioning the cursor on the exact matching source line.
--   4. Nested classes: inner class (`Outer$Inner`), static nested class
--      (`Outer$StaticNested`), and anonymous class (`Outer$StaticNested$1`).
--   5. Native / Unknown Source / missing class / non-stacktrace lines returning
--      `nil` without LSP errors.
--   6. Library `jdt://` resolution from a local compiled dependency JAR
--      (`java/classFileContents` readable, `vim.uri_to_fname` non-readable),
--      plus observed real JDTLS behavior (`nil`) for JDK stdlib frames.
--   7. Identical FQCN disambiguation both via `projectNames` (`{ "dup-a" }` vs
--      `{ "dup-b" }`) in one workspace and across two isolated Maven projects
--      with separate JDTLS clients/workspaces (zero cross-project leakage).
--   8. Optional product action check when `java_menu.stacktrace` is available.
--
-- Run:
--   nvim --headless -u NONE -n \
--     -c "set rtp+=." \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-jdtls" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-lspconfig" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/jc.nvim" \
--     -c "lua local ok, err = pcall(dofile, 'tests/java_menu/stacktrace_real_spec.lua'); if not ok then io.stderr:write(tostring(err)..'\n'); vim.cmd('cquit 1') end" \
--     -c "qa!"

local SPEC_NAME = "stacktrace_real_spec"

local lsp = require("java_menu.lsp")
local fixtures = require("tests.java_menu.fixtures")

local temp_dirs = {}
local started_clients = {}

local function register_dir(dir)
  if dir and dir ~= "" then
    temp_dirs[#temp_dirs + 1] = dir
  end
  return dir
end

local function cleanup()
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

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
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

-- Check runtime prerequisites honestly: skip only when local tools/plugins are absent.
local jdtls_files = vim.api.nvim_get_runtime_file("lua/jdtls.lua", true)
if #jdtls_files == 0 then
  return skip("nvim-jdtls plugin unavailable in runtimepath")
end
local ok_jdtls, jdtls = pcall(require, "jdtls")
if not ok_jdtls or type(jdtls) ~= "table" or type(jdtls.start_or_attach) ~= "function" then
  return skip("nvim-jdtls API unavailable")
end
if vim.fn.executable("mvn") ~= 1 then
  return skip("Maven executable not found")
end
if vim.fn.executable("javac") ~= 1 or vim.fn.executable("jar") ~= 1 or vim.fn.executable("java") ~= 1 then
  return skip("JDK tools (javac/jar/java) not found")
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
  return buf
end

local function lsp_request_sync(client, method, params, bufnr, timeout_ms)
  assert(client, "nil LSP client for " .. method)
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

local function resolve_stacktrace(client, bufnr, frame_line, project_names)
  local args = { frame_line }
  if project_names ~= nil then
    args[2] = project_names
  end
  return lsp_request_sync(client, "workspace/executeCommand", {
    command = "java.project.resolveStackTraceLocation",
    arguments = args,
  }, bufnr, 15000)
end

local function is_nil_res(val)
  return val == nil or val == vim.NIL
end

local function has_command(client, command_name)
  local provider = client.server_capabilities and client.server_capabilities.executeCommandProvider
  local cmds = provider and provider.commands or {}
  for _, cmd in ipairs(cmds) do
    if cmd == command_name then
      return true
    end
  end
  return false
end

local function write_java_unit(module_dir, pkg, name, lines)
  local rel_pkg = pkg:gsub("%.", "/")
  local path = module_dir .. "/src/main/java/" .. rel_pkg .. "/" .. name .. ".java"
  fixtures.write(path, lines)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

local function extract_frame_line(frame_line)
  local lnum = frame_line:match(":(%d+)%)%s*$")
  return lnum and tonumber(lnum) or nil
end

local function open_resolved_uri_at_line(client, uri, lnum)
  if vim.startswith(uri, "file://") then
    local path = vim.fs.normalize(vim.uri_to_fname(uri))
    assert(vim.fn.filereadable(path) == 1, "resolved file:// URI is not readable: " .. path)
    local buf = open_java(path)
    if lnum then
      local line_count = vim.api.nvim_buf_line_count(buf)
      assert(
        lnum >= 1 and lnum <= line_count,
        string.format("line %d out of range [1..%d] in %s", lnum, line_count, path)
      )
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    end
    return buf, vim.api.nvim_get_current_line()
  elseif vim.startswith(uri, "jdt://") then
    local cfc_err, cfc_res = lsp_request_sync(client, "java/classFileContents", { uri = uri }, 0, 15000)
    assert(cfc_err == nil and type(cfc_res) == "string" and #cfc_res > 0, "java/classFileContents failed for " .. uri)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = vim.split(cfc_res:gsub("\r\n", "\n"), "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "java"
    vim.bo[buf].modifiable = false
    vim.api.nvim_set_current_buf(buf)
    if lnum then
      local clamped = math.max(1, math.min(lnum, #lines))
      vim.api.nvim_win_set_cursor(0, { clamped, 0 })
    end
    return buf, vim.api.nvim_get_current_line(), cfc_res
  else
    error("unexpected URI scheme from resolveStackTraceLocation: " .. tostring(uri))
  end
end

local function build_multimodule_project()
  local raw_root = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-stacktrace-multi")
  vim.fn.mkdir(raw_root, "p")
  local root = vim.fs.normalize(vim.uv.fs_realpath(raw_root) or raw_root)
  register_dir(root)

  -- Local dependency JAR compiled with javac + jar (zero network, triggers jdt:// URI).
  local lib_src_dir = root .. "/extlib-src"
  local lib_classes_dir = root .. "/extlib-classes"
  local lib_jar = root .. "/libs/extlib-1.0.jar"
  vim.fn.mkdir(lib_classes_dir, "p")
  vim.fn.mkdir(root .. "/libs", "p")
  local extlib_java = write_java_unit(lib_src_dir, "com.demo.extlib", "ExtLib", {
    "package com.demo.extlib;",
    "",
    "public class ExtLib {",
    "  public static void fail(String message) {",
    "    throw new IllegalStateException(message);",
    "  }",
    "}",
  })
  local jc_out = vim.fn.system({ "javac", "--release", "21", "-g", "-d", lib_classes_dir, extlib_java })
  assert(vim.v.shell_error == 0, "javac failed for ExtLib: " .. jc_out)
  local jar_out = vim.fn.system({ "jar", "cf", lib_jar, "-C", lib_classes_dir, "." })
  assert(vim.v.shell_error == 0, "jar failed for ExtLib: " .. jar_out)

  local api_dir = root .. "/api"
  local service_dir = root .. "/service"
  local dup_a_dir = root .. "/dup-a"
  local dup_b_dir = root .. "/dup-b"

  fixtures.write(root .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.java.menu.test</groupId>",
    "  <artifactId>stacktrace-multi-root</artifactId>",
    "  <version>1.0</version>",
    "  <packaging>pom</packaging>",
    "  <modules>",
    "    <module>api</module>",
    "    <module>service</module>",
    "    <module>dup-a</module>",
    "    <module>dup-b</module>",
    "  </modules>",
    "  <properties>",
    "    <maven.compiler.release>21</maven.compiler.release>",
    "    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>",
    "  </properties>",
    "</project>",
  })

  fixtures.write(api_dir .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <parent>",
    "    <groupId>com.java.menu.test</groupId>",
    "    <artifactId>stacktrace-multi-root</artifactId>",
    "    <version>1.0</version>",
    "  </parent>",
    "  <artifactId>api</artifactId>",
    "  <packaging>jar</packaging>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>com.demo.extlib</groupId>",
    "      <artifactId>extlib</artifactId>",
    "      <version>1.0</version>",
    "      <scope>system</scope>",
    "      <systemPath>" .. lib_jar .. "</systemPath>",
    "    </dependency>",
    "  </dependencies>",
    "</project>",
  })

  fixtures.write(service_dir .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <parent>",
    "    <groupId>com.java.menu.test</groupId>",
    "    <artifactId>stacktrace-multi-root</artifactId>",
    "    <version>1.0</version>",
    "  </parent>",
    "  <artifactId>service</artifactId>",
    "  <packaging>jar</packaging>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>com.java.menu.test</groupId>",
    "      <artifactId>api</artifactId>",
    "      <version>1.0</version>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.demo.extlib</groupId>",
    "      <artifactId>extlib</artifactId>",
    "      <version>1.0</version>",
    "      <scope>system</scope>",
    "      <systemPath>" .. lib_jar .. "</systemPath>",
    "    </dependency>",
    "  </dependencies>",
    "</project>",
  })

  for _, mod_name in ipairs({ "dup-a", "dup-b" }) do
    fixtures.write(root .. "/" .. mod_name .. "/pom.xml", {
      '<project xmlns="http://maven.apache.org/POM/4.0.0">',
      "  <modelVersion>4.0.0</modelVersion>",
      "  <parent>",
      "    <groupId>com.java.menu.test</groupId>",
      "    <artifactId>stacktrace-multi-root</artifactId>",
      "    <version>1.0</version>",
      "  </parent>",
      "  <artifactId>" .. mod_name .. "</artifactId>",
      "  <packaging>jar</packaging>",
      "</project>",
    })
  end

  local api_entry = write_java_unit(api_dir, "com.demo.stack.api", "ApiEntry", {
    "package com.demo.stack.api;",
    "",
    "import com.demo.extlib.ExtLib;",
    "",
    "public class ApiEntry {",
    "  public static void trigger() {",
    '    ExtLib.fail("boom-from-api");',
    "  }",
    "}",
  })

  local service_runner = write_java_unit(service_dir, "com.demo.stack.service", "StackRunner", {
    "package com.demo.stack.service;",
    "",
    "import com.demo.stack.api.ApiEntry;",
    "",
    "public class StackRunner {",
    "  public static void main(String[] args) {",
    "    try {",
    "      new StackRunner().execute();",
    "    } catch (Throwable t) {",
    "      t.printStackTrace(System.out);",
    "    }",
    "  }",
    "",
    "  public void execute() {",
    "    new InnerWorker().runWork();",
    "  }",
    "",
    "  public class InnerWorker {",
    "    public void runWork() {",
    "      StaticNested.invoke();",
    "    }",
    "  }",
    "",
    "  public static class StaticNested {",
    "    public static void invoke() {",
    "      Runnable r = new Runnable() {",
    "        @Override",
    "        public void run() {",
    "          ApiEntry.trigger();",
    "        }",
    "      };",
    "      r.run();",
    "    }",
    "  }",
    "}",
  })

  local dup_a_file = write_java_unit(dup_a_dir, "com.demo.dup", "SameTarget", {
    "package com.demo.dup;",
    "",
    "public class SameTarget {",
    "  public static String origin() {",
    '    return "from-dup-a";',
    "  }",
    "}",
  })

  local dup_b_file = write_java_unit(dup_b_dir, "com.demo.dup", "SameTarget", {
    "package com.demo.dup;",
    "",
    "public class SameTarget {",
    "  // extra line to distinguish dup-b",
    "  public static String origin() {",
    '    return "from-dup-b";',
    "  }",
    "}",
  })

  return root,
    {
      lib_jar = lib_jar,
      api_dir = api_dir,
      service_dir = service_dir,
      api_entry = api_entry,
      service_runner = service_runner,
      dup_a_file = dup_a_file,
      dup_b_file = dup_b_file,
    }
end

local function build_isolated_project(label, marker)
  local raw_root = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-stacktrace-" .. label)
  vim.fn.mkdir(raw_root, "p")
  local root = vim.fs.normalize(vim.uv.fs_realpath(raw_root) or raw_root)
  register_dir(root)

  fixtures.write(root .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.java.menu.test</groupId>",
    "  <artifactId>iso-" .. label .. "</artifactId>",
    "  <version>1.0</version>",
    "  <properties>",
    "    <maven.compiler.release>21</maven.compiler.release>",
    "    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>",
    "  </properties>",
    "</project>",
  })

  local target = write_java_unit(root, "com.demo.isolated", "CollidingClass", {
    "package com.demo.isolated;",
    "",
    "public class CollidingClass {",
    "  public static String who() {",
    '    return "' .. marker .. '";',
    "  }",
    "}",
  })

  return root, target
end

local function run_tests()
  local summary = {
    mvn_offline = "not-run",
    jdk_stdlib_res = "not-checked",
    product_action = "not_implemented",
  }

  local root_multi, files = build_multimodule_project()
  local data_multi = register_dir(root_multi .. "-data")

  -- 1. Offline Maven compile + real JVM execution to obtain authentic stacktrace frames.
  local mvn_out = vim.fn.system({ "mvn", "-o", "-q", "-B", "-f", root_multi .. "/pom.xml", "compile" })
  assert(vim.v.shell_error == 0, "offline Maven compile failed: " .. mvn_out)
  summary.mvn_offline = "ok"

  local cp = table.concat({
    files.service_dir .. "/target/classes",
    files.api_dir .. "/target/classes",
    files.lib_jar,
  }, ":")
  local stack_output = vim.fn.system({ "java", "-cp", cp, "com.demo.stack.service.StackRunner" })
  assert(vim.v.shell_error == 0, "java StackRunner failed: " .. stack_output)

  local raw_lines = vim.split(stack_output, "\n", { plain = true })
  local frames = {}
  for _, line in ipairs(raw_lines) do
    if line:match("^%s*at ") then
      frames[#frames + 1] = line
    end
  end
  assert(#frames >= 7, "expected >=7 real JVM stacktrace frames, got:\n" .. stack_output)

  local function find_frame(pattern)
    for _, line in ipairs(frames) do
      if line:find(pattern, 1, true) then
        return line
      end
    end
    error("expected stacktrace frame matching '" .. pattern .. "' in:\n" .. stack_output)
  end

  local frame_extlib = find_frame("com.demo.extlib.ExtLib.fail(")
  local frame_api = find_frame("com.demo.stack.api.ApiEntry.trigger(")
  local frame_anon = find_frame("com.demo.stack.service.StackRunner$StaticNested$1.run(")
  local frame_static_nested = find_frame("com.demo.stack.service.StackRunner$StaticNested.invoke(")
  local frame_inner = find_frame("com.demo.stack.service.StackRunner$InnerWorker.runWork(")
  local frame_execute = find_frame("com.demo.stack.service.StackRunner.execute(")
  local frame_main = find_frame("com.demo.stack.service.StackRunner.main(")

  -- 2. Attach real JDTLS at multi-module aggregator root.
  local buf_runner = open_java(files.service_runner)
  local client_id = jdtls.start_or_attach({
    cmd = { jdtls_bin, "-data", data_multi },
    root_dir = root_multi,
    capabilities = lsp.capabilities(),
    settings = { java = { configuration = { maven = { offline = true } } } },
  })
  assert(client_id, "JDTLS failed to start for multi-module root")
  local started = vim.lsp.get_client_by_id(client_id)
  assert(started, "started JDTLS client not found")
  started_clients[#started_clients + 1] = started

  assert(
    fixtures.wait_for(60000, function()
      return lsp.client(buf_runner) ~= nil
    end),
    "JDTLS failed to attach at multi-module root within 60s"
  )
  local client_multi = lsp.client(buf_runner)
  assert(client_multi and vim.fs.normalize(client_multi.root_dir or "") == root_multi, "unexpected JDTLS root_dir")
  assert(
    has_command(client_multi, "java.project.resolveStackTraceLocation"),
    "JDTLS did not advertise java.project.resolveStackTraceLocation in executeCommandProvider.commands"
  )

  -- Wait until all 4 modules are imported and cross-module frames resolve.
  local last_poll_info = ""
  assert(
    vim.wait(90000, function()
      local p_err, projs = lsp_request_sync(
        client_multi,
        "workspace/executeCommand",
        { command = "java.project.getAll" },
        buf_runner,
        10000
      )
      if p_err ~= nil or type(projs) ~= "table" or #projs < 4 then
        last_poll_info = "projects=" .. vim.inspect(p_err or projs)
        return false
      end
      local a_err, a_uri = resolve_stacktrace(client_multi, buf_runner, frame_api)
      local s_err, s_uri = resolve_stacktrace(client_multi, buf_runner, frame_main)
      if a_err == nil and type(a_uri) == "string" and s_err == nil and type(s_uri) == "string" then
        return true
      end
      last_poll_info = "api=" .. vim.inspect(a_err or a_uri) .. " svc=" .. vim.inspect(s_err or s_uri)
      return false
    end, 400),
    "JDTLS did not finish indexing multi-module project within 90s: " .. last_poll_info
  )

  -- 3. Multi-module frames + nested classes resolution.
  local uri_api_expected = vim.uri_from_fname(files.api_entry)
  local uri_runner_expected = vim.uri_from_fname(files.service_runner)

  local multi_cases = {
    { label = "api frame", frame = frame_api, expected_uri = uri_api_expected },
    { label = "service main", frame = frame_main, expected_uri = uri_runner_expected },
    { label = "service execute", frame = frame_execute, expected_uri = uri_runner_expected },
    { label = "inner class", frame = frame_inner, expected_uri = uri_runner_expected },
    { label = "static nested class", frame = frame_static_nested, expected_uri = uri_runner_expected },
    { label = "anonymous nested class", frame = frame_anon, expected_uri = uri_runner_expected },
  }
  for _, tc in ipairs(multi_cases) do
    local err, res = resolve_stacktrace(client_multi, buf_runner, tc.frame)
    assert(err == nil, string.format("%s returned LSP error: %s", tc.label, vim.inspect(err)))
    assert(type(res) == "string", string.format("%s expected URI string, got %s", tc.label, vim.inspect(res)))
    assert(
      res == tc.expected_uri,
      string.format("%s URI mismatch: expected %s, got %s", tc.label, tc.expected_uri, res)
    )
  end

  -- 4. Line at cursor ("linha no cursor"): place real stacktrace in a scratch buffer,
  --    read the line under the cursor, resolve via JDTLS, open target, and verify exact line.
  local stack_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(stack_buf, 0, -1, false, raw_lines)

  local cursor_checks = {
    { frame = frame_api, expected_text = 'ExtLib.fail("boom-from-api");' },
    { frame = frame_anon, expected_text = "ApiEntry.trigger();" },
    { frame = frame_static_nested, expected_text = "r.run();" },
    { frame = frame_inner, expected_text = "StaticNested.invoke();" },
    { frame = frame_execute, expected_text = "new InnerWorker().runWork();" },
    { frame = frame_main, expected_text = "new StackRunner().execute();" },
  }

  for _, check in ipairs(cursor_checks) do
    local stack_row = nil
    for idx, line in ipairs(raw_lines) do
      if line == check.frame then
        stack_row = idx
        break
      end
    end
    assert(stack_row, "frame missing from stack_buf: " .. check.frame)

    vim.api.nvim_set_current_buf(stack_buf)
    vim.api.nvim_win_set_cursor(0, { stack_row, 0 })
    local line_at_cursor = vim.api.nvim_get_current_line()
    assert(line_at_cursor == check.frame, "cursor line mismatch in stack_buf")

    local expected_lnum = extract_frame_line(line_at_cursor)
    assert(expected_lnum, "failed to extract line number from: " .. line_at_cursor)

    local r_err, resolved_uri = resolve_stacktrace(client_multi, buf_runner, line_at_cursor)
    assert(
      r_err == nil and type(resolved_uri) == "string",
      "cursor frame failed to resolve: " .. vim.inspect(r_err or resolved_uri)
    )

    local target_buf, target_line_text = open_resolved_uri_at_line(client_multi, resolved_uri, expected_lnum)
    local actual_cursor = vim.api.nvim_win_get_cursor(0)
    assert(
      actual_cursor[1] == expected_lnum,
      string.format("expected cursor at line %d, got %d", expected_lnum, actual_cursor[1])
    )
    assert(
      target_line_text:find(check.expected_text, 1, true),
      string.format(
        "target line %d text mismatch: expected '%s' in '%s' (buf=%d)",
        expected_lnum,
        check.expected_text,
        target_line_text,
        target_buf
      )
    )
  end

  -- Exercise the actual action with the JDTLS client and a project-owned
  -- text buffer containing a frame, rather than resolving the protocol alone.
  do
    local trace_path = root_multi .. "/stacktrace-test.log"
    assert(vim.fn.writefile({ frame_api }, trace_path) == 0, "could not write stack trace fixture")
    vim.cmd("edit " .. vim.fn.fnameescape(trace_path))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local stacktrace = require("java_menu.stacktrace")
    stacktrace.stacktrace()
    local expected_line = extract_frame_line(frame_api)
    local navigated = vim.wait(20000, function()
      return vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(files.api_entry)
    end, 50)
    assert(navigated, "stacktrace action did not navigate to the API source")
    assert(vim.api.nvim_win_get_cursor(0)[1] == expected_line, "stacktrace action jumped to the wrong line")
  end

  -- 5. Library `jdt://` resolution (local JAR dependency) + JDK stdlib observed behavior.
  local ext_err, ext_uri = resolve_stacktrace(client_multi, buf_runner, frame_extlib)
  assert(ext_err == nil, "ExtLib frame returned LSP error: " .. vim.inspect(ext_err))
  assert(
    type(ext_uri) == "string" and vim.startswith(ext_uri, "jdt://"),
    "expected ExtLib library frame to resolve to jdt:// URI, got: " .. vim.inspect(ext_uri)
  )
  assert(
    vim.fn.filereadable(vim.uri_to_fname(ext_uri)) == 0,
    "jdt:// URI unexpectedly resolved to a readable local file"
  )
  local ext_lnum = extract_frame_line(frame_extlib)
  local _, _, ext_source = open_resolved_uri_at_line(client_multi, ext_uri, ext_lnum)
  assert(
    ext_source:find("class ExtLib", 1, true) and ext_source:find("IllegalStateException", 1, true),
    "java/classFileContents did not return ExtLib source: " .. tostring(ext_source)
  )

  do
    local trace_path = root_multi .. "/stacktrace-library.log"
    assert(vim.fn.writefile({ frame_extlib }, trace_path) == 0)
    vim.cmd("edit " .. vim.fn.fnameescape(trace_path))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require("java_menu.stacktrace").stacktrace()
    assert(
      vim.wait(20000, function()
        return vim.api.nvim_buf_get_name(0) == ext_uri
      end, 50),
      "stacktrace action did not open the library URI"
    )
    assert(vim.api.nvim_win_get_cursor(0)[1] == ext_lnum, "stacktrace action jumped to wrong library line")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(table.concat(lines, "\n"):find("IllegalStateException", 1, true), "library source content missing")
  end

  -- JDK stdlib frame (observed real behavior on JDTLS 1.63.0: returns nil).
  local jdk_err, jdk_res =
    resolve_stacktrace(client_multi, buf_runner, "\tat java.base/java.lang.String.valueOf(String.java:4556)")
  assert(jdk_err == nil, "JDK stdlib frame returned unexpected LSP error: " .. vim.inspect(jdk_err))
  if is_nil_res(jdk_res) then
    summary.jdk_stdlib_res = "nil"
  elseif type(jdk_res) == "string" then
    assert(vim.startswith(jdk_res, "jdt://"), "unexpected non-jdt URI for JDK frame: " .. jdk_res)
    summary.jdk_stdlib_res = "jdt://"
  else
    error("unexpected non-string/non-nil result for JDK frame: " .. vim.inspect(jdk_res))
  end

  -- 6. Native / Unknown Source / missing class / non-stacktrace lines -> nil without error.
  local nil_cases = {
    { label = "native method", line = "\tat java.base/java.lang.Object.wait(Native Method)" },
    { label = "unknown source", line = "\tat com.demo.stack.api.ApiEntry.trigger(Unknown Source)" },
    { label = "missing class", line = "\tat com.does.not.Exist.missing(Exist.java:12)" },
    { label = "exception header", line = "java.lang.IllegalStateException: boom-from-api" },
    { label = "plain text", line = "not a stacktrace line at all" },
  }
  for _, tc in ipairs(nil_cases) do
    local n_err, n_res = resolve_stacktrace(client_multi, buf_runner, tc.line)
    assert(n_err == nil, string.format("%s returned LSP error: %s", tc.label, vim.inspect(n_err)))
    assert(is_nil_res(n_res), string.format("%s expected nil, got %s", tc.label, vim.inspect(n_res)))
  end

  -- 7. Identical FQCN disambiguation:
  -- 7a. Same workspace (`dup-a` vs `dup-b`) via optional 2nd argument `projectNames`.
  local dup_frame = "\tat com.demo.dup.SameTarget.origin(SameTarget.java:5)"
  local uri_dup_a_expected = vim.uri_from_fname(files.dup_a_file)
  local uri_dup_b_expected = vim.uri_from_fname(files.dup_b_file)

  local da_err, da_res = resolve_stacktrace(client_multi, buf_runner, dup_frame, { "dup-a" })
  assert(da_err == nil and da_res == uri_dup_a_expected, "dup-a projectNames filter mismatch: " .. vim.inspect(da_res))

  local db_err, db_res = resolve_stacktrace(client_multi, buf_runner, dup_frame, { "dup-b" })
  assert(db_err == nil and db_res == uri_dup_b_expected, "dup-b projectNames filter mismatch: " .. vim.inspect(db_res))
  assert(da_res ~= db_res, "dup-a and dup-b resolved to identical URI")

  -- Project filter scoping: `api` frame restricted to `{ "service" }` yields nil, `{ "api" }` and `{}` yield api URI.
  local scoped_miss_err, scoped_miss = resolve_stacktrace(client_multi, buf_runner, frame_api, { "service" })
  assert(scoped_miss_err == nil and is_nil_res(scoped_miss), "expected nil when filtering api frame to service")
  local scoped_hit_err, scoped_hit = resolve_stacktrace(client_multi, buf_runner, frame_api, { "api" })
  assert(scoped_hit_err == nil and scoped_hit == uri_api_expected, "expected api URI when filtering to api")
  local empty_proj_err, empty_proj = resolve_stacktrace(client_multi, buf_runner, frame_api, {})
  assert(empty_proj_err == nil and empty_proj == uri_api_expected, "expected api URI with empty projectNames list")

  -- 7b. Two separate standalone Maven projects with identical FQCN and isolated JDTLS clients.
  local iso_root_a, iso_file_a = build_isolated_project("iso-a", "marker-a")
  local iso_root_b, iso_file_b = build_isolated_project("iso-b", "marker-b")
  local iso_data_a = register_dir(iso_root_a .. "-data")
  local iso_data_b = register_dir(iso_root_b .. "-data")

  local buf_iso_a = open_java(iso_file_a)
  local cid_a = jdtls.start_or_attach({
    cmd = { jdtls_bin, "-data", iso_data_a },
    root_dir = iso_root_a,
    capabilities = lsp.capabilities(),
    settings = { java = { configuration = { maven = { offline = true } } } },
  })
  assert(cid_a, "JDTLS failed to start for isolated Project A")
  started_clients[#started_clients + 1] = vim.lsp.get_client_by_id(cid_a)
  assert(
    fixtures.wait_for(60000, function()
      local c = lsp.client(buf_iso_a)
      return c ~= nil and vim.fs.normalize(c.root_dir or "") == iso_root_a
    end),
    "JDTLS A failed to attach"
  )
  local client_iso_a = lsp.client(buf_iso_a)

  local buf_iso_b = open_java(iso_file_b)
  local cid_b = jdtls.start_or_attach({
    cmd = { jdtls_bin, "-data", iso_data_b },
    root_dir = iso_root_b,
    capabilities = lsp.capabilities(),
    settings = { java = { configuration = { maven = { offline = true } } } },
  })
  assert(cid_b, "JDTLS failed to start for isolated Project B")
  started_clients[#started_clients + 1] = vim.lsp.get_client_by_id(cid_b)
  assert(
    fixtures.wait_for(60000, function()
      local c = lsp.client(buf_iso_b)
      return c ~= nil and vim.fs.normalize(c.root_dir or "") == iso_root_b
    end),
    "JDTLS B failed to attach"
  )
  local client_iso_b = lsp.client(buf_iso_b)

  assert(client_iso_a.id ~= client_iso_b.id, "isolated projects reused the same JDTLS client")
  assert(
    client_iso_a.id ~= client_multi.id and client_iso_b.id ~= client_multi.id,
    "isolated project reused multi client"
  )

  local iso_frame = "\tat com.demo.isolated.CollidingClass.who(CollidingClass.java:5)"
  local iso_uri_a_expected = vim.uri_from_fname(iso_file_a)
  local iso_uri_b_expected = vim.uri_from_fname(iso_file_b)

  local got_iso_a, got_iso_b
  assert(
    vim.wait(60000, function()
      local ea, ra = resolve_stacktrace(client_iso_a, buf_iso_a, iso_frame)
      local eb, rb = resolve_stacktrace(client_iso_b, buf_iso_b, iso_frame)
      if ea == nil and type(ra) == "string" and eb == nil and type(rb) == "string" then
        got_iso_a = ra
        got_iso_b = rb
        return true
      end
      return false
    end, 400),
    "isolated projects did not resolve CollidingClass within 60s"
  )

  assert(got_iso_a == iso_uri_a_expected, "Project A leaked or resolved wrong URI: " .. tostring(got_iso_a))
  assert(got_iso_b == iso_uri_b_expected, "Project B leaked or resolved wrong URI: " .. tostring(got_iso_b))
  assert(not got_iso_a:find(iso_root_b, 1, true), "Project A URI leaked Project B path")
  assert(not got_iso_b:find(iso_root_a, 1, true), "Project B URI leaked Project A path")

  -- 8. Product action check (only if implemented & available).
  local ok_menu, java_menu = pcall(require, "java_menu")
  local has_action = ok_menu and type(java_menu.actions) == "table" and java_menu.actions.stacktrace ~= nil
  local ok_mod, stack_mod = pcall(require, "java_menu.stacktrace")
  if has_action and ok_mod and type(stack_mod) == "table" then
    local entry_name = java_menu.actions.stacktrace.entry or "stacktrace"
    if type(stack_mod[entry_name]) == "function" then
      summary.product_action = "available(" .. entry_name .. ")"
    else
      summary.product_action = "module_present_without_entry"
    end
  end

  print(
    string.format(
      "%s: OK (mvn_offline=%s; jdt_extlib=ok; jdk_stdlib=%s; iso_clients=ok; product_action=%s)",
      SPEC_NAME,
      summary.mvn_offline,
      summary.jdk_stdlib_res,
      summary.product_action
    )
  )
end

local ok, err = xpcall(run_tests, debug.traceback)
cleanup()
if not ok then
  error(err, 0)
end
vim.cmd("qa!")
