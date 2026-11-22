-- Regressão: limites reais de diretório no preview e buffer modificado no
-- destino de RenameFile.
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "luafile tests/java_menu/preview_paths_spec.lua" -c qa

local preview = require("java_menu.preview")
local is_linux = vim.uv.os_uname().sysname == "Linux"
local has_renameat2 = preview._has_renameat2()
if is_linux then
  assert(has_renameat2, "renameat2 deveria estar disponível no Linux")
end

local root_dir = vim.fn.tempname() .. "/java-menu-preview-spec"
local other_root = root_dir .. "2"
local linked_root = root_dir .. "-link"

local function uri(path)
  return vim.uri_from_fname(path)
end

vim.fn.mkdir(root_dir .. "/src", "p")
vim.fn.mkdir(other_root .. "/src", "p")
vim.fn.writefile({ "old" }, root_dir .. "/src/Main.java")
vim.fn.writefile({ "outside" }, other_root .. "/src/Main.java")
local real_root = vim.fs.normalize(vim.uv.fs_realpath(root_dir))

local function probe_symlink()
  local probe_link = root_dir .. "/src/.symlink_probe"
  os.remove(probe_link)
  local ok, err, code = vim.uv.fs_symlink(root_dir .. "/src/Main.java", probe_link)
  if ok then
    os.remove(probe_link)
    return true, nil
  end
  if is_linux then
    error("symlink deveria funcionar no Linux: " .. tostring(code or err), 0)
  end
  return false, tostring(code or err)
end

local can_symlink, symlink_skip_reason = probe_symlink()
if not can_symlink then
  print(
    "[preview_paths_spec] symlinks indisponíveis neste host ("
      .. symlink_skip_reason
      .. "); validando subconjunto portátil"
  )
end
if not has_renameat2 then
  print("[preview_paths_spec] renameat2 indisponível neste host; validando fallback portátil")
end

assert(preview._inside_project(root_dir, root_dir .. "/src/Main.java"), "caminho válido rejeitado")
assert(not preview._inside_project(root_dir, other_root .. "/src/Main.java"), "irmão do root aceito")
assert(not preview._inside_project(root_dir, root_dir .. "2/src/Main.java"), "sufixo de root aceito")

if can_symlink then
  -- symlink do root para o mesmo projeto continua válido
  os.remove(linked_root)
  assert(vim.uv.fs_symlink(root_dir, linked_root), "não consegui criar symlink do root")

  -- symlink dentro do projeto apontando para fora continua inválido
  os.remove(root_dir .. "/src/outside.txt")
  assert(vim.uv.fs_symlink(other_root .. "/src/Main.java", root_dir .. "/src/outside.txt"))
  os.remove(root_dir .. "/src/outside_dir")
  assert(vim.uv.fs_symlink(other_root .. "/src", root_dir .. "/src/outside_dir"))

  assert(preview._inside_project(linked_root, linked_root .. "/src/Main.java"), "root via symlink rejeitado")
  assert(
    preview._inside_project(root_dir, linked_root .. "/src/newpkg/sub/New.java"),
    "caminho multi-nível inexistente via alias do root rejeitado"
  )
  assert(not preview._inside_project(root_dir, root_dir .. "/src/outside.txt"), "symlink para fora aceito")
  assert(
    not preview._inside_project(root_dir, root_dir .. "/src/outside_dir/newpkg/Evil.java"),
    "caminho inexistente através de symlink externo aceito"
  )

  -- project.root / preferred / package_for via symlink (simula alias/short path)
  local project = require("java_menu.project")
  vim.fn.writefile({ "<project><artifactId>demo</artifactId></project>" }, root_dir .. "/pom.xml")
  vim.fn.mkdir(root_dir .. "/src/main/java/com/demo", "p")
  vim.fn.writefile({ "package com.demo;", "", "public class App {}" }, root_dir .. "/src/main/java/com/demo/App.java")
  local alias_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(alias_buf, linked_root .. "/src/main/java/com/demo/App.java")
  assert(
    project.root(alias_buf) == real_root,
    "project.root via alias divergiu: " .. tostring(project.root(alias_buf)) .. " ~= " .. real_root
  )
  local srs = project.source_roots(root_dir)
  local pref = project.preferred(srs, alias_buf)
  assert(pref and pref.path == real_root .. "/src/main/java", "project.preferred falhou via alias")
  local draft_alias_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(draft_alias_buf, linked_root .. "/src/main/java/com/demo/sub/Draft.java")
  assert(project.root(draft_alias_buf) == real_root, "project.root de arquivo inexistente via alias divergiu")
  assert(
    project.package_for(draft_alias_buf, srs[1].path) == "com.demo.sub",
    "project.package_for falhou via alias: " .. tostring(project.package_for(draft_alias_buf, srs[1].path))
  )

  -- buffer modificado no destino via alias (mesmo sem arquivo em disco)
  local alias_stale_path = linked_root .. "/src/AliasDraft.java"
  local real_stale_path = root_dir .. "/src/AliasDraft.java"
  local alias_stale_buf = vim.fn.bufadd(alias_stale_path)
  vim.api.nvim_buf_set_lines(alias_stale_buf, 0, -1, false, { "rascunho" })
  assert(vim.bo[alias_stale_buf].modified, "buffer alias não ficou modificado")
  assert(
    preview._modified_buffer_for(real_stale_path) == alias_stale_buf,
    "buffer modificado via alias não detectado pelo caminho real"
  )
  vim.bo[alias_stale_buf].modified = false
  pcall(vim.api.nvim_buf_delete, alias_stale_buf, { force = true })

  -- preview.plan + apply com URIs misturando caminho real e alias do root
  pcall(vim.api.nvim_buf_delete, alias_buf, { force = true })
  local loaded_alias_buf = vim.fn.bufadd(linked_root .. "/src/main/java/com/demo/App.java")
  vim.fn.bufload(loaded_alias_buf)
  local mixed_plan, mixed_err = preview.plan({
    documentChanges = {
      {
        textDocument = { uri = vim.uri_from_fname(linked_root .. "/src/main/java/com/demo/AppRenamed.java") },
        edits = {
          {
            range = { start = { line = 2, character = 13 }, ["end"] = { line = 2, character = 16 } },
            newText = "AppRenamed",
          },
        },
      },
      {
        kind = "rename",
        oldUri = vim.uri_from_fname(root_dir .. "/src/main/java/com/demo/App.java"),
        newUri = vim.uri_from_fname(root_dir .. "/src/main/java/com/demo/AppRenamed.java"),
      },
    },
  }, { root = real_root, encoding = "utf-16" })
  assert(mixed_plan ~= nil, "mixed alias preview.plan falhou: " .. tostring(mixed_err))
  assert(
    mixed_plan.files[1].diff[1] == "--- a/src/main/java/com/demo/AppRenamed.java",
    "diff header via alias não ficou relativo: " .. tostring(mixed_plan.files[1].diff[1])
  )
  local mixed_res, mixed_problems = preview._apply(mixed_plan)
  assert(
    mixed_res ~= nil and mixed_res.error == nil,
    "mixed alias apply falhou: " .. tostring(mixed_res and mixed_res.error) .. " / " .. vim.inspect(mixed_problems)
  )
  assert(vim.fn.filereadable(root_dir .. "/src/main/java/com/demo/AppRenamed.java") == 1, "arquivo renomeado ausente")
  pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(root_dir .. "/src/main/java/com/demo/AppRenamed.java"), { force = true })
