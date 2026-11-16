-- Generate: disponibilidade das três entradas de construtor e dos geradores.
-- Sem JDTLS real: valida apenas a árvore de operações e a filtragem dos campos
-- semânticos; a geração real fica em generate_lsp_spec (integração).
--
-- Run:
--   tests/java_menu/run.sh fast

local ui = require("java_menu.ui")
local generate = require("java_menu.generate")

ui.jdtls_attached = function()
  return true
end

local function state(opts)
  return {
    bufnr = 0,
    node = { name = opts.class or "Demo" },
    fields = opts.fields or {},
    ctor_fields = opts.ctor_fields or opts.fields or {},
    ctors = opts.ctors or {},
    methods = opts.methods or {},
    accessors = opts.accessors or {},
  }
end

local function entry(ops, key)
  for _, item in ipairs(ops) do
    if item.key == key then
      return item
    end
  end
  error("operação ausente: " .. key)
end

local three = {
  { name = "count", type = "int" },
  { name = "label", type = "String" },
  { name = "active", type = "boolean" },
}

-- 1. classe com três campos: os três construtores disponíveis
local ops = generate._operations(state({ fields = three }))
assert(entry(ops, "constructor").label == "Constructor (Select Fields)")
assert(entry(ops, "constructor").enabled, "Constructor (Select Fields) deveria estar habilitado")
assert(entry(ops, "all_args").label == "All-Args Constructor")
assert(entry(ops, "all_args").enabled, "All-Args Constructor deveria estar habilitado")
assert(entry(ops, "no_args").label == "No-Args Constructor")
assert(entry(ops, "no_args").enabled, "No-Args Constructor deveria estar habilitado")
assert(#generate._constructor_fields(state({ fields = three })) == 3, "campo elegível descartado")

-- 2. construtor vazio existente: No-Args indisponível, com motivo
ops = generate._operations(state({ fields = three, ctors = { { name = "Demo()" } } }))
assert(not entry(ops, "no_args").enabled, "No-Args deveria bloquear construtor vazio existente")
assert(entry(ops, "no_args").reason:find("no-args", 1, true) ~= nil, "motivo do No-Args ausente")
assert(entry(ops, "all_args").enabled, "All-Args não deveria ser afetado pelo construtor vazio")

-- 3. construtor full existente: All-Args indisponível; seletor continua útil
ops = generate._operations(state({
  fields = three,
  ctors = { { name = "Demo(int, String, boolean)" } },
}))
assert(not entry(ops, "all_args").enabled, "All-Args deveria bloquear construtor full existente")
assert(entry(ops, "all_args").reason:find("all these parameters", 1, true) ~= nil, "motivo do All-Args ausente")
assert(entry(ops, "constructor").enabled, "seletor deveria continuar disponível com subconjunto")

-- 4. classe sem campos: construtores com campos indisponíveis, No-Args disponível
ops = generate._operations(state({ fields = {} }))
assert(not entry(ops, "constructor").enabled, "seletor sem campos deveria estar indisponível")
assert(not entry(ops, "all_args").enabled, "All-Args sem campos deveria estar indisponível")
assert(entry(ops, "no_args").enabled, "No-Args sem campos deveria estar disponível")
assert(entry(ops, "constructor").reason:find("no fields", 1, true) ~= nil, "motivo de campos ausente")

-- 5. campos static/final: static não entra na lista do construtor; final entra
local mixed = {
  { name = "shared", type = "int", isStatic = true },
  { name = "id", type = "int" },
  { name = "name", type = "String" },
}
local eligible = generate._constructor_fields(state({ fields = mixed }))
assert(#eligible == 2, "static deveria ser filtrado (recebi " .. #eligible .. ")")
assert(eligible[1].name == "id" and eligible[2].name == "name", "ordem dos campos elegíveis mudou")
ops = generate._operations(state({ fields = mixed }))
assert(entry(ops, "all_args").enabled, "All-Args deveria ignorar apenas static")

-- 6. toString existente: entrada desabilitada com motivo
ops = generate._operations(state({
  fields = three,
  methods = { { name = "toString()" } },
}))
assert(not entry(ops, "tostring").enabled, "toString existente deveria desabilitar a entrada")
assert(entry(ops, "tostring").reason:find("already exists", 1, true) ~= nil, "motivo de toString existente ausente")

-- 7. campo final sem inicializador bloqueia No-Args (construtor vazio inválido)
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {
  "package com.demo;",
  "",
  "public class Rules {",
  "    private final int id;",
  "}",
})
local final_state = state({
  class = "Rules",
  fields = { { name = "id", type = "int" } },
  ctor_fields = { { name = "id", type = "int" } },
})
final_state.bufnr = scratch
final_state.field_nodes = {
  id = { selectionRange = { start = { line = 3, character = 22 } } },
}
assert(generate._has_pending_final_field(final_state), "campo final não foi reconhecido")
ops = generate._operations(final_state)
assert(not entry(ops, "no_args").enabled, "No-Args deveria bloquear campo final sem inicialização")
assert(entry(ops, "no_args").reason:find("final", 1, true) ~= nil, "motivo de campo final ausente")
assert(entry(ops, "all_args").enabled, "All-Args deveria continuar disponível com campo final")
vim.api.nvim_buf_delete(scratch, { force = true })

print("generate_operations_spec: OK")
vim.cmd("qa!")
