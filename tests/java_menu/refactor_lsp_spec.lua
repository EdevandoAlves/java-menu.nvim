-- Integração real: Rename/Move via JDTLS, com preview, cancelamento,
-- bloqueio de buffer modificado no destino e apply de RenameFile.
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "set rtp+=~/.local/share/nvim/lazy/nvim-jdtls" \
--     -c "set rtp+=~/.local/share/nvim/lazy/nvim-lspconfig" \
--     -c "set rtp+=~/.local/share/nvim/lazy/jc.nvim" \
--     -c "luafile tests/java_menu/refactor_lsp_spec.lua" -c qa

local lsp = require("java_menu.lsp")
local fixtures = require("tests.java_menu.fixtures")
local ui = require("java_menu.ui")
local preview = require("java_menu.preview")
local refactor = require("java_menu.refactor")

local ok_jdtls, jdtls = pcall(require, "jdtls")
assert(ok_jdtls and type(jdtls.start_or_attach) == "function", "nvim-jdtls indisponível")

local jdtls_bin = vim.fn.exepath("jdtls")
if jdtls_bin == "" then
  jdtls_bin = vim.fn.stdpath("data") .. "/mason/bin/jdtls"
end
assert(vim.fn.filereadable(jdtls_bin) == 1, "jdtls não está disponível")

local root, widget_file = fixtures.maven_project("refactor-reg", "com.demo.ref", "Widget")
-- referência cruzada: Main importa Widget e cria uma instância
local main_file = root .. "/src/main/java/com/demo/ref/Main.java"
vim.fn.writefile(
  vim.split(
    [[
package com.demo.ref;

public class Main {
  public static void main(String[] args) {
    Widget widget = new Widget();
    System.out.println(widget.name());
  }
}
]],
    "\n",
    { plain = true }
  ),
  main_file
)

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function open(path)
  path = vim.fs.normalize(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    if vim.api.nvim_get_current_buf() ~= buf then
      vim.api.nvim_set_current_buf(buf)
    end
  else
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
  if path:sub(-5) == ".java" and vim.bo.filetype ~= "java" then
    vim.bo.filetype = "java"
  end
end

open(widget_file)
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", root .. "-data" },
  root_dir = root,
})
local attached = fixtures.wait_for(45000, function()
  return lsp.client(0) ~= nil
end)
assert(attached, "JDTLS não anexou")

-- stubs de UI, por operação
local menu_choice
local ask_value
local preview_choice
local destination_pattern
local notices = {}
local preview_opened = false

