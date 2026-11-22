-- Integration (Issue #12): real JDTLS Call Hierarchy responses against isolated
-- Java Maven projects.
--
-- Inspired by tests/java_menu/fixtures.lua and tests/java_menu/lsp_clients_spec.lua.
-- Verifies raw LSP server behavior directly via java_menu.lsp + Neovim LSP APIs
-- without assuming any unimplemented Call Hierarchy UI module:
--   1. Real JDTLS attachment + server capability `callHierarchyProvider`.
--   2. `textDocument/prepareCallHierarchy` from both method declaration and call site,
--      plus empty/nil response on a non-callable position.
--   3. `callHierarchy/incomingCalls` (multi-caller + multi-hop + exact `fromRanges`
--      positions matching call-site tokens in source files).
--   4. `callHierarchy/outgoingCalls` (same-class helper, cross-class call, and JDK
--      library call returning a `jdt://` URI).
--   5. Real `jdt://` URI inspection and limitations (non-`file://` scheme, not a
--      local readable file path, `java/classFileContents` behavior, and
--      `prepareCallHierarchy` / `outgoingCalls` behavior on `jdt://` items).
--   6. Separate Maven projects (A and B) with distinct JDTLS clients/workspaces
--      and colliding class/method names (`Entry.run`), asserting zero cross-project
--      leakage.
--
-- Run:
--   nvim --headless -u NONE -n \
--     -c "set rtp+=." \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-jdtls" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-lspconfig" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/jc.nvim" \
--     -c "lua local ok, err = pcall(dofile, 'tests/java_menu/call_hierarchy_real_spec.lua'); if not ok then io.stderr:write(tostring(err)..'\n'); vim.cmd('cquit 1') end" \
--     -c "qa!"

local SPEC_NAME = "call_hierarchy_real_spec"

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

-- Check runtime prerequisites honestly: skip only when local JDTLS/plugin is absent.
local ok_jdtls, jdtls = pcall(require, "jdtls")
if not ok_jdtls or type(jdtls.start_or_attach) ~= "function" then
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

local function slice_range(path, range)
  assert(range and range.start and range["end"], "missing LSP range")
  local lines = vim.fn.readfile(path)
  local line = lines[range.start.line + 1]
  assert(line, string.format("line %d out of bounds in %s", range.start.line + 1, path))
  if range.start.line == range["end"].line then
    return line:sub(range.start.character + 1, range["end"].character)
  end
  return line:sub(range.start.character + 1)
end

local function position_params(bufnr, client, line, col)
  return {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line, character = col },
    offsetEncoding = lsp.encoding(client),
  }
end

