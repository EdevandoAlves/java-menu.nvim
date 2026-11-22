-- Integration (Issue #13): real JDTLS Type Hierarchy responses against isolated
-- Java Maven projects.
--
-- Inspired by tests/java_menu/fixtures.lua and tests/java_menu/call_hierarchy_real_spec.lua.
-- Note: no Type Hierarchy UI/menu module exists yet under lua/java_menu/, so this
-- spec tests the raw JDTLS Type Hierarchy LSP protocol via java_menu.lsp + Neovim
-- LSP APIs without claiming UI/menu coverage:
--   1. Real JDTLS attachment + server capability `typeHierarchyProvider`.
--   2. `textDocument/prepareTypeHierarchy` on interface declaration, class
--      declaration, type reference/usage site, and non-type position.
--   3. `typeHierarchy/subtypes` (interface -> direct implementations, abstract
--      class -> concrete subclass, multi-hop subclass chain, leaf class).
--   4. `typeHierarchy/supertypes` (subclass -> superclass, class -> superclass +
--      implemented interfaces, root class -> interface + JDK `java.lang.Object`).
--   5. Exact LSP `uri`, `range`, `selectionRange` locations on disk plus `jdt://`
--      JDK supertype behavior (`java/classFileContents`, non-readable path).
--   6. Separate Maven projects (A and B) with colliding type names (`Greeter`,
--      `FormalGreeter`) and distinct JDTLS clients/workspaces, asserting zero
--      cross-project leakage.
--
-- Run:
--   nvim --headless -u NONE -n \
--     -c "set rtp+=." \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-jdtls" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/nvim-lspconfig" \
--     -c "set rtp+=$HOME/.local/share/nvim/lazy/jc.nvim" \
--     -c "lua local ok, err = pcall(dofile, 'tests/java_menu/type_hierarchy_real_spec.lua'); if not ok then io.stderr:write(tostring(err)..'\n'); vim.cmd('cquit 1') end" \
--     -c "qa!"

local SPEC_NAME = "type_hierarchy_real_spec"

local lsp = require("java_menu.lsp")
local fixtures = require("tests.java_menu.fixtures")

local SYMBOL_KIND = vim.lsp.protocol.SymbolKind

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

local function write_java_unit(root, pkg, name, lines)
  local rel_pkg = pkg:gsub("%.", "/")
  local path = root .. "/src/main/java/" .. rel_pkg .. "/" .. name .. ".java"
  fixtures.write(path, lines)
  return path
end

local function wait_for_type_indexed(client, bufnr, line, col, label)
  local items, last_err
  local indexed = vim.wait(60000, function()
    local err, res = lsp_request_sync(
      client,
      "textDocument/prepareTypeHierarchy",
      position_params(bufnr, client, line, col),
      bufnr,
      10000
    )
    last_err = err
    if err == nil and type(res) == "table" and #res > 0 then
      items = res
      return true
    end
    return false
  end, 300)
  assert(
    indexed,
    string.format(
      "JDTLS did not index %s for prepareTypeHierarchy within 60s; last err=%s",
      label,
      vim.inspect(last_err)
    )
  )
  return items
end

local function find_type_item(items, expected_name, expected_uri)
  assert(type(items) == "table", "expected TypeHierarchyItem list, got " .. vim.inspect(items))
  for _, item in ipairs(items) do
    if item.name == expected_name and (not expected_uri or item.uri == expected_uri) then
      return item
    end
  end
  return nil
end

local function assert_type_location(item, file_path, expected_name, expected_kind, expected_pkg)
  assert(item, "missing TypeHierarchyItem for " .. expected_name)
  assert(item.name == expected_name, string.format("expected name '%s', got '%s'", expected_name, tostring(item.name)))
  assert(
    item.kind == expected_kind,
    string.format("expected SymbolKind %d for %s, got %s", expected_kind, expected_name, tostring(item.kind))
  )
  if expected_pkg then
    assert(
      item.detail == expected_pkg,
      string.format("expected detail '%s' for %s, got '%s'", expected_pkg, expected_name, tostring(item.detail))
    )
  end
  local expected_uri = vim.uri_from_fname(file_path)
  assert(
    item.uri == expected_uri,
    string.format("URI mismatch for %s: expected %s, got %s", expected_name, expected_uri, tostring(item.uri))
  )
  assert(item.range and item.range.start and item.range["end"], "TypeHierarchyItem missing range for " .. expected_name)
  assert(
    item.selectionRange and item.selectionRange.start and item.selectionRange["end"],
    "TypeHierarchyItem missing selectionRange for " .. expected_name
  )
  local decl_line = find_token_pos(file_path, expected_name, expected_name)
  assert(
    item.selectionRange.start.line == decl_line,
    string.format(
      "selectionRange line mismatch for %s: expected %d, got %d",
      expected_name,
      decl_line,
      item.selectionRange.start.line
    )
  )
  local sliced = slice_range(file_path, item.selectionRange)
  assert(
    sliced == expected_name,
    string.format("selectionRange did not slice to '%s': got '%s'", expected_name, sliced)
  )
end

local function run_tests()
  local summary = {
    mvn_offline = "not-run",
    jdt_uri_samples = {},
  }

  -- 1. Build isolated Maven Project A with interface, implementations, abstract
  --    superclass, multi-hop subclass chain, and a caller referencing them.
  local pkg_a = "com.demo.typehier"
  local root_a, _ = fixtures.maven_project("typehier-a", pkg_a, "Greeter")
  register_dir(root_a)
  local data_a = register_dir(root_a .. "-data")

  local greeter_a = write_java_unit(root_a, pkg_a, "Greeter", {
    "package " .. pkg_a .. ";",
    "",
    "public interface Greeter {",
    "  String greet(String name);",
    "}",
  })

  local auditable_a = write_java_unit(root_a, pkg_a, "Auditable", {
    "package " .. pkg_a .. ";",
    "",
    "public interface Auditable {",
    "  String auditTag();",
    "}",
  })

  local abstract_a = write_java_unit(root_a, pkg_a, "AbstractGreeter", {
    "package " .. pkg_a .. ";",
    "",
    "public abstract class AbstractGreeter implements Greeter {",
    "  protected String prefix() {",
    '    return "Hello";',
    "  }",
    "}",
  })

  local formal_a = write_java_unit(root_a, pkg_a, "FormalGreeter", {
    "package " .. pkg_a .. ";",
    "",
    "public class FormalGreeter extends AbstractGreeter implements Auditable {",
    "  @Override",
    "  public String greet(String name) {",
    '    return prefix() + ", " + name;',
    "  }",
    "",
    "  @Override",
    "  public String auditTag() {",
    '    return "formal";',
    "  }",
    "}",
  })

  local vip_a = write_java_unit(root_a, pkg_a, "VipFormalGreeter", {
    "package " .. pkg_a .. ";",
    "",
    "public class VipFormalGreeter extends FormalGreeter {",
    "  @Override",
    "  public String greet(String name) {",
    '    return super.greet("VIP " + name);',
    "  }",
    "}",
  })

  local casual_a = write_java_unit(root_a, pkg_a, "CasualGreeter", {
    "package " .. pkg_a .. ";",
    "",
    "public class CasualGreeter implements Greeter {",
    "  @Override",
    "  public String greet(String name) {",
    '    return "Hey " + name;',
    "  }",
    "}",
  })

  local runner_a = write_java_unit(root_a, pkg_a, "Runner", {
    "package " .. pkg_a .. ";",
    "",
    "public class Runner {",
    "  public String run(String name) {",
    "    Greeter g = new VipFormalGreeter();",
    "    return g.greet(name);",
    "  }",
    "}",
  })

  -- Optional offline Maven verification (zero external deps).
  if vim.fn.executable("mvn") == 1 then
    local mvn_out = vim.fn.system({ "mvn", "-o", "-q", "-B", "-f", root_a .. "/pom.xml", "compile" })
    if vim.v.shell_error == 0 then
      summary.mvn_offline = "ok"
      assert(
        vim.fn.filereadable(root_a .. "/target/classes/com/demo/typehier/VipFormalGreeter.class") == 1,
        "mvn -o compile succeeded but VipFormalGreeter.class missing"
      )
    else
      summary.mvn_offline = "unavailable_or_uncached: " .. vim.trim(mvn_out):gsub("\n", " | ")
    end
  else
    summary.mvn_offline = "mvn_absent"
  end

  -- 2. Attach real JDTLS client to Project A.
  local buf_greeter_a = open_java(greeter_a)
  jdtls.start_or_attach({
    cmd = { jdtls_bin, "-data", data_a },
    root_dir = root_a,
    capabilities = lsp.capabilities(),
  })

  local attached_a = fixtures.wait_for(60000, function()
    return lsp.client(buf_greeter_a) ~= nil
  end)
  assert(attached_a, "JDTLS A failed to attach within 60s")
  local client_a = lsp.client(buf_greeter_a)
  assert(client_a and client_a.root_dir == root_a, "JDTLS A attached with unexpected root_dir")
  started_clients[#started_clients + 1] = client_a

  assert(
    client_a.server_capabilities and client_a.server_capabilities.typeHierarchyProvider,
    "JDTLS A did not advertise typeHierarchyProvider capability"
  )

  -- Open remaining Project A files and attach them to client_a.
  local buf_abstract_a = open_java(abstract_a)
  local buf_formal_a = open_java(formal_a)
  local buf_vip_a = open_java(vip_a)
  local buf_casual_a = open_java(casual_a)
  local buf_auditable_a = open_java(auditable_a)
  local buf_runner_a = open_java(runner_a)
  for _, b in ipairs({
    buf_abstract_a,
    buf_formal_a,
    buf_vip_a,
    buf_casual_a,
    buf_auditable_a,
    buf_runner_a,
  }) do
    assert(vim.lsp.buf_attach_client(b, client_a.id), "failed to attach buffer to client_a")
  end
  assert(
    fixtures.wait_for(30000, function()
      return lsp.client(buf_runner_a) == client_a and lsp.client(buf_vip_a) == client_a
    end),
    "Project A buffers did not attach to client_a"
  )

  -- 3. Verify `textDocument/prepareTypeHierarchy` on interface declaration,
  --    class declaration, type reference site, and non-type position.
  local greeter_line, greeter_col = find_token_pos(greeter_a, "public interface Greeter", "Greeter")
  local greeter_items = wait_for_type_indexed(client_a, buf_greeter_a, greeter_line, greeter_col, "Greeter")
  assert(#greeter_items == 1, "expected 1 TypeHierarchyItem for Greeter, got " .. #greeter_items)
  local greeter_item = greeter_items[1]
  assert_type_location(greeter_item, greeter_a, "Greeter", SYMBOL_KIND.Interface, pkg_a)

  -- Prepare from class declaration (VipFormalGreeter).
  local vip_line, vip_col = find_token_pos(vip_a, "public class VipFormalGreeter", "VipFormalGreeter")
  local vip_items = wait_for_type_indexed(client_a, buf_vip_a, vip_line, vip_col, "VipFormalGreeter")
  assert(#vip_items == 1, "expected 1 TypeHierarchyItem for VipFormalGreeter, got " .. #vip_items)
  local vip_item = vip_items[1]
  assert_type_location(vip_item, vip_a, "VipFormalGreeter", SYMBOL_KIND.Class, pkg_a)

  -- Prepare from usage/reference site in Runner.java (`Greeter g = new VipFormalGreeter();`).
  local ref_greeter_line, ref_greeter_col = find_token_pos(runner_a, "Greeter g = new VipFormalGreeter", "Greeter")
  local ref_err, ref_res = lsp_request_sync(
    client_a,
    "textDocument/prepareTypeHierarchy",
    position_params(buf_runner_a, client_a, ref_greeter_line, ref_greeter_col),
    buf_runner_a
  )
  assert(ref_err == nil, "prepareTypeHierarchy from type reference failed: " .. vim.inspect(ref_err))
  assert(type(ref_res) == "table" and #ref_res == 1, "expected 1 item from Greeter reference")
  assert_type_location(ref_res[1], greeter_a, "Greeter", SYMBOL_KIND.Interface, pkg_a)

  local ref_vip_line, ref_vip_col = find_token_pos(runner_a, "new VipFormalGreeter()", "VipFormalGreeter")
  local ref_vip_err, ref_vip_res = lsp_request_sync(
    client_a,
    "textDocument/prepareTypeHierarchy",
    position_params(buf_runner_a, client_a, ref_vip_line, ref_vip_col),
    buf_runner_a
  )
  assert(
    ref_vip_err == nil,
    "prepareTypeHierarchy from constructor type reference failed: " .. vim.inspect(ref_vip_err)
  )
  assert(type(ref_vip_res) == "table" and #ref_vip_res == 1, "expected 1 item from VipFormalGreeter reference")
  assert_type_location(ref_vip_res[1], vip_a, "VipFormalGreeter", SYMBOL_KIND.Class, pkg_a)

  -- Non-type position (package keyword on line 0): JDTLS falls back to the
  -- compilation unit's primary type (`Greeter`) without an LSP error.
  local pkg_err, pkg_res = lsp_request_sync(
    client_a,
    "textDocument/prepareTypeHierarchy",
    position_params(buf_greeter_a, client_a, 0, 2),
    buf_greeter_a
  )
  assert(pkg_err == nil, "prepareTypeHierarchy on package line returned error: " .. vim.inspect(pkg_err))
  assert(
    type(pkg_res) == "table" and #pkg_res == 1,
    "expected primary type fallback on package line, got " .. vim.inspect(pkg_res)
  )
  assert_type_location(pkg_res[1], greeter_a, "Greeter", SYMBOL_KIND.Interface, pkg_a)

  -- 4. Verify `typeHierarchy/subtypes` (interface -> implementations & multi-hop subclasses).
  local sub_greeter_err, sub_greeter =
    lsp_request_sync(client_a, "typeHierarchy/subtypes", { item = greeter_item }, buf_greeter_a)
  assert(sub_greeter_err == nil, "subtypes(Greeter) failed: " .. vim.inspect(sub_greeter_err))
  assert(
    type(sub_greeter) == "table" and #sub_greeter == 2,
    "expected 2 direct subtypes for Greeter (AbstractGreeter, CasualGreeter), got " .. vim.inspect(sub_greeter)
  )

  local abstract_item = find_type_item(sub_greeter, "AbstractGreeter", vim.uri_from_fname(abstract_a))
  local casual_item = find_type_item(sub_greeter, "CasualGreeter", vim.uri_from_fname(casual_a))
  assert_type_location(abstract_item, abstract_a, "AbstractGreeter", SYMBOL_KIND.Class, pkg_a)
  assert_type_location(casual_item, casual_a, "CasualGreeter", SYMBOL_KIND.Class, pkg_a)

  -- Hop 2: AbstractGreeter -> FormalGreeter
  local sub_abs_err, sub_abs =
    lsp_request_sync(client_a, "typeHierarchy/subtypes", { item = abstract_item }, buf_abstract_a)
  assert(sub_abs_err == nil, "subtypes(AbstractGreeter) failed: " .. vim.inspect(sub_abs_err))
  assert(
    type(sub_abs) == "table" and #sub_abs == 1,
    "expected 1 direct subtype for AbstractGreeter, got " .. vim.inspect(sub_abs)
  )
  local formal_item = find_type_item(sub_abs, "FormalGreeter", vim.uri_from_fname(formal_a))
  assert_type_location(formal_item, formal_a, "FormalGreeter", SYMBOL_KIND.Class, pkg_a)

  -- Hop 3: FormalGreeter -> VipFormalGreeter
  local sub_formal_err, sub_formal =
    lsp_request_sync(client_a, "typeHierarchy/subtypes", { item = formal_item }, buf_formal_a)
  assert(sub_formal_err == nil, "subtypes(FormalGreeter) failed: " .. vim.inspect(sub_formal_err))
  assert(
    type(sub_formal) == "table" and #sub_formal == 1,
    "expected 1 direct subtype for FormalGreeter, got " .. vim.inspect(sub_formal)
  )
  local vip_from_sub = find_type_item(sub_formal, "VipFormalGreeter", vim.uri_from_fname(vip_a))
  assert_type_location(vip_from_sub, vip_a, "VipFormalGreeter", SYMBOL_KIND.Class, pkg_a)

  -- Leaf class subtypes: empty/nil without error.
  local sub_vip_err, sub_vip = lsp_request_sync(client_a, "typeHierarchy/subtypes", { item = vip_item }, buf_vip_a)
  assert(sub_vip_err == nil, "subtypes(VipFormalGreeter) failed: " .. vim.inspect(sub_vip_err))
  assert(
    sub_vip == nil or sub_vip == vim.NIL or (type(sub_vip) == "table" and #sub_vip == 0),
    "expected 0 subtypes for leaf VipFormalGreeter, got " .. vim.inspect(sub_vip)
  )

  -- 5. Verify `typeHierarchy/supertypes` (subclass -> superclass, interfaces, and JDK Object).
  local sup_vip_err, sup_vip = lsp_request_sync(client_a, "typeHierarchy/supertypes", { item = vip_item }, buf_vip_a)
  assert(sup_vip_err == nil, "supertypes(VipFormalGreeter) failed: " .. vim.inspect(sup_vip_err))
  assert(
    type(sup_vip) == "table" and #sup_vip == 1,
    "expected 1 direct supertype for VipFormalGreeter (FormalGreeter), got " .. vim.inspect(sup_vip)
  )
  local formal_from_sup = find_type_item(sup_vip, "FormalGreeter", vim.uri_from_fname(formal_a))
  assert_type_location(formal_from_sup, formal_a, "FormalGreeter", SYMBOL_KIND.Class, pkg_a)

  -- FormalGreeter supertypes: AbstractGreeter (extends) + Auditable (implements).
  local sup_formal_err, sup_formal =
    lsp_request_sync(client_a, "typeHierarchy/supertypes", { item = formal_from_sup }, buf_formal_a)
  assert(sup_formal_err == nil, "supertypes(FormalGreeter) failed: " .. vim.inspect(sup_formal_err))
  assert(
    type(sup_formal) == "table" and #sup_formal == 2,
    "expected 2 direct supertypes for FormalGreeter (AbstractGreeter, Auditable), got " .. vim.inspect(sup_formal)
  )
  local abs_from_sup = find_type_item(sup_formal, "AbstractGreeter", vim.uri_from_fname(abstract_a))
  local audit_from_sup = find_type_item(sup_formal, "Auditable", vim.uri_from_fname(auditable_a))
  assert_type_location(abs_from_sup, abstract_a, "AbstractGreeter", SYMBOL_KIND.Class, pkg_a)
  assert_type_location(audit_from_sup, auditable_a, "Auditable", SYMBOL_KIND.Interface, pkg_a)

  -- AbstractGreeter supertypes: Greeter (implements) + java.lang.Object (`jdt://`).
  local sup_abs_err, sup_abs =
    lsp_request_sync(client_a, "typeHierarchy/supertypes", { item = abs_from_sup }, buf_abstract_a)
  assert(sup_abs_err == nil, "supertypes(AbstractGreeter) failed: " .. vim.inspect(sup_abs_err))
  assert(
    type(sup_abs) == "table" and #sup_abs == 2,
    "expected 2 direct supertypes for AbstractGreeter (Greeter, Object), got " .. vim.inspect(sup_abs)
  )
  local greeter_from_sup = find_type_item(sup_abs, "Greeter", vim.uri_from_fname(greeter_a))
  assert_type_location(greeter_from_sup, greeter_a, "Greeter", SYMBOL_KIND.Interface, pkg_a)

  local object_item = find_type_item(sup_abs, "Object")
  assert(object_item, "missing java.lang.Object supertype for AbstractGreeter")
  assert(object_item.kind == SYMBOL_KIND.Class, "expected Object kind == Class")
  assert(
    object_item.detail == "java.lang",
    "expected Object detail == 'java.lang', got " .. tostring(object_item.detail)
  )
  assert(
    vim.startswith(object_item.uri, "jdt://"),
    "expected java.lang.Object supertype to use jdt:// URI, got " .. tostring(object_item.uri)
  )
  summary.jdt_uri_samples[#summary.jdt_uri_samples + 1] = object_item.uri
  assert(
    vim.fn.filereadable(vim.uri_to_fname(object_item.uri)) == 0,
    "jdt:// Object URI unexpectedly resolved to a readable local file"
  )

  local cfc_err, cfc_res =
    lsp_request_sync(client_a, "java/classFileContents", { uri = object_item.uri }, buf_abstract_a)
  assert(
    cfc_err == nil and type(cfc_res) == "string" and cfc_res:find("class Object", 1, true),
    "java/classFileContents failed on jdt:// Object URI: " .. vim.inspect(cfc_err)
  )

  -- 6. Separate Maven Project B with colliding type names (`Greeter`, `FormalGreeter`)
  --    in an isolated workspace/client, verifying zero cross-project leakage.
  local pkg_b = "com.other.typehier"
  local root_b, _ = fixtures.maven_project("typehier-b", pkg_b, "Greeter")
  register_dir(root_b)
  local data_b = register_dir(root_b .. "-data")

  local greeter_b = write_java_unit(root_b, pkg_b, "Greeter", {
    "package " .. pkg_b .. ";",
    "",
    "public interface Greeter {",
    "  int code();",
    "}",
  })

  local formal_b = write_java_unit(root_b, pkg_b, "FormalGreeter", {
    "package " .. pkg_b .. ";",
    "",
    "public class FormalGreeter implements Greeter {",
    "  @Override",
    "  public int code() {",
    "    return 42;",
    "  }",
    "}",
  })

  local buf_greeter_b = open_java(greeter_b)
  local buf_formal_b = open_java(formal_b)

  vim.api.nvim_set_current_buf(buf_greeter_b)
  jdtls.start_or_attach({
    cmd = { jdtls_bin, "-data", data_b },
    root_dir = root_b,
    capabilities = lsp.capabilities(),
  })

  local attached_b = fixtures.wait_for(60000, function()
    local c = lsp.client(buf_greeter_b)
    return c ~= nil and c.root_dir == root_b
  end)
  assert(attached_b, "JDTLS B failed to attach to Project B")
  local client_b = lsp.client(buf_greeter_b)
  assert(client_b and client_b.id ~= client_a.id, "Project B reused Project A's JDTLS client")
  started_clients[#started_clients + 1] = client_b
  assert(vim.lsp.buf_attach_client(buf_formal_b, client_b.id), "failed to attach Project B FormalGreeter buffer")
  assert(
    fixtures.wait_for(30000, function()
      return lsp.client(buf_formal_b) == client_b
    end),
    "Project B FormalGreeter buffer did not attach to client_b"
  )
  assert(lsp.global_count() >= 2, "expected at least 2 active JDTLS clients")
  assert(lsp.client(buf_greeter_a) == client_a, "Project A buffer lost client_a after Project B attached")

  local greeter_b_line, greeter_b_col = find_token_pos(greeter_b, "public interface Greeter", "Greeter")
  local greeter_b_items =
    wait_for_type_indexed(client_b, buf_greeter_b, greeter_b_line, greeter_b_col, "Project B Greeter")
  assert(#greeter_b_items == 1, "expected 1 TypeHierarchyItem for Project B Greeter")
  assert_type_location(greeter_b_items[1], greeter_b, "Greeter", SYMBOL_KIND.Interface, pkg_b)

  local sub_b_err, sub_b =
    lsp_request_sync(client_b, "typeHierarchy/subtypes", { item = greeter_b_items[1] }, buf_greeter_b)
  assert(sub_b_err == nil, "subtypes(Project B Greeter) failed: " .. vim.inspect(sub_b_err))
  assert(type(sub_b) == "table" and #sub_b == 1, "expected 1 subtype for Project B Greeter, got " .. vim.inspect(sub_b))
  assert_type_location(sub_b[1], formal_b, "FormalGreeter", SYMBOL_KIND.Class, pkg_b)
  assert(not sub_b[1].uri:find(root_a, 1, true), "Project B type hierarchy leaked Project A path")

  local sup_b_err, sup_b = lsp_request_sync(client_b, "typeHierarchy/supertypes", { item = sub_b[1] }, buf_formal_b)
  assert(sup_b_err == nil, "supertypes(Project B FormalGreeter) failed: " .. vim.inspect(sup_b_err))
  local greeter_b_sup = find_type_item(sup_b, "Greeter", vim.uri_from_fname(greeter_b))
  assert_type_location(greeter_b_sup, greeter_b, "Greeter", SYMBOL_KIND.Interface, pkg_b)
  for _, item in ipairs(sup_b or {}) do
    assert(not item.uri:find(root_a, 1, true), "Project B supertype leaked Project A path: " .. tostring(item.uri))
  end

  -- Re-check Project A via client_a while client_b is running: must return Project A types only.
  local sub_a_again_err, sub_a_again =
    lsp_request_sync(client_a, "typeHierarchy/subtypes", { item = greeter_item }, buf_greeter_a)
  assert(sub_a_again_err == nil and type(sub_a_again) == "table" and #sub_a_again == 2)
  for _, item in ipairs(sub_a_again) do
    assert(not item.uri:find(root_b, 1, true), "Project A type hierarchy leaked Project B path: " .. tostring(item.uri))
  end

  -- Exercise the plugin's picker and navigation using the real server.
  local ui = require("java_menu.ui")
  local types = require("java_menu.types")
  local original_pick = ui.pick_one
  local chosen
  local function select_result(fragment)
    chosen = nil
    ui.pick_one = function(items, _, callback)
      for _, label in ipairs(items) do
        if label:find(fragment, 1, true) then
          chosen = label
          callback(label)
          return
        end
      end
      error("expected type entry containing " .. fragment .. ": " .. vim.inspect(items))
    end
  end
  local ui_ok, ui_err = xpcall(function()
    vim.api.nvim_set_current_buf(buf_greeter_a)
    vim.api.nvim_win_set_cursor(0, { greeter_line + 1, greeter_col })
    select_result("AbstractGreeter.java")
    types.subtypes()
    assert(
      vim.wait(15000, function()
        return chosen ~= nil and vim.api.nvim_get_current_buf() == buf_abstract_a
      end, 50),
      "subtypes menu did not navigate to AbstractGreeter"
    )
    local abstract_line = find_token_pos(abstract_a, "public abstract class AbstractGreeter", "AbstractGreeter")
    assert(vim.api.nvim_win_get_cursor(0)[1] == abstract_line + 1, "subtypes menu selected wrong line")

    select_result("Greeter.java")
    types.supertypes()
    assert(
      vim.wait(15000, function()
        return chosen ~= nil and vim.api.nvim_get_current_buf() == buf_greeter_a
      end, 50),
      "supertypes menu did not navigate to Greeter"
    )
    assert(vim.api.nvim_win_get_cursor(0)[1] == greeter_line + 1, "supertypes menu selected wrong line")
  end, debug.traceback)
  ui.pick_one = original_pick
  assert(ui_ok, ui_err)

  print(
    string.format(
      "%s: OK (protocol and menu; mvn_offline=%s; jdt_uris=%d)",
      SPEC_NAME,
      summary.mvn_offline,
      #summary.jdt_uri_samples
    )
  )
end

local ok, err = xpcall(run_tests, debug.traceback)
cleanup()
if not ok then
  error(err, 0)
end
vim.cmd("qa!")
