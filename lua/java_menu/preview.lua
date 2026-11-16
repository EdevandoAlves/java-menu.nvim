-- java_menu/preview.lua
-- WorkspaceEdit preview and application (rename/move) without touching
-- anything before the user approves.
--
-- Flow: normalize(edit) -> plan -> review (menu + diffs) -> apply
-- The preview is computed in temporary buffers (never in the real buffer or
-- on disk). Application revalidates ticks/content and only then changes
-- buffers/files.

local ui = require("java_menu.ui")

local M = {}

-- ---------- helpers ----------

---Normalize with realpath when possible; for a path that does not exist yet,
---resolve the real directory and keep the basename (rename destination).
---@param path string
---@return string
local function real_path(path)
  local real = vim.uv.fs_realpath(path)
  if real then
    return vim.fs.normalize(real)
  end
  local dir = vim.fs.dirname(path)
  local real_dir = vim.uv.fs_realpath(dir)
  if real_dir then
    return vim.fs.normalize(vim.fs.joinpath(real_dir, vim.fs.basename(path)))
  end
  return vim.fs.normalize(path)
end

---Real directory boundary: `/tmp/proj` does not contain `/tmp/proj2`.
---@param root string
---@param path string
---@return boolean
local function inside_project(root, path)
  if type(root) ~= "string" or type(path) ~= "string" then
    return false
  end
  local real_root = real_path(root)
  local real_path = real_path(path)
  if real_root == "" or real_path == "" then
    return false
  end
  if real_root == real_path then
    return true
  end
  local sep = real_root:sub(-1) == "/" and "" or "/"
  return real_path:sub(1, #real_root + #sep) == real_root .. sep
end

---Modified buffer pointing at `path`, even when the file does not exist.
---@param path string
---@return integer|nil
local function modified_buffer_for(path)
  local target = vim.fs.normalize(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fs.normalize(name) == target then
        return buf
      end
    end
  end
end

local function path_of(uri)
  return vim.uri_to_fname(uri)
end

local function relpath(root, path)
  return vim.fs.relpath(root, path) or path
end

---Compare the document named by the server with the content used in the plan.
---The preview does not track `OptionalVersionedTextDocumentIdentifier`; it is
---computed from the current state. It therefore only requires consistency
---between edits for the same URI.
---@param text_document table|nil
---@return string|nil reason
local function document_version_error(text_document, _)
  if type(text_document) ~= "table" or type(text_document.uri) ~= "string" then
    return "TextDocumentEdit without textDocument.uri"
  end
  return nil
end

---Document content to validate on reapplication: current buffer tick or file
---content, whichever the preview used.
---@param text_document table|nil
---@return string|nil reason
local function document_content_error(text_document, plan)
  if type(text_document) ~= "table" or type(text_document.uri) ~= "string" then
    return "TextDocumentEdit without textDocument.uri"
  end
  local path = path_of(text_document.uri)
  local file
  for _, candidate in ipairs(plan.files or {}) do
    if candidate.path == path then
      file = candidate
      break
    end
  end
  if not file then
    return "document without preview: " .. relpath(plan.root, path)
  end
  if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
    if vim.b[file.bufnr].changedtick ~= file.tick then
      return "buffer changed since the preview: " .. relpath(plan.root, file.source_path or file.path)
    end
    local now = vim.fn.readfile(file.source_path or file.path)
    if table.concat(now, "\n") ~= table.concat(file.before, "\n") then
      return "file changed since the preview: " .. relpath(plan.root, file.source_path or file.path)
    end
    return
  end
  local now = vim.fn.filereadable(file.source_path or file.path) == 1 and vim.fn.readfile(file.source_path or file.path)
    or nil
  if not now or table.concat(now, "\n") ~= table.concat(file.before, "\n") then
    return "file changed since the preview: " .. relpath(plan.root, file.source_path or file.path)
  end
end

---Current document content: buffer (if loaded) or file.
---@return string[]|nil lines, number|nil bufnr, number|nil tick
local function current_lines(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf, vim.b[buf].changedtick
  end
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path), nil, nil
  end
  return nil, nil, nil
end

---Apply text edits to a scratch buffer and return the resulting lines.
local function after_lines(lines, edits, encoding)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  local ok, err = pcall(vim.lsp.util.apply_text_edits, edits, scratch, encoding)
  local result
  if ok then
    result = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
  end
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  if not ok then
    return nil, tostring(err)
  end
  return result
end

---Unified diff + line counts.
local function make_diff(before, after, root, path)
  local unified = vim.diff(table.concat(before, "\n") .. "\n", table.concat(after, "\n") .. "\n", {
    result_type = "unified",
    ctxlen = 3,
  })
  local lines
  if type(unified) == "string" then
    lines = vim.split(unified, "\n", { plain = true })
  else
    lines = unified or {}
  end

  local header = { "--- a/" .. relpath(root, path), "+++ b/" .. relpath(root, path) }
  local added, removed = 0, 0
  for _, line in ipairs(lines) do
    if line:sub(1, 3) ~= "+++" and line:sub(1, 3) ~= "---" then
      if line:sub(1, 1) == "+" then
        added = added + 1
      elseif line:sub(1, 1) == "-" then
        removed = removed + 1
      end
    end
  end
  return vim.list_extend(header, lines), added, removed
end

-- ---------- normalization ----------

---Normalize a WorkspaceEdit into an ordered operation list.
---An unknown operation (or unexpected field) blocks everything.
---@param edit table
---@param opts { encoding: string, root: string }
---@return table|nil plan or nil + reason
function M.plan(edit, opts)
  if type(edit) ~= "table" then
    return nil, "empty WorkspaceEdit"
  end
  if edit.command ~= nil then
    return nil, "the server requested an additional command (unexpected side effect)"
  end

  local ops = {}

  local function push_edit(uri, edits, version)
    if type(uri) ~= "string" or type(edits) ~= "table" then
      return "invalid TextDocumentEdit"
    end
    for _, edit_item in ipairs(edits) do
      if type(edit_item) ~= "table" or not edit_item.range or edit_item.newText == nil then
        return "invalid TextEdit (missing range/newText)"
      end
    end
    ops[#ops + 1] = {
      kind = "edit",
      uri = uri,
      path = path_of(uri),
      edits = edits,
      version = version,
    }
  end

  local document_changes = edit.documentChanges
  if type(document_changes) == "table" and #document_changes > 0 then
    for _, change in ipairs(document_changes) do
      if type(change) ~= "table" then
        return nil, "documentChanges contains an invalid entry"
      end
      if change.kind == "create" then
        ops[#ops + 1] = { kind = "create", uri = change.uri, path = path_of(change.uri) }
      elseif change.kind == "rename" then
        ops[#ops + 1] = {
          kind = "rename",
          old_uri = change.oldUri,
          new_uri = change.newUri,
          old_path = path_of(change.oldUri),
          new_path = path_of(change.newUri),
        }
      elseif change.kind == "delete" then
        ops[#ops + 1] = { kind = "delete", uri = change.uri, path = path_of(change.uri) }
      elseif change.kind == nil and change.textDocument and change.edits then
        local err = document_version_error(change.textDocument, nil)
        if err then
          return nil, err
        end
        local server_version = change.textDocument.version
        if server_version == vim.NIL then
          server_version = nil
        end
        local err2 = push_edit(change.textDocument.uri, change.edits, server_version)
        if err2 then
          return nil, err2
        end
      else
        return nil, "operation not supported in WorkspaceEdit: " .. tostring(change.kind)
      end
    end
  elseif type(edit.changes) == "table" and next(edit.changes) ~= nil then
    for uri, edits in pairs(edit.changes) do
      local err = push_edit(uri, edits)
      if err then
        return nil, err
      end
    end
    table.sort(ops, function(a, b)
      return a.path < b.path
    end)
  else
    return nil, "WorkspaceEdit without changes/documentChanges"
  end

  -- rename targets: an edit may point to the new path, which does not exist
  -- does not exist on disk yet (jdtls sends the edit before RenameFile)
  local rename_targets = {}
  local rename_sources = {}
  for _, op in ipairs(ops) do
    if op.kind == "rename" then
      rename_targets[op.new_path] = op.old_path
      rename_sources[op.old_path] = true
    end
  end

  -- a document can have only one consistent source in the plan
  local document_sources = {}
  for _, op in ipairs(ops) do
    if op.kind == "rename" then
      for _, path in ipairs({ op.old_path, op.new_path }) do
        local other = document_sources[path]
        if other and other ~= op.old_path then
          return nil, "invalid sequence: " .. path .. " participates in more than one rename"
        end
        document_sources[path] = op.old_path
      end
    end
  end

  -- direct conflicts at the same destination
  local document_targets = {}
  for _, op in ipairs(ops) do
    if op.kind == "rename" then
      local old = document_targets[op.new_path]
      if old then
        return nil, "invalid sequence: " .. op.new_path .. " is the target of another rename (" .. old .. ")"
      end
      document_targets[op.new_path] = op.old_path
    elseif op.kind == "create" then
      local old = document_targets[op.path]
      if old then
        return nil, "invalid sequence: " .. op.path .. " is the target of " .. old
      end
      document_targets[op.path] = "create"
    end
  end

  -- rename targets cannot coincide with an earlier create/delete
  -- (current JDTLS does not emit these chains; if it does, block them)
  for _, op in ipairs(ops) do
    if op.kind == "create" and (rename_targets[op.path] or rename_sources[op.path]) then
      return nil, "invalid sequence: create on a path involved in a rename: " .. op.path
    end
    if op.kind == "delete" and (rename_targets[op.path] or rename_sources[op.path]) then
      return nil, "invalid sequence: delete on a path involved in a rename: " .. op.path
    end
  end

  -- files created before a TextDocumentEdit: the preview starts from an empty
  -- file because `CreateFile` does not exist on disk during planning
  local created_paths = {}
  for _, op in ipairs(ops) do
    if op.kind == "create" then
      created_paths[op.path] = true
    end
  end

  -- files with edits: compute before/after without touching anything
  local files = {}
  local seen_documents = {}
  local seen_sources = {}
  local renamed_away = {}
  for _, op in ipairs(ops) do
    if op.kind == "rename" then
      renamed_away[op.old_path] = true
    elseif op.kind == "edit" then
      -- edit on a path that an EARLIER rename already removed: the document
      -- no longer exists at that address (LSP applies in emitted order)
      if renamed_away[op.path] then
        return nil, "invalid sequence: edits for the old path after the rename: " .. op.path
      end
      local source_path = op.path
      if vim.fn.filereadable(op.path) == 0 and rename_targets[op.path] then
        source_path = rename_targets[op.path]
        op.rename_from = source_path
      end
      op.source_path = source_path

      local before, bufnr, tick
      if vim.fn.filereadable(source_path) == 0 and created_paths[source_path] then
        before = {}
      else
        before, bufnr, tick = current_lines(source_path)
        if not before then
          return nil, "document not found: " .. op.path
        end
      end
      if seen_documents[op.path] and seen_documents[op.path] ~= source_path then
        return nil, "edits for " .. op.path .. " point to documents with different sources"
      end
      -- a second TextDocumentEdit for the same document would have ranges
      -- shifted by the first; the preview does not model that, so block it
      if seen_sources[source_path] then
        return nil,
          "invalid sequence: more than one TextDocumentEdit for the document: " .. relpath(opts.root, source_path)
      end
      seen_documents[op.path] = source_path
      seen_sources[source_path] = true
      local after, err = after_lines(before, op.edits, opts.encoding)
      if not after then
        return nil, "failed to compute the preview for " .. op.path .. ": " .. err
      end
      op.after_lines = after
      local diff, added, removed = make_diff(before, after, opts.root, op.path)
      files[#files + 1] = {
        path = op.path,
        source_path = source_path,
        rename_from = op.rename_from,
        uri = op.uri,
        version = op.version,
        created = created_paths[op.path] == true,
        before = before,
        after = after,
        diff = diff,
        added = added,
        removed = removed,
        bufnr = bufnr,
        tick = tick,
        edits = op.edits,
      }
    end
  end

  return { root = opts.root, encoding = opts.encoding, ops = ops, files = files }
end

-- ---------- UI ----------

local function file_label(plan, file)
  return string.format("M  %s  (+%d/-%d)", relpath(plan.root, file.path), file.added, file.removed)
end

local function op_label(plan, op)
  if op.kind == "rename" then
    return string.format("R  %s → %s", relpath(plan.root, op.old_path), relpath(plan.root, op.new_path))
  elseif op.kind == "create" then
    return string.format("C  %s (novo)", relpath(plan.root, op.path))
  elseif op.kind == "delete" then
    return string.format("D  %s", relpath(plan.root, op.path))
  end
end

---Open the diff (read-only) in a split; `on_close` runs when it closes.
local function show_diff(plan, file, on_close)
  local prev_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, file.diff)
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.api.nvim_buf_set_name(buf, "java-preview://" .. relpath(plan.root, file.path))

  vim.cmd("sbuffer " .. buf)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].wrap = false

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    if vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
    on_close()
  end

  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close preview" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Close preview" })
