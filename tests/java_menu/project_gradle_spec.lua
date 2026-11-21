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
assert(note ~= nil and note:find("partial", 1, true), "descoberta dinâmica deveria ser parcial: " .. tostring(note))
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

-- 8. Safe multi-line, semicolons, comments inside strings/URLs, settings.include, deeply nested
local multiline = fixtures.gradle_project("multiline", {
  "pluginManagement {",
  "  repositories {",
  '    maven { url = uri("https://repo.example.com/maven2") }',
  "  }",
  "}",
  'rootProject.name = "include-projectDir-app"',
  "include(",
  '  ":app", // primary app',
  '  /* ":disabled", */',
  '  ":services:api:impl",',
  ")",
  "include ':cli', // bare multi-line",
  "  ':shared:model'",
  "include(':one'); include(':two');",
  "settings.include(':three')",
}, {
  kts = true,
  src_dirs = {
    "app/src/main/java",
    "services/api/impl/src/main/java",
    "cli",
    "shared/model",
    "one",
    "two",
    "three",
  },
})
fixtures.write(multiline .. "/services/api/impl/build.gradle.kts", { "// impl" })
fixtures.write(multiline .. "/services/build.gradle.kts", { "// intermediate" })
local rels_ml = rels(multiline, project.modules(multiline))
for _, expected in ipairs({ "app", "services/api/impl", "cli", "shared/model", "one", "two", "three" }) do
  assert(
    vim.tbl_contains(rels_ml, expected),
    "safe multi-line/nested missing: " .. expected .. " in " .. vim.inspect(rels_ml)
  )
