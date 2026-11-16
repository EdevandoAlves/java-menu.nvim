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
-- package de destino real para o Move Class (precisa existir/indexar)
local dest_dir = root .. "/src/main/java/com/demo/dest"
vim.fn.mkdir(dest_dir, "p")
vim.fn.writefile({
  "package com.demo.dest;",
  "",
  "public class Placeholder {}",
}, dest_dir .. "/Placeholder.java")
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

local function text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
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
  elseif prompt:find("move", 1, true) then
    for _, item in ipairs(items) do
      if
        item:find(destination_pattern, 1, true)
        and not item:find("unavailable", 1, true)
        and not item:find("already the current package", 1, true)
      then
        cb(item)
        return
      end
    end
  elseif prompt == "Java: Preview — changes" then
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
preview_choice = "✔ Apply changes"
preview_opened = false
refactor.refactor()
fixtures.wait_for(30000, function()
  return preview_opened and has_notice("not applied")
end)
assert(preview_opened, "preview do rename bloqueado não abriu")
assert(has_notice("not applied"), "bloqueio do buffer modificado não apareceu: " .. vim.inspect(notices))
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
-- deixa o jdtls reconciliar Main.java antes do move (o move precisa editar a referência)
vim.wait(2500, function()
  return false
end, 100)

-- 3. Move Class abre destinos por source root e o cancelamento não altera nada
cursor_on_class(renamed_file, "WidgetRenamed")
notices = {}
menu_choice = "Move Class"
destination_pattern = "[src/main/java]"
preview_choice = "✖ Cancel"
preview_opened = false
local before = read(renamed_file)
refactor.refactor()
fixtures.wait_for(30000, function()
  return preview_opened
end)
assert(preview_opened, "preview do Move Class não abriu")
assert(has_notice("refactoring cancelled"), "cancelamento do Move não avisou")
assert(read(renamed_file) == before, "cancelamento do Move alterou a origem")
assert(vim.fn.filereadable(renamed_file) == 1, "cancelamento do Move removeu a origem")

-- 4. Move Class aplicado: package/diretório/declaração/referências corretos
local moved_file = dest_dir .. "/WidgetRenamed.java"
cursor_on_class(renamed_file, "WidgetRenamed")
notices = {}
menu_choice = "Move Class"
destination_pattern = "com.demo.dest"
preview_choice = "✔ Apply changes"
preview_opened = false
refactor.refactor()
assert(
  fixtures.wait_for(30000, function()
    return preview_opened and vim.fn.filereadable(moved_file) == 1
  end),
  "Move Class não aplicou o destino; notices: " .. vim.inspect(notices)
)
assert(not has_notice("preview blocked"), "prévia bloqueou um move válido: " .. vim.inspect(notices))
vim.cmd("silent wa")
assert(vim.fn.filereadable(renamed_file) == 0, "Move deixou a origem em disco")
local moved_text = read(moved_file)
assert(moved_text:find("package com.demo.dest;", 1, true) ~= nil, "package não foi atualizado:\n" .. moved_text)
assert(moved_text:find("class WidgetRenamed", 1, true) ~= nil, "declaração da classe sumiu:\n" .. moved_text)
local main_text = read(renamed_main)
assert(
  main_text:find("import com.demo.dest.WidgetRenamed;", 1, true) ~= nil,
  "referência/import não foi atualizado:\n" .. main_text
)

-- compilação Java real de todo o projeto após o move
local java_files = vim.fn.glob(root .. "/src/main/java/**/*.java", false, true)
assert(#java_files > 0, "nenhum fonte Java para compilar após o move")
vim.fn.mkdir(root .. "/target/classes", "p")
local compile_out = vim.fn.system(vim.list_extend({
  "javac",
  "--release",
  "21",
  "-d",
  root .. "/target/classes",
}, java_files))
assert(vim.v.shell_error == 0, "javac falhou após Move Class:\n" .. compile_out)

-- 5. Extract Constant real: cenário elegível, mesmo caminho do menu Visual
local const_file = root .. "/src/main/java/com/demo/ref/ConstUse.java"
vim.fn.writefile({
  "package com.demo.ref;",
  "",
  "public class ConstUse {",
  "    public int minutesPerDay() {",
  "        return 24 * 60;",
  "    }",
  "}",
}, const_file)
open(const_file)
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", root .. "-data" },
  root_dir = root,
  capabilities = lsp.capabilities(),
})
assert(
  fixtures.wait_for(20000, function()
    return lsp.client(vim.fn.bufnr(const_file)) ~= nil
  end),
  "ConstUse.java não anexou ao JDTLS"
)
vim.wait(3000, function()
  return false
end, 50)
local const_ctx = {
  bufnr = vim.api.nvim_get_current_buf(),
  mode = "v",
  start_line = 4,
  start_col = 15,
  end_line = 4,
  end_col = 21,
  tick = vim.b[vim.api.nvim_get_current_buf()].changedtick,
}
refactor._run_extract(const_ctx, "extract_constant")
assert(
  fixtures.wait_for(20000, function()
    local current = text()
    return current:find("private static final int INT = 24 * 60;", 1, true) ~= nil
      and current:find("return INT;", 1, true) ~= nil
  end),
  "Extract Constant não aplicou a refatoração; buffer:\n" .. text()
)
vim.cmd("silent write")

