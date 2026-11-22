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

local is_win = vim.fn.has("win32") == 1

---Resolve `path` to its canonical path when it exists, or canonicalize its
---deepest existing ancestor and keep the non-existent tail.
---Refuses broken symlinks (or unresolvable links/paths) in any component,
---without collapsing `..` across symlinks before resolution.
---@param path string
---@return string|nil resolved, string|nil err
local function resolve_path(path)
  if type(path) ~= "string" or path == "" then
    return nil, "invalid path"
  end

  local raw = is_win and path:gsub("\\", "/") or path
  local real_full = vim.uv.fs_realpath(raw)
  if real_full then
    return vim.fs.normalize(real_full)
  end

  local p = raw
  local is_abs = p:sub(1, 1) == "/"
    or (is_win and (p:match("^%a:/") ~= nil or p:match("^%a:$") ~= nil or p:sub(1, 2) == "//"))
  if not is_abs then
    local cwd = vim.uv.cwd() or "."
    if is_win then
      cwd = cwd:gsub("\\", "/")
    end
    p = cwd:gsub("/+$", "") .. "/" .. p
  end

  local prefix, rest
  if is_win and p:match("^//[^/]+/[^/]+") then
    prefix = p:match("^(//[^/]+/[^/]+)")
    rest = p:sub(#prefix + 1)
  elseif is_win and p:match("^%a:/") then
    prefix = p:sub(1, 3)
    rest = p:sub(4)
  elseif is_win and p:match("^%a:$") then
    prefix = p .. "/"
    rest = ""
  else
    prefix = "/"
    rest = p:sub(2)
  end

  local real_prefix = vim.uv.fs_realpath(prefix)
  local cur = real_prefix and vim.fs.normalize(real_prefix) or prefix
  local in_missing = false
  local tail = {}

  for seg in rest:gmatch("[^/]+") do
    if seg == "." then
      -- no-op
    elseif seg == ".." then
      if in_missing then
        if #tail > 0 then
          table.remove(tail)
          if #tail == 0 then
            in_missing = false
          end
        end
      else
        local up = (cur == "/" and "" or cur:gsub("/+$", "")) .. "/.."
        local real_up, uerr, ucode = vim.uv.fs_realpath(up)
        if not real_up then
          return nil, "unresolvable parent path (" .. tostring(ucode or uerr) .. "): " .. up
        end
        cur = vim.fs.normalize(real_up)
      end
    else
      if in_missing then
        tail[#tail + 1] = seg
      else
        local base = cur == "/" and "" or cur:gsub("/+$", "")
        local next_path = base .. "/" .. seg
        local lstat, lerr, lcode = vim.uv.fs_lstat(next_path)
        if lstat then
          local real_next, rerr, rcode = vim.uv.fs_realpath(next_path)
          if not real_next then
            if lstat.type == "link" then
              return nil, "broken symlink: " .. next_path
            end
            return nil, "unresolvable path (" .. tostring(rcode or rerr) .. "): " .. next_path
          end
          cur = vim.fs.normalize(real_next)
        elseif lcode == "ENOENT" or lcode == "ENOTDIR" then
          in_missing = true
          tail[#tail + 1] = seg
        else
          return nil, "unresolvable path (" .. tostring(lcode or lerr) .. "): " .. next_path
        end
      end
    end
  end

  if #tail == 0 then
    return vim.fs.normalize(cur)
  end
  local base = cur == "/" and "" or cur:gsub("/+$", "")
  return vim.fs.normalize(base .. "/" .. table.concat(tail, "/"))
end

---Real directory boundary: `/tmp/proj` does not contain `/tmp/proj2`.
---Rejects broken symlinks or unresolvable paths in any component.
---@param root string
---@param path string
---@return boolean
local function inside_project(root, path)
  if type(root) ~= "string" or type(path) ~= "string" then
    return false
  end
  local real_root = resolve_path(root)
  local real_target = resolve_path(path)
  if not real_root or not real_target or real_root == "" or real_target == "" then
    return false
  end
  if real_root == real_target then
    return true
  end
  local sep = real_root:sub(-1) == "/" and "" or "/"
  return real_target:sub(1, #real_root + #sep) == real_root .. sep
end

---Validate that `path` resolves cleanly (no broken symlinks in any component)
---and remains inside `root`.
---@param root string
---@param path string
---@return string|nil resolved, string|nil reason
local function validate_op_path(root, path)
  local real_root, root_err = resolve_path(root)
  if not real_root or real_root == "" then
    return nil, root_err or ("invalid project root: " .. tostring(root))
  end
  local real_target, target_err = resolve_path(path)
  if not real_target or real_target == "" then
    return nil, target_err or ("invalid path: " .. tostring(path))
  end
  local sep = real_root:sub(-1) == "/" and "" or "/"
  if real_root ~= real_target and real_target:sub(1, #real_root + #sep) ~= real_root .. sep then
    return nil, "outside the project: " .. path
  end
  return real_target, nil
end

---Locate all existing valid buffers pointing to `path` (by direct path or
---canonical resolution via symlink/short path).
---@param path string
---@return integer[]
local function find_buffers_for(path)
  local target, target_err = resolve_path(path)
  local seen = {}
  local result = {}
  local direct = vim.fn.bufnr(path)
  if direct ~= -1 and vim.api.nvim_buf_is_valid(direct) then
    local name = vim.api.nvim_buf_get_name(direct)
    local name_real = name ~= "" and resolve_path(name) or nil
    if (target and name_real == target) or (not target and not target_err and name == path) then
      seen[direct] = true
      result[#result + 1] = direct
    end
  end
  if target then
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if not seen[candidate] and vim.api.nvim_buf_is_valid(candidate) then
        local name = vim.api.nvim_buf_get_name(candidate)
        if name ~= "" and resolve_path(name) == target then
          seen[candidate] = true
          result[#result + 1] = candidate
        end
      end
    end
  end
  return result
end

local function buffer_priority(buf)
  local loaded = vim.api.nvim_buf_is_loaded(buf)
  if loaded and vim.bo[buf].modified then
    return 4
  end
  if loaded and vim.fn.bufwinid(buf) ~= -1 then
    return 3
  end
  if loaded then
    return 2
  end
  return 1
end

---Locate the primary existing buffer for `path`, falling back to canonical path
---matching when the buffer was opened through a Windows short path or symlink.
---@param path string
---@return integer
local function find_buffer_for(path)
  local bufs = find_buffers_for(path)
  if #bufs == 0 then
    return -1
  end
  local best = bufs[1]
  local best_prio = buffer_priority(best)
  for i = 2, #bufs do
    local prio = buffer_priority(bufs[i])
    if prio > best_prio then
      best = bufs[i]
      best_prio = prio
    end
  end
  return best
end

---Modified buffer pointing at `path`, even when the file does not exist.
---@param path string
---@return integer|nil
local function modified_buffer_for(path)
  local target = resolve_path(path)
  if not target then
    return nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and resolve_path(name) == target then
        return buf
      end
    end
  end
end

local function path_of(uri)
  local fname = vim.uri_to_fname(uri)
  if is_win then
    fname = fname:gsub("\\", "/")
    local unc = fname:match("^//")
    fname = (unc or "") .. fname:sub(unc and 3 or 1):gsub("//+", "/")
    return fname
  end
  return (fname:gsub("//+", "/"))
end

local function relpath(root, path)
  if type(root) ~= "string" or root == "" then
    return path
  end
  local real_root = resolve_path(root)
  local real_target = resolve_path(path)
  if not real_root or not real_target then
    return path
  end
  return vim.fs.relpath(real_root, real_target) or path
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

local function disk_content_matches(path, file)
  local now = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path, "b") or nil
  local expected_disk = file.disk_before or file.before
  return now ~= nil and expected_disk ~= nil and table.concat(now, "\n") == table.concat(expected_disk, "\n")
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
  local key, key_err = resolve_path(path)
  if not key then
    return key_err or ("invalid path: " .. path)
  end
  local file
  for _, candidate in ipairs(plan.files or {}) do
    local cand_key = candidate.path_key or resolve_path(candidate.path)
    if cand_key and cand_key == key then
      file = candidate
      break
    end
  end
  if not file then
    return "document without preview: " .. relpath(plan.root, path)
  end
  local src_path = file.source_path or file.path
  if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
    local buf_name = vim.api.nvim_buf_get_name(file.bufnr)
    local buf_key = buf_name ~= "" and resolve_path(buf_name) or nil
    local src_key = file.source_key or resolve_path(src_path)
    if not buf_key or not src_key or buf_key ~= src_key then
      return "buffer identity changed since the preview: " .. relpath(plan.root, src_path)
    end
    if vim.b[file.bufnr].changedtick ~= file.tick then
      return "buffer changed since the preview: " .. relpath(plan.root, src_path)
    end
    if not disk_content_matches(src_path, file) then
      return "file changed since the preview: " .. relpath(plan.root, src_path)
    end
    return
  end
  if not disk_content_matches(src_path, file) then
    return "file changed since the preview: " .. relpath(plan.root, src_path)
  end
end

---Current document content: buffer (if loaded) or file.
---@return string[]|nil lines, number|nil bufnr, number|nil tick
local function current_lines(path)
  local buf = find_buffer_for(path)
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

  local root = type(opts) == "table" and opts.root or nil
  local has_root = type(root) == "string" and root ~= ""
  local function plan_resolve(path)
    if has_root then
      return validate_op_path(root, path)
    end
    return resolve_path(path)
  end

  for _, op in ipairs(ops) do
    if op.kind == "rename" then
      local old_key, old_err = plan_resolve(op.old_path)
      if not old_key then
        return nil, old_err
      end
      local new_key, new_err = plan_resolve(op.new_path)
      if not new_key then
        return nil, new_err
      end
      op.old_key = old_key
      op.new_key = new_key
    else
      local key, err = plan_resolve(op.path)
      if not key then
        return nil, err
      end
      op.path_key = key
    end
  end

  -- rename targets: an edit may point to the new path, which does not exist
  -- on disk yet (jdtls sends the edit before RenameFile)
  local rename_targets = {}
  local rename_sources = {}
  for _, op in ipairs(ops) do
    if op.kind == "rename" then
      rename_targets[op.new_key] = op.old_path
      rename_sources[op.old_key] = true
    end
  end

  -- a document can have only one consistent source in the plan
  local document_sources = {}
  for _, op in ipairs(ops) do
    if op.kind == "rename" then
      local old_key = op.old_key
      for _, entry in ipairs({ { path = op.old_path, key = op.old_key }, { path = op.new_path, key = op.new_key } }) do
        local other = document_sources[entry.key]
        if other and other ~= old_key then
          return nil, "invalid sequence: " .. entry.path .. " participates in more than one rename"
        end
        document_sources[entry.key] = old_key
      end
    end
  end

  -- direct conflicts at the same destination
  local document_targets = {}
  for _, op in ipairs(ops) do
    if op.kind == "rename" then
      local new_key = op.new_key
      local old = document_targets[new_key]
      if old then
        return nil, "invalid sequence: " .. op.new_path .. " is the target of another rename (" .. old .. ")"
      end
      document_targets[new_key] = op.old_path
    elseif op.kind == "create" then
      local key = op.path_key
      local old = document_targets[key]
      if old then
        return nil, "invalid sequence: " .. op.path .. " is the target of " .. old
      end
      document_targets[key] = "create"
    end
  end

  -- rename targets cannot coincide with an earlier create/delete
  -- (current JDTLS does not emit these chains; if it does, block them)
  for _, op in ipairs(ops) do
    if op.kind == "create" then
      local key = op.path_key
      if rename_targets[key] or rename_sources[key] then
        return nil, "invalid sequence: create on a path involved in a rename: " .. op.path
      end
    elseif op.kind == "delete" then
      local key = op.path_key
      if rename_targets[key] or rename_sources[key] then
        return nil, "invalid sequence: delete on a path involved in a rename: " .. op.path
      end
    end
  end

  -- files created before a TextDocumentEdit: the preview starts from an empty
  -- file because `CreateFile` does not exist on disk during planning
  local created_paths = {}
  for _, op in ipairs(ops) do
    if op.kind == "create" then
      created_paths[op.path_key] = true
    end
  end

  -- files with edits: compute before/after without touching anything
  local files = {}
  local seen_documents = {}
  local seen_sources = {}
  local renamed_away = {}
  for _, op in ipairs(ops) do
    if op.kind == "rename" then
      renamed_away[op.old_key] = true
    elseif op.kind == "edit" then
      local op_key = op.path_key
      -- edit on a path that an EARLIER rename already removed: the document
      -- no longer exists at that address (LSP applies in emitted order)
      if renamed_away[op_key] then
        return nil, "invalid sequence: edits for the old path after the rename: " .. op.path
      end
      local source_path = op.path
      if vim.fn.filereadable(op.path) == 0 and rename_targets[op_key] then
        source_path = rename_targets[op_key]
        op.rename_from = source_path
      end
      op.source_path = source_path
      local src_key, src_err = plan_resolve(source_path)
      if not src_key then
        return nil, src_err
      end
      op.source_key = src_key

      local before, bufnr, tick
      local disk_before = vim.fn.filereadable(source_path) == 1 and vim.fn.readfile(source_path, "b") or nil
      if vim.fn.filereadable(source_path) == 0 and created_paths[src_key] then
        before = {}
        disk_before = {}
      else
        before, bufnr, tick = current_lines(source_path)
        if not before then
          return nil, "document not found: " .. op.path
        end
      end
      if seen_documents[op_key] and seen_documents[op_key] ~= src_key then
        return nil, "edits for " .. op.path .. " point to documents with different sources"
      end
      -- a second TextDocumentEdit for the same document would have ranges
      -- shifted by the first; the preview does not model that, so block it
      if seen_sources[src_key] then
        return nil,
          "invalid sequence: more than one TextDocumentEdit for the document: " .. relpath(opts.root, source_path)
      end
      seen_documents[op_key] = src_key
      seen_sources[src_key] = true
      local after, err = after_lines(before, op.edits, opts.encoding)
      if not after then
        return nil, "failed to compute the preview for " .. op.path .. ": " .. err
      end
      op.after_lines = after
      local diff, added, removed = make_diff(before, after, opts.root, op.path)
      files[#files + 1] = {
        path = op.path,
        path_key = op_key,
        source_path = source_path,
        source_key = src_key,
        rename_from = op.rename_from,
        uri = op.uri,
        version = op.version,
        created = created_paths[op_key] == true,
        before = before,
        disk_before = disk_before,
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
      local key = resolve_path(op.old_path)
      if key then
        map[key] = op.new_path
      end
    end
  end
  return map
end

local function file_for_source(plan, source_key)
  if not source_key then
    return nil
  end
  for _, file in ipairs(plan.files or {}) do
    local src = file.source_path or file.path
    local key = file.source_key or resolve_path(src)
    if key == source_key then
      return file
    end
  end
end

local function count_modified_buffers(bufs)
  local count = 0
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      count = count + 1
    end
  end
  return count
end

local function pick_primary_buffer(bufs)
  if #bufs == 0 then
    return -1
  end
  local best = bufs[1]
  local best_prio = buffer_priority(best)
  for i = 2, #bufs do
    local prio = buffer_priority(bufs[i])
    if prio > best_prio then
      best = bufs[i]
      best_prio = prio
    end
  end
  return best
end

local function validate_buffer_identity(buf, expected_key, expected_stat)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false, "buffer is no longer valid"
  end
  local buf_name = vim.api.nvim_buf_get_name(buf)
  if buf_name == "" then
    return false, "buffer has no file name"
  end
  local buf_key, buf_err = resolve_path(buf_name)
  if not buf_key or buf_key ~= expected_key then
    return false, buf_err or ("buffer identity mismatch: " .. buf_name)
  end
  if expected_stat then
    local buf_stat = vim.uv.fs_stat(buf_name)
    if not buf_stat or buf_stat.dev ~= expected_stat.dev or buf_stat.ino ~= expected_stat.ino then
      return false, "buffer inode mismatch: " .. buf_name
    end
  end
  return true, nil
end

local function revalidate(plan)
  local problems = {}
  local renames = resolve_renames(plan)

  for _, file in ipairs(plan.files) do
    local src_path = file.source_path or file.path
    local src_key, src_err = validate_op_path(plan.root, src_path)
    local _, dst_err = validate_op_path(plan.root, file.path)
    local renamed_to = src_key and renames[src_key] or nil
    local display_path = renamed_to or src_path
    if not src_key then
      problems[#problems + 1] = src_err
    elseif dst_err then
      problems[#problems + 1] = dst_err
    elseif file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
      local ok_id, id_err = validate_buffer_identity(file.bufnr, src_key, nil)
      if not ok_id then
        problems[#problems + 1] = "buffer identity changed since the preview ("
          .. id_err
          .. "): "
          .. relpath(plan.root, display_path)
      elseif vim.b[file.bufnr].changedtick ~= file.tick then
        problems[#problems + 1] = "buffer changed since the preview: " .. relpath(plan.root, display_path)
      elseif not disk_content_matches(src_path, file) then
        problems[#problems + 1] = "file changed since the preview: " .. relpath(plan.root, display_path)
      else
        for _, buf in ipairs(find_buffers_for(src_path)) do
          if buf ~= file.bufnr and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
            problems[#problems + 1] = "conflicting modified buffer for: " .. relpath(plan.root, display_path)
            break
          end
        end
      end
    elseif file.created and vim.fn.filereadable(src_path) == 0 and vim.uv.fs_lstat(src_path) == nil then
      -- CreateFile does not exist on disk before application
      if modified_buffer_for(src_path) then
        problems[#problems + 1] = "buffer changed since the preview: " .. relpath(plan.root, display_path)
      end
    else
      if not disk_content_matches(src_path, file) then
        problems[#problems + 1] = "file changed since the preview: " .. relpath(plan.root, display_path)
      elseif modified_buffer_for(src_path) then
        problems[#problems + 1] = "buffer changed since the preview: " .. relpath(plan.root, display_path)
      end
    end
  end

  for _, op in ipairs(plan.ops) do
    if op.kind == "rename" then
      local old_key, old_err = validate_op_path(plan.root, op.old_path)
      local new_key, new_err = validate_op_path(plan.root, op.new_path)
      local _, dir_err = validate_op_path(plan.root, vim.fs.dirname(op.new_path))
      if not old_key then
        problems[#problems + 1] = old_err
      end
      if not new_key then
        problems[#problems + 1] = new_err
      end
      if dir_err and dir_err ~= new_err then
        problems[#problems + 1] = dir_err
      end
      if old_key then
        if vim.fn.filereadable(op.old_path) == 0 then
          problems[#problems + 1] = "source does not exist: " .. relpath(plan.root, op.old_path)
        end
        if count_modified_buffers(find_buffers_for(op.old_path)) > 1 then
          problems[#problems + 1] = "conflicting modified buffers for: " .. relpath(plan.root, op.old_path)
        end
      end
      if new_key then
        if vim.fn.filereadable(op.new_path) == 1 or vim.uv.fs_lstat(op.new_path) ~= nil then
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
      end
    elseif op.kind == "create" then
      local key, err = validate_op_path(plan.root, op.path)
      local _, dir_err = validate_op_path(plan.root, vim.fs.dirname(op.path))
      if not key then
        problems[#problems + 1] = err
      else
        if dir_err and dir_err ~= err then
          problems[#problems + 1] = dir_err
        end
        if vim.fn.filereadable(op.path) == 1 or vim.uv.fs_lstat(op.path) ~= nil then
          problems[#problems + 1] = "file already exists: " .. relpath(plan.root, op.path)
        end
        local stale = modified_buffer_for(op.path)
        if stale then
          problems[#problems + 1] = "the destination has an unsaved modified buffer: "
            .. relpath(plan.root, op.path)
            .. " — close/save this buffer before applying"
        end
      end
    elseif op.kind == "delete" then
      local key, err = validate_op_path(plan.root, op.path)
      if not key then
        problems[#problems + 1] = err
      else
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
    elseif op.kind == "edit" then
      local _, err = validate_op_path(plan.root, op.path)
      if err then
        problems[#problems + 1] = err
      end
    end
  end

  return problems
end

local function buffer_for(path)
  local buf = find_buffer_for(path)
  if buf == -1 then
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
  elseif not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  return buf
end

---Final content computed by the preview for the document being renamed.
local function after_for(plan, old_key)
  if not old_key then
    return nil
  end
  for _, file in ipairs(plan.files or {}) do
    if file.source_path then
      local key = file.source_key or resolve_path(file.source_path)
      if key == old_key then
        return file.after
      end
    end
  end
end

local renameat2_probed = false
local renameat2_fn = nil

local function posix_errno(name)
  local neg = vim.uv.errno and vim.uv.errno[name]
  if type(neg) == "number" and neg < 0 then
    return -neg
  end
  return nil
end

---Probe Linux `renameat2(2)` via LuaJIT FFI (`RENAME_NOREPLACE`).
---Returns a wrapper `fun(old_path: string, new_path: string): boolean, integer|nil`
---or `nil` when unavailable (non-Linux, no FFI, or missing libc symbol).
local function probe_renameat2()
  if renameat2_probed then
    return renameat2_fn
  end
  renameat2_probed = true
  local ok_ffi, ffi = pcall(require, "ffi")
  if not ok_ffi or ffi.os ~= "Linux" then
    return nil
  end
  local has_decl = pcall(function()
    return ffi.C.renameat2
  end)
  if not has_decl then
    local ok_cdef = pcall(
      ffi.cdef,
      [[
      int renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
    ]]
    )
    if not ok_cdef then
      return nil
    end
  end
  local ok_sym, fn = pcall(function()
    return ffi.C.renameat2
  end)
  if ok_sym and type(fn) == "cdata" then
    local AT_FDCWD = -100
    local RENAME_NOREPLACE = 1
    renameat2_fn = function(old_path, new_path)
      local rc = fn(AT_FDCWD, old_path, AT_FDCWD, new_path, RENAME_NOREPLACE)
      if rc == 0 then
        return true, nil
      end
      return false, ffi.errno()
    end
  end
  return renameat2_fn
end

local function same_regular_inode(st, expected)
  return st ~= nil
    and st.type == "file"
    and st.dev ~= nil
    and st.ino ~= nil
    and st.dev == expected.dev
    and st.ino == expected.ino
end

---Move `old_path` to `new_path` without overwriting an existing destination.
---
---Primitives and fail-safe policy:
---1. On Linux with `renameat2(AT_FDCWD, ..., RENAME_NOREPLACE)`, performs a
---   single atomic no-replace rename supporting regular files and symlinks on
---   the same filesystem (`EEXIST` aborts without touching `new_path`, `EXDEV`
---   refuses explicitly).
---2. When `renameat2` is unavailable (non-Linux, missing libc symbol, or
---   `ENOSYS`/`EINVAL`/`ENOTSUP`), falls back to `vim.uv.fs_link` +
---   `vim.uv.fs_unlink` ONLY for regular files (`old_lstat.type == "file"`)
---   with verifiable `(dev, ino)` on the same filesystem. `fs_link` atomically
---   fails with `EEXIST` if `new_path` already exists. Symlinks, directories,
---   cross-device moves (`EXDEV`), and filesystems without hard-link support
---   are explicitly refused — never falls back to overwriting `vim.fn.rename`
---   or `vim.uv.fs_rename`.
---
---Real concurrency limits:
--- - Parent symlink swaps: both `renameat2(AT_FDCWD, ...)` and `vim.uv.fs_link`
---   / `vim.uv.fs_unlink` are path-based rather than walking components from a
---   pinned root fd via `openat(..., O_DIRECTORY | O_NOFOLLOW)`. A concurrent
---   swap of an intermediate parent directory to a symlink between
---   `validate_op_path` and the kernel syscall is therefore not prevented.
--- - Fallback window (`fs_link` + `fs_unlink`): `fs_link` is atomic with
---   respect to `new_path` non-existence, but removing `old_path` is a second
---   step. Before unlinking `old_path`, both `new_path` and `old_path` are
---   re-checked by `(type, dev, ino)`; however, because `vim.uv` lacks
---   `unlinkat`, a narrow TOCTOU window remains between that pre-unlink
---   `fs_lstat(old_path)` and `fs_unlink(old_path)`. If `fs_unlink` fails,
---   rollback unlinks `new_path` only when its `(type, dev, ino)` still matches
---   `old_lstat`.
local function rename_noreplace(old_path, new_path, old_lstat, root)
  local r2
  if M._renameat2_override ~= nil then
    if M._renameat2_override ~= false then
      r2 = M._renameat2_override
    end
  else
    r2 = probe_renameat2()
  end

  if r2 then
    local ok_r2, err_no = r2(old_path, new_path)
    if ok_r2 then
      return
    end
    local eexist = posix_errno("EEXIST")
    local exdev = posix_errno("EXDEV")
    local enoent = posix_errno("ENOENT")
    local enosys = posix_errno("ENOSYS")
    local einval = posix_errno("EINVAL")
    local enotsup = posix_errno("ENOTSUP")
    if eexist and err_no == eexist then
      error("destination already exists: " .. relpath(root, new_path), 0)
    end
    if exdev and err_no == exdev then
      error(
        "cross-device rename without overwrite is not supported: "
          .. relpath(root, old_path)
          .. " -> "
          .. relpath(root, new_path),
        0
      )
    end
    if enoent and err_no == enoent then
      error("source or destination parent no longer exists: " .. relpath(root, old_path), 0)
    end
    local unsupported = (enosys and err_no == enosys)
      or (einval and err_no == einval)
      or (enotsup and err_no == enotsup)
    if not unsupported then
      error("rename without overwrite failed (errno " .. tostring(err_no) .. "): " .. relpath(root, old_path), 0)
    end
    if old_lstat.type ~= "file" then
      error(
        "rename without overwrite is not supported for non-regular files on this filesystem: "
          .. relpath(root, old_path),
        0
      )
    end
  end

  if old_lstat.type ~= "file" then
    if old_lstat.type == "link" then
      error("rename without overwrite is not supported for symlinks on this platform: " .. relpath(root, old_path), 0)
    end
    error(
      "rename without overwrite is only supported for regular files on this platform: " .. relpath(root, old_path),
      0
    )
  end
  if old_lstat.dev == nil or old_lstat.ino == nil then
    error("cannot verify source file identity before rename: " .. relpath(root, old_path), 0)
  end

  local link_ok, link_err, link_code = vim.uv.fs_link(old_path, new_path)
  if not link_ok then
    if link_code == "EEXIST" then
      error("destination already exists: " .. relpath(root, new_path), 0)
    end
    if link_code == "EXDEV" then
      error(
        "cross-device rename without overwrite is not supported: "
          .. relpath(root, old_path)
          .. " -> "
          .. relpath(root, new_path),
        0
      )
    end
    error("rename without overwrite failed (" .. tostring(link_code or link_err) .. "): " .. relpath(root, old_path), 0)
  end

  local new_lstat = vim.uv.fs_lstat(new_path)
  if not same_regular_inode(new_lstat, old_lstat) then
    error("concurrent modification detected during rename; refusing to unlink: " .. relpath(root, new_path), 0)
  end

  local cur_old_lstat = vim.uv.fs_lstat(old_path)
  if not same_regular_inode(cur_old_lstat, old_lstat) then
    if cur_old_lstat == nil then
      error("source disappeared concurrently during rename; destination preserved: " .. relpath(root, new_path), 0)
    end
    error("source changed concurrently during rename; refusing to unlink source: " .. relpath(root, old_path), 0)
  end

  local unlink_ok, unlink_err, unlink_code = vim.uv.fs_unlink(old_path)
  if not unlink_ok then
    local rollback_note = ""
    local rb_lstat = vim.uv.fs_lstat(new_path)
    if same_regular_inode(rb_lstat, old_lstat) then
      local rb_ok = vim.uv.fs_unlink(new_path)
      if not rb_ok then
        rollback_note = " (new link kept at " .. relpath(root, new_path) .. ")"
      end
    else
      rollback_note = " (destination changed concurrently and was preserved)"
    end
    error(
      "rename failed while removing source ("
        .. tostring(unlink_code or unlink_err)
        .. "): "
        .. relpath(root, old_path)
        .. rollback_note,
      0
    )
  end
end

local function apply_op(op, plan, renamed, applied_documents, edited_sources)
  if op.kind == "edit" then
    local op_key = op.path_key or resolve_path(op.path)
    if not op_key then
      error("invalid path: " .. tostring(op.path), 0)
    end
    -- if an earlier RenameFile already materialized the content planned for
    -- this path, the subsequent TextDocumentEdit is already in the buffer
    if applied_documents[op_key] then
      return "edits already included in the rename: " .. relpath(plan.root, op.path)
    end
    local path = renamed[op_key] or op.source_path or op.path
    local path_key, path_err = validate_op_path(plan.root, path)
    if not path_key then
      error(path_err, 0)
    end
    local _, op_err = validate_op_path(plan.root, op.path)
    if op_err then
      error(op_err, 0)
    end
    local buf = buffer_for(path)
    local content_error = document_content_error({ uri = op.uri, version = op.version }, plan)
    if content_error then
      error(content_error, 0)
    end
    vim.lsp.util.apply_text_edits(op.edits, buf, plan.encoding)
    if not vim.bo[buf].buflisted then
      vim.bo[buf].buflisted = true
    end
    edited_sources[path_key] = true
    return "edits " .. relpath(plan.root, path)
  elseif op.kind == "rename" then
    -- Revalidate paths and capture buffer/file identity BEFORE renaming on disk,
    -- because after rename a file symlink pointing to `op.old_path` becomes
    -- dangling and can no longer be matched via `fs_realpath`.
    local old_key, old_err = validate_op_path(plan.root, op.old_path)
    if not old_key then
      error(old_err, 0)
    end
    local new_key_pre, new_err = validate_op_path(plan.root, op.new_path)
    if not new_key_pre then
      error(new_err, 0)
    end
    local _, dir_err = validate_op_path(plan.root, vim.fs.dirname(op.new_path))
    if dir_err then
      error(dir_err, 0)
    end
    if vim.fn.filereadable(op.old_path) == 0 then
      error("source does not exist: " .. relpath(plan.root, op.old_path), 0)
    end
    if vim.fn.filereadable(op.new_path) == 1 or vim.uv.fs_lstat(op.new_path) ~= nil then
      error("destination already exists: " .. relpath(plan.root, op.new_path), 0)
    end
    if vim.fn.isdirectory(vim.fs.dirname(op.new_path)) == 0 then
      error("destination directory does not exist: " .. relpath(plan.root, vim.fs.dirname(op.new_path)), 0)
    end
    if modified_buffer_for(op.new_path) then
      error("the destination has an unsaved modified buffer: " .. relpath(plan.root, op.new_path), 0)
    end

    local old_stat = vim.uv.fs_stat(op.old_path)
    local old_lstat = vim.uv.fs_lstat(op.old_path)
    if not old_lstat or not old_stat then
      error("source does not exist: " .. relpath(plan.root, op.old_path), 0)
    end
    if old_lstat.type ~= "file" and old_lstat.type ~= "link" then
      error(
        "rename without overwrite is only supported for regular files and symlinks: " .. relpath(plan.root, op.old_path),
        0
      )
    end
    local old_bufs = find_buffers_for(op.old_path)
    if count_modified_buffers(old_bufs) > 1 then
      error("conflicting modified buffers for: " .. relpath(plan.root, op.old_path), 0)
    end

    local planned_file = file_for_source(plan, old_key)
    if planned_file then
      if not disk_content_matches(op.old_path, planned_file) then
        error("file changed since the preview: " .. relpath(plan.root, op.old_path), 0)
      end
      if not edited_sources[old_key] then
        if planned_file.bufnr then
          if not vim.api.nvim_buf_is_valid(planned_file.bufnr) then
            error("buffer no longer valid before rename: " .. relpath(plan.root, op.old_path), 0)
          end
          local ok_id, id_err = validate_buffer_identity(planned_file.bufnr, old_key, old_stat)
          if not ok_id then
            error("buffer identity changed before rename: " .. tostring(id_err), 0)
          end
          if vim.b[planned_file.bufnr].changedtick ~= planned_file.tick then
            error("buffer changed since the preview: " .. relpath(plan.root, op.old_path), 0)
          end
        elseif count_modified_buffers(old_bufs) > 0 then
          error("buffer changed since the preview: " .. relpath(plan.root, op.old_path), 0)
        end
      end
    end

    local old_buf = -1
    if planned_file and planned_file.bufnr and vim.api.nvim_buf_is_valid(planned_file.bufnr) then
      old_buf = planned_file.bufnr
    else
      old_buf = pick_primary_buffer(old_bufs)
    end
    if old_buf ~= -1 then
      local ok_id, id_err = validate_buffer_identity(old_buf, old_key, old_stat)
      if not ok_id then
        error("buffer identity changed before rename: " .. tostring(id_err), 0)
      end
    end

    local old_loaded = old_buf ~= -1 and vim.api.nvim_buf_is_loaded(old_buf)
    local old_lines = old_loaded and vim.api.nvim_buf_get_lines(old_buf, 0, -1, false) or nil
    local old_modified = old_loaded and vim.bo[old_buf].modified or false
    local after = after_for(plan, old_key)
    local win = old_loaded and vim.fn.bufwinid(old_buf) or -1
    local was_current = old_loaded and vim.api.nvim_get_current_buf() == old_buf
    -- the new buffer must inherit the old buffer's LSP clients,
    -- otherwise JDTLS loses the document after RenameFile/Move
    local old_clients = old_loaded and vim.lsp.get_clients({ bufnr = old_buf }) or {}

    rename_noreplace(op.old_path, op.new_path, old_lstat, plan.root)
    local new_key_post, post_err = validate_op_path(plan.root, op.new_path)
    if not new_key_post then
      error(post_err, 0)
    end
    renamed[old_key] = op.new_path

    -- Align the buffer with the new path without writing anything: reload the
    -- moved file and reapply the preview content (or preserved buffer edits) in
    -- memory. The user's `:wa` then writes without a prompt (correct b_mtime)
    -- and nothing is saved automatically.
    local stale_set = {}
    for _, buf in ipairs(old_bufs) do
      stale_set[buf] = true
    end
    for _, stale in ipairs(find_buffers_for(op.new_path)) do
      if not stale_set[stale] and not vim.bo[stale].modified then
        pcall(vim.api.nvim_buf_delete, stale, { force = true })
      end
    end

    if old_lstat and old_lstat.type == "link" then
      if old_buf ~= -1 then
        pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
      end
    else
      for _, buf in ipairs(old_bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
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
      applied_documents[new_key_post] = true
    elseif old_modified and old_lines then
      vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, old_lines)
      vim.bo[new_buf].modified = true
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
    local pre_key, pre_err = validate_op_path(plan.root, op.path)
    if not pre_key then
      error(pre_err, 0)
    end
    if vim.fn.filereadable(op.path) == 1 or vim.uv.fs_lstat(op.path) ~= nil then
      error("file already exists: " .. relpath(plan.root, op.path), 0)
    end
    vim.fn.mkdir(vim.fs.dirname(op.path), "p")
    local post_key, post_err = validate_op_path(plan.root, op.path)
    if not post_key then
      error(post_err, 0)
    end
    local _, dir_err = validate_op_path(plan.root, vim.fs.dirname(op.path))
    if dir_err then
      error(dir_err, 0)
    end
    if vim.uv.fs_lstat(op.path) ~= nil then
      error("create recusado (destino já existe ou é symlink): " .. relpath(plan.root, op.path), 0)
    end
    local fd, open_err = vim.uv.fs_open(op.path, "wx", tonumber("644", 8))
    if not fd then
      error("create falhou: " .. relpath(plan.root, op.path) .. " (" .. tostring(open_err) .. ")", 0)
    end
    vim.uv.fs_close(fd)
    if vim.fn.filereadable(op.path) == 0 then
      error("create falhou: " .. relpath(plan.root, op.path), 0)
    end
    return "create " .. relpath(plan.root, op.path)
  elseif op.kind == "delete" then
    local del_key, del_err = validate_op_path(plan.root, op.path)
    if not del_key then
      error(del_err, 0)
    end
    if vim.fn.filereadable(op.path) == 0 then
      error("file does not exist: " .. relpath(plan.root, op.path), 0)
    end
    if not edited_sources[del_key] and modified_buffer_for(op.path) then
      error("the file has an unsaved modified buffer: " .. relpath(plan.root, op.path), 0)
    end
    local bufs = find_buffers_for(op.path)
    local ok, rc = pcall(vim.fn.delete, op.path)
    if not ok or rc ~= 0 or vim.fn.filereadable(op.path) == 1 then
      error("delete falhou: " .. relpath(plan.root, op.path), 0)
    end
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
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

  local pre_keys = {}
  for i, op in ipairs(plan.ops) do
    if op.kind == "edit" then
      pre_keys[i] = {
        op_key = op.path_key or resolve_path(op.path),
        src_key = op.source_key or resolve_path(op.source_path or op.path),
      }
    end
  end

  local applied = {}
  local renamed = {}
  local applied_documents = {}
  local edited_sources = {}
  local seen_documents = {}
  for i, op in ipairs(plan.ops) do
    if op.kind == "edit" then
      local version_error = document_version_error({ uri = op.uri, version = op.version }, op.version)
      if version_error then
        return { applied = applied, error = version_error }
      end
      local op_key = pre_keys[i].op_key
      local src_key = pre_keys[i].src_key
      if not op_key or not src_key then
        return { applied = applied, error = "invalid path in edit operation" }
      end
      local source = seen_documents[op_key]
      if source and source ~= src_key then
        return {
          applied = applied,
          error = "invalid sequence: edits for the same document have different sources",
        }
      end
      seen_documents[op_key] = src_key
    end

    local ok, err = pcall(apply_op, op, plan, renamed, applied_documents, edited_sources)
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
M._has_renameat2 = function()
  return probe_renameat2() ~= nil
end
M._plan = M.plan
M._apply = M.apply

return M
