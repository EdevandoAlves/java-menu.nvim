-- java_menu/diagnostics.lua
-- <leader>jp → Environment: a read-only report of the environment the Java
-- workflows depend on (Neovim, JDK, build tools, JDTLS, optional plugins).
--
-- Strictly informational: nothing is installed, configured, started or built.
-- External programs are only queried (`java -version`, `mvn -version`, ...) and
-- their output is formatted, never executed beyond the version flag.

local M = {}

---Run a command and capture its output (stderr included by system()).
---@param cmd string[]
---@return string|nil
local function run(cmd)
  local ok, out = pcall(vim.fn.system, cmd)
  if not ok then
    return nil
  end
  return tostring(out)
end

---First non-empty line of `text`, optionally the first one matching `pattern`.
---@param text string|nil
---@param pattern string|nil
---@return string|nil
local function version_line(text, pattern)
  local fallback
  for line in (text or ""):gmatch("[^\r\n]+") do
    line = vim.trim(line)
    if line ~= "" then
      if pattern and line:match(pattern) then
        return line
      end
      fallback = fallback or line
    end
  end
  return fallback
end

---`Label: /path/to/tool (version)` or `Label: not found`.
---@param label string
---@param exe string
---@param args string[]
---@param pattern string|nil line pattern that carries the version
---@return string
local function tool_line(label, exe, args, pattern)
  local path = vim.fn.exepath(exe)
  if path == "" then
    return label .. ": not found"
  end
  local cmd = { exe }
  vim.list_extend(cmd, args)
  local version = version_line(run(cmd), pattern)
  return label .. ": " .. path .. " (" .. (version or "version unavailable") .. ")"
end

---@param root string|nil
---@param wrapper string
---@return string
local function wrapper_state(root, wrapper)
  if not root then
    return "no project"
  end
  local path = root .. "/" .. wrapper
  if vim.uv.fs_stat(path) == nil then
    return "not present"
  end
  return "present (" .. (vim.fs.relpath(root, path) or wrapper) .. ")"
end

---@param label string
---@param mod string
---@param missing string
---@return string
local function module_line(label, mod, missing)
  local ok = pcall(require, mod)
  return label .. ": " .. (ok and "available" or missing)
end

---Environment report lines. Pure: only reads state and queries version flags.
---@return string[]
function M._collect()
  local project = require("java_menu.project")
  local lsp = require("java_menu.lsp")

  local version = vim.version()
  local lines = {
    ("Neovim: %d.%d.%d"):format(version.major, version.minor, version.patch),
    tool_line("Java", "java", { "-version" }, "^openjdk version"),
    tool_line("javac", "javac", { "--version" }, "^javac "),
  }

  local java_home = vim.env.JAVA_HOME
  lines[#lines + 1] = "JAVA_HOME: " .. ((java_home and java_home ~= "") and java_home or "not set")

  lines[#lines + 1] = tool_line("Maven", "mvn", { "-version" }, "^Apache Maven")
  lines[#lines + 1] = tool_line("Gradle", "gradle", { "--version" }, "^Gradle %S+")

  -- Spring Boot project creation (7B.2) needs an HTTP client and unzip; both
  -- are optional for the rest of the plugin, so they are only reported here.
  if vim.fn.exepath("curl") ~= "" then
    lines[#lines + 1] = tool_line("curl", "curl", { "--version" }, "^curl ")
  elseif vim.fn.exepath("wget") ~= "" then
    lines[#lines + 1] = tool_line("wget", "wget", { "--version" }, "^GNU Wget")
  else
    lines[#lines + 1] = "curl: not found (wget absent too; Spring Boot project download unavailable)"
  end
  lines[#lines + 1] = tool_line("unzip", "unzip", { "-v" }, "^UnZip")

  local bufnr = vim.api.nvim_get_current_buf()
  local root = project.root(bufnr)
  lines[#lines + 1] = "Maven wrapper: " .. wrapper_state(root, "mvnw")
  lines[#lines + 1] = "Gradle wrapper: " .. wrapper_state(root, "gradlew")

  local client = lsp.client(bufnr)
  if client then
    local count = #vim.lsp.get_clients({ name = "jdtls", bufnr = bufnr })
    local workspace = project.client_workspace_dir(client) or "unknown"
    lines[#lines + 1] = ("JDTLS: attached (%d client(s), workspace: %s)"):format(count, workspace)
  else
    lines[#lines + 1] = "JDTLS: not attached"
  end

  lines[#lines + 1] = module_line("jc.nvim", "jc.jdtls", "MISSING (required)")
  lines[#lines + 1] = module_line("snacks.nvim", "snacks", "not found (fallback: vim.ui.*)")
  lines[#lines + 1] = module_line("which-key.nvim", "which-key", "not found (optional)")
  lines[#lines + 1] = module_line("neotest", "neotest", "not found (Tests menu disabled)")
  lines[#lines + 1] = module_line("nvim-dap", "dap", "not found (Debug menu disabled)")
  return lines
end

---Open the environment report in a read-only scratch buffer (closed with `q`).
function M.report()
  local lines = M._collect()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.b[buf].java_env_title = "Environment"

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local height = math.min(#lines + 2, math.max(6, vim.o.lines - 4))
  vim.api.nvim_win_set_height(win, height)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, nowait = true })
  return buf
end

return M
