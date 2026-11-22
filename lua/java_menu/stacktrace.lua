-- java_menu/stacktrace.lua
-- <leader>js: Navigate a Java stack trace line under the cursor to its source
-- file and line using JDTLS (`java.project.resolveStackTraceLocation`),
-- verified source-root scoping, and per-buffer provenance.
--
-- Reuses `java_menu.hierarchy` for operation/cancellation lifecycle,
-- `changedtick`/window/buffer guards, and safe `file://` + canonical `jdt://`
-- navigation. Never sends an empty workspace-wide project list to JDTLS and
-- never guesses a project from cwd or the first open buffer/client.

local ui = require("java_menu.ui")
local lsp = require("java_menu.lsp")
local project = require("java_menu.project")
local hierarchy = require("java_menu.hierarchy")

local M = {}

local COMMANDS = {
  resolve = "java.project.resolveStackTraceLocation",
  list_source_paths = "java.project.listSourcePaths",
}

local SUPPORTED_EXTS = {
  java = true,
  kt = true,
  groovy = true,
  clj = true,
  scala = true,
}

local MAX_AUTO_QUERY_PROJECTS = 12

local ctrl = hierarchy.new_controller({ feature_label = "stack trace" })

local function canonical(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local norm = vim.fs.normalize(path)
  local real = vim.uv.fs_realpath(norm)
  return real and vim.fs.normalize(real) or norm
end

local function subtree(parent, path)
  if type(parent) ~= "string" or parent == "" or type(path) ~= "string" or path == "" then
    return false
  end
  if parent == path then
    return true
  end
  local sep = parent:sub(-1) == "/" and "" or "/"
  return path:sub(1, #parent + #sep) == parent .. sep
end

local function is_disk_file_name(name)
  return type(name) == "string" and name ~= "" and not name:match("^[%a][%w+.-]*://")
end

local function is_nil_res(val)
  return val == nil or val == vim.NIL
end

local function build_module()
  if package.loaded["java_menu.build"] then
    return package.loaded["java_menu.build"]
  end
  local ok, mod = pcall(require, "java_menu.build")
  if ok and type(mod) == "table" then
    return mod
  end
  return nil
end

local function supports_command(client, bufnr, cmd_name)
  if hierarchy.client_stopped(client) then
    return false
  end
  if not hierarchy.supports_method(client, "workspace/executeCommand", bufnr, "executeCommandProvider") then
    return false
  end
  local cap = type(client.server_capabilities) == "table" and client.server_capabilities.executeCommandProvider or nil
  if type(cap) == "table" and type(cap.commands) == "table" then
    for _, c in ipairs(cap.commands) do
      if c == cmd_name then
        return true
      end
    end
    return false
  end
  return true
end

local function live_jdtls_clients()
  local out = {}
  for _, client in ipairs(vim.lsp.get_clients({ name = "jdtls" }) or {}) do
    if not hierarchy.client_stopped(client) then
      out[#out + 1] = client
    end
  end
  table.sort(out, function(a, b)
    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
  end)
  return out
end

local function client_matches_root(client, canon_root)
  if not canon_root or type(client) ~= "table" or type(client.root_dir) ~= "string" or client.root_dir == "" then
    return false
  end
  local croot = canonical(client.root_dir)
  return croot ~= nil and (subtree(croot, canon_root) or subtree(canon_root, croot))
end

local function owning_module(path, root)
  local cpath = canonical(path)
  if not cpath or not root then
    return nil
  end
  local best, best_len = nil, -1
  for _, mod in ipairs(project.modules(root)) do
    local cmod = canonical(mod)
    if cmod and subtree(cmod, cpath) and #cmod > best_len then
      best = cmod
      best_len = #cmod
    end
  end
  return best
end

---Resolve verified provenance for `bufnr` without ever guessing from cwd or
---falling back to another open buffer.
---@param bufnr integer
---@return table
local function resolve_provenance(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return { kind = "invalid", trusted = false, reason = "the target buffer no longer exists" }
  end

  if vim.b[bufnr].java_build_title ~= nil or vim.b[bufnr].java_build_root ~= nil then
    local bmod = build_module()
    local prov = bmod and type(bmod.output_provenance) == "function" and bmod.output_provenance(bufnr) or nil
    if prov and type(prov.root) == "string" and prov.root ~= "" then
      return {
        kind = "build_output",
        trusted = true,
        root = canonical(prov.root),
        module = prov.module and canonical(prov.module) or nil,
        client_id = prov.client_id,
        client_root_dir = prov.client_root_dir and canonical(prov.client_root_dir) or nil,
      }
    end
    return {
      kind = "unverified_output",
      trusted = false,
      reason = "build output buffer has no verified project provenance",
    }
  end

  local jdt_owner = vim.b[bufnr].java_menu_jdt_owner
  local jdt_uri = vim.b[bufnr].java_menu_jdt_uri
  if type(jdt_owner) == "table" and type(jdt_uri) == "string" and jdt_uri ~= "" then
    local rdir = (type(jdt_owner.root_dir) == "string" and jdt_owner.root_dir ~= "") and canonical(jdt_owner.root_dir)
      or nil
    return {
      kind = "jdt",
      trusted = true,
      root = rdir,
      client_id = jdt_owner.client_id,
      client_root_dir = rdir,
    }
  end

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype == "" and is_disk_file_name(bufname) then
    local root = project.root(bufnr)
    if root then
      local croot = canonical(root)
      return {
        kind = "project_file",
        trusted = true,
        root = croot,
        module = owning_module(bufname, croot),
      }
    end
    local attached = lsp.clients(bufnr)
    if #attached > 0 then
      local single_root = nil
      if #attached == 1 and type(attached[1].root_dir) == "string" and attached[1].root_dir ~= "" then
        single_root = canonical(attached[1].root_dir)
      end
      return {
        kind = "attached_file",
        trusted = true,
        root = single_root,
      }
    end
    return {
      kind = "outside_project",
      trusted = false,
      reason = "buffer is not inside a recognized Java project",
    }
  end

  local attached = lsp.clients(bufnr)
  if #attached > 0 then
    local single_root = nil
    if #attached == 1 and type(attached[1].root_dir) == "string" and attached[1].root_dir ~= "" then
      single_root = canonical(attached[1].root_dir)
    end
    return {
      kind = "attached_buf",
      trusted = true,
      root = single_root,
    }
  end

  return {
    kind = "untrusted",
    trusted = false,
    reason = "buffer has no verified project context",
  }
end

local function valid_dotted_class(class_name)
  if type(class_name) ~= "string" or class_name == "" then
    return false
  end
  if class_name:sub(1, 1) == "." or class_name:sub(-1) == "." or class_name:find("..", 1, true) then
    return false
  end
  for seg in class_name:gmatch("[^%.]+") do
    if not seg:match("^[%w%$_]+$") then
      return false
    end
  end
  return true
end

local function valid_method_name(method_name)
  if type(method_name) ~= "string" or method_name == "" then
    return false
  end
  return method_name == "<init>" or method_name == "<clinit>" or method_name:match("^[%w%$_]+$") ~= nil
end

local function parse_module_spec(spec)
  if not spec or spec == "" then
    return nil, nil, true
  end
  local name, ver = spec:match("^([^@]+)@(.+)$")
  if name then
    if not name:match("^[%w%.%$_%-]+$") or not ver:match("^[%w%.%+%-%_]+$") then
      return nil, nil, false
    end
    return name, ver, true
  end
  if not spec:match("^[%w%.%$_%-]+$") then
    return nil, nil, false
  end
  return spec, nil, true
end

---Parse one line of a Java stack trace.
---Supports standard frames, Java 9+ `module/` and `module@version/` and
---`classloader/module@version/` prefixes, inner/anonymous classes (`Outer$Inner`),
---`Native Method`, and `Unknown Source`.
---@param line string|nil
---@return table|nil parsed
local function parse_line(line)
  if type(line) ~= "string" or vim.trim(line) == "" then
    return nil
  end

  for paren_pos, inner in line:gmatch("()%(([^()]+)%)") do
    local loc_kind, file_name, ext, line_number
    if inner == "Native Method" then
      loc_kind = "native"
    elseif inner == "Unknown Source" then
      loc_kind = "unknown"
    else
      local fn, fext, lnum = inner:match("^([%w%-%._$]+%.(%a+)):(%d+)$")
      if fn and SUPPORTED_EXTS[fext] then
        loc_kind = "source"
        file_name = fn
        ext = fext
        line_number = tonumber(lnum)
      else
        local fn_only, ext_only = inner:match("^([%w%-%._$]+%.(%a+))$")
        if fn_only and SUPPORTED_EXTS[ext_only] then
          loc_kind = "source"
          file_name = fn_only
          ext = ext_only
          line_number = nil
        end
      end
    end

    if loc_kind then
      local before = line:sub(1, paren_pos - 1)
      local head = before:match("([^%s]+)$")
      if head then
        local slash_count = 0
        for _ in head:gmatch("/") do
          slash_count = slash_count + 1
        end

        local classloader, mod_spec, qualified_member
        local head_ok = true
        if slash_count == 0 then
          qualified_member = head
        elseif slash_count == 1 then
          mod_spec, qualified_member = head:match("^([^/]+)/([^/]+)$")
          head_ok = mod_spec ~= nil and mod_spec ~= "" and qualified_member ~= nil
        elseif slash_count == 2 then
          classloader, mod_spec, qualified_member = head:match("^([^/]*)/([^/]*)/([^/]+)$")
          head_ok = qualified_member ~= nil
          if head_ok and classloader ~= "" and not classloader:match("^[%w%.%$_%-]+$") then
            head_ok = false
          end
        else
          head_ok = false
        end

        local module_name, module_version
        if head_ok and mod_spec and mod_spec ~= "" then
          local ok_mod
          module_name, module_version, ok_mod = parse_module_spec(mod_spec)
          head_ok = ok_mod
        end

        if head_ok and qualified_member then
          local declaring_class, method_name = qualified_member:match("^(.+)%.([^%.]+)$")
          if valid_dotted_class(declaring_class) and valid_method_name(method_name) then
            local package_name, simple_class = declaring_class:match("^(.+)%.([^%.]+)$")
            if not package_name then
              package_name = ""
              simple_class = declaring_class
            end
            local outer_class = simple_class:match("^([^$]+)") or simple_class
            local is_inner = simple_class:find("$", 1, true) ~= nil
            local source_relpath
            if loc_kind == "source" then
              local pkg_dir = package_name ~= "" and (package_name:gsub("%.", "/")) or ""
              source_relpath = pkg_dir ~= "" and (pkg_dir .. "/" .. file_name) or file_name
            end
            return {
              kind = loc_kind,
              raw = line,
              classloader = (classloader and classloader ~= "") and classloader or nil,
              module_name = module_name,
              module_version = module_version,
              declaring_class = declaring_class,
              package_name = package_name,
              simple_class = simple_class,
              outer_class = outer_class,
              is_inner = is_inner,
              method_name = method_name,
              file_name = file_name,
              ext = ext,
              line_number = line_number,
              source_relpath = source_relpath,
            }
          end
        end
      end
    end
  end

  return nil
end

local function frame_summary(parsed)
  local base = parsed.declaring_class .. "." .. parsed.method_name
  if parsed.file_name then
    local loc = parsed.file_name .. (parsed.line_number and (":" .. tostring(parsed.line_number)) or "")
    return base .. " (" .. loc .. ")"
  end
  return base
end

local function target_range(parsed)
  local row0 = 0
  if type(parsed.line_number) == "number" and parsed.line_number > 0 then
    row0 = parsed.line_number - 1
  end
  return {
    start = { line = row0, character = 0 },
    ["end"] = { line = row0, character = 0 },
  }
end

local function client_label(client, bufnr)
  local root_desc = (type(client.root_dir) == "string" and client.root_dir ~= "")
      and (vim.fs.basename(client.root_dir) .. " — " .. client.root_dir)
    or "no root_dir"
  local cap = supports_command(client, bufnr, COMMANDS.resolve) and "" or " [no resolveStackTraceLocation]"
  return string.format("#%s %s (%s)%s", tostring(client.id or "?"), client.name or "jdtls", root_desc, cap)
end

local function is_client_root_compatible(client, prov)
  if hierarchy.client_stopped(client) then
    return false
  end
  if prov.root and not client_matches_root(client, prov.root) then
    return false
  end
  if prov.client_root_dir then
    local croot = (type(client.root_dir) == "string" and client.root_dir ~= "") and canonical(client.root_dir) or nil
    if not croot or not (subtree(croot, prov.client_root_dir) or subtree(prov.client_root_dir, croot)) then
      return false
    end
  end
  return true
end

local function is_client_id_compatible(client, prov)
  if prov.client_id == nil then
    return true
  end
  if client.id ~= prov.client_id then
    return false
  end
  if prov.client_root_dir then
    local croot = (type(client.root_dir) == "string" and client.root_dir ~= "") and canonical(client.root_dir) or nil
    if croot ~= prov.client_root_dir then
      return false
    end
  end
  return true
end

local function provenance_still_matches(ctx)
  local orig = ctx and ctx.provenance
  if type(orig) ~= "table" then
    return false
  end
  local cur = resolve_provenance(ctx.bufnr)
  return cur.trusted == orig.trusted
    and cur.kind == orig.kind
    and cur.root == orig.root
    and cur.client_id == orig.client_id
    and cur.client_root_dir == orig.client_root_dir
end

local function pick_client_explicitly(op_token, ctx, clients, prompt, on_client)
  local labels, by_label, seen = {}, {}, {}
  for _, client in ipairs(clients) do
    local label = hierarchy.unique_label(client_label(client, ctx.bufnr), seen)
    labels[#labels + 1] = label
    by_label[label] = client
  end

  ui.pick_one(labels, prompt, function(choice)
    if not ctrl:is_op_active(op_token) then
      return
    end
    local picked = by_label[choice]
    if not picked then
      ctrl:end_operation(op_token)
      return
    end
    if not ctrl:context_still_valid(ctx, true, true) then
      ctrl:end_operation(op_token)
      return
    end
    if not provenance_still_matches(ctx) then
      ui.notify("buffer project provenance changed during stack trace — operation aborted", vim.log.levels.WARN)
      ctrl:end_operation(op_token)
      return
    end
    if hierarchy.client_stopped(picked) then
      ui.notify("selected jdtls client is no longer running", vim.log.levels.WARN)
      ctrl:end_operation(op_token)
      return
    end
    if not supports_command(picked, ctx.bufnr, COMMANDS.resolve) then
      ui.notify("selected jdtls client does not support " .. COMMANDS.resolve, vim.log.levels.WARN)
      ctrl:end_operation(op_token)
      return
    end
    on_client(picked)
  end)
end

local function select_client(op_token, ctx, prov, on_client)
  if not ctrl:is_op_active(op_token) then
    return
  end
  if not ctrl:context_still_valid(ctx, true, true) then
    ctrl:end_operation(op_token)
    return
  end

  if prov.kind == "unverified_output" then
    ui.notify("cannot resolve stack trace: " .. (prov.reason or "unverified build output"), vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return
  end

  local attached = lsp.clients(ctx.bufnr)
  local live = live_jdtls_clients()

  if prov.trusted and (prov.root or prov.client_id ~= nil) then
    -- Only use an attached client if its id/root is compatible with verified provenance.
    local exact_attached = {}
    for _, client in ipairs(attached) do
      if is_client_root_compatible(client, prov) and is_client_id_compatible(client, prov) then
        exact_attached[#exact_attached + 1] = client
      end
    end

    if #exact_attached == 1 then
      local client = exact_attached[1]
      if not supports_command(client, ctx.bufnr, COMMANDS.resolve) then
        ui.notify("jdtls client does not support " .. COMMANDS.resolve, vim.log.levels.WARN)
        ctrl:end_operation(op_token)
        return
      end
      local scoped = prov.root
        or (type(client.root_dir) == "string" and client.root_dir ~= "" and canonical(client.root_dir))
      ctx.explicit_client_choice = false
      on_client(client, scoped)
      return
    elseif #exact_attached > 1 then
      pick_client_explicitly(
        op_token,
        ctx,
        exact_attached,
        "Java: Stack Trace — select JDTLS client",
        function(picked)
          local scoped = prov.root
            or (type(picked.root_dir) == "string" and picked.root_dir ~= "" and canonical(picked.root_dir))
          ctx.explicit_client_choice = true
          on_client(picked, scoped)
        end
      )
      return
    end

    -- Attached clients were absent or incompatible with provenance (wrong id/root):
    -- search live clients strictly matching provenance; never forward to a wrong project.
    local matching = {}
    for _, client in ipairs(live) do
      if is_client_root_compatible(client, prov) then
        matching[#matching + 1] = client
      end
    end

    if prov.client_id ~= nil then
      for _, client in ipairs(matching) do
        if is_client_id_compatible(client, prov) then
          if not supports_command(client, ctx.bufnr, COMMANDS.resolve) then
            ui.notify("jdtls client does not support " .. COMMANDS.resolve, vim.log.levels.WARN)
            ctrl:end_operation(op_token)
            return
          end
          local scoped = prov.root
            or (type(client.root_dir) == "string" and client.root_dir ~= "" and canonical(client.root_dir))
          ctx.explicit_client_choice = false
          on_client(client, scoped)
          return
        end
      end
    end

    if #matching == 0 then
      local target_desc = prov.root and ("project " .. vim.fs.basename(prov.root))
        or ("client #" .. tostring(prov.client_id))
      ui.notify("no running jdtls client matches " .. target_desc, vim.log.levels.WARN)
      ctrl:end_operation(op_token)
      return
    end

    if prov.client_id == nil and #matching == 1 then
      local client = matching[1]
      if not supports_command(client, ctx.bufnr, COMMANDS.resolve) then
        ui.notify("jdtls client does not support " .. COMMANDS.resolve, vim.log.levels.WARN)
        ctrl:end_operation(op_token)
        return
      end
      ctx.explicit_client_choice = false
      on_client(client, prov.root)
      return
    end

    local prompt = prov.client_id ~= nil
        and string.format(
          "Java: Stack Trace — provenance client #%s unavailable; select JDTLS client",
          tostring(prov.client_id)
        )
      or "Java: Stack Trace — select JDTLS client"
    pick_client_explicitly(op_token, ctx, matching, prompt, function(picked)
      local scoped = prov.root
        or (type(picked.root_dir) == "string" and picked.root_dir ~= "" and canonical(picked.root_dir))
      ctx.explicit_client_choice = true
      on_client(picked, scoped)
    end)
    return
  end

  if prov.trusted then
    if #attached == 1 then
      local client = attached[1]
      if not supports_command(client, ctx.bufnr, COMMANDS.resolve) then
        ui.notify("jdtls client does not support " .. COMMANDS.resolve, vim.log.levels.WARN)
        ctrl:end_operation(op_token)
        return
      end
      local scoped = (type(client.root_dir) == "string" and client.root_dir ~= "" and canonical(client.root_dir)) or nil
      ctx.explicit_client_choice = false
      on_client(client, scoped)
      return
    end
    if #attached > 1 then
      pick_client_explicitly(op_token, ctx, attached, "Java: Stack Trace — select JDTLS client", function(picked)
        local scoped = (type(picked.root_dir) == "string" and picked.root_dir ~= "" and canonical(picked.root_dir))
          or nil
        ctx.explicit_client_choice = true
        on_client(picked, scoped)
      end)
      return
    end
  end

  -- Buffer without reliable project context: never choose the first client/project silently.
  if #live == 0 then
    ui.notify(
      string.format(
        "cannot resolve stack trace: %s and no jdtls client is running",
        prov.reason or "no project context"
      ),
      vim.log.levels.WARN
    )
    ctrl:end_operation(op_token)
    return
  end

  pick_client_explicitly(
    op_token,
    ctx,
    live,
    "Java: Stack Trace — no buffer project context; select JDTLS client",
    function(picked)
      local scoped = (type(picked.root_dir) == "string" and picked.root_dir ~= "") and canonical(picked.root_dir) or nil
      ctx.explicit_client_choice = true
      on_client(picked, scoped)
    end
  )
end

local function uri_permitted_for_scope(uri, scoped_root)
  if hierarchy.is_jdt_uri(uri) then
    return true, nil
  end
  if not hierarchy.is_file_uri(uri) then
    return false, "unsupported URI scheme returned by jdtls: " .. tostring(uri)
  end
  if not scoped_root then
    return true, nil
  end
  local path = canonical(vim.uri_to_fname(uri))
  if not path or not subtree(scoped_root, path) then
    return false,
      string.format("refused navigation outside project %s: %s", vim.fs.basename(scoped_root), tostring(path or uri))
  end
  return true, nil
end

local function check_provenance_before_continue(op_token, ctx)
  if not provenance_still_matches(ctx) then
    ui.notify("buffer project provenance changed during stack trace — navigation refused", vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return false
  end
  return true
end

local function navigate_checked(op_token, client, ctx, parsed, uri, scoped_root, expected_file_path)
  if not ctrl:is_op_active(op_token) then
    return
  end
  if not ctrl:context_still_valid(ctx, true, true) then
    ctrl:end_operation(op_token)
    return
  end
  if not check_provenance_before_continue(op_token, ctx) then
    return
  end

  local prov = ctx.provenance
  local effective_root = scoped_root or (prov and prov.trusted and prov.root) or nil
  if prov and prov.trusted then
    if prov.root and (not effective_root or effective_root ~= prov.root) then
      ui.notify("resolved target scope does not match buffer provenance — navigation refused", vim.log.levels.WARN)
      ctrl:end_operation(op_token)
      return
    end
    if (prov.root or prov.client_root_dir) and not is_client_root_compatible(client, prov) then
      ui.notify(
        "selected jdtls client is incompatible with buffer project provenance — navigation refused",
        vim.log.levels.WARN
      )
      ctrl:end_operation(op_token)
      return
    end
    if not ctx.explicit_client_choice and prov.client_id ~= nil and not is_client_id_compatible(client, prov) then
      ui.notify(
        "selected jdtls client ID is incompatible with buffer provenance — navigation refused",
        vim.log.levels.WARN
      )
      ctrl:end_operation(op_token)
      return
    end
  end

  if is_nil_res(uri) or uri == "" then
    ui.notify("source location not found in jdtls for " .. frame_summary(parsed), vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return
  end
  if type(uri) ~= "string" then
    ui.notify("jdtls returned an unexpected stack trace location", vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return
  end

  local permitted, reason = uri_permitted_for_scope(uri, effective_root)
  if not permitted then
    ui.notify(reason, vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return
  end

  if expected_file_path then
    if not hierarchy.is_file_uri(uri) then
      ui.notify(
        string.format(
          "jdtls resolved %s instead of local candidate %s — navigation refused",
          tostring(uri),
          tostring(canonical(expected_file_path) or expected_file_path)
        ),
        vim.log.levels.WARN
      )
      ctrl:end_operation(op_token)
      return
    end
    local got = canonical(vim.uri_to_fname(uri))
    local want = canonical(expected_file_path)
    if not got or not want or got ~= want then
      ui.notify(
        string.format(
          "jdtls resolved %s instead of selected candidate %s — navigation refused",
          tostring(got or uri),
          tostring(want or expected_file_path)
        ),
        vim.log.levels.WARN
      )
      ctrl:end_operation(op_token)
      return
    end
  end

  ctx.navigation_guard = function()
    if not check_provenance_before_continue(op_token, ctx) then
      return false
    end
    if
      prov
      and prov.trusted
      and (prov.root or prov.client_root_dir)
      and not is_client_root_compatible(client, prov)
    then
      ui.notify("selected jdtls client no longer matches buffer provenance", vim.log.levels.WARN)
      return false
    end
    return true
  end
  ctrl:navigate_to({
    uri = uri,
    range = target_range(parsed),
  }, client, ctx, op_token)
end

local function query_resolve_for_project(op_token, client, ctx, project_name, cb)
  ctrl:request(op_token, client, ctx.bufnr, "workspace/executeCommand", {
    command = COMMANDS.resolve,
    arguments = { ctx.line, { project_name } },
  }, "resolve stack trace (" .. project_name .. ")", ctx, cb)
end

local function collect_scoped_source_paths(raw_data, scoped_root)
  local entries = {}
  local proj_seen, project_names = {}, {}
  for _, entry in ipairs(raw_data) do
    if type(entry) == "table" and type(entry.path) == "string" and entry.path ~= "" then
      local cpath = canonical(entry.path)
      if cpath and (not scoped_root or subtree(scoped_root, cpath)) then
        local pname = (type(entry.projectName) == "string" and entry.projectName ~= "") and entry.projectName or nil
        entries[#entries + 1] = {
          path = cpath,
          project_name = pname,
          display_path = (type(entry.displayPath) == "string" and entry.displayPath ~= "") and entry.displayPath or nil,
        }
        if pname and not proj_seen[pname] then
          proj_seen[pname] = true
          project_names[#project_names + 1] = pname
        end
      end
    end
  end
  table.sort(project_names)
  return entries, project_names
end

local function find_disk_candidates(scoped_entries, source_relpath, scoped_root)
  local candidates, seen = {}, {}
  for _, entry in ipairs(scoped_entries) do
    local candidate_path = entry.path .. "/" .. source_relpath
    if vim.fn.filereadable(candidate_path) == 1 then
      local cfile = canonical(candidate_path) or candidate_path
      local key = cfile .. "\0" .. tostring(entry.project_name or "")
      if not seen[key] then
        seen[key] = true
        local rel = (scoped_root and vim.fs.relpath(scoped_root, cfile))
          or (entry.display_path and (entry.display_path .. "/" .. source_relpath))
          or cfile
        candidates[#candidates + 1] = {
          file_path = cfile,
          source_root = entry.path,
          project_name = entry.project_name,
          rel_label = rel,
        }
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.rel_label ~= b.rel_label then
      return a.rel_label < b.rel_label
    end
    return tostring(a.project_name or "") < tostring(b.project_name or "")
  end)
  return candidates
end

local function resolve_across_projects(op_token, client, ctx, parsed, scoped_root, project_names)
  if #project_names == 0 then
    ui.notify("jdtls did not report project names to scope stack trace lookup", vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return
  end

  if #project_names == 1 then
    query_resolve_for_project(op_token, client, ctx, project_names[1], function(uri)
      navigate_checked(op_token, client, ctx, parsed, uri, scoped_root, nil)
    end)
    return
  end

  if #project_names > MAX_AUTO_QUERY_PROJECTS then
    ui.pick_one(project_names, "Java: Stack Trace — select project scope", function(choice)
      if not ctrl:is_op_active(op_token) then
        return
      end
      if not choice or choice == "" then
        ctrl:end_operation(op_token)
        return
      end
      if not ctrl:context_still_valid(ctx, true, true) then
        ctrl:end_operation(op_token)
        return
      end
      if not check_provenance_before_continue(op_token, ctx) then
        return
      end
      query_resolve_for_project(op_token, client, ctx, choice, function(uri)
        navigate_checked(op_token, client, ctx, parsed, uri, scoped_root, nil)
      end)
    end)
    return
  end

  local effective_root = scoped_root or (ctx.provenance and ctx.provenance.trusted and ctx.provenance.root) or nil
  local by_uri, uri_order = {}, {}
  local rejected_reason = nil
  local function step(idx)
    if not ctrl:is_op_active(op_token) then
      return
    end
    if idx > #project_names then
      if #uri_order == 0 then
        ui.notify(
          rejected_reason or ("source location not found in jdtls for " .. frame_summary(parsed)),
          vim.log.levels.WARN
        )
        ctrl:end_operation(op_token)
        return
      end
      if #uri_order == 1 then
        navigate_checked(op_token, client, ctx, parsed, uri_order[1], scoped_root, nil)
        return
      end

      local labels, by_label, seen = {}, {}, {}
      for _, uri in ipairs(uri_order) do
        local projs = table.concat(by_uri[uri], ", ")
        local label =
          hierarchy.unique_label(string.format("%s  [%s]", hierarchy.uri_label(uri, scoped_root), projs), seen)
        labels[#labels + 1] = label
        by_label[label] = uri
      end
      ui.pick_one(labels, "Java: Stack Trace — multiple projects resolved; select location", function(choice)
        if not ctrl:is_op_active(op_token) then
          return
        end
        local picked_uri = by_label[choice]
        if not picked_uri then
          ctrl:end_operation(op_token)
          return
        end
        if not ctrl:context_still_valid(ctx, true, true) then
          ctrl:end_operation(op_token)
          return
        end
        if not check_provenance_before_continue(op_token, ctx) then
          return
        end
        navigate_checked(op_token, client, ctx, parsed, picked_uri, scoped_root, nil)
      end)
      return
    end

    local proj_name = project_names[idx]
    query_resolve_for_project(op_token, client, ctx, proj_name, function(uri)
      if not check_provenance_before_continue(op_token, ctx) then
        return
      end
      if not is_nil_res(uri) and type(uri) == "string" and uri ~= "" then
        local permitted, reason = uri_permitted_for_scope(uri, effective_root)
        if permitted then
          if not by_uri[uri] then
            by_uri[uri] = {}
            uri_order[#uri_order + 1] = uri
          end
          by_uri[uri][#by_uri[uri] + 1] = proj_name
        elseif reason and not rejected_reason then
          rejected_reason = reason
        end
      end
      step(idx + 1)
    end)
  end

  step(1)
end

local function resolve_with_client(op_token, client, ctx, parsed, scoped_root)
  if not supports_command(client, ctx.bufnr, COMMANDS.list_source_paths) then
    ui.notify("jdtls client does not support " .. COMMANDS.list_source_paths, vim.log.levels.WARN)
    ctrl:end_operation(op_token)
    return
  end

  ctrl:request(
    op_token,
    client,
    ctx.bufnr,
    "workspace/executeCommand",
    {
      command = COMMANDS.list_source_paths,
      arguments = {},
    },
    "list source paths",
    ctx,
    function(res)
      if not check_provenance_before_continue(op_token, ctx) then
        return
      end
      if type(res) ~= "table" or type(res.data) ~= "table" then
        ui.notify("jdtls returned invalid source paths response", vim.log.levels.WARN)
        ctrl:end_operation(op_token)
        return
      end

      local scoped_entries, project_names = collect_scoped_source_paths(res.data, scoped_root)
      if #scoped_entries == 0 then
        if scoped_root then
          ui.notify(
            string.format("jdtls has no imported source paths for project %s", vim.fs.basename(scoped_root)),
            vim.log.levels.WARN
          )
        else
          ui.notify("selected jdtls client has no imported source paths", vim.log.levels.WARN)
        end
        ctrl:end_operation(op_token)
        return
      end

      local disk_candidates = find_disk_candidates(scoped_entries, parsed.source_relpath, scoped_root)

      if #disk_candidates == 1 then
        local cand = disk_candidates[1]
        if not cand.project_name then
          ui.notify("jdtls did not report a project name for the matching source root", vim.log.levels.WARN)
          ctrl:end_operation(op_token)
          return
        end
        query_resolve_for_project(op_token, client, ctx, cand.project_name, function(uri)
          navigate_checked(op_token, client, ctx, parsed, uri, scoped_root, cand.file_path)
        end)
        return
      end

      if #disk_candidates > 1 then
        local proj_counts = {}
        for _, cand in ipairs(disk_candidates) do
          local key = tostring(cand.project_name or "")
          proj_counts[key] = (proj_counts[key] or 0) + 1
        end

        local labels, by_label, seen = {}, {}, {}
        for _, cand in ipairs(disk_candidates) do
          local text = cand.project_name and string.format("%s  [%s]", cand.rel_label, cand.project_name)
            or cand.rel_label
          local label = hierarchy.unique_label(text, seen)
          labels[#labels + 1] = label
          by_label[label] = cand
        end

        ui.pick_one(labels, "Java: Stack Trace — multiple matching files; select target", function(choice)
          if not ctrl:is_op_active(op_token) then
            return
          end
          local picked = by_label[choice]
          if not picked then
            ctrl:end_operation(op_token)
            return
          end
          if not ctrl:context_still_valid(ctx, true, true) then
            ctrl:end_operation(op_token)
            return
          end
          if not check_provenance_before_continue(op_token, ctx) then
            return
          end
          local pkey = tostring(picked.project_name or "")
          if picked.project_name and proj_counts[pkey] == 1 then
            query_resolve_for_project(op_token, client, ctx, picked.project_name, function(uri)
              navigate_checked(op_token, client, ctx, parsed, uri, scoped_root, picked.file_path)
            end)
          else
            -- Multiple source roots within the same JDT project share `projectName`;
            -- JDTLS `resolveStackTraceLocation` would pick one arbitrarily, so jump
            -- directly to the verified file selected by the user.
            local uri = vim.uri_from_fname(picked.file_path)
            navigate_checked(op_token, client, ctx, parsed, uri, scoped_root, picked.file_path)
          end
        end)
        return
      end

      resolve_across_projects(op_token, client, ctx, parsed, scoped_root, project_names)
    end
  )
end

local function capture_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row0 = math.max(0, (cursor[1] or 1) - 1)
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ""
  return {
    bufnr = bufnr,
    win = win,
    cursor = cursor,
    tick = vim.b[bufnr].changedtick,
    project_root = nil,
    line = line,
    provenance = nil,
    cword = "",
  }
end

---Cancel the active stack trace resolution request, if any.
---@return boolean cancelled
function M.cancel()
  return ctrl:cancel(true)
end

---Navigate the Java stack trace line under the cursor to its file and line.
function M.stacktrace()
  -- Cancel any active operation/picker before any early return, including
  -- re-invocations on invalid, native, unknown, or moved cursor positions.
  ctrl:cancel(false)

  local ctx = capture_context()
  if not ctx then
    ui.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return
  end

  local parsed = parse_line(ctx.line)
  if not parsed then
    ui.notify("no Java stack trace frame found on the current line", vim.log.levels.WARN)
    return
  end

  if parsed.kind == "native" then
    ui.notify("cannot navigate: native method (" .. frame_summary(parsed) .. ")", vim.log.levels.WARN)
    return
  end

  if parsed.kind == "unknown" then
    ui.notify("cannot navigate: unknown source (" .. frame_summary(parsed) .. ")", vim.log.levels.WARN)
    return
  end

  local prov = resolve_provenance(ctx.bufnr)
  ctx.provenance = prov
  ctx.project_root = prov.root

  local op_token = ctrl:begin_operation()
  select_client(op_token, ctx, prov, function(client, scoped_root)
    resolve_with_client(op_token, client, ctx, parsed, scoped_root)
  end)
end

-- Exposed for deterministic tests
M._parse_line = parse_line
M._resolve_provenance = resolve_provenance
M._supports_command = supports_command
M._target_range = target_range
M._navigate_to = function(entry, client, ctx, op_token)
  return ctrl:navigate_to(entry, client, ctx, op_token)
end
M._pending = function()
  return ctrl:pending()
end
M._reset = function()
  ctrl:reset()
end

return M