end

-- buffer modificado no destino, mesmo sem arquivo em disco
local old_path = root_dir .. "/src/Main.java"
local new_path = root_dir .. "/src/Renamed.java"
local stale_buf = vim.fn.bufadd(new_path)
vim.api.nvim_buf_set_lines(stale_buf, 0, -1, false, { "trabalho não salvo" })
assert(vim.bo[stale_buf].modified, "buffer de teste não ficou modificado")
assert(preview._modified_buffer_for(new_path) == stale_buf, "buffer modificado não encontrado")

local plan = {
  root = root_dir,
  encoding = "utf-16",
  ops = { { kind = "rename", old_path = old_path, new_path = new_path } },
  files = {},
}
local problems = preview._revalidate(plan)
local has_modified_problem = false
for _, problem in ipairs(problems) do
  if problem:find("unsaved modified buffer", 1, true) then
    has_modified_problem = true
  end
end
assert(has_modified_problem, "revalidate não bloqueou buffer modificado: " .. vim.inspect(problems))

-- sem buffer modificado, a validação não reporta esse problema
vim.bo[stale_buf].modified = false
problems = preview._revalidate(plan)
for _, problem in ipairs(problems) do
  assert(not problem:find("unsaved modified buffer", 1, true), "problema fantasma de buffer modificado")
end

-- cancelamento não aplica nada
local applied = false
local original_menu = require("java_menu.ui").menu
require("java_menu.ui").menu = function(_, _, on_choice)
  on_choice({ key = "cancel" })
end
local done = false
preview.review(plan, function(value)
  applied = value
  done = true
end)
require("java_menu.ui").menu = original_menu
assert(done and not applied, "cancelamento alterou o estado do preview")
assert(table.concat(vim.fn.readfile(old_path), "\n") == "old", "cancelamento alterou o arquivo de origem")
assert(vim.fn.filereadable(new_path) == 0, "cancelamento criou o destino")

-- ---------- Regressão (1): symlinks quebrados em qualquer componente e escape ao escrever ----------