local function run_tests()
  local summary = {
    mvn_offline = "not-run",
    jdt_uri_samples = {},
    jdt_limitations = {},
  }

  -- 1. Build isolated Maven Project A with known incoming/outgoing call graph.
  local root_a, entry_a = fixtures.maven_project("callhier-a", "com.demo.callhier", "Entry")
  register_dir(root_a)
  local data_a = register_dir(root_a .. "-data")

  local calc_a = fixtures.java_file(
    root_a,
    "com.demo.callhier",
    "Calculator",
    [[
  public int add(int a, int b) {
    return a + b;
  }]]
  )

  local service_a = fixtures.java_file(
    root_a,
    "com.demo.callhier",
    "Service",
    [[
  private final Calculator calculator = new Calculator();

  public int compute(int base) {
    int clean = normalize(base);
    int sum = calculator.add(clean, 10);
    String formatted = String.valueOf(sum);
    return formatted.length();
  }

  private int normalize(int n) {
    return Math.max(n, 0);
  }]]
  )

  entry_a = fixtures.java_file(
    root_a,
    "com.demo.callhier",
    "Entry",
    [[
  private final Service service = new Service();
  private final Calculator calculator = new Calculator();

  public static void main(String[] args) {
    new Entry().run();
  }

  public int run() {
    int first = service.compute(5);
    int second = calculator.add(first, 1);
    return second;
  }]]
  )

  -- Optional offline Maven verification (zero external deps, should compile offline if m2 cache has compiler plugin).
  if vim.fn.executable("mvn") == 1 then
    local mvn_out = vim.fn.system({ "mvn", "-o", "-q", "-B", "-f", root_a .. "/pom.xml", "compile" })
    if vim.v.shell_error == 0 then
      summary.mvn_offline = "ok"
      assert(
        vim.fn.filereadable(root_a .. "/target/classes/com/demo/callhier/Entry.class") == 1,
        "mvn -o compile succeeded but Entry.class missing"
      )
    else
      summary.mvn_offline = "unavailable_or_uncached: " .. vim.trim(mvn_out):gsub("\n", " | ")
    end
  else
    summary.mvn_offline = "mvn_absent"
  end

  -- 2. Attach real JDTLS client to Project A.
  local buf_entry_a = open_java(entry_a)
  jdtls.start_or_attach({
    cmd = { jdtls_bin, "-data", data_a },
    root_dir = root_a,
    capabilities = lsp.capabilities(),
  })

  local attached_a = fixtures.wait_for(60000, function()
    return lsp.client(buf_entry_a) ~= nil
  end)
  assert(attached_a, "JDTLS A failed to attach within 60s")
  local client_a = lsp.client(buf_entry_a)
  assert(client_a and client_a.root_dir == root_a, "JDTLS A attached with unexpected root_dir")
  started_clients[#started_clients + 1] = client_a

  assert(
    client_a.server_capabilities and client_a.server_capabilities.callHierarchyProvider,
    "JDTLS A did not advertise callHierarchyProvider capability"
  )

  -- Open remaining Project A files so buffers exist and share client_a.
  local buf_calc_a = open_java(calc_a)
  local buf_service_a = open_java(service_a)
  assert(vim.lsp.buf_attach_client(buf_calc_a, client_a.id), "failed to attach Calculator buffer")
  assert(vim.lsp.buf_attach_client(buf_service_a, client_a.id), "failed to attach Service buffer")
  assert(
    fixtures.wait_for(30000, function()
      return lsp.client(buf_calc_a) == client_a and lsp.client(buf_service_a) == client_a
    end),
    "Project A buffers did not attach to client_a"
  )

  -- Wait until JDTLS finishes Maven import & indexing by polling prepareCallHierarchy on Calculator.add.
  local add_line, add_col = find_token_pos(calc_a, "public int add(", "add")
  assert(add_line == 3, "expected Calculator.add at 0-based line 3, got " .. add_line)

  local add_items, last_prep_err
  local indexed_a = vim.wait(60000, function()
    local err, res = lsp_request_sync(
      client_a,
      "textDocument/prepareCallHierarchy",
      position_params(buf_calc_a, client_a, add_line, add_col),
      buf_calc_a,
      10000
    )
    last_prep_err = err
    if err == nil and type(res) == "table" and #res > 0 then
      add_items = res
      return true
    end
    return false
  end, 300)
  assert(
    indexed_a,
    "JDTLS A did not index Calculator.add for prepareCallHierarchy within 60s; last err=" .. vim.inspect(last_prep_err)
  )

  -- 3. Verify `textDocument/prepareCallHierarchy` on declaration and exact positions.
  assert(#add_items == 1, "expected 1 CallHierarchyItem for Calculator.add, got " .. #add_items)
  local add_item = add_items[1]
  assert(add_item.name:find("add", 1, true), "unexpected item.name for add: " .. tostring(add_item.name))
  assert(add_item.uri == vim.uri_from_fname(calc_a), "unexpected Calculator.add URI: " .. tostring(add_item.uri))
  assert(
    add_item.selectionRange.start.line == add_line,
    string.format("expected selectionRange line %d, got %d", add_line, add_item.selectionRange.start.line)
  )
  assert(
    slice_range(calc_a, add_item.selectionRange) == "add",
    "selectionRange did not slice to 'add': " .. slice_range(calc_a, add_item.selectionRange)
  )

  -- Also prepare from call site in Entry.run() (`calculator.add(first, 1)`).
  local call_add_line, call_add_col = find_token_pos(entry_a, "calculator.add(first, 1)", "add")
  local prep_callsite_err, prep_callsite_res = lsp_request_sync(
    client_a,
    "textDocument/prepareCallHierarchy",
    position_params(buf_entry_a, client_a, call_add_line, call_add_col),
    buf_entry_a
  )
  assert(prep_callsite_err == nil, "prepareCallHierarchy from call site failed: " .. vim.inspect(prep_callsite_err))
  assert(
    type(prep_callsite_res) == "table" and #prep_callsite_res == 1,
    "expected 1 item preparing from call site calculator.add, got " .. vim.inspect(prep_callsite_res)
  )
  assert(
    prep_callsite_res[1].uri == vim.uri_from_fname(calc_a)
      and prep_callsite_res[1].selectionRange.start.line == add_line,
    "prepareCallHierarchy on call site did not resolve to Calculator.add declaration"
  )

  -- Non-callable position (package line) should return nil/vim.NIL or empty table without LSP error.
  local prep_pkg_err, prep_pkg_res = lsp_request_sync(
    client_a,
    "textDocument/prepareCallHierarchy",
    position_params(buf_calc_a, client_a, 0, 2),
    buf_calc_a
  )
  assert(prep_pkg_err == nil, "prepareCallHierarchy on package line returned error: " .. vim.inspect(prep_pkg_err))
  assert(
    prep_pkg_res == nil or prep_pkg_res == vim.NIL or (type(prep_pkg_res) == "table" and #prep_pkg_res == 0),
    "expected empty/nil prepareCallHierarchy on package line, got " .. vim.inspect(prep_pkg_res)
  )

  -- 4. Verify `callHierarchy/incomingCalls` on Calculator.add (2 callers: Service.compute and Entry.run).
  local inc_add_err, inc_add =
    lsp_request_sync(client_a, "callHierarchy/incomingCalls", { item = add_item }, buf_calc_a)
  assert(inc_add_err == nil, "incomingCalls(Calculator.add) returned error: " .. vim.inspect(inc_add_err))
  assert(
    type(inc_add) == "table" and #inc_add == 2,
    "expected 2 incoming callers for add, got " .. vim.inspect(inc_add)
  )

  local callers_by_uri = {}
  for _, call in ipairs(inc_add) do
    assert(call.from and call.from.uri, "incoming call missing `from` item")
    assert(type(call.fromRanges) == "table" and #call.fromRanges >= 1, "incoming call missing `fromRanges`")
    callers_by_uri[call.from.uri] = call
  end

  local service_call = callers_by_uri[vim.uri_from_fname(service_a)]
  local entry_call = callers_by_uri[vim.uri_from_fname(entry_a)]
  assert(service_call, "missing incoming caller from Service.java")
  assert(entry_call, "missing incoming caller from Entry.java")
  assert(
    service_call.from.name:find("compute", 1, true),
    "unexpected caller name in Service.java: " .. service_call.from.name
  )
  assert(entry_call.from.name:find("run", 1, true), "unexpected caller name in Entry.java: " .. entry_call.from.name)

  local svc_add_line = find_token_pos(service_a, "calculator.add(clean, 10)", "add")
  assert(
    service_call.fromRanges[1].start.line == svc_add_line,
    string.format(
      "Service.compute -> add fromRange line mismatch: expected %d, got %d",
      svc_add_line,
      service_call.fromRanges[1].start.line
    )
  )
  assert(
    slice_range(service_a, service_call.fromRanges[1]):match("^add%f[^%w_]"),
    "Service.compute fromRange slice mismatch: " .. slice_range(service_a, service_call.fromRanges[1])
  )
  assert(
    entry_call.fromRanges[1].start.line == call_add_line,
    string.format(
      "Entry.run -> add fromRange line mismatch: expected %d, got %d",
      call_add_line,
      entry_call.fromRanges[1].start.line
    )
  )
  assert(
    slice_range(entry_a, entry_call.fromRanges[1]):match("^add%f[^%w_]"),
    "Entry.run fromRange slice mismatch: " .. slice_range(entry_a, entry_call.fromRanges[1])
  )

  -- Multi-hop incoming chain: Service.compute -> Entry.run -> Entry.main.
  local inc_compute_err, inc_compute =
    lsp_request_sync(client_a, "callHierarchy/incomingCalls", { item = service_call.from }, buf_service_a)
  assert(inc_compute_err == nil, "incomingCalls(Service.compute) failed: " .. vim.inspect(inc_compute_err))
  assert(type(inc_compute) == "table" and #inc_compute == 1, "expected 1 caller for Service.compute")
  assert(inc_compute[1].from.name:find("run", 1, true), "expected Entry.run as caller of Service.compute")

  local inc_run_err, inc_run =
    lsp_request_sync(client_a, "callHierarchy/incomingCalls", { item = inc_compute[1].from }, buf_entry_a)
  assert(inc_run_err == nil, "incomingCalls(Entry.run) failed: " .. vim.inspect(inc_run_err))
  assert(type(inc_run) == "table" and #inc_run == 1, "expected 1 caller for Entry.run (Entry.main)")
  assert(inc_run[1].from.name:find("main", 1, true), "expected Entry.main as caller of Entry.run")
  local main_run_line = find_token_pos(entry_a, "new Entry().run()", "run")
  assert(inc_run[1].fromRanges[1].start.line == main_run_line, "Entry.main -> run fromRange line mismatch")
  assert(
    slice_range(entry_a, inc_run[1].fromRanges[1]):match("^run%f[^%w_]"),
    "Entry.main -> run fromRange slice mismatch"
  )

  -- 5. Verify `callHierarchy/outgoingCalls` on Service.compute (local, cross-class, and JDK `jdt://`).
  local out_compute_err, out_compute =
    lsp_request_sync(client_a, "callHierarchy/outgoingCalls", { item = service_call.from }, buf_service_a)
  assert(out_compute_err == nil, "outgoingCalls(Service.compute) failed: " .. vim.inspect(out_compute_err))
  assert(
    type(out_compute) == "table" and #out_compute >= 4,
    "expected >=4 outgoing calls from compute, got " .. #out_compute
  )

  local saw_normalize, saw_calc_add, saw_value_of, saw_length = false, false, false, false
  local jdt_items = {}
  for _, call in ipairs(out_compute) do
    assert(call.to and call.to.name and call.to.uri, "outgoing call missing `to` fields")
    assert(type(call.fromRanges) == "table" and #call.fromRanges >= 1, "outgoing call missing `fromRanges`")
    local name = call.to.name
    local tok = slice_range(service_a, call.fromRanges[1])
    if name:find("normalize", 1, true) and call.to.uri == vim.uri_from_fname(service_a) then
      saw_normalize = true
      assert(tok:match("%f[%w_]normalize%f[^%w_]"), "normalize fromRange slice mismatch: " .. tok)
    elseif name:find("add", 1, true) and call.to.uri == vim.uri_from_fname(calc_a) then
      saw_calc_add = true
      assert(tok:match("%f[%w_]add%f[^%w_]"), "add fromRange slice mismatch: " .. tok)
    elseif name:find("valueOf", 1, true) then
      saw_value_of = true
      assert(tok:match("%f[%w_]valueOf%f[^%w_]"), "valueOf fromRange slice mismatch: " .. tok)
      jdt_items[#jdt_items + 1] = call.to
    elseif name:find("length", 1, true) then
      saw_length = true
      assert(tok:match("%f[%w_]length%f[^%w_]"), "length fromRange slice mismatch: " .. tok)
      jdt_items[#jdt_items + 1] = call.to
    end
  end
  assert(saw_normalize, "outgoingCalls missing local Service.normalize")
  assert(saw_calc_add, "outgoingCalls missing cross-class Calculator.add")
  assert(saw_value_of, "outgoingCalls missing JDK String.valueOf")
  assert(saw_length, "outgoingCalls missing JDK String.length")

  -- 6. Verify real `jdt://` URI behavior and document/assert its limitations.
  assert(#jdt_items >= 2, "expected at least 2 JDK CallHierarchyItems with jdt:// URIs")
  for _, jdt_item in ipairs(jdt_items) do
    assert(
      vim.startswith(jdt_item.uri, "jdt://"),
      "expected JDK outgoing target to use jdt:// URI, got: " .. tostring(jdt_item.uri)
    )
    summary.jdt_uri_samples[#summary.jdt_uri_samples + 1] = jdt_item.uri

    -- Limitation 1: `vim.uri_to_fname` does not yield a readable filesystem path for `jdt://`.
    local fname = vim.uri_to_fname(jdt_item.uri)
    assert(
      vim.fn.filereadable(fname) == 0,
      "jdt:// URI unexpectedly resolved to a readable local file: " .. tostring(fname)
    )
  end
  summary.jdt_limitations[#summary.jdt_limitations + 1] =
    "jdt:// URI is virtual (not file://) and vim.uri_to_fname() is not readable on disk"

  -- Inspect what JDTLS returns for `java/classFileContents` and `callHierarchy/outgoingCalls` on a `jdt://` item.
  local jdk_item = jdt_items[1]
  local cfc_err, cfc_res = lsp_request_sync(client_a, "java/classFileContents", { uri = jdk_item.uri }, buf_service_a)
  assert(cfc_err == nil and type(cfc_res) == "string" and #cfc_res > 0, "java/classFileContents failed on jdt:// URI")
  summary.jdt_limitations[#summary.jdt_limitations + 1] = "reading source for jdt:// targets requires JDTLS custom request java/classFileContents (returned "
    .. #cfc_res
    .. " bytes)"

  local jdk_out_err, jdk_out_res =
    lsp_request_sync(client_a, "callHierarchy/outgoingCalls", { item = jdk_item }, buf_service_a)
  assert(jdk_out_err == nil, "outgoingCalls on jdt:// item returned error: " .. vim.inspect(jdk_out_err))
  local jdk_out_count = type(jdk_out_res) == "table" and #jdk_out_res or 0
  summary.jdt_limitations[#summary.jdt_limitations + 1] =
    string.format("callHierarchy/outgoingCalls on JDK jdt:// item (%s) returned %d items", jdk_item.name, jdk_out_count)

  local jdk_prep_err, jdk_prep_res = lsp_request_sync(client_a, "textDocument/prepareCallHierarchy", {
    textDocument = { uri = jdk_item.uri },
    position = jdk_item.selectionRange.start,
    offsetEncoding = lsp.encoding(client_a),
  }, buf_service_a)
  assert(jdk_prep_err == nil, "prepareCallHierarchy on jdt:// URI returned error: " .. vim.inspect(jdk_prep_err))
  local jdk_prep_count = type(jdk_prep_res) == "table" and #jdk_prep_res or 0
  summary.jdt_limitations[#summary.jdt_limitations + 1] =
    string.format("prepareCallHierarchy directly on jdt:// URI (%s) returned %d items", jdk_item.name, jdk_prep_count)

  -- 7. Separate Maven Project B with colliding class/method name (`Entry.run`), isolated workspace/client.
  local root_b, entry_b = fixtures.maven_project("callhier-b", "com.other.callhier", "Entry")
  register_dir(root_b)
  local data_b = register_dir(root_b .. "-data")

  local other_service_b = fixtures.java_file(
    root_b,
    "com.other.callhier",
    "OtherService",
    [[
  public int work(int v) {
    return v * 2;
  }]]
  )

  entry_b = fixtures.java_file(
    root_b,
    "com.other.callhier",
    "Entry",
    [[
  private final OtherService otherService = new OtherService();

  public int run() {
    return otherService.work(7);
  }]]
  )

  local buf_entry_b = open_java(entry_b)
  jdtls.start_or_attach({
    cmd = { jdtls_bin, "-data", data_b },
    root_dir = root_b,
    capabilities = lsp.capabilities(),
  })

  local attached_b = fixtures.wait_for(60000, function()
    local c = lsp.client(buf_entry_b)
    return c ~= nil and c.root_dir == root_b
  end)
  assert(attached_b, "JDTLS B failed to attach to Project B")
  local client_b = lsp.client(buf_entry_b)
  assert(client_b and client_b.id ~= client_a.id, "Project B reused Project A's JDTLS client")
  started_clients[#started_clients + 1] = client_b
  assert(lsp.global_count() >= 2, "expected at least 2 active JDTLS clients")
  assert(lsp.client(buf_entry_a) == client_a, "Project A buffer lost client_a after Project B attached")

  local run_b_line, run_b_col = find_token_pos(entry_b, "public int run()", "run")
  local run_b_items, last_b_err
  local indexed_b = vim.wait(60000, function()
    local err, res = lsp_request_sync(
      client_b,
      "textDocument/prepareCallHierarchy",
      position_params(buf_entry_b, client_b, run_b_line, run_b_col),
      buf_entry_b,
      10000
    )
    last_b_err = err
    if err == nil and type(res) == "table" and #res > 0 then
      run_b_items = res
      return true
    end
    return false
  end, 300)
  assert(indexed_b, "JDTLS B did not index Entry.run within 60s; last err=" .. vim.inspect(last_b_err))
  assert(#run_b_items == 1 and run_b_items[1].uri == vim.uri_from_fname(entry_b), "Entry.run in B resolved wrong URI")

  local out_b_err, out_b =
    lsp_request_sync(client_b, "callHierarchy/outgoingCalls", { item = run_b_items[1] }, buf_entry_b)
  assert(out_b_err == nil, "outgoingCalls(Project B Entry.run) failed: " .. vim.inspect(out_b_err))
  assert(type(out_b) == "table" and #out_b == 1, "expected 1 outgoing call in Project B, got " .. vim.inspect(out_b))
  assert(
    out_b[1].to.uri == vim.uri_from_fname(other_service_b) and out_b[1].to.name:find("work", 1, true),
    "Project B Entry.run did not resolve to OtherService.work: " .. vim.inspect(out_b)
  )
  assert(not out_b[1].to.uri:find(root_a, 1, true), "Project B call hierarchy leaked Project A path")

  -- Re-check Project A via client_a while client_b is running: must still return Project A callers only.
  local inc_a_again_err, inc_a_again =
    lsp_request_sync(client_a, "callHierarchy/incomingCalls", { item = add_item }, buf_calc_a)
  assert(inc_a_again_err == nil and type(inc_a_again) == "table" and #inc_a_again == 2)
  for _, call in ipairs(inc_a_again) do
    assert(
      not call.from.uri:find(root_b, 1, true),
      "Project A call hierarchy leaked Project B path: " .. tostring(call.from.uri)
    )
  end

  -- Exercise the plugin's actual asynchronous UI and navigation against JDTLS.
  local ui = require("java_menu.ui")
  local calls = require("java_menu.calls")
  local original_pick = ui.pick_one
  local chosen_label
  local function select_result(fragment)
    chosen_label = nil
    ui.pick_one = function(items, _, callback)
      for _, label in ipairs(items) do
        if label:find(fragment, 1, true) then
          chosen_label = label
          callback(label)
          return
        end
      end
      error("expected call hierarchy entry containing " .. fragment .. ": " .. vim.inspect(items))
    end
  end
  local ui_ok, ui_err = xpcall(function()
    vim.api.nvim_set_current_buf(buf_calc_a)
    vim.api.nvim_win_set_cursor(0, { add_line + 1, add_col })
    select_result("Service.java")
    calls.incoming()
    assert(
      vim.wait(15000, function()
        return chosen_label ~= nil and vim.api.nvim_get_current_buf() == buf_service_a
      end, 50),
      "incoming menu did not navigate to Service.java"
    )
    assert(vim.api.nvim_win_get_cursor(0)[1] == svc_add_line + 1, "incoming menu selected the wrong call site")

    local compute_line, compute_col = find_token_pos(service_a, "public int compute(", "compute")
    vim.api.nvim_win_set_cursor(0, { compute_line + 1, compute_col })
    select_result("Calculator.java")
    calls.outgoing()
    assert(
      vim.wait(15000, function()
        return chosen_label ~= nil and vim.api.nvim_get_current_buf() == buf_calc_a
      end, 50),
      "outgoing menu did not navigate to Calculator.java"
    )
    assert(vim.api.nvim_win_get_cursor(0)[1] == add_line + 1, "outgoing menu selected the wrong definition")
  end, debug.traceback)
  ui.pick_one = original_pick
  assert(ui_ok, ui_err)

  print(
    string.format(
      "%s: OK (mvn_offline=%s; jdt_uris=%d; limitations=%s)",
      SPEC_NAME,
      summary.mvn_offline,
      #summary.jdt_uri_samples,
      table.concat(summary.jdt_limitations, " | ")
    )
  )
end

local ok, err = xpcall(run_tests, debug.traceback)
cleanup()
if not ok then
  error(err, 0)
end
vim.cmd("qa!")