end

---Review menu. Loops until Apply or Cancel.
---@param plan table
---@param on_done fun(applied: boolean)
function M.review(plan, on_done)
  local function open()
    local entries = {}

    for _, file in ipairs(plan.files) do
      entries[#entries + 1] = { label = file_label(plan, file), key = "file", file = file, enabled = true }
    end
    for _, op in ipairs(plan.ops) do
      if op.kind ~= "edit" then
        entries[#entries + 1] = {
          label = op_label(plan, op),
          key = "fileop",
          enabled = false,
          reason = "file operation (applied only on confirmation)",
        }
      end
    end
    entries[#entries + 1] = { label = "✔ Apply changes", key = "apply", enabled = true }
    entries[#entries + 1] = { label = "✖ Cancelar", key = "cancel", enabled = true }

    ui.menu(entries, "Java: Preview — changes", function(entry)
      if entry.key == "cancel" then
        ui.notify("refactoring cancelled; nothing was changed", vim.log.levels.INFO)
        on_done(false)
        return
      end
      if entry.key == "apply" then
        local result, problems = M.apply(plan)
        if not result then
          ui.notify("not applied: " .. table.concat(problems, "; "), vim.log.levels.ERROR)
          return
        end
        if result.error then
          ui.notify(
            "partial application: "
              .. result.error
              .. (
                result.applied
                  and #result.applied > 0
                  and (" | already applied: " .. table.concat(result.applied, ", "))
                or ""
              ),
            vim.log.levels.ERROR
          )
          on_done(true)
          return
        end
        local parts = {}
        if #plan.files > 0 then
          parts[#parts + 1] = string.format("%d file(s) with modified buffer (use :wa to save)", #plan.files)
        end
        local fileops = 0
        for _, op in ipairs(plan.ops) do
          if op.kind ~= "edit" then
            fileops = fileops + 1
          end
        end
        if fileops > 0 then
          parts[#parts + 1] = string.format("%d file operation(s) applied", fileops)
        end
        ui.notify("applied: " .. table.concat(parts, " · "))
        on_done(true)
        return
      end
      -- file: show the diff and return to the menu
      show_diff(plan, entry.file, open)
    end)
  end

  open()
end

-- ---------- application ----------

local function resolve_renames(plan)
  local map = {}
  for _, op in ipairs(plan.ops) do
    if op.kind == "rename" then
      map[op.old_path] = op.new_path
    end
  end
  return map
end

local function revalidate(plan)
  local problems = {}
  local renames = resolve_renames(plan)

  for _, file in ipairs(plan.files) do
    local path = file.source_path or file.path
    if renames[path] then
      path = renames[path]
    end
    if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
      if vim.b[file.bufnr].changedtick ~= file.tick then
        problems[#problems + 1] = "buffer changed since the preview: " .. relpath(plan.root, path)
      end
    elseif file.created and vim.fn.filereadable(file.source_path or file.path) == 0 then
      -- CreateFile does not exist on disk before application
    else
      local now = vim.fn.filereadable(file.source_path or file.path) == 1
          and vim.fn.readfile(file.source_path or file.path)
        or nil
      if not now or table.concat(now, "\n") ~= table.concat(file.before, "\n") then
        problems[#problems + 1] = "file changed since the preview: " .. relpath(plan.root, path)
      end
    end
  end

  for _, op in ipairs(plan.ops) do
    if op.kind == "rename" then
      if vim.fn.filereadable(op.old_path) == 0 then
        problems[#problems + 1] = "source does not exist: " .. relpath(plan.root, op.old_path)
      end
      if vim.fn.filereadable(op.new_path) == 1 then
        problems[#problems + 1] = "destination already exists: " .. relpath(plan.root, op.new_path)
      end
      if vim.fn.isdirectory(vim.fs.dirname(op.new_path)) == 0 then
        problems[#problems + 1] = "destination directory does not exist: "
          .. relpath(plan.root, vim.fs.dirname(op.new_path))
      end
      local stale = modified_buffer_for(op.new_path)
      if stale then
        problems[#problems + 1] = "the destination has an unsaved modified buffer: "
          .. relpath(plan.root, op.new_path)
          .. " — close/save this buffer before applying"
      end
    elseif op.kind == "create" then
      if vim.fn.filereadable(op.path) == 1 then
        problems[#problems + 1] = "file already exists: " .. relpath(plan.root, op.path)
      end
      local stale = modified_buffer_for(op.path)
      if stale then
        problems[#problems + 1] = "the destination has an unsaved modified buffer: "
          .. relpath(plan.root, op.path)
          .. " — close/save this buffer before applying"
      end
    elseif op.kind == "delete" then
      if vim.fn.filereadable(op.path) == 0 then
        problems[#problems + 1] = "file does not exist: " .. relpath(plan.root, op.path)
      end
      local stale = modified_buffer_for(op.path)
      if stale then
        problems[#problems + 1] = "the file has an unsaved modified buffer: "
          .. relpath(plan.root, op.path)
          .. " — close/save this buffer before applying"
      end
    end
  end

  -- everything inside the project
  for _, op in ipairs(plan.ops) do
    local paths = {}
    if op.kind == "rename" then
      paths = { op.old_path, op.new_path }
    else
      paths = { op.path }
    end
    for _, path in ipairs(paths) do
      if not inside_project(plan.root, path) then
        problems[#problems + 1] = "outside the project: " .. path
      end
    end
  end

  return problems
end

local function buffer_for(path)
  local buf = vim.fn.bufnr(path)
  if buf == -1 then
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
  end
  return buf
end

---Final content computed by the preview for the document being renamed.
local function after_for(plan, old_path)
  for _, file in ipairs(plan.files or {}) do
    if file.source_path == old_path then
      return file.after
    end
  end
end

local function apply_op(op, plan, renamed, applied_documents)
  if op.kind == "edit" then
    -- if an earlier RenameFile already materialized the content planned for
    -- this path, the subsequent TextDocumentEdit is already in the buffer
    if applied_documents[op.path] then
      return "edits already included in the rename: " .. relpath(plan.root, op.path)
    end
    local path = renamed[op.path] or op.source_path or op.path
    local buf = buffer_for(path)
    local content_error = document_content_error({ uri = op.uri, version = op.version }, plan)
    if content_error then
      error(content_error, 0)
    end
    vim.lsp.util.apply_text_edits(op.edits, buf, plan.encoding)
    if not vim.bo[buf].buflisted then
      vim.bo[buf].buflisted = true
    end
    return "edits " .. relpath(plan.root, path)
  elseif op.kind == "rename" then
    local ok, rc = pcall(vim.fn.rename, op.old_path, op.new_path)
    if not ok then
      error("rename falhou: " .. tostring(rc), 0)
    end
    if rc ~= 0 or vim.fn.filereadable(op.old_path) == 1 then
      error("rename failed (permission?): " .. relpath(plan.root, op.old_path), 0)
    end
    renamed[op.old_path] = op.new_path

    -- Align the buffer with the new path without writing anything: reload the file
    -- moved file and reapplies the preview content in memory. The user's
    -- `:wa` then writes without a prompt (correct b_mtime) and nothing is
    -- saved automatically.
    local old_buf = vim.fn.bufnr(op.old_path)
    local old_loaded = old_buf ~= -1 and vim.api.nvim_buf_is_loaded(old_buf)
    local after = after_for(plan, op.old_path)
    local win = old_loaded and vim.fn.bufwinid(old_buf) or -1
    local was_current = old_loaded and vim.api.nvim_get_current_buf() == old_buf
    -- the new buffer must inherit the old buffer's LSP clients,
    -- otherwise JDTLS loses the document after RenameFile/Move
    local old_clients = old_loaded and vim.lsp.get_clients({ bufnr = old_buf }) or {}

    local stale = vim.fn.bufnr(op.new_path)
    if stale ~= -1 and stale ~= old_buf and not vim.bo[stale].modified then
      pcall(vim.api.nvim_buf_delete, stale, { force = true })
    end

    if old_loaded then
      pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
    end

    local new_buf
    if win ~= -1 then
      pcall(vim.api.nvim_set_current_win, win)
      vim.cmd("edit " .. vim.fn.fnameescape(op.new_path))
      new_buf = vim.api.nvim_get_current_buf()
    else
      new_buf = vim.fn.bufadd(op.new_path)
      vim.fn.bufload(new_buf)
    end

    if after then
      vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, after)
      vim.bo[new_buf].modified = true
      applied_documents[op.new_path] = true
    end
    vim.bo[new_buf].buflisted = true
    for _, client in ipairs(old_clients) do
      local attached = vim.lsp.get_clients({ bufnr = new_buf, id = client.id })
      if #attached == 0 then
        pcall(vim.lsp.buf_attach_client, new_buf, client.id)
      end
    end

    if was_current and win == -1 then
      pcall(vim.api.nvim_set_current_buf, new_buf)
    end
    return "rename " .. relpath(plan.root, op.old_path) .. " → " .. relpath(plan.root, op.new_path)
  elseif op.kind == "create" then
    vim.fn.mkdir(vim.fs.dirname(op.path), "p")
    local ok, rc = pcall(vim.fn.writefile, {}, op.path)
    if not ok or rc ~= 0 or vim.fn.filereadable(op.path) == 0 then
      error("create falhou: " .. relpath(plan.root, op.path), 0)
    end
    return "create " .. relpath(plan.root, op.path)
  elseif op.kind == "delete" then
    local ok, rc = pcall(vim.fn.delete, op.path)
    if not ok or rc ~= 0 or vim.fn.filereadable(op.path) == 1 then
      error("delete falhou: " .. relpath(plan.root, op.path), 0)
    end
    local buf = vim.fn.bufnr(op.path)
    if buf ~= -1 then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    return "delete " .. relpath(plan.root, op.path)
  end
  error("unknown operation: " .. tostring(op.kind), 0)
end

---Apply the plan preserving the received order. The preview is the only
---content source; every TextDocumentEdit is revalidated against the planned
---document. Buffers are never written automatically (`:wa` belongs to the user).
---@return table|nil result, string[]|nil problems
function M.apply(plan)
  local problems = revalidate(plan)
  if #problems > 0 then
    return nil, problems
  end

  local applied = {}
  local renamed = {}
  local applied_documents = {}
  local seen_documents = {}
  for _, op in ipairs(plan.ops) do
    if op.kind == "edit" then
      local version_error = document_version_error({ uri = op.uri, version = op.version }, op.version)
      if version_error then
        return { applied = applied, error = version_error }
      end
      local source = seen_documents[op.path]
      if source and source ~= (op.source_path or op.path) then
        return {
          applied = applied,
          error = "invalid sequence: edits for the same document have different sources",
        }
      end
      seen_documents[op.path] = op.source_path or op.path
    end

    local ok, err = pcall(apply_op, op, plan, renamed, applied_documents)
    if not ok then
      return { applied = applied, error = tostring(err) }
    end
    applied[#applied + 1] = err
  end
  return { applied = applied }
end

-- exposed for tests
M._revalidate = revalidate
M._show_diff = show_diff
M._inside_project = inside_project
M._modified_buffer_for = modified_buffer_for
M._plan = M.plan
M._apply = M.apply

return M
