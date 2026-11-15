-- B4: workspace JDTLS exclusivo por projeto (identificador estável por caminho
-- canônico completo). Cenários C e D da fase 6B.3A em nível de unidade.
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "luafile tests/java_menu/project_workspace_spec.lua" -c qa

local project = require("java_menu.project")

local base = vim.fs.normalize(vim.fn.tempname())
local function make_project(rel)
  local path = base .. "/" .. rel
  vim.fn.mkdir(path .. "/src", "p")
  return path
end

-- C. dois projetos com o mesmo basename em paths distintos não colidem
local a = make_project("wsa/alpha")
local b = make_project("wsb/alpha")
local id_a, id_b = project.workspace_id(a), project.workspace_id(b)
assert(id_a ~= id_b, "projetos com o mesmo basename colidiram: " .. id_a)
assert(project.workspace_dir(a) ~= project.workspace_dir(b), "diretórios -data colidiram")

-- o identificador não é mais o basename puro (esquema antigo)
assert(id_a ~= "alpha" and id_b ~= "alpha", "identificador voltou a ser o basename")
assert(id_a:find("wsa", 1, true) and id_a:find("alpha", 1, true), "identificador não inclui o caminho completo")

-- D. reabrir o mesmo projeto preserva a identidade
assert(project.workspace_id(a) == id_a, "identificador instável entre chamadas")
assert(project.workspace_dir(a) == project.workspace_dir(a), "workspace_dir instável")
assert(
  project.workspace_dir(a) == vim.fs.joinpath(vim.fn.stdpath("data"), "jdtls", id_a),
  "workspace_dir fora do padrão"
)

-- caminho canônico: symlink para o mesmo projeto → mesma identidade
local link = base .. "/wsa/alpha-link"
os.remove(link)
assert(vim.uv.fs_symlink(a, link), "não consegui criar symlink")
assert(project.workspace_id(link) == id_a, "symlink gerou identidade diferente")

-- escape injetivo: `w_x`, `w/x` e `w%x` geram identificadores distintos
local u = make_project("w_x")
local s = make_project("w/x")
local p = make_project("w%x")
assert(project.workspace_id(u) ~= project.workspace_id(s), "escape não injetivo (underscore vs barra)")
assert(project.workspace_id(s) ~= project.workspace_id(p), "escape não injetivo (barra vs % literal)")
assert(project.workspace_id(u) ~= project.workspace_id(p), "escape não injetivo (underscore vs % literal)")

-- cliente_workspace_dir: extrai o -data do cmd do cliente ativo
local fake = { config = { cmd = { "jdtls", "-data", "/x/y", "other" } } }
assert(project.client_workspace_dir(fake) == "/x/y", "não extraiu o -data do cmd")
assert(project.client_workspace_dir({ config = { cmd = { "jdtls" } } }) == nil, "-data ausente deveria devolver nil")
assert(project.client_workspace_dir({ config = {} }) == nil, "cmd ausente deveria devolver nil")
assert(project.client_workspace_dir(nil) == nil, "cliente nil deveria devolver nil")

print("project_workspace_spec: OK")
vim.cmd("qa!")
