-- Integration (Issue #14): real JDTLS Call Hierarchy and Type Hierarchy menu
-- navigation across a multi-module Maven aggregator project (`api` + `service`).
--
-- Project layout:
--   <root>/pom.xml                 (aggregator: modules api, service)
--   <root>/api/pom.xml             (interface Greeter + greet(String))
--   <root>/service/pom.xml         (depends on api; DefaultGreeter + GreetingRunner)
--
-- Verifies real JDTLS attached at the aggregator root and real menu navigation
-- through `java_menu.calls.calls()` and `java_menu.types.types()`:
--   1. Calls incoming (`api` Greeter.greet -> `service` GreetingRunner.run).
--   2. Calls outgoing (`service` GreetingRunner.run -> `api` Greeter.greet).
--   3. Types interface -> implementation (`api` Greeter -> `service` DefaultGreeter).
--   4. Types class -> interface (`service` DefaultGreeter -> `api` Greeter).
--
-- Run:
--   nvim --headless -u NONE -n \
--     -c "set rtp+=." \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-jdtls" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-lspconfig" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/jc.nvim" \
--     -c "lua local ok, err = pcall(dofile, 'tests/java_menu/hierarchy_multimodule_real_spec.lua'); if not ok then io.stderr:write(tostring(err)..'\n'); vim.cmd('cquit 1') end" \
--     -c "qa!"

local SPEC_NAME = "hierarchy_multimodule_real_spec"

local lsp = require("java_menu.lsp")
local project = require("java_menu.project")
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
  pcall(function()
    if package.loaded["java_menu.calls"] then
      require("java_menu.calls")._reset()
    end
    if package.loaded["java_menu.types"] then
      require("java_menu.types")._reset()
    end
    if package.loaded["java_menu.hierarchy"] then
      require("java_menu.hierarchy").reset_jdt_bufs()
    end
  end)

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

-- Check runtime prerequisites honestly: skip only when local JDTLS/plugin is absent.
local jdtls_files = vim.api.nvim_get_runtime_file("lua/jdtls.lua", true)
if #jdtls_files == 0 then
  return skip("nvim-jdtls plugin unavailable in runtimepath")
end
local ok_jdtls, jdtls = pcall(require, "jdtls")
assert(ok_jdtls, "nvim-jdtls failed to load: " .. tostring(jdtls))
assert(type(jdtls) == "table" and type(jdtls.start_or_attach) == "function", "nvim-jdtls API unavailable")
if vim.fn.executable("mvn") ~= 1 then
  return skip("Maven executable not found")
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

local function find_token_pos(path, line_pattern, token)
  local lines = vim.fn.readfile(path)
  for idx, line in ipairs(lines) do
    if line:find(line_pattern, 1, true) then
      local s = line:find(token, 1, true)
      assert(s, string.format("token '%s' not found on line matching '%s' in %s", token, line_pattern, path))
      return idx - 1, s - 1, line
    end
  end
  error(string.format("line matching '%s' not found in %s", line_pattern, path))
end

local function position_params(bufnr, client, line, col)
  return {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line, character = col },
    offsetEncoding = lsp.encoding(client),
  }
end

local function write_java_unit(module_dir, pkg, name, lines)
  local rel_pkg = pkg:gsub("%.", "/")
  local path = module_dir .. "/src/main/java/" .. rel_pkg .. "/" .. name .. ".java"
  fixtures.write(path, lines)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

