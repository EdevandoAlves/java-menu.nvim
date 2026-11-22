-- java_menu/init.lua
-- Public API of java-menu.nvim: require("java_menu").setup(opts).
--
-- The plugin is a menu layer over jc.nvim (a required dependency) and over the
-- JDTLS client that the USER already started: no server, Mason, blink.cmp or
-- personal configuration lives here. Keymaps are global (not limited to
-- ft=java), so the menus stay available in pom.xml, build.gradle(.kts) and any
-- buffer inside a Java project.
--
-- Java modules load on demand: each keymap callback requires the module only
-- when the key is used (setup() loads none of them).

local M = {}

-- Menu actions: name → key (prefix suffix), module, modes and label.
-- Each module's public entry point keeps its original responsibility
-- (new.new, build.build, ...).
M.actions = {
  new = { key = "n", module = "java_menu.new", entry = "new", modes = { "n" }, desc = "New" },
  generate = { key = "g", module = "java_menu.generate", entry = "generate", modes = { "n" }, desc = "Generate" },
  refactor = { key = "r", module = "java_menu.refactor", entry = "refactor", modes = { "n", "x" }, desc = "Refactor" },
  imports = { key = "i", module = "java_menu.imports", entry = "imports", modes = { "n" }, desc = "Imports" },
  build = { key = "b", module = "java_menu.build", entry = "build", modes = { "n" }, desc = "Build/Run" },
  tests = { key = "t", module = "java_menu.tests", entry = "tests", modes = { "n" }, desc = "Tests" },
  debug = { key = "d", module = "java_menu.debug", entry = "debug", modes = { "n" }, desc = "Debug" },
  project = { key = "p", module = "java_menu.project_menu", entry = "project", modes = { "n" }, desc = "Project" },
  calls = { key = "c", module = "java_menu.calls", entry = "calls", modes = { "n" }, desc = "Call Hierarchy" },
  types = { key = "h", module = "java_menu.types", entry = "types", modes = { "n" }, desc = "Type Hierarchy" },
  stacktrace = {
    key = "s",
    module = "java_menu.stacktrace",
    entry = "stacktrace",
    modes = { "n" },
    desc = "Stack Trace",
  },
}

M.config = {
  prefix = "<leader>j",
  -- enable/disable groups (keys of M.actions); true by default
  groups = {},
  -- register the group label with which-key when available (optional)
  which_key = true,
}

-- Keymaps and command created by the last setup() call; this is what makes
-- setup() idempotent: it clears its own registrations before recreating them.
local registered = {
  maps = {}, -- { { mode, lhs }, ... }
  command = nil,
}

local DESC_PREFIX = "Java Menu: "

local function desc_for(action)
  return DESC_PREFIX .. action.desc
end

---Require jc.nvim (a hard dependency) with a clear, actionable error.
local function require_jc()
  local ok, jc_jdtls = pcall(require, "jc.jdtls")
  if not ok or type(jc_jdtls) ~= "table" then
    error(
      "java-menu.nvim: jc.nvim is a required dependency and was not found "
        .. "(require('jc.jdtls') failed: "
        .. tostring(jc_jdtls)
        .. "). Install artur-shaik/jc.nvim alongside this plugin."
    )
  end
end

---Remove registrations created by a previous setup() (idempotency).
---A keymap is deleted only while it is still ours (its description carries
---our prefix): if the user replaced one of our keymaps, it is preserved and
---reported as a conflict by the new registration.
local function clear_previous()
  for _, m in ipairs(registered.maps) do
    local cur = vim.fn.maparg(m.lhs, m.mode, false, true)
    if type(cur) == "table" and not vim.tbl_isempty(cur) then
      local ours = type(cur.desc) == "string" and cur.desc:find(DESC_PREFIX, 1, true) ~= nil
      if ours then
        pcall(vim.keymap.del, m.mode, m.lhs)
      end
    end
  end
  registered.maps = {}
  if registered.command then
    pcall(vim.api.nvim_del_user_command, registered.command)
    registered.command = nil
  end
