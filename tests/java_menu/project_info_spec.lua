-- 7B.1: Project Info (read-only). Root/build tool/modules/source roots em
-- Maven single e multimódulo, Gradle (com limitação de descoberta), Plain Java
-- e sem projeto. O relatório não escreve nada no projeto.
--
-- Run:
--   tests/java_menu/run.sh fast

local project = require("java_menu.project")
local project_menu = require("java_menu.project_menu")
local fixtures = require("tests.java_menu.fixtures")

local roots = {}
local function tracked(root)
  roots[#roots + 1] = root
  return root
end

local function buffer_for(path)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, path)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

---Lê as linhas do relatório aberto (buffer atual) e fecha o split.
local function read_report()
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf].buftype == "nofile", "relatório não é um buffer nofile")
  assert(vim.bo[buf].modifiable == false, "relatório deveria ser read-only")
  local q = vim.fn.maparg("q", "n", false, true)
  assert(type(q) == "table" and q.buffer == 1, "mapeamento q ausente no relatório")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.cmd("close")
  return lines
end

local function find_line(lines, prefix)
  for _, line in ipairs(lines) do
    if line:sub(1, #prefix) == prefix then
      return line
    end
  end
end

---Snapshot recursivo (tipo + caminho) para provar que nada foi escrito.
local function walk(dir, out)
  out = out or {}
  for name, kind in vim.fs.dir(dir) do
    local path = dir .. "/" .. name
    out[#out + 1] = kind .. " " .. path
    if kind == "directory" then
      walk(path, out)
    end
  end
  table.sort(out)
  return out
end

-- ---------- 1. Maven single-module ----------

local root, main_path = fixtures.maven_project("pinfo", "com.pinfo", "App")
tracked(root)
local real_root = vim.uv.fs_realpath(root)
buffer_for(main_path)

assert(project_menu._info_available(0) == true, "projeto Maven deveria ter Project Info")
project_menu.info(0)
local lines = read_report()
assert(find_line(lines, "Root: ") == "Root: " .. real_root, "root divergiu: " .. tostring(find_line(lines, "Root: ")))
assert(find_line(lines, "Build tool: ") == "Build tool: Maven", "build tool divergiu")
assert(find_line(lines, "Modules: ") == "Modules: 1", "contagem de módulos divergiu: " .. tostring(find_line(lines, "Modules: ")))
assert(vim.tbl_contains(lines, "  ."), "lista de módulos sem a raiz: " .. vim.inspect(lines))
assert(vim.tbl_contains(lines, "  src/main/java"), "source root da raiz ausente: " .. vim.inspect(lines))
assert(find_line(lines, "JDTLS: ") == "JDTLS: not attached", "JDTLS deveria estar desanexado nesta sessão")

-- ---------- 2. Maven multimódulo ----------

local nested, mods = fixtures.maven_nested("pinfo")
tracked(nested)
local nested_real = vim.uv.fs_realpath(nested)
buffer_for(mods.api .. "/src/main/java/com/nest/api/Thing.java")
project_menu.info(0)
lines = read_report()
local expected_modules = project.modules(nested_real)
assert(
  find_line(lines, "Modules: ") == "Modules: " .. tostring(#expected_modules),
  "contagem multimódulo divergiu: " .. tostring(find_line(lines, "Modules: "))
)
for _, rel in ipairs({ "services", "services/api", "services/worker", "libraries/core" }) do
  assert(vim.tbl_contains(lines, "  " .. rel), "módulo " .. rel .. " ausente: " .. vim.inspect(lines))
end
assert(not vim.tbl_contains(lines, "  rogue"), "módulo não declarado apareceu na lista")
assert(find_line(lines, "Discovery: ") == nil, "Maven não deveria reportar limitação de descoberta")

-- ---------- 3. Gradle estático ----------

local gradle = fixtures.gradle_project("pinfo-g", { "include(':app')" }, { src_dirs = { "app/src/main/java" } })
tracked(gradle)
buffer_for(gradle .. "/app/src/main/java/.keep")
project_menu.info(0)
lines = read_report()
assert(find_line(lines, "Build tool: ") == "Build tool: Gradle", "build tool Gradle divergiu")
assert(find_line(lines, "Modules: ") == "Modules: 2", "módulos Gradle divergiram: " .. tostring(find_line(lines, "Modules: ")))
assert(vim.tbl_contains(lines, "  app"), "módulo app ausente na lista Gradle")

-- Gradle com include dinâmico: limitação explícita, nunca módulo inventado
local dynamic = fixtures.gradle_project("pinfo-dyn", {
  "include(':app')",
  'include(":libs:${suffix}")',
}, { src_dirs = { "app/src/main/java" } })
tracked(dynamic)
buffer_for(dynamic .. "/app/src/main/java/.keep")
project_menu.info(0)
lines = read_report()
assert(find_line(lines, "Build tool: ") == "Build tool: Gradle", "build tool Gradle (dinâmico) divergiu")
local discovery = find_line(lines, "Discovery: ")
assert(discovery ~= nil, "limitação de descoberta não reportada: " .. vim.inspect(lines))

-- ---------- 4. Plain Java (sem build file) ----------

local plain = tracked(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-pinfo-plain"))
local plain_main = plain .. "/src/main/java/com/x/A.java"
fixtures.write(plain_main, { "package com.x;", "", "public class A {}" })
local plain_buf = buffer_for(plain_main)

local real_plain = vim.uv.fs_realpath(plain)
assert(project_menu._plain_root(0) == real_plain, "_plain_root divergiu: " .. tostring(project_menu._plain_root(0)))
assert(project.root(0) == nil, "plain não deveria ter root de build")
project_menu.info(0)
lines = read_report()
assert(find_line(lines, "Build tool: ") == "Build tool: Plain Java (no build file)", "label plain divergiu")
assert(find_line(lines, "Root: ") == "Root: " .. real_plain, "root plain divergiu")
assert(find_line(lines, "Modules: ") == "Modules: 1", "plain deveria ter só a raiz")
assert(vim.tbl_contains(lines, "  src/main/java"), "source root plain ausente")

-- ---------- 5. Sem projeto ----------

local empty = tracked(vim.fs.normalize(vim.fn.tempname() .. "/java-menu-pinfo-empty"))
vim.fn.mkdir(empty, "p")
local prev_cwd = vim.uv.cwd()
vim.cmd("cd " .. vim.fn.fnameescape(empty))
local blank = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(blank)
assert(project.root(0) == nil, "diretório vazio não deveria ter root")
assert(project_menu._plain_root(0) == nil, "_plain_root encontrou um projeto no vazio")
assert(project_menu._info_available(0) == false, "Info deveria estar indisponível sem projeto")

local real_select = vim.ui.select
local captured
vim.ui.select = function(items, _, on_choice)
  captured = items
  on_choice(nil)
end
project_menu.project()
vim.ui.select = real_select
assert(captured ~= nil, "menu não usou o fallback vim.ui.select")
local info_label
for _, label in ipairs(captured) do
  if label:find("Project Info", 1, true) then
    info_label = label
  end
end
assert(
  info_label and info_label:find("no Java project", 1, true),
  "motivo de indisponibilidade incoerente: " .. tostring(info_label)
)

-- ---------- 6. Info é read-only: nenhum arquivo escrito ----------

vim.api.nvim_set_current_buf(plain_buf)
local before = walk(real_plain)
project_menu.info(0)
read_report()
local after = walk(real_plain)
assert(vim.deep_equal(before, after), "Project Info escreveu no projeto: " .. vim.inspect(after))

-- ---------- restauração ----------

vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
for _, dir in ipairs(roots) do
  vim.fn.delete(dir, "rf")
end

print("project_info_spec: OK (Maven, multimódulo, Gradle, plain, sem projeto, read-only)")
vim.cmd("qa!")
