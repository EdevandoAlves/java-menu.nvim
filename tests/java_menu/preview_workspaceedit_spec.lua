-- Sequências de WorkspaceEdit com fixtures manuais (sem JDTLS): ordem,
-- preview sem tocar em nada, apply igual à preview e bloqueios seguros.
--
-- Cenários (Auditoria 6A / fase 6B.2):
--   A. TextDocumentEdit → RenameFile (fluxo atual do JDTLS 1.63)
--   B. RenameFile → TextDocumentEdit
--   C. CreateFile → TextDocumentEdit
--   D. TextDocumentEdit → DeleteFile
--   E. Vários edits no mesmo documento (+ offsets UTF-16)
--   F. Rename com referências em outros arquivos
--   G. Operação desconhecida
--   H. Ordem inválida de operações
--   I. Arquivo destino existente
--   J. Buffer destino modificado
--   K. Alteração concorrente durante a prévia
--   L. Cancelamento sem qualquer alteração
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "luafile tests/java_menu/preview_workspaceedit_spec.lua" -c qa

local preview = require("java_menu.preview")
local ui = require("java_menu.ui")

-- ---------- helpers ----------

local function write_file(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
end

local function scenario_dir(name)
  local root = vim.fs.normalize(vim.fn.tempname() .. "/pwe-" .. name)
  vim.fn.mkdir(root .. "/src", "p")
  return root
end

local function uri(path)
  return vim.uri_from_fname(path)
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function join(lines)
  return table.concat(lines or {}, "\n")
end

local function text_edit(l1, c1, l2, c2, new_text)
  return {
    range = {
      start = { line = l1, character = c1 },
      ["end"] = { line = l2, character = c2 },
    },
    newText = new_text,
  }
end

local function tde(path, edits, version)
  return { textDocument = { uri = uri(path), version = version }, edits = edits }
end

local function rename_op(old, new)
  return { kind = "rename", oldUri = uri(old), newUri = uri(new) }
end

local function create_op(path)
  return { kind = "create", uri = uri(path) }
end

local function delete_op(path)
  return { kind = "delete", uri = uri(path) }
end

local function plan_for(edit, root)
  return preview._plan(edit, { encoding = "utf-16", root = root })
end

local function assert_plan_blocked(edit, root, text)
  local plan, err = plan_for(edit, root)
  assert(plan == nil, "plan deveria bloquear: " .. vim.inspect(plan and plan.ops))
  assert(type(err) == "string", "plan bloqueou sem motivo")
  assert(err:find(text, 1, true), "motivo esperado '" .. text .. "' ausente em: " .. err)
end

local function problems_contain(problems, text)
  for _, problem in ipairs(problems or {}) do
    if problem:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function assert_apply_blocked(plan, text)
  local result, problems = preview._apply(plan)
  assert(result == nil, "apply deveria bloquear antes de alterar: " .. vim.inspect(result))
  assert(problems_contain(problems, text), "motivo esperado '" .. text .. "' ausente: " .. vim.inspect(problems))
end

---Apply + persistência explícita do usuário (`:wa`), comparando o resultado
---com a prévia linha a linha.
local function apply_and_persist(plan, root)
  local result, problems = preview._apply(plan)
  assert(result, vim.inspect(problems))
  assert(result.error == nil, "apply falhou no meio da sequência: " .. tostring(result.error))
  for _, file in ipairs(plan.files) do
    local buf = vim.fn.bufnr(file.path)
    assert(buf ~= -1 and vim.api.nvim_buf_is_loaded(buf), "buffer ausente após apply: " .. file.path)
    assert(
      join(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) == join(file.after),
      "buffer diverge da prévia: " .. file.path
    )
  end
  vim.cmd("silent wa")
  for _, file in ipairs(plan.files) do
    assert(vim.fn.filereadable(file.path) == 1, "arquivo não persistiu: " .. file.path)
    assert(read(file.path) == join(file.after), "disco diverge da prévia: " .. file.path)
  end
  return result
end

-- conteúdos de referência
local WIDGET = table.concat({
  "package com.demo;",
  "",
  "public class Widget {",
  "    public String name() {",
  '        return "Widget";',
  "    }",
  "}",
}, "\n")

local function widget_fixture(root, class_name)
  local old = root .. "/src/" .. (class_name or "Widget") .. ".java"
  write_file(old, WIDGET)
  return old
end

local function widget_edits(new_name)
  return {
    text_edit(2, 13, 2, 19, new_name), -- "public class Widget {"
    text_edit(4, 16, 4, 22, new_name), -- '        return "Widget";'
  }
end

-- stubs de UI para todo o spec
local notices = {}
ui.notify = function(msg, _)
  notices[#notices + 1] = tostring(msg)
end

local function has_notice(text)
  for _, notice in ipairs(notices) do
    if notice:find(text, 1, true) then
      return true
    end
  end
  return false
end

-- ---------- A. TextDocumentEdit → RenameFile (fluxo do JDTLS 1.63) ----------

do
  local root = scenario_dir("a-edit-rename")
  local old = widget_fixture(root)
  local new = root .. "/src/WidgetRenamed.java"
  local original_lines = vim.split(WIDGET, "\n", { plain = true })

  local edit = { documentChanges = { tde(new, widget_edits("WidgetRenamed"), 42), rename_op(old, new) } }
  local buf_count = #vim.api.nvim_list_bufs()
  local plan = plan_for(edit, root)
  assert(type(plan) == "table", "plan recusou o fluxo do JDTLS")
  assert(#vim.api.nvim_list_bufs() == buf_count, "plan criou buffers")
  assert(#plan.ops == 2, "esperava 2 operações, recebi " .. #plan.ops)
  assert(plan.ops[1].kind == "edit", "operação 1 deveria ser edit")
  assert(plan.ops[1].source_path == old, "edit não resolveu o caminho antigo")
  assert(plan.ops[1].rename_from == old, "edit não marcou rename_from")
  assert(plan.ops[2].kind == "rename", "operação 2 deveria ser rename")
  assert(#plan.files == 1, "esperava 1 arquivo na prévia")
  local file = plan.files[1]
  assert(file.path == new and file.source_path == old, "prévia com caminhos errados")
  assert(join(file.before) == WIDGET, "conteúdo original diverge")
  assert(join(file.after):find("class WidgetRenamed", 1, true), "prévia não aplicou o edit")
  assert(#file.diff > 0, "prévia sem diff")

  -- preview não toca em nada
  assert(vim.fn.filereadable(new) == 0, "preview criou o destino")
  assert(read(old) == WIDGET, "preview alterou a origem")

  local result, problems = preview._apply(plan)
  assert(result, vim.inspect(problems))
  assert(#result.applied == 2, "esperava 2 operações aplicadas")
  -- rename move o conteúdo original no disco; o edit fica no buffer até o :wa
  assert(read(new) == WIDGET, "rename deveria mover o conteúdo original sem salvar o edit")
  assert(vim.fn.filereadable(old) == 0, "origem não removida")
  vim.cmd("silent wa")
  assert(read(new) == join(file.after), "disco diverge da prévia após :wa")
end

-- ---------- B. RenameFile → TextDocumentEdit ----------

do
  local root = scenario_dir("b-rename-edit")
  local old = widget_fixture(root)
  local new = root .. "/src/WidgetRenamed.java"

  local edit = { documentChanges = { rename_op(old, new), tde(new, widget_edits("WidgetRenamed")) } }
  local plan = plan_for(edit, root)
  assert(type(plan) == "table", "plan recusou rename antes do edit")
  assert(plan.ops[1].kind == "rename", "ordem recebida não preservada (rename primeiro)")
  assert(plan.ops[2].kind == "edit", "ordem recebida não preservada (edit depois)")
  assert(plan.ops[2].source_path == old, "edit pós-rename não resolveu a origem")
  assert(plan.files[1].path == new, "prévia deveria apontar para o caminho novo")

  local result = apply_and_persist(plan, root)
  -- o segundo op é no-op: o conteúdo já foi materializado pelo rename
  assert(
    result.applied[2]:find("already included", 1, true),
    "edit pós-rename deveria ser no-op: " .. vim.inspect(result.applied)
  )
  assert(vim.fn.filereadable(old) == 0, "origem não removida")
end

-- ---------- C. CreateFile → TextDocumentEdit ----------

do
  local root = scenario_dir("c-create-edit")
  local fresh = root .. "/src/com/demo/Fresh.java"
  local body = table.concat({
    "package com.demo;",
    "",
    "public class Fresh {",
    "}",
  }, "\n")

  local edit = {
    documentChanges = {
      create_op(fresh),
      tde(fresh, { text_edit(0, 0, 0, 0, body) }, vim.NIL),
    },
  }
  local plan = plan_for(edit, root)
  assert(type(plan) == "table", "plan recusou create + edit")
  assert(plan.files[1].created == true, "arquivo criado não marcado como created")
  assert(join(plan.files[1].before) == "", "prévia de arquivo novo deveria partir de vazio")
  assert(join(plan.files[1].after) == body, "prévia do create diverge")

  local result, problems = preview._apply(plan)
  assert(result, vim.inspect(problems))
  assert(vim.fn.filereadable(fresh) == 1, "create não escreveu o arquivo")
  assert(vim.fn.getfsize(fresh) == 0, "create não deveria salvar conteúdo (edits ficam no buffer)")
  local buf = vim.fn.bufnr(fresh)
  assert(buf ~= -1 and vim.api.nvim_buf_is_loaded(buf), "buffer do arquivo criado ausente")
  assert(join(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) == body, "buffer diverge da prévia (create + edit)")
  vim.cmd("silent wa")
  assert(read(fresh) == body, "conteúdo final diverge da prévia")
end

-- ---------- D. TextDocumentEdit → DeleteFile ----------

do
  local root = scenario_dir("d-edit-delete")
  local doomed = root .. "/src/Doomed.java"
  write_file(
    doomed,
    table.concat({
      "public class Doomed {",
      "    int x = 1;",
      "}",
    }, "\n")
  )

  local edit = { documentChanges = { tde(doomed, { text_edit(1, 4, 1, 7, "long") }), delete_op(doomed) } }
  local plan = plan_for(edit, root)
  assert(type(plan) == "table", "plan recusou edit + delete")
  assert(join(plan.files[1].after):find("long x", 1, true), "prévia não aplicou o edit")
  assert(plan.ops[2].kind == "delete", "operação 2 deveria ser delete")

  local result, problems = preview._apply(plan)
  assert(result, vim.inspect(problems))
  assert(#result.applied == 2, "esperava edits + delete aplicados")
  assert(vim.fn.filereadable(doomed) == 0, "delete não removeu o arquivo")
  assert(vim.fn.bufnr(doomed) == -1, "delete não limpou o buffer")
end

-- ---------- E. Vários edits no mesmo documento + offsets UTF-16 ----------

do
  local root = scenario_dir("e-multi-edits")
  local doc = root .. "/src/Counter.java"
  local original = table.concat({ "int total = 0;", "int doubled = total + total;" }, "\n")
  write_file(doc, original)
  local expected = table.concat({ "int sum = 0;", "int doubled = sum + total;" }, "\n")

  local edit = {
    documentChanges = {
      tde(doc, { text_edit(0, 4, 0, 9, "sum"), text_edit(1, 14, 1, 19, "sum") }),
    },
  }
  local plan = plan_for(edit, root)
  assert(type(plan) == "table", "plan recusou vários edits num TextDocumentEdit")
  assert(#plan.files == 1, "vários edits deveriam formar um único arquivo na prévia")
  assert(join(plan.files[1].after) == expected, "prévia com vários edits diverge:\n" .. join(plan.files[1].after))
  apply_and_persist(plan, root)

  -- E2: dois TextDocumentEdit para o mesmo documento é sequência insegura:
  -- os ranges do segundo já estariam deslocados pelo primeiro
  local dup =
    { documentChanges = { tde(doc, { text_edit(0, 4, 0, 9, "sum") }), tde(doc, { text_edit(1, 14, 1, 19, "sum") }) } }
  assert_plan_blocked(dup, root, "more than one TextDocumentEdit")
  assert(read(doc) == expected, "bloqueio alterou o documento")

  -- E3: offsets UTF-16 com emoji (2 unidades UTF-16, 4 bytes)
  local emoji = root .. "/src/Emoji.java"
  local emoji_text = table.concat({ 's = "👍👍";', 'label = "Widget";' }, "\n")
  write_file(emoji, emoji_text)
  local emoji_plan = plan_for({ documentChanges = { tde(emoji, { text_edit(1, 9, 1, 15, "WidgetNovo") }) } }, root)
  assert(type(emoji_plan) == "table", "plan recusou edit com offsets UTF-16")
  local emoji_after = join(emoji_plan.files[1].after)
  assert(emoji_after:find('label = "WidgetNovo"', 1, true), "offset UTF-16 errado:\n" .. emoji_after)
  assert(emoji_after:find("👍👍", 1, true), "conteúdo multibyte corrompido")
  apply_and_persist(emoji_plan, root)
  assert(read(emoji) == emoji_after, "disco diverge da prévia UTF-16")
end

-- ---------- F. Rename com referências em outros arquivos ----------

do
  local root = scenario_dir("f-rename-refs")
  local old = widget_fixture(root)
  local new = root .. "/src/WidgetRenamed.java"
  local main = root .. "/src/Main.java"
  write_file(
    main,
    table.concat({
      "package com.demo;",
      "",
      "public class Main {",
      "    Widget field = new Widget();",
      "}",
    }, "\n")
  )

  local edit = {
    documentChanges = {
      tde(main, { text_edit(3, 4, 3, 10, "WidgetRenamed"), text_edit(3, 23, 3, 29, "WidgetRenamed") }),
      tde(new, widget_edits("WidgetRenamed")),
      rename_op(old, new),
    },
  }
  local plan = plan_for(edit, root)
  assert(type(plan) == "table", "plan recusou rename com referências")
  assert(#plan.files == 2, "prévia deveria listar 2 arquivos, recebi " .. #plan.files)
  assert(#plan.ops == 3, "esperava 2 edits + rename, recebi " .. #plan.ops)

  apply_and_persist(plan, root)
  assert(read(main):find("WidgetRenamed field = new WidgetRenamed", 1, true), "referência não atualizada no disco")
  assert(vim.fn.filereadable(old) == 0, "origem não removida")
end

-- ---------- G. Operação desconhecida ----------

do
  local root = scenario_dir("g-unknown")
  local doc = widget_fixture(root)
  local untouched = read(doc)

  assert_plan_blocked(
    { documentChanges = { { kind = "copy", oldUri = uri(doc), newUri = uri(root .. "/src/Copy.java") } } },
    root,
    "operation not supported"
  )
  assert_plan_blocked(
    { command = "java.applyWorkspaceEdit", documentChanges = { tde(doc, { text_edit(0, 0, 0, 0, "x") }) } },
    root,
    "additional command"
  )
  assert_plan_blocked(
    { documentChanges = { { edits = { text_edit(0, 0, 0, 0, "x") } } } },
    root,
    "operation not supported"
  )
  assert(read(doc) == untouched, "operação desconhecida alterou arquivos")
  assert(vim.fn.filereadable(root .. "/src/Copy.java") == 0, "operação desconhecida criou arquivo")
end

-- ---------- H. Ordem inválida de operações ----------

do
  local root = scenario_dir("h-invalid-order")
  local a = widget_fixture(root, "Alpha")
  local b = root .. "/src/Beta.java"
  local c = root .. "/src/Gamma.java"
  local original = read(a)

  -- edit no caminho antigo DEPOIS do rename (hoje falharia no meio do apply)
  assert_plan_blocked(
    { documentChanges = { rename_op(a, b), tde(a, { text_edit(0, 0, 0, 0, "x") }) } },
    root,
    "after the rename"
  )
  -- cadeia de renames (Beta participaria de dois)
  assert_plan_blocked({ documentChanges = { rename_op(a, b), rename_op(b, c) } }, root, "more than one rename")
  -- dois renames para o mesmo destino (a origem Beta participa dos dois)
  assert_plan_blocked({ documentChanges = { rename_op(a, b), rename_op(c, b) } }, root, "more than one rename")
  -- delete da origem de um rename
  assert_plan_blocked({ documentChanges = { rename_op(a, b), delete_op(a) } }, root, "involved in a rename")
  -- create no destino/origem de um rename (colisão de destinos ou participante)
  assert_plan_blocked({ documentChanges = { rename_op(a, b), create_op(b) } }, root, "is the target of")
  -- TextDocumentEdit para documento inexistente sem origem
  assert_plan_blocked(
    { documentChanges = { tde(root .. "/src/Missing.java", { text_edit(0, 0, 0, 0, "x") }) } },
    root,
    "document not found"
  )
  -- TextDocumentEdit sem textDocument.uri
  assert_plan_blocked(
    { documentChanges = { { textDocument = { version = 7 }, edits = { text_edit(0, 0, 0, 0, "x") } } } },
    root,
    "without textDocument.uri"
  )
  assert(read(a) == original, "sequência inválida alterou arquivos")
  assert(vim.fn.filereadable(b) == 0 and vim.fn.filereadable(c) == 0, "sequência inválida criou arquivos")
end

-- ---------- I. Arquivo destino existente ----------

do
  local root = scenario_dir("i-dest-exists")
  local old = widget_fixture(root)
  local occupied = root .. "/src/WidgetRenamed.java"
  write_file(occupied, "class Occupied {}")

  local plan =
    plan_for({ documentChanges = { tde(occupied, widget_edits("WidgetRenamed")), rename_op(old, occupied) } }, root)
  assert(type(plan) == "table", "destino existente deveria bloquear no apply, não no plan")
  assert_apply_blocked(plan, "destination already exists")
  assert(read(old) == WIDGET, "origem alterada em apply bloqueado")
  assert(read(occupied) == "class Occupied {}", "destino sobrescrito em apply bloqueado")

  -- create em caminho existente
  local plan2 = plan_for({ documentChanges = { create_op(occupied) } }, root)
  assert(type(plan2) == "table", "create em existente deveria bloquear no apply")
  assert_apply_blocked(plan2, "file already exists")
  assert(read(occupied) == "class Occupied {}", "create sobrescreveu arquivo existente")
end

-- ---------- J. Buffer destino modificado ----------

do
  local root = scenario_dir("j-stale-dest")
  local old = widget_fixture(root)
  local new = root .. "/src/WidgetRenamed.java"

  local stale = vim.fn.bufadd(new)
  vim.api.nvim_buf_set_lines(stale, 0, -1, false, { "trabalho não salvo" })
  assert(vim.bo[stale].modified, "buffer stale de teste não ficou modificado")

  local plan = plan_for({ documentChanges = { tde(new, widget_edits("WidgetRenamed")), rename_op(old, new) } }, root)
  assert(type(plan) == "table", "buffer modificado no destino deveria bloquear no apply")
  assert_apply_blocked(plan, "unsaved modified buffer")
  assert(read(old) == WIDGET, "origem alterada em apply bloqueado")
  assert(vim.fn.filereadable(new) == 0, "apply bloqueado criou o destino")

  vim.bo[stale].modified = false
  vim.api.nvim_buf_delete(stale, { force = true })

  -- o mesmo bloqueio vale para CreateFile
  local fresh = root .. "/src/Fresh2.java"
  local stale2 = vim.fn.bufadd(fresh)
  vim.api.nvim_buf_set_lines(stale2, 0, -1, false, { "trabalho não salvo" })
  local plan2 = plan_for({ documentChanges = { create_op(fresh) } }, root)
  assert_apply_blocked(plan2, "unsaved modified buffer")
  assert(vim.fn.filereadable(fresh) == 0, "apply bloqueado criou o destino")
  vim.bo[stale2].modified = false
  vim.api.nvim_buf_delete(stale2, { force = true })
end

-- ---------- K. Alteração concorrente durante a prévia ----------

do
  local root = scenario_dir("k-concurrent")
  local old = widget_fixture(root)
  local new = root .. "/src/WidgetRenamed.java"

  local plan = plan_for({ documentChanges = { tde(new, widget_edits("WidgetRenamed")), rename_op(old, new) } }, root)
  -- o arquivo muda depois da prévia (concorrência)
  write_file(old, WIDGET:gsub("class Widget", "class WidgetTouched"))
  assert_apply_blocked(plan, "file changed since the preview")
  assert(read(old):find("class WidgetTouched", 1, true), "apply bloqueado alterou a origem")
  assert(vim.fn.filereadable(new) == 0, "apply bloqueado renomeou")

  -- buffer com tick alterado depois da prévia
  local doc = root .. "/src/Tick.java"
  write_file(doc, "int a = 1;")
  vim.cmd("edit " .. vim.fn.fnameescape(doc))
  local doc_buf = vim.api.nvim_get_current_buf()
  local plan2 = plan_for({ documentChanges = { tde(doc, { text_edit(0, 4, 0, 5, "b") }) } }, root)
  vim.api.nvim_buf_set_lines(doc_buf, 0, -1, false, { "int a = 2;" })
  assert_apply_blocked(plan2, "buffer changed since the preview")
  -- o arquivo em disco continua intacto; a mudança foi só no buffer
  assert(read(doc) == "int a = 1;", "apply bloqueado alterou o documento")
  vim.bo[doc_buf].modified = false
  vim.api.nvim_buf_delete(doc_buf, { force = true })
end

-- ---------- L. Cancelamento sem qualquer alteração ----------

do
  local root = scenario_dir("l-cancel")
  local old = widget_fixture(root)
  local new = root .. "/src/WidgetRenamed.java"
  local original_menu = ui.menu

  local plan = plan_for({ documentChanges = { tde(new, widget_edits("WidgetRenamed")), rename_op(old, new) } }, root)
  local buf_count = #vim.api.nvim_list_bufs()

  ui.menu = function(_, _, on_choice)
    on_choice({ key = "cancel" })
  end
  local done, applied = false, nil
  preview.review(plan, function(value)
    done, applied = true, value
  end)
  assert(done and applied == false, "cancelamento deveria devolver false")
  assert(has_notice("refactoring cancelled; nothing was changed"), "cancelamento não avisou: " .. vim.inspect(notices))
  assert(read(old) == WIDGET, "cancelamento alterou a origem")
  assert(vim.fn.filereadable(new) == 0, "cancelamento criou o destino")
  assert(#vim.api.nvim_list_bufs() == buf_count, "cancelamento criou buffers")
  assert(vim.fn.bufnr(new) == -1, "cancelamento criou buffer do destino")

  -- o caminho de aplicar pelo menu reproduz exatamente a prévia
  ui.menu = function(_, _, on_choice)
    on_choice({ key = "apply" })
  end
  notices = {}
  done, applied = false, nil
  preview.review(plan, function(value)
    done, applied = true, value
  end)
  assert(done and applied == true, "aplicar pelo menu deveria devolver true")
  assert(has_notice("applied:"), "aplicação pelo menu não avisou: " .. vim.inspect(notices))
  assert(vim.fn.filereadable(old) == 0, "apply pelo menu não removeu a origem")
  local buf = vim.fn.bufnr(new)
  assert(buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified, "apply pelo menu sem buffer pendente")
  assert(
    join(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) == join(plan.files[1].after),
    "apply pelo menu diverge da prévia"
  )
  vim.cmd("silent wa")
  assert(read(new) == join(plan.files[1].after), "disco diverge da prévia após :wa")

  ui.menu = original_menu
end

print("preview_workspaceedit_spec: OK")
vim.cmd("qa!")
