-- java_menu/debug.lua
-- Debug Java via nvim-dap + java-debug (jdtls).
-- Does not create its own adapter or UI: reuses the adapter registered by the
-- user with nvim-jdtls (LspAttach) and reuses nvim-dap.

local ui = require("java_menu.ui")
local lsp = require("java_menu.lsp")
local project = require("java_menu.project")

local M = {}

local function dap()
  local ok, mod = pcall(require, "dap")
  if ok then
    return mod
  end
end

local function dapui()
  local ok, mod = pcall(require, "dapui")
  if ok then
    return mod
  end
end

local function java_ready()
  local d = dap()
  return d ~= nil and d.adapters ~= nil and d.adapters.java ~= nil
end

local function session()
  local d = dap()
  return d and d.session() or nil
end

local function is_attach(sess)
  return sess ~= nil and sess.config ~= nil and sess.config.request == "attach"
end

local function launch_configs()
  local d = dap()
  local out = {}
  for _, config in ipairs((d and d.configurations and d.configurations.java) or {}) do
    if config.request == "launch" then
      out[#out + 1] = config
    end
  end
  return out
end

-- ---------- buffer project (wrong-project main) ----------

local function real(path)
  local r = vim.uv.fs_realpath(path)
  return r and vim.fs.normalize(r) or vim.fs.normalize(path)
end

---Is `path` inside the subtree of `parent`?
local function subtree(parent, path)
  parent, path = real(parent), real(path)
  return parent == path or path:sub(1, #parent + 1) == parent .. "/"
end

---Roots considered "this project": the buffer-detected root plus the roots of
---jdtls clients in the same tree (aggregator/module).
---@param bufnr number|nil
---@return string[]
local function current_roots(bufnr)
  local roots = {}
  local root = project.root(bufnr)
  if root then
    roots[#roots + 1] = root
  else
    local client = lsp.client(bufnr)
    local other = client and client.config and client.config.root_dir
    if other then
      roots[#roots + 1] = other
    end
  end
  for _, client in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
    local other = client.config and client.config.root_dir
    if other then
      for _, known in ipairs(roots) do
        if subtree(known, other) or subtree(other, known) then
          roots[#roots + 1] = other
          break
        end
      end
    end
  end
  return roots
end

---Classify a launch config: "own" (this project), "other" (another project)
---or "ambiguous" (no decisive project metadata). Uses cwd, classPaths and
---modulePaths; projectName alone does not prove ownership (two projects may
---share a name) and the class name is never used as a criterion.
---@param config table
---@param roots string[]
---@return string "own"|"other"|"ambiguous"
local function classify_config(config, roots)
  if #roots == 0 then
    return "ambiguous"
  end
  if type(config.cwd) == "string" and config.cwd ~= "" then
    for _, root in ipairs(roots) do
      if subtree(root, config.cwd) then
        return "own"
      end
    end
    return "other"
  end
  for _, key in ipairs({ "classPaths", "modulePaths" }) do
    local paths = config[key]
    if type(paths) == "table" then
      for _, path in ipairs(paths) do
        if type(path) == "string" and path ~= "" then
          for _, root in ipairs(roots) do
            if subtree(root, path) then
              return "own"
            end
          end
        end
      end
    end
  end
  return "ambiguous"
end

---Launch configs split by ownership of the buffer project.
---@param bufnr number|nil
---@return table[] own, table[] other, table[] ambiguous
local function project_configs(bufnr)
  local roots = current_roots(bufnr)
  local own, other, ambiguous = {}, {}, {}
  for _, config in ipairs(launch_configs()) do
    local verdict = classify_config(config, roots)
    if verdict == "own" then
      own[#own + 1] = config
    elseif verdict == "other" then
      other[#other + 1] = config
    else
      ambiguous[#ambiguous + 1] = config
    end
  end
  return own, other, ambiguous
end

-- ---------- context buffer ----------

local DEBUG_FILETYPES = {
  ["dap-repl"] = true,
  ["dapui_scopes"] = true,
  ["dapui_breakpoints"] = true,
  ["dapui_stacks"] = true,
  ["dapui_watches"] = true,
  ["dapui_console"] = true,
  ["dapui_hover"] = true,
}

local last_code_buf

---Code buffer behind the DAP REPL/panels (the menu may be opened from there).
local function context_buf()
  local cur = vim.api.nvim_get_current_buf()
  if not DEBUG_FILETYPES[vim.bo[cur].filetype] then
    if vim.bo[cur].buftype == "" then
      last_code_buf = cur
    end
    return cur
  end
  if last_code_buf and vim.api.nvim_buf_is_valid(last_code_buf) then
    return last_code_buf
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and not DEBUG_FILETYPES[vim.bo[buf].filetype] then
      return buf
    end
  end
  return cur
end

-- ---------- operations ----------

local function debug_main()
  if session() then
    ui.notify("a debug session is already active — stop it before starting another", vim.log.levels.WARN)
    return
  end

  local bufnr = context_buf()
  local own, other, ambiguous = project_configs(bufnr)
  if #own == 0 then
    if #other > 0 then
      ui.notify(
        #other
          .. " main class(es) discovered, but from another project — nothing was started; open a .java file from this project",
        vim.log.levels.WARN
      )
    elseif #ambiguous > 0 then
      ui.notify(
        #ambiguous
          .. " launch configuration(s) without project metadata (ambiguous) — nothing was started; open a project file with jdtls attached and let jdtls rediscover the main classes",
        vim.log.levels.WARN
      )
    else
      ui.notify(
        "no main class discovered by jdtls — open a project .java file with jdtls attached and reopen the menu",
        vim.log.levels.WARN
      )
    end
    return
  end
  if #ambiguous > 0 then
    ui.notify(#ambiguous .. " configuration(s) without project metadata were ignored for safety", vim.log.levels.INFO)
  end

  local labels, by_label = {}, {}
  for _, config in ipairs(own) do
    labels[#labels + 1] = config.name
    by_label[config.name] = config
  end

  ui.pick_one(labels, "Java: Debug — main class", function(choice)
    local config = by_label[choice]
    if not config then
      return
    end
    if session() then
      ui.notify("a debug session is already active", vim.log.levels.WARN)
      return
    end
    dap().run(config)
  end)
end

local function debug_test(kind)
  if session() then
    ui.notify("a debug session is already active — stop it before starting another", vim.log.levels.WARN)
    return
  end
  local ok, jdtls_dap = pcall(require, "jdtls.dap")
  if not ok then
    ui.notify("jdtls.dap unavailable", vim.log.levels.ERROR)
    return
  end
  local fn = kind == "nearest" and jdtls_dap.test_nearest_method or jdtls_dap.test_class
  if type(fn) ~= "function" then
    ui.notify("test debugging is not supported by this nvim-jdtls version", vim.log.levels.WARN)
    return
  end
  pcall(fn, {})
end

local function attach_jvm()
  if session() then
    ui.notify("a debug session is already active — stop it before attaching", vim.log.levels.WARN)
    return
  end

  ui.ask("Java: Debug — host JDWP: ", "127.0.0.1", function(host)
    if host == nil then
      return
    end
    host = vim.trim(host)
    if host == "" then
      host = "127.0.0.1"
    end
    ui.ask("Java: Debug — JDWP port: ", "5005", function(port)
      if port == nil then
        return
      end
      local number = tonumber(vim.trim(port))
      if not number or number <= 0 or number > 65535 then
        ui.notify("invalid port: " .. tostring(port), vim.log.levels.WARN)
        return
      end
      dap().run({
        type = "java",
        name = "Attach JVM " .. host .. ":" .. number,
        request = "attach",
        hostName = host,
        port = number,
      })
    end)
  end)
end

local function toggle_breakpoint(condition)
  if condition == nil then
    dap().toggle_breakpoint()
    return
  end
  ui.ask("Java: Debug — breakpoint condition: ", "", function(value)
    if value == nil then
      return
    end
    value = vim.trim(value)
    if value == "" then
      dap().toggle_breakpoint()
    else
      dap().set_breakpoint(value)
    end
  end)
end

local function stop_session()
  local sess = session()
  if not sess then
    ui.notify("no active debug session", vim.log.levels.WARN)
    return
  end
  if is_attach(sess) then
    -- external JVM: only disconnect, never terminate the process
    dap().disconnect({ terminateDebuggee = false })
    ui.notify("disconnected from the JVM (the external process keeps running)", vim.log.levels.INFO)
    return
  end
  dap().terminate({})
end

local function float_elem(name)
  local ui_mod = dapui()
  if not ui_mod then
    ui.notify("nvim-dap-ui is not installed", vim.log.levels.WARN)
    return
  end
  pcall(ui_mod.float_element, name)
end

-- ---------- menu ----------

---Entry point of `<leader>jd`.
function M.debug()
  local bufnr = context_buf()
  local sess = session()
  local ready = java_ready()
  local attached = ui.jdtls_attached(bufnr)
  local is_java = vim.bo[bufnr].filetype == "java"
  local has_ui = dapui() ~= nil

  local function session_reason()
    if not ready then
      return "java-debug is not loaded (bundle is not in the jdtls client — restart Neovim)"
    end
    if not sess then
      return "no active debug session"
    end
  end

  local function test_reason()
    if not ready then
      return "java-debug is not loaded (restart Neovim)"
    end
    if not attached then
      return "jdtls is not attached (test debugging uses jdtls java-test)"
    end
    if not is_java then
      return "open the test .java file"
    end
  end

  local entries = {
    {
      key = "main",
      label = "Debug Main Class",
      enabled = ready and not sess and #project_configs(bufnr) > 0,
      reason = (not ready and "java-debug is not loaded (restart Neovim)") or (sess and "active debug session") or (
        function()
          local own, other, ambiguous = project_configs(bufnr)
          if #own == 0 and #other > 0 then
            return "main class discovered only in another project"
          end
          if #own == 0 and #ambiguous > 0 then
            return "launch configuration(s) without project metadata"
          end
          return "no main class discovered by jdtls"
        end
      )(),
    },
    {
      key = "test_nearest",
      label = "Debug Nearest JUnit Test",
      enabled = ready and not sess and attached and is_java,
      reason = test_reason(),
    },
    {
      key = "test_class",
      label = "Debug JUnit Test Class",
      enabled = ready and not sess and attached and is_java,
      reason = test_reason(),
    },
    {
      key = "attach",
      label = "Attach JVM (JDWP, loopback)",
      enabled = ready and not sess,
      reason = (not ready and "java-debug is not loaded (restart Neovim)") or "active debug session",
    },
    { key = "toggle_bp", label = "Toggle Breakpoint", enabled = true },
    { key = "cond_bp", label = "Conditional Breakpoint", enabled = true },
    {
      key = "continue",
      label = "Continue / Start",
      enabled = sess ~= nil,
      reason = session_reason(),
    },
    { key = "pause", label = "Pause", enabled = sess ~= nil, reason = session_reason() },
    { key = "over", label = "Step Over", enabled = sess ~= nil, reason = session_reason() },
    { key = "into", label = "Step Into", enabled = sess ~= nil, reason = session_reason() },
    { key = "out", label = "Step Out", enabled = sess ~= nil, reason = session_reason() },
    {
      key = "vars",
      label = "Inspect Variables",
      enabled = sess ~= nil and has_ui,
      reason = (sess == nil and session_reason()) or "nvim-dap-ui not installed",
    },
    { key = "repl", label = "Open Debug REPL", enabled = sess ~= nil, reason = session_reason() },
    {
      key = "stack",
      label = "Show Call Stack",
      enabled = sess ~= nil and has_ui,
      reason = (sess == nil and session_reason()) or "nvim-dap-ui not installed",
    },
    {
      key = "stop",
      label = (sess == nil) and "Stop Debug Session"
        or (is_attach(sess) and "Stop Debug Session (disconnect)" or "Stop Debug Session (terminate)"),
      enabled = sess ~= nil,
      reason = session_reason(),
    },
  }

  ui.menu(entries, "Java: Debug", function(entry)
    if entry.key == "main" then
      debug_main()
    elseif entry.key == "test_nearest" then
      debug_test("nearest")
    elseif entry.key == "test_class" then
      debug_test("class")
    elseif entry.key == "attach" then
      attach_jvm()
    elseif entry.key == "toggle_bp" then
      toggle_breakpoint(nil)
    elseif entry.key == "cond_bp" then
      toggle_breakpoint("")
    elseif entry.key == "continue" then
      dap().continue()
    elseif entry.key == "pause" then
      dap().pause()
    elseif entry.key == "over" then
      dap().step_over()
    elseif entry.key == "into" then
      dap().step_into()
    elseif entry.key == "out" then
      dap().step_out()
    elseif entry.key == "vars" then
      float_elem("scopes")
    elseif entry.key == "repl" then
      dap().repl.open()
    elseif entry.key == "stack" then
      float_elem("frames")
    elseif entry.key == "stop" then
      stop_session()
    end
  end)
end

-- exposed for tests
M._context_buf = context_buf
M._launch_configs = launch_configs
M._project_configs = project_configs
M._current_roots = current_roots
M._classify_config = classify_config

return M