local function build_multimodule_project()
  local raw_root = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-multimodule")
  vim.fn.mkdir(raw_root, "p")
  local root = vim.fs.normalize(vim.uv.fs_realpath(raw_root) or raw_root)
  register_dir(root)

  local api_dir = root .. "/api"
  local service_dir = root .. "/service"

  fixtures.write(root .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.java.menu.test</groupId>",
    "  <artifactId>multimodule-root</artifactId>",
    "  <version>1.0</version>",
    "  <packaging>pom</packaging>",
    "  <modules>",
    "    <module>api</module>",
    "    <module>service</module>",
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
    "    <artifactId>multimodule-root</artifactId>",
    "    <version>1.0</version>",
    "  </parent>",
    "  <artifactId>api</artifactId>",
    "  <packaging>jar</packaging>",
    "</project>",
  })

  fixtures.write(service_dir .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <parent>",
    "    <groupId>com.java.menu.test</groupId>",
    "    <artifactId>multimodule-root</artifactId>",
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
    "  </dependencies>",
    "</project>",
  })

  local pkg_api = "com.demo.multi.api"
  local pkg_service = "com.demo.multi.service"

  local greeter_path = write_java_unit(api_dir, pkg_api, "Greeter", {
    "package " .. pkg_api .. ";",
    "",
    "public interface Greeter {",
    "  String greet(String name);",
    "}",
  })

  local impl_path = write_java_unit(service_dir, pkg_service, "DefaultGreeter", {
    "package " .. pkg_service .. ";",
    "",
    "import " .. pkg_api .. ".Greeter;",
    "",
    "public class DefaultGreeter implements Greeter {",
    "  @Override",
    "  public String greet(String name) {",
    '    return "Hello, " + name;',
    "  }",
    "}",
  })

  local caller_path = write_java_unit(service_dir, pkg_service, "GreetingRunner", {
    "package " .. pkg_service .. ";",
    "",
    "import " .. pkg_api .. ".Greeter;",
    "",
    "public class GreetingRunner {",
    "  private final Greeter greeter;",
    "",
    "  public GreetingRunner(Greeter greeter) {",
    "    this.greeter = greeter;",
    "  }",
    "",
    "  public String run(String name) {",
    "    return greeter.greet(name);",
    "  }",
    "}",
  })

  return root,
    {
      api_dir = api_dir,
      service_dir = service_dir,
      pkg_api = pkg_api,
      pkg_service = pkg_service,
      greeter = greeter_path,
      impl = impl_path,
      caller = caller_path,
    }
end

local function wait_for_multimodule_indexed(client, buf_greeter, files)
  local greet_line, greet_col = find_token_pos(files.greeter, "String greet(String name);", "greet")
  local greeter_line, greeter_col = find_token_pos(files.greeter, "public interface Greeter", "Greeter")

  local last_info = ""
  local ready = vim.wait(90000, function()
    local c_err, c_items = lsp_request_sync(
      client,
      "textDocument/prepareCallHierarchy",
      position_params(buf_greeter, client, greet_line, greet_col),
      buf_greeter,
      10000
    )
    if c_err ~= nil or type(c_items) ~= "table" or #c_items == 0 then
      last_info = "prepareCallHierarchy=" .. vim.inspect(c_err or c_items)
      return false
    end

    local inc_err, inc =
      lsp_request_sync(client, "callHierarchy/incomingCalls", { item = c_items[1] }, buf_greeter, 10000)
    if inc_err ~= nil or type(inc) ~= "table" or #inc == 0 then
      last_info = "incomingCalls=" .. vim.inspect(inc_err or inc)
      return false
    end

    local has_caller = false
    for _, call in ipairs(inc) do
      if call.from and call.from.uri == vim.uri_from_fname(files.caller) then
        has_caller = true
        break
      end
    end
    if not has_caller then
      last_info = "incomingCalls missing GreetingRunner: " .. vim.inspect(inc)
      return false
    end

    local t_err, t_items = lsp_request_sync(
      client,
      "textDocument/prepareTypeHierarchy",
      position_params(buf_greeter, client, greeter_line, greeter_col),
      buf_greeter,
      10000
    )
    if t_err ~= nil or type(t_items) ~= "table" or #t_items == 0 then
      last_info = "prepareTypeHierarchy=" .. vim.inspect(t_err or t_items)
      return false
    end

    local sub_err, sub = lsp_request_sync(client, "typeHierarchy/subtypes", { item = t_items[1] }, buf_greeter, 10000)
    if sub_err ~= nil or type(sub) ~= "table" or #sub == 0 then
      last_info = "subtypes=" .. vim.inspect(sub_err or sub)
      return false
    end

    for _, item in ipairs(sub) do
      if item.uri == vim.uri_from_fname(files.impl) then
        return true
      end
    end
    last_info = "subtypes missing DefaultGreeter: " .. vim.inspect(sub)
    return false
  end, 400)

  assert(ready, "JDTLS did not finish indexing cross-module api <-> service hierarchy within 90s: " .. last_info)
end

local function find_matching_label(items, fragments)
  for _, label in ipairs(items) do
    local matched = true
    for _, frag in ipairs(fragments) do
      if not label:find(frag, 1, true) then
        matched = false
        break
      end
    end
    if matched then
      return label
    end
  end
  return nil
end