ui.notify = function(msg, _)
  notices[#notices + 1] = tostring(msg)
end
ui.ask = function(_, _, cb)
  cb(ask_value)
end
ui.pick_one = function(items, prompt, cb)
  if prompt == "Java: Refactor" then
    for _, item in ipairs(items) do
      if item:sub(1, #menu_choice) == menu_choice then
        cb(item)
        return
      end
    end
  elseif prompt:find("mover", 1, true) then
    for _, item in ipairs(items) do
      if
        item:find(destination_pattern, 1, true)
        and not item:find("indisponível", 1, true)
        and not item:find("já é o package atual", 1, true)
      then
        cb(item)
        return
      end
    end
  elseif prompt == "Java: Preview — alterações" then
    preview_opened = true
    for _, item in ipairs(items) do
      if item:find(preview_choice, 1, true) then
        cb(item)
        return
      end
    end
  end
  cb(nil)
end

local function has_notice(text)
  for _, notice in ipairs(notices) do
    if notice:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function cursor_on_class(path, class_name)
  open(path)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, line in ipairs(lines) do
    local col = line:find(class_name, 1, true)
    if col and line:find("class%s+" .. class_name) then
      vim.api.nvim_win_set_cursor(0, { i, col - 1 })
      return
    end
  end
  error("classe não encontrada em " .. path)
end

---Abre/captura os detalhes de um WorkspaceEdit de rename+edit via LSP.
---Usa o cliente real do buffer; não toca em disco nem buffers.
local function capture_rename_edit(bufnr, new_name, class_name)
  local client = lsp.client_or_reason(bufnr)
  assert(client, "JDTLS não está anexado")
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.newName = new_name
  local err, edit
  client:request("textDocument/rename", params, function(e, r)
    vim.schedule(function()
      err, edit = e, r
    end)
  end, bufnr)
  assert(
    fixtures.wait_for(20000, function()
      return err ~= nil or edit ~= nil
    end, 100),
    "textDocument/rename não respondeu"
  )
  assert(not err, "rename recusado: " .. vim.inspect(err))
  assert(type(edit) == "table" and next(edit) ~= nil, "rename sem WorkspaceEdit")
  return edit
end

local function apply_and_validate_rename(edit, root, old_path, new_path, new_class)
  local old_class = new_class:gsub("Renamed$", "")
  local plan = preview._plan(edit, { encoding = lsp.encoding(lsp.client(vim.fn.bufnr(old_path))), root = root })
  assert(plan, vim.inspect(plan))
  assert(#plan.ops >= 3, "esperava edits + rename, recebi " .. #plan.ops)
  for i = 1, #plan.ops - 1 do
    assert(plan.ops[i].kind == "edit", "operação " .. i .. " não é edit: " .. tostring(plan.ops[i].kind))
  end
  assert(
    plan.ops[#plan.ops].kind == "rename",
    "última operação não é rename: " .. tostring(plan.ops[#plan.ops].kind)
  )
  for _, op in ipairs(plan.ops) do
    if op.kind == "edit" then
      local basename = vim.fn.fnamemodify(op.path, ":t")
      assert(basename == "Main.java" or basename == "Widget.java", "edit fora dos documentos esperados: " .. op.path)
    elseif op.kind == "rename" then
      assert(op.old_path == old_path, "rename origem divergente: " .. op.old_path)
      assert(op.new_path == new_path, "rename destino divergente: " .. op.new_path)
    else
      error("operação inesperada no rename real: " .. op.kind)
    end
  end
  local renamed_files = {}
  local new_file_seen = false
  for _, op in ipairs(plan.ops) do
    if op.kind == "rename" and op.new_path == new_path then
      new_file_seen = true
    end
  end
  for _, file in ipairs(plan.files) do
    renamed_files[#renamed_files + 1] = file.path
    local old = table.concat(file.before, "\n")
    local new = table.concat(file.after, "\n")
    assert(old ~= new, "preview sem diferença em " .. file.path)
    local basename = vim.fn.fnamemodify(file.path, ":t")
    if basename == "Widget.java" then
      assert(new:find("class%s+" .. new_class) ~= nil, "preview não renomeou " .. file.path .. "\n" .. new)
    end
  end
  assert(new_file_seen, "preview não incluiu o arquivo renomeado")
  local result, problems = preview._apply(plan)
  assert(result, vim.inspect(problems))
  assert(not result.error, result.error)
  assert(vim.fn.filereadable(new_path) == 1, "apply não criou o destino")
  assert(vim.fn.filereadable(old_path) == 0, "apply não removeu a origem")
  local buf = vim.fn.bufnr(new_path)
  assert(buf ~= -1 and vim.api.nvim_buf_is_loaded(buf), "apply não manteve o buffer destino")
  local buffer_text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(buffer_text:find(new_class, 1, true) ~= nil, "buffer diverge da prévia:\n" .. buffer_text)
  vim.cmd("silent wa")
  assert(read(new_path):find(new_class, 1, true) ~= nil, "conteúdo aplicado diverge da prévia após :wa")
  return renamed_files
end

-- 1. Rename bloqueado por buffer modificado no destino
local blocked_target = root .. "/src/main/java/com/demo/ref/Unsaved.java"
local stale = vim.fn.bufadd(blocked_target)
vim.api.nvim_buf_set_lines(stale, 0, -1, false, { "trabalho não salvo" })
assert(vim.bo[stale].modified, "buffer stale de teste não ficou modificado")

cursor_on_class(widget_file, "Widget")
notices = {}
menu_choice = "Rename Symbol"
ask_value = "Unsaved"
preview_choice = "✔ Aplicar alterações"
preview_opened = false
refactor.refactor()
fixtures.wait_for(30000, function()
  return preview_opened and has_notice("não apliquei")
end)
assert(preview_opened, "preview do rename bloqueado não abriu")
assert(has_notice("não apliquei"), "bloqueio do buffer modificado não apareceu: " .. vim.inspect(notices))
assert(vim.fn.filereadable(blocked_target) == 0, "bloqueio criou o destino")
assert(read(widget_file):find("class Widget", 1, true) ~= nil, "bloqueio alterou a origem")
vim.bo[stale].modified = false
vim.api.nvim_buf_delete(stale, { force = true })

-- 2. Rename aplicado com RenameFile + TextDocumentEdit e referência cruzada
local renamed_file = root .. "/src/main/java/com/demo/ref/WidgetRenamed.java"
local renamed_main = root .. "/src/main/java/com/demo/ref/Main.java"
cursor_on_class(widget_file, "Widget")
local rename_edit = capture_rename_edit(vim.api.nvim_get_current_buf(), "WidgetRenamed", "Widget")
local affected = apply_and_validate_rename(rename_edit, root, widget_file, renamed_file, "WidgetRenamed")
assert(vim.tbl_contains(affected, renamed_main), "referência cruzada fora do rename: " .. vim.inspect(affected))

local renamed_buf = vim.fn.bufnr(renamed_file)
assert(renamed_buf ~= -1 and vim.api.nvim_buf_is_loaded(renamed_buf), "rename não manteve o buffer destino")
local buffer_text = table.concat(vim.api.nvim_buf_get_lines(renamed_buf, 0, -1, false), "\n")
assert(buffer_text:find("class WidgetRenamed", 1, true) ~= nil, "rename não atualizou a declaração")
local reattached = fixtures.wait_for(5000, function()
  return lsp.client(renamed_buf) ~= nil
end)
assert(reattached, "o buffer renomeado não herdou o cliente JDTLS")
vim.cmd("silent wa")
assert(read(renamed_file):find("class WidgetRenamed", 1, true) ~= nil, "rename não persistiu após :wa")

-- 3. Move Class abre destinos por source root e o cancelamento não altera nada
cursor_on_class(renamed_file, "WidgetRenamed")
notices = {}
menu_choice = "Move Class"
destination_pattern = "[src/main/java]"
preview_choice = "✖ Cancelar"
preview_opened = false
local before = read(renamed_file)
refactor.refactor()
fixtures.wait_for(30000, function()
  return preview_opened
end)
assert(preview_opened, "preview do Move Class não abriu")
assert(has_notice("refatoração cancelada"), "cancelamento do Move não avisou")
assert(read(renamed_file) == before, "cancelamento do Move alterou a origem")
assert(vim.fn.filereadable(renamed_file) == 1, "cancelamento do Move removeu a origem")

print("refactor_lsp_spec: OK")
vim.cmd("qa!")
