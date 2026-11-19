-- 7B.1: scaffolding de projetos (Plain Java e Maven). Cobre o CORE puro
-- (validação, geração em staging, publicação com rollback) e o SHELL
-- interativo (cancelamento sem escrita, resumo, criação e falha de validação).
-- Nada aqui toca JDTLS, cwd global ou arquivos fora dos temporários do spec.
--
-- Run:
--   tests/java_menu/run.sh fast

local create = require("java_menu.create")

local real_notify = vim.notify
local notices = {}
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = tostring(msg), level = level }
end

local real_select = vim.ui.select
local real_input = vim.ui.input

local dirs = {}
local function new_parent(label)
  local dir = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-create-" .. label)
  vim.fn.mkdir(dir, "p")
  dirs[#dirs + 1] = dir
  return dir
end

local function entries(dir)
  return vim.fn.readdir(dir) or {}
end

local function exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

local function plain_opts(parent, name)
  return { kind = "plain", parent = parent, name = name or "app", pkg = "com.example.app", release = "21" }
end

local function maven_opts(parent, name)
  return {
    kind = "maven",
    parent = parent,
    name = name or "ma",
    pkg = "com.example.app",
    release = "21",
    group = "com.example",
    artifact = "ma",
  }
end

-- ---------- 1. _validate: opções válidas ----------

local valid_parent = new_parent("valid")
assert(create._validate(plain_opts(valid_parent)) == nil, "opts plain válidas foram rejeitadas")
assert(create._validate(maven_opts(valid_parent)) == nil, "opts maven válidas foram rejeitadas")

-- ---------- 2. _validate: nome inválido ----------

for _, bad in ipairs({ "", "a/b", "..", "../evil", "x/y", ".hidden", "trailing." }) do
  local reason = create._validate(plain_opts(valid_parent, bad))
  assert(reason ~= nil and reason:find("invalid project name", 1, true), "nome '" .. bad .. "' não rejeitado: " .. tostring(reason))
end

-- ---------- 3. _validate: package e release inválidos ----------

for _, bad in ipairs({ "", "1abc", "a..b", "a.b.", ".a", "com.class" }) do
  local opts = plain_opts(valid_parent)
  opts.pkg = bad
  local reason = create._validate(opts)
  assert(reason ~= nil and reason:find("invalid package", 1, true), "package '" .. bad .. "' não rejeitado: " .. tostring(reason))
end

local bad_release = plain_opts(valid_parent)
bad_release.release = "abc"
assert(create._validate(bad_release):find("invalid Java release", 1, true), "release inválido não rejeitado")

-- ---------- 4. _validate: parent ----------

local relative = plain_opts("relative/dir")
assert(create._validate(relative):find("must be absolute", 1, true), "parent relativo não rejeitado")

local missing = plain_opts(valid_parent .. "/missing")
assert(create._validate(missing):find("does not exist", 1, true), "parent inexistente não rejeitado")

local parent_file = valid_parent .. "/afile.txt"
vim.fn.writefile({ "x" }, parent_file)
assert(create._validate(plain_opts(parent_file)):find("not a directory", 1, true), "parent arquivo não rejeitado")

-- ---------- 5. _validate: target existente / symlink / staging ----------

local occupied = valid_parent .. "/occupied"
vim.fn.mkdir(occupied, "p")
vim.fn.writefile({ "x" }, occupied .. "/keep.txt")
assert(create._validate(plain_opts(valid_parent, "occupied")):find("not empty", 1, true), "target não vazio foi aceito")

vim.fn.mkdir(valid_parent .. "/ready", "p")
assert(create._validate(plain_opts(valid_parent, "ready")) == nil, "target vazio deveria ser aceito")

local real_dir = valid_parent .. "/real-dir"
vim.fn.mkdir(real_dir, "p")
local link_ok = vim.uv.fs_symlink(real_dir, valid_parent .. "/link")
assert(link_ok, "não foi possível criar o symlink de teste")
assert(create._validate(plain_opts(valid_parent, "link")):find("symlink", 1, true), "target symlink foi aceito")

vim.fn.mkdir(valid_parent .. "/.staged.java-menu-stage", "p")
local staged = plain_opts(valid_parent, "staged")
assert(create._validate(staged):find("stale staging directory", 1, true), "staging pré-existente não rejeitado")

-- ---------- 6. _validate: maven group/artifact ----------

local bad_group = maven_opts(valid_parent)
bad_group.group = "com.1bad"
assert(create._validate(bad_group):find("invalid groupId", 1, true), "groupId inválido não rejeitado")
local bad_artifact = maven_opts(valid_parent)
bad_artifact.artifact = " bad"
assert(create._validate(bad_artifact):find("invalid artifactId", 1, true), "artifactId inválido não rejeitado")

-- ---------- 7. happy path plain ----------

local plain_parent = new_parent("plain")
local plain = plain_opts(plain_parent, "app")
local ok, err = create._run(plain)
assert(ok, "criação plain falhou: " .. tostring(err))

local plain_target = plain_parent .. "/app"
local main_path = plain_target .. "/src/main/java/com/example/app/Main.java"
assert(vim.fn.filereadable(main_path) == 1, "Main.java não criado em " .. main_path)
local main_text = table.concat(vim.fn.readfile(main_path), "\n")
assert(main_text:find("package com.example.app;", 1, true), "package ausente no Main.java:\n" .. main_text)
assert(main_text:find("static void main", 1, true), "método main ausente no Main.java:\n" .. main_text)
assert(vim.deep_equal(entries(plain_parent), { "app" }), "o parent tem lixo além do projeto: " .. vim.inspect(entries(plain_parent)))
assert(not exists(plain_parent .. "/.app.java-menu-stage"), "staging não removido")

-- ---------- 8. happy path maven ----------

local maven_parent = new_parent("maven")
local maven = maven_opts(maven_parent, "ma")
ok, err = create._run(maven)
assert(ok, "criação maven falhou: " .. tostring(err))

local maven_target = maven_parent .. "/ma"
local pom_path = maven_target .. "/pom.xml"
assert(vim.fn.filereadable(pom_path) == 1, "pom.xml não criado")
local pom = table.concat(vim.fn.readfile(pom_path), "\n")
assert(pom:find("<groupId>com.example</groupId>", 1, true), "groupId ausente no pom")
assert(pom:find("<artifactId>ma</artifactId>", 1, true), "artifactId ausente no pom")
assert(pom:find("<packaging>jar</packaging>", 1, true), "packaging jar ausente no pom")
assert(pom:find("<maven.compiler.release>21</maven.compiler.release>", 1, true), "release ausente no pom")
assert(not pom:find("<dependencies>", 1, true), "pom não deveria ter dependências")
assert(vim.fn.isdirectory(maven_target .. "/src/main/resources") == 1, "src/main/resources ausente")
assert(vim.fn.isdirectory(maven_target .. "/src/test/java/com/example/app") == 1, "src/test/java/<pkg> ausente")
assert(vim.fn.filereadable(maven_target .. "/src/main/java/com/example/app/Main.java") == 1, "Main.java maven ausente")

-- ---------- 9. shell: cancelar no primeiro passo não escreve nada ----------

local cancel_parent = new_parent("cancel")
vim.ui.select = function(_, _, on_choice)
  on_choice(nil)
end
vim.ui.input = function(_, on_confirm)
  on_confirm("não deveria ser usado")
end
create.create()
assert(not exists(cancel_parent .. "/cancelled"), "cancelamento criou o target")
local cancel_entries = entries(cancel_parent)
assert(#cancel_entries == 0, "cancelamento deixou lixo no parent: " .. vim.inspect(cancel_entries))

-- ---------- 10. shell: caminho feliz completo ----------

local shell_parent = new_parent("shell")
local selects = { "Plain Java", "✔ Create project" }
local select_index = 0
vim.ui.select = function(_, _, on_choice)
  select_index = select_index + 1
  on_choice(selects[select_index])
end
local inputs = { shell_parent, "shellapp", "com.shell", "21" }
local input_index = 0
vim.ui.input = function(_, on_confirm)
  input_index = input_index + 1
  on_confirm(inputs[input_index])
end
create.create()

local shell_target = shell_parent .. "/shellapp"
assert(vim.fn.filereadable(shell_target .. "/src/main/java/com/shell/Main.java") == 1, "shell não criou a estrutura")
assert(
  vim.api.nvim_buf_get_name(0):find("Main.java", 1, true) ~= nil,
  "Main.java criado não foi aberto no buffer atual: " .. vim.api.nvim_buf_get_name(0)
)

-- ---------- 11. shell: validação falha aborta sem escrita ----------

local invalid_parent = new_parent("invalid")
notices = {}
select_index = 0
selects = { "Plain Java" }
input_index = 0
inputs = { invalid_parent, "bad/name", "com.shell", "21" }
create.create()
assert(#notices > 0, "falha de validação não notificou")
local last = notices[#notices]
assert(last.msg:find("invalid project name", 1, true), "motivo ausente na notificação: " .. last.msg)
assert(last.level == vim.log.levels.WARN, "validação deveria notificar como WARN")
assert(#entries(invalid_parent) == 0, "validação falhou mas escreveu: " .. vim.inspect(entries(invalid_parent)))

-- ---------- 12. _run com geração forçada a falhar ----------

local broken_parent = new_parent("broken")
local original_body = create._main_body
create._main_body = function()
  error("boom na geração")
end
local broken = plain_opts(broken_parent, "broken")
ok, err = create._run(broken)
create._main_body = original_body
assert(not ok, "geração quebrada não falhou")
assert(tostring(err):find("generation failed", 1, true), "erro de geração não é claro: " .. tostring(err))
assert(not exists(broken_parent .. "/broken"), "target criado apesar da falha")
assert(#entries(broken_parent) == 0, "staging sobrou após a falha: " .. vim.inspect(entries(broken_parent)))

-- ---------- 13. _publish em target pré-existente vazio ----------

local publish_parent = new_parent("publish")
local publish_target = publish_parent .. "/dest"
vim.fn.mkdir(publish_target, "p")
vim.fn.writefile({ "mantido" }, publish_target .. "/keep.txt")
local stage = publish_parent .. "/stage"
vim.fn.mkdir(stage .. "/src", "p")
vim.fn.writefile({ "class Main {}" }, stage .. "/src/Main.java")

local published, publish_err, moved = create._publish(stage, publish_target)
assert(published, "publish em target vazio falhou: " .. tostring(publish_err))
assert(vim.deep_equal(moved, { "src" }), "entradas movidas inesperadas: " .. vim.inspect(moved))
assert(vim.fn.filereadable(publish_target .. "/src/Main.java") == 1, "conteúdo não foi movido para o target")
assert(vim.fn.filereadable(publish_target .. "/keep.txt") == 1, "entrada pré-existente foi removida")
assert(not exists(stage), "staging não foi removido após publicar")

-- ---------- restauração ----------

vim.ui.select = real_select
vim.ui.input = real_input
vim.notify = real_notify
for _, dir in ipairs(dirs) do
  vim.fn.delete(dir, "rf")
end

print("create_project_spec: OK (validação, staging, rollback, shell e cancelamento)")
vim.cmd("qa!")
