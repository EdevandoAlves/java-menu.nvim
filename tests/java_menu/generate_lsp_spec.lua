-- Integração real do Generate: JDTLS gera construtores, toString e
-- equals/hashCode; valida seleção de campos, duplicados, campos static/final,
-- classe sem campos e compilação javac do resultado.
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/Projects/java-menu.nvim" \
--     -c "set rtp+=~/.local/share/nvim/lazy/nvim-jdtls" \
--     -c "set rtp+=~/.local/share/nvim/lazy/nvim-lspconfig" \
--     -c "set rtp+=~/.local/share/nvim/lazy/jc.nvim" \
--     -c "luafile tests/java_menu/generate_lsp_spec.lua" -c qa

local lsp = require("java_menu.lsp")
local ui = require("java_menu.ui")
local generate = require("java_menu.generate")
local fixtures = require("tests.java_menu.fixtures")

local ok_jdtls, jdtls = pcall(require, "jdtls")
assert(ok_jdtls and type(jdtls.start_or_attach) == "function", "nvim-jdtls indisponível")
local jdtls_bin = vim.fn.exepath("jdtls")
if jdtls_bin == "" then
  jdtls_bin = vim.fn.stdpath("data") .. "/mason/bin/jdtls"
end
assert(vim.fn.filereadable(jdtls_bin) == 1, "jdtls não está disponível")

local root = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-generate")
vim.fn.mkdir(root .. "/src/main/java/com/demo/gen", "p")
vim.fn.writefile({
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>com.demo</groupId>",
  "  <artifactId>generate-reg</artifactId>",
  "  <version>1.0</version>",
  "  <properties><maven.compiler.release>21</maven.compiler.release></properties>",
  "</project>",
}, root .. "/pom.xml")

local demo = root .. "/src/main/java/com/demo/gen/Demo.java"
vim.fn.writefile({
  "package com.demo.gen;",
  "",
  "public class Demo {",
  "    private int count;",
  "    private String label;",
  "    private boolean active;",
  "",
  "    public int total() {",
  "        return count;",
  "    }",
  "}",
}, demo)

local function open(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "java"
end

local function text(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function count_matches(haystack, needle)
  local n, init = 0, 1
  while true do
    local s = haystack:find(needle, init, true)
    if not s then
      return n
    end
    n = n + 1
    init = s + #needle
  end
end

open(demo)
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", root .. "-data" },
  root_dir = root,
  capabilities = lsp.capabilities(),
})
assert(
  fixtures.wait_for(60000, function()
    return lsp.client(vim.fn.bufnr(demo)) ~= nil
  end),
  "JDTLS não anexou ao projeto de Generate"
)
assert(
  fixtures.wait_for(20000, function()
    local diagnostics = vim.diagnostic.get(vim.fn.bufnr(demo))
    return #diagnostics == 0
  end),
  "diagnósticos iniciais não estabilizaram"
)
vim.wait(2500, function()
  return false
end, 100)

-- ---------- stubs de UI (fluxo real do menu) ----------

local notices = {}
local menu_entries, menu_cb
local pick_indices = { 1 }
local pick_string