local function run_tests()
  local summary = {
    mvn_offline = "not-run",
  }

  local root, files = build_multimodule_project()
  local data_dir = register_dir(root .. "-data")

  -- Compilation failures are failures, including missing offline dependencies.
  do
    local mvn_out = vim.fn.system({ "mvn", "-o", "-q", "-B", "-f", root .. "/pom.xml", "compile" })
    assert(vim.v.shell_error == 0, "offline Maven compile failed: " .. mvn_out)
    summary.mvn_offline = "ok"
    assert(
      vim.fn.filereadable(files.api_dir .. "/target/classes/com/demo/multi/api/Greeter.class") == 1,
      "mvn -o compile succeeded but api Greeter.class missing"
    )
    assert(
      vim.fn.filereadable(files.service_dir .. "/target/classes/com/demo/multi/service/DefaultGreeter.class") == 1,
      "mvn -o compile succeeded but service DefaultGreeter.class missing"
    )
    assert(
      vim.fn.filereadable(files.service_dir .. "/target/classes/com/demo/multi/service/GreetingRunner.class") == 1,
      "mvn -o compile succeeded but service GreetingRunner.class missing"
    )
  end

  -- Attach real JDTLS at the aggregator root.
  local buf_greeter = open_java(files.greeter)
  local client_id = jdtls.start_or_attach({
    cmd = { jdtls_bin, "-data", data_dir },
    root_dir = root,
    capabilities = lsp.capabilities(),
  })
  assert(client_id, "JDTLS could not be started")
  local started = vim.lsp.get_client_by_id(client_id)
  assert(started, "started JDTLS client not found")
  started_clients[#started_clients + 1] = started

  local attached = fixtures.wait_for(60000, function()
    return lsp.client(buf_greeter) ~= nil
  end)
  assert(attached, "JDTLS failed to attach at aggregator root within 60s")
  local client = lsp.client(buf_greeter)
  assert(client, "nil JDTLS client")
  assert(
    vim.fs.normalize(client.root_dir or "") == root,
    string.format("expected JDTLS root_dir=%s, got %s", root, tostring(client.root_dir))
  )

  assert(
    client.server_capabilities and client.server_capabilities.callHierarchyProvider,
    "JDTLS did not advertise callHierarchyProvider capability"
  )
  assert(
    client.server_capabilities and client.server_capabilities.typeHierarchyProvider,
    "JDTLS did not advertise typeHierarchyProvider capability"
  )

  local buf_impl = open_java(files.impl)
  local buf_caller = open_java(files.caller)
  assert(vim.lsp.buf_attach_client(buf_impl, client.id), "failed to attach DefaultGreeter buffer")
  assert(vim.lsp.buf_attach_client(buf_caller, client.id), "failed to attach GreetingRunner buffer")
  assert(
    fixtures.wait_for(30000, function()
      return lsp.client(buf_impl) == client and lsp.client(buf_caller) == client
    end),
    "service buffers did not attach to aggregator JDTLS client"
  )

  -- Verify project.root resolves to the aggregator root for both modules.
  assert(
    project.root(buf_greeter) == root,
    string.format("expected project.root(api)=%s, got %s", root, tostring(project.root(buf_greeter)))
  )
  assert(
    project.root(buf_impl) == root and project.root(buf_caller) == root,
    "expected project.root(service) to resolve to aggregator root"
  )

  wait_for_multimodule_indexed(client, buf_greeter, files)

  local greet_line, greet_col = find_token_pos(files.greeter, "String greet(String name);", "greet")
  local greeter_line, greeter_col = find_token_pos(files.greeter, "public interface Greeter", "Greeter")
  local impl_line, impl_col = find_token_pos(files.impl, "public class DefaultGreeter", "DefaultGreeter")
  local run_line, run_col = find_token_pos(files.caller, "public String run(String name)", "run")
  local callsite_line, callsite_col = find_token_pos(files.caller, "return greeter.greet(name);", "greet(")

  local rel_greeter = "api/src/main/java/com/demo/multi/api/Greeter.java"
  local rel_impl = "service/src/main/java/com/demo/multi/service/DefaultGreeter.java"
  local rel_caller = "service/src/main/java/com/demo/multi/service/GreetingRunner.java"

  local ui = require("java_menu.ui")
  local calls = require("java_menu.calls")
  local types = require("java_menu.types")
  local original_pick = ui.pick_one

  local function run_two_step_menu(
    trigger_fn,
    expected_menu_prompt,
    menu_fragment,
    expected_result_prompt_frag,
    result_fragments
  )
    local stage = 0
    local captured = {
      menu_items = nil,
      menu_choice = nil,
      result_prompt = nil,
      result_items = nil,
      result_choice = nil,
      err = nil,
    }

    ui.pick_one = function(items, prompt, callback)
      local ok_pick, pick_err = xpcall(function()
        stage = stage + 1
        if stage == 1 then
          assert(
            prompt == expected_menu_prompt,
            string.format("expected menu prompt '%s', got '%s'", expected_menu_prompt, tostring(prompt))
          )
          captured.menu_items = items
          local choice = find_matching_label(items, { menu_fragment })
          assert(choice, string.format("menu entry '%s' not found in %s", menu_fragment, vim.inspect(items)))
          assert(
            not choice:find("unavailable", 1, true),
            string.format("menu entry '%s' unexpectedly unavailable: %s", menu_fragment, choice)
          )
          captured.menu_choice = choice
          callback(choice)
        elseif stage == 2 then
          assert(
            type(prompt) == "string" and prompt:find(expected_result_prompt_frag, 1, true),
            string.format(
              "expected result prompt containing '%s', got '%s'",
              expected_result_prompt_frag,
              tostring(prompt)
            )
          )
          captured.result_prompt = prompt
          captured.result_items = items
          local choice = find_matching_label(items, result_fragments)
          assert(
            choice,
            string.format("expected result entry matching %s in %s", vim.inspect(result_fragments), vim.inspect(items))
          )
          captured.result_choice = choice
          callback(choice)
        else
          error("unexpected extra ui.pick_one call (" .. tostring(prompt) .. "): " .. vim.inspect(items))
        end
      end, debug.traceback)
      if not ok_pick then
        captured.err = pick_err
      end
    end

    trigger_fn()
    return captured
  end

  local ui_ok, ui_err = xpcall(function()
    -- 1. Calls Incoming via menu: api (Greeter.greet) -> service (GreetingRunner.run call site)
    vim.api.nvim_set_current_buf(buf_greeter)
    vim.api.nvim_win_set_cursor(0, { greet_line + 1, greet_col })
    local incoming_pos = string.format("%d:%d", callsite_line + 1, callsite_col + 1)
    local inc_cap = run_two_step_menu(
      calls.calls,
      "Java: Call Hierarchy",
      "Incoming Calls (callers)",
      "Java: Incoming Calls",
      { "run", "[" .. files.pkg_service .. ".GreetingRunner]", rel_caller .. ":" .. incoming_pos }
    )
    assert(
      vim.wait(15000, function()
        return inc_cap.err ~= nil or (inc_cap.result_choice ~= nil and vim.api.nvim_get_current_buf() == buf_caller)
      end, 50),
      "calls incoming menu did not navigate to GreetingRunner.java"
    )
    assert(inc_cap.err == nil, inc_cap.err)
    assert(
      vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == files.caller,
      "calls incoming navigated to wrong path: " .. vim.api.nvim_buf_get_name(0)
    )
    local inc_cursor = vim.api.nvim_win_get_cursor(0)
    assert(
      inc_cursor[1] == callsite_line + 1 and inc_cursor[2] == callsite_col,
      string.format(
        "calls incoming cursor mismatch: expected (%d,%d), got (%d,%d)",
        callsite_line + 1,
        callsite_col,
        inc_cursor[1],
        inc_cursor[2]
      )
    )

    -- 2. Calls Outgoing via menu: service (GreetingRunner.run) -> api (Greeter.greet declaration)
    vim.api.nvim_win_set_cursor(0, { run_line + 1, run_col })
    local outgoing_pos = string.format("%d:%d", greet_line + 1, greet_col + 1)
    local out_from_tag = string.format("(from L%d)", callsite_line + 1)
    local out_cap = run_two_step_menu(
      calls.calls,
      "Java: Call Hierarchy",
      "Outgoing Calls (callees)",
      "Java: Outgoing Calls",
      { "greet", "[" .. files.pkg_api .. ".Greeter]", rel_greeter .. ":" .. outgoing_pos, out_from_tag }
    )
    assert(
      vim.wait(15000, function()
        return out_cap.err ~= nil or (out_cap.result_choice ~= nil and vim.api.nvim_get_current_buf() == buf_greeter)
      end, 50),
      "calls outgoing menu did not navigate to Greeter.java"
    )
    assert(out_cap.err == nil, out_cap.err)
    assert(
      vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == files.greeter,
      "calls outgoing navigated to wrong path: " .. vim.api.nvim_buf_get_name(0)
    )
    local out_cursor = vim.api.nvim_win_get_cursor(0)
    assert(
      out_cursor[1] == greet_line + 1 and out_cursor[2] == greet_col,
      string.format(
        "calls outgoing cursor mismatch: expected (%d,%d), got (%d,%d)",
        greet_line + 1,
        greet_col,
        out_cursor[1],
        out_cursor[2]
      )
    )

    -- 3. Types interface -> implementation via menu (Subtypes): api (Greeter) -> service (DefaultGreeter)
    vim.api.nvim_set_current_buf(buf_greeter)
    vim.api.nvim_win_set_cursor(0, { greeter_line + 1, greeter_col })
    local impl_pos = string.format("%d:%d", impl_line + 1, impl_col + 1)
    local sub_cap = run_two_step_menu(
      types.types,
      "Java: Type Hierarchy",
      "Subtypes",
      "Java: Subtypes — Greeter",
      { "DefaultGreeter", "[" .. files.pkg_service .. "]", rel_impl .. ":" .. impl_pos }
    )
    assert(
      vim.wait(15000, function()
        return sub_cap.err ~= nil or (sub_cap.result_choice ~= nil and vim.api.nvim_get_current_buf() == buf_impl)
      end, 50),
      "types subtypes menu did not navigate to DefaultGreeter.java"
    )
    assert(sub_cap.err == nil, sub_cap.err)
    assert(
      vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == files.impl,
      "types subtypes navigated to wrong path: " .. vim.api.nvim_buf_get_name(0)
    )
    local sub_cursor = vim.api.nvim_win_get_cursor(0)
    assert(
      sub_cursor[1] == impl_line + 1 and sub_cursor[2] == impl_col,
      string.format(
        "types subtypes cursor mismatch: expected (%d,%d), got (%d,%d)",
        impl_line + 1,
        impl_col,
        sub_cursor[1],
        sub_cursor[2]
      )
    )

    -- 4. Types class -> interface via menu (Supertypes): service (DefaultGreeter) -> api (Greeter)
    local greeter_pos = string.format("%d:%d", greeter_line + 1, greeter_col + 1)
    local sup_cap = run_two_step_menu(
      types.types,
      "Java: Type Hierarchy",
      "Supertypes",
      "Java: Supertypes — DefaultGreeter",
      { "Greeter", "[" .. files.pkg_api .. "]", rel_greeter .. ":" .. greeter_pos }
    )
    assert(
      vim.wait(15000, function()
        return sup_cap.err ~= nil or (sup_cap.result_choice ~= nil and vim.api.nvim_get_current_buf() == buf_greeter)
      end, 50),
      "types supertypes menu did not navigate to Greeter.java"
    )
    assert(sup_cap.err == nil, sup_cap.err)
    assert(
      vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == files.greeter,
      "types supertypes navigated to wrong path: " .. vim.api.nvim_buf_get_name(0)
    )
    local sup_cursor = vim.api.nvim_win_get_cursor(0)
    assert(
      sup_cursor[1] == greeter_line + 1 and sup_cursor[2] == greeter_col,
      string.format(
        "types supertypes cursor mismatch: expected (%d,%d), got (%d,%d)",
        greeter_line + 1,
        greeter_col,
        sup_cursor[1],
        sup_cursor[2]
      )
    )

    -- 5. Types interface -> implementation via menu (Implementations): api (Greeter) -> service (DefaultGreeter)
    vim.api.nvim_set_current_buf(buf_greeter)
    vim.api.nvim_win_set_cursor(0, { greeter_line + 1, greeter_col })
    local impl_cap = run_two_step_menu(
      types.types,
      "Java: Type Hierarchy",
      "Implementations",
      "Java: Implementations — Greeter",
      { "public class DefaultGreeter implements Greeter {", rel_impl .. ":" .. impl_pos }
    )
    assert(
      vim.wait(15000, function()
        return impl_cap.err ~= nil or (impl_cap.result_choice ~= nil and vim.api.nvim_get_current_buf() == buf_impl)
      end, 50),
      "types implementations menu did not navigate to DefaultGreeter.java"
    )
    assert(impl_cap.err == nil, impl_cap.err)
    assert(
      vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == files.impl,
      "types implementations navigated to wrong path: " .. vim.api.nvim_buf_get_name(0)
    )
    local impl_cursor = vim.api.nvim_win_get_cursor(0)
    assert(
      impl_cursor[1] == impl_line + 1 and impl_cursor[2] == impl_col,
      string.format(
        "types implementations cursor mismatch: expected (%d,%d), got (%d,%d)",
        impl_line + 1,
        impl_col,
        impl_cursor[1],
        impl_cursor[2]
      )
    )
  end, debug.traceback)

  ui.pick_one = original_pick
  assert(ui_ok, ui_err)

  print(string.format("%s: OK (menu api<->service calls+types; mvn_offline=%s)", SPEC_NAME, summary.mvn_offline))
end

local ok, err = xpcall(run_tests, debug.traceback)
cleanup()
if not ok then
  error(err, 0)
end
vim.cmd("qa!")
