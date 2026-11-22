-- Issue #16: Create explicitly pending/failing JUnit 5 test skeleton for a
-- selected method via JDTLS textDocument/documentSymbol (deterministic FAST spec).
--
-- Covers:
--   1. Menu availability & disabled reasons (non-java, non-src/main, detached, no capability)
--   2. Real JUnit 5 classpath verification via java.project.getClasspaths (never trusting pom text alone)
--   3. Type hierarchy (nested classes, enums, multiple top-level types, ignoring local/anon types)
--   4. Overloads with explicit signature selection, cursor hint without guessing, no generated assertions
--   5. Valid Java identifier & collision-free naming + comment/string-safe test file analysis
--   6. Safe imports (no duplicates, JUnit 4 / TestNG conflict avoidance, single-line class expansion)
--   7. Multi-module counterpart reuse & jc.templates reuse for new test files
--   8. Multi-JDTLS client selection, cancellation ($/cancelRequest), changedtick/buffer guards
--   9. Dirty target buffer refusal, cancel-at-any-step safety, and exclusive wx / disk-race protection
--
-- Run:
--   tests/java_menu/run.sh fast

local tests_mod = require("java_menu.tests")
local ui = require("java_menu.ui")
local fixtures = require("tests.java_menu.fixtures")

local real_notify = vim.notify
local real_select = vim.ui.select
local real_input = vim.ui.input
local real_get_clients = vim.lsp.get_clients

local notices = {}
local function clear_notices()
  notices = {}