vim.notify = function(msg, _)
  notices[#notices + 1] = tostring(msg)
end
ui.menu = function(entries, _, cb)
  menu_entries, menu_cb = entries, cb
end
ui.pick_many = function(items, _, cb)
  local chosen = {}
  for _, index in ipairs(pick_indices) do
    if items[index] then
      chosen[#chosen + 1] = items[index].value
    end
  end
  cb(chosen)
end
vim.ui.select = function(items, opts, cb)
  if opts and opts.prompt and opts.prompt:find("already exists", 1, true) then
    local what = opts.prompt:match("Generate — (.-) already exists")
    cb(what and ("Substituir " .. what) or items[1])
    return
  end
  if pick_string then
    for _, item in ipairs(items) do
      if item == pick_string then
        cb(item)
        return
      end
    end
  end
  cb(items[1])
end

local function entry(key)
  for _, item in ipairs(menu_entries or {}) do
    if item.key == key then
      return item
    end
  end
  error("entrada ausente no menu Generate: " .. key)
end

local function entry_ops(ops, key)
  for _, item in ipairs(ops or {}) do
    if item.key == key then
      return item
    end
  end
  error("operação ausente: " .. key)
end

local function open_menu()
  menu_entries, menu_cb = nil, nil
  generate.generate()
  assert(
    fixtures.wait_for(20000, function()
      return menu_entries ~= nil
    end),
    "menu Generate não abriu; notices: " .. table.concat(notices, "; ")
  )
  return menu_entries
end

local function choose(key)
  open_menu()
  menu_cb(entry(key))
end

local function wait_text(needle, label)
  assert(
    fixtures.wait_for(20000, function()
      return text():find(needle, 1, true) ~= nil
    end),
    (label or needle) .. " não apareceu; buffer:\n" .. text() .. "\nnotices: " .. table.concat(notices, "; ")
  )
end

local function assert_no_client_error()
  for _, notice in ipairs(notices) do
    assert(not notice:find("attempt to index global 'client'", 1, true), "erro de client nil: " .. notice)
    assert(not notice:find("nil value", 1, true), "erro nil: " .. notice)
  end
end

-- ---------- 1. Constructor (Select Fields) ----------

local entries = open_menu()
assert(entry("constructor").label == "Constructor (Select Fields)")
assert(entry("constructor").enabled, "Constructor (Select Fields) desabilitado")
assert(entry("all_args").enabled, "All-Args desabilitado sem construtor existente")
assert(entry("no_args").enabled, "No-Args desabilitado sem construtor existente")

pick_indices = { 1, 2 }
choose("constructor")
wait_text("public Demo(int count, String label)", "construtor de 2 campos")
assert(text():find("this.count = count;", 1, true), "atribuição de count ausente")
assert(text():find("this.label = label;", 1, true), "atribuição de label ausente")
assert(not text():find("this.active = active;", 1, true), "campo não selecionado foi incluído")
assert_no_client_error()

-- ---------- 2. All-Args Constructor ----------

choose("all_args")
wait_text("public Demo(int count, String label, boolean active)", "construtor all-args")
assert(text():find("this.active = active;", 1, true), "atribuição de active ausente no all-args")
assert_no_client_error()

-- ---------- 3. No-Args Constructor ----------

choose("no_args")
wait_text("public Demo()", "construtor sem argumentos")
assert_no_client_error()

-- Duplicados: as três entradas refletem o estado real
open_menu()
assert(not entry("all_args").enabled, "All-Args deveria ficar indisponível após gerar o construtor full")
assert(not entry("no_args").enabled, "No-Args deveria ficar indisponível após gerar o construtor vazio")
assert(entry("all_args").reason:find("all these parameters", 1, true) ~= nil, "motivo do All-Args ausente")
assert(entry("no_args").reason:find("no-args", 1, true) ~= nil, "motivo do No-Args ausente")

-- ---------- 4. toString() ----------

pick_indices = { 1, 2, 3 }
pick_string = "STRING_BUILDER"
choose("tostring")
wait_text("public String toString()", "toString")
assert(text():find("StringBuilder", 1, true), "estilo STRING_BUILDER não foi aplicado")
assert_no_client_error()

-- toString existente: entrada indisponível
open_menu()
assert(not entry("tostring").enabled, "toString existente deveria desabilitar a entrada")
assert(entry("tostring").reason:find("already exists", 1, true) ~= nil, "motivo de toString existente ausente")

-- ---------- 5. equals() + hashCode() ----------

pick_indices = { 1, 2, 3 }
choose("equals_hashcode")
wait_text("public int hashCode()", "hashCode")
wait_text("public boolean equals(Object", "equals")
assert(text():find("label.equals(other.label)", 1, true), "equals não usou o campo label")
assert_no_client_error()

-- Regeneração com confirmação: não duplica métodos
local before_hash = count_matches(text(), "public int hashCode()")
local before_equals = count_matches(text(), "public boolean equals(Object")
choose("equals_hashcode")
wait_text("public boolean equals(Object", "equals regenerado")
assert(count_matches(text(), "public int hashCode()") == before_hash, "hashCode duplicado após regenerar")
assert(count_matches(text(), "public boolean equals(Object") == before_equals, "equals duplicado após regenerar")
assert_no_client_error()

-- ---------- 6. Compilação Java real ----------

vim.cmd("silent write")
local files = vim.fn.glob(root .. "/src/main/java/**/*.java", false, true)
assert(#files > 0, "nenhum arquivo Java para compilar")
vim.fn.mkdir(root .. "/target/classes", "p")
local compile_out = vim.fn.system(vim.list_extend({
  "javac",
  "--release",
  "21",
  "-d",
  root .. "/target/classes",
}, files))
assert(vim.v.shell_error == 0, "javac falhou:\n" .. compile_out)

-- ---------- 7. Campos static/final e classe sem campos ----------

local rules = root .. "/src/main/java/com/demo/gen/Rules.java"
vim.fn.writefile({
  "package com.demo.gen;",
  "",
  "public class Rules {",
  "    private static int shared;",
  "    private final int id;",
  "    private String name;",
  "",
  "    public Rules(int id) {",
  "        this.id = id;",
  "    }",
  "}",
}, rules)
open(rules)
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", root .. "-data" },
  root_dir = root,
  capabilities = lsp.capabilities(),
})
assert(
  fixtures.wait_for(20000, function()
    return lsp.client(vim.fn.bufnr(rules)) ~= nil
  end),
  "Rules.java não anexou ao JDTLS"
)
vim.wait(2500, function()
  return false
end, 100)

local rules_state
generate._load_state(vim.fn.bufnr(rules), function(state)
  rules_state = state
end)
assert(
  fixtures.wait_for(20000, function()
    return rules_state ~= nil
  end),
  "estado de Rules.java não carregou"
)
local names = {}
for _, field in ipairs(generate._constructor_fields(rules_state)) do
  names[#names + 1] = field.name
end
assert(not vim.tbl_contains(names, "shared"), "campo static entrou no construtor: " .. vim.inspect(names))
assert(vim.tbl_contains(names, "id"), "campo final id deveria ser elegível")
assert(vim.tbl_contains(names, "name"), "campo name deveria ser elegível")
local rules_ops = generate._operations(rules_state)
assert(not entry_ops(rules_ops, "no_args").enabled, "No-Args deveria ser bloqueado por campo final sem inicialização")

local empty = root .. "/src/main/java/com/demo/gen/Empty.java"
vim.fn.writefile({
  "package com.demo.gen;",
  "",
  "public class Empty {",
  "}",
}, empty)
open(empty)
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", root .. "-data" },
  root_dir = root,
  capabilities = lsp.capabilities(),
})
assert(
  fixtures.wait_for(20000, function()
    return lsp.client(vim.fn.bufnr(empty)) ~= nil
  end),
  "Empty.java não anexou ao JDTLS"
)
vim.wait(2500, function()
  return false
end, 100)
open_menu()
assert(not entry("constructor").enabled, "Constructor sem campos deveria estar indisponível")
assert(not entry("all_args").enabled, "All-Args sem campos deveria estar indisponível")
assert(entry("no_args").enabled, "No-Args sem campos deveria estar disponível")

print("generate_lsp_spec: OK")
vim.cmd("qa!")
