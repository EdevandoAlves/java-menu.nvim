-- 8C (Issue #15): Java Stack Trace Navigation (java_menu.stacktrace) deterministic FAST tests.
-- Covers:
--   1. Lazy registration in init.lua without altering existing shortcuts
--   2. Stack trace line parsing (standard, module/version, classloader, inner/lambda/ctor, native, unknown, non-frame)
--   3. Per-buffer build output provenance (survives subsequent runs in other projects, refuses spoofed buffers, no secrets)
--   4. Untrusted/no-context buffers never guess cwd or first buffer/client (explicit selection or refusal)
--   5. Verified source-root scoping (never sends empty arguments[1]; disambiguates duplicate FQCNs and main/test roots)
--   6. Safe file:// and canonical jdt:// navigation via hierarchy, out-of-scope URI refusal, missing source message
--   7. Multi-client explicit selection, cancellation ($/cancelRequest), changedtick, window/buffer guards, line clamping
--
-- Run:
--   tests/java_menu/run.sh fast

local jm = require("java_menu")
local lsp = require("java_menu.lsp")
local build = require("java_menu.build")
local ui = require("java_menu.ui")
local run_config = require("java_menu.run_config")
local fixtures = require("tests.java_menu.fixtures")

local real_notify = vim.notify
local real_select = vim.ui.select
local real_get_clients = vim.lsp.get_clients
local real_ui_pick_one = ui.pick_one
local real_ui_notify = ui.notify
local real_ui_menu = ui.menu
local orig_cwd = vim.fn.getcwd()

local notices = {}
local function reset_notices()
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

local function open_file(path, lines, ft)
  local target = canonical(path)
  if lines then
    fixtures.write(path, lines)
    vim.cmd("edit! " .. vim.fn.fnameescape(target))
  else
    local existing = vim.fn.bufnr(target)
    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
      vim.api.nvim_set_current_buf(existing)
    else
      vim.cmd("edit " .. vim.fn.fnameescape(target))
    end
  end
  local buf = vim.api.nvim_get_current_buf()
  if ft then
    vim.bo[buf].filetype = ft
  end
  return track_buf(buf)
end

local function open_scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  return track_buf(buf)
end

local function flush_schedule()
  vim.wait(30, function()
    return false
  end, 5)
end

local function make_mock_client(opts)
  opts = opts or {}
  local next_id = 500
  local sent = {}
  local cancelled = {}
  local pending_callbacks = {}

  local default_caps = {
    executeCommandProvider = {
      commands = {
        "java.project.listSourcePaths",
        "java.project.resolveStackTraceLocation",
      },
    },
  }

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

local function cleanup()
  pcall(function()
    if package.loaded["java_menu.stacktrace"] then
      require("java_menu.stacktrace")._reset()
    end
    if package.loaded["java_menu.hierarchy"] then
      require("java_menu.hierarchy").reset_jdt_bufs()
    end
  end)
  pcall(vim.cmd, "silent! only")
  pcall(vim.fn.chdir, orig_cwd)
  vim.notify = real_notify
  vim.ui.select = real_select
  vim.lsp.get_clients = real_get_clients
  ui.pick_one = real_ui_pick_one
  ui.notify = real_ui_notify
  ui.menu = real_ui_menu
  for _, buf in ipairs(created_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  for _, dir in ipairs(temp_dirs) do
    pcall(vim.fn.delete, dir, "rf")
  end
end

local function run_tests()
  vim.notify = function(msg, level)
    notices[#notices + 1] = { msg = tostring(msg), level = level }
  end
  ui.notify = function(msg, level)
    vim.notify("Java: " .. msg, level or vim.log.levels.INFO)
  end

  -- ---------- 1. Lazy action in init.lua without altering existing shortcuts ----------
  assert(package.loaded["java_menu.stacktrace"] == nil, "java_menu.stacktrace loaded before setup")
  jm.setup({ prefix = "<leader>j" })

  for _, key in ipairs({ "n", "g", "r", "i", "b", "t", "d", "p", "c", "h", "s" }) do
    local m = vim.fn.maparg("<leader>j" .. key, "n", false, true)
    assert(type(m) == "table" and not vim.tbl_isempty(m), "missing keymap <leader>j" .. key)
  end
  local smap = vim.fn.maparg("<leader>js", "n", false, true)
  assert(smap.desc == "Java Menu: Stack Trace", "unexpected <leader>js desc: " .. tostring(smap.desc))
  assert(package.loaded["java_menu.stacktrace"] == nil, "setup loaded java_menu.stacktrace eagerly")

  jm.setup({ prefix = "<leader>j", groups = { stacktrace = false } })
  assert(vim.fn.maparg("<leader>js", "n") == "", "stacktrace group disabled still mapped")
  assert(
    vim.fn.maparg("<leader>jh", "n", false, true).desc == "Java Menu: Type Hierarchy",
    "disabling stacktrace affected types"
  )

  vim.keymap.set("n", "<leader>js", function() end, { desc = "custom stacktrace map" })
  reset_notices()
  jm.setup({ prefix = "<leader>j", groups = { stacktrace = true } })
  assert(
    last_notice() and last_notice().msg:find("conflict", 1, true) and last_notice().msg:find("<leader>js", 1, true),
    "conflict on <leader>js was not reported"
  )
  assert(
    vim.fn.maparg("<leader>js", "n", false, true).desc == "custom stacktrace map",
    "third-party <leader>js was overwritten"
  )
  vim.keymap.del("n", "<leader>js")
  jm.setup({ prefix = "<leader>j" })

  local st = require("java_menu.stacktrace")

  -- ---------- 2. Line parsing edge cases ----------
  local p1 = st._parse_line("\tat com.acme.Main.main(Main.java:10)")
  assert(p1 and p1.kind == "source" and p1.declaring_class == "com.acme.Main" and p1.line_number == 10)
  assert(p1.source_relpath == "com/acme/Main.java")

  local p_mod = st._parse_line("\tat java.base@21.0.2/java.lang.Thread.run(Thread.java:1583)")
  assert(
    p_mod
      and p_mod.kind == "source"
      and p_mod.module_name == "java.base"
      and p_mod.module_version == "21.0.2"
      and p_mod.declaring_class == "java.lang.Thread"
      and p_mod.source_relpath == "java/lang/Thread.java"
      and p_mod.line_number == 1583,
    "failed to parse module@version frame"
  )

  local p_cl =
    st._parse_line("\tat my.loader/my.mod@1.0.0-SNAPSHOT/com.acme.Outer$Inner.<init>(Outer.java:25) ~[app.jar:na]")
  assert(
    p_cl
      and p_cl.kind == "source"
      and p_cl.classloader == "my.loader"
      and p_cl.module_name == "my.mod"
      and p_cl.module_version == "1.0.0-SNAPSHOT"
      and p_cl.is_inner == true
      and p_cl.outer_class == "Outer"
      and p_cl.method_name == "<init>"
      and p_cl.source_relpath == "com/acme/Outer.java"
      and p_cl.line_number == 25,
    "failed to parse classloader/module@version/inner frame"
  )

  local p_app = st._parse_line("\tat app//com.acme.Outer.lambda$main$0(Outer.java:18)")
  assert(
    p_app
      and p_app.classloader == "app"
      and p_app.module_name == nil
      and p_app.method_name == "lambda$main$0"
      and p_app.source_relpath == "com/acme/Outer.java"
      and p_app.line_number == 18,
    "failed to parse app// lambda frame"
  )

  local p_def = st._parse_line("at Main.main(Main.java)")
  assert(
    p_def
      and p_def.package_name == ""
      and p_def.simple_class == "Main"
      and p_def.source_relpath == "Main.java"
      and p_def.line_number == nil,
    "failed to parse default package without line number"
  )

  local p_nat = st._parse_line("\tat java.base@21/java.lang.Object.wait(Native Method)")
  assert(p_nat and p_nat.kind == "native" and p_nat.declaring_class == "java.lang.Object", "failed native frame")

  local p_unk = st._parse_line("\tat com.acme.Proxy.$do(Unknown Source)")
  assert(p_unk and p_unk.kind == "unknown" and p_unk.declaring_class == "com.acme.Proxy", "failed unknown frame")

  local p_lam = st._parse_line("\tat com.acme.Main$$Lambda/0x00007f8b1c001000.run(Unknown Source)")
  assert(p_lam and p_lam.kind == "unknown", "failed Java 21 hidden lambda unknown frame")

  assert(st._parse_line("") == nil, "empty line should not parse")
  assert(st._parse_line("Caused by: java.lang.IllegalStateException: boom") == nil, "Caused by should not parse")
  assert(st._parse_line("\t... 14 more") == nil, "elided frame should not parse")
  assert(st._parse_line('System.out.println("hello")') == nil, "method call should not parse")

  -- Native / Unknown / non-frame notifications without calling LSP
  local lsp_calls_on_non_source = 0
  vim.lsp.get_clients = function()
    lsp_calls_on_non_source = lsp_calls_on_non_source + 1
    return {}
  end

  open_scratch({
    "\tat java.base@21.0.2/java.lang.Object.wait(Native Method)",
    "\tat com.acme.Proxy.$do(Unknown Source)",
    "Caused by: java.lang.RuntimeException: boom",
  })
  reset_notices()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  st.stacktrace()
  assert(has_notice("native method"), "expected native method notice")
  reset_notices()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  st.stacktrace()
  assert(has_notice("unknown source"), "expected unknown source notice")
  reset_notices()
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  st.stacktrace()
  assert(has_notice("no Java stack trace frame"), "expected non-frame notice")
  assert(lsp_calls_on_non_source == 0, "non-source frames should not query LSP clients")

  -- ---------- 3. Per-buffer build output provenance & isolation across projects ----------
  local cfg_base = track_dir(vim.fs.normalize(vim.fn.tempname() .. "-st-cfg"))
  run_config._base_dir = cfg_base

  local root_a, main_a = fixtures.maven_project("st-proj-a", "com.alpha", "AlphaMain")
  track_dir(root_a)
  root_a = canonical(root_a)
  fixtures.write(main_a, {
    "package com.alpha;",
    "public class AlphaMain {",
    "  public static void main(String[] args) {",
    '    throw new RuntimeException("alpha");',
    "  }",
    "}",
  })
  fixtures.write(root_a .. "/.env", { "SECRET_TOKEN=super-secret-value-12345" })
  fixtures.write(root_a .. "/mvnw", {
    "#!/bin/sh",
    'echo "\tat com.alpha.AlphaMain.main(AlphaMain.java:4)"',
    "exit 0",
  })
  vim.fn.system({ "chmod", "+x", root_a .. "/mvnw" })

  local root_b, main_b = fixtures.maven_project("st-proj-b", "com.beta", "BetaMain")
  track_dir(root_b)
  root_b = canonical(root_b)
  fixtures.write(main_b, {
    "package com.beta;",
    "public class BetaMain {",
    "  public static void main(String[] args) {",
    '    throw new RuntimeException("beta");',
    "  }",
    "}",
  })
  fixtures.write(root_b .. "/mvnw", {
    "#!/bin/sh",
    'echo "\tat com.beta.BetaMain.main(BetaMain.java:4)"',
    "exit 0",
  })
  vim.fn.system({ "chmod", "+x", root_b .. "/mvnw" })

  -- Stub ui.menu / ui.pick_one temporarily for build.build() runs
  local b_entries, b_cb
  ui.menu = function(entries, _, on_choice)
    b_entries, b_cb = entries, on_choice
  end
  local function find_entry(key)
    for _, e in ipairs(b_entries) do
      if e.key == key then
        return e
      end
    end
  end

  open_file(main_a, nil, "java")
  build.build()
  b_cb(find_entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return not build._state.running and not build._is_draining()
    end),
    "build A did not finish"
  )
  local out_buf_a = track_buf(build._state.last_output)
  assert(out_buf_a and vim.api.nvim_buf_is_valid(out_buf_a), "missing build output buffer A")

  open_file(main_b, nil, "java")
  build.build()
  b_cb(find_entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return not build._state.running and not build._is_draining()
    end),
    "build B did not finish"
  )
  local out_buf_b = track_buf(build._state.last_output)
  assert(out_buf_b and out_buf_b ~= out_buf_a, "expected distinct output buffer B")
  assert(canonical(build._state.last_output_root) == root_b, "global last_output_root should now be B")

  local prov_a = build.output_provenance(out_buf_a)
  local prov_b = build.output_provenance(out_buf_b)
  assert(prov_a and prov_a.root == root_a, "output buffer A lost its root provenance: " .. vim.inspect(prov_a))
  assert(prov_b and prov_b.root == root_b, "output buffer B wrong root provenance: " .. vim.inspect(prov_b))
  assert(not vim.inspect(prov_a):find("super-secret-value-12345", 1, true), "provenance leaked .env secret")

  -- Spoofed / tampered buffer must NOT be trusted
  local spoof_buf = open_scratch({ "\tat com.alpha.AlphaMain.main(AlphaMain.java:4)" })
  vim.b[spoof_buf].java_build_title = "compile"
  assert(build.output_provenance(spoof_buf) == nil, "spoofed buffer without build provenance must return nil")
  local spoof_prov = st._resolve_provenance(spoof_buf)
  assert(spoof_prov.trusted == false, "spoofed output buffer must not be trusted")

  -- Tampering java_build_root on a real output buffer invalidates trust
  local saved_root_var = vim.b[out_buf_b].java_build_root
  vim.b[out_buf_b].java_build_root = root_a
  assert(build.output_provenance(out_buf_b) == nil, "tampered java_build_root must fail provenance check")
  vim.b[out_buf_b].java_build_root = saved_root_var
  assert(build.output_provenance(out_buf_b).root == root_b, "restored java_build_root should verify")

  -- Restore ui.pick_one and ui.menu for stacktrace tests
  ui.pick_one = real_ui_pick_one
  ui.menu = real_ui_menu

  -- Navigate from out_buf_a even while last_output_root is root_b
  local client_a = make_mock_client({
    id = 11,
    root_dir = root_a,
    respond = function(method, params)
      if params.command == "java.project.listSourcePaths" then
        return nil, { data = { { path = root_a .. "/src/main/java", projectName = "st-proj-a" } } }
      elseif params.command == "java.project.resolveStackTraceLocation" then
        assert(
          type(params.arguments[2]) == "table" and #params.arguments[2] == 1 and params.arguments[2][1] == "st-proj-a",
          "expected restricted projectNames { 'st-proj-a' }, got " .. vim.inspect(params.arguments[2])
        )
        return nil, vim.uri_from_fname(main_a)
      end
    end,
  })
  local client_b = make_mock_client({
    id = 12,
    root_dir = root_b,
    respond = function()
      error("client_b must NEVER be called from output buffer A")
    end,
  })
  vim.lsp.get_clients = function(filter)
    local all = { client_a, client_b }
    if filter and filter.bufnr then
      return {}
    end
    return all
  end

  vim.api.nvim_set_current_buf(out_buf_a)
  local out_lines_a = vim.api.nvim_buf_get_lines(out_buf_a, 0, -1, false)
  local trace_row_a
  for idx, l in ipairs(out_lines_a) do
    if l:find("AlphaMain.java:4", 1, true) then
      trace_row_a = idx
      break
    end
  end
  assert(trace_row_a, "expected stacktrace line in output buffer A")
  vim.api.nvim_win_set_cursor(0, { trace_row_a, 0 })
  stub_select(nil)
  st.stacktrace()
  flush_schedule()
  assert(#select_calls == 0, "proven build output buffer A should not prompt when 1 matching client exists")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(main_a), "did not navigate to AlphaMain.java")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 4, "did not jump to line 4 in AlphaMain.java")

  -- When matching client for out_buf_a is stopped, refuse instead of using client_b
  client_a._stopped = true
  vim.api.nvim_set_current_buf(out_buf_a)
  vim.api.nvim_win_set_cursor(0, { trace_row_a, 0 })
  reset_notices()
  st.stacktrace()
  assert(has_notice("no running jdtls client matches project"), "expected refusal when matching client is stopped")
  assert(#client_b._sent == 0, "client_b was touched when client_a was stopped")
  client_a._stopped = false

  -- Spoofed / tampered build output buffer MUST refuse even when clients are attached/running
  vim.api.nvim_set_current_buf(spoof_buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local sent_spoof_a, sent_spoof_b = #client_a._sent, #client_b._sent
  vim.lsp.get_clients = function()
    return { client_a, client_b }
  end
  reset_notices()
  stub_select(function(items)
    return items[1]
  end)
  st.stacktrace()
  assert(has_notice("no verified project provenance"), "spoofed output buffer must be refused")
  assert(#select_calls == 0, "spoofed output buffer must not open client picker")
  assert(#client_a._sent == sent_spoof_a and #client_b._sent == sent_spoof_b, "spoofed output buffer contacted LSP")

  -- Regression (3): foreign-root attached client on verified build output is NEVER used
  vim.lsp.get_clients = function(filter)
    if filter and filter.bufnr == out_buf_a then
      return { client_b }
    end
    return { client_a, client_b }
  end
  vim.api.nvim_set_current_buf(out_buf_a)
  vim.api.nvim_win_set_cursor(0, { trace_row_a, 0 })
  stub_select(nil)
  st.stacktrace()
  flush_schedule()
  assert(#select_calls == 0, "should resolve matching live client_a without prompting when only client_b was attached")
  assert(#client_b._sent == 0, "foreign-root attached client_b must NEVER be contacted")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(main_a), "did not route to matching client_a")

  -- When matching client_a is stopped while foreign client_b is attached to out_buf_a, refuse
  client_a._stopped = true
  vim.api.nvim_set_current_buf(out_buf_a)
  vim.api.nvim_win_set_cursor(0, { trace_row_a, 0 })
  reset_notices()
  st.stacktrace()
  assert(
    has_notice("no running jdtls client matches project"),
    "expected refusal when only wrong-root client is attached"
  )
  assert(#client_b._sent == 0, "foreign-root attached client_b was contacted when client_a stopped")
  client_a._stopped = false

  -- Regression (3b): verified build output with pinned client_id only auto-uses matching id+root attached client
  local pinned_client_a = make_mock_client({
    id = 111,
    root_dir = root_a,
    respond = function(_, params)
      if params.command == "java.project.listSourcePaths" then
        return nil, { data = { { path = root_a .. "/src/main/java", projectName = "st-proj-a" } } }
      elseif params.command == "java.project.resolveStackTraceLocation" then
        return nil, vim.uri_from_fname(main_a)
      end
    end,
  })
  local other_id_client_a = make_mock_client({
    id = 112,
    root_dir = root_a,
    respond = function(_, params)
      if params.command == "java.project.listSourcePaths" then
        return nil, { data = { { path = root_a .. "/src/main/java", projectName = "st-proj-a" } } }
      elseif params.command == "java.project.resolveStackTraceLocation" then
        return nil, vim.uri_from_fname(main_a)
      end
    end,
  })
  vim.lsp.get_clients = function(filter)
    if filter and filter.bufnr then
      return { pinned_client_a }
    end
    return { pinned_client_a }
  end
  open_file(main_a, nil, "java")
  ui.menu = function(entries, _, on_choice)
    b_entries, b_cb = entries, on_choice
  end
  build.build()
  b_cb(find_entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return not build._state.running and not build._is_draining()
    end),
    "pinned build A did not finish"
  )
  ui.menu = real_ui_menu
  local out_buf_pinned = track_buf(build._state.last_output)
  local prov_pinned = build.output_provenance(out_buf_pinned)
  assert(prov_pinned and prov_pinned.client_id == 111, "expected pinned client_id 111 in build output provenance")

  local trace_row_pinned
  for idx, l in ipairs(vim.api.nvim_buf_get_lines(out_buf_pinned, 0, -1, false)) do
    if l:find("AlphaMain.java:4", 1, true) then
      trace_row_pinned = idx
      break
    end
  end
  assert(trace_row_pinned, "expected stacktrace line in pinned output buffer")

  -- Attached wrong-id (#112) and wrong-root (#12) on out_buf_pinned while #111 is live -> routes to #111
  vim.lsp.get_clients = function(filter)
    if filter and filter.bufnr == out_buf_pinned then
      return { other_id_client_a, client_b }
    end
    return { pinned_client_a, other_id_client_a, client_b }
  end
  vim.api.nvim_set_current_buf(out_buf_pinned)
  vim.api.nvim_win_set_cursor(0, { trace_row_pinned, 0 })
  stub_select(nil)
  st.stacktrace()
  flush_schedule()
  assert(#select_calls == 0, "should prefer exact pinned client #111 without prompting")
  assert(#pinned_client_a._sent == 2, "expected pinned client #111 to handle request")
  assert(#other_id_client_a._sent == 0, "wrong-id attached client #112 must not be used when #111 is live")
  assert(#client_b._sent == 0, "wrong-root client_b must never be used")

  -- When pinned client #111 is stopped and #112 (different id, same root) is attached -> MUST prompt explicitly
  pinned_client_a._stopped = true
  vim.api.nvim_set_current_buf(out_buf_pinned)
  vim.api.nvim_win_set_cursor(0, { trace_row_pinned, 0 })
  stub_select(nil) -- user cancels
  st.stacktrace()
  assert(#select_calls == 1, "attached client with mismatched id must require explicit selection")
  assert(#other_id_client_a._sent == 0, "cancelling mismatched-id picker must not dispatch LSP requests")
  stub_select(function(items)
    for _, item in ipairs(items) do
      if item:find("#112", 1, true) then
        return item
      end
    end
  end)
  st.stacktrace()
  flush_schedule()
  assert(#select_calls == 1 and #other_id_client_a._sent == 2, "explicitly confirmed #112 should resolve")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(main_a), "did not navigate via confirmed #112")
  pinned_client_a._stopped = false

  -- ---------- 4. Untrusted buffer (scratch / outside project) never guesses cwd/first client ----------
  vim.fn.chdir(root_a)
  local scratch = open_scratch({ "\tat com.alpha.AlphaMain.main(AlphaMain.java:4)" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  -- With 0 live clients: refuse
  vim.lsp.get_clients = function()
    return {}
  end
  reset_notices()
  st.stacktrace()
  assert(has_notice("no jdtls client is running"), "expected refusal with 0 clients")

  -- With 1 live client: MUST still ask explicit selection (never silently choose first client/cwd)
  vim.lsp.get_clients = function(filter)
    if filter and filter.bufnr then
      return {}
    end
    return { client_a }
  end
  local sent_before_cancel = #client_a._sent
  stub_select(nil) -- user cancels picker
  st.stacktrace()
  assert(#select_calls == 1, "untrusted buffer with 1 client must ask explicitly instead of auto-selecting")
  assert(#client_a._sent == sent_before_cancel, "cancelling picker must not dispatch LSP requests")

  -- User explicitly confirms client_a from picker
  stub_select(function(items)
    return items[1]
  end)
  st.stacktrace()
  flush_schedule()
  assert(#select_calls == 1, "expected explicit picker")
  assert(#client_a._sent == sent_before_cancel + 2, "expected LSP requests after confirming client_a")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(main_a), "did not jump after explicit client choice")

  -- ---------- 5. Multi-module source-root verification & duplicate FQCN disambiguation ----------
  local mm_root = track_dir(vim.fs.normalize(vim.fn.tempname() .. "-st-mm"))
  fixtures.write(mm_root .. "/pom.xml", {
    "<project><modelVersion>4.0.0</modelVersion><groupId>com.mm</groupId><artifactId>mm</artifactId><version>1.0</version><packaging>pom</packaging>",
    "<modules><module>api</module><module>service</module><module>dup-a</module><module>dup-b</module></modules></project>",
  })
  for _, m in ipairs({ "api", "service", "dup-a", "dup-b" }) do
    fixtures.write(mm_root .. "/" .. m .. "/pom.xml", {
      "<project><modelVersion>4.0.0</modelVersion><groupId>com.mm</groupId><artifactId>"
        .. m
        .. "</artifactId><version>1.0</version></project>",
    })
  end
  mm_root = canonical(mm_root)

  local api_file = mm_root .. "/api/src/main/java/com/mm/api/ApiEntry.java"
  local svc_file = mm_root .. "/service/src/main/java/com/mm/svc/Runner.java"
  local dup_a_file = mm_root .. "/dup-a/src/main/java/com/mm/dup/Same.java"
  local dup_b_file = mm_root .. "/dup-b/src/main/java/com/mm/dup/Same.java"
  local same_test_file = mm_root .. "/service/src/test/java/com/mm/svc/Runner.java"

  fixtures.write(api_file, { "package com.mm.api;", "public class ApiEntry {", "  public static void go() {}", "}" })
  fixtures.write(svc_file, {
    "package com.mm.svc;",
    "public class Runner {",
    "  // at com.mm.api.ApiEntry.go(ApiEntry.java:3)",
    "  // at com.mm.dup.Same.origin(Same.java:4)",
    "  // at com.mm.svc.Runner.testIt(Runner.java:2)",
    "  // at com.ext.ExtLib.boom(ExtLib.java:12)",
    "  // at com.missing.Nope.none(Nope.java:99)",
    "}",
  })
  fixtures.write(dup_a_file, {
    "package com.mm.dup;",
    "public class Same {",
    "  public static void origin() {",
    "    // dup-a line 4",
    "  }",
    "}",
  })
  fixtures.write(dup_b_file, {
    "package com.mm.dup;",
    "public class Same {",
    "  public static void origin() {",
    "    // dup-b line 4",
    "  }",
    "}",
  })
  fixtures.write(same_test_file, { "package com.mm.svc;", "public class Runner {", "  // test runner line 3", "}" })

  local stray_root = track_dir(vim.fs.normalize(vim.fn.tempname() .. "-st-stray"))
  local stray_file = stray_root .. "/src/main/java/com/mm/api/ApiEntry.java"
  fixtures.write(stray_file, { "package com.mm.api;", "public class ApiEntry { /* stray */ }" })

  local jdt_ext_uri = "jdt://contents/extlib.jar/com.ext/ExtLib.class?=service/%5C/extlib.jar%3Ccom.ext(ExtLib.class"
  local jdt_ext_src = table.concat({
    "package com.ext;",
    "public class ExtLib {",
    "  public static void boom() {",
    "    // line 4",
    "    // line 5",
    "    // line 6",
    "    // line 7",
    "    // line 8",
    "    // line 9",
    "    // line 10",
    "    // line 11",
    '    throw new IllegalStateException("ext");',
    "  }",
    "}",
  }, "\n")

  local mm_client
  mm_client = make_mock_client({
    id = 20,
    root_dir = mm_root,
    respond = function(method, params)
      if method == "java/classFileContents" then
        assert(params.uri == jdt_ext_uri, "unexpected jdt uri: " .. tostring(params.uri))
        return nil, jdt_ext_src
      end
      if params.command == "java.project.listSourcePaths" then
        return nil,
          {
            data = {
              { path = mm_root .. "/api/src/main/java", projectName = "api" },
              { path = mm_root .. "/service/src/main/java", projectName = "service" },
              { path = mm_root .. "/service/src/test/java", projectName = "service" },
              { path = mm_root .. "/dup-a/src/main/java", projectName = "dup-a" },
              { path = mm_root .. "/dup-b/src/main/java", projectName = "dup-b" },
              -- Stray out-of-project entry in same workspace must be ignored by scoped_root
              { path = stray_root .. "/src/main/java", projectName = "stray" },
            },
          }
      elseif params.command == "java.project.resolveStackTraceLocation" then
        local proj_list = params.arguments[2]
        assert(
          type(proj_list) == "table" and #proj_list == 1,
          "must NEVER call resolveStackTraceLocation with empty/multi arbitrary projectNames: "
            .. vim.inspect(proj_list)
        )
        local p = proj_list[1]
        assert(p ~= "stray", "out-of-root project 'stray' must never be queried")
        local line = params.arguments[1]
        if line:find("ApiEntry.java", 1, true) and p == "api" then
          return nil, vim.uri_from_fname(api_file)
        elseif line:find("Same.java", 1, true) and p == "dup-a" then
          return nil, vim.uri_from_fname(dup_a_file)
        elseif line:find("Same.java", 1, true) and p == "dup-b" then
          return nil, vim.uri_from_fname(dup_b_file)
        elseif line:find("ExtLib.java", 1, true) and p == "service" then
          return nil, jdt_ext_uri
        end
        return nil, vim.NIL
      end
    end,
  })

  vim.lsp.get_clients = function(filter)
    if filter and filter.bufnr then
      if filter.bufnr == vim.fn.bufnr(svc_file) then
        return { mm_client }
      end
      return {}
    end
    return { mm_client }
  end

  -- 5a. Cross-module unique match (`api`), ignoring `stray`
  local svc_buf = open_file(svc_file, nil, "java")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  stub_select(nil)
  st.stacktrace()
  flush_schedule()
  assert(#select_calls == 0, "unique api match should not prompt")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(api_file), "did not jump to api/ApiEntry.java")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3, "expected line 3 in ApiEntry.java")

  -- 5b. Duplicate FQCN across `dup-a` and `dup-b` -> prompts user, chooses `dup-b`
  open_file(svc_file, nil, "java")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  stub_select(function(items)
    for _, item in ipairs(items) do
      if item:find("dup-b", 1, true) then
        return item
      end
    end
  end)
  st.stacktrace()
  flush_schedule()
  assert(#select_calls == 1, "duplicate FQCN across modules must prompt user")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(dup_b_file), "did not navigate to chosen dup-b Same.java")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 4, "expected line 4 in dup-b Same.java")

  -- 5c. Multiple source roots within same JDT project (`service` main vs test) -> prompts user, respects choice
  open_file(svc_file, nil, "java")
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  stub_select(function(items)
    for _, item in ipairs(items) do
      if item:find("src/test/java", 1, true) then
        return item
      end
    end
  end)
  st.stacktrace()
  flush_schedule()
  assert(#select_calls == 1, "main vs test collision in same project must prompt")
  assert(
    canonical(vim.api.nvim_buf_get_name(0)) == canonical(same_test_file),
    "did not navigate to chosen src/test/java Runner.java"
  )
  assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "expected line 2 in test Runner.java")

  -- 5d. Library jdt:// target via non-empty per-project queries + canonical jdt:// buffer
  open_file(svc_file, nil, "java")
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  stub_select(nil)
  st.stacktrace()
  flush_schedule()
  local jdt_buf = vim.api.nvim_get_current_buf()
  track_buf(jdt_buf)
  assert(vim.api.nvim_buf_get_name(jdt_buf) == jdt_ext_uri, "expected canonical jdt:// buffer name")
  assert(
    vim.bo[jdt_buf].buftype == "nofile" and vim.bo[jdt_buf].modifiable == false,
    "jdt:// buffer should be read-only nofile"
  )
  assert(vim.api.nvim_win_get_cursor(0)[1] == 12, "expected line 12 in jdt:// ExtLib.class")

  -- 5e. Missing class / nil from JDTLS -> clear message
  open_file(svc_file, nil, "java")
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  reset_notices()
  st.stacktrace()
  flush_schedule()
  assert(has_notice("source location not found in jdtls"), "expected missing source location notice")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(svc_file), "missing target must stay on current file")

  -- ---------- 6. Line clamping when target file has fewer lines ----------
  local clamp_file = mm_root .. "/api/src/main/java/com/mm/api/ShortFile.java"
  fixtures.write(clamp_file, { "package com.mm.api;", "public class ShortFile {}" })
  local clamp_client = make_mock_client({
    id = 21,
    root_dir = mm_root,
    respond = function(_, params)
      if params.command == "java.project.listSourcePaths" then
        return nil, { data = { { path = mm_root .. "/api/src/main/java", projectName = "api" } } }
      elseif params.command == "java.project.resolveStackTraceLocation" then
        return nil, vim.uri_from_fname(clamp_file)
      end
    end,
  })
  vim.lsp.get_clients = function(filter)
    if filter and filter.bufnr then
      return { clamp_client }
    end
    return { clamp_client }
  end
  open_file(svc_file, nil, "java")
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// at com.mm.api.ShortFile.go(ShortFile.java:999)" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  st.stacktrace()
  flush_schedule()
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(clamp_file), "did not open ShortFile.java")
  assert(
    vim.api.nvim_win_get_cursor(0)[1] == 2,
    "expected line clamped to 2, got " .. vim.api.nvim_win_get_cursor(0)[1]
  )

  -- ---------- 7. Out-of-scope file:// URI refusal ----------
  local evil_client = make_mock_client({
    id = 22,
    root_dir = mm_root,
    respond = function(_, params)
      if params.command == "java.project.listSourcePaths" then
        return nil, { data = { { path = mm_root .. "/api/src/main/java", projectName = "api" } } }
      elseif params.command == "java.project.resolveStackTraceLocation" then
        return nil, vim.uri_from_fname(stray_file)
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { evil_client }
  end
  open_file(svc_file, nil, "java")
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// at com.other.Foreign.go(Foreign.java:1)" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  reset_notices()
  st.stacktrace()
  flush_schedule()
  assert(has_notice("refused navigation outside project"), "expected out-of-scope URI refusal")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(svc_file), "out-of-scope URI must not navigate")

  -- ---------- 7b. Regression (2): expected_file refuses jdt:// & divergent file://, checks provenance ----------
  local cfc_called_when_local = false
  local jdt_instead_of_local_client = make_mock_client({
    id = 23,
    root_dir = mm_root,
    respond = function(method, params)
      if method == "java/classFileContents" then
        cfc_called_when_local = true
        return nil, "class Fake {}"
      end
      if params.command == "java.project.listSourcePaths" then
        return nil, { data = { { path = mm_root .. "/api/src/main/java", projectName = "api" } } }
      elseif params.command == "java.project.resolveStackTraceLocation" then
        return nil, jdt_ext_uri
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { jdt_instead_of_local_client }
  end
  open_file(svc_file, nil, "java")
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// at com.mm.api.ApiEntry.go(ApiEntry.java:3)" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  reset_notices()
  st.stacktrace()
  flush_schedule()
  assert(has_notice("instead of local candidate"), "expected refusal when jdt:// returned for local candidate")
  assert(not cfc_called_when_local, "java/classFileContents must not be called when local candidate exists")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(svc_file), "jdt:// for local candidate must not navigate")

  local divergent_file_client = make_mock_client({
    id = 24,
    root_dir = mm_root,
    respond = function(_, params)
      if params.command == "java.project.listSourcePaths" then
        return nil,
          {
            data = {
              { path = mm_root .. "/dup-a/src/main/java", projectName = "dup-a" },
              { path = mm_root .. "/dup-b/src/main/java", projectName = "dup-b" },
            },
          }
      elseif params.command == "java.project.resolveStackTraceLocation" then
        -- User picks dup-b, but JDTLS returns dup-a!
        return nil, vim.uri_from_fname(dup_a_file)
      end
    end,
  })
  vim.lsp.get_clients = function()
    return { divergent_file_client }
  end
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// at com.mm.dup.Same.origin(Same.java:4)" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  stub_select(function(items)
    for _, item in ipairs(items) do
      if item:find("dup-b", 1, true) then
        return item
      end
    end
  end)
  reset_notices()
  st.stacktrace()
  flush_schedule()
  assert(has_notice("instead of selected candidate"), "expected refusal when file:// diverges from selected candidate")
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(svc_file), "divergent file:// must not navigate")

  -- Provenance tampered mid-flight before navigation is refused
  local deferred_prov_client = make_mock_client({
    id = 25,
    root_dir = root_a,
    respond = function()
      return nil, nil, true
    end,
  })
  vim.lsp.get_clients = function(filter)
    if filter and filter.bufnr then
      return {}
    end
    return { deferred_prov_client }
  end
  vim.api.nvim_set_current_buf(out_buf_a)
  vim.api.nvim_win_set_cursor(0, { trace_row_a, 0 })
  st.stacktrace()
  assert(st._pending() ~= nil, "expected pending listSourcePaths for deferred provenance test")
  local req_prov_1 = st._pending().request_id
  deferred_prov_client:deliver(req_prov_1, nil, {
    data = { { path = root_a .. "/src/main/java", projectName = "st-proj-a" } },
  })
  flush_schedule()
  assert(st._pending() ~= nil, "expected pending resolveStackTraceLocation for deferred provenance test")
  local req_prov_2 = st._pending().request_id
  local orig_build_root = vim.b[out_buf_a].java_build_root
  vim.b[out_buf_a].java_build_root = root_b -- tamper mid-flight!
  reset_notices()
  deferred_prov_client:deliver(req_prov_2, nil, vim.uri_from_fname(main_a))
  flush_schedule()
  vim.b[out_buf_a].java_build_root = orig_build_root
  assert(has_notice("provenance changed"), "expected provenance mismatch refusal before navigation")
  assert(vim.api.nvim_get_current_buf() == out_buf_a, "tampered provenance must not navigate")

  -- ---------- 8. Multi-client selection, cancel(), stale pickers/callbacks, changedtick & window guards ----------
  local deferred_client = make_mock_client({
    id = 30,
    root_dir = mm_root,
    respond = function()
      return nil, nil, true -- defer!
    end,
  })
  local second_client = make_mock_client({
    id = 31,
    root_dir = mm_root,
    respond = function()
      error("second_client was not chosen")
    end,
  })

  vim.lsp.get_clients = function(filter)
    if filter and filter.bufnr then
      return { deferred_client, second_client }
    end
    return { deferred_client, second_client }
  end

  open_file(svc_file, nil, "java")
  vim.api.nvim_buf_set_lines(svc_buf, 0, 2, false, {
    "// at com.mm.api.ApiEntry.go(ApiEntry.java:3)",
    "\tat java.base@21/java.lang.Object.wait(Native Method)",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  -- Multi-client prompt selects #30; then cancel() sends $/cancelRequest and discards late response
  stub_select(function(items)
    for _, item in ipairs(items) do
      if item:find("#30", 1, true) then
        return item
      end
    end
  end)
  st.stacktrace()
  assert(#select_calls == 1, "multiple attached clients must prompt explicitly")
  assert(st._pending() ~= nil, "expected pending listSourcePaths request")
  local req_id_cancel = st._pending().request_id
  assert(st.cancel() == true, "cancel() should return true when request is pending")
  assert(deferred_client._cancelled[1] == req_id_cancel, "cancel() must send $/cancelRequest")
  deferred_client:deliver(req_id_cancel, nil, {
    data = { { path = mm_root .. "/api/src/main/java", projectName = "api" } },
  })
  flush_schedule()
  assert(#deferred_client._sent == 1, "late callback after cancel must not issue resolveStackTraceLocation")

  -- Regression (1): Re-invoking on Native / Unknown / Non-frame after moving cursor cancels prior op BEFORE return
  vim.lsp.get_clients = function()
    return { deferred_client }
  end
  local invalid_lines = {
    { kind = "native", text = "\tat java.base@21/java.lang.Object.wait(Native Method)", notice = "native method" },
    { kind = "unknown", text = "\tat com.acme.Proxy.$do(Unknown Source)", notice = "unknown source" },
    { kind = "nonframe", text = "Caused by: java.lang.RuntimeException: boom", notice = "no Java stack trace frame" },
  }
  for _, tc in ipairs(invalid_lines) do
    vim.api.nvim_buf_set_lines(svc_buf, 0, 2, false, {
      "// at com.mm.api.ApiEntry.go(ApiEntry.java:3)",
      tc.text,
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    st.stacktrace()
    assert(st._pending() ~= nil, "expected pending request before " .. tc.kind .. " re-invocation")
    local prior_req = st._pending().request_id
    local sent_count = #deferred_client._sent
    local cancel_count = #deferred_client._cancelled

    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- cursor changed to invalid/native/unknown line
    reset_notices()
    st.stacktrace()
    assert(has_notice(tc.notice), "expected notice for " .. tc.kind)
    assert(st._pending() == nil, tc.kind .. " invocation must clear prior pending request before returning")
    assert(
      #deferred_client._cancelled == cancel_count + 1
        and deferred_client._cancelled[#deferred_client._cancelled] == prior_req,
      tc.kind .. " invocation must send $/cancelRequest for prior operation"
    )
    reset_notices()
    deferred_client:deliver(prior_req, nil, {
      data = { { path = mm_root .. "/api/src/main/java", projectName = "api" } },
    })
    flush_schedule()
    assert(#deferred_client._sent == sent_count, "late callback after " .. tc.kind .. " cancel must not proceed")
    assert(#notices == 0, "late callback after " .. tc.kind .. " cancel emitted unexpected notice")
  end

  -- Stale picker protection (client picker & disk candidate picker) when superseded by native/unknown/new op
  vim.api.nvim_buf_set_lines(svc_buf, 0, 2, false, {
    "// at com.mm.dup.Same.origin(Same.java:4)",
    "\tat java.base@21/java.lang.Object.wait(Native Method)",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.lsp.get_clients = function(filter)
    if filter and filter.bufnr then
      return { deferred_client, second_client }
    end
    return { deferred_client, second_client }
  end
  local captured_pickers = defer_select()
  st.stacktrace()
  assert(#captured_pickers == 1, "expected deferred client picker")
  local stale_client_picker = captured_pickers[1]
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  reset_notices()
  st.stacktrace() -- native invocation invalidates stale_client_picker!
  assert(has_notice("native method"))
  local sent_before_stale_pick = #deferred_client._sent
  reset_notices()
  stale_client_picker.choose(stale_client_picker.items[1])
  flush_schedule()
  assert(#deferred_client._sent == sent_before_stale_pick, "stale client picker must not dispatch LSP request")
  assert(#notices == 0, "stale client picker must not emit notices")

  -- Stale disk-candidate picker after changedtick & after cancel()
  vim.lsp.get_clients = function()
    return { deferred_client }
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  captured_pickers = defer_select()
  st.stacktrace()
  local req_list_dup = st._pending().request_id
  deferred_client:deliver(req_list_dup, nil, {
    data = {
      { path = mm_root .. "/dup-a/src/main/java", projectName = "dup-a" },
      { path = mm_root .. "/dup-b/src/main/java", projectName = "dup-b" },
    },
  })
  flush_schedule()
  assert(#captured_pickers == 1, "expected deferred disk-candidate picker")
  local stale_cand_picker = captured_pickers[1]
  local sent_before_cand_pick = #deferred_client._sent
  assert(st.cancel() == false or st._pending() == nil) -- cancel active picker op
  -- Also test with changedtick on a fresh disk-candidate picker
  captured_pickers = defer_select()
  st.stacktrace()
  local req_list_dup2 = st._pending().request_id
  deferred_client:deliver(req_list_dup2, nil, {
    data = {
      { path = mm_root .. "/dup-a/src/main/java", projectName = "dup-a" },
      { path = mm_root .. "/dup-b/src/main/java", projectName = "dup-b" },
    },
  })
  flush_schedule()
  assert(#captured_pickers == 1, "expected second deferred disk-candidate picker")
  local tick_cand_picker = captured_pickers[1]
  -- Stale first picker fired while second is active must do nothing
  stale_cand_picker.choose(stale_cand_picker.items[1])
  assert(#deferred_client._sent == sent_before_cand_pick + 1, "stale candidate picker fired unexpectedly")
  -- Modify buffer before choosing from tick_cand_picker -> changedtick guard must abort
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// edited while candidate picker open" })
  reset_notices()
  tick_cand_picker.choose(tick_cand_picker.items[1])
  assert(has_notice("buffer changed"), "expected changedtick notice on candidate picker")
  assert(#deferred_client._sent == sent_before_cand_pick + 1, "changedtick-invalidated picker sent LSP request")

  -- changedtick guard: editing buffer while request is in flight discards result
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// at com.mm.api.ApiEntry.go(ApiEntry.java:3)" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local sent_before_tick = #deferred_client._sent
  st.stacktrace()
  local req_tick = st._pending().request_id
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// edited!" })
  reset_notices()
  deferred_client:deliver(req_tick, nil, {
    data = { { path = mm_root .. "/api/src/main/java", projectName = "api" } },
  })
  flush_schedule()
  assert(has_notice("buffer changed"), "expected changedtick guard warning")
  assert(#deferred_client._sent == sent_before_tick + 1, "stale callback after changedtick must not proceed")

  -- Window switch guard
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// at com.mm.api.ApiEntry.go(ApiEntry.java:3)" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local sent_before_win = #deferred_client._sent
  st.stacktrace()
  local req_win = st._pending().request_id
  local orig_win = vim.api.nvim_get_current_win()
  vim.cmd("split")
  local other_win = vim.api.nvim_get_current_win()
  assert(other_win ~= orig_win)
  reset_notices()
  deferred_client:deliver(req_win, nil, {
    data = { { path = mm_root .. "/api/src/main/java", projectName = "api" } },
  })
  flush_schedule()
  assert(has_notice("window or buffer changed"), "expected window guard warning")
  assert(#deferred_client._sent == sent_before_win + 1, "stale callback after window switch must not proceed")
  vim.api.nvim_win_close(other_win, true)

  -- Stale java/classFileContents callback after cancel()
  local jdt_ext_uri_cancel =
    "jdt://contents/extlib.jar/com.ext/ExtCancel.class?=service/%5C/extlib.jar%3Ccom.ext(ExtCancel.class"
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// at com.ext.ExtCancel.boom(ExtCancel.java:12)" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  st.stacktrace()
  local req_ext_list = st._pending().request_id
  deferred_client:deliver(req_ext_list, nil, {
    data = { { path = mm_root .. "/service/src/main/java", projectName = "service" } },
  })
  flush_schedule()
  local req_ext_res = st._pending().request_id
  deferred_client:deliver(req_ext_res, nil, jdt_ext_uri_cancel)
  flush_schedule()
  assert(st._pending() ~= nil, "expected pending java/classFileContents request")
  local req_ext_cfc = st._pending().request_id
  assert(st.cancel() == true, "cancel() should cancel pending java/classFileContents")
  reset_notices()
  deferred_client:deliver(req_ext_cfc, nil, jdt_ext_src)
  flush_schedule()
  assert(canonical(vim.api.nvim_buf_get_name(0)) == canonical(svc_file), "stale classFileContents must not navigate")
  assert(vim.fn.bufnr(jdt_ext_uri_cancel) == -1, "stale cancelled classFileContents must not create jdt:// buffer")
  assert(#notices == 0, "stale cancelled classFileContents emitted unexpected notice")

  -- A client whose project root changes during classFileContents must not
  -- populate or open a virtual buffer using stale provenance.
  local changed_root_uri = "jdt://contents/extlib.jar/com.ext/RootChanged.class?=service/RootChanged.class"
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// at com.ext.RootChanged.boom(RootChanged.java:12)" })
  st.stacktrace()
  local root_list = st._pending().request_id
  deferred_client:deliver(root_list, nil, {
    data = { { path = mm_root .. "/service/src/main/java", projectName = "service" } },
  })
  flush_schedule()
  local root_resolve = st._pending().request_id
  deferred_client:deliver(root_resolve, nil, changed_root_uri)
  flush_schedule()
  local root_contents = st._pending().request_id
  local saved_root = deferred_client.root_dir
  deferred_client.root_dir = "/unrelated-project"
  reset_notices()
  deferred_client:deliver(root_contents, nil, jdt_ext_src)
  flush_schedule()
  deferred_client.root_dir = saved_root
  assert(vim.fn.bufnr(changed_root_uri) == -1, "changed client root must not populate jdt:// buffer")
  assert(has_notice("no longer matches"), "expected warning for changed client root")

  local stopped_uri = "jdt://contents/extlib.jar/com.ext/Stopped.class?=service/Stopped.class"
  vim.api.nvim_buf_set_lines(svc_buf, 0, 1, false, { "// at com.ext.Stopped.boom(Stopped.java:12)" })
  st.stacktrace()
  local stopped_list = st._pending().request_id
  deferred_client:deliver(stopped_list, nil, {
    data = { { path = mm_root .. "/service/src/main/java", projectName = "service" } },
  })
  flush_schedule()
  deferred_client:deliver(st._pending().request_id, nil, stopped_uri)
  flush_schedule()
  local stopped_contents = st._pending().request_id
  deferred_client._stopped = true
  reset_notices()
  deferred_client:deliver(stopped_contents, nil, jdt_ext_src)
  flush_schedule()
  deferred_client._stopped = false
  assert(vim.fn.bufnr(stopped_uri) == -1, "stopped client must not populate jdt:// buffer")
  assert(has_notice("no longer available"), "expected warning for stopped client")

  -- Unsupported capability refusal
  local no_cap_client = make_mock_client({
    id = 40,
    root_dir = mm_root,
    server_capabilities = { executeCommandProvider = { commands = { "java.project.listSourcePaths" } } },
  })
  vim.lsp.get_clients = function()
    return { no_cap_client }
  end
  reset_notices()
  st.stacktrace()
  assert(has_notice("does not support java.project.resolveStackTraceLocation"), "expected unsupported command notice")

  print("[stacktrace_spec] OK")
end

local ok, err = xpcall(run_tests, debug.traceback)
cleanup()
if not ok then
  error(err, 0)
end