end

---Existing keymaps from other plugins are never overwritten: they are kept
---and the conflict is reported once, naming the affected key. A mapping with
---our description (our own registration that survived cleanup) is treated as
---ours and may be recreated.
local function conflicting(lhs, mode, want_desc)
  local existing = vim.fn.maparg(lhs, mode, false, true)
  if type(existing) ~= "table" or vim.tbl_isempty(existing) then
    return false
  end
  return existing.desc ~= want_desc
end

local function apply_keymaps(prefix, groups, conflicts)
  for name, action in pairs(M.actions) do
    if groups[name] ~= false then -- default: all groups enabled
      local lhs = prefix .. action.key
      local want_desc = desc_for(action)
      for _, mode in ipairs(action.modes) do
        if conflicting(lhs, mode, want_desc) then
          conflicts[#conflicts + 1] = ("%s (%s): conflict — already mapped for another purpose; keymap preserved and group '%s' not registered"):format(
            lhs,
            mode,
            name
          )
        else
          vim.keymap.set(mode, lhs, function()
            local mod = require(action.module)
            mod[action.entry]()
          end, { desc = want_desc, silent = true })
          registered.maps[#registered.maps + 1] = { mode = mode, lhs = lhs }
        end
      end
    end
  end
end

local function sorted_action_names()
  local names = {}
  for name in pairs(M.actions) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---Run one menu group on demand — entry point for plugin-manager `keys`
---(loads only the requested action's module).
---@param name string
function M.trigger(name)
  local action = M.actions[name]
  if not action then
    error(
      "java-menu.nvim: unknown action '"
        .. tostring(name)
        .. "' — options: "
        .. table.concat(sorted_action_names(), ", ")
    )
  end
  require(action.module)[action.entry]()
end

local function apply_command()
  local names = sorted_action_names()
  vim.api.nvim_create_user_command("JavaMenu", function(ev)
    local name = ev.args ~= "" and ev.args or nil
    if not name then
      vim.notify("java-menu.nvim: use :JavaMenu <" .. table.concat(names, "|") .. ">", vim.log.levels.INFO)
      return
    end
    M.trigger(name)
  end, {
    nargs = "?",
    complete = function()
      return names
    end,
    desc = "Open a Java menu group",
  })
  registered.command = "JavaMenu"
end

local function apply_which_key(prefix)
  if not M.config.which_key then
    return
  end
  -- optional integration: a missing which-key is not an error
  local ok, wk = pcall(require, "which-key")
  if ok and type(wk.add) == "function" then
    pcall(wk.add, { { prefix, group = "Java" } })
  end
end

---Configure the plugin. Idempotent: running it again clears only its own
---keymaps and command before recreating them; third-party keymaps are
---preserved and conflicts are reported. No Java module is loaded here.
---@param opts { prefix?: string, groups?: table<string, boolean>, which_key?: boolean }|nil
function M.setup(opts)
  opts = opts or {}
  if opts.prefix ~= nil and type(opts.prefix) ~= "string" then
    error("java-menu.nvim: opts.prefix must be a string, got " .. type(opts.prefix))
  end
  if opts.groups ~= nil and type(opts.groups) ~= "table" then
    error("java-menu.nvim: opts.groups must be a table, got " .. type(opts.groups))
  end

  require_jc()

  M.config.prefix = opts.prefix or M.config.prefix
  if opts.groups then
    for k, v in pairs(opts.groups) do
      M.config.groups[k] = v
    end
  end
  if opts.which_key ~= nil then
    M.config.which_key = opts.which_key
  end

  clear_previous()

  local conflicts = {}
  apply_keymaps(M.config.prefix, M.config.groups, conflicts)
  apply_command()
  apply_which_key(M.config.prefix)

  if #conflicts > 0 then
    vim.notify("java-menu.nvim: " .. table.concat(conflicts, "; "), vim.log.levels.WARN)
  end
end

return M
