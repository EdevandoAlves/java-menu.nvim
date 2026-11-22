-- 8A (Issue #12): JDTLS Call Hierarchy (java_menu.calls) deterministic FAST tests.
-- Covers lazy registration, menu states, client offset_encoding, explicit
-- multi-JDTLS selection, incoming/outgoing positions & multiple call sites,
-- empty/error/unsupported capability handling, request cancellation, stale
-- callback protection, and safe navigation to file:// and virtual jdt:// URIs.
--
-- Run:
--   tests/java_menu/run.sh fast

local jm = require("java_menu")
local lsp = require("java_menu.lsp")
local fixtures = require("tests.java_menu.fixtures")

local real_notify = vim.notify
local real_select = vim.ui.select
local real_get_clients = vim.lsp.get_clients
local real_expand = vim.fn.expand

local notices = {}
local function reset_notices()
  notices = {}
end
local function last_notice()
  return notices[#notices]
end

local select_calls = {}
local select_chooser = nil
local function stub_select(chooser)
  select_calls = {}
  select_chooser = chooser
  vim.ui.select = function(items, opts, on_choice)
    select_calls[#select_calls + 1] = {
      items = vim.deepcopy(items),
      prompt = opts and opts.prompt or "",
    }
    local choice = type(select_chooser) == "function" and select_chooser(items, opts, #select_calls) or select_chooser
    on_choice(choice)
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
local created_autocmds = {}
local started_lsp_clients = {}

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

local function open_java(path, lines)
  if lines then
    fixtures.write(path, lines)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "java"
  return track_buf(buf)
end

local function canonical(path)
  local norm = vim.fs.normalize(path)
  return vim.fs.normalize(vim.uv.fs_realpath(norm) or norm)
end

local function find_line(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return line
    end
  end
  return nil
end

local function flush_schedule()
  vim.wait(30, function()
    return false
  end, 5)
end

local function cleanup()
  pcall(function()
    if package.loaded["java_menu.calls"] then
      require("java_menu.calls")._reset()
    end
  end)
  for _, c in ipairs(started_lsp_clients) do
    pcall(function()
      if c and type(c.stop) == "function" and not c:is_stopped() then
        c:stop(true)
      end
    end)
  end
  pcall(vim.cmd, "silent! only")
  vim.notify = real_notify
  vim.ui.select = real_select
  vim.lsp.get_clients = real_get_clients
  vim.fn.expand = real_expand
  for _, id in ipairs(created_autocmds) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  for _, buf in ipairs(created_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  for _, dir in ipairs(temp_dirs) do
    pcall(vim.fn.delete, dir, "rf")
  end
end

local function make_mock_client(opts)
  opts = opts or {}
  local next_id = 100
  local sent = {}
  local cancelled = {}
  local pending_callbacks = {}

  local client = {
    id = opts.id or 1,
    name = opts.name or "jdtls",
    root_dir = opts.root_dir,
    offset_encoding = opts.offset_encoding or "utf-16",
    server_capabilities = opts.server_capabilities ~= nil and opts.server_capabilities
      or { callHierarchyProvider = true },
    _stopped = opts.stopped == true,
    _sent = sent,
    _cancelled = cancelled,
    _pending = pending_callbacks,
  }

  function client:is_stopped()
    return self._stopped
  end

  if opts.supports_method ~= nil then
    function client:supports_method(method, bufnr)
      if type(opts.supports_method) == "function" then
        return opts.supports_method(self, method, bufnr)
      end
      return opts.supports_method == true
    end
  end

  function client:request(method, params, handler, bufnr)
    if opts.fail_send then
      return false, nil
    end
    next_id = next_id + 1
    local req_id = next_id
    local rec = {
      id = req_id,
      method = method,
      params = vim.deepcopy(params),
      bufnr = bufnr,
      handler = handler,
    }
    sent[#sent + 1] = rec
    pending_callbacks[req_id] = rec
    if opts.respond then
      local err, res, defer = opts.respond(method, params, req_id, bufnr)
      if not defer then
        pending_callbacks[req_id] = nil
        handler(err, res, { method = method, client_id = self.id, request_id = req_id, bufnr = bufnr })
      end
    end
    return true, req_id
  end

  function client:cancel_request(req_id)
    cancelled[#cancelled + 1] = req_id
    return true
  end

  function client:deliver(req_id, err, res)
    local rec = pending_callbacks[req_id]
    assert(rec, "no pending callback for req_id " .. tostring(req_id))
    pending_callbacks[req_id] = nil
    rec.handler(err, res, { method = rec.method, client_id = self.id, request_id = req_id, bufnr = rec.bufnr })
  end

  return client
end

local function run_tests()
  vim.notify = function(msg, level)
    notices[#notices + 1] = { msg = tostring(msg), level = level }
  end

  -- ---------- 1. Lazy action in init.lua without altering existing shortcuts ----------
  assert(package.loaded["java_menu.calls"] == nil, "java_menu.calls loaded before setup")
  jm.setup({ prefix = "<leader>j" })

  for _, key in ipairs({ "n", "g", "r", "i", "b", "t", "d", "p", "c" }) do
    local m = vim.fn.maparg("<leader>j" .. key, "n", false, true)
    assert(type(m) == "table" and not vim.tbl_isempty(m), "missing keymap <leader>j" .. key)
  end
  local cmap = vim.fn.maparg("<leader>jc", "n", false, true)
  assert(cmap.desc == "Java Menu: Call Hierarchy", "unexpected <leader>jc desc: " .. tostring(cmap.desc))
  assert(package.loaded["java_menu.calls"] == nil, "setup loaded java_menu.calls eagerly")

  -- Group disable & conflict preservation
  jm.setup({ prefix = "<leader>j", groups = { calls = false } })
  assert(vim.fn.maparg("<leader>jc", "n") == "", "calls group disabled still mapped")
  assert(vim.fn.maparg("<leader>jp", "n", false, true).desc == "Java Menu: Project", "disabling calls affected project")

  vim.keymap.set("n", "<leader>jc", function() end, { desc = "custom calls map" })
  reset_notices()
  jm.setup({ prefix = "<leader>j", groups = { calls = true } })
  assert(
    last_notice() and last_notice().msg:find("conflict", 1, true) and last_notice().msg:find("<leader>jc", 1, true),
    "conflict on <leader>jc was not reported"
  )
  assert(
    vim.fn.maparg("<leader>jc", "n", false, true).desc == "custom calls map",
    "third-party <leader>jc was overwritten"
  )
  vim.keymap.del("n", "<leader>jc")
  jm.setup({ prefix = "<leader>j" })

  -- Lazy load via trigger
  local root, main_path = fixtures.maven_project("calls-spec", "com.acme", "Main")
  track_dir(root)
  local helper_path = root .. "/src/main/java/com/acme/Helper.java"
  local caller_path = root .. "/src/main/java/com/acme/Caller.java"
  local main_buf = open_java(main_path, {
    "package com.acme;",
    "",
    "public class Main {",
    '  String s = "😀";',
    "  public void run() {",
    "    Helper.work(1);",
    "  }",
    "}",
  })

  local mock_clients_by_buf = {}
  vim.lsp.get_clients = function(filter)
    filter = filter or {}
    if filter.bufnr ~= nil then
      local list = mock_clients_by_buf[filter.bufnr] or {}
      local out = {}
      for _, c in ipairs(list) do
        if not filter.name or c.name == filter.name then
          out[#out + 1] = c
        end
      end
      return out
    end
    return {}
  end

  stub_select(nil)
  jm.trigger("calls")
  assert(package.loaded["java_menu.calls"] ~= nil, "trigger('calls') did not load java_menu.calls")
  local calls = require("java_menu.calls")

  -- ---------- 2. Menu availability states ----------
  -- 2a. No JDTLS attached
  assert(#select_calls == 1 and select_calls[1].prompt == "Java: Call Hierarchy")
  local inc_line = find_line(select_calls[1].items, "Incoming Calls")
  local out_line = find_line(select_calls[1].items, "Outgoing Calls")
  assert(inc_line and inc_line:find("unavailable: jdtls is not attached", 1, true), "expected disabled incoming reason")
  assert(out_line and out_line:find("unavailable: jdtls is not attached", 1, true), "expected disabled outgoing reason")

  -- 2b. JDTLS attached without callHierarchyProvider capability
  local no_cap_client = make_mock_client({
    id = 5,
    root_dir = root,
    server_capabilities = {},
    supports_method = false,
  })
  mock_clients_by_buf[main_buf] = { no_cap_client }
  stub_select(nil)
  calls.calls()
  inc_line = find_line(select_calls[1].items, "Incoming Calls")
  assert(
    inc_line and inc_line:find("unavailable: jdtls client does not support call hierarchy", 1, true),
    "expected unsupported capability reason, got: " .. tostring(inc_line)
  )

  reset_notices()
  calls.incoming()
  flush_schedule()
  assert(
    last_notice() and last_notice().msg:find("does not support call hierarchy", 1, true),
    "expected unsupported capability warning on direct incoming()"
  )
  assert(#no_cap_client._sent == 0, "unsupported client should not receive prepareCallHierarchy")

  -- ---------- 3. Client offset_encoding on prepareCallHierarchy ----------
  vim.api.nvim_win_set_cursor(0, { 4, 18 }) -- after emoji surrogate pair on line 4: `  String s = "😀";`
  for _, spec in ipairs({
    { enc = "utf-16", expected_char = 16 },
    { enc = "utf-8", expected_char = 18 },
    { enc = "utf-32", expected_char = 15 },
  }) do
    local c = make_mock_client({
      id = 7,
      root_dir = root,
      offset_encoding = spec.enc,
      respond = function(method)
        if method == "textDocument/prepareCallHierarchy" then
          return nil, {}
        end
      end,
    })
    mock_clients_by_buf[main_buf] = { c }
    reset_notices()
    calls.incoming()
    flush_schedule()
    assert(#c._sent == 1, "expected 1 prepareCallHierarchy request for " .. spec.enc)
    assert(
      c._sent[1].params.position.line == 3 and c._sent[1].params.position.character == spec.expected_char,
      string.format(
        "encoding %s char mismatch: expected %d, got %d",
        spec.enc,
        spec.expected_char,
        c._sent[1].params.position.character
      )
    )
    assert(
      last_notice() and last_notice().msg:find("no call hierarchy item found", 1, true),
      "expected empty prepareCallHierarchy notice"
    )
  end

  -- ---------- 4. Explicit selection when multiple JDTLS clients are attached ----------
  local c1 = make_mock_client({ id = 11, root_dir = root .. "/a" })
  local c2 = make_mock_client({
    id = 22,
    root_dir = root .. "/b",
    respond = function(method)
      if method == "textDocument/prepareCallHierarchy" then
        return nil, vim.NIL -- also tests vim.NIL empty handling
      end
    end,
  })
  mock_clients_by_buf[main_buf] = { c2, c1 } -- intentionally unsorted input
  assert(#lsp.clients(main_buf) == 2 and lsp.clients(main_buf)[1].id == 11, "lsp.clients should return sorted clients")

  stub_select(function(items)
    for _, item in ipairs(items) do
      if item:find("#22", 1, true) then
        return item
      end
    end
  end)
  calls.incoming()
  flush_schedule()
  assert(#select_calls == 1, "expected client picker when multiple JDTLS clients exist")
  assert(
    select_calls[1].prompt == "Java: Call Hierarchy — select JDTLS client",
    "unexpected client picker prompt: " .. tostring(select_calls[1].prompt)
  )
  assert(#c1._sent == 0, "unselected JDTLS client #11 should not receive request")
  assert(#c2._sent == 1, "selected JDTLS client #22 did not receive prepareCallHierarchy")

  -- ---------- 5. Multiple prepared items + Incoming Calls + multiple call sites ----------
  open_java(helper_path, {
    "package com.acme;",
    "",
    "public class Helper {",
    "  public static int work(int v) {",
    "    return v + 1;",
    "  }",
    "}",
  })
  open_java(caller_path, {
    "package com.acme;",
    "",
    "public class Caller {",
    "  public int run() {",
    "    int a = Helper.work(1);",
    '    String tag = "😀"; Helper.work(2);',
    "    return a;",
    "  }",
    "  public int other() {",
    "    return Helper.work(3);",
    "  }",
    "}",
  })
  local caller_buf = vim.api.nvim_get_current_buf()
  local helper_buf = open_java(helper_path)
  vim.api.nvim_win_set_cursor(0, { 4, 20 }) -- on `work`

  local item_a = {
    name = "work(int) : int",
    detail = "com.acme.Helper",
    uri = vim.uri_from_fname(helper_path),
    range = { start = { line = 3, character = 2 }, ["end"] = { line = 5, character = 3 } },
    selectionRange = { start = { line = 3, character = 20 }, ["end"] = { line = 3, character = 24 } },
    data = { opaque = "item-a" },
  }
  local item_b = {
    name = "work(String) : int",
    detail = "com.acme.Helper",
    uri = vim.uri_from_fname(helper_path),
    range = { start = { line = 3, character = 2 }, ["end"] = { line = 5, character = 3 } },
    selectionRange = { start = { line = 3, character = 20 }, ["end"] = { line = 3, character = 24 } },
    data = { opaque = "item-b" },
  }

  local inc_client = make_mock_client({
    id = 31,
    root_dir = root,
    offset_encoding = "utf-16",
    respond = function(method, params)
      if method == "textDocument/prepareCallHierarchy" then
        return nil, { item_a, item_b }
      elseif method == "callHierarchy/incomingCalls" then
        assert(params.item and params.item.data and params.item.data.opaque == "item-b", "opaque item data lost")
        return nil,
          {
            {
              from = {
                name = "run() : int",
                detail = "com.acme.Caller",
                uri = vim.uri_from_fname(caller_path),
                range = { start = { line = 3, character = 2 }, ["end"] = { line = 7, character = 3 } },
                selectionRange = { start = { line = 3, character = 13 }, ["end"] = { line = 3, character = 16 } },
              },
              fromRanges = {
                { start = { line = 4, character = 19 }, ["end"] = { line = 4, character = 23 } },
                -- line 6 (0-based 5): `    String tag = "😀"; Helper.work(2);`
                -- `Helper.` starts at utf-16 col 23; `work` starts at utf-16 col 30 (byte 32)
                { start = { line = 5, character = 30 }, ["end"] = { line = 5, character = 34 } },
              },
            },
            {
              from = {
                name = "other() : int",
                detail = "com.acme.Caller",
                uri = vim.uri_from_fname(caller_path),
                range = { start = { line = 8, character = 2 }, ["end"] = { line = 10, character = 3 } },
                selectionRange = { start = { line = 8, character = 13 }, ["end"] = { line = 8, character = 18 } },
              },
              fromRanges = {}, -- fallback to from.selectionRange
            },
          }
      end
    end,
  })
  mock_clients_by_buf[helper_buf] = { inc_client }

  -- Pick second prepared item, then pick second call site in Caller.run (line 6 with emoji)
  stub_select(function(items, opts)
    if opts.prompt:find("select symbol", 1, true) then
      return items[2]
    elseif opts.prompt:find("Incoming Calls", 1, true) then
      assert(#items == 3, "expected 3 incoming entries (2 fromRanges + 1 fallback), got " .. #items)
      return items[2]
    end
  end)
  calls.incoming()
  flush_schedule()

  assert(
    canonical(vim.api.nvim_buf_get_name(0)) == canonical(caller_path),
    "incoming call did not navigate to Caller.java"
  )
  local pos = vim.api.nvim_win_get_cursor(0)
  local caller_line6 = vim.api.nvim_buf_get_lines(0, 5, 6, false)[1]
  local expected_byte_col = caller_line6:find("work", 1, true) - 1
  assert(pos[1] == 6 and pos[2] == expected_byte_col, string.format("wrong incoming call pos: %d:%d", pos[1], pos[2]))

  -- ---------- 6. Outgoing Calls: file:// and jdt:// without confusing fromRanges ----------
  -- Check that BufReadCmd for jdt://* is NOT triggered by our jdt:// loader
  local bufreadcmd_fired = 0
  created_autocmds[#created_autocmds + 1] = vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "jdt://*",
    callback = function()
      bufreadcmd_fired = bufreadcmd_fired + 1
    end,
  })

  local jdt_uri = "jdt://contents/java.base/java.lang/String.class?=calls-spec/%5C/jdk%5C/String.class"
  local jdt_source = table.concat({
    "package java.lang;",
    "public final class String {",
    "  public static String valueOf(int i) {",
    '    return "";',
    "  }",
    "}",
  }, "\n")

  local out_client = make_mock_client({
    id = 41,
    root_dir = root,
    offset_encoding = "utf-16",
    respond = function(method, params)
      if method == "textDocument/prepareCallHierarchy" then
        return nil,
          {
            {
              name = "run() : int",
              detail = "com.acme.Caller",
              uri = vim.uri_from_fname(caller_path),
              range = { start = { line = 3, character = 2 }, ["end"] = { line = 7, character = 3 } },
              selectionRange = { start = { line = 3, character = 13 }, ["end"] = { line = 3, character = 16 } },
            },
          }
      elseif method == "callHierarchy/outgoingCalls" then
        return nil,
          {
            {
              to = {
                name = "work(int) : int",
                detail = "com.acme.Helper",
                uri = vim.uri_from_fname(helper_path),
                range = { start = { line = 3, character = 2 }, ["end"] = { line = 5, character = 3 } },
                selectionRange = { start = { line = 3, character = 20 }, ["end"] = { line = 3, character = 24 } },
              },
              fromRanges = {
                { start = { line = 4, character = 19 }, ["end"] = { line = 4, character = 23 } },
                { start = { line = 5, character = 30 }, ["end"] = { line = 5, character = 34 } },
              },
            },
            {
              to = {
                name = "valueOf(int) : String",
                detail = "java.lang.String",
                uri = jdt_uri,
                range = { start = { line = 2, character = 2 }, ["end"] = { line = 4, character = 3 } },
                selectionRange = { start = { line = 2, character = 23 }, ["end"] = { line = 2, character = 30 } },
              },
              fromRanges = {
                { start = { line = 5, character = 10 }, ["end"] = { line = 5, character = 17 } },
              },
            },
          }
      elseif method == "java/classFileContents" then
        assert(params.uri == jdt_uri, "unexpected java/classFileContents uri: " .. tostring(params.uri))
        return nil, jdt_source
      end
    end,
  })
  mock_clients_by_buf[caller_buf] = { out_client }

  -- 6a. Select file:// outgoing callee (Helper.work) — must jump to Helper.java line 4 (NOT caller line 5/6!)
  vim.api.nvim_set_current_buf(caller_buf)
  vim.api.nvim_win_set_cursor(0, { 4, 13 })
  stub_select(function(items)
    assert(items[1]:find("(from L5, L6)", 1, true), "expected caller lines context, got: " .. tostring(items[1]))
    return items[1]
  end)
  calls.outgoing()
  flush_schedule()
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(helper_path), "outgoing call did not open Helper.java")
  assert(
    vim.api.nvim_win_get_cursor(0)[1] == 4 and vim.api.nvim_win_get_cursor(0)[2] == 20,
    "outgoing call jumped to wrong line/col in Helper.java"
  )

  -- 6b. Select jdt:// outgoing callee (String.valueOf)
  vim.api.nvim_set_current_buf(caller_buf)
  vim.api.nvim_win_set_cursor(0, { 4, 13 })
  stub_select(function(items)
    assert(items[2]:find("jdt://java.base/java.lang/String.class:3:24", 1, true), "bad jdt label: " .. items[2])
    return items[2]
  end)
  calls.outgoing()
  flush_schedule()
  local jdt_buf = vim.api.nvim_get_current_buf()
  track_buf(jdt_buf)
  assert(vim.api.nvim_buf_get_name(jdt_buf) == jdt_uri, "did not open jdt:// buffer")
  assert(vim.bo[jdt_buf].buftype == "nofile", "jdt:// buffer should be nofile")
  assert(vim.bo[jdt_buf].modifiable == false, "jdt:// buffer should be read-only")
  assert(vim.bo[jdt_buf].filetype == "java", "jdt:// buffer filetype should be java")
  assert(bufreadcmd_fired == 0, "BufReadCmd fired unexpectedly during jdt:// load")
  assert(
    vim.api.nvim_win_get_cursor(0)[1] == 3 and vim.api.nvim_win_get_cursor(0)[2] == 23,
    "jdt:// cursor not placed at selectionRange"
  )

  -- Re-navigating to already-loaded jdt:// buffer reuses it without another java/classFileContents request
  local prev_sent_count = #out_client._sent
  vim.api.nvim_set_current_buf(caller_buf)
  assert(
    calls._navigate_to(
      { uri = jdt_uri, range = { start = { line = 2, character = 23 } } },
      out_client,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  assert(#out_client._sent == prev_sent_count, "already-loaded jdt:// buffer triggered duplicate classFileContents")

  -- ---------- 7. Safe URI error paths (missing file://, OOB range, unknown scheme, failed jdt://) ----------
  vim.api.nvim_set_current_buf(caller_buf)
  reset_notices()
  assert(
    calls._navigate_to(
      { uri = vim.uri_from_fname(root .. "/DoesNotExist.java"), range = { start = { line = 0, character = 0 } } },
      out_client,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == false
  )
  assert(vim.api.nvim_get_current_buf() == caller_buf, "missing file:// switched buffer")
  assert(last_notice() and last_notice().msg:find("target file not found", 1, true), "expected missing file notice")

  -- Out-of-bounds line/character clamps safely
  assert(
    calls._navigate_to(
      { uri = vim.uri_from_fname(helper_path), range = { start = { line = 999, character = 999 } } },
      out_client,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  assert(vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(0), "OOB line did not clamp safely")

  -- Unsupported URI scheme
  vim.api.nvim_set_current_buf(caller_buf)
  reset_notices()
  assert(
    calls._navigate_to(
      { uri = "zip:///tmp/lib.jar!/Foo.class", range = { start = { line = 0, character = 0 } } },
      out_client,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == false
  )
  assert(
    last_notice() and last_notice().msg:find("unsupported URI scheme", 1, true),
    "expected unsupported URI scheme notice"
  )

  -- Failed java/classFileContents
  local err_jdt_uri = "jdt://contents/java.base/java.lang/Integer.class?=calls-spec/foo"
  local failing_jdt_client = make_mock_client({
    id = 42,
    root_dir = root,
    respond = function(method)
      if method == "java/classFileContents" then
        return { code = -32603, message = "decompile failed" }, nil
      end
    end,
  })
  reset_notices()
  calls._navigate_to(
    { uri = err_jdt_uri, range = { start = { line = 0, character = 0 } } },
    failing_jdt_client,
    { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
  )
  flush_schedule()
  assert(vim.api.nvim_get_current_buf() == caller_buf, "failed jdt:// switched away from caller_buf")
  assert(
    last_notice() and last_notice().msg:find("could not open jdt:// source", 1, true),
    "expected jdt:// error notice"
  )

  -- ---------- 8. Request cancellation & stale callback protection ----------
  vim.api.nvim_set_current_buf(caller_buf)
  local slow_client = make_mock_client({
    id = 51,
    root_dir = root,
    respond = function()
      return nil, nil, true -- deferred!
    end,
  })
  mock_clients_by_buf[caller_buf] = { slow_client }

  -- 8a. Explicit cancel via menu / M.cancel()
  calls.incoming()
  assert(#slow_client._sent == 1, "slow prepare request was not dispatched")
  local req1 = slow_client._sent[1].id
  assert(calls._pending() ~= nil and calls._pending().request_id == req1, "pending request not tracked")

  stub_select(nil)
  calls.calls()
  assert(
    find_line(select_calls[1].items, "Cancel active request"),
    "menu did not expose Cancel active request entry while pending"
  )

  reset_notices()
  assert(calls.cancel() == true, "M.cancel() should return true when request is pending")
  assert(#slow_client._cancelled == 1 and slow_client._cancelled[1] == req1, "client:cancel_request not called")
  assert(calls._pending() == nil, "pending request not cleared on cancel")

  -- Late callback from cancelled req1 MUST be ignored
  reset_notices()
  slow_client:deliver(req1, nil, { item_a })
  flush_schedule()
  assert(#slow_client._sent == 1, "stale cancelled prepare callback triggered incomingCalls!")
  assert(#notices == 0, "stale cancelled callback emitted unexpected notice: " .. vim.inspect(notices))

  -- 8b. Superseding a pending request cancels the older one and ignores its late callback
  calls.incoming()
  local req2 = slow_client._sent[2].id
  calls.outgoing()
  local req3 = slow_client._sent[3].id
  assert(slow_client._cancelled[2] == req2, "new request did not cancel previous pending request")

  slow_client:deliver(req2, nil, { item_a }) -- stale req2
  flush_schedule()
  assert(#slow_client._sent == 3, "stale superseded req2 triggered outgoing/incomingCalls!")

  -- Complete req3 -> advances to outgoingCalls (req4)
  slow_client:deliver(req3, nil, { item_a })
  flush_schedule()
  assert(#slow_client._sent == 4 and slow_client._sent[4].method == "callHierarchy/outgoingCalls")
  local req4 = slow_client._sent[4].id

  -- 8c. Buffer switched before callback arrives -> must NOT open picker in new buffer
  vim.api.nvim_set_current_buf(helper_buf)
  stub_select(nil)
  reset_notices()
  slow_client:deliver(req4, nil, {
    {
      to = item_b,
      fromRanges = { { start = { line = 4, character = 19 }, ["end"] = { line = 4, character = 23 } } },
    },
  })
  flush_schedule()
  assert(#select_calls == 0, "stale callback after buffer switch opened picker in wrong buffer!")
  assert(last_notice() and last_notice().msg:find("buffer changed", 1, true), "expected buffer changed notice")

  -- 8d. Buffer edited (changedtick changed) before callback arrives -> must abort safely
  vim.api.nvim_set_current_buf(caller_buf)
  calls.outgoing()
  local req5 = slow_client._sent[5].id
  vim.api.nvim_buf_set_lines(caller_buf, 0, 0, false, { "// edited" })
  stub_select(nil)
  reset_notices()
  slow_client:deliver(req5, nil, { item_a })
  flush_schedule()
  assert(#slow_client._sent == 5, "stale callback after buffer edit proceeded to outgoingCalls")
  assert(last_notice() and last_notice().msg:find("buffer changed", 1, true), "expected changedtick guard notice")
  vim.bo[caller_buf].modified = false

  -- 8e. Server-initiated -32800 RequestCancelled error handled cleanly
  calls.incoming()
  local req6 = slow_client._sent[6].id
  reset_notices()
  slow_client:deliver(req6, { code = -32800, message = "cancelled" }, nil)
  flush_schedule()
  assert(
    last_notice() and last_notice().level == vim.log.levels.INFO and last_notice().msg:find("cancelled", 1, true),
    "expected INFO cancellation notice on -32800"
  )

  -- ---------- 9. Operation token protection across client/prepare/results selectors ----------
  -- 9a. Stale client selector callback cannot start prepare, cancel new flow, or navigate
  vim.api.nvim_set_current_buf(caller_buf)
  local old_cli = make_mock_client({ id = 61, root_dir = root .. "/old" })
  local new_cli = make_mock_client({
    id = 62,
    root_dir = root .. "/new",
    respond = function()
      return nil, nil, true -- deferred
    end,
  })
  mock_clients_by_buf[caller_buf] = { old_cli, new_cli }
  local captured = defer_select()
  calls.incoming()
  assert(#captured == 1 and captured[1].prompt:find("select JDTLS client", 1, true), "expected deferred client picker")
  local stale_client_picker = captured[1]

  -- Start a newer flow and pick new_cli so req_new is in flight
  calls.outgoing()
  assert(#captured == 2, "expected second client picker for outgoing")
  local pick_new_label = find_line(captured[2].items, "#62")
  assert(pick_new_label, "missing #62 in second client picker")
  captured[2].choose(pick_new_label)
  assert(#new_cli._sent == 1, "new flow did not dispatch prepareCallHierarchy")
  local req_new = new_cli._sent[1].id

  -- Fire stale Flow A client picker callback -> must be completely ignored
  reset_notices()
  local pick_old_label = find_line(stale_client_picker.items, "#61")
  stale_client_picker.choose(pick_old_label)
  flush_schedule()
  assert(#old_cli._sent == 0, "stale client selector started a request!")
  assert(#new_cli._cancelled == 0, "stale client selector cancelled the new flow!")
  assert(calls._pending() and calls._pending().request_id == req_new, "new flow pending request was clobbered")
  assert(#notices == 0, "stale client selector emitted unexpected notice: " .. vim.inspect(notices))

  -- Finish Flow B cleanly
  new_cli:deliver(req_new, nil, {})
  flush_schedule()
  assert(
    last_notice() and last_notice().msg:find("no call hierarchy item found", 1, true),
    "new flow did not complete after stale client selector callback"
  )

  -- 9b. Stale preparation (symbol) selector callback cannot fetch calls or cancel new flow
  local sym_cli = make_mock_client({
    id = 63,
    root_dir = root,
    respond = function()
      return nil, nil, true
    end,
  })
  mock_clients_by_buf[caller_buf] = { sym_cli }
  captured = defer_select()
  calls.incoming()
  local prep_a = sym_cli._sent[1].id
  sym_cli:deliver(prep_a, nil, { item_a, item_b })
  flush_schedule()
  assert(#captured == 1 and captured[1].prompt:find("select symbol", 1, true), "expected deferred symbol picker")
  local stale_sym_picker = captured[1]

  -- Supersede with Flow B while symbol picker is open
  calls.outgoing()
  assert(#sym_cli._sent == 2, "new flow did not send prepareCallHierarchy")
  local prep_b = sym_cli._sent[2].id
  local cancelled_before = #sym_cli._cancelled

  -- Fire stale symbol picker callback -> must NOT send incomingCalls or cancel prep_b
  reset_notices()
  stale_sym_picker.choose(stale_sym_picker.items[1])
  flush_schedule()
  assert(#sym_cli._sent == 2, "stale symbol selector sent incomingCalls!")
  assert(#sym_cli._cancelled == cancelled_before, "stale symbol selector cancelled new flow!")
  assert(calls._pending() and calls._pending().request_id == prep_b, "prep_b lost after stale symbol selector")
  assert(#notices == 0, "stale symbol selector emitted unexpected notice")

  -- 9c. Stale results selector callback cannot navigate, send classFileContents, or cancel new flow
  sym_cli:deliver(prep_b, nil, { item_a })
  flush_schedule()
  local out_b = sym_cli._sent[3].id
  local res_jdt_uri = "jdt://contents/java.base/java.lang/Long.class?=calls-spec/long"
  sym_cli:deliver(out_b, nil, {
    {
      to = {
        name = "work(int) : int",
        detail = "com.acme.Helper",
        uri = vim.uri_from_fname(helper_path),
        range = { start = { line = 3, character = 2 }, ["end"] = { line = 5, character = 3 } },
        selectionRange = { start = { line = 3, character = 20 }, ["end"] = { line = 3, character = 24 } },
      },
      fromRanges = { { start = { line = 4, character = 19 }, ["end"] = { line = 4, character = 23 } } },
    },
    {
      to = {
        name = "valueOf(long) : Long",
        detail = "java.lang.Long",
        uri = res_jdt_uri,
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 10 } },
        selectionRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
      },
      fromRanges = { { start = { line = 4, character = 10 }, ["end"] = { line = 4, character = 17 } } },
    },
  })
  flush_schedule()
  assert(#captured == 2 and captured[2].prompt:find("Outgoing Calls", 1, true), "expected deferred results picker")
  local stale_results_picker = captured[2]

  -- Supersede with Flow C while results picker is open
  calls.incoming()
  assert(#sym_cli._sent == 4, "Flow C did not send prepareCallHierarchy")
  local prep_c = sym_cli._sent[4].id
  local cancelled_before_res = #sym_cli._cancelled

  -- Fire stale results callback (both file:// item and jdt:// item)
  reset_notices()
  stale_results_picker.choose(stale_results_picker.items[1]) -- file://
  stale_results_picker.choose(stale_results_picker.items[2]) -- jdt://
  flush_schedule()
  assert(vim.api.nvim_get_current_buf() == caller_buf, "stale results selector navigated away from caller_buf!")
  assert(#sym_cli._sent == 4, "stale results selector dispatched java/classFileContents!")
  assert(#sym_cli._cancelled == cancelled_before_res, "stale results selector cancelled Flow C!")
  assert(calls._pending() and calls._pending().request_id == prep_c, "Flow C pending request was displaced")
  assert(#notices == 0, "stale results selector emitted unexpected notice")

  -- Cancel Flow C cleanly before next tests
  assert(calls.cancel() == true)

  -- 9d. Stale java/classFileContents callback superseded by a newer flow
  local cfc_slow_uri = "jdt://contents/java.base/java.lang/Short.class?=calls-spec/short"
  local cfc_cli = make_mock_client({
    id = 66,
    root_dir = root,
    respond = function()
      return nil, nil, true -- deferred
    end,
  })
  mock_clients_by_buf[caller_buf] = { cfc_cli }
  calls._navigate_to(
    { uri = cfc_slow_uri, range = { start = { line = 0, character = 0 } } },
    cfc_cli,
    { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
  )
  local cfc_old_req = cfc_cli._sent[1].id
  calls.incoming()
  local new_prep_req = cfc_cli._sent[2].id
  assert(cfc_cli._cancelled[1] == cfc_old_req, "new flow did not cancel pending classFileContents")
  reset_notices()
  cfc_cli:deliver(cfc_old_req, nil, "package java.lang;\npublic final class Short {}")
  flush_schedule()
  assert(vim.api.nvim_get_current_buf() == caller_buf, "stale classFileContents navigated after new flow started")
  assert(calls._pending() and calls._pending().request_id == new_prep_req, "stale classFileContents clobbered new flow")
  assert(#notices == 0, "stale classFileContents emitted unexpected notice")
  assert(calls.cancel() == true)

  -- ---------- 10. changedtick invalidates result selection AND classFileContents return ----------
  -- 10a. changedtick changes while results selector is open -> selection aborts for file:// and jdt://
  vim.api.nvim_set_current_buf(caller_buf)
  local tick_client = make_mock_client({
    id = 64,
    root_dir = root,
    respond = function(method)
      if method == "textDocument/prepareCallHierarchy" then
        return nil, { item_a }
      elseif method == "callHierarchy/outgoingCalls" then
        return nil,
          {
            {
              to = {
                name = "work(int) : int",
                detail = "com.acme.Helper",
                uri = vim.uri_from_fname(helper_path),
                range = { start = { line = 3, character = 2 }, ["end"] = { line = 5, character = 3 } },
                selectionRange = { start = { line = 3, character = 20 }, ["end"] = { line = 3, character = 24 } },
              },
              fromRanges = {},
            },
            {
              to = {
                name = "valueOf(long) : Long",
                detail = "java.lang.Long",
                uri = res_jdt_uri,
                range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
                selectionRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
              },
              fromRanges = {},
            },
          }
      elseif method == "java/classFileContents" then
        return nil, nil, true -- deferred if ever reached
      end
    end,
  })
  mock_clients_by_buf[caller_buf] = { tick_client }
  captured = defer_select()
  calls.outgoing()
  flush_schedule()
  assert(#captured == 1 and captured[1].prompt:find("Outgoing Calls", 1, true), "expected outgoing results picker")
  local sent_before_edit = #tick_client._sent
  vim.api.nvim_buf_set_lines(caller_buf, 0, 0, false, { "// tick changed before result pick" })
  reset_notices()
  captured[1].choose(captured[1].items[1]) -- file://
  flush_schedule()
  assert(vim.api.nvim_get_current_buf() == caller_buf, "file:// result navigated despite changedtick change")
  assert(
    last_notice() and last_notice().msg:find("buffer changed", 1, true),
    "expected buffer changed notice on file:// pick"
  )

  -- Same check for jdt:// entry when buffer changed while picker open
  captured = defer_select()
  calls.outgoing()
  flush_schedule()
  sent_before_edit = #tick_client._sent
  vim.api.nvim_buf_set_lines(caller_buf, 0, 0, false, { "// tick changed before jdt pick" })
  reset_notices()
  captured[1].choose(captured[1].items[2]) -- jdt://
  flush_schedule()
  assert(#tick_client._sent == sent_before_edit, "jdt:// pick sent classFileContents despite changedtick change")
  assert(vim.api.nvim_get_current_buf() == caller_buf, "jdt:// result navigated despite changedtick change")
  assert(
    last_notice() and last_notice().msg:find("buffer changed", 1, true),
    "expected buffer changed notice on jdt:// pick"
  )

  -- 10b. changedtick changes while java/classFileContents is in flight -> return is invalidated
  captured = defer_select()
  calls.outgoing()
  flush_schedule()
  captured[1].choose(captured[1].items[2]) -- sends deferred java/classFileContents
  local cfc_req = tick_client._sent[#tick_client._sent]
  assert(cfc_req.method == "java/classFileContents", "expected deferred classFileContents request")
  vim.api.nvim_buf_set_lines(caller_buf, 0, 0, false, { "// tick changed during classFileContents" })
  reset_notices()
  tick_client:deliver(cfc_req.id, nil, "package java.lang;\npublic final class Long {}")
  flush_schedule()
  assert(vim.api.nvim_get_current_buf() == caller_buf, "classFileContents navigated despite changedtick change!")
  assert(
    last_notice() and last_notice().msg:find("buffer changed", 1, true),
    "expected buffer changed notice when classFileContents returned after edit"
  )
  assert(vim.fn.bufnr(res_jdt_uri) == -1, "stale classFileContents populated a jdt:// buffer after edit")
  vim.bo[caller_buf].modified = false

  -- ---------- 11. expand('<cword>') safe isolation on empty line for file:// and jdt:// ----------
  local empty_path = root .. "/src/main/java/com/acme/EmptyLine.java"
  local empty_buf = open_java(empty_path, {
    "package com.acme;",
    "",
    "public class EmptyLine {}",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- strictly empty line
  local empty_jdt_uri = "jdt://contents/java.base/java.lang/Boolean.class?=calls-spec/bool"
  local empty_nav_client = make_mock_client({
    id = 65,
    root_dir = root,
    respond = function(method)
      if method == "java/classFileContents" then
        return nil, "package java.lang;\npublic final class Boolean {\n  public static final int X = 1;\n}"
      end
    end,
  })
  -- 11a. file:// from empty line
  assert(
    calls._navigate_to(
      { uri = vim.uri_from_fname(helper_path), range = { start = { line = 3, character = 20 } } },
      empty_nav_client,
      { bufnr = empty_buf, win = vim.api.nvim_get_current_win() }
    ) == true,
    "file:// navigation from empty line failed"
  )
  assert(
    canonical(vim.api.nvim_buf_get_name(0)) == canonical(helper_path),
    "did not jump to Helper.java from empty line"
  )

  -- 11b. jdt:// from empty line
  vim.api.nvim_set_current_buf(empty_buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(
    calls._navigate_to(
      { uri = empty_jdt_uri, range = { start = { line = 2, character = 2 } } },
      empty_nav_client,
      { bufnr = empty_buf, win = vim.api.nvim_get_current_win() }
    ) == true,
    "jdt:// navigation from empty line failed"
  )
  flush_schedule()
  track_buf(vim.api.nvim_get_current_buf())
  assert(vim.api.nvim_buf_get_name(0) == empty_jdt_uri, "did not jump to jdt:// from empty line")

  -- 11c. Forced vim.fn.expand('<cword>') error (e.g. Vim:E349) isolated by pcall for both file:// and jdt://
  local forced_jdt_uri = "jdt://contents/java.base/java.lang/Byte.class?=calls-spec/byte"
  vim.fn.expand = function(expr, ...)
    if expr == "<cword>" then
      error("Vim:E349: No identifier under cursor")
    end
    return real_expand(expr, ...)
  end
  local ok_forced, err_forced = pcall(function()
    vim.api.nvim_set_current_buf(empty_buf)
    assert(
      calls._navigate_to(
        { uri = vim.uri_from_fname(helper_path), range = { start = { line = 3, character = 20 } } },
        empty_nav_client,
        { bufnr = empty_buf, win = vim.api.nvim_get_current_win() }
      ) == true,
      "file:// navigation failed when expand('<cword>') threw"
    )
    assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(helper_path))

    vim.api.nvim_set_current_buf(empty_buf)
    assert(
      calls._navigate_to(
        { uri = forced_jdt_uri, range = { start = { line = 1, character = 2 } } },
        empty_nav_client,
        { bufnr = empty_buf, win = vim.api.nvim_get_current_win() }
      ) == true,
      "jdt:// navigation failed when expand('<cword>') threw"
    )
    flush_schedule()
    track_buf(vim.api.nvim_get_current_buf())
    assert(vim.api.nvim_buf_get_name(0) == forced_jdt_uri)
  end)
  vim.fn.expand = real_expand
  assert(ok_forced, "expand('<cword>') error leaked: " .. tostring(err_forced))

  -- ---------- 12. jdt:// canonical URI preservation & collision refusal ----------
  local function assert_no_synthetic_jdt_buffers()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        assert(
          not name:match("^jdt://client%-"),
          "synthetic jdt://client-... buffer must never be created: " .. tostring(name)
        )
      end
    end
  end

  local shared_jdt_uri = "jdt://contents/shared.lib/com.shared/Api.class?=shared/Api.class"
  local cli_a = make_mock_client({
    id = 71,
    root_dir = root .. "/project-a",
    respond = function(method)
      if method == "java/classFileContents" then
        return nil, "// project-a\npackage com.shared;\npublic class Api { void fromA() {} }"
      end
    end,
  })
  local cli_b = make_mock_client({
    id = 72,
    root_dir = root .. "/project-b",
    respond = function(method)
      if method == "java/classFileContents" then
        return nil, "// project-b\npackage com.shared;\npublic class Api { void fromB() {} }"
      end
    end,
  })

  -- 12a. Client A loads shared_jdt_uri into the canonical buffer
  vim.api.nvim_set_current_buf(caller_buf)
  assert(
    calls._navigate_to(
      { uri = shared_jdt_uri, range = { start = { line = 2, character = 0 } } },
      cli_a,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  flush_schedule()
  local buf_a = track_buf(vim.api.nvim_get_current_buf())
  assert(vim.api.nvim_buf_get_name(buf_a) == shared_jdt_uri, "buf_a did not preserve canonical jdt:// URI")
  assert(vim.uri_from_bufnr(buf_a) == shared_jdt_uri, "vim.uri_from_bufnr(buf_a) altered canonical URI")
  assert(#cli_a._sent == 1, "cli_a should request classFileContents once")
  assert(
    vim.api.nvim_buf_get_lines(buf_a, 0, 1, false)[1] == "// project-a",
    "buf_a did not receive project-a contents"
  )
  assert(vim.b[buf_a].java_menu_jdt_owner and vim.b[buf_a].java_menu_jdt_owner.client_id == 71)
  assert_no_synthetic_jdt_buffers()

  -- 12b. Client B collides on the EXACT SAME shared_jdt_uri -> MUST refuse with clear reason
  -- (never synthesize jdt://client-... and never reuse/clobber buf_a)
  vim.api.nvim_set_current_buf(caller_buf)
  reset_notices()
  assert(
    calls._navigate_to(
      { uri = shared_jdt_uri, range = { start = { line = 2, character = 0 } } },
      cli_b,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == false,
    "expected collision refusal when cli_b opens jdt:// URI owned by cli_a"
  )
  flush_schedule()
  assert(vim.api.nvim_get_current_buf() == caller_buf, "refused collision switched away from caller_buf")
  assert(#cli_b._sent == 0, "colliding cli_b should not request classFileContents or send invented URI")
  assert(
    vim.api.nvim_buf_get_lines(buf_a, 0, 1, false)[1] == "// project-a",
    "cli_b collision modified cli_a's buffer contents!"
  )
  assert(
    last_notice()
      and last_notice().level == vim.log.levels.WARN
      and last_notice().msg:find("already owned by jdtls #71", 1, true),
    "expected clear collision refusal reason, got: " .. vim.inspect(last_notice())
  )
  assert_no_synthetic_jdt_buffers()

  -- 12c. Client A still reuses its own owned canonical buffer on subsequent navigation
  vim.api.nvim_set_current_buf(caller_buf)
  assert(
    calls._navigate_to(
      { uri = shared_jdt_uri, range = { start = { line = 2, character = 0 } } },
      cli_a,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  assert(vim.api.nvim_get_current_buf() == buf_a, "cli_a did not reuse its own buffer")
  assert(#cli_a._sent == 1, "cli_a sent duplicate classFileContents for its own buffer")

  -- 12d. Unowned pre-existing jdt:// buffer (no ownership proof) must NOT be reused, overwritten, or bypassed
  local unowned_uri = "jdt://contents/ext.lib/com.ext/Unowned.class?=ext/Unowned.class"
  local pre_buf = track_buf(vim.uri_to_bufnr(unowned_uri))
  vim.fn.bufload(pre_buf)
  vim.bo[pre_buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(pre_buf, 0, -1, false, { "// pre-existing foreign buffer" })
  mock_clients_by_buf[pre_buf] = { cli_b }

  vim.api.nvim_set_current_buf(caller_buf)
  reset_notices()
  assert(
    calls._navigate_to(
      { uri = unowned_uri, range = { start = { line = 0, character = 0 } } },
      cli_a,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == false,
    "expected collision refusal for unowned pre-existing jdt:// buffer"
  )
  flush_schedule()
  assert(vim.api.nvim_get_current_buf() == caller_buf, "unowned collision switched away from caller_buf")
  assert(#cli_a._sent == 1, "cli_a sent classFileContents despite unowned buffer collision")
  assert(
    vim.api.nvim_buf_get_lines(pre_buf, 0, 1, false)[1] == "// pre-existing foreign buffer",
    "unowned pre-existing buffer was modified!"
  )
  assert(
    last_notice()
      and last_notice().level == vim.log.levels.WARN
      and last_notice().msg:find("attached to another LSP client", 1, true),
    "expected foreign LSP client collision notice, got: " .. vim.inspect(last_notice())
  )
  assert_no_synthetic_jdt_buffers()

  -- 12e. Restarted client (different id) refuses while old client's buffer is open, and succeeds once closed
  local cli_a_restarted = make_mock_client({
    id = 73,
    root_dir = root .. "/project-a",
    respond = function(method)
      if method == "java/classFileContents" then
        return nil, "// project-a-restarted\npackage com.shared;\npublic class Api { void restarted() {} }"
      end
    end,
  })
  vim.api.nvim_set_current_buf(caller_buf)
  reset_notices()
  assert(
    calls._navigate_to(
      { uri = shared_jdt_uri, range = { start = { line = 2, character = 0 } } },
      cli_a_restarted,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == false,
    "restarted client must refuse while previous client's canonical jdt:// buffer is still open"
  )
  flush_schedule()
  assert(#cli_a_restarted._sent == 0, "restarted client sent classFileContents despite open collision")
  assert(vim.api.nvim_buf_get_lines(buf_a, 0, 1, false)[1] == "// project-a")
  assert(
    last_notice() and last_notice().msg:find("already owned by jdtls #71", 1, true),
    "expected clear collision notice for restarted client"
  )
  assert_no_synthetic_jdt_buffers()

  -- Closing/deleting buf_a frees the canonical URI for cli_a_restarted
  vim.api.nvim_buf_delete(buf_a, { force = true })
  vim.api.nvim_set_current_buf(caller_buf)
  assert(
    calls._navigate_to(
      { uri = shared_jdt_uri, range = { start = { line = 2, character = 0 } } },
      cli_a_restarted,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  flush_schedule()
  local buf_a_restarted = track_buf(vim.api.nvim_get_current_buf())
  assert(vim.api.nvim_buf_get_name(buf_a_restarted) == shared_jdt_uri)
  assert(#cli_a_restarted._sent == 1)
  assert(vim.api.nvim_buf_get_lines(buf_a_restarted, 0, 1, false)[1] == "// project-a-restarted")
  assert_no_synthetic_jdt_buffers()

  -- 12f. Mid-flight collision race while java/classFileContents is pending -> refused without overwriting
  local race_uri = "jdt://contents/race.lib/com.race/Race.class?=race/Race.class"
  local race_cli = make_mock_client({
    id = 74,
    root_dir = root .. "/project-race",
    respond = function()
      return nil, nil, true -- deferred
    end,
  })
  vim.api.nvim_set_current_buf(caller_buf)
  assert(
    calls._navigate_to(
      { uri = race_uri, range = { start = { line = 0, character = 0 } } },
      race_cli,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  local race_req_id = race_cli._sent[1].id
  local race_foreign_buf = track_buf(vim.uri_to_bufnr(race_uri))
  vim.fn.bufload(race_foreign_buf)
  vim.bo[race_foreign_buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(race_foreign_buf, 0, -1, false, { "// claimed mid-flight" })
  reset_notices()
  race_cli:deliver(race_req_id, nil, "// should not overwrite")
  flush_schedule()
  assert(vim.api.nvim_get_current_buf() == caller_buf, "mid-flight race switched buffer!")
  assert(
    vim.api.nvim_buf_get_lines(race_foreign_buf, 0, 1, false)[1] == "// claimed mid-flight",
    "mid-flight race overwrote colliding canonical buffer!"
  )
  assert(
    last_notice()
      and last_notice().level == vim.log.levels.WARN
      and last_notice().msg:find("already exists with unowned content", 1, true),
    "expected mid-flight collision refusal notice, got: " .. vim.inspect(last_notice())
  )
  assert_no_synthetic_jdt_buffers()

  -- 12g. Real Neovim LSP transport (didOpen, hover, definition, prepareCallHierarchy):
  -- confirm canonical URI is preserved and NO invented URI ever reaches any server.
  local real_jdt_uri = "jdt://contents/java.base/java.lang/Object.class?=lsp-real/Object.class"
  local real_jdt_src = table.concat({
    "package java.lang;",
    "public class Object {",
    "  public native int hashCode();",
    "}",
  }, "\n")

  local function start_inproc_jdtls(project_root, recorded_msgs)
    local seed_buf = track_buf(vim.api.nvim_create_buf(false, true))
    vim.api.nvim_buf_set_name(seed_buf, project_root .. "/Seed.java")
    local client_id = vim.lsp.start({
      name = "jdtls",
      root_dir = project_root,
      cmd = function()
        return {
          request = function(method, params, cb)
            recorded_msgs[#recorded_msgs + 1] = {
              kind = "request",
              method = method,
              params = vim.deepcopy(params),
            }
            if method == "initialize" then
              cb(nil, {
                capabilities = {
                  hoverProvider = true,
                  definitionProvider = true,
                  callHierarchyProvider = true,
                  textDocumentSync = 1,
                },
              })
            elseif method == "java/classFileContents" then
              cb(nil, real_jdt_src)
            elseif method == "textDocument/hover" then
              cb(nil, { contents = { kind = "markdown", value = "hashCode" } })
            elseif method == "textDocument/definition" then
              cb(nil, {})
            elseif method == "textDocument/prepareCallHierarchy" then
              cb(nil, {})
            else
              cb(nil, nil)
            end
            return true, #recorded_msgs
          end,
          notify = function(method, params)
            recorded_msgs[#recorded_msgs + 1] = {
              kind = "notify",
              method = method,
              params = vim.deepcopy(params),
            }
          end,
          is_closing = function()
            return false
          end,
          terminate = function() end,
        }
      end,
    }, { bufnr = seed_buf })
    assert(client_id, "failed to start in-process mock jdtls client")
    local c = vim.lsp.get_client_by_id(client_id)
    assert(c, "started client missing from vim.lsp.get_client_by_id")
    started_lsp_clients[#started_lsp_clients + 1] = c
    return c
  end

  local function collect_uris(val, out)
    if type(val) == "string" then
      if val:find("://", 1, true) then
        out[#out + 1] = val
      end
    elseif type(val) == "table" then
      for k, v in pairs(val) do
        collect_uris(k, out)
        collect_uris(v, out)
      end
    end
  end

  local function assert_no_invented_uris(msgs, label)
    local uris = {}
    collect_uris(msgs, uris)
    for _, u in ipairs(uris) do
      assert(not u:match("^jdt://client%-"), label .. " received invented URI: " .. tostring(u))
    end
  end

  vim.lsp.get_clients = real_get_clients
  local msgs_a, msgs_b = {}, {}
  local real_cli_a = start_inproc_jdtls(root .. "/project-a", msgs_a)
  local real_cli_b = start_inproc_jdtls(root .. "/project-b", msgs_b)
  assert(
    vim.wait(1000, function()
      local open_a, open_b = false, false
      for _, m in ipairs(msgs_a) do
        if m.method == "textDocument/didOpen" then
          open_a = true
        end
      end
      for _, m in ipairs(msgs_b) do
        if m.method == "textDocument/didOpen" then
          open_b = true
        end
      end
      return real_cli_a.initialized and real_cli_b.initialized and open_a and open_b
    end, 10),
    "in-process mock jdtls clients did not initialize"
  )
  for i = #msgs_a, 1, -1 do
    msgs_a[i] = nil
  end
  for i = #msgs_b, 1, -1 do
    msgs_b[i] = nil
  end

  vim.api.nvim_set_current_buf(caller_buf)
  assert(
    calls._navigate_to(
      { uri = real_jdt_uri, range = { start = { line = 2, character = 20 } } },
      real_cli_a,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  assert(
    vim.wait(1000, function()
      local jumped = vim.api.nvim_buf_get_name(0) == real_jdt_uri
      local saw_open = false
      for _, m in ipairs(msgs_a) do
        if
          m.method == "textDocument/didOpen"
          and m.params
          and m.params.textDocument
          and m.params.textDocument.uri == real_jdt_uri
        then
          saw_open = true
        end
      end
      return jumped and saw_open
    end, 10),
    "didOpen with canonical URI was not sent after opening jdt:// buffer"
  )
  local real_jdt_buf = track_buf(vim.api.nvim_get_current_buf())
  assert(vim.api.nvim_buf_get_name(real_jdt_buf) == real_jdt_uri, "real LSP jdt:// buffer name altered")

  vim.lsp.buf.hover()
  vim.lsp.buf.definition()
  calls.outgoing()
  assert(
    vim.wait(1000, function()
      local saw_hover, saw_def, saw_prep = false, false, false
      for _, m in ipairs(msgs_a) do
        if m.method == "textDocument/hover" then
          saw_hover = true
        elseif m.method == "textDocument/definition" then
          saw_def = true
        elseif m.method == "textDocument/prepareCallHierarchy" then
          saw_prep = true
        end
      end
      return saw_hover and saw_def and saw_prep
    end, 10),
    "expected hover, definition, and prepareCallHierarchy requests on attached jdt:// buffer"
  )

  for _, m in ipairs(msgs_a) do
    if
      m.method == "textDocument/didOpen"
      or m.method == "textDocument/hover"
      or m.method == "textDocument/definition"
      or m.method == "textDocument/prepareCallHierarchy"
    then
      assert(
        m.params and m.params.textDocument and m.params.textDocument.uri == real_jdt_uri,
        string.format(
          "%s sent wrong URI: expected %s, got %s",
          m.method,
          real_jdt_uri,
          vim.inspect(m.params and m.params.textDocument)
        )
      )
    end
  end

  -- Now collide from real_cli_b on the same real_jdt_uri -> must refuse, never attach, never invent URI
  vim.api.nvim_set_current_buf(caller_buf)
  reset_notices()
  local msgs_b_before = #msgs_b
  assert(
    calls._navigate_to(
      { uri = real_jdt_uri, range = { start = { line = 2, character = 20 } } },
      real_cli_b,
      { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
    ) == false
  )
  flush_schedule()
  assert(#msgs_b == msgs_b_before, "colliding real_cli_b sent unexpected LSP messages")
  assert(
    not vim.lsp.buf_is_attached(real_jdt_buf, real_cli_b.id),
    "colliding real_cli_b attached to real_cli_a's jdt:// buffer"
  )
  assert(
    last_notice()
      and last_notice().level == vim.log.levels.WARN
      and last_notice().msg:find("already owned by jdtls", 1, true),
    "expected collision refusal notice on real LSP collision"
  )
  assert_no_invented_uris(msgs_a, "real_cli_a")
  assert_no_invented_uris(msgs_b, "real_cli_b")
  assert_no_synthetic_jdt_buffers()

  real_cli_a:stop(true)
  real_cli_b:stop(true)
  vim.lsp.get_clients = function(filter)
    filter = filter or {}
    if filter.bufnr ~= nil then
      local list = mock_clients_by_buf[filter.bufnr] or {}
      local out = {}
      for _, c in ipairs(list) do
        if not filter.name or c.name == filter.name then
          out[#out + 1] = c
        end
      end
      return out
    end
    return {}
  end

  -- ---------- 13. Two-window context_still_valid protection ----------
  -- Reproduces: user starts call hierarchy in win1 (showing caller_buf), then moves
  -- caller_buf to win2, replaces win1 with main_buf, and focuses win2. Even though
  -- nvim_get_current_buf() is still caller_buf, win1 no longer displays caller_buf,
  -- so callbacks must be invalidated without switching windows or buffers.
  vim.cmd("silent! only")
  local win1 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win1, caller_buf)
  vim.cmd("vsplit")
  local win2 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win2, helper_buf)
  vim.api.nvim_set_current_win(win1)

  local two_win_jdt_uri = "jdt://contents/java.base/java.lang/Double.class?=two-win/Double.class"
  local two_win_cli = make_mock_client({
    id = 81,
    root_dir = root,
    respond = function()
      return nil, nil, true -- always deferred
    end,
  })
  mock_clients_by_buf[caller_buf] = { two_win_cli }

  -- 13a. Move caller_buf to win2 & replace win1 while prepareCallHierarchy is in flight
  calls.outgoing()
  local tw_prep_req = two_win_cli._sent[#two_win_cli._sent].id
  vim.api.nvim_win_set_buf(win2, caller_buf)
  vim.api.nvim_win_set_buf(win1, main_buf)
  vim.api.nvim_set_current_win(win2)
  assert(vim.api.nvim_get_current_buf() == caller_buf)

  stub_select(nil)
  reset_notices()
  local sent_before_tw_prep = #two_win_cli._sent
  two_win_cli:deliver(tw_prep_req, nil, { item_a })
  flush_schedule()
  assert(#two_win_cli._sent == sent_before_tw_prep, "moved buffer triggered outgoingCalls!")
  assert(#select_calls == 0, "moved buffer opened picker!")
  assert(vim.api.nvim_get_current_win() == win2, "stale callback switched focus away from win2")
  assert(vim.api.nvim_win_get_buf(win2) == caller_buf, "stale callback changed win2's buffer")
  assert(vim.api.nvim_win_get_buf(win1) == main_buf, "stale callback changed win1's buffer")
  assert(
    last_notice()
      and last_notice().level == vim.log.levels.WARN
      and last_notice().msg:find("window or buffer changed", 1, true),
    "expected window or buffer changed notice, got: " .. vim.inspect(last_notice())
  )

  -- 13b. Move caller_buf to win2 & replace win1 while results picker is open
  vim.api.nvim_set_current_win(win1)
  vim.api.nvim_win_set_buf(win1, caller_buf)
  vim.api.nvim_win_set_buf(win2, helper_buf)
  captured = defer_select()
  calls.outgoing()
  local tw_prep_2 = two_win_cli._sent[#two_win_cli._sent].id
  two_win_cli:deliver(tw_prep_2, nil, { item_a })
  flush_schedule()
  local tw_out_2 = two_win_cli._sent[#two_win_cli._sent].id
  two_win_cli:deliver(tw_out_2, nil, {
    {
      to = {
        name = "work(int) : int",
        detail = "com.acme.Helper",
        uri = vim.uri_from_fname(helper_path),
        range = { start = { line = 3, character = 2 }, ["end"] = { line = 5, character = 3 } },
        selectionRange = { start = { line = 3, character = 20 }, ["end"] = { line = 3, character = 24 } },
      },
      fromRanges = {},
    },
    {
      to = {
        name = "valueOf(double) : Double",
        detail = "java.lang.Double",
        uri = two_win_jdt_uri,
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
        selectionRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
      },
      fromRanges = {},
    },
  })
  flush_schedule()
  assert(#captured == 1 and captured[1].prompt:find("Outgoing Calls", 1, true))

  vim.api.nvim_win_set_buf(win2, caller_buf)
  vim.api.nvim_win_set_buf(win1, main_buf)
  vim.api.nvim_set_current_win(win2)
  reset_notices()
  captured[1].choose(captured[1].items[1]) -- file://
  flush_schedule()
  assert(vim.api.nvim_get_current_win() == win2, "stale picker pick switched focus to win1!")
  assert(vim.api.nvim_win_get_buf(win2) == caller_buf, "stale picker pick replaced win2 buffer!")
  assert(vim.api.nvim_win_get_buf(win1) == main_buf, "stale picker pick replaced win1 buffer!")
  assert(
    last_notice() and last_notice().msg:find("window or buffer changed", 1, true),
    "expected window or buffer changed notice on stale result pick"
  )

  -- 13c. Move caller_buf to win2 & replace win1 while java/classFileContents is in flight
  vim.api.nvim_set_current_win(win1)
  vim.api.nvim_win_set_buf(win1, caller_buf)
  vim.api.nvim_win_set_buf(win2, helper_buf)
  captured = defer_select()
  calls.outgoing()
  local tw_prep_3 = two_win_cli._sent[#two_win_cli._sent].id
  two_win_cli:deliver(tw_prep_3, nil, { item_a })
  flush_schedule()
  local tw_out_3 = two_win_cli._sent[#two_win_cli._sent].id
  two_win_cli:deliver(tw_out_3, nil, {
    {
      to = {
        name = "valueOf(double) : Double",
        detail = "java.lang.Double",
        uri = two_win_jdt_uri,
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
        selectionRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
      },
      fromRanges = {},
    },
  })
  flush_schedule()
  captured[1].choose(captured[1].items[1]) -- sends java/classFileContents
  local tw_cfc_req = two_win_cli._sent[#two_win_cli._sent]
  assert(tw_cfc_req.method == "java/classFileContents")

  vim.api.nvim_win_set_buf(win2, caller_buf)
  vim.api.nvim_win_set_buf(win1, main_buf)
  vim.api.nvim_set_current_win(win2)
  reset_notices()
  two_win_cli:deliver(tw_cfc_req.id, nil, "package java.lang;\npublic final class Double {}")
  flush_schedule()
  assert(vim.api.nvim_get_current_win() == win2, "stale classFileContents switched focus to win1!")
  assert(vim.api.nvim_win_get_buf(win2) == caller_buf, "stale classFileContents replaced win2 buffer!")
  assert(vim.api.nvim_win_get_buf(win1) == main_buf, "stale classFileContents replaced win1 buffer!")
  assert(vim.fn.bufnr(two_win_jdt_uri) == -1, "stale classFileContents loaded jdt:// buffer after window move!")
  assert(
    last_notice() and last_notice().msg:find("window or buffer changed", 1, true),
    "expected window or buffer changed notice on stale classFileContents"
  )

  -- 13d. Captured win1 closed while win2 holds caller_buf during deferred classFileContents
  vim.api.nvim_set_current_win(win1)
  vim.api.nvim_win_set_buf(win1, caller_buf)
  vim.api.nvim_win_set_buf(win2, caller_buf)
  calls._navigate_to(
    { uri = two_win_jdt_uri, range = { start = { line = 0, character = 0 } } },
    two_win_cli,
    { bufnr = caller_buf, win = win1 }
  )
  local tw_cfc_req2 = two_win_cli._sent[#two_win_cli._sent]
  assert(tw_cfc_req2.method == "java/classFileContents")
  vim.api.nvim_win_close(win1, true)
  assert(vim.api.nvim_get_current_win() == win2)
  reset_notices()
  two_win_cli:deliver(tw_cfc_req2.id, nil, "package java.lang;\npublic final class Double {}")
  flush_schedule()
  assert(vim.api.nvim_get_current_win() == win2)
  assert(vim.api.nvim_win_get_buf(win2) == caller_buf, "closed origin window caused jump in win2!")
  assert(vim.fn.bufnr(two_win_jdt_uri) == -1, "closed origin window populated jdt:// buffer!")
  assert(last_notice() and last_notice().msg:find("window or buffer changed", 1, true))
  vim.cmd("silent! only")

  -- FileType hooks must not attach another client while a virtual buffer is
  -- being populated and before its owner has been recorded.
  local guarded_uri = "jdt://contents/java.base/java.lang/Guard.class?=guard/Guard.class"
  local filetype_fired = false
  local hook = vim.api.nvim_create_autocmd("FileType", {
    pattern = "java",
    callback = function()
      filetype_fired = true
    end,
  })
  calls._navigate_to(
    { uri = guarded_uri, range = { start = { line = 0, character = 0 } } },
    two_win_cli,
    { bufnr = caller_buf, win = vim.api.nvim_get_current_win() }
  )
  local guarded_req = two_win_cli._sent[#two_win_cli._sent]
  assert(guarded_req.method == "java/classFileContents")
  two_win_cli:deliver(guarded_req.id, nil, "package java.lang;\npublic class Guard {}")
  flush_schedule()
  vim.api.nvim_del_autocmd(hook)
  assert(not filetype_fired, "FileType hook ran before jdt:// buffer ownership was established")
  assert(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) == guarded_uri)

  print("calls_spec: OK")
end

local ok, err = xpcall(run_tests, debug.traceback)
cleanup()
if not ok then
  io.stderr:write("[calls_spec] FAIL\n" .. tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
