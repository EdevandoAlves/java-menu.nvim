-- B2: isolamento de Build/Stop/Output por projeto. Processos reais (mvnw
-- simulado com sleep), encerramento real da árvore, processo externo
-- intocado, repeat por projeto e build Maven aninhado real (-pl/-am).
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "luafile tests/java_menu/build_isolation_spec.lua" -c qa

local ui = require("java_menu.ui")
local build = require("java_menu.build")
local fixtures = require("tests.java_menu.fixtures")

-- jc.settings simulado (o build grava/lê o build-last por projeto)
local jcstore = {}
package.loaded["jc.settings"] = {
  read_project = function(_, name)
    return jcstore[name]
  end,
  write_project = function(_, name, value)
    jcstore[name] = value
  end,
}

-- dois projetos com mvnw "dorminhoco" (processo real controlável)
local function sleepy_project(label)
  local root, _ = fixtures.maven_project("iso-" .. label, "com.iso." .. label, "Main")
  local mvnw = root .. "/mvnw"
  fixtures.write(mvnw, { "#!/bin/sh", "exec sleep 60" })
  vim.fn.system({ "chmod", "+x", mvnw })
  assert(vim.fn.executable(mvnw) == 1, "mvnw de teste não ficou executável")
  return root
end

local root_a = sleepy_project("alpha")
local root_b = sleepy_project("beta")

-- stubs de UI
local notices = {}
local menu_entries, menu_cb
local pick_script = {} -- fila de escolhas para ui.pick_one
local last_pick_prompt, last_pick_labels