-- 6. Static Import real: o quick assist do jdtls exige range do membro
local static_file = root .. "/src/main/java/com/demo/ref/StaticUse.java"
vim.fn.writefile({
  "package com.demo.ref;",
  "",
  "public class StaticUse {",
  "    public int max(int a, int b) {",
  "        return Math.max(a, b);",
  "    }",
  "}",
}, static_file)
open(static_file)
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", root .. "-data" },
  root_dir = root,
  capabilities = lsp.capabilities(),
})
assert(
  fixtures.wait_for(20000, function()
    return lsp.client(vim.fn.bufnr(static_file)) ~= nil
  end),
  "StaticUse.java não anexou ao JDTLS"
)
vim.wait(4000, function()
  return false
end, 50)
vim.api.nvim_win_set_cursor(0, { 5, 20 }) -- sobre `max`
local debug_range =
  refactor._identifier_range(vim.api.nvim_get_current_buf(), lsp.client(vim.api.nvim_get_current_buf()).offset_encoding)
refactor._static_import(true, vim.api.nvim_get_current_buf())
assert(
  fixtures.wait_for(20000, function()
    local current = text()
    return current:find("import static java.lang.Math.max;", 1, true) ~= nil
      and current:find("return max(a, b);", 1, true) ~= nil
  end),
  "Static Import não aplicou o import/uso; range="
    .. vim.inspect(debug_range)
    .. " buffer="
    .. vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false))
)
vim.cmd("silent write")

-- cursor sobre o qualificador (`Math`) também resolve o membro
local static_file2 = root .. "/src/main/java/com/demo/ref/StaticUse2.java"
vim.fn.writefile({
  "package com.demo.ref;",
  "",
  "public class StaticUse2 {",
  "    public int max(int a, int b) {",
  "        return Math.max(a, b);",
  "    }",
  "}",
}, static_file2)
open(static_file2)
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", root .. "-data" },
  root_dir = root,
  capabilities = lsp.capabilities(),
})
assert(
  fixtures.wait_for(20000, function()
    return lsp.client(vim.fn.bufnr(static_file2)) ~= nil
  end),
  "StaticUse2.java não anexou ao JDTLS"
)
vim.wait(3000, function()
  return false
end, 50)
vim.api.nvim_win_set_cursor(0, { 5, 15 })
refactor._static_import(true, vim.api.nvim_get_current_buf())
assert(
  fixtures.wait_for(20000, function()
    local current = text()
    return current:find("import static java.lang.Math.max;", 1, true) ~= nil
      and current:find("return max(a, b);", 1, true) ~= nil
  end),
  "Static Import com cursor no qualificador não aplicou"
)
vim.cmd("silent write")

-- 7. Change Method Signature real continua funcionando
local sig = root .. "/src/main/java/com/demo/ref/Sig.java"
local sig_use = root .. "/src/main/java/com/demo/ref/SigUse.java"
vim.fn.writefile({
  "package com.demo.ref;",
  "",
  "public class Sig {",
  "    public int calc(int a, int b) {",
  "        return a + b;",
  "    }",
  "}",
}, sig)
vim.fn.writefile({
  "package com.demo.ref;",
  "",
  "public class SigUse {",
  "    public int use() {",
  "        return new Sig().calc(1, 2);",
  "    }",
  "}",
}, sig_use)
open(sig)
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", root .. "-data" },
  root_dir = root,
  capabilities = lsp.capabilities(),
})
assert(
  fixtures.wait_for(20000, function()
    return lsp.client(vim.fn.bufnr(sig)) ~= nil
  end),
  "Sig.java não anexou ao JDTLS"
)
vim.wait(3000, function()
  return false
end, 50)
vim.api.nvim_win_set_cursor(0, { 4, 15 }) -- `calc`

local signature = require("java_menu.signature")
local menu_calls = 0
local asks = { "int c", "0" }
ui.menu = function(entries, _, cb)
  menu_calls = menu_calls + 1
  for _, item in ipairs(entries) do
    if menu_calls == 1 and item.key == "add" then
      cb(item)
      return
    elseif menu_calls > 1 and item.key == "apply" then
      cb(item)
      return
    end
  end
end
ui.ask = function(_, _, cb)
  local value = table.remove(asks, 1)
  cb(value)
end
local sig_edit
signature.change_signature(vim.api.nvim_get_current_buf(), function(edit)
  sig_edit = edit
end)
assert(
  fixtures.wait_for(20000, function()
    return sig_edit ~= nil
  end),
  "Change Signature não devolveu edit"
)
vim.lsp.util.apply_workspace_edit(sig_edit, lsp.client(vim.fn.bufnr(sig)).offset_encoding)
vim.cmd("silent wa")
assert(text():find("calc(int a, int b, int c)", 1, true) ~= nil, "assinatura não mudou:\n" .. text())
assert(read(sig_use):find("calc(1, 2, 0)", 1, true) ~= nil, "chamada não foi atualizada:\n" .. read(sig_use))

-- 8. compilação final do projeto após todas as refatorações
local all_java = vim.fn.glob(root .. "/src/main/java/**/*.java", false, true)
vim.fn.mkdir(root .. "/target/classes", "p")
local final_out = vim.fn.system(vim.list_extend({
  "javac",
  "--release",
  "21",
  "-d",
  root .. "/target/classes",
}, all_java))
assert(vim.v.shell_error == 0, "javac falhou após as refatorações:\n" .. final_out)

print("refactor_lsp_spec: OK")
vim.cmd("qa!")
