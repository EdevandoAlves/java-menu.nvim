-- 8B (Issue #13): JDTLS Type Hierarchy (java_menu.types) deterministic FAST tests.
-- Covers lazy registration without altering existing shortcuts, real LSP
-- capability gating (typeHierarchyProvider vs implementationProvider and
-- Neovim's self-mapping quirk), client offset_encoding, explicit multi-JDTLS
-- selection, supertypes/subtypes/implementations flows, request cancellation,
-- stale callback/picker protection, changedtick/window guards, and canonical
-- jdt:// URI isolation shared with java_menu.calls.
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
    if package.loaded["java_menu.types"] then
      require("java_menu.types")._reset()
    end
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
  local next_id = 200
  local sent = {}
  local cancelled = {}
  local pending_callbacks = {}

  local default_caps = { typeHierarchyProvider = true, implementationProvider = true }
  local client = {
    id = opts.id or 1,
    name = opts.name or "jdtls",
    root_dir = opts.root_dir,
    offset_encoding = opts.offset_encoding or "utf-16",
    server_capabilities = opts.server_capabilities ~= nil and opts.server_capabilities or default_caps,
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

  -- ---------- 1. Lazy registration & preservation of existing shortcuts ----------
  assert(package.loaded["java_menu.types"] == nil, "java_menu.types loaded before setup")
  jm.setup({ prefix = "<leader>j" })

  for _, key in ipairs({ "n", "g", "r", "i", "b", "t", "d", "p", "c", "h" }) do
    local m = vim.fn.maparg("<leader>j" .. key, "n", false, true)
    assert(type(m) == "table" and not vim.tbl_isempty(m), "missing keymap <leader>j" .. key)
  end
  local hmap = vim.fn.maparg("<leader>jh", "n", false, true)
  assert(hmap.desc == "Java Menu: Type Hierarchy", "unexpected <leader>jh desc: " .. tostring(hmap.desc))
  assert(package.loaded["java_menu.types"] == nil, "setup loaded java_menu.types eagerly")

  jm.setup({ prefix = "<leader>j", groups = { types = false } })
  assert(vim.fn.maparg("<leader>jh", "n") == "", "types group disabled still mapped")
  assert(
    vim.fn.maparg("<leader>jc", "n", false, true).desc == "Java Menu: Call Hierarchy",
    "disabling types affected calls"
  )

  vim.keymap.set("n", "<leader>jh", function() end, { desc = "custom types map" })
  reset_notices()
  jm.setup({ prefix = "<leader>j", groups = { types = true } })
  assert(
    last_notice() and last_notice().msg:find("conflict", 1, true) and last_notice().msg:find("<leader>jh", 1, true),
    "conflict on <leader>jh was not reported"
  )
  assert(
    vim.fn.maparg("<leader>jh", "n", false, true).desc == "custom types map",
    "third-party <leader>jh was overwritten"
  )
  vim.keymap.del("n", "<leader>jh")
  jm.setup({ prefix = "<leader>j" })

  local root, main_path = fixtures.maven_project("types-spec", "com.acme", "Main")
  track_dir(root)
  local iface_path = root .. "/src/main/java/com/acme/Greeter.java"
  local base_path = root .. "/src/main/java/com/acme/BaseGreeter.java"
  local impl_path = root .. "/src/main/java/com/acme/FriendlyGreeter.java"

  local main_buf = open_java(main_path, {
    "package com.acme;",
    "",
    "public class Main {",
    '  String s = "😀";',
    "  Greeter g = new FriendlyGreeter();",
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
  jm.trigger("types")
  assert(package.loaded["java_menu.types"] ~= nil, "trigger('types') did not load java_menu.types")
  local types = require("java_menu.types")

  -- ---------- 2. Real LSP capability gating ----------
  -- 2a. No JDTLS attached
  assert(#select_calls == 1 and select_calls[1].prompt == "Java: Type Hierarchy")
  for _, label_frag in ipairs({ "Supertypes", "Subtypes", "Implementations" }) do
    local line = find_line(select_calls[1].items, label_frag)
    assert(
      line and line:find("unavailable: jdtls is not attached", 1, true),
      "expected disabled reason for " .. label_frag
    )
  end

  -- 2b. Client mimicking Neovim's self-mapping quirk: supertypes/subtypes return true
  -- even when prepareTypeHierarchy and implementation are unsupported -> must be disabled!
  local self_map_no_cap = make_mock_client({
    id = 5,
    root_dir = root,
    server_capabilities = {},
    supports_method = function(_, method)
      return method == "typeHierarchy/supertypes" or method == "typeHierarchy/subtypes"
    end,
  })
  mock_clients_by_buf[main_buf] = { self_map_no_cap }
  stub_select(nil)
  types.types()
  local sup_line = find_line(select_calls[1].items, "Supertypes")
  local sub_line = find_line(select_calls[1].items, "Subtypes")
  local impl_line = find_line(select_calls[1].items, "Implementations")
  assert(
    sup_line and sup_line:find("unavailable: jdtls client does not support type hierarchy", 1, true),
    "expected unsupported type hierarchy on Supertypes, got: " .. tostring(sup_line)
  )
  assert(
    sub_line and sub_line:find("unavailable: jdtls client does not support type hierarchy", 1, true),
    "expected unsupported type hierarchy on Subtypes, got: " .. tostring(sub_line)
  )
  assert(
    impl_line and impl_line:find("unavailable: jdtls client does not support implementations", 1, true),
    "expected unsupported implementations, got: " .. tostring(impl_line)
  )

  reset_notices()
  types.supertypes()
  flush_schedule()
  assert(
    last_notice() and last_notice().msg:find("does not support type hierarchy", 1, true),
    "expected unsupported warning on direct supertypes()"
  )
  reset_notices()
  types.implementations()
  flush_schedule()
  assert(
    last_notice() and last_notice().msg:find("does not support implementations", 1, true),
    "expected unsupported warning on direct implementations()"
  )
  assert(#self_map_no_cap._sent == 0, "unsupported client should not receive requests")

  -- 2c. Type hierarchy only (implementationProvider = false)
  local th_only = make_mock_client({
    id = 6,
    root_dir = root,
    server_capabilities = { typeHierarchyProvider = true, implementationProvider = false },
  })
  mock_clients_by_buf[main_buf] = { th_only }
  stub_select(nil)
  types.types()
  sup_line = find_line(select_calls[1].items, "Supertypes")
  impl_line = find_line(select_calls[1].items, "Implementations")
  assert(sup_line and not sup_line:find("unavailable", 1, true), "Supertypes should be enabled")
  assert(impl_line and impl_line:find("unavailable: jdtls client does not support implementations", 1, true))

  -- 2d. Implementation only (typeHierarchyProvider = false)
  local impl_only = make_mock_client({
    id = 7,
    root_dir = root,
    server_capabilities = { typeHierarchyProvider = false, implementationProvider = true },
  })
  mock_clients_by_buf[main_buf] = { impl_only }
  stub_select(nil)
  types.types()
  sup_line = find_line(select_calls[1].items, "Supertypes")
  impl_line = find_line(select_calls[1].items, "Implementations")
  assert(sup_line and sup_line:find("unavailable: jdtls client does not support type hierarchy", 1, true))
  assert(impl_line and not impl_line:find("unavailable", 1, true), "Implementations should be enabled")

  -- ---------- 3. Client offset_encoding on prepareTypeHierarchy and implementation ----------
  vim.api.nvim_win_set_cursor(0, { 4, 18 }) -- after emoji surrogate pair on line 4: `  String s = "😀";`
  for _, spec in ipairs({
    { enc = "utf-16", expected_char = 16 },
    { enc = "utf-8", expected_char = 18 },
    { enc = "utf-32", expected_char = 15 },
  }) do
    local c = make_mock_client({
      id = 8,
      root_dir = root,
      offset_encoding = spec.enc,
      respond = function(method)
        if method == "textDocument/prepareTypeHierarchy" then
          return nil, {}
        elseif method == "textDocument/implementation" then
          return nil, vim.NIL
        end
      end,
    })
    mock_clients_by_buf[main_buf] = { c }
    reset_notices()
    types.supertypes()
    flush_schedule()
    assert(#c._sent == 1 and c._sent[1].method == "textDocument/prepareTypeHierarchy")
    assert(
      c._sent[1].params.position.line == 3 and c._sent[1].params.position.character == spec.expected_char,
      string.format("prepareTypeHierarchy encoding %s mismatch: got %d", spec.enc, c._sent[1].params.position.character)
    )
    assert(last_notice() and last_notice().msg:find("no type hierarchy item found", 1, true))

    reset_notices()
    types.implementations()
    flush_schedule()
    assert(#c._sent == 2 and c._sent[2].method == "textDocument/implementation")
    assert(
      c._sent[2].params.position.line == 3 and c._sent[2].params.position.character == spec.expected_char,
      string.format("implementation encoding %s mismatch: got %d", spec.enc, c._sent[2].params.position.character)
    )
    assert(last_notice() and last_notice().msg:find("no implementations found", 1, true))
  end

  -- ---------- 4. Explicit multi-client selection with mixed capabilities ----------
  local c_no_th = make_mock_client({
    id = 11,
    root_dir = root .. "/a",
    server_capabilities = { typeHierarchyProvider = false, implementationProvider = true },
  })
  local c_with_th = make_mock_client({
    id = 22,
    root_dir = root .. "/b",
    server_capabilities = { typeHierarchyProvider = true, implementationProvider = false },
    respond = function(method)
      if method == "textDocument/prepareTypeHierarchy" then
        return nil, vim.NIL
      end
    end,
  })
  mock_clients_by_buf[main_buf] = { c_with_th, c_no_th }

  -- Picking unsupported #11 for supertypes refuses cleanly
  stub_select(function(items)
    local line = find_line(items, "#11")
    assert(line and line:find("[no typeHierarchy]", 1, true), "expected [no typeHierarchy] tag on #11")
    return line
  end)
  reset_notices()
  types.supertypes()
  flush_schedule()
  assert(#c_no_th._sent == 0 and #c_with_th._sent == 0)
  assert(last_notice() and last_notice().msg:find("selected jdtls client does not support type hierarchy", 1, true))

  -- Picking supported #22 dispatches prepareTypeHierarchy to #22 only
  stub_select(function(items)
    return find_line(items, "#22")
  end)
  types.supertypes()
  flush_schedule()
  assert(#c_no_th._sent == 0 and #c_with_th._sent == 1)

  -- ---------- 5. Supertypes & Subtypes flows (file:// + jdt:// + opaque data) ----------
  local iface_buf = open_java(iface_path, {
    "package com.acme;",
    "",
    "public interface Greeter {",
    "  String greet();",
    "}",
  })
  local base_buf = open_java(base_path, {
    "package com.acme;",
    "",
    "public abstract class BaseGreeter implements Greeter {",
    '  String tag = "😀"; public String greet() { return tag; }',
    "}",
  })
  local impl_buf = open_java(impl_path, {
    "package com.acme;",
    "",
    'public class FriendlyGreeter extends BaseGreeter { String x = "😀"; }',
  })

  local serializable_uri = "jdt://contents/java.base/java.io/Serializable.class?=types-spec/Serializable.class"
  local serializable_src = table.concat({
    "package java.io;",
    "public interface Serializable {}",
  }, "\n")

  local item_greeter = {
    name = "Greeter",
    detail = "com.acme",
    kind = 11,
    uri = vim.uri_from_fname(iface_path),
    range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
    selectionRange = { start = { line = 2, character = 17 }, ["end"] = { line = 2, character = 24 } },
    data = { opaque = "greeter-token" },
  }
  local item_alt = {
    name = "GreeterAlt",
    detail = "com.acme",
    kind = 11,
    uri = vim.uri_from_fname(iface_path),
    range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
    selectionRange = { start = { line = 2, character = 17 }, ["end"] = { line = 2, character = 24 } },
    data = { opaque = "alt-token" },
  }
  local item_base = {
    name = "BaseGreeter",
    detail = "com.acme",
    kind = 5,
    uri = vim.uri_from_fname(base_path),
    range = { start = { line = 2, character = 0 }, ["end"] = { line = 4, character = 1 } },
    selectionRange = { start = { line = 2, character = 22 }, ["end"] = { line = 2, character = 33 } },
  }
  local item_friendly = {
    name = "FriendlyGreeter",
    detail = "com.acme",
    kind = 5,
    uri = vim.uri_from_fname(impl_path),
    range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 67 } },
    -- After emoji on line 3: `public class FriendlyGreeter ...` (FriendlyGreeter at col 13)
    selectionRange = { start = { line = 2, character = 13 }, ["end"] = { line = 2, character = 28 } },
  }
  local item_serializable = {
    name = "Serializable",
    detail = "java.io",
    kind = 11,
    uri = serializable_uri,
    range = { start = { line = 1, character = 17 }, ["end"] = { line = 1, character = 29 } },
  }

  local th_client = make_mock_client({
    id = 31,
    root_dir = root,
    offset_encoding = "utf-16",
    respond = function(method, params)
      if method == "textDocument/prepareTypeHierarchy" then
        return nil, { item_alt, item_greeter }
      elseif method == "typeHierarchy/subtypes" then
        assert(params.item and params.item.data and params.item.data.opaque == "greeter-token", "opaque data lost")
        return nil, { item_base, item_friendly }
      elseif method == "typeHierarchy/supertypes" then
        return nil, { item_serializable }
      elseif method == "textDocument/implementation" then
        return nil,
          {
            {
              targetUri = vim.uri_from_fname(impl_path),
              targetRange = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 67 } },
              targetSelectionRange = { start = { line = 2, character = 53 }, ["end"] = { line = 2, character = 54 } },
            },
            {
              uri = serializable_uri,
              range = { start = { line = 1, character = 17 }, ["end"] = { line = 1, character = 29 } },
            },
          }
      elseif method == "java/classFileContents" then
        return nil, serializable_src
      end
    end,
  })
  mock_clients_by_buf[iface_buf] = { th_client }
  mock_clients_by_buf[impl_buf] = { th_client }

  -- 5a. Subtypes: choose second prepared item (`Greeter`), then pick `BaseGreeter`
  vim.api.nvim_set_current_buf(iface_buf)
  vim.api.nvim_win_set_cursor(0, { 3, 17 })
  stub_select(function(items, opts)
    if opts.prompt:find("select symbol", 1, true) then
      return items[2]
    elseif opts.prompt:find("Subtypes", 1, true) then
      assert(#items == 2, "expected 2 subtype entries")
      return find_line(items, "BaseGreeter")
    end
  end)
  types.subtypes()
  flush_schedule()
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(base_path), "did not navigate to BaseGreeter.java")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3 and vim.api.nvim_win_get_cursor(0)[2] == 22)

  -- 5b. Supertypes: pick jdt:// Serializable (falling back to range when selectionRange omitted)
  local bufreadcmd_fired = 0
  created_autocmds[#created_autocmds + 1] = vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "jdt://*",
    callback = function()
      bufreadcmd_fired = bufreadcmd_fired + 1
    end,
  })
  vim.api.nvim_set_current_buf(impl_buf)
  vim.api.nvim_win_set_cursor(0, { 3, 13 })
  stub_select(function(items, opts)
    if opts.prompt:find("select symbol", 1, true) then
      return items[2]
    elseif opts.prompt:find("Supertypes", 1, true) then
      local line = find_line(items, "Serializable")
      assert(
        line and line:find("jdt://java.base/java.io/Serializable.class:2:18", 1, true),
        "bad jdt label: " .. tostring(line)
      )
      return line
    end
  end)
  types.supertypes()
  flush_schedule()
  local jdt_buf = track_buf(vim.api.nvim_get_current_buf())
  assert(vim.api.nvim_buf_get_name(jdt_buf) == serializable_uri, "did not open canonical jdt:// buffer")
  assert(vim.bo[jdt_buf].buftype == "nofile" and vim.bo[jdt_buf].modifiable == false)
  assert(vim.bo[jdt_buf].filetype == "java")
  assert(bufreadcmd_fired == 0, "BufReadCmd fired during jdt:// load")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 2 and vim.api.nvim_win_get_cursor(0)[2] == 17)

  -- ---------- 6. Implementations (Location & LocationLink + snippet + single Location) ----------
  vim.api.nvim_set_current_buf(iface_buf)
  vim.api.nvim_win_set_cursor(0, { 3, 17 })
  stub_select(function(items, opts)
    assert(opts.prompt:find("Implementations", 1, true), "unexpected prompt: " .. tostring(opts.prompt))
    local file_entry = find_line(items, "FriendlyGreeter.java")
    assert(file_entry and file_entry:find("public class FriendlyGreeter", 1, true), "expected snippet in impl entry")
    return file_entry
  end)
  types.implementations()
  flush_schedule()
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(impl_path))
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3 and vim.api.nvim_win_get_cursor(0)[2] == 53)

  -- Single Location normalization in _build_entries
  local single_entries = types._build_entries("implementations", {
    uri = vim.uri_from_fname(base_path),
    range = { start = { line = 2, character = 22 }, ["end"] = { line = 2, character = 33 } },
  }, root)
  assert(#single_entries == 1 and single_entries[1].uri == vim.uri_from_fname(base_path))

  -- ---------- 7. Shared jdt:// isolation with calls.lua & real Neovim LSP ----------
  local calls = require("java_menu.calls")
  local shared_jdt_uri = "jdt://contents/shared.lib/com.shared/SharedType.class?=shared/SharedType.class"
  local cli_a = make_mock_client({
    id = 71,
    root_dir = root .. "/proj-a",
    respond = function(method)
      if method == "java/classFileContents" then
        return nil, "package com.shared;\npublic interface SharedType {}"
      end
    end,
  })
  local cli_b = make_mock_client({
    id = 72,
    root_dir = root .. "/proj-b",
    respond = function(method)
      if method == "java/classFileContents" then
        return nil, "package com.shared;\npublic interface SharedType { /* B */ }"
      end
    end,
  })

  -- Open via calls.lua under cli_a
  vim.api.nvim_set_current_buf(iface_buf)
  assert(
    calls._navigate_to(
      { uri = shared_jdt_uri, range = { start = { line = 1, character = 17 } } },
      cli_a,
      { bufnr = iface_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  flush_schedule()
  local shared_buf = track_buf(vim.api.nvim_get_current_buf())
  assert(vim.api.nvim_buf_get_name(shared_buf) == shared_jdt_uri)

  -- Same client via types.lua reuses shared_buf without extra classFileContents
  vim.api.nvim_set_current_buf(iface_buf)
  assert(
    types._navigate_to(
      { uri = shared_jdt_uri, range = { start = { line = 1, character = 17 } } },
      cli_a,
      { bufnr = iface_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  assert(vim.api.nvim_get_current_buf() == shared_buf, "types.lua did not reuse calls.lua owned jdt:// buffer")
  assert(#cli_a._sent == 1, "reuse sent duplicate classFileContents")

  -- Different client cli_b via types.lua MUST refuse collision
  vim.api.nvim_set_current_buf(iface_buf)
  reset_notices()
  assert(
    types._navigate_to(
      { uri = shared_jdt_uri, range = { start = { line = 1, character = 17 } } },
      cli_b,
      { bufnr = iface_buf, win = vim.api.nvim_get_current_win() }
    ) == false
  )
  flush_schedule()
  assert(#cli_b._sent == 0, "colliding cli_b sent classFileContents")
  assert(last_notice() and last_notice().msg:find("already owned by jdtls #71", 1, true))

  -- Real Neovim vim.lsp.start transport + real Client:supports_method capability check
  local function start_inproc_jdtls(project_root, caps, recorded_msgs)
    local seed_buf = track_buf(vim.api.nvim_create_buf(false, true))
    vim.api.nvim_buf_set_name(seed_buf, project_root .. "/Seed.java")
    local client_id = vim.lsp.start({
      name = "jdtls",
      root_dir = project_root,
      cmd = function()
        return {
          request = function(method, params, cb)
            recorded_msgs[#recorded_msgs + 1] = { method = method, params = vim.deepcopy(params) }
            if method == "initialize" then
              cb(nil, { capabilities = caps })
            elseif method == "java/classFileContents" then
              cb(nil, "package java.lang;\npublic interface Cloneable {}")
            elseif method == "textDocument/implementation" then
              cb(nil, {})
            else
              cb(nil, nil)
            end
            return true, #recorded_msgs
          end,
          notify = function(method, params)
            recorded_msgs[#recorded_msgs + 1] = { method = method, params = vim.deepcopy(params) }
          end,
          is_closing = function()
            return false
          end,
          terminate = function() end,
        }
      end,
    }, { bufnr = seed_buf })
    local c = vim.lsp.get_client_by_id(client_id)
    started_lsp_clients[#started_lsp_clients + 1] = c
    return c
  end

  vim.lsp.get_clients = real_get_clients
  local real_msgs = {}
  local real_cli = start_inproc_jdtls(root .. "/real-inproc", {
    typeHierarchyProvider = false,
    implementationProvider = true,
    textDocumentSync = 1,
  }, real_msgs)
  assert(
    vim.wait(1000, function()
      return real_cli.initialized
    end, 10),
    "in-process client did not initialize"
  )
  assert(
    types._supports_type_hierarchy(real_cli, iface_buf, "typeHierarchy/supertypes") == false,
    "real Neovim client with typeHierarchyProvider=false should not support type hierarchy"
  )
  assert(
    types._supports_implementations(real_cli, iface_buf) == true,
    "real Neovim client with implementationProvider=true should support implementations"
  )

  local cloneable_uri = "jdt://contents/java.base/java.lang/Cloneable.class?=real/Cloneable.class"
  vim.api.nvim_set_current_buf(iface_buf)
  assert(
    types._navigate_to(
      { uri = cloneable_uri, range = { start = { line = 1, character = 17 } } },
      real_cli,
      { bufnr = iface_buf, win = vim.api.nvim_get_current_win() }
    ) == true
  )
  assert(
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_name(0) == cloneable_uri
    end, 10),
    "real_cli did not open canonical Cloneable jdt:// buffer"
  )
  local real_jdt_buf = track_buf(vim.api.nvim_get_current_buf())
  types.implementations()
  assert(
    vim.wait(1000, function()
      for _, m in ipairs(real_msgs) do
        if
          m.method == "textDocument/implementation"
          and m.params
          and m.params.textDocument
          and m.params.textDocument.uri == cloneable_uri
        then
          return true
        end
      end
      return false
    end, 10),
    "implementation on jdt:// buffer did not preserve canonical URI"
  )
  assert(vim.api.nvim_buf_is_valid(real_jdt_buf))
  real_cli:stop(true)

  -- Restore mock get_clients
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

  -- ---------- 8. Cancellation, stale callbacks/pickers, changedtick & window guards ----------
  vim.api.nvim_set_current_buf(iface_buf)
  local slow_client = make_mock_client({
    id = 81,
    root_dir = root,
    respond = function()
      return nil, nil, true -- deferred
    end,
  })
  mock_clients_by_buf[iface_buf] = { slow_client }

  -- 8a. Cancel via types.cancel() + menu entry
  types.supertypes()
  local req1 = slow_client._sent[1].id
  assert(types._pending() and types._pending().request_id == req1)
  stub_select(nil)
  types.types()
  assert(find_line(select_calls[1].items, "Cancel active request"), "missing Cancel active request menu item")
  assert(types.cancel() == true)
  assert(slow_client._cancelled[1] == req1)
  assert(types._pending() == nil)
  reset_notices()
  slow_client:deliver(req1, nil, { item_greeter })
  flush_schedule()
  assert(#slow_client._sent == 1 and #notices == 0, "stale cancelled callback was not ignored")

  -- 8b. Superseding flow + server -32800
  types.subtypes()
  local req2 = slow_client._sent[2].id
  types.implementations()
  local req3 = slow_client._sent[3].id
  assert(slow_client._cancelled[2] == req2)
  slow_client:deliver(req2, nil, { item_greeter })
  flush_schedule()
  assert(#slow_client._sent == 3, "superseded req2 triggered subtypes")
  reset_notices()
  slow_client:deliver(req3, { code = -32800, message = "cancelled" }, nil)
  flush_schedule()
  assert(last_notice() and last_notice().level == vim.log.levels.INFO and last_notice().msg:find("cancelled", 1, true))

  -- 8c. Stale results picker & changedtick invalidation
  local captured = defer_select()
  types.implementations()
  local req4 = slow_client._sent[4].id
  slow_client:deliver(req4, nil, {
    { uri = vim.uri_from_fname(impl_path), range = { start = { line = 2, character = 13 } } },
  })
  flush_schedule()
  assert(#captured == 1 and captured[1].prompt:find("Implementations", 1, true))
  local stale_impl_picker = captured[1]

  -- Supersede with supertypes while implementations picker is open
  types.supertypes()
  local req5 = slow_client._sent[5].id
  reset_notices()
  stale_impl_picker.choose(stale_impl_picker.items[1])
  flush_schedule()
  assert(vim.api.nvim_get_current_buf() == iface_buf, "stale picker navigated!")
  assert(types._pending() and types._pending().request_id == req5)
  assert(#notices == 0)

  -- Edit buffer (changedtick) while req5 is in flight -> abort cleanly
  vim.api.nvim_buf_set_lines(iface_buf, 0, 0, false, { "// edited" })
  reset_notices()
  slow_client:deliver(req5, nil, { item_greeter })
  flush_schedule()
  assert(#slow_client._sent == 5, "stale callback after changedtick proceeded to supertypes")
  assert(last_notice() and last_notice().msg:find("buffer changed", 1, true))
  vim.bo[iface_buf].modified = false

  -- 8d. Two-window move guard while prepareTypeHierarchy is in flight
  vim.cmd("silent! only")
  local win1 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win1, iface_buf)
  vim.cmd("vsplit")
  local win2 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win2, base_buf)
  vim.api.nvim_set_current_win(win1)

  types.subtypes()
  local req6 = slow_client._sent[6].id
  vim.api.nvim_win_set_buf(win2, iface_buf)
  vim.api.nvim_win_set_buf(win1, main_buf)
  vim.api.nvim_set_current_win(win2)
  reset_notices()
  slow_client:deliver(req6, nil, { item_greeter })
  flush_schedule()
  assert(#slow_client._sent == 6, "window move triggered subtypes")
  assert(vim.api.nvim_get_current_win() == win2 and vim.api.nvim_win_get_buf(win2) == iface_buf)
  assert(last_notice() and last_notice().msg:find("window or buffer changed", 1, true))
  vim.cmd("silent! only")

  -- ---------- 9. jdt:// FileType suppression, malicious hook isolation, and safe local ftplugin ----------
  vim.lsp.get_clients = real_get_clients
  local iso_owner_msgs, iso_foreign_msgs = {}, {}
  local iso_owner = start_inproc_jdtls(root .. "/types-iso-owner", {
    typeHierarchyProvider = true,
    implementationProvider = true,
    textDocumentSync = 1,
  }, iso_owner_msgs)
  local iso_foreign = start_inproc_jdtls(root .. "/types-iso-foreign", {
    typeHierarchyProvider = true,
    implementationProvider = true,
    textDocumentSync = 1,
  }, iso_foreign_msgs)
  assert(
    vim.wait(1000, function()
      return iso_owner.initialized and iso_foreign.initialized
    end, 10),
    "types isolation test clients did not initialize"
  )
  local foreign_seed_buf = next(iso_foreign.attached_buffers)
  assert(foreign_seed_buf and vim.lsp.buf_is_attached(foreign_seed_buf, iso_foreign.id))
  for i = #iso_owner_msgs, 1, -1 do
    iso_owner_msgs[i] = nil
  end
  for i = #iso_foreign_msgs, 1, -1 do
    iso_foreign_msgs[i] = nil
  end

  local fake_rtp = track_dir(vim.fs.normalize(vim.fn.tempname() .. "-types-fake-rtp"))
  fixtures.write(
    fake_rtp .. "/ftplugin/java.lua",
    string.format(
      [[
vim.g.__types_malicious_rtp_ftplugin = true
pcall(vim.lsp.buf_attach_client, 0, %d)
vim.schedule(function()
  pcall(vim.lsp.buf_attach_client, 0, %d)
end)
]],
      iso_foreign.id,
      iso_foreign.id
    )
  )

  local saved_rtp_before = vim.o.runtimepath
  local saved_ei_before = vim.o.eventignore
  local saved_did_ftplugin = vim.g.did_load_ftplugin
  local saved_syntax_on = vim.g.syntax_on
  vim.cmd("filetype plugin on")
  vim.cmd("syntax on")
  vim.opt.runtimepath:prepend(fake_rtp)

  local types_guarded_uri = "jdt://contents/java.base/java.lang/Comparable.class?=types-guard/Comparable.class"
  local ft_fired = false
  local malicious_ft = vim.api.nvim_create_autocmd("FileType", {
    pattern = "java",
    callback = function(ev)
      ft_fired = true
      pcall(vim.lsp.buf_attach_client, ev.buf, iso_foreign.id)
      local b = ev.buf
      vim.schedule(function()
        pcall(vim.lsp.buf_attach_client, b, iso_foreign.id)
      end)
    end,
  })
  local lsp_attach_hook = vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(ev)
      if vim.api.nvim_buf_is_valid(ev.buf) and vim.b[ev.buf].java_menu_jdt_uri == types_guarded_uri then
        vim.b[ev.buf].types_lsp_attach_client = ev.data and ev.data.client_id
      end
    end,
  })

  vim.api.nvim_set_current_buf(iface_buf)
  local ok_iso, iso_err = pcall(function()
    assert(
      types._navigate_to(
        { uri = types_guarded_uri, range = { start = { line = 1, character = 17 } } },
        iso_owner,
        { bufnr = iface_buf, win = vim.api.nvim_get_current_win() }
      ) == true
    )
    assert(
      vim.wait(1000, function()
        return vim.api.nvim_buf_get_name(0) == types_guarded_uri and vim.lsp.buf_is_attached(0, iso_owner.id)
      end, 10),
      "types isolation owner client did not open and attach jdt:// buffer"
    )
    flush_schedule()

    local jdt_buf = track_buf(vim.api.nvim_get_current_buf())
    assert(not ft_fired, "arbitrary FileType autocmd ran on types jdt:// buffer")
    assert(vim.g.__types_malicious_rtp_ftplugin == nil, "user/plugin rtp ftplugin ran on types jdt:// buffer!")
    assert(not vim.lsp.buf_is_attached(jdt_buf, iso_foreign.id), "foreign client attached to types jdt:// buffer!")
    assert(#iso_foreign_msgs == 0, "foreign client received LSP messages via types jdt:// buffer!")
    assert(vim.lsp.buf_is_attached(foreign_seed_buf, iso_foreign.id), "foreign client detached from its own buffer!")
    assert(vim.b[jdt_buf].did_ftplugin == 1, "bundled $VIMRUNTIME ftplugin did not initialize in types")
    assert(vim.b[jdt_buf].current_syntax == "java", "bundled $VIMRUNTIME syntax did not initialize in types")
    assert(vim.b[jdt_buf].types_lsp_attach_client == iso_owner.id, "LspAttach did not fire for owning client")
  end)

  vim.api.nvim_del_autocmd(malicious_ft)
  vim.api.nvim_del_autocmd(lsp_attach_hook)
  vim.o.runtimepath = saved_rtp_before
  vim.o.eventignore = saved_ei_before
  vim.g.did_load_ftplugin = saved_did_ftplugin
  vim.g.syntax_on = saved_syntax_on
  vim.g.__types_malicious_rtp_ftplugin = nil
  iso_owner:stop(true)
  iso_foreign:stop(true)
  assert(ok_iso, iso_err)

  print("types_spec: OK")
end

local ok, err = xpcall(run_tests, debug.traceback)
cleanup()
if not ok then
  io.stderr:write("[types_spec] FAIL\n" .. tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
