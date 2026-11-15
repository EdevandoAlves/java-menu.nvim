-- M3: descoberta de módulos Maven — single-module, diretos, aninhados,
-- POMs intermediários, caminho relativo explícito, duplicados/ciclos,
-- symlinks/fora do agregador, herança vs agregação, .git.
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "luafile tests/java_menu/project_nested_spec.lua" -c qa

local project = require("java_menu.project")
local fixtures = require("tests.java_menu.fixtures")

local function names(root, mods)
  local out = {}
  for _, m in ipairs(mods) do
    out[#out + 1] = vim.fs.relpath(root, m) or m
  end
  table.sort(out)
  return out
end

-- 1. single-module: só a raiz (comportamento preservado)
local single = fixtures.maven_project("nest-single", "com.single", "Solo")
local mods_single = project.modules(single)
assert(#mods_single == 1 and mods_single[1] == vim.uv.fs_realpath(single), "single-module deveria ser só a raiz")
assert(project.discovery_limitation(single) == nil, "Maven não deve ter limitação de descoberta")

-- 2. multimódulo com subdiretórios diretos declarados
local direct = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-nest-direct")
fixtures.write(direct .. "/pom.xml", {
  "<project>",
  "  <packaging>pom</packaging>",
  "  <modules>",
  "    <module>app</module>",
  "    <module>tools</module>",
  "  </modules>",
  "</project>",
})
fixtures.write(direct .. "/app/pom.xml", { "<project>", "  <artifactId>app</artifactId>", "</project>" })
fixtures.write(direct .. "/tools/pom.xml", { "<project>", "  <artifactId>tools</artifactId>", "</project>" })
local mods_direct = project.modules(direct)
assert(#mods_direct == 3, "esperava raiz + 2 módulos diretos, recebi " .. #mods_direct)
assert(vim.tbl_contains(names(direct, mods_direct), "app"), "módulo direto ausente")

-- 3. aninhado: POM intermediário declara api/worker; raiz declara services e
--    libraries/core com caminho aninhado; rogue/.git nunca entram
local root, mods = fixtures.maven_nested("nested")
local rels = names(root, project.modules(root))
assert(#rels == 5, "esperava raiz + 4 módulos, recebi " .. #rels .. ": " .. vim.inspect(rels))
for _, expected in ipairs({ "services", "services/api", "services/worker", "libraries/core" }) do
  assert(vim.tbl_contains(rels, expected), "módulo aninhado ausente: " .. expected .. " em " .. vim.inspect(rels))
end
assert(not vim.tbl_contains(rels, "rogue"), "pasta não declarada entrou como módulo")
assert(not vim.tbl_contains(rels, "libraries"), "diretório intermediário sem pom entrou como módulo")

-- 4. caminho relativo explícito (./nome) no POM intermediário
fixtures.write(root .. "/services/pom.xml", {
  "<project>",
  "  <packaging>pom</packaging>",
  "  <modules>",
  "    <module>./api</module>",
  "    <module>worker</module>",
  "  </modules>",
  "</project>",
})
local rels2 = names(root, project.modules(root))
assert(vim.tbl_contains(rels2, "services/api"), "caminho relativo explícito (./api) não resolvido")

-- 5. duplicados: declaração repetida não duplica módulo
fixtures.write(root .. "/pom.xml", {
  "<project>",
  "  <packaging>pom</packaging>",
  "  <modules>",
  "    <module>services</module>",
  "    <module>services</module>",
  "    <module>libraries/core</module>",
  "  </modules>",
  "</project>",
})
local seen_services = 0
for _, m in ipairs(project.modules(root)) do
  if m == vim.uv.fs_realpath(root .. "/services") then
    seen_services = seen_services + 1
  end
end
assert(seen_services == 1, "módulo duplicado entrou " .. seen_services .. "x")

-- 6. ciclo: módulo declarando ".." não trava nem reinclui a raiz
fixtures.write(
  root .. "/pom.xml",
  { "<project>", "  <packaging>pom</packaging>", "  <modules><module>services</module></modules>", "</project>" }
)
fixtures.write(
  root .. "/services/pom.xml",
  { "<project>", "  <packaging>pom</packaging>", "  <modules><module>..</module></modules>", "</project>" }
)
local cyclic = project.modules(root)
assert(#cyclic == 2, "ciclo produziu módulos errados: " .. vim.inspect(names(root, cyclic)))
-- restaura o agregador para o resto do spec
fixtures.write(root .. "/pom.xml", {
  "<project>",
  "  <packaging>pom</packaging>",
  "  <modules>",
  "    <module>services</module>",
  "    <module>libraries/core</module>",
  "  </modules>",
  "</project>",
})

-- 7. symlink para fora do agregador é rejeitado; symlink para dentro segue
local outside = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-nest-outside")
fixtures.write(outside .. "/pom.xml", { "<project>", "  <artifactId>outside</artifactId>", "</project>" })
os.remove(root .. "/services/escape")
assert(vim.uv.fs_symlink(outside, root .. "/services/escape"), "não criou symlink externo")
fixtures.write(root .. "/services/pom.xml", {
  "<project>",
  "  <packaging>pom</packaging>",
  "  <modules><module>escape</module></modules>",
  "</project>",
})
for _, m in ipairs(project.modules(root)) do
  assert(not m:find("outside", 1, true), "symlink para fora do agregador virou módulo")
end
os.remove(root .. "/services/escape")
assert(vim.fn.filereadable(outside .. "/pom.xml") == 1, "symlink afetou o destino externo")
-- restaura o POM intermediário para o resto do spec (escape não é módulo real)
fixtures.write(root .. "/services/pom.xml", {
  "<project>",
  "  <packaging>pom</packaging>",
  "  <modules><module>api</module><module>worker</module></modules>",
  "</project>",
})

-- 8. herança Maven (<parent>) sem agregação NÃO cria módulo
local heir = root .. "/rogue"
fixtures.write(heir .. "/pom.xml", {
  "<project>",
  "  <parent>",
  "    <groupId>com.nest</groupId>",
  "    <artifactId>root</artifactId>",
  "    <version>1.0</version>",
  "  </parent>",
  "  <artifactId>rogue</artifactId>",
  "</project>",
})
for _, m in ipairs(project.modules(root)) do
  assert(not m:find("rogue", 1, true), "herança foi confundida com agregação")
end

-- 9. .git com pom.xml não é projeto Java isolado
for _, m in ipairs(project.modules(root)) do
  assert(not m:find("/.git", 1, true), ".git entrou como módulo")
end

-- 10. root do agregador preservado para buffers em módulos aninhados
local core_src = root .. "/libraries/core/src/main/java/com/nest/core/Thing.java"
vim.cmd("edit " .. vim.fn.fnameescape(core_src))
assert(project.root(0) == vim.uv.fs_realpath(root), "root deveria ser o agregador, foi " .. tostring(project.root(0)))
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/services/api/src/main/java/com/nest/api/Thing.java"))
assert(project.root(0) == vim.uv.fs_realpath(root), "root do módulo aninhado divergiu")

-- 11. source_roots cobre os módulos aninhados (New/Tests/Refactor)
local srs = project.source_roots(root)
local sr_rels = {}
for _, sr in ipairs(srs) do
  sr_rels[#sr_rels + 1] = vim.fs.relpath(root, sr.path)
end
for _, expected in ipairs({
  "services/api/src/main/java",
  "services/worker/src/main/java",
  "libraries/core/src/main/java",
}) do
  assert(vim.tbl_contains(sr_rels, expected), "source root aninhado ausente: " .. expected)
end

-- 12. New em módulo aninhado: template criado no source root do módulo
-- (template interno "class", sem depender do jc.nvim)
local new = require("java_menu.new")
local kind
for _, candidate in ipairs(new.kinds) do
  if candidate.template == "class" then
    kind = candidate
    break
  end
end
assert(kind, "kind com template class não encontrado")
local nested_src = root .. "/services/api/src/main/java"
local created = new.create(kind, nested_src, "com.nest.api", "NestedThing", { imports = {} })
assert(created, "New não criou arquivo no módulo aninhado")
assert(created:sub(1, #nested_src) == nested_src, "New escreveu fora do módulo aninhado: " .. created)

print("project_nested_spec: OK")
vim.cmd("qa!")
