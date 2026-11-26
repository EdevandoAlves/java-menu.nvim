-- 7B.1: menu Project (<leader>jp). Registro no grupo de atalhos, lazy-load,
-- grupos desabilitáveis, conflito preservado e as entradas do menu com
-- enabled/reason (sem projeto × dentro de projeto Maven). O menu é read-only:
-- cancelar não cria arquivo nenhum.
--
-- Run:
--   tests/java_menu/run.sh fast

local jm = require("java_menu")
local fixtures = require("tests.java_menu.fixtures")

local prefix = "<leader>j"

-- captura de notificações (restaurado ao final — isolamento)
local real_notify = vim.notify
local notices = {}
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = tostring(msg), level = level }
end
local function last_notice()
  return notices[#notices] and notices[#notices].msg or ""
end

-- stub do vim.ui.select (fallback sem Snacks): captura as entradas e cancela
local real_select = vim.ui.select
local captured = {}
local function stub_select(choice)
  vim.ui.select = function(items, opts, on_choice)
    captured[#captured + 1] = { items = vim.deepcopy(items), prompt = opts and opts.prompt }
    on_choice(choice)
  end
end
local function labels(i)
  return captured[i] and table.concat(captured[i].items, "\n") or ""
end

-- ---------- 1. lazy-load: setup não carrega o módulo ----------

assert(package.loaded["java_menu.project_menu"] == nil, "project_menu carregado antes do setup")

jm.setup({ prefix = prefix })

local m = vim.fn.maparg(prefix .. "p", "n", false, true)
assert(type(m) == "table" and not vim.tbl_isempty(m), "<leader>jp não registrado")
assert(m.desc == "Java Menu: Project", "desc inesperada em <leader>jp: " .. tostring(m.desc))
assert(vim.fn.exists(":JavaMenu") == 2, "comando :JavaMenu não registrado")
assert(package.loaded["java_menu.project_menu"] == nil, "setup carregou project_menu eager")

-- ---------- 2. menu sem projeto (cwd vazio, buffer sem nome) ----------

local empty = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(empty, "p")
local prev_cwd = vim.uv.cwd()
vim.cmd.cd(vim.fn.fnameescape(empty))

stub_select(nil)
jm.trigger("project")

assert(package.loaded["java_menu.project_menu"] ~= nil, "trigger('project') não carregou o módulo")
assert(#captured == 1, "o fallback vim.ui.select não foi usado (" .. #captured .. " chamadas)")
assert(captured[1].prompt == "Java: Project", "prompt do menu Project divergiu: " .. tostring(captured[1].prompt))

local text = labels(1)
assert(
  text:find("New Project", 1, true) and not text:find("New Project[^\n]*(unavailable", 1),
  "New Project deveria estar habilitado"
)
local info_line
for line in text:gmatch("[^\n]+") do
  if line:find("Project Info", 1, true) then
    info_line = line
  end
end
assert(
  info_line and info_line:find("(unavailable: no Java project", 1, true),
  "Project Info deveria estar desabilitado: " .. tostring(info_line)
)
local deps_line
for line in text:gmatch("[^\n]+") do
  if line:find("Dependencies", 1, true) then
    deps_line = line
  end
end
assert(
  deps_line and deps_line:find("(unavailable: no Maven/Gradle project", 1, true),
  "Dependencies deveria estar desabilitado sem projeto: " .. tostring(deps_line)
)
local spring_line
for line in text:gmatch("[^\n]+") do
  if line:find("Open Spring Configuration", 1, true) then
    spring_line = line
  end
end
assert(
  spring_line and spring_line:find("(unavailable: no Maven/Gradle project", 1, true),
  "Open Spring Configuration deveria estar desabilitado sem projeto: " .. tostring(spring_line)
)
local env_line
for line in text:gmatch("[^\n]+") do
  if line:find("Environment", 1, true) then
    env_line = line
  end
end
assert(
  env_line and not env_line:find("(unavailable", 1, true),
  "Environment deveria estar habilitado: " .. tostring(env_line)
)

-- cancelar (cb nil) não pode criar nada no cwd vazio
assert(#vim.fn.readdir(empty) == 0, "o menu criou arquivos no diretório vazio: " .. vim.inspect(vim.fn.readdir(empty)))

-- ---------- 3. menu dentro de um projeto Maven: Info habilitado ----------

local root, main_path = fixtures.maven_project("pmenu", "com.pmenu", "App")
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, main_path)
vim.bo[buf].filetype = "java"
vim.api.nvim_set_current_buf(buf)

captured = {}
jm.trigger("project")
assert(#captured == 1, "segunda chamada do menu não foi capturada")
local project_info
for line in labels(1):gmatch("[^\n]+") do
  if line:find("Project Info", 1, true) then
    project_info = line
  end
end
assert(
  project_info and not project_info:find("(unavailable", 1, true),
  "Project Info deveria estar habilitado em projeto Maven: " .. tostring(project_info)
)

local deps_project
for line in labels(1):gmatch("[^\n]+") do
  if line:find("Dependencies", 1, true) then
    deps_project = line
  end
end
assert(
  deps_project and not deps_project:find("(unavailable", 1, true),
  "Dependencies deveria estar habilitado em projeto Maven: " .. tostring(deps_project)
)

-- ---------- 4. grupos desabilitáveis ----------

jm.setup({ prefix = prefix, groups = { project = false } })
assert(vim.fn.maparg(prefix .. "p", "n") == "", "grupo project desabilitado continua mapeado")
assert(
  vim.fn.maparg(prefix .. "b", "n", false, true).desc == "Java Menu: Build/Run",
  "desabilitar project afetou o grupo build"
)
jm.setup({ prefix = prefix, groups = { project = true } })
assert(vim.fn.maparg(prefix .. "p", "n", false, true).desc == "Java Menu: Project", "grupo project não voltou")

-- ---------- 5. conflito preserva o mapa de terceiros ----------

vim.keymap.del("n", prefix .. "p")
vim.keymap.set("n", prefix .. "p", function() end, { desc = "meu mapa pessoal" })
notices = {}
jm.setup({ prefix = prefix })
local mine = vim.fn.maparg(prefix .. "p", "n", false, true)
assert(type(mine) == "table" and mine.desc == "meu mapa pessoal", "atalho de terceiros foi sobrescrito")
assert(
  last_notice():find("conflict", 1, true) ~= nil and last_notice():find(prefix .. "p", 1, true) ~= nil,
  "conflito de <leader>jp não informado: " .. last_notice()
)

-- ---------- restauração ----------

vim.ui.select = real_select
vim.notify = real_notify
vim.cmd.cd(vim.fn.fnameescape(prev_cwd))
vim.fn.delete(empty, "rf")
vim.fn.delete(root, "rf")

print("project_menu_spec: OK (lazy, entradas com reason, menus sem/com projeto, grupos e conflito)")
vim.cmd("qa!")