ui.notify = function(msg, _)
  notices[#notices + 1] = tostring(msg)
end
ui.ask = function(_, _, cb)
  cb("")
end
ui.menu = function(entries, _, on_choice)
  menu_entries, menu_cb = entries, on_choice
end
ui.pick_one = function(items, prompt, on_choice)
  last_pick_prompt, last_pick_labels = prompt, items
  local choice = table.remove(pick_script, 1)
  if choice then
    for _, item in ipairs(items) do
      if item:find(choice, 1, true) then
        return on_choice(item)
      end
    end
  end
end

local function has_notice(text)
  for _, notice in ipairs(notices) do
    if notice:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function entry(key)
  for _, item in ipairs(menu_entries or {}) do
    if item.key == key then
      return item
    end
  end
end

local function pid_alive(pid)
  vim.fn.system({ "kill", "-0", tostring(pid) })
  return vim.v.shell_error == 0
end

local function open_main(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "java"
end

-- 1. build no projeto A (processo real, estado com origem)
open_main(root_a .. "/src/main/java/com/iso/alpha/Main.java")
build.build()
local compile_entry = entry("compile")
assert(compile_entry.enabled, "Compile deveria estar habilitado no projeto A")
menu_cb(compile_entry)
assert(
  fixtures.wait_for(10000, function()
    return build._state.running and build._state.job ~= nil
  end),
  "processo do projeto A não iniciou"
)
assert(build._state.root == vim.uv.fs_realpath(root_a), "estado não registrou o projeto de origem A")
assert(build._state.cwd == vim.uv.fs_realpath(root_a), "cwd do processo divergiu do projeto A")
assert(build._state.cmd[1] == root_a .. "/mvnw", "runner do projeto A divergiu")
local pid_a = vim.fn.jobpid(build._state.job)
assert(pid_alive(pid_a), "processo do projeto A não está vivo")

-- 2. troca para o projeto B: o menu não trata o processo de A como de B
open_main(root_b .. "/src/main/java/com/iso/beta/Main.java")
notices = {}
build.build()
local stop_entry = entry("stop")
assert(stop_entry.enabled, "Stop deveria aparecer com processo ativo (de outro projeto)")
assert(stop_entry.label:find("alpha", 1, true), "Stop não identifica a origem: " .. stop_entry.label)
assert(stop_entry.reason:find("outro projeto", 1, true), "Stop não avisa que é de outro projeto")
local output_entry = entry("output")
assert(output_entry.label:find("alpha", 1, true), "Show Last Output não identifica a origem")
menu_cb(stop_entry)
assert(last_pick_prompt:find("outro projeto", 1, true), "Stop entre projetos deveria pedir confirmação")
pick_script = { "não" }
-- a escolha "não" acontece dentro do pick_one; reabre o fluxo
build.build()
menu_cb(entry("stop"))
assert(build._state.running, "processo de A foi encerrado sem escolha explícita")
assert(pid_alive(pid_a), "processo de A morreu sem confirmação")

-- 3. escolha explícita "sim" encerra o processo de A
pick_script = { "sim" }
build.build()
menu_cb(entry("stop"))
assert(
  fixtures.wait_for(10000, function()
    return not build._state.running
  end),
  "processo de A não encerrou após confirmação"
)
assert(not pid_alive(pid_a), "árvore do processo de A sobreviveu ao Stop")
assert(has_notice("alpha encerrado"), "encerramento entre projetos não avisou a origem")

-- 4. processo externo (não iniciado pelo menu) nunca é encerrado
local external = vim.fn.jobstart({ "sleep", "30" })
assert(external > 0 and pid_alive(vim.fn.jobpid(external)), "processo externo de teste não iniciou")
open_main(root_a .. "/src/main/java/com/iso/alpha/Main.java")
build.build()
menu_cb(entry("compile"))
assert(
  fixtures.wait_for(10000, function()
    return build._state.running
  end),
  "segundo build em A não iniciou"
)
pick_script = { "sim" }
build.build()
menu_cb(entry("stop"))
assert(
  fixtures.wait_for(10000, function()
    return not build._state.running
  end),
  "processo do menu não encerrou"
)
assert(pid_alive(vim.fn.jobpid(external)), "Stop do menu encerrou processo externo!")
vim.fn.jobstop(external)

-- 5. Repeat Last por projeto: args de A nunca rodam em B
open_main(root_b .. "/src/main/java/com/iso/beta/Main.java")
build.build()
local repeat_entry = entry("repeat")
assert(repeat_entry.enabled == false, "Repeat deveria estar desabilitado em B sem build prévio")
assert(repeat_entry.reason:find("nenhum build anterior", 1, true), "motivo do repeat divergiu")
-- build em B registra o last de B
menu_cb(entry("compile"))
assert(
  fixtures.wait_for(10000, function()
    return build._state.running
  end),
  "build de B não iniciou"
)
pick_script = { "sim" }
build.build()
menu_cb(entry("stop"))
assert(
  fixtures.wait_for(10000, function()
    return not build._state.running
  end),
  "build de B não encerrou"
)
-- valor cruzado no jc não pode vencer o registro por raiz
jcstore["build-last"] = "clean"
open_main(root_a .. "/src/main/java/com/iso/alpha/Main.java")
build.build()
menu_cb(entry("repeat"))
assert(
  fixtures.wait_for(10000, function()
    return build._state.running
  end),
  "repeat em A não iniciou"
)
assert(build._state.cwd == vim.uv.fs_realpath(root_a), "repeat rodou fora do projeto A")
assert(build._state.cmd[1] == root_a .. "/mvnw", "repeat usou runner de outro projeto")
assert(build._state.cmd[2] == "compile", "repeat deveria usar os args do projeto A: " .. vim.inspect(build._state.cmd))
build.build()
menu_cb(entry("stop"))
assert(
  fixtures.wait_for(10000, function()
    return not build._state.running
  end),
  "repeat de A não encerrou"
)

-- 6. build Maven aninhado real com -pl/-am (descoberta M3 alimentando o B2)
local nested = fixtures.maven_nested("build")
open_main(nested .. "/pom.xml")
build.build()
-- mvn do PATH (sem mvnw no aninhado); módulo via picker
pick_script = { "services/api" }
menu_cb(entry("compile"))
assert(
  fixtures.wait_for(10000, function()
    return build._state.running
  end),
  "build aninhado não iniciou: " .. table.concat(notices, "; ")
)
assert(build._state.cwd == vim.uv.fs_realpath(nested), "build aninhado rodou fora do agregador")
assert(build._state.cmd[1] == "mvn", "runner deveria ser o mvn do PATH")
assert(
  build._state.cmd[2] == "-pl" and build._state.cmd[3] == "services/api" and build._state.cmd[4] == "-am",
  "escopo -pl/-am divergiu: " .. vim.inspect(build._state.cmd)
)
assert(
  fixtures.wait_for(120000, function()
    return not build._state.running
  end),
  "mvn -pl services/api -am compile não terminou"
)
assert(build._state.status == "success", "build aninhado real falhou: status " .. build._state.status)

print("build_isolation_spec: OK")
vim.cmd("qa!")
