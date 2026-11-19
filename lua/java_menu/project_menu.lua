-- java_menu/project_menu.lua
-- <leader>jp: the Project menu. Read-only entry point that delegates to the
-- new modules (create, diagnostics) and shows what was detected for the
-- current buffer: root, build tool, modules, source roots, discovery
-- limitation and the attached JDTLS client.
--
-- This module never scaffolds, edits build files or starts JDTLS: it only
-- formats what `project.lua` and `lsp.lua` already resolved. Dependencies are
-- loaded on demand, like every menu module of the plugin.

local M = {}

local INFO_REASON = "no Java project (pom.xml, build.gradle or src/main/java) from this directory"
local DEPS_REASON = "no Maven/Gradle project from this directory"

---Menu context buffer: when the menu is opened from an output buffer (build
---output, this menu's own report), look for a real file buffer so the project
---is still resolved from the code the user was working on.
---@return integer
local function context_buf()
  local cur = vim.api.nvim_get_current_buf()
  if vim.bo[cur].buftype == "" then
    return cur
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      buf ~= cur
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == ""
      and vim.api.nvim_buf_get_name(buf) ~= ""
    then
      return buf
    end
  end
  return cur
end

---Directory of the buffer (or the cwd for an unnamed buffer), canonical.
---@param bufnr integer|nil
---@return string
local function start_dir(bufnr)
  local buf = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local dir = name ~= "" and vim.fs.dirname(name) or vim.uv.cwd()
  return vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
end

---Project root without a build file: the closest directory (at most 16
---levels up) that contains src/main/java.
---@param bufnr integer|nil
---@return string|nil
function M._plain_root(bufnr)
  local dir = start_dir(bufnr)
  for _ = 1, 16 do
    if vim.fn.isdirectory(dir .. "/src/main/java") == 1 then
      return dir
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      return nil
    end
    dir = parent
  end
  return nil
end

---Is Project Info available for the buffer? A build marker or a plain
---src/main/java layout is enough (no JDTLS required).
---@param bufnr integer|nil
---@return boolean
function M._info_available(bufnr)
  local project = require("java_menu.project")
  return project.root(bufnr) ~= nil or M._plain_root(bufnr) ~= nil
end

---Build tool of the root, from the markers already known by project.lua.
---@param root string
---@return string
local function build_tool_label(root)
  local project = require("java_menu.project")
  if vim.fn.filereadable(root .. "/pom.xml") == 1 then
    return "Maven"
  end
  for _, marker in ipairs(project.markers) do
    if vim.fn.filereadable(root .. "/" .. marker) == 1 then
      return "Gradle"
    end
  end
  return "Plain Java (no build file)"
end

---Lines of the Project Info report (pure: nothing is written).
---@param bufnr integer|nil
---@return string[]
function M._info_lines(bufnr)
  local project = require("java_menu.project")
  local lsp = require("java_menu.lsp")

  local root = project.root(bufnr) or M._plain_root(bufnr)
  if not root then
    return { "Root: (none)", "Build tool: (none)", "Modules: 0" }
  end
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)

  local tool = build_tool_label(root)
  local modules = tool == "Plain Java (no build file)" and { root } or project.modules(root)
  local lines = {
    "Root: " .. root,
    "Build tool: " .. tool,
    "Modules: " .. tostring(#modules),
  }
  for _, mod in ipairs(modules) do
    local rel = vim.fs.relpath(root, mod) or mod
    lines[#lines + 1] = "  " .. rel
  end

  lines[#lines + 1] = "Source roots:"
  local roots = project.source_roots(root)
  if #roots == 0 then
    lines[#lines + 1] = "  (none)"
  else
    for _, source_root in ipairs(roots) do
      lines[#lines + 1] = "  " .. source_root.label
    end
  end

  local limitation = project.discovery_limitation(root)
  if limitation then
    lines[#lines + 1] = "Discovery: " .. limitation
  end

  local client = lsp.client(bufnr)
  if client then
    local workspace = project.client_workspace_dir(client) or "unknown"
    lines[#lines + 1] = "JDTLS: attached (workspace: " .. workspace .. ")"
  else
    lines[#lines + 1] = "JDTLS: not attached"
  end
  return lines
end

---Read-only scratch buffer for a report: a split below, closed with `q`.
---@param lines string[]
---@param title string
---@param title_var string `vim.b` key that marks the report buffer
---@return integer bufnr
local function open_report(lines, title, title_var)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.b[buf][title_var] = title

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

---Open the Project Info report (read-only, no side effects).
---@param bufnr integer|nil
function M.info(bufnr)
  local lines = M._info_lines(bufnr)
  open_report(lines, "Project Info", "java_info_title")
end

---Run the Project menu. Entries are always visible; unavailable ones explain
---why (ui.menu notifies the reason when chosen).
function M.project()
  local ui = require("java_menu.ui")
  local bufnr = context_buf()
  local deps_available, deps_reason = require("java_menu.deps").available(bufnr)

  local entries = {
    { key = "new", label = "New Project…", enabled = true },
    { key = "info", label = "Project Info…", enabled = M._info_available(bufnr), reason = INFO_REASON },
    { key = "deps", label = "Dependencies…", enabled = deps_available, reason = deps_reason or DEPS_REASON },
    { key = "env", label = "Environment…", enabled = true },
  }

  ui.menu(entries, "Java: Project", function(entry)
    if entry.key == "new" then
      require("java_menu.create").create()
    elseif entry.key == "info" then
      M.info(bufnr)
    elseif entry.key == "deps" then
      require("java_menu.deps").menu(bufnr)
    elseif entry.key == "env" then
      require("java_menu.diagnostics").report()
    end
  end)
end

return M