end
local function last_notice()
  return notices[#notices]
end
local function has_notice(needle)
  for _, n in ipairs(notices) do
    if n.msg:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local select_calls = {}
local function stub_select(chooser)
  select_calls = {}
  vim.ui.select = function(items, opts, on_choice)
    local entry = {
      items = vim.deepcopy(items),
      prompt = opts and opts.prompt or "",
    }
    select_calls[#select_calls + 1] = entry
    local choice
    if type(chooser) == "function" then
      choice = chooser(items, opts, #select_calls)
    else
      choice = chooser
    end
    on_choice(choice)
  end
end

local input_calls = {}
local function stub_input(responder)
  input_calls = {}
  vim.ui.input = function(opts, on_confirm)
    local entry = {
      prompt = opts and opts.prompt or "",
      default = opts and opts.default or "",
    }
    input_calls[#input_calls + 1] = entry
    local val
    if type(responder) == "function" then
      val = responder(opts, #input_calls)
    else
      val = responder
    end
    on_confirm(val)
  end
end

local function defer_select()
  local captured = {}
  vim.ui.select = function(items, opts, on_choice)
    captured[#captured + 1] = {
      items = vim.deepcopy(items),
      prompt = opts and opts.prompt or "",
      choose = function(choice)
        on_choice(choice)
      end,
    }
  end
  return captured
end

local temp_dirs = {}
local created_bufs = {}

local function track_dir(dir)
  temp_dirs[#temp_dirs + 1] = dir
  return dir
end

local function track_buf(buf)
  if buf and buf > 0 then
    created_bufs[#created_bufs + 1] = buf
  end
  return buf
end

local function canonical(path)
  local norm = vim.fs.normalize(path)
  return vim.fs.normalize(vim.uv.fs_realpath(norm) or norm)
end

local function write_raw_bytes(path, bytes)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(vim.uv.fs_open(path, "w", 438))
  assert(vim.uv.fs_write(fd, bytes, 0) == #bytes)
  assert(vim.uv.fs_close(fd))
  return path
end

local function u16le(n)
  return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32le(n)
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

---Build a minimal uncompressed ZIP/JAR file containing `entries` ({ { name, data }, ... }).
local function write_minimal_jar(path, entries)
  local local_parts = {}
  local cd_parts = {}
  local offset = 0
  for _, e in ipairs(entries) do
    local name = e.name
    local data = e.data or ""
    local lh = "PK\3\4"
      .. u16le(20)
      .. u16le(0)
      .. u16le(0)
      .. u16le(0)
      .. u16le(0)
      .. u32le(0)
      .. u32le(#data)
      .. u32le(#data)
      .. u16le(#name)
      .. u16le(0)
      .. name
      .. data
    local cd = "PK\1\2"
      .. u16le(20)
      .. u16le(20)
      .. u16le(0)
      .. u16le(0)
      .. u16le(0)
      .. u16le(0)
      .. u32le(0)
      .. u32le(#data)
      .. u32le(#data)
      .. u16le(#name)
      .. u16le(0)
      .. u16le(0)
      .. u16le(0)
      .. u16le(0)
      .. u32le(0)
      .. u32le(offset)
      .. name
    local_parts[#local_parts + 1] = lh
    cd_parts[#cd_parts + 1] = cd
    offset = offset + #lh
  end
  local cd_blob = table.concat(cd_parts)
  local eocd = "PK\5\6"
    .. u16le(0)
    .. u16le(0)
    .. u16le(#entries)
    .. u16le(#entries)
    .. u32le(#cd_blob)
    .. u32le(offset)
    .. u16le(0)
  return write_raw_bytes(path, table.concat(local_parts) .. cd_blob .. eocd)
end

local function make_junit5_api_jar(dir, name)
  return write_minimal_jar(dir .. "/" .. (name or "junit-jupiter-api-5.10.2.jar"), {
    { name = "org/junit/jupiter/api/Test.class", data = "\xca\xfe\xba\xbe" },
  })
end

local function make_junit5_engine_jar(dir, name)
  return write_minimal_jar(dir .. "/" .. (name or "junit-jupiter-engine-5.10.2.jar"), {
    { name = "org/junit/jupiter/engine/JupiterTestEngine.class", data = "\xca\xfe\xba\xbe" },
  })
end

local function open_java(path, lines)
  if lines then
    fixtures.write(path, lines)
  end
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "java"
  return track_buf(buf)
end

local function find_item(items, needle)
  for _, item in ipairs(items or {}) do
    if item:find(needle, 1, true) then
      return item
    end
  end
  return nil
end

local function flush_schedule()
  vim.wait(40, function()
    return false
  end, 5)
end

local function make_mock_client(opts)
  opts = opts or {}
  local next_id = 500
  local sent = {}
  local cancelled = {}
  local pending = {}

  local client = {
    id = opts.id or 1,
    name = opts.name or "jdtls",
    root_dir = opts.root_dir,
    offset_encoding = opts.offset_encoding or "utf-16",
    server_capabilities = opts.server_capabilities ~= nil and opts.server_capabilities or {
      documentSymbolProvider = true,
      executeCommandProvider = { commands = { "java.project.getClasspaths" } },
    },
    _stopped = opts.stopped == true,
    _sent = sent,
    _cancelled = cancelled,
  }

  function client:is_stopped()
    return self._stopped
  end

  function client:supports_method(method)
    if self._stopped then
      return false
    end
    local caps = self.server_capabilities or {}
    if method == "textDocument/documentSymbol" then
      return caps.documentSymbolProvider ~= nil and caps.documentSymbolProvider ~= false
    end
    if method == "workspace/executeCommand" then
      return caps.executeCommandProvider ~= nil and caps.executeCommandProvider ~= false
    end
    return false
  end

  function client:request(method, params, cb)
    next_id = next_id + 1
    local req_id = next_id
    sent[#sent + 1] = { id = req_id, method = method, params = params }
    if opts.defer then
      pending[req_id] = function(err, res)
        cb(err, res)
      end
      return true, req_id
    end
    if opts.handler then
      local err, res = opts.handler(method, params, req_id, self)
      cb(err, res)
      return true, req_id
    end
    cb(nil, nil)
    return true, req_id
  end

  function client:cancel_request(req_id)
    cancelled[#cancelled + 1] = req_id
  end

  function client:respond(req_id, err, res)
    local fn = pending[req_id]
    pending[req_id] = nil
    if fn then
      fn(err, res)
    end
  end

  return client
end

local function cleanup()
  pcall(function()
    tests_mod._reset()
  end)
  vim.notify = real_notify
  vim.ui.select = real_select
  vim.ui.input = real_input
  vim.lsp.get_clients = real_get_clients
  for _, buf in ipairs(created_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  for _, dir in ipairs(temp_dirs) do
    pcall(vim.fn.delete, dir, "rf")
  end
end

local function run_all()
  vim.notify = function(msg, level)
    notices[#notices + 1] = { msg = tostring(msg), level = level }
  end

  -- ---------- 1. Menu availability & reasons ----------

  local root, calc_main = fixtures.maven_project(
    "junit-method-fast",
    "com.acme",
    "Calc",
    [[
  public int add(int a, int b) { return a + b; }
]]
  )
  track_dir(root)
  local calc_test = root .. "/src/test/java/com/acme/CalcTest.java"
  fixtures.write(calc_test, { "package com.acme;", "", "public class CalcTest {}" })

  -- Non-Java file (pom.xml)
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/pom.xml"))
  vim.bo[0].filetype = "xml"
  vim.lsp.get_clients = function()
    return { make_mock_client({ root_dir = root }) }
  end
  stub_select(nil)
  tests_mod.tests()
  local pom_entry = find_item(select_calls[1].items, "Create JUnit 5 Test for Method")
  assert(
    pom_entry and pom_entry:find("(unavailable: open a .java file)", 1, true),
    "non-java entry should be disabled: " .. tostring(pom_entry)
  )

  -- File outside src/main/java
  local scratch_java = root .. "/Scratch.java"
  open_java(scratch_java, { "public class Scratch { void x() {} }" })
  stub_select(nil)
  tests_mod.tests()
  local scratch_entry = find_item(select_calls[1].items, "Create JUnit 5 Test for Method")
  assert(
    scratch_entry and scratch_entry:find("(unavailable: open a .java file under src/main/java", 1, true),
    "scratch file should be disabled: " .. tostring(scratch_entry)
  )

  -- Test file under src/test/java
  open_java(calc_test)
  stub_select(nil)
  tests_mod.tests()
  local test_entry = find_item(select_calls[1].items, "Create JUnit 5 Test for Method")
  assert(
    test_entry and test_entry:find("(unavailable: open a .java source file under src/main/java)", 1, true),
    "test file should disable method skeleton entry: " .. tostring(test_entry)
  )

  -- Java source without JDTLS attached
  open_java(calc_main)
  vim.lsp.get_clients = function()
    return {}
  end
  stub_select(nil)
  tests_mod.tests()
  local no_jdtls_entry = find_item(select_calls[1].items, "Create JUnit 5 Test for Method")
  assert(
    no_jdtls_entry and no_jdtls_entry:find("(unavailable: jdtls is not attached to this buffer)", 1, true),
    "detached jdtls should disable entry: " .. tostring(no_jdtls_entry)
  )

  -- Java source with JDTLS lacking documentSymbolProvider
  vim.lsp.get_clients = function()
    return { make_mock_client({ root_dir = root, server_capabilities = { documentSymbolProvider = false } }) }
  end
  stub_select(nil)
  tests_mod.tests()
  local no_ds_entry = find_item(select_calls[1].items, "Create JUnit 5 Test for Method")
  assert(
    no_ds_entry and no_ds_entry:find("does not support textDocument/documentSymbol", 1, true),
    "missing documentSymbolProvider should disable entry: " .. tostring(no_ds_entry)
  )

  -- Enabled even without neotest and with multiple JDTLS clients attached!
  vim.lsp.get_clients = function()
    return {
      make_mock_client({ id = 11, root_dir = root }),
      make_mock_client({ id = 12, root_dir = root }),
    }
  end
  stub_select(nil)
  tests_mod.tests()
  local enabled_entry = find_item(select_calls[1].items, "Create JUnit 5 Test for Method")
  assert(
    enabled_entry and not enabled_entry:find("unavailable:", 1, true),
    "entry should be enabled with documentSymbol even without neotest and with 2 clients: " .. tostring(enabled_entry)
  )

  -- ---------- 2. Classpath verification (no textual pom guessing) ----------

  -- 2a. pom.xml has textual "junit" (e.g. junit 4 or un-synced), but getClasspaths lacks junit-jupiter -> REFUSE!
  local j4_root, j4_main = fixtures.maven_project(
    "junit4-trap",
    "com.trap",
    "Trap",
    [[
  public int ping() { return 1; }
]]
  )
  track_dir(j4_root)
  fixtures.write(j4_root .. "/pom.xml", {
    "<project>",
    "  <!-- junit-jupiter-api commented out -->",
    "  <dependencies><dependency><groupId>junit</groupId><artifactId>junit</artifactId><version>4.13.2</version></dependency></dependencies>",
    "</project>",
  })
  local j4_client = make_mock_client({
    root_dir = j4_root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "Trap",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              selectionRange = { start = { line = 2, character = 13 }, ["end"] = { line = 2, character = 17 } },
              children = {
                {
                  name = "ping()",
                  detail = " : int",
                  kind = 6,
                  range = { start = { line = 3, character = 2 }, ["end"] = { line = 3, character = 30 } },
                  selectionRange = { start = { line = 3, character = 13 }, ["end"] = { line = 3, character = 17 } },
                },
              },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil,
          {
            classpaths = {
              j4_root .. "/target/classes",
              "/m2/junit/junit/4.13.2/junit-4.13.2.jar",
            },
          }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { j4_client }
  end
  open_java(j4_main)
  clear_notices()
  stub_select(function(items)
    return items[1]
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(
    has_notice("only JUnit 3/4 found"),
    "must refuse when only JUnit 4 is on JDTLS test classpath despite 'junit' text in pom.xml"
  )
  assert(
    vim.fn.filereadable(j4_root .. "/src/test/java/com/trap/TrapTest.java") == 0,
    "refused JUnit 4 project must not create TrapTest.java"
  )

  -- 2b. Empty test classpath (no junit at all) -> REFUSE!
  local empty_cp_client = make_mock_client({
    root_dir = j4_root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "Trap",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              selectionRange = { start = { line = 2, character = 13 }, ["end"] = { line = 2, character = 17 } },
              children = {
                {
                  name = "ping()",
                  kind = 6,
                  range = { start = { line = 3, character = 2 }, ["end"] = { line = 3, character = 30 } },
                  selectionRange = { start = { line = 3, character = 13 }, ["end"] = { line = 3, character = 17 } },
                },
              },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { j4_root .. "/target/classes" } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { empty_cp_client }
  end
  clear_notices()
  tests_mod.create_method_test()
  flush_schedule()
  assert(has_notice("was not found on the JDTLS test classpath"), "must refuse when JUnit 5 is missing on classpath")
  assert(vim.fn.filereadable(j4_root .. "/src/test/java/com/trap/TrapTest.java") == 0)

  -- 2c. Client without java.project.getClasspaths capability -> warns honestly + marks UNVERIFIED in confirmation
  local unverified_client = make_mock_client({
    root_dir = j4_root,
    server_capabilities = { documentSymbolProvider = true },
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "Trap",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              selectionRange = { start = { line = 2, character = 13 }, ["end"] = { line = 2, character = 17 } },
              children = {
                {
                  name = "ping()",
                  detail = " : int",
                  kind = 6,
                  range = { start = { line = 3, character = 2 }, ["end"] = { line = 3, character = 30 } },
                  selectionRange = { start = { line = 3, character = 13 }, ["end"] = { line = 3, character = 17 } },
                },
              },
            },
          }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { unverified_client }
  end
  clear_notices()
  local saw_unverified_confirm = false
  stub_select(function(items)
    if find_item(items, "UNVERIFIED (jdtls lacks java.project.getClasspaths)") then
      saw_unverified_confirm = true
      return find_item(items, "✖ Cancel")
    end
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(has_notice("cannot verify JUnit 5 on test classpath"), "must warn when getClasspaths capability is absent")
  assert(saw_unverified_confirm, "confirmation summary must state UNVERIFIED classpath")
  assert(vim.fn.filereadable(j4_root .. "/src/test/java/com/trap/TrapTest.java") == 0, "Cancel must create nothing")

  local shared_m2_dir = track_dir(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-m2"))
  local real_api_jar = make_junit5_api_jar(shared_m2_dir)

  -- 2d. pom.xml has NO "junit" text, but getClasspaths returns real junit-jupiter-api jar -> SUCCEEDS!
  local parent_root, parent_main = fixtures.maven_project(
    "junit5-inherited",
    "com.inh",
    "Inherited",
    [[
  public String greet() { return "hi"; }
]]
  )
  track_dir(parent_root)
  -- No "junit" anywhere in pom.xml
  fixtures.write(parent_root .. "/pom.xml", {
    "<project><modelVersion>4.0.0</modelVersion><groupId>com.inh</groupId><artifactId>inh</artifactId><version>1.0</version></project>",
  })
  local inh_client = make_mock_client({
    root_dir = parent_root,
    handler = function(method, params)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "Inherited",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              selectionRange = { start = { line = 2, character = 13 }, ["end"] = { line = 2, character = 22 } },
              children = {
                {
                  name = "greet()",
                  detail = " : String",
                  kind = 6,
                  range = { start = { line = 3, character = 2 }, ["end"] = { line = 3, character = 40 } },
                  selectionRange = { start = { line = 3, character = 16 }, ["end"] = { line = 3, character = 21 } },
                },
              },
            },
          }
      elseif method == "workspace/executeCommand" then
        assert(params.command == "java.project.getClasspaths")
        local decoded = vim.json.decode(params.arguments[2])
        assert(decoded and decoded.scope == "test", "must query test scope")
        return nil,
          {
            classpaths = {
              parent_root .. "/target/test-classes",
              real_api_jar,
            },
          }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { inh_client }
  end
  open_java(parent_main)
  local verified_seen = false
  stub_select(function(items)
    if find_item(items, "verified (org.junit.jupiter.api.Test on test classpath)") then
      verified_seen = true
    end
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(verified_seen, "real JUnit 5 API class on classpath should be marked verified even without 'junit' in pom.xml")
  local inh_test = parent_root .. "/src/test/java/com/inh/InheritedTest.java"
  assert(vim.fn.filereadable(inh_test) == 1, "new test file should be created after confirmation")
  local inh_content = table.concat(vim.fn.readfile(inh_test), "\n")
  assert(inh_content:find("import org.junit.jupiter.api.Test;", 1, true), "must import JUnit 5 Test")
  assert(inh_content:find("void testGreet()", 1, true), "must generate testGreet method")
  assert(
    inh_content:find(
      'throw new java.lang.AssertionError("TODO: implement test for Inherited.greet() : String");',
      1,
      true
    ),
    "must contain explicit unshadowable AssertionError TODO skeleton: " .. inh_content
  )
  assert(not inh_content:find("fail(", 1, true), "must NOT generate shadowable fail() call")
  assert(not inh_content:find("void test()", 1, true), "jc.templates dummy void test() must be replaced")
  assert(not inh_content:find("assert", 1, true), "must NOT generate guessed assertions")
  assert(vim.b.jc_new_java_file == true, "new file should set vim.b.jc_new_java_file")

  -- ---------- 3. Type hierarchy, overloads, SymbolInformation, cursor matching ----------

  local hier_symbols = {
    {
      name = "Outer",
      kind = 5,
      range = { start = { line = 2, character = 0 }, ["end"] = { line = 25, character = 1 } },
      selectionRange = { start = { line = 2, character = 13 }, ["end"] = { line = 2, character = 18 } },
      children = {
        {
          name = "Outer(String)",
          kind = 9, -- Constructor: ignored
          range = { start = { line = 3, character = 2 }, ["end"] = { line = 3, character = 25 } },
          selectionRange = { start = { line = 3, character = 9 }, ["end"] = { line = 3, character = 14 } },
        },
        {
          name = "compute(int)",
          detail = " : int",
          kind = 6,
          range = { start = { line = 4, character = 2 }, ["end"] = { line = 9, character = 3 } },
          selectionRange = { start = { line = 4, character = 13 }, ["end"] = { line = 4, character = 20 } },
          children = {
            {
              name = "new Runnable() {...}",
              kind = 5, -- Local/anon class inside method: must be ignored
              range = { start = { line = 5, character = 18 }, ["end"] = { line = 7, character = 5 } },
              children = {
                {
                  name = "run()",
                  kind = 6,
                  range = { start = { line = 6, character = 6 }, ["end"] = { line = 6, character = 25 } },
                },
              },
            },
          },
        },
        {
          name = "compute(double, double)",
          detail = " : double",
          kind = 6,
          range = { start = { line = 10, character = 2 }, ["end"] = { line = 12, character = 3 } },
          selectionRange = { start = { line = 10, character = 16 }, ["end"] = { line = 10, character = 23 } },
        },
        {
          name = "compute()",
          detail = " : void",
          kind = 6,
          range = { start = { line = 13, character = 2 }, ["end"] = { line = 14, character = 3 } },
          selectionRange = { start = { line = 13, character = 14 }, ["end"] = { line = 13, character = 21 } },
        },
        {
          name = "Inner",
          kind = 5,
          range = { start = { line = 15, character = 2 }, ["end"] = { line = 22, character = 3 } },
          selectionRange = { start = { line = 15, character = 22 }, ["end"] = { line = 15, character = 27 } },
          children = {
            {
              name = "compute(List<String>, String...)",
              detail = " : String",
              kind = 6,
              range = { start = { line = 16, character = 4 }, ["end"] = { line = 18, character = 5 } },
              selectionRange = { start = { line = 16, character = 18 }, ["end"] = { line = 16, character = 25 } },
            },
            {
              name = "compute(int)",
              detail = " : int",
              kind = 6,
              range = { start = { line = 19, character = 4 }, ["end"] = { line = 21, character = 5 } },
              selectionRange = { start = { line = 19, character = 15 }, ["end"] = { line = 19, character = 22 } },
            },
          },
        },
        {
          name = "Status",
          kind = 10, -- Enum
          range = { start = { line = 23, character = 2 }, ["end"] = { line = 24, character = 3 } },
          children = {
            {
              name = "label()",
              detail = " : String",
              kind = 6,
              range = { start = { line = 23, character = 20 }, ["end"] = { line = 23, character = 45 } },
            },
          },
        },
      },
    },
    {
      name = "PackageHelper",
      kind = 5,
      range = { start = { line = 27, character = 0 }, ["end"] = { line = 29, character = 1 } },
      children = {
        {
          name = "assist",
          detail = "(String) : boolean",
          kind = 6,
          range = { start = { line = 28, character = 2 }, ["end"] = { line = 28, character = 30 } },
        },
      },
    },
  }

  local extracted = tests_mod._extract_methods_from_symbols(hier_symbols, { line = 17, character = 6 })
  assert(#extracted == 7, "expected 7 methods (ignoring constructor and anon Runnable.run), got " .. #extracted)
  assert(extracted[1].qualified_type == "Outer" and extracted[1].is_overloaded)
  assert(extracted[4].qualified_type == "Outer.Inner" and extracted[4].at_cursor == true)
  assert(extracted[4].is_overloaded, "Outer.Inner.compute should be marked overloaded")
  assert(extracted[6].qualified_type == "Outer.Status" and not extracted[6].is_overloaded)
  assert(extracted[7].qualified_type == "PackageHelper" and extracted[7].signature == "assist(String)")

  -- Distinct default names for hierarchy & overloads
  assert(tests_mod._default_test_method_name(extracted[1]) == "testCompute_int")
  assert(tests_mod._default_test_method_name(extracted[2]) == "testCompute_double_double")
  assert(tests_mod._default_test_method_name(extracted[3]) == "testCompute_noArgs")
  assert(tests_mod._default_test_method_name(extracted[4]) == "testInner_compute_List_StringVarargs")
  assert(tests_mod._default_test_method_name(extracted[5]) == "testInner_compute_int")
  assert(tests_mod._default_test_method_name(extracted[6]) == "testStatus_label")
  assert(tests_mod._default_test_method_name(extracted[7]) == "testAssist")

  -- Flat SymbolInformation[] support
  local flat_symbols = {
    {
      name = "Outer",
      kind = 5,
      location = { range = { start = { line = 1, character = 0 }, ["end"] = { line = 10, character = 1 } } },
    },
    {
      name = "Inner",
      kind = 5,
      location = { range = { start = { line = 2, character = 2 }, ["end"] = { line = 8, character = 3 } } },
    },
    {
      name = "work(String)",
      kind = 6,
      location = { range = { start = { line = 3, character = 4 }, ["end"] = { line = 5, character = 5 } } },
    },
  }
  local flat_extracted = tests_mod._extract_methods_from_symbols(flat_symbols, { line = 4, character = 4 })
  assert(#flat_extracted == 1 and flat_extracted[1].qualified_type == "Outer.Inner" and flat_extracted[1].at_cursor)

  -- Never guess selection: even when cursor is inside Outer.Inner.compute(List, String...),
  -- picker MUST open showing all overloads with signatures!
  local hier_root, hier_main = fixtures.maven_project(
    "hier-ovl",
    "com.ovl",
    "Outer",
    [[
  // filler
]]
  )
  track_dir(hier_root)
  local hier_lines = { "package com.ovl;", "", "public class Outer {" }
  for i = 4, 30 do
    hier_lines[i] = "  // line " .. i
  end
  hier_lines[31] = "}"
  open_java(hier_main, hier_lines)
  vim.api.nvim_win_set_cursor(0, { 18, 4 }) -- line 17 (0-based) inside Outer.Inner.compute(List, String...)
  local hier_client = make_mock_client({
    root_dir = hier_root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil, hier_symbols
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { hier_client }
  end
  local method_picker_items = nil
  stub_select(function(items, opts)
    if opts.prompt == "Java: Tests — select method" then
      method_picker_items = vim.deepcopy(items)
      return find_item(items, "Outer.compute(double, double)")
    end
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(method_picker_items ~= nil, "method picker must always open instead of guessing")
  assert(
    method_picker_items[1]:find("Outer.Inner.compute(List<String>, String...) : String  [at cursor]", 1, true),
    "cursor method should be listed first with [at cursor] and signature: " .. tostring(method_picker_items[1])
  )
  assert(
    find_item(method_picker_items, "Outer.compute(double, double) : double") ~= nil,
    "overloads must show explicit signatures"
  )
  assert(
    find_item(method_picker_items, "Runnable") == nil,
    "anonymous class method inside method body must not be listed"
  )
  local hier_test = hier_root .. "/src/test/java/com/ovl/OuterTest.java"
  local hier_test_content = table.concat(vim.fn.readfile(hier_test), "\n")
  assert(hier_test_content:find("void testCompute_double_double()", 1, true), "explicitly selected overload must win")

  -- ---------- 4. Collision avoidance, valid identifier enforcement, safe imports ----------

  -- Existing file with comments/strings containing fake methods, existing tests,
  -- JUnit 4 import conflict, and 4-space indentation
  local conflict_lines = {
    "package com.acme;",
    "",
    "/* void testAdd_int_int() {} */",
    "import org.junit.Test;",
    "import static org.junit.Assert.*;",
    "",
    "public class CalcTest {",
    '    private String fake = "void testAdd_int_int_2() {}";',
    "",
    "    @Test",
    "    public void testAdd_int_int() {",
    "        // void testOther() {}",
    "    }",
    "}",
  }
  local conflict_analysis = tests_mod._analyze_test_file(conflict_lines, "CalcTest")
  assert(conflict_analysis.existing_methods["testAdd_int_int"] == true, "real test method must be detected")
  assert(not conflict_analysis.existing_methods["testAdd_int_int_2"], "string literal method must be ignored")
  assert(conflict_analysis.conflicting_test_import == true, "org.junit.Test conflict must be detected")
  assert(conflict_analysis.conflicting_fail_import == true, "org.junit.Assert.* fail conflict must be detected")
  assert(conflict_analysis.indent == "    ", "4-space indent should be detected")

  local ovl_method = {
    name = "add",
    params = { "int", "int" },
    type_path = { "Calc" },
    qualified_type = "Calc",
    is_overloaded = true,
    display_signature = "add(int, int) : int",
  }
  local non_colliding = tests_mod._default_test_method_name(ovl_method, conflict_analysis.existing_methods)
  assert(non_colliding == "testAdd_int_int_2", "expected testAdd_int_int_2, got " .. tostring(non_colliding))

  local conflict_plan, cp_err =
    tests_mod._plan_existing_test_edit(conflict_lines, "CalcTest", non_colliding, "Calc.add(int, int) : int")
  assert(conflict_plan ~= nil, "plan should succeed: " .. tostring(cp_err))
  local body_joined = table.concat(conflict_plan.body_edit.lines, "\n")
  assert(body_joined:find("@org.junit.jupiter.api.Test", 1, true), "must qualify @Test when JUnit 4 Test is imported")
  assert(
    body_joined:find(
      'throw new java.lang.AssertionError("TODO: implement test for Calc.add(int, int) : int");',
      1,
      true
    ),
    "must throw java.lang.AssertionError instead of calling fail(): " .. body_joined
  )
  assert(not body_joined:find("fail(", 1, true), "must never emit fail() call that could be shadowed")
  assert(conflict_plan.import_edit == nil, "must not add conflicting Test or unnecessary Assertions import")

  -- Single-line empty class expansion + existing JUnit 5 imports (no duplicates)
  local single_line_test = {
    "package com.acme;",
    "",
    "import org.junit.jupiter.api.Test;",
    "import static org.junit.jupiter.api.Assertions.*;",
    "",
    "public class CalcTest {}",
  }
  local single_plan = tests_mod._plan_existing_test_edit(single_line_test, "CalcTest", "testSum", "Calc.sum() : int")
  assert(single_plan ~= nil and single_plan.import_edit == nil, "existing JUnit 5 imports must not be duplicated")
  assert(
    single_plan.body_edit.start_row0 == 5 and single_plan.body_edit.end_row0 == 6,
    "single-line empty class should split closing brace"
  )
  assert(single_plan.body_edit.lines[1] == "public class CalcTest {", "opening class line preserved")
  assert(single_plan.body_edit.lines[#single_plan.body_edit.lines] == "}", "closing brace placed on own line")

  -- Interactive invalid name & collision re-prompting, then inserting into existing file
  open_java(calc_test, {
    "package com.acme;",
    "",
    "import org.junit.jupiter.api.Test;",
    "import static org.junit.jupiter.api.Assertions.assertEquals;",
    "",
    "public class CalcTest {",
    "  @Test",
    "  void testAdd() {",
    "    assertEquals(2, 2);",
    "  }",
    "}",
  })
  local calc_client = make_mock_client({
    root_dir = root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "Calc",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = {
                {
                  name = "add(int, int)",
                  detail = " : int",
                  kind = 6,
                  range = { start = { line = 3, character = 2 }, ["end"] = { line = 3, character = 45 } },
                },
              },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { calc_client }
  end
  open_java(calc_main)
  clear_notices()
  local ask_seq = { "123bad", "class", "testAdd", "testAddCustom" }
  stub_input(function(_, n)
    return ask_seq[n]
  end)
  stub_select(function(items)
    return items[1]
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(#input_calls == 4, "must re-prompt on invalid identifier, keyword, and colliding method name")
  assert(has_notice("invalid Java method identifier"), "must report invalid identifier")
  assert(has_notice("already exists in CalcTest.java"), "must report collision")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(calc_test), "should focus CalcTest.java buffer")
  assert(vim.bo[0].modified == true, "existing buffer edited without forced save")
  local edited_lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(
    edited_lines:find(
      'throw new java.lang.AssertionError("TODO: implement test for Calc.add(int, int) : int");',
      1,
      true
    ),
    "must throw java.lang.AssertionError: " .. edited_lines
  )
  assert(not edited_lines:find("fail(", 1, true), "must NOT generate shadowable fail() call")
  local _, test_imp_count = edited_lines:gsub("import org%.junit%.jupiter%.api%.Test;", "")
  assert(test_imp_count == 1, "must NOT duplicate import org.junit.jupiter.api.Test")
  assert(edited_lines:find("void testAddCustom()", 1, true), "must insert testAddCustom")
  assert(edited_lines:find("assertEquals(2, 2);", 1, true), "must preserve existing tests")
  vim.cmd("edit! " .. vim.fn.fnameescape(calc_test))

  -- ---------- 5. Multi-client selection, cancellation, changedtick & stale callback guards ----------

  local c1 = make_mock_client({ id = 21, root_dir = "/other/project", defer = true })
  local c2 = make_mock_client({ id = 22, root_dir = root, defer = true })
  vim.lsp.get_clients = function()
    return { c1, c2 }
  end
  open_java(calc_main)
  stub_select(function(items)
    return find_item(items, "#22")
  end)
  tests_mod.create_method_test()
  assert(#c1._sent == 0 and #c2._sent == 1, "must query only explicitly selected client #22")
  assert(c2._sent[1].method == "textDocument/documentSymbol")

  -- Cancel via M.cancel() sends $/cancelRequest and ignores late response
  assert(tests_mod.cancel() == true, "cancel() should return true for active request")
  assert(#c2._cancelled == 1 and c2._cancelled[1] == c2._sent[1].id, "cancel must send $/cancelRequest")
  c2:respond(c2._sent[1].id, nil, {
    {
      name = "Calc",
      kind = 5,
      range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
      children = { { name = "add(int, int)", kind = 6 } },
    },
  })
  flush_schedule()
  assert(#select_calls == 1, "cancelled callback must not open method picker")

  -- Cancel via Tests menu ("Cancel active request")
  local deferred_picker = defer_select()
  tests_mod.create_method_test()
  assert(#deferred_picker == 1)
  deferred_picker[1].choose(find_item(deferred_picker[1].items, "#22"))
  assert(#c2._sent == 2)
  local menu_captured = defer_select()
  tests_mod.tests()
  assert(#menu_captured == 1)
  local cancel_item = find_item(menu_captured[1].items, "Cancel active request")
  assert(cancel_item ~= nil, "Tests menu must offer Cancel active request while pending")
  menu_captured[1].choose(cancel_item)
  assert(#c2._cancelled == 2, "menu Cancel must cancel active request")
  c2:respond(c2._sent[2].id, nil, {})
  flush_schedule()

  -- changedtick guard while LSP request is in flight
  open_java(calc_main)
  vim.lsp.get_clients = function()
    return { c2 }
  end
  clear_notices()
  local before_req_count = #c2._sent
  tests_mod.create_method_test()
  local req_id = c2._sent[before_req_count + 1].id
  local src_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(src_buf, 0, 0, false, { "// edited mid-request" })
  c2:respond(req_id, nil, {
    {
      name = "Calc",
      kind = 5,
      range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
      children = { { name = "add(int, int)", kind = 6 } },
    },
  })
  flush_schedule()
  assert(has_notice("buffer changed"), "changedtick mismatch must abort and notify")
  vim.bo[src_buf].modified = false

  -- changedtick guard while confirmation picker is open
  open_java(calc_main)
  local sync_c2 = make_mock_client({
    id = 23,
    root_dir = root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "Calc",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = { { name = "add(int, int)", kind = 6 } },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { sync_c2 }
  end
  local before_text = table.concat(vim.fn.readfile(calc_test), "\n")
  local deferred_confirm = defer_select()
  stub_input(function()
    return "testShouldNotInsert"
  end)
  tests_mod.create_method_test()
  flush_schedule()
  -- Choose method
  assert(#deferred_confirm == 1, "method picker should be open")
  deferred_confirm[1].choose(deferred_confirm[1].items[1])
  flush_schedule()
  -- Confirmation picker is now open; mutate source buffer before confirming
  assert(#deferred_confirm == 2, "confirmation picker should be open")
  vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, 0, false, { "// mutated before confirm" })
  clear_notices()
  deferred_confirm[2].choose(deferred_confirm[2].items[1])
  flush_schedule()
  assert(has_notice("buffer changed"), "changedtick change before confirm must abort")
  assert(table.concat(vim.fn.readfile(calc_test), "\n") == before_text, "disk file must remain untouched")
  vim.bo[0].modified = false

  -- ---------- 6. Dirty target buffer refusal & race overwrite protection ----------

  -- Dirty target buffer -> refuse with reason
  local dirty_buf = open_java(calc_test)
  vim.api.nvim_buf_set_lines(dirty_buf, 0, 0, false, { "// unsaved user edit" })
  assert(vim.bo[dirty_buf].modified == true)
  open_java(calc_main)
  clear_notices()
  stub_select(function(items)
    return items[1]
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(has_notice("has unsaved changes"), "dirty target buffer must be refused with clear reason")
  assert(
    vim.api.nvim_buf_get_lines(dirty_buf, 0, 1, false)[1] == "// unsaved user edit",
    "dirty buffer content must remain intact"
  )
  vim.api.nvim_buf_call(dirty_buf, function()
    vim.cmd("edit! " .. vim.fn.fnameescape(calc_test))
  end)

  -- Race on new file creation: file appears on disk while confirmation dialog is open -> refuse without overwrite
  local race_root, race_main = fixtures.maven_project(
    "race-new",
    "com.race",
    "RaceSvc",
    [[
  public void go() {}
]]
  )
  track_dir(race_root)
  local race_test = race_root .. "/src/test/java/com/race/RaceSvcTest.java"
  local race_client = make_mock_client({
    root_dir = race_root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "RaceSvc",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = { { name = "go()", kind = 6 } },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { race_client }
  end
  open_java(race_main)
  clear_notices()
  stub_select(function(items, opts)
    if opts.prompt:find("confirm", 1, true) then
      fixtures.write(race_test, { "// external process wrote this" })
    end
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(has_notice("already exists on disk"), "must refuse when target file appeared before confirmation")
  assert(vim.fn.readfile(race_test)[1] == "// external process wrote this", "must never overwrite race-created file")

  -- Race on existing file: file modified on disk while confirmation dialog is open -> refuse
  clear_notices()
  stub_select(function(items, opts)
    if opts.prompt:find("confirm", 1, true) then
      fixtures.write(race_test, { "package com.race;", "", "// external disk edit", "public class RaceSvcTest {}" })
    end
    return items[1]
  end)
  fixtures.write(race_test, { "package com.race;", "", "public class RaceSvcTest {}" })
  tests_mod.create_method_test()
  flush_schedule()
  assert(has_notice("changed on disk"), "must refuse when existing file changed on disk mid-flow")

  -- ---------- 7. Ambiguous & multi-module counterparts ----------

  local amb_root, amb_main = fixtures.maven_project(
    "amb-test",
    "com.amb",
    "Svc",
    [[
  public void run() {}
]]
  )
  track_dir(amb_root)
  local amb_test = amb_root .. "/src/test/java/com/amb/SvcTest.java"
  local amb_it = amb_root .. "/src/test/java/com/amb/SvcIT.java"
  fixtures.write(amb_test, { "package com.amb;", "", "public class SvcTest {}" })
  fixtures.write(amb_it, { "package com.amb;", "", "public class SvcIT {}" })
  local amb_client = make_mock_client({
    root_dir = amb_root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "Svc",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = { { name = "run()", kind = 6 } },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { amb_client }
  end
  open_java(amb_main)
  local saw_amb_prompt = false
  stub_select(function(items, opts)
    if opts.prompt:find("select target test class", 1, true) then
      saw_amb_prompt = true
      return find_item(items, "SvcIT")
    end
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(saw_amb_prompt, "ambiguous counterparts must prompt explicitly instead of guessing")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(amb_it), "chosen SvcIT must be opened and edited")
  assert(
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("void testRun()", 1, true),
    "SvcIT should receive testRun skeleton"
  )
  vim.bo[0].modified = false

  -- ---------- 8. Multi-module cross_module, symlink refusal, ask cancel & M.tests() end-to-end ----------

  local mm_root = track_dir(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-junit-mm"))
  fixtures.write(mm_root .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.mm</groupId>",
    "  <artifactId>mm-root</artifactId>",
    "  <version>1.0</version>",
    "  <packaging>pom</packaging>",
    "  <modules><module>services/api</module><module>integration-tests</module></modules>",
    "</project>",
  })
  for _, mod in ipairs({ "services/api", "integration-tests" }) do
    fixtures.write(mm_root .. "/" .. mod .. "/pom.xml", {
      "<project><modelVersion>4.0.0</modelVersion><artifactId>" .. vim.fs.basename(mod) .. "</artifactId></project>",
    })
  end
  local mm_api_src = mm_root .. "/services/api/src/main/java/com/mm/ApiSvc.java"
  local mm_it_test = mm_root .. "/integration-tests/src/test/java/com/mm/ApiSvcIT.java"
  local mm_api_test = mm_root .. "/services/api/src/test/java/com/mm/ApiSvcTest.java"
  fixtures.write(mm_api_src, { "package com.mm;", "", "public class ApiSvc {", "  public void ping() {}", "}" })
  fixtures.write(mm_it_test, { "package com.mm;", "", "public class ApiSvcIT {}" })

  local mm_client = make_mock_client({
    root_dir = mm_root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "ApiSvc",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = { { name = "ping()", detail = " : void", kind = 6 } },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { mm_client }
  end
  open_java(mm_api_src)

  -- Cancel at ui.ask creates nothing
  stub_select(function(items, opts)
    if opts.prompt:find("destination test class", 1, true) then
      return find_item(items, "Create services/api")
    end
    return items[1]
  end)
  stub_input(function()
    return nil
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(vim.fn.filereadable(mm_api_test) == 0, "cancelling ui.ask must not create ApiSvcTest.java")

  -- End-to-end via M.tests() menu + cross_module Create in owning module
  stub_select(function(items, opts)
    if opts.prompt:find("Java: Tests — services/api", 1, true) then
      return find_item(items, "Create JUnit 5 Test for Method")
    elseif opts.prompt:find("destination test class", 1, true) then
      return find_item(items, "Create services/api")
    end
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.tests()
  flush_schedule()
  assert(vim.fn.filereadable(mm_api_test) == 1, "M.tests() end-to-end should create services/api ApiSvcTest.java")
  local mm_created = table.concat(vim.fn.readfile(mm_api_test), "\n")
  assert(mm_created:find("void testPing()", 1, true), "created ApiSvcTest should contain testPing()")

  -- Buffer switch guard while confirmation is open
  open_java(mm_api_src)
  local switch_deferred = defer_select()
  tests_mod.create_method_test()
  flush_schedule()
  switch_deferred[1].choose(switch_deferred[1].items[1]) -- method
  flush_schedule()
  assert(#switch_deferred == 2, "confirm dialog should open")
  local other_buf = open_java(mm_it_test)
  clear_notices()
  switch_deferred[2].choose(switch_deferred[2].items[1])
  flush_schedule()
  assert(has_notice("buffer changed"), "buffer switch during confirmation must abort")
  assert(vim.bo[other_buf].modified == false)

  -- Symlink refusal on existing target test file
  local sym_root, sym_main = fixtures.maven_project(
    "sym-test",
    "com.sym",
    "Sym",
    [[
  public void act() {}
]]
  )
  track_dir(sym_root)
  local sym_real = sym_root .. "/RealOutside.java"
  local sym_test = sym_root .. "/src/test/java/com/sym/SymTest.java"
  fixtures.write(sym_real, { "// must not be touched" })
  vim.fn.mkdir(vim.fs.dirname(sym_test), "p")
  if vim.uv.fs_symlink(sym_real, sym_test) then
    local sym_client = make_mock_client({
      root_dir = sym_root,
      handler = function(method)
        if method == "textDocument/documentSymbol" then
          return nil,
            {
              {
                name = "Sym",
                kind = 5,
                range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
                children = { { name = "act()", kind = 6 } },
              },
            }
        elseif method == "workspace/executeCommand" then
          return nil, { classpaths = { "/m2/junit-jupiter-api-5.10.2.jar" } }
        end
      end,
    })
    vim.lsp.get_clients = function()
      return { sym_client }
    end
    open_java(sym_main)
    clear_notices()
    stub_select(function(items)
      return items[1]
    end)
    stub_input(function(opts)
      return opts.default
    end)
    tests_mod.create_method_test()
    flush_schedule()
    assert(has_notice("symlink"), "symlink target must be refused with clear reason")
    assert(vim.fn.readfile(sym_real)[1] == "// must not be touched", "symlink target must remain intact")
  end

  -- ---------- 9. Regressions for review findings (1)-(6) ----------

  -- (1) Local `fail(String)` method shadowing `import static Assertions.fail` + wildcard JUnit 4 / local class Test:
  -- generated body must never call fail(), must throw java.lang.AssertionError, and must qualify @Test when shadowed.
  local shadow_root, shadow_main = fixtures.maven_project(
    "shadow-fail",
    "com.shadow",
    "ShadowSvc",
    [[
  public int work() { return 1; }
]]
  )
  track_dir(shadow_root)
  local shadow_test = shadow_root .. "/src/test/java/com/shadow/ShadowSvcTest.java"
  open_java(shadow_test, {
    "package com.shadow;",
    "",
    "import org.junit.jupiter.api.Test;",
    "import static org.junit.jupiter.api.Assertions.fail;",
    "",
    "public class ShadowSvcTest {",
    "  private void fail(String msg) {",
    "    // no-op local fail shadowing static import!",
    "  }",
    "}",
  })
  local shadow_client = make_mock_client({
    root_dir = shadow_root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "ShadowSvc",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = { { name = "work()", detail = " : int", kind = 6 } },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { shadow_client }
  end
  open_java(shadow_main)
  stub_select(function(items)
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(shadow_test))
  local shadow_buf_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(
    shadow_buf_text:find(
      'throw new java.lang.AssertionError("TODO: implement test for ShadowSvc.work() : int");',
      1,
      true
    ),
    "must throw java.lang.AssertionError even when static fail is imported alongside local fail(): " .. shadow_buf_text
  )
  assert(not shadow_buf_text:find("fail(", 1, true) or shadow_buf_text:match("private void fail%("))
  assert(not shadow_buf_text:find('fail("TODO:', 1, true), "must never call shadowed fail()")
  assert(not shadow_buf_text:find("assert", 1, true), "must not suggest implemented test via assertions")
  vim.bo[0].modified = false

  -- Wildcard JUnit 4 + local class Test conflict qualification
  local wild_plan, wild_err = tests_mod._plan_existing_test_edit({
    "package com.shadow;",
    "import org.junit.*;",
    "public class ShadowSvcTest {",
    "  static class Test {}",
    "}",
  }, "ShadowSvcTest", "testWork", "ShadowSvc.work() : int")
  assert(wild_plan ~= nil, "wildcard plan should succeed: " .. tostring(wild_err))
  local wild_body = table.concat(wild_plan.body_edit.lines, "\n")
  assert(wild_body:find("@org.junit.jupiter.api.Test", 1, true), "must qualify @Test on org.junit.* / local Test")
  assert(wild_plan.import_edit == nil, "must not add unqualified Test import when shadowed")

  local explicit_plan, explicit_err = tests_mod._plan_existing_test_edit({
    "package com.shadow;",
    "import org.junit.jupiter.api.Test;",
    "public class ShadowSvcTest {",
    "  @interface Test {}",
    "}",
  }, "ShadowSvcTest", "testWork", "ShadowSvc.work()")
  assert(explicit_plan, tostring(explicit_err))
  assert(
    table.concat(explicit_plan.body_edit.lines, "\n"):find("@org.junit.jupiter.api.Test", 1, true),
    "explicit import must not mask a nested annotation named Test"
  )

  -- (2) Clean loaded buffer vs disk byte comparison (encoding + EOL) BEFORE flow and at application
  local enc_root, enc_main = fixtures.maven_project(
    "enc-eol",
    "com.enc",
    "EncSvc",
    [[
  public void run() {}
]]
  )
  track_dir(enc_root)
  local enc_test = enc_root .. "/src/test/java/com/enc/EncSvcTest.java"
  -- Latin-1 + CRLF + no trailing EOL on disk
  local latin1_crlf_noeol = vim.iconv("package com.enc;\r\n// café\r\npublic class EncSvcTest {}", "utf-8", "latin1")
  write_raw_bytes(enc_test, latin1_crlf_noeol)
  local saved_fencs = vim.o.fileencodings
  vim.o.fileencodings = "ucs-bom,utf-8,latin1"
  vim.cmd("edit! " .. vim.fn.fnameescape(enc_test))
  local enc_buf = track_buf(vim.api.nvim_get_current_buf())
  vim.bo[enc_buf].filetype = "java"
  assert(vim.bo[enc_buf].modified == false)
  assert(vim.bo[enc_buf].fileformat == "dos")
  assert(vim.bo[enc_buf].eol == false)
  assert(vim.bo[enc_buf].fileencoding == "latin1")

  local enc_client = make_mock_client({
    root_dir = enc_root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "EncSvc",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = { { name = "run()", kind = 6 } },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { enc_client }
  end

  -- 2a: Clean buffer matching latin1 + CRLF + noeol disk bytes -> SUCCEEDS!
  open_java(enc_main)
  clear_notices()
  stub_select(function(items)
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(
    canonical(vim.api.nvim_buf_get_name(0)) == canonical(enc_test),
    "matching latin1/CRLF/noeol buffer must succeed"
  )
  assert(vim.bo[enc_buf].modified == true)
  vim.bo[enc_buf].modified = false
  -- Reload original clean buffer from disk
  vim.cmd("edit! " .. vim.fn.fnameescape(enc_test))

  -- 2b: Disk changes externally BEFORE flow starts (e.g. EOL changed LF vs CRLF or external edit) -> REFUSED BEFORE flow!
  write_raw_bytes(enc_test, vim.iconv("package com.enc;\n// café\npublic class EncSvcTest {}\n", "utf-8", "latin1"))
  open_java(enc_main)
  clear_notices()
  local preflow_selects = 0
  stub_select(function(items)
    preflow_selects = preflow_selects + 1
    return items[1]
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(preflow_selects == 0, "must refuse BEFORE opening pickers when clean loaded buffer differs from disk")
  assert(has_notice("differs from file on disk"), "must notify disk mismatch before flow: " .. vim.inspect(notices))
  assert(vim.bo[enc_buf].modified == false, "stale clean buffer must not be modified")

  -- 2c: Clean loaded buffer differs only in UTF-8 vs UTF-8 BOM on disk -> REFUSED!
  vim.cmd("edit! " .. vim.fn.fnameescape(enc_test))
  assert(vim.bo[enc_buf].modified == false)
  write_raw_bytes(enc_test, "\xef\xbb\xbfpackage com.enc;\n// external\npublic class EncSvcTest {}\n")
  open_java(enc_main)
  clear_notices()
  tests_mod.create_method_test()
  flush_schedule()
  assert(has_notice("differs from file on disk"), "must detect BOM/content difference between clean buffer and disk")

  -- 2d: Clean loaded buffer matches disk at pre-flow, then disk changes during confirmation -> REFUSED at apply!
  vim.api.nvim_buf_call(enc_buf, function()
    vim.cmd("edit! " .. vim.fn.fnameescape(enc_test))
  end)
  assert(vim.bo[enc_buf].modified == false)
  open_java(enc_main)
  clear_notices()
  stub_select(function(items, opts)
    if opts.prompt:find("confirm", 1, true) then
      write_raw_bytes(enc_test, "package com.enc;\n// external change during confirm\npublic class EncSvcTest {}\n")
    end
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(
    has_notice("differs from file on disk") or has_notice("changed on disk"),
    "must refuse at apply time when disk changed"
  )
  assert(vim.bo[enc_buf].modified == false, "loaded buffer must remain unmodified after apply-time refusal")
  vim.o.fileencodings = saved_fencs

  -- (3) Exact test class name required (never fall back to first different class!)
  local wrong_cls_lines = {
    "package com.acme;",
    "",
    "public class OtherClassTest {}",
  }
  local wrong_plan, wrong_err = tests_mod._plan_existing_test_edit(wrong_cls_lines, "CalcTest", "testAdd", "Calc.add()")
  assert(wrong_plan == nil and wrong_err and wrong_err:find("CalcTest", 1, true), "must refuse different first class")

  -- Helper class first, exact CalcTest second -> targets CalcTest only
  local helper_first_lines = {
    "package com.acme;",
    "class Helper { void testAdd() {} }",
    "public class CalcTest {}",
  }
  local hf_analysis = tests_mod._analyze_test_file(helper_first_lines, "CalcTest")
  assert(hf_analysis.target_found and hf_analysis.target_open_line == 3, "must target CalcTest, not Helper")
  assert(not hf_analysis.existing_methods["testAdd"], "Helper's methods must not block CalcTest")

  -- End-to-end refusal when CalcTest.java only contains WrongTest
  open_java(calc_test, { "package com.acme;", "", "public class WrongTest {}" })
  open_java(calc_main)
  clear_notices()
  stub_select(function(items)
    return items[1]
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(has_notice("could not locate class 'CalcTest'"), "must refuse file lacking exact CalcTest class")
  assert(table.concat(vim.fn.readfile(calc_test), "\n"):find("WrongTest", 1, true))
  assert(not table.concat(vim.fn.readfile(calc_test), "\n"):find("@Test", 1, true))

  -- (4) Inline package/import/class combinations must produce valid Java (or refuse cleanly)
  local inline_cases = {
    { "package com.acme; public class InlineTest {}" },
    { "package com.acme; import java.util.List; public class InlineTest {}" },
    { "import java.util.List; import java.util.Map; public class InlineTest {}" },
    { "package com.acme; import java.util.List;", "public class InlineTest {}" },
    { "package com.acme; import java.util.List; public class InlineTest {", "}" },
  }
  for idx, ilines in ipairs(inline_cases) do
    local iplan, ierr = tests_mod._plan_existing_test_edit(ilines, "InlineTest", "testGo", "Inline.go() : void")
    assert(iplan ~= nil, "inline case " .. idx .. " should plan cleanly: " .. tostring(ierr))
    local out_lines = vim.deepcopy(ilines)
    local be = iplan.body_edit
    for _ = 1, (be.end_row0 - be.start_row0) do
      table.remove(out_lines, be.start_row0 + 1)
    end
    for k, l in ipairs(be.lines) do
      table.insert(out_lines, be.start_row0 + k, l)
    end
    if iplan.import_edit then
      local ie = iplan.import_edit
      for _ = 1, (ie.end_row0 - ie.start_row0) do
        table.remove(out_lines, ie.start_row0 + 1)
      end
      for k, l in ipairs(ie.lines) do
        table.insert(out_lines, ie.start_row0 + k, l)
      end
    end
    local joined = table.concat(out_lines, "\n")
    local imp_pos = joined:find("import org.junit.jupiter.api.Test;", 1, true)
    local cls_pos = joined:find("public class InlineTest", 1, true)
    assert(
      imp_pos and cls_pos and imp_pos < cls_pos,
      "inline case " .. idx .. " import must precede class:\n" .. joined
    )
    local recheck = tests_mod._analyze_test_file(out_lines, "InlineTest")
    assert(
      not recheck.malformed_reason and recheck.target_found and recheck.existing_methods["testGo"],
      "inline case " .. idx .. " produced invalid Java:\n" .. joined
    )
  end

  -- Unbalanced / unclosed comment test file must refuse without writing
  local bad_plan, bad_err = tests_mod._plan_existing_test_edit(
    { "package com.acme;", "/* unclosed", "public class InlineTest {}" },
    "InlineTest",
    "testGo",
    "Inline.go()"
  )
  assert(bad_plan == nil and bad_err:find("unclosed", 1, true), "unclosed comment must be refused")

  -- (5) junit-jupiter-engine does NOT prove API; real API class check + target module classpath check
  local eng_jar = make_junit5_engine_jar(shared_m2_dir)
  local eng_info = tests_mod._inspect_junit5_classpath({ classpaths = { eng_jar } })
  assert(eng_info.status == "missing" and eng_info.saw_engine_only == true, "engine jar alone must NOT verify API")

  -- Fake junit-jupiter-api jar on disk lacking Test.class -> must NOT verify!
  local fake_api_jar = write_minimal_jar(shared_m2_dir .. "/junit-jupiter-api-fake-5.10.2.jar", {
    { name = "org/junit/jupiter/api/NotTest.class", data = "x" },
  })
  local fake_info = tests_mod._inspect_junit5_classpath({ classpaths = { fake_api_jar } })
  assert(fake_info.status == "missing", "jar on disk without org/junit/jupiter/api/Test.class must NOT verify")

  -- Non-existent junit-jupiter-api jar path -> must NOT claim verified (returns unverified)
  local unv_info = tests_mod._inspect_junit5_classpath({ classpaths = { "/no/such/m2/junit-jupiter-api-5.10.2.jar" } })
  assert(unv_info.status == "unverified", "missing jar on disk must return unverified, not verified")

  -- Cross-module: services/api HAS JUnit 5 API, integration-tests has ONLY junit-jupiter-engine -> REFUSE when choosing integration-tests!
  local xm_client = make_mock_client({
    root_dir = mm_root,
    handler = function(method, params)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "ApiSvc",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = { { name = "ping()", detail = " : void", kind = 6 } },
            },
          }
      elseif method == "workspace/executeCommand" then
        local uri = params.arguments[1] or ""
        if uri:find("integration%-tests") then
          return nil, { classpaths = { eng_jar } }
        end
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { xm_client }
  end
  -- Remove mm_api_test so ApiSvc triggers cross_module picker offering Use integration-tests · com.mm.ApiSvcIT
  local mm_api_buf = vim.fn.bufnr(mm_api_test)
  if mm_api_buf ~= -1 and vim.api.nvim_buf_is_valid(mm_api_buf) then
    pcall(vim.api.nvim_buf_delete, mm_api_buf, { force = true })
  end
  vim.fn.delete(mm_api_test)
  open_java(mm_api_src)
  clear_notices()
  stub_select(function(items, opts)
    if opts.prompt:find("destination test class", 1, true) then
      return find_item(items, "Use integration-tests")
    end
    return items[1]
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(
    has_notice("junit-jupiter-engine alone does not provide the API"),
    "choosing integration-tests must verify integration-tests classpath and refuse engine-only: "
      .. vim.inspect(notices)
  )
  assert(
    table.concat(vim.fn.readfile(mm_it_test), "\n") == "package com.mm;\n\npublic class ApiSvcIT {}",
    "refused cross-module target ApiSvcIT.java must remain untouched"
  )

  -- Cross-module when client root_dir does not cover integration-tests -> explicit UNVERIFIED warning (never claims verified)
  local scoped_client = make_mock_client({
    root_dir = mm_root .. "/services/api",
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "ApiSvc",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = { { name = "ping()", detail = " : void", kind = 6 } },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { scoped_client }
  end
  clear_notices()
  local saw_cross_unverified = false
  stub_select(function(items, opts)
    if opts.prompt:find("destination test class", 1, true) then
      return find_item(items, "Use integration-tests")
    elseif opts.prompt:find("confirm", 1, true) then
      if find_item(items, "UNVERIFIED") and not find_item(items, "verified (") then
        saw_cross_unverified = true
      end
      return find_item(items, "✖ Cancel")
    end
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(saw_cross_unverified, "cross-module target outside client root must warn UNVERIFIED, never claim verified")

  -- (6) Incompatible jc.templates must fail without creating file (never write skeleton-less file)
  local saved_jc_tpl = package.loaded["jc.templates"]
  for _, bad_tpl in ipairs({
    {
      render = function()
        return "package wrong; public class InheritedTest {}"
      end,
    },
    {
      render = function()
        return "public interface InheritedTest {}"
      end,
    },
    {
      render = function()
        return "public class WrongNameTest {}"
      end,
    },
    {
      render = function()
        error("broken template")
      end,
    },
  }) do
    package.loaded["jc.templates"] = bad_tpl
    local r_out, r_err =
      tests_mod._render_junit5_for_method("InheritedTest", "com.inh", "testGreet", "Inherited.greet()")
    assert(r_out == nil and r_err ~= nil, "incompatible jc.templates must fail cleanly")
  end

  local tpl_root, tpl_main = fixtures.maven_project(
    "bad-jc-tpl",
    "com.badtpl",
    "BadTpl",
    [[
  public void go() {}
]]
  )
  track_dir(tpl_root)
  local tpl_test = tpl_root .. "/src/test/java/com/badtpl/BadTplTest.java"
  package.loaded["jc.templates"] = {
    render = function()
      return "package com.badtpl;\npublic interface BadTplTest {}"
    end,
  }
  local tpl_client = make_mock_client({
    root_dir = tpl_root,
    handler = function(method)
      if method == "textDocument/documentSymbol" then
        return nil,
          {
            {
              name = "BadTpl",
              kind = 5,
              range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
              children = { { name = "go()", kind = 6 } },
            },
          }
      elseif method == "workspace/executeCommand" then
        return nil, { classpaths = { real_api_jar } }
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { tpl_client }
  end
  open_java(tpl_main)
  clear_notices()
  stub_select(function(items)
    return items[1]
  end)
  stub_input(function(opts)
    return opts.default
  end)
  tests_mod.create_method_test()
  flush_schedule()
  assert(has_notice("incompatible jc.templates"), "must report incompatible jc.templates error")
  assert(vim.fn.filereadable(tpl_test) == 0, "incompatible jc.templates must NOT create file without skeleton")
  package.loaded["jc.templates"] = saved_jc_tpl

  print("junit_method_spec: OK")
end

local ok, err = xpcall(run_all, debug.traceback)
cleanup()
if not ok then
  io.stderr:write("[junit_method_spec] FAIL\n" .. tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
