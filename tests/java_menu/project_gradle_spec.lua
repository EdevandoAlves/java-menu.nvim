-- M3 (Gradle): includes estáticos do settings.gradle(.kts), projectDir
-- explícito, declaração dinâmica → descoberta parcial sem inventar módulos,
-- e distinção entre caminho lógico e físico (achado M3 / Build Gradle).
--
-- Sem Gradle instalado, estes testes são de descoberta estática (a execução
-- real de tarefas Gradle é validada apenas quando há wrapper/binário).
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "luafile tests/java_menu/project_gradle_spec.lua" -c qa

local project = require("java_menu.project")
local build = require("java_menu.build")
local fixtures = require("tests.java_menu.fixtures")

local function rels(root, mods)
  local out = {}
  for _, m in ipairs(mods) do
    out[#out + 1] = vim.fs.relpath(root, m) or m
  end
  table.sort(out)
  return out
end

-- 1. include simples (com e sem dois-pontos iniciais)
local simple = fixtures.gradle_project("simple", {
  "rootProject.name = 'simple'",
  "include(':app')",
}, { src_dirs = { "app/src/main/java" } })
local mods_simple = project.modules(simple)
assert(#mods_simple == 2, "include simples: esperava root+app, recebi " .. #mods_simple)
assert(project.discovery_limitation(simple) == nil, "settings estático não deveria reportar limitação")
vim.cmd("edit " .. vim.fn.fnameescape(simple .. "/app/src/main/java/.keep"))
assert(project.root(0) == vim.uv.fs_realpath(simple), "root do subprojeto Gradle divergiu")

-- 2. include aninhado, sem colons iniciais, múltiplos por chamada, aspas simples
local nested = fixtures.gradle_project("nested", {
  "include(':services:api')",
  "include 'services:worker'",
  'include(":libs:core", ":tools")',
}, { src_dirs = { "services/api/src/main/java", "services/worker/src/main/java", "libs/core", "tools" } })
local rels_nested = rels(nested, project.modules(nested))
assert(
  vim.tbl_contains(rels_nested, "services/api")
    and vim.tbl_contains(rels_nested, "services/worker")
    and vim.tbl_contains(rels_nested, "libs/core")
    and vim.tbl_contains(rels_nested, "tools"),
  "includes aninhados incompletos: " .. vim.inspect(rels_nested)
)
assert(#rels_nested == 5, "esperava raiz + 4 módulos declarados, recebi " .. #rels_nested)

-- include declarado sem diretório não vira módulo fantasma
local phantom = fixtures.gradle_project("phantom", { "include(':missing')" }, {})
assert(#project.modules(phantom) == 1, "include sem diretório inventou módulo")

-- comentários não contam
local commented = fixtures.gradle_project("commented", {
  "// include(':ghost')",
  "/* include(':ghost2') */",
}, {})
assert(#project.modules(commented) == 1, "include comentado virou módulo")

-- 3. settings.gradle.kts (mesma sintaxe)
local kts = fixtures.gradle_project("kts", {
  'rootProject.name = "kts"',
  'include(":services:api")',
}, { kts = true, src_dirs = { "services/api" } })
assert(vim.tbl_contains(rels(kts, project.modules(kts)), "services/api"), "settings.gradle.kts não interpretado")

-- 4. projectDir estático reposiciona o módulo; caminho lógico continua :custom
local custom = fixtures.gradle_project("custom", {
  "include(':custom')",
  "project(':custom').projectDir = file('libs/custom-dir')",
  "include(':normal')",
}, { src_dirs = { "libs/custom-dir", "normal" } })
local rels_custom = rels(custom, project.modules(custom))
assert(vim.tbl_contains(rels_custom, "libs/custom-dir"), "projectDir estático não resolvido")
assert(vim.tbl_contains(rels_custom, "normal"), "include normal perdido com projectDir presente")
assert(
  project.gradle_path(custom, custom .. "/libs/custom-dir") == ":custom",
  "caminho lógico do projectDir divergiu: " .. project.gradle_path(custom, custom .. "/libs/custom-dir")
)

-- 5. projectDir para fora do agregador não entra e marca descoberta parcial
local outside = fixtures.gradle_project("outside", {
  "include(':far')",
  "project(':far').projectDir = file('../far-away')",
})
vim.fn.mkdir(vim.fs.dirname(outside) .. "/far-away", "p") -- destino real fora do root
local mods_outside = project.modules(outside)
assert(#mods_outside == 1, "projectDir fora do agregador virou módulo")
assert(project.discovery_limitation(outside) ~= nil, "projectDir externo deveria marcar limitação")

-- 6. declaração dinâmica: parcial, sem inventar módulos
local dynamic = fixtures.gradle_project("dynamic", {
  'val suffix = "x"',
  "include(':dyn' + suffix)",
  'include(":keepme")',
  "project(':moved').projectDir = file(\"$rootDir/moved\")",
}, { src_dirs = { "keepme", "moved", "dynx" } })
local rels_dynamic = rels(dynamic, project.modules(dynamic))
assert(vim.tbl_contains(rels_dynamic, "keepme"), "include estático perdido junto com o dinâmico")
assert(not vim.tbl_contains(rels_dynamic, "dyn"), "literal de include dinâmico virou módulo")
assert(not vim.tbl_contains(rels_dynamic, "moved"), "projectDir interpolado virou módulo")
local note = project.discovery_limitation(dynamic)
assert(note ~= nil and note:find("parcial", 1, true), "descoberta dinâmica deveria ser parcial: " .. tostring(note))
assert(note:find("Gradle", 1, true), "nota não menciona Gradle: " .. note)

-- 7. caminho lógico × caminho físico (consumidor de Build)
assert(project.gradle_path(nested, nested .. "/services/api") == ":services:api", "caminho lógico divergiu")
assert(
  vim.deep_equal(
    build._scope_args("gradle", nested, nested .. "/services/api", { "compile" }),
    { ":services:api:compile" }
  ),
  "scope_args Gradle deveria usar o caminho lógico: "
    .. vim.inspect(build._scope_args("gradle", nested, nested .. "/services/api", { "compile" }))
)
assert(
  vim.deep_equal(
    build._scope_args("maven", nested, nested .. "/services/api", { "compile" }),
    { "-pl", "services/api", "-am", "compile" }
  ),
  "scope_args Maven divergiu"
)
-- módulo = raiz: sem escopo (single-module preservado)
assert(
  vim.deep_equal(build._scope_args("maven", simple, simple, { "compile" }), { "compile" }),
  "escopo indevido para a raiz"
)

print("project_gradle_spec: OK")
vim.cmd("qa!")