end
assert(#rels_ml == 8, "expected root + 7 modules, got " .. #rels_ml .. ": " .. vim.inspect(rels_ml))
assert(
  project.discovery_limitation(multiline) == nil,
  "static multiline should have no limitation: " .. tostring(project.discovery_limitation(multiline))
)
vim.cmd("edit " .. vim.fn.fnameescape(multiline .. "/services/api/impl/src/main/java/.keep"))
assert(
  project.root(0) == vim.uv.fs_realpath(multiline),
  "deeply nested Gradle module root diverged: " .. tostring(project.root(0))
)

-- 9. Additional safe static projectDir syntaxes (Groovy & Kotlin DSL)
local pdir = fixtures.gradle_project("pdir-variants", {
  "include(':bare', ':newroot', ':ktset', ':rpdir', ':resolved', ':ml', ':dot', ':blk', ':appblk', ':withblk', ':fp', ':services:api')",
  "project(':bare').projectDir = file 'libs/bare-dir'",
  "project(':newroot').projectDir = new File(rootDir, 'libs/new-file-root')",
  'project(":ktset").projectDir = File(settingsDir, "libs/kt-file-settings")',
  "project(':rpdir').projectDir = new File(rootProject.projectDir, 'libs/root-proj')",
  'project(":resolved").projectDir = rootDir.resolve("libs/resolved")',
  "project(':ml').projectDir =",
  "  file('libs/ml-dir')",
  "project(':dot')",
  "  .projectDir = file('libs/dot-dir')",
  "project(':blk') {",
  "  projectDir = file('libs/blk-dir')",
  "}",
  'project(":appblk").apply {',
  '  projectDir = File(rootDir, "libs/apply-dir")',
  "}",
  'with(project(":withblk")) {',
  '  projectDir = file("libs/with-dir")',
  "}",
  'findProject(":fp")?.projectDir = file("libs/fp-dir")',
  'findProject(":not-included")?.projectDir = file("libs/ignored-dir")',
  'project(":services:api").projectDir = file("custom/api")',
}, {
  src_dirs = {
    "libs/bare-dir",
    "libs/new-file-root",
    "libs/kt-file-settings",
    "libs/root-proj",
    "libs/resolved",
    "libs/ml-dir",
    "libs/dot-dir",
    "libs/blk-dir",
    "libs/apply-dir",
    "libs/with-dir",
    "libs/fp-dir",
    "libs/ignored-dir",
    "custom/api",
  },
})
local rels_pdir = rels(pdir, project.modules(pdir))
for _, expected in ipairs({
  "libs/bare-dir",
  "libs/new-file-root",
  "libs/kt-file-settings",
  "libs/root-proj",
  "libs/resolved",
  "libs/ml-dir",
  "libs/dot-dir",
  "libs/blk-dir",
  "libs/apply-dir",
  "libs/with-dir",
  "libs/fp-dir",
  "custom/api",
}) do
  assert(
    vim.tbl_contains(rels_pdir, expected),
    "projectDir variant missing: " .. expected .. " in " .. vim.inspect(rels_pdir)
  )
end
assert(not vim.tbl_contains(rels_pdir, "libs/ignored-dir"), "findProject on unincluded module should not add module")
assert(project.gradle_path(pdir, pdir .. "/libs/apply-dir") == ":appblk", "apply block logical path diverged")
assert(project.gradle_path(pdir, pdir .. "/custom/api") == ":services:api", "nested projectDir logical path diverged")
assert(
  project.discovery_limitation(pdir) == nil,
  "static projectDir variants should have no limitation: " .. tostring(project.discovery_limitation(pdir))
)

-- 10. Isolation: undeclared subproject (even with comment/prefix match in settings),
--     outward symlink, includeFlat, and .git
local iso_base = vim.fs.normalize(vim.fn.tempname() .. "-iso")
local iso_root = iso_base .. "/agg"
local iso_outside = iso_base .. "/outside-proj"
local iso_sibling = iso_base .. "/sibling"
fixtures.write(iso_root .. "/settings.gradle", {
  "rootProject.name = 'rogue'",
  "// include(':rogue')",
  "include(':app', ':rogue-extra', ':escape')",
  "includeFlat('sibling')",
})
fixtures.write(iso_root .. "/build.gradle", { "// root" })
fixtures.write(iso_root .. "/app/build.gradle", { "// app" })
fixtures.write(iso_root .. "/app/src/main/java/App.java", { "public class App {}" })
fixtures.write(iso_root .. "/rogue-extra/build.gradle", { "// rogue-extra" })
fixtures.write(iso_root .. "/rogue/build.gradle", { "// rogue standalone" })
fixtures.write(iso_root .. "/rogue/src/main/java/Rogue.java", { "public class Rogue {}" })
fixtures.write(iso_root .. "/.git/build.gradle", { "// git" })
fixtures.write(iso_outside .. "/build.gradle", { "// outside" })
fixtures.write(iso_outside .. "/src/main/java/Out.java", { "public class Out {}" })
fixtures.write(iso_sibling .. "/build.gradle", { "// sibling" })
assert(vim.uv.fs_symlink(iso_outside, iso_root .. "/escape"), "failed to create outward symlink")

local rels_iso = rels(iso_root, project.modules(iso_root))
assert(
  vim.tbl_contains(rels_iso, "app") and vim.tbl_contains(rels_iso, "rogue-extra"),
  "declared modules missing in iso"
)
assert(not vim.tbl_contains(rels_iso, "rogue"), "undeclared rogue module entered modules()")
assert(not vim.tbl_contains(rels_iso, "escape"), "outward symlink entered modules()")
assert(not vim.tbl_contains(rels_iso, ".git"), ".git entered modules()")
assert(#rels_iso == 3, "expected root + app + rogue-extra, got: " .. vim.inspect(rels_iso))

local iso_note = project.discovery_limitation(iso_root)
assert(
  iso_note ~= nil and iso_note:find("includeFlat", 1, true),
  "includeFlat should mark limitation: " .. tostring(iso_note)
)
assert(
  iso_note:find("outside the aggregator", 1, true),
  "outward symlink should mark limitation: " .. tostring(iso_note)
)

vim.cmd("edit " .. vim.fn.fnameescape(iso_root .. "/rogue/src/main/java/Rogue.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(iso_root .. "/rogue"),
  "undeclared rogue should stay isolated as its own root, got " .. tostring(project.root(0))
)
vim.cmd("edit " .. vim.fn.fnameescape(iso_outside .. "/src/main/java/Out.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(iso_outside),
  "outward symlink target should stay isolated, got " .. tostring(project.root(0))
)

-- 11. Nested standalone builds and includeBuild composite builds stay isolated
local nest = fixtures.gradle_project("nested-builds", {
  "rootProject.name = 'build-logic'",
  "// include(':samples:demo')",
  "include(':app')",
  "includeBuild('build-logic')",
}, { src_dirs = { "app/src/main/java" } })
fixtures.write(nest .. "/app/build.gradle", { "// app" })
fixtures.write(nest .. "/samples/demo/settings.gradle", { "include(':demo-lib')" })
fixtures.write(nest .. "/samples/demo/demo-lib/build.gradle", { "// demo-lib" })
fixtures.write(nest .. "/samples/demo/demo-lib/src/main/java/Demo.java", { "public class Demo {}" })
fixtures.write(nest .. "/build-logic/settings.gradle", { "include(':conventions')" })
fixtures.write(nest .. "/build-logic/conventions/build.gradle", { "// conventions" })
fixtures.write(nest .. "/build-logic/conventions/src/main/java/Conv.java", { "public class Conv {}" })

local rels_nb = rels(nest, project.modules(nest))
assert(
  #rels_nb == 2 and vim.tbl_contains(rels_nb, "app"),
  "nested standalone builds leaked into outer modules: " .. vim.inspect(rels_nb)
)
assert(
  project.discovery_limitation(nest) == nil,
  "static includeBuild should not invent false limitation: " .. tostring(project.discovery_limitation(nest))
)

local demo_mods = rels(nest .. "/samples/demo", project.modules(nest .. "/samples/demo"))
assert(
  #demo_mods == 2 and vim.tbl_contains(demo_mods, "demo-lib"),
  "nested build should discover its own modules: " .. vim.inspect(demo_mods)
)

vim.cmd("edit " .. vim.fn.fnameescape(nest .. "/samples/demo/demo-lib/src/main/java/Demo.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(nest .. "/samples/demo"),
  "nested build root diverged: " .. tostring(project.root(0))
)
vim.cmd("edit " .. vim.fn.fnameescape(nest .. "/build-logic/conventions/src/main/java/Conv.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(nest .. "/build-logic"),
  "includeBuild root diverged: " .. tostring(project.root(0))
)

-- 12. Dynamic expressions (without apply from): preserve provable static siblings + partial warnings, never guess values
local dyn2 = fixtures.gradle_project("dyn-expressions", {
  'val suffix = "x"',
  'val dynMods = listOf(":varmod")',
  'include(":keep", ":dyn" + suffix)',
  "include(dynMods)",
  'include(":${suffix}")',
  "if (hasProperty('withOpt')) {",
  "  include(':opt')",
  "}",
  "if (hasProperty('withOpt2'))",
  "  include(':opt2')",
  "file('modules').listFiles().forEach { include(\":${it.name}\") }",
  "include(':moved', ':moved2', ':moved3', ':moved4')",
  'project(":moved").projectDir = file("$rootDir/moved")',
  'project(":moved2").projectDir = file(suffix)',
  'project(":moved3").projectDir = File(customBase, "moved3")',
  'project(":moved4").apply {',
  "  if (hasProperty('alt')) {",
  '    projectDir = file("alt")',
  "  }",
  "}",
}, {
  kts = true,
  src_dirs = {
    "keep",
    "dyn",
    "dynx",
    "varmod",
    "opt",
    "opt2",
    "moved",
    "moved2",
    "moved3",
    "moved4",
    "alt",
  },
})
local rels_dyn2 = rels(dyn2, project.modules(dyn2))
assert(vim.tbl_contains(rels_dyn2, "keep"), "static sibling in mixed include lost")
for _, forbidden in ipairs({ "dyn", "dynx", "varmod", "opt", "opt2", "moved", "moved2", "moved3", "moved4", "alt" }) do
  assert(not vim.tbl_contains(rels_dyn2, forbidden), "dynamic/conditional module guessed: " .. forbidden)
end
assert(#rels_dyn2 == 2, "expected only root + keep, got: " .. vim.inspect(rels_dyn2))
local note2 = project.discovery_limitation(dyn2)
assert(note2 ~= nil and note2:find("partial", 1, true), "dynamic expressions should set partial note")
assert(note2:find("dynamic/conditional", 1, true), "conditional/loop include should be noted: " .. tostring(note2))

-- 12b. apply from external script can alter any projectDir: suppress unverified mappings, isolate, and warn
local apply_kts = fixtures.gradle_project("apply-from-kts", {
  'include(":keep", ":explicit")',
  'project(":explicit").projectDir = file("custom-explicit")',
  'apply(from = "gradle/extra.gradle.kts")',
}, {
  kts = true,
  src_dirs = { "keep/src/main/java", "custom-explicit/src/main/java" },
})
fixtures.write(apply_kts .. "/keep/build.gradle.kts", { "// keep" })
fixtures.write(apply_kts .. "/keep/src/main/java/Keep.java", { "public class Keep {}" })
local rels_ak = rels(apply_kts, project.modules(apply_kts))
assert(
  #rels_ak == 1,
  "apply(from=...) must not report unverified default/pre-apply mappings as factual: " .. vim.inspect(rels_ak)
)
local note_ak = project.discovery_limitation(apply_kts)
assert(
  note_ak ~= nil and note_ak:find("partial", 1, true),
  "apply(from=...) should set partial note: " .. tostring(note_ak)
)
assert(note_ak:find("apply from", 1, true), "apply(from=...) note missing: " .. tostring(note_ak))
vim.cmd("edit " .. vim.fn.fnameescape(apply_kts .. "/keep/src/main/java/Keep.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(apply_kts .. "/keep"),
  "unverified module under apply(from=...) should stay isolated, got " .. tostring(project.root(0))
)

local apply_groovy = fixtures.gradle_project("apply-from-groovy", {
  "include(':a')",
  "apply from: 'gradle/extra.gradle'",
  "include(':b')",
  "project(':b').projectDir = file('custom-b')",
}, { src_dirs = { "a", "b", "custom-b" } })
assert(#project.modules(apply_groovy) == 1, "Groovy apply from must suppress unverified mappings")
assert((project.discovery_limitation(apply_groovy) or ""):find("apply from", 1, true), "Groovy apply from note missing")

local apply_cond = fixtures.gradle_project("apply-from-cond", {
  "include(':a')",
  "if (file('local.settings.gradle').exists()) {",
  "  apply(from: 'local.settings.gradle')",
  "}",
}, { src_dirs = { "a" } })
assert(#project.modules(apply_cond) == 1, "conditional apply from must suppress unverified mappings")
assert(
  (project.discovery_limitation(apply_cond) or ""):find("apply from", 1, true),
  "conditional apply from note missing"
)

local apply_block = fixtures.gradle_project("apply-from-block", {
  "include(':a')",
  'settings.apply { from("extra.gradle.kts") }',
}, { kts = true, src_dirs = { "a" } })
assert(#project.modules(apply_block) == 1, "apply { from(...) } must suppress unverified mappings")
assert(
  (project.discovery_limitation(apply_block) or ""):find("apply from", 1, true),
  "apply { from(...) } note missing"
)

local apply_plugin = fixtures.gradle_project("apply-plugin-safe", {
  'apply(plugin = "com.example.settings")',
  'include(":app")',
}, { kts = true, src_dirs = { "app" } })
local rels_ap = rels(apply_plugin, project.modules(apply_plugin))
assert(#rels_ap == 2 and vim.tbl_contains(rels_ap, "app"), "apply(plugin=...) should not suppress static module")
assert(project.discovery_limitation(apply_plugin) == nil, "apply(plugin=...) should not trigger apply-from limitation")

-- 13. Conditional projectDir overrides, setProjectDir and unrecognized setters suppress unsafe guesses
local cond_set = fixtures.gradle_project("cond-setters", {
  "include(':app', ':cond_inline', ':cond_if', ':setter', ':blk_setter', ':var_alias', ':with_scope', ':prop_setter', ':find_cond', ':keep')",
  "if (hasProperty('alt')) {",
  "  project(':app').projectDir = file('alt-app')",
  "}",
  "if (hasProperty('alt2'))",
  "  project(':cond_inline').projectDir = file('alt-inline')",
  "project(':cond_if').projectDir = file('custom-ci')",
  "if (hasProperty('alt3')) {",
  "  project(':cond_if').projectDir = file('alt-ci')",
  "}",
  "project(':setter').setProjectDir(file('moved-setter'))",
  "project(':blk_setter') {",
  "  setProjectDir(file('moved-blk'))",
  "}",
  "def p = project(':var_alias')",
  "p.projectDir = file('moved-alias')",
  "project(':with_scope').with {",
  "  projectDir = file('moved-with')",
  "}",
  "project(':prop_setter').setProperty('projectDir', file('moved-prop'))",
  "if (hasProperty('alt4')) {",
  "  findProject(':find_cond')?.projectDir = file('alt-find')",
  "}",
}, {
  src_dirs = {
    "app/src/main/java",
    "alt-app",
    "cond_inline",
    "alt-inline",
    "cond_if",
    "custom-ci",
    "alt-ci",
    "setter",
    "moved-setter",
    "blk_setter",
    "moved-blk",
    "var_alias",
    "moved-alias",
    "with_scope",
    "moved-with",
    "prop_setter",
    "moved-prop",
    "find_cond",
    "alt-find",
    "keep",
  },
})
fixtures.write(cond_set .. "/app/build.gradle", { "// suppressed app" })
fixtures.write(cond_set .. "/app/src/main/java/App.java", { "public class App {}" })
local rels_cs = rels(cond_set, project.modules(cond_set))
assert(vim.tbl_contains(rels_cs, "keep"), "static sibling lost with conditional/setter overrides")
assert(#rels_cs == 2, "expected only root + keep, got: " .. vim.inspect(rels_cs))
local note_cs = project.discovery_limitation(cond_set)
assert(
  note_cs ~= nil and note_cs:find("partial", 1, true),
  "conditional/setter overrides should warn: " .. tostring(note_cs)
)
assert(note_cs:find("setProjectDir", 1, true), "setProjectDir should be noted: " .. tostring(note_cs))
vim.cmd("edit " .. vim.fn.fnameescape(cond_set .. "/app/src/main/java/App.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(cond_set .. "/app"),
  "suppressed :app should stay isolated at its own root, got " .. tostring(project.root(0))
)

local untargeted = fixtures.gradle_project("untargeted-setter", {
  "include(':app')",
  "def dynName = ':app'",
  "project(dynName).projectDir = file('moved')",
}, { src_dirs = { "app", "moved" } })
local rels_untargeted = rels(untargeted, project.modules(untargeted))
assert(
  #rels_untargeted == 1,
  "untargeted projectDir override must suppress root/app guess: " .. vim.inspect(rels_untargeted)
)
assert(project.discovery_limitation(untargeted) ~= nil, "untargeted projectDir override should warn")

-- 14. Statement-order-aware nested ':parent:child' projectDir (verified with real Gradle 9.2.1)
-- 14a. include(':parent:child') BEFORE project(':parent').projectDir = file('custom'):
--      child stays at root/parent/child; decoy custom/child stays isolated.
local order_before = fixtures.gradle_project("order-child-before", {
  "include(':parent:child')",
  "project(':parent').projectDir = file('custom')",
}, {
  src_dirs = {
    "parent/child/src/main/java",
    "custom/child/src/main/java",
  },
})
fixtures.write(order_before .. "/parent/child/build.gradle", { "// real child at default dir" })
fixtures.write(order_before .. "/parent/child/src/main/java/Child.java", { "public class Child {}" })
fixtures.write(order_before .. "/custom/child/build.gradle", { "// decoy under custom" })
fixtures.write(order_before .. "/custom/child/src/main/java/Decoy.java", { "public class Decoy {}" })
local rels_ob = rels(order_before, project.modules(order_before))
assert(
  vim.tbl_contains(rels_ob, "parent/child"),
  "child before parent projectDir should stay at root/parent/child: " .. vim.inspect(rels_ob)
)
assert(
  not vim.tbl_contains(rels_ob, "custom/child"),
  "decoy custom/child leaked when child was included before parent projectDir"
)
assert(#rels_ob == 2, "expected root + parent/child, got: " .. vim.inspect(rels_ob))
assert(project.discovery_limitation(order_before) == nil, "static order-before should have no limitation")
assert(
  project.gradle_path(order_before, order_before .. "/parent/child") == ":parent:child",
  "logical path diverged for child before parent projectDir"
)
vim.cmd("edit " .. vim.fn.fnameescape(order_before .. "/parent/child/src/main/java/Child.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(order_before),
  "child at parent/child should resolve to aggregator root, got " .. tostring(project.root(0))
)
vim.cmd("edit " .. vim.fn.fnameescape(order_before .. "/custom/child/src/main/java/Decoy.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(order_before .. "/custom/child"),
  "decoy custom/child should stay isolated, got " .. tostring(project.root(0))
)

-- 14b. include(':parent'); project(':parent').projectDir = file('custom'); include(':parent:child'):
--      child is placed at root/custom/child; decoy parent/child stays isolated.
local order_after = fixtures.gradle_project("order-child-after", {
  "include(':parent')",
  "project(':parent').projectDir = file('custom')",
  "include(':parent:child', ':parent:child:leaf', ':parent:direct')",
  "project(':parent:direct').projectDir = file('direct-dir')",
  "include(':implicit_p:child')",
  "project(':implicit_p').projectDir = file('custom-implicit')",
  "include(':implicit_p:second')",
}, {
  src_dirs = {
    "custom/child/src/main/java",
    "custom/child/leaf/src/main/java",
    "direct-dir",
    "parent/child/src/main/java",
    "implicit_p/child",
    "custom-implicit/child",
    "custom-implicit/second",
  },
})
fixtures.write(order_after .. "/custom/child/build.gradle", { "// real child" })
fixtures.write(order_after .. "/custom/child/src/main/java/Child.java", { "public class Child {}" })
fixtures.write(order_after .. "/parent/child/build.gradle", { "// decoy child" })
fixtures.write(order_after .. "/parent/child/src/main/java/Decoy.java", { "public class Decoy {}" })
local rels_oa = rels(order_after, project.modules(order_after))
for _, expected in ipairs({
  "custom",
  "custom/child",
  "custom/child/leaf",
  "direct-dir",
  "implicit_p/child",
  "custom-implicit/second",
}) do
  assert(
    vim.tbl_contains(rels_oa, expected),
    "order-aware module missing: " .. expected .. " in " .. vim.inspect(rels_oa)
  )
end
assert(not vim.tbl_contains(rels_oa, "parent/child"), "decoy default parent/child leaked into modules()")
assert(
  not vim.tbl_contains(rels_oa, "custom-implicit/child"),
  "child included before implicit parent move leaked into custom-implicit/child"
)
assert(#rels_oa == 7, "expected root + 6 modules, got: " .. vim.inspect(rels_oa))
assert(project.discovery_limitation(order_after) == nil, "static order-after overrides should have no limitation")
assert(
  project.gradle_path(order_after, order_after .. "/custom/child") == ":parent:child",
  "nested child logical path diverged"
)
assert(
  project.gradle_path(order_after, order_after .. "/custom/child/leaf") == ":parent:child:leaf",
  "nested leaf logical path diverged"
)
assert(
  project.gradle_path(order_after, order_after .. "/direct-dir") == ":parent:direct",
  "explicit child override logical path diverged"
)
assert(
  project.gradle_path(order_after, order_after .. "/implicit_p/child") == ":implicit_p:child",
  "implicit child before parent move logical path diverged"
)
assert(
  project.gradle_path(order_after, order_after .. "/custom-implicit/second") == ":implicit_p:second",
  "implicit child after parent move logical path diverged"
)
vim.cmd("edit " .. vim.fn.fnameescape(order_after .. "/custom/child/src/main/java/Child.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(order_after),
  "overridden nested child should resolve to aggregator root, got " .. tostring(project.root(0))
)
vim.cmd("edit " .. vim.fn.fnameescape(order_after .. "/parent/child/src/main/java/Decoy.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(order_after .. "/parent/child"),
  "decoy parent/child should stay isolated, got " .. tostring(project.root(0))
)

local nested_dyn = fixtures.gradle_project("nested-dyn-parent", {
  "def dyn = 'x'",
  "include(':dyn_p')",
  "project(':dyn_p').projectDir = file(dyn)",
  "include(':dyn_p:child')",
  "include(':cond_p')",
  "if (hasProperty('alt')) {",
  "  project(':cond_p').projectDir = file('alt-p')",
  "}",
  "include(':cond_p:child')",
  "include(':set_p')",
  "project(':set_p').setProjectDir(file('set-p-dir'))",
  "include(':set_p:child')",
  "include(':before_p', ':before_p:child')",
  "project(':before_p').projectDir = file(dyn)",
  "include(':ok')",
}, {
  src_dirs = {
    "dyn_p/child/src/main/java",
    "cond_p/child",
    "set_p/child",
    "alt-p/child",
    "set-p-dir/child",
    "before_p/child",
    "ok",
  },
})
fixtures.write(nested_dyn .. "/dyn_p/child/build.gradle", { "// dyn child" })
fixtures.write(nested_dyn .. "/dyn_p/child/src/main/java/DynChild.java", { "public class DynChild {}" })
local rels_nd = rels(nested_dyn, project.modules(nested_dyn))
assert(vim.tbl_contains(rels_nd, "ok"), "static sibling lost with dynamic parent")
assert(
  vim.tbl_contains(rels_nd, "before_p/child"),
  "child included before dynamic parent override should stay at root/before_p/child"
)
assert(#rels_nd == 3, "children after dynamic/conditional/setter parent must be skipped, got: " .. vim.inspect(rels_nd))
assert(project.discovery_limitation(nested_dyn) ~= nil, "dynamic parent should mark partial limitation")
vim.cmd("edit " .. vim.fn.fnameescape(nested_dyn .. "/dyn_p/child/src/main/java/DynChild.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(nested_dyn .. "/dyn_p/child"),
  "skipped child of dynamic parent should stay isolated, got " .. tostring(project.root(0))
)

local nested_out_base = vim.fs.normalize(vim.fn.tempname() .. "-nest-out")
local nested_out = nested_out_base .. "/agg"
fixtures.write(nested_out .. "/settings.gradle", {
  "include(':out_p')",
  "project(':out_p').projectDir = file('../outside-parent')",
  "include(':out_p:child')",
})
fixtures.write(nested_out .. "/build.gradle", { "// root" })
fixtures.write(nested_out .. "/out_p/child/build.gradle", { "// decoy" })
fixtures.write(nested_out_base .. "/outside-parent/child/build.gradle", { "// outside child" })
local rels_no = rels(nested_out, project.modules(nested_out))
assert(#rels_no == 1, "child after outside parent must not leak: " .. vim.inspect(rels_no))
assert(
  (project.discovery_limitation(nested_out) or ""):find("outside the aggregator", 1, true),
  "outside parent/child should report outside the aggregator"
)

-- 14c. rootDir.resolve('/outside') absolute path must NOT strip '/' and resolve under root
local resolve_abs = fixtures.gradle_project("resolve-abs-outside", {
  'include(":outside", ":keep")',
  'project(":outside").projectDir = rootDir.resolve("/outside")',
}, {
  kts = true,
  src_dirs = { "outside/src/main/java", "keep" },
})
fixtures.write(resolve_abs .. "/outside/build.gradle.kts", { "// decoy inside root/outside" })
fixtures.write(resolve_abs .. "/outside/src/main/java/Decoy.java", { "public class Decoy {}" })
local rels_ra = rels(resolve_abs, project.modules(resolve_abs))
assert(vim.tbl_contains(rels_ra, "keep"), "static sibling lost with rootDir.resolve('/outside')")
assert(not vim.tbl_contains(rels_ra, "outside"), "rootDir.resolve('/outside') stripped leading '/' into root/outside!")
assert(#rels_ra == 2, "expected only root + keep, got: " .. vim.inspect(rels_ra))
local note_ra = project.discovery_limitation(resolve_abs)
assert(
  note_ra ~= nil and note_ra:find("outside the aggregator", 1, true),
  "rootDir.resolve('/outside') should note outside the aggregator: " .. tostring(note_ra)
)
vim.cmd("edit " .. vim.fn.fnameescape(resolve_abs .. "/outside/src/main/java/Decoy.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(resolve_abs .. "/outside"),
  "decoy root/outside should stay isolated, got " .. tostring(project.root(0))
)

local resolve_rel_out = fixtures.gradle_project("resolve-rel-outside", {
  'include(":relout")',
  'project(":relout").projectDir = settingsDir.resolve("../nonexistent-outside")',
}, { kts = true, src_dirs = { "relout" } })
assert(#project.modules(resolve_rel_out) == 1, "settingsDir.resolve('../nonexistent-outside') must not leak")
assert(
  (project.discovery_limitation(resolve_rel_out) or ""):find("outside the aggregator", 1, true),
  "nonexistent relative outside path should still note outside the aggregator"
)

-- 15. Groovy slashy and dollar-slashy strings (multiline, comments, division, unsupported rejection)
local slashy_safe = fixtures.gradle_project("slashy-safe", {
  "def half = 10 / 2",
  "def pat = /include(':ghost_single')/",
  "def multiSlash = /",
  "  escaped \\/ slash",
  "  include(':ghost_multi')",
  "/",
  "def dslash = $/include(':ghost_ds_single')/$",
  "def multiDollar = $/",
  "  // https://example.com",
  "  /* block inside dollar-slashy */",
  "  $/ escaped slash",
  "  $$ escaped dollar",
  '  unbalanced " { (',
  "  include(':ghost_ds_multi')",
  "  project(':real').projectDir = file('wrong_dir')",
  "/$",
  "def ratio = half / 2",
  "include(':real')",
}, {
  src_dirs = { "ghost_single", "ghost_multi", "ghost_ds_single", "ghost_ds_multi", "wrong_dir", "real/src/main/java" },
})
fixtures.write(slashy_safe .. "/ghost_multi/build.gradle", { "// ghost" })
fixtures.write(slashy_safe .. "/ghost_multi/src/main/java/Ghost.java", { "public class Ghost {}" })
local rels_ss = rels(slashy_safe, project.modules(slashy_safe))
assert(vim.tbl_contains(rels_ss, "real"), "real module missed after slashy/dollar-slashy/division")
assert(#rels_ss == 2, "slashy/dollar-slashy strings caused false includes: " .. vim.inspect(rels_ss))
assert(
  project.discovery_limitation(slashy_safe) == nil,
  "safe slashy/dollar-slashy strings and division should not warn: "
    .. tostring(project.discovery_limitation(slashy_safe))
)
vim.cmd("edit " .. vim.fn.fnameescape(slashy_safe .. "/ghost_multi/src/main/java/Ghost.java"))
assert(
  project.root(0) == vim.uv.fs_realpath(slashy_safe .. "/ghost_multi"),
  "module mentioned only inside slashy string must stay isolated, got " .. tostring(project.root(0))
)

local slashy_unsup = fixtures.gradle_project("slashy-unsup", {
  "include(/slash_mod/, ':keep')",
  "include($/dollar_mod/$)",
  "include(':pdir_slash', ':pdir_dslash')",
  "project(':pdir_slash').projectDir = file(/slash_dir/)",
  "project(':pdir_dslash').projectDir = file($/dslash_dir/$)",
}, { src_dirs = { "slash_mod", "dollar_mod", "pdir_slash", "slash_dir", "pdir_dslash", "dslash_dir", "keep" } })
local rels_su = rels(slashy_unsup, project.modules(slashy_unsup))
assert(vim.tbl_contains(rels_su, "keep"), "static sibling lost alongside unsupported slashy include")
assert(#rels_su == 2, "unsupported slashy/dollar-slashy args must not guess modules: " .. vim.inspect(rels_su))
local note_su = project.discovery_limitation(slashy_unsup)
assert(
  note_su ~= nil and note_su:find("slashy", 1, true),
  "unsupported slashy/dollar-slashy should emit partial warning: " .. tostring(note_su)
)

local slashy_unclosed = fixtures.gradle_project("slashy-unclosed", {
  "def broken = $/",
  "  include(':ghost_unclosed')",
}, { src_dirs = { "ghost_unclosed" } })
assert(#project.modules(slashy_unclosed) == 1, "unclosed dollar-slashy must not invent module")
assert(project.discovery_limitation(slashy_unclosed) ~= nil, "unclosed dollar-slashy should warn")

local slashy_unclosed2 = fixtures.gradle_project("slashy-unclosed2", {
  "def broken = /",
  "  include(':ghost_unclosed2')",
}, { src_dirs = { "ghost_unclosed2" } })
assert(#project.modules(slashy_unclosed2) == 1, "unclosed slashy must not invent module")
assert(project.discovery_limitation(slashy_unclosed2) ~= nil, "unclosed slashy should warn")

print("project_gradle_spec: OK")
vim.cmd("qa!")