if can_symlink then
  -- 1a. symlink final quebrado -> fora do projeto
  local broken_leaf = root_dir .. "/src/broken_leaf.java"
  local outside_new = other_root .. "/src/EscapedNew.java"
  os.remove(broken_leaf)
  os.remove(outside_new)
  assert(vim.uv.fs_symlink(outside_new, broken_leaf), "não consegui criar symlink quebrado final")
  assert(not preview._inside_project(root_dir, broken_leaf), "inside_project aceitou symlink final quebrado")
  local broken_plan, broken_err = preview.plan({
    documentChanges = {
      { kind = "create", uri = uri(broken_leaf) },
    },
  }, { root = root_dir, encoding = "utf-16" })
  assert(broken_plan == nil, "preview.plan aceitou CreateFile em symlink final quebrado")
  assert(
    type(broken_err) == "string" and broken_err:find("broken symlink", 1, true) ~= nil,
    "motivo esperado de symlink quebrado ausente: " .. tostring(broken_err)
  )
  local manual_broken_plan = {
    root = root_dir,
    encoding = "utf-16",
    ops = { { kind = "create", uri = uri(broken_leaf), path = broken_leaf } },
    files = {},
  }
  local manual_problems = preview._revalidate(manual_broken_plan)
  assert(#manual_problems > 0, "revalidate aceitou CreateFile em symlink final quebrado")
  local manual_res = preview._apply(manual_broken_plan)
  assert(manual_res == nil, "apply executou CreateFile em symlink final quebrado")
  assert(vim.uv.fs_lstat(outside_new) == nil, "CreateFile escapou pelo symlink quebrado e criou fora do projeto")

  -- 1b. symlink quebrado em componente intermediário e travessia '..' pós-symlink
  local broken_dir = root_dir .. "/src/broken_dir"
  local outside_missing_dir = other_root .. "/missing_dir"
  os.remove(broken_dir)
  assert(vim.uv.fs_symlink(outside_missing_dir, broken_dir), "não consegui criar symlink quebrado intermediário")
  assert(
    not preview._inside_project(root_dir, broken_dir .. "/sub/Evil.java"),
    "inside_project aceitou symlink quebrado intermediário"
  )
  local broken_mid_plan = preview.plan({
    documentChanges = { { kind = "create", uri = uri(broken_dir .. "/sub/Evil.java") } },
  }, { root = root_dir, encoding = "utf-16" })
  assert(broken_mid_plan == nil, "preview.plan aceitou CreateFile sob symlink quebrado intermediário")
  local manual_mid_res = preview._apply({
    root = root_dir,
    encoding = "utf-16",
    ops = { { kind = "create", uri = uri(broken_dir .. "/sub/Evil.java"), path = broken_dir .. "/sub/Evil.java" } },
    files = {},
  })
  assert(manual_mid_res == nil, "apply aceitou CreateFile sob symlink quebrado intermediário")
  assert(vim.uv.fs_lstat(outside_missing_dir) == nil, "CreateFile criou diretório fora do projeto")

  assert(
    not preview._inside_project(root_dir, root_dir .. "/src/outside_dir/../escape/Evil.java"),
    "inside_project colapsou '..' antes de resolver symlink externo"
  )
  local dotdot_plan = preview.plan({
    documentChanges = { { kind = "create", uri = uri(root_dir .. "/src/outside_dir/../escape/Evil.java") } },
  }, { root = root_dir, encoding = "utf-16" })
  assert(dotdot_plan == nil, "preview.plan aceitou travessia '..' pós-symlink externo")

  -- 1c. escape ao escrever (TOCTOU durante CreateFile: symlink plantado antes da escrita)
  local toctou_dir = root_dir .. "/src/toctou_pkg"
  local toctou_target = toctou_dir .. "/EscapedWrite.java"
  local toctou_plan, toctou_err = preview.plan({
    documentChanges = { { kind = "create", uri = uri(toctou_target) } },
  }, { root = root_dir, encoding = "utf-16" })
  assert(toctou_plan ~= nil, "plan válido para TOCTOU falhou: " .. tostring(toctou_err))
  local orig_mkdir = vim.fn.mkdir
  vim.fn.mkdir = function(dir, ...)
    -- Simula corrida: imediatamente antes da escrita, o diretório vira symlink externo
    if dir == toctou_dir then
      pcall(os.remove, toctou_dir)
      assert(vim.uv.fs_symlink(other_root .. "/src", toctou_dir))
      return 1
    end
    return orig_mkdir(dir, ...)
  end
  local toctou_res = preview._apply(toctou_plan)
  vim.fn.mkdir = orig_mkdir
  pcall(os.remove, toctou_dir)
  assert(
    toctou_res ~= nil and toctou_res.error ~= nil,
    "apply deveria falhar quando diretório vira symlink externo antes da escrita"
  )
  assert(
    vim.uv.fs_lstat(other_root .. "/src/EscapedWrite.java") == nil,
    "CreateFile escapou e escreveu fora do projeto durante corrida"
  )

  -- 1d. escape ao escrever via symlink quebrado plantado no destino final após revalidate
  local toctou_leaf_dir = root_dir .. "/src/toctou_leaf_pkg"
  local toctou_leaf = toctou_leaf_dir .. "/Leaf.java"
  local leaf_escape_dst = other_root .. "/src/LeafEscaped.java"
  os.remove(leaf_escape_dst)
  local leaf_plan, leaf_err = preview.plan({
    documentChanges = { { kind = "create", uri = uri(toctou_leaf) } },
  }, { root = root_dir, encoding = "utf-16" })
  assert(leaf_plan ~= nil, "plan válido para TOCTOU leaf falhou: " .. tostring(leaf_err))
  vim.fn.mkdir = function(dir, ...)
    local rc = orig_mkdir(dir, ...)
    if dir == toctou_leaf_dir then
      assert(vim.uv.fs_symlink(leaf_escape_dst, toctou_leaf))
    end
    return rc
  end
  local leaf_res = preview._apply(leaf_plan)
  vim.fn.mkdir = orig_mkdir
  assert(leaf_res ~= nil and leaf_res.error ~= nil, "apply não bloqueou symlink quebrado plantado antes de criar")
  assert(vim.uv.fs_lstat(leaf_escape_dst) == nil, "CreateFile escreveu fora do projeto por symlink quebrado")
  vim.fn.delete(toctou_leaf_dir, "rf")

  -- 1e. alias válido do root continua funcionando para CreateFile + Edit + :wa
  local alias_created = linked_root .. "/src/newalias/CreatedViaAlias.java"
  local real_created = root_dir .. "/src/newalias/CreatedViaAlias.java"
  local alias_create_plan, alias_create_err = preview.plan({
    documentChanges = {
      { kind = "create", uri = uri(alias_created) },
      {
        textDocument = { uri = uri(alias_created) },
        edits = {
          {
            range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
            newText = "public class CreatedViaAlias {}",
          },
        },
      },
    },
  }, { root = real_root, encoding = "utf-16" })
  assert(alias_create_plan ~= nil, "CreateFile via alias válido do root falhou: " .. tostring(alias_create_err))
  local alias_create_res, alias_create_probs = preview._apply(alias_create_plan)
  assert(
    alias_create_res ~= nil and alias_create_res.error == nil,
    "apply via alias válido falhou: "
      .. tostring(alias_create_res and alias_create_res.error)
      .. " / "
      .. vim.inspect(alias_create_probs)
  )
  vim.cmd("silent wa")
  assert(vim.fn.filereadable(real_created) == 1, "arquivo criado via alias ausente no disco")
  assert(
    table.concat(vim.fn.readfile(real_created), "\n") == "public class CreatedViaAlias {}",
    "conteúdo criado via alias diverge"
  )
  pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(alias_created), { force = true })

  -- ---------- Regressão (2): buffer aberto por symlink de arquivo para origem em rename ----------

  -- 2a. Edit -> RenameFile quando o buffer foi aberto por symlink de arquivo (com alteração não salva)
  local sym_src = root_dir .. "/src/SymSource.java"
  local sym_alias = root_dir .. "/src/SymAlias.java"
  local sym_dst = root_dir .. "/src/SymRenamed.java"
  vim.fn.writefile({
    "package com.demo;",
    "",
    "public class SymSource {}",
  }, sym_src)
  os.remove(sym_alias)
  assert(vim.uv.fs_symlink(sym_src, sym_alias), "não consegui criar symlink de arquivo para origem")

  vim.cmd("edit " .. vim.fn.fnameescape(sym_alias))
  local alias_win = vim.api.nvim_get_current_win()
  local sym_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(sym_buf, 0, 1, false, { "package com.demo; // unsaved" })
  assert(vim.bo[sym_buf].modified, "buffer via symlink não ficou modificado")

  local sym_plan, sym_err = preview.plan({
    documentChanges = {
      {
        textDocument = { uri = uri(sym_dst) },
        edits = {
          {
            range = { start = { line = 2, character = 13 }, ["end"] = { line = 2, character = 22 } },
            newText = "SymRenamed",
          },
        },
      },
      { kind = "rename", oldUri = uri(sym_src), newUri = uri(sym_dst) },
    },
  }, { root = root_dir, encoding = "utf-16" })
  assert(sym_plan ~= nil, "preview.plan via file symlink falhou: " .. tostring(sym_err))

  local sym_res, sym_probs = preview._apply(sym_plan)
  assert(
    sym_res ~= nil and sym_res.error == nil,
    "apply via file symlink falhou: " .. tostring(sym_res and sym_res.error) .. " / " .. vim.inspect(sym_probs)
  )
  assert(vim.fn.filereadable(sym_src) == 0, "origem não foi movida no rename")
  assert(vim.fn.filereadable(sym_dst) == 1, "destino não foi criado no rename")
  assert(not vim.api.nvim_buf_is_valid(sym_buf), "buffer antigo via symlink ficou órfão/invisível")
  local new_win_buf = vim.api.nvim_win_get_buf(alias_win)
  assert(
    vim.uv.fs_realpath(vim.api.nvim_buf_get_name(new_win_buf)) == vim.uv.fs_realpath(sym_dst),
    "janela não foi atualizada para o buffer renomeado"
  )
  assert(vim.bo[new_win_buf].modified, "buffer renomeado deveria permanecer modified até :wa")
  local migrated_text = table.concat(vim.api.nvim_buf_get_lines(new_win_buf, 0, -1, false), "\n")
  assert(migrated_text:find("// unsaved", 1, true) ~= nil, "edição não salva do buffer via symlink foi perdida")
  assert(migrated_text:find("public class SymRenamed {}", 1, true) ~= nil, "edição do rename não foi aplicada")
  vim.cmd("silent wa")
  assert(table.concat(vim.fn.readfile(sym_dst), "\n") == migrated_text, "disco diverge após :wa")
  pcall(vim.api.nvim_buf_delete, new_win_buf, { force = true })
  os.remove(sym_alias)

  -- 2b. RenameFile puro (sem TextDocumentEdit) preserva alterações não salvas de buffer aberto por symlink
  local pure_src = root_dir .. "/src/PureSymSrc.java"
  local pure_alias = root_dir .. "/src/PureSymAlias.java"
  local pure_dst = root_dir .. "/src/PureSymDst.java"
  vim.fn.writefile({ "public class PureSymSrc {}" }, pure_src)
  os.remove(pure_alias)
  assert(vim.uv.fs_symlink(pure_src, pure_alias))
  vim.cmd("edit " .. vim.fn.fnameescape(pure_alias))
  local pure_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(pure_buf, 0, -1, false, { "public class PureSymSrc { int kept = 1; }" })
  assert(vim.bo[pure_buf].modified)

  local pure_plan, pure_err = preview.plan({
    documentChanges = {
      { kind = "rename", oldUri = uri(pure_src), newUri = uri(pure_dst) },
    },
  }, { root = root_dir, encoding = "utf-16" })
  assert(pure_plan ~= nil, "preview.plan de RenameFile puro falhou: " .. tostring(pure_err))
  local pure_res, pure_probs = preview._apply(pure_plan)
  assert(
    pure_res ~= nil and pure_res.error == nil,
    "apply de RenameFile puro via symlink falhou: "
      .. tostring(pure_res and pure_res.error)
      .. " / "
      .. vim.inspect(pure_probs)
  )
  assert(not vim.api.nvim_buf_is_valid(pure_buf), "buffer via symlink ficou órfão em RenameFile puro")
  local pure_new_buf = vim.fn.bufnr(pure_dst)
  assert(pure_new_buf ~= -1 and vim.api.nvim_buf_is_loaded(pure_new_buf), "buffer destino ausente em RenameFile puro")
  assert(vim.bo[pure_new_buf].modified, "buffer destino perdeu estado modified em RenameFile puro")
  assert(
    table.concat(vim.api.nvim_buf_get_lines(pure_new_buf, 0, -1, false), "\n")
      == "public class PureSymSrc { int kept = 1; }",
    "alterações não salvas foram perdidas em RenameFile puro via symlink"
  )
  vim.bo[pure_new_buf].modified = false
  pcall(vim.api.nvim_buf_delete, pure_new_buf, { force = true })
  os.remove(pure_alias)

  -- 2c. Mudança concorrente / perda de identidade no buffer via symlink bloqueia ANTES do rename
  local guard_src = root_dir .. "/src/GuardSrc.java"
  local guard_alias = root_dir .. "/src/GuardAlias.java"
  local guard_dst = root_dir .. "/src/GuardDst.java"
  vim.fn.writefile({ "public class GuardSrc {}" }, guard_src)
  os.remove(guard_alias)
  assert(vim.uv.fs_symlink(guard_src, guard_alias))
  vim.cmd("edit " .. vim.fn.fnameescape(guard_alias))
  local guard_buf = vim.api.nvim_get_current_buf()
  local guard_plan, guard_err = preview.plan({
    documentChanges = {
      { kind = "rename", oldUri = uri(guard_src), newUri = uri(guard_dst) },
      {
        textDocument = { uri = uri(guard_dst) },
        edits = {
          {
            range = { start = { line = 0, character = 13 }, ["end"] = { line = 0, character = 21 } },
            newText = "GuardDst",
          },
        },
      },
    },
  }, { root = root_dir, encoding = "utf-16" })
  assert(guard_plan ~= nil, "guard_plan falhou: " .. tostring(guard_err))
  vim.api.nvim_buf_set_lines(guard_buf, 0, -1, false, { "public class GuardSrc { int race = 1; }" })
  local guard_res, guard_probs = preview._apply(guard_plan)
  assert(guard_res == nil, "apply não bloqueou alteração concorrente no buffer via symlink")
  assert(
    vim.inspect(guard_probs):find("buffer changed", 1, true) ~= nil,
    "motivo inesperado ao bloquear buffer via symlink: " .. vim.inspect(guard_probs)
  )
  assert(vim.fn.filereadable(guard_src) == 1, "rename executou apesar do bloqueio")
  assert(vim.fn.filereadable(guard_dst) == 0, "destino criado apesar do bloqueio")
  vim.bo[guard_buf].modified = false
  pcall(vim.api.nvim_buf_delete, guard_buf, { force = true })
  os.remove(guard_alias)
end

-- ---------- Regressão (3): corrida no destino de RenameFile (no-replace atômico e limites) ----------

local function read_text(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function with_rename_trap(fn)
  local orig_rename = vim.fn.rename
  local called = false
  vim.fn.rename = function(...)
    called = true
    return orig_rename(...)
  end
  local ok, err = pcall(fn)
  vim.fn.rename = orig_rename
  assert(ok, err)
  assert(not called, "vim.fn.rename inseguro (overwrite) foi chamado")
end

local function with_uv_mocks(overrides, fn)
  local originals = {}
  for k, v in pairs(overrides) do
    originals[k] = vim.uv[k]
    vim.uv[k] = v
  end
  local ok, err = pcall(fn)
  for k, orig in pairs(originals) do
    vim.uv[k] = orig
  end
  assert(ok, err)
end

-- 3a. Corrida determinística com renameat2 real (buffer carregado): destino criado imediatamente
--     antes da operação não é sobrescrito
do
  local race_src = root_dir .. "/src/RaceLoadedSrc.java"
  local race_dst = root_dir .. "/src/RaceLoadedDst.java"
  vim.fn.writefile({ "public class RaceLoadedSrc {}" }, race_src)
  os.remove(race_dst)

  vim.cmd("edit " .. vim.fn.fnameescape(race_src))
  local race_buf = vim.api.nvim_get_current_buf()
  local race_plan, race_err = preview.plan({
    documentChanges = {
      {
        textDocument = { uri = uri(race_dst) },
        edits = {
          {
            range = { start = { line = 0, character = 13 }, ["end"] = { line = 0, character = 26 } },
            newText = "RaceLoadedDst",
          },
        },
      },
      { kind = "rename", oldUri = uri(race_src), newUri = uri(race_dst) },
    },
  }, { root = root_dir, encoding = "utf-16" })
  assert(race_plan ~= nil, "race_plan (3a) falhou: " .. tostring(race_err))

  local orig_get_clients = vim.lsp.get_clients
  local injected = false
  with_rename_trap(function()
    vim.lsp.get_clients = function(opts)
      if not injected and opts and opts.bufnr == race_buf then
        injected = true
        vim.fn.writefile({ "// concurrent winner 3a" }, race_dst)
      end
      return orig_get_clients(opts)
    end
    local ok_apply, res, probs = pcall(preview._apply, race_plan)
    vim.lsp.get_clients = orig_get_clients
    assert(ok_apply, tostring(res))
    assert(
      res ~= nil and res.error ~= nil,
      "apply deveria falhar quando destino surge antes do rename: " .. vim.inspect(probs)
    )
    assert(
      res.error:find("destination already exists", 1, true) ~= nil,
      "erro inesperado em 3a: " .. tostring(res.error)
    )
  end)

  assert(injected, "injeção de corrida em 3a não executou")
  assert(read_text(race_dst) == "// concurrent winner 3a", "destino concorrente foi sobrescrito em 3a")
  assert(read_text(race_src) == "public class RaceLoadedSrc {}", "origem em disco foi alterada em 3a")
  assert(vim.fn.bufnr(race_dst) == -1, "buffer do destino concorrente foi aberto indevidamente em 3a")
  vim.bo[race_buf].modified = false
  pcall(vim.api.nvim_buf_delete, race_buf, { force = true })
  os.remove(race_src)
  os.remove(race_dst)
end

-- 3b. Corrida determinística com renameat2 real (sem buffer carregado): injeção após pre-check de destino
do
  local disk_src = root_dir .. "/src/RaceDiskSrc.java"
  local disk_dst = root_dir .. "/src/RaceDiskDst.java"
  vim.fn.writefile({ "public class RaceDiskSrc {}" }, disk_src)
  os.remove(disk_dst)

  local disk_plan, disk_err = preview.plan({
    documentChanges = { { kind = "rename", oldUri = uri(disk_src), newUri = uri(disk_dst) } },
  }, { root = root_dir, encoding = "utf-16" })
  assert(disk_plan ~= nil, "disk_plan (3b) falhou: " .. tostring(disk_err))

  local real_lstat = vim.uv.fs_lstat
  local saw_precheck_dst_nil = false
  local injected = false
  with_rename_trap(function()
    with_uv_mocks({
      fs_lstat = function(p)
        local st, err, code = real_lstat(p)
        if p == disk_dst and st == nil then
          saw_precheck_dst_nil = true
        elseif saw_precheck_dst_nil and not injected and p == disk_src then
          injected = true
          vim.fn.writefile({ "// concurrent winner 3b" }, disk_dst)
        end
        return st, err, code
      end,
    }, function()
      local res, probs = preview._apply(disk_plan)
      assert(res ~= nil and res.error ~= nil, "apply deveria falhar em 3b: " .. vim.inspect(probs))
      assert(res.error:find("destination already exists", 1, true) ~= nil, "erro inesperado em 3b: " .. res.error)
    end)
  end)

  assert(injected, "injeção de corrida em 3b não executou")
  assert(read_text(disk_dst) == "// concurrent winner 3b", "destino concorrente foi sobrescrito em 3b")
  assert(read_text(disk_src) == "public class RaceDiskSrc {}", "origem foi alterada em 3b")
  os.remove(disk_src)
  os.remove(disk_dst)
end

-- 3c. Fallback portátil fs_link + fs_unlink: funciona sem renameat2 e preserva destino em corrida
do
  preview._renameat2_override = false
  local ok_block, err_block = pcall(function()
    local fb_src = root_dir .. "/src/FallbackSrc.java"
    local fb_dst = root_dir .. "/src/FallbackDst.java"
    vim.fn.writefile({ "public class FallbackSrc {}" }, fb_src)
    os.remove(fb_dst)
    vim.cmd("edit " .. vim.fn.fnameescape(fb_src))
    local fb_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(fb_buf, 0, -1, false, { "public class FallbackSrc { int ok = 1; }" })

    local ok_plan, ok_err = preview.plan({
      documentChanges = { { kind = "rename", oldUri = uri(fb_src), newUri = uri(fb_dst) } },
    }, { root = root_dir, encoding = "utf-16" })
    assert(ok_plan ~= nil, "ok_plan (3c) falhou: " .. tostring(ok_err))

    with_rename_trap(function()
      local res, probs = preview._apply(ok_plan)
      assert(
        res ~= nil and res.error == nil,
        "fallback fs_link falhou: " .. tostring(res and res.error) .. " / " .. vim.inspect(probs)
      )
    end)
    assert(vim.fn.filereadable(fb_src) == 0, "origem ainda existe após fallback fs_link")
    assert(read_text(fb_dst) == "public class FallbackSrc {}", "conteúdo em disco divergiu após fallback fs_link")
    local fb_new_buf = vim.fn.bufnr(fb_dst)
    assert(fb_new_buf ~= -1 and vim.bo[fb_new_buf].modified, "buffer modificado não foi preservado no fallback")
    vim.bo[fb_new_buf].modified = false
    pcall(vim.api.nvim_buf_delete, fb_new_buf, { force = true })
    os.remove(fb_dst)

    -- Corrida injetada imediatamente antes de vim.uv.fs_link
    local race_src = root_dir .. "/src/FallbackRaceSrc.java"
    local race_dst = root_dir .. "/src/FallbackRaceDst.java"
    vim.fn.writefile({ "public class FallbackRaceSrc {}" }, race_src)
    os.remove(race_dst)
    local race_plan = preview.plan({
      documentChanges = { { kind = "rename", oldUri = uri(race_src), newUri = uri(race_dst) } },
    }, { root = root_dir, encoding = "utf-16" })
    assert(race_plan ~= nil)

    local real_fs_link = vim.uv.fs_link
    local real_fs_unlink = vim.uv.fs_unlink
    local unlink_called = false
    with_rename_trap(function()
      with_uv_mocks({
        fs_link = function(oldp, newp)
          if newp == race_dst then
            vim.fn.writefile({ "// concurrent winner 3c" }, race_dst)
          end
          return real_fs_link(oldp, newp)
        end,
        fs_unlink = function(p)
          unlink_called = true
          return real_fs_unlink(p)
        end,
      }, function()
        local res = preview._apply(race_plan)
        assert(res ~= nil and res.error ~= nil, "fallback deveria falhar quando destino surge antes de fs_link")
        assert(res.error:find("destination already exists", 1, true) ~= nil, "erro inesperado em 3c: " .. res.error)
      end)
    end)
    assert(not unlink_called, "fs_unlink não deve rodar quando fs_link falha com EEXIST")
    assert(read_text(race_dst) == "// concurrent winner 3c", "destino concorrente sobrescrito no fallback fs_link")
    assert(read_text(race_src) == "public class FallbackRaceSrc {}", "origem alterada no fallback fs_link")
    os.remove(race_src)
    os.remove(race_dst)
  end)
  preview._renameat2_override = nil
  assert(ok_block, err_block)
end

-- 3d. Operações sem no-replace confiável são recusadas explicitamente (sem cair para vim.fn.rename)
do
  if can_symlink then
    local link_target = root_dir .. "/src/LinkTarget.java"
    local link_src = root_dir .. "/src/LinkSrc.java"
    local link_dst = root_dir .. "/src/LinkDst.java"
    vim.fn.writefile({ "public class LinkTarget {}" }, link_target)
    os.remove(link_src)
    os.remove(link_dst)
    assert(vim.uv.fs_symlink(link_target, link_src))

    local sym_race_plan = preview.plan({
      documentChanges = { { kind = "rename", oldUri = uri(link_src), newUri = uri(link_dst) } },
    }, { root = root_dir, encoding = "utf-16" })
    assert(sym_race_plan ~= nil)
    local real_lstat = vim.uv.fs_lstat

    if has_renameat2 then
      -- Com renameat2 (Linux): symlink é renomeado atomicamente e preserva destino em corrida
      local saw_nil, injected_sym_race = false, false
      with_rename_trap(function()
        with_uv_mocks({
          fs_lstat = function(p)
            local st, err, code = real_lstat(p)
            if p == link_dst and st == nil then
              saw_nil = true
            elseif saw_nil and not injected_sym_race and p == link_src then
              injected_sym_race = true
              vim.fn.writefile({ "// concurrent symlink dst" }, link_dst)
            end
            return st, err, code
          end,
        }, function()
          local res = preview._apply(sym_race_plan)
          assert(res ~= nil and res.error ~= nil and res.error:find("destination already exists", 1, true) ~= nil)
        end)
      end)
      assert(injected_sym_race and read_text(link_dst) == "// concurrent symlink dst")
      assert(real_lstat(link_src) and real_lstat(link_src).type == "link")
      os.remove(link_dst)

      -- Rename atômico real de symlink quando destino está livre
      with_rename_trap(function()
        local res, probs = preview._apply(sym_race_plan)
        assert(
          res ~= nil and res.error == nil,
          "renameat2 em symlink falhou: " .. tostring(res and res.error) .. " / " .. vim.inspect(probs)
        )
      end)
      assert(real_lstat(link_src) == nil and real_lstat(link_dst) and real_lstat(link_dst).type == "link")
      assert(read_text(link_target) == "public class LinkTarget {}")
      -- Move de volta para testar recusa sem renameat2
      os.remove(link_dst)
      assert(vim.uv.fs_symlink(link_target, link_src))
    else
      -- Sem renameat2 (ex.: macOS): symlink é recusado explicitamente mesmo com destino livre
      with_rename_trap(function()
        local res = preview._apply(sym_race_plan)
        assert(res ~= nil and res.error ~= nil, "symlink deveria ser recusado sem renameat2")
        assert(res.error:find("not supported for symlinks", 1, true) ~= nil, "erro inesperado: " .. res.error)
      end)
      assert(real_lstat(link_src) and real_lstat(link_src).type == "link")
      assert(real_lstat(link_dst) == nil)
    end

    -- Sem renameat2: symlink deve ser recusado explicitamente (não usa fs_link nem vim.fn.rename)
    preview._renameat2_override = false
    local ok_sym_refuse, err_sym_refuse = pcall(function()
      with_rename_trap(function()
        local res = preview._apply(sym_race_plan)
        assert(res ~= nil and res.error ~= nil, "symlink deveria ser recusado sem renameat2")
        assert(res.error:find("not supported for symlinks", 1, true) ~= nil, "erro inesperado: " .. res.error)
      end)
    end)
    preview._renameat2_override = nil
    assert(ok_sym_refuse, err_sym_refuse)
    assert(real_lstat(link_src).type == "link" and real_lstat(link_dst) == nil)

    -- ENOSYS de renameat2 em symlink também recusa explicitamente sem fallback
    preview._renameat2_override = function()
      return false, -vim.uv.errno.ENOSYS
    end
    local ok_enosys_sym, err_enosys_sym = pcall(function()
      with_rename_trap(function()
        local res = preview._apply(sym_race_plan)
        assert(res ~= nil and res.error ~= nil)
        assert(res.error:find("not supported for non-regular files", 1, true) ~= nil, "erro inesperado: " .. res.error)
      end)
    end)
    preview._renameat2_override = nil
    assert(ok_enosys_sym, err_enosys_sym)
    os.remove(link_src)
    os.remove(link_target)
  end

  -- ENOSYS de renameat2 em arquivo regular cai com segurança para fs_link + fs_unlink
  local enosys_src = root_dir .. "/src/EnosysRegSrc.java"
  local enosys_dst = root_dir .. "/src/EnosysRegDst.java"
  vim.fn.writefile({ "public class EnosysRegSrc {}" }, enosys_src)
  os.remove(enosys_dst)
  local enosys_plan = preview.plan({
    documentChanges = { { kind = "rename", oldUri = uri(enosys_src), newUri = uri(enosys_dst) } },
  }, { root = root_dir, encoding = "utf-16" })
  preview._renameat2_override = function()
    return false, -vim.uv.errno.ENOSYS
  end
  local ok_enosys_reg, err_enosys_reg = pcall(function()
    with_rename_trap(function()
      local res = preview._apply(enosys_plan)
      assert(res ~= nil and res.error == nil, "fallback pós-ENOSYS falhou: " .. tostring(res and res.error))
    end)
  end)
  preview._renameat2_override = nil
  assert(ok_enosys_reg, err_enosys_reg)
  assert(vim.fn.filereadable(enosys_src) == 0 and read_text(enosys_dst) == "public class EnosysRegSrc {}")
  os.remove(enosys_dst)

  -- EXDEV (cross-device) é recusado explicitamente tanto em renameat2 quanto em fs_link
  local exdev_src = root_dir .. "/src/ExdevSrc.java"
  local exdev_dst = root_dir .. "/src/ExdevDst.java"
  vim.fn.writefile({ "public class ExdevSrc {}" }, exdev_src)
  os.remove(exdev_dst)
  local exdev_plan = preview.plan({
    documentChanges = { { kind = "rename", oldUri = uri(exdev_src), newUri = uri(exdev_dst) } },
  }, { root = root_dir, encoding = "utf-16" })

  preview._renameat2_override = function()
    return false, -vim.uv.errno.EXDEV
  end
  local ok_ex1, err_ex1 = pcall(function()
    with_rename_trap(function()
      local res = preview._apply(exdev_plan)
      assert(res ~= nil and res.error ~= nil and res.error:find("cross-device", 1, true) ~= nil)
    end)
  end)
  preview._renameat2_override = nil
  assert(ok_ex1, err_ex1)

  preview._renameat2_override = false
  local ok_ex2, err_ex2 = pcall(function()
    with_rename_trap(function()
      with_uv_mocks({
        fs_link = function()
          return nil, "EXDEV: cross-device link", "EXDEV"
        end,
      }, function()
        local res = preview._apply(exdev_plan)
        assert(res ~= nil and res.error ~= nil and res.error:find("cross-device", 1, true) ~= nil)
      end)
    end)
  end)
  preview._renameat2_override = nil
  assert(ok_ex2, err_ex2)
  assert(read_text(exdev_src) == "public class ExdevSrc {}" and vim.uv.fs_lstat(exdev_dst) == nil)
  os.remove(exdev_src)
end

-- 3e. Fail-safe no fallback fs_link + fs_unlink: falha de unlink e troca concorrente da origem/destino
do
  preview._renameat2_override = false
  local ok_block, err_block = pcall(function()
    -- Falha de fs_unlink faz rollback seguro de dst (mesmo inode) e preserva src
    local rb_src = root_dir .. "/src/RollbackSrc.java"
    local rb_dst = root_dir .. "/src/RollbackDst.java"
    vim.fn.writefile({ "public class RollbackSrc {}" }, rb_src)
    os.remove(rb_dst)
    local rb_plan = preview.plan({
      documentChanges = { { kind = "rename", oldUri = uri(rb_src), newUri = uri(rb_dst) } },
    }, { root = root_dir, encoding = "utf-16" })
    local real_unlink = vim.uv.fs_unlink
    with_uv_mocks({
      fs_unlink = function(p)
        if p == rb_src then
          return nil, "EACCES: simulated", "EACCES"
        end
        return real_unlink(p)
      end,
    }, function()
      local res = preview._apply(rb_plan)
      assert(res ~= nil and res.error ~= nil and res.error:find("removing source", 1, true) ~= nil)
    end)
    assert(read_text(rb_src) == "public class RollbackSrc {}" and vim.uv.fs_lstat(rb_dst) == nil)

    -- Se dst for trocado por arquivo estrangeiro antes do rollback, rollback NÃO apaga o arquivo estrangeiro
    with_uv_mocks({
      fs_unlink = function(p)
        if p == rb_src then
          os.remove(rb_dst)
          vim.fn.writefile({ "// foreign dst replacement" }, rb_dst)
          return nil, "EACCES: simulated", "EACCES"
        end
        return real_unlink(p)
      end,
    }, function()
      local res = preview._apply(rb_plan)
      assert(res ~= nil and res.error ~= nil and res.error:find("preserved", 1, true) ~= nil)
    end)
    assert(read_text(rb_dst) == "// foreign dst replacement", "rollback apagou arquivo estrangeiro no destino")
    assert(read_text(rb_src) == "public class RollbackSrc {}")
    os.remove(rb_dst)

    -- Se src for trocado por arquivo estrangeiro após fs_link, não chama fs_unlink em src e preserva ambos
    local real_link = vim.uv.fs_link
    local unlinked_src = false
    with_uv_mocks({
      fs_link = function(oldp, newp)
        local ok_l, err_l, code_l = real_link(oldp, newp)
        if ok_l and oldp == rb_src then
          os.remove(rb_src)
          vim.fn.writefile({ "// foreign src replacement" }, rb_src)
        end
        return ok_l, err_l, code_l
      end,
      fs_unlink = function(p)
        if p == rb_src then
          unlinked_src = true
        end
        return real_unlink(p)
      end,
    }, function()
      local res = preview._apply(rb_plan)
      assert(res ~= nil and res.error ~= nil and res.error:find("refusing to unlink source", 1, true) ~= nil)
    end)
    assert(not unlinked_src, "fs_unlink foi chamado após troca concorrente da origem")
    assert(read_text(rb_src) == "// foreign src replacement", "origem trocada concorrentemente foi removida")
    assert(read_text(rb_dst) == "public class RollbackSrc {}", "inode original preservado no destino")
    os.remove(rb_src)
    os.remove(rb_dst)
  end)
  preview._renameat2_override = nil
  assert(ok_block, err_block)
end

-- 3f. Symlink quebrado plantado no destino durante corrida também é preservado (renameat2 e fs_link)
if can_symlink then
  for _, disable_r2 in ipairs({ false, true }) do
    if disable_r2 then
      preview._renameat2_override = false
    end
    local ok_case, err_case = pcall(function()
      local dl_src = root_dir .. "/src/DanglingRaceSrc.java"
      local dl_dst = root_dir .. "/src/DanglingRaceDst.java"
      local dl_target = root_dir .. "/src/MissingTarget.java"
      vim.fn.writefile({ "public class DanglingRaceSrc {}" }, dl_src)
      os.remove(dl_dst)
      os.remove(dl_target)
      local dl_plan = preview.plan({
        documentChanges = { { kind = "rename", oldUri = uri(dl_src), newUri = uri(dl_dst) } },
      }, { root = root_dir, encoding = "utf-16" })
      local real_lstat = vim.uv.fs_lstat
      local saw_nil, injected = false, false
      with_rename_trap(function()
        with_uv_mocks({
          fs_lstat = function(p)
            local st, err, code = real_lstat(p)
            if p == dl_dst and st == nil then
              saw_nil = true
            elseif saw_nil and not injected and p == dl_src then
              injected = true
              assert(vim.uv.fs_symlink(dl_target, dl_dst))
            end
            return st, err, code
          end,
        }, function()
          local res = preview._apply(dl_plan)
          assert(res ~= nil and res.error ~= nil and res.error:find("destination already exists", 1, true) ~= nil)
        end)
      end)
      assert(injected)
      local st_dst = real_lstat(dl_dst)
      assert(st_dst ~= nil and st_dst.type == "link", "symlink quebrado no destino foi sobrescrito")
      assert(read_text(dl_src) == "public class DanglingRaceSrc {}")
      os.remove(dl_dst)
      os.remove(dl_src)
    end)
    preview._renameat2_override = nil
    assert(ok_case, err_case)
  end
end

print("preview_paths_spec: OK")
vim.cmd("qa!")
