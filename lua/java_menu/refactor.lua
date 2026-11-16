-- java_menu/refactor.lua
-- <leader>jr: local (single-file) refactorings over the jc.nvim API.
--
-- The Visual selection is captured BEFORE opening the picker (buffer, mode,
-- range and changedtick) and reapplied through the '< / '> marks when the
-- operation runs, which is what jc.nvim reads
-- (vim.lsp.util.make_given_range_params). No old Visual marks are reused and
-- no operation runs in another buffer.

local ui = require("java_menu.ui")
local preview = require("java_menu.preview")
local project = require("java_menu.project")
local signature = require("java_menu.signature")
local lsp = require("java_menu.lsp")

local M = {}

local function encoding(bufnr)
  local client = lsp.client(bufnr)
  return lsp.encoding(client)
end

---Rename a symbol: prepareRename (validation) + new name + textDocument/rename.
---The edit is NEVER applied here: it goes to the preview.
local function rename_symbol(bufnr)
  if not ui.same_buffer(bufnr) then
    return
  end

  local current = vim.fn.expand("<cword>")
  local tick = vim.b[bufnr].changedtick
  ui.ask("Java: Refactor — new name: ", current, function(name)
    if name == nil then
      return
    end
    name = vim.trim(name)
    if name == "" or name == current then
      return
    end
    if not name:match("^[%a_$][%w_$]*$") then
      ui.notify("invalid name: " .. name, vim.log.levels.WARN)
      return
    end
    if not ui.same_buffer(bufnr) then
      return
    end
    if vim.b[bufnr].changedtick ~= tick then
      ui.notify("the buffer changed since the rename — run the operation again", vim.log.levels.WARN)
      return
    end

    local client, client_reason = lsp.client_or_reason(bufnr)
    if not client then
      ui.notify(client_reason or "jdtls is not attached to this buffer", vim.log.levels.ERROR)
      return
    end

    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    params.newName = name

    client:request("textDocument/rename", params, function(err, edit)
      vim.schedule(function()
        if err then
          ui.notify("rename refused by jdtls: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
          return
        end
        if type(edit) ~= "table" or not next(edit) then
          ui.notify("jdtls returned no changes for this rename", vim.log.levels.WARN)
          return
        end
        M.preview_edit(edit, bufnr)
      end)
    end, bufnr)
  end)
end

---Move Class destination label. It includes the source root because the same
---package exists under src/main, src/test and each project module.
---@param project_root string|nil
---@param dest table
---@return string label, string dir
local function destination_label(project_root, dest)
  local dir = vim.uri_to_fname(dest.uri)
  local name = dest.isDefaultPackage and "(default package)" or (dest.displayName or "")
  local where = (project_root and vim.fs.relpath(project_root, dir)) or dir
  return name .. "  [" .. where .. "]", dir
end

M._destination_label = destination_label

---Validate that the move WorkspaceEdit placed the file exactly in the
---selected package and that the resulting `package` declaration matches it.
---@param plan table java_menu.preview plan
---@param expected { source_path: string, target_path: string, package: string, root: string|nil }
---@return boolean ok, string|nil reason
function M._validate_move_plan(plan, expected)
  local function show(path)
    return expected.root and vim.fs.relpath(expected.root, path) or path
  end
  local source = vim.fs.normalize(expected.source_path)
  local target = vim.fs.normalize(expected.target_path)

  local rename
  for _, op in ipairs(plan.ops or {}) do
    if op.kind == "rename" and vim.fs.normalize(op.old_path) == source then
      rename = op
      break
    end
  end
  if not rename then
    return false, "the jdtls edit does not contain the file move"
  end
  if vim.fs.normalize(rename.new_path) ~= target then
    return false,
      "computed destination ("
        .. show(rename.new_path)
        .. ") does not match the selected package ("
        .. show(target)
        .. ")"
  end

  local moved
  for _, file in ipairs(plan.files or {}) do
    if vim.fs.normalize(file.source_path or file.path) == source then
      moved = file
      break
    end
  end

  -- Moving between source roots with the same package may produce only a
  -- RenameFile (no package edit). In that case the current package is the
  -- resulting package and must already match the selected package.
  local after = moved and moved.after
  if not after then
    if vim.fn.filereadable(source) == 0 then
      return false, "preview has no content for the moved file"
    end
    after = vim.fn.readfile(source)
  end

  local actual_package
  for _, line in ipairs(after) do
    local name = line:match("^%s*package%s+([%w_.]+)%s*;")
    if name then
      actual_package = name
      break
    end
  end

  if expected.package == "" then
    if actual_package then
      return false, "default-package destination cannot keep the package declaration " .. actual_package
    end
  else
    local want = "package " .. expected.package .. ";"
    if actual_package ~= expected.package then
      local got = actual_package and ("package " .. actual_package .. ";") or "no package declaration"
      return false, "resulting declaration (" .. got .. ") does not match " .. want
    end
  end

  return true
end

---Move Class: getMoveDestinations -> destination -> java/move (returns the edit) -> preview.
local function move_class(bufnr)
  if not ui.same_buffer(bufnr) then
    return
  end

  local client, client_reason = lsp.client_or_reason(bufnr)
  if not client then
    ui.notify(client_reason or "jdtls is not attached to this buffer", vim.log.levels.ERROR)
    return
  end

  local uri = vim.uri_from_bufnr(bufnr)
  local file_name = vim.fn.fnamemodify(vim.uri_to_fname(uri), ":t")
  local tick = vim.b[bufnr].changedtick
  local project_root = project.root(bufnr)

  client:request("java/getMoveDestinations", {
    moveKind = "moveResource",
    sourceUris = { uri },
    params = vim.NIL,
  }, function(err, result)
    vim.schedule(function()
      if err then
        ui.notify("could not list destinations: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
        return
      end
      local destinations = result and result.destinations or {}
      if #destinations == 0 then
        ui.notify("jdtls offered no destinations for this class", vim.log.levels.WARN)
        return
      end

      local current_dir = vim.fs.dirname(vim.uri_to_fname(uri))
      local labels, by_label, usable = {}, {}, 0

      for _, dest in ipairs(destinations) do
        local text, dir = destination_label(project_root, dest)
        if by_label[text] then
          local n = 2
          while by_label[text .. "  #" .. n] do
            n = n + 1
          end
          text = text .. "  #" .. n
        end

        local reason
        if dir == current_dir then
          reason = "already the current package"
        elseif vim.fn.filereadable(dir .. "/" .. file_name) == 1 then
          reason = " " .. file_name .. " already exists in this package"
        end

        if reason then
          text = text .. "  (unavailable: " .. reason .. ")"
        else
          usable = usable + 1
        end

        labels[#labels + 1] = text
        by_label[text] = { dest = dest, reason = reason }
      end

      if usable == 0 then
        ui.notify("no destination package available", vim.log.levels.WARN)
        return
      end

      ui.pick_one(labels, "Java: Refactor — move " .. file_name .. " to", function(choice)
        local picked = by_label[choice]
        if not picked then
          return
        end
        if picked.reason then
          ui.notify(picked.reason, vim.log.levels.WARN)
          return
        end
        if not ui.same_buffer(bufnr) then
          return
        end
        if vim.b[bufnr].changedtick ~= tick then
          ui.notify("the buffer changed since the menu was opened — run Move Class again", vim.log.levels.WARN)
          return
        end

        local dest_dir = vim.uri_to_fname(picked.dest.uri)
        if vim.fn.isdirectory(dest_dir) == 0 then
          ui.notify("destination package does not exist on disk: " .. dest_dir, vim.log.levels.WARN)
          return
        end

        local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
        params.context = { diagnostics = {} }

        client:request("java/move", {
          moveKind = "moveResource",
          sourceUris = { uri },
          params = params,
          destination = picked.dest,
          updateReferences = true,
        }, function(move_err, move_result)
          vim.schedule(function()
            if move_err then
              ui.notify("move refused: " .. (move_err.message or vim.inspect(move_err)), vim.log.levels.ERROR)
              return
            end
            if move_result and move_result.errorMessage then
              ui.notify("move refused: " .. move_result.errorMessage, vim.log.levels.ERROR)
              return
            end
            if not (move_result and move_result.edit) then
              ui.notify("jdtls returned no changes for the move", vim.log.levels.WARN)
              return
            end
            local expected = {
              source_path = vim.uri_to_fname(uri),
              target_path = vim.fs.joinpath(dest_dir, file_name),
              package = picked.dest.isDefaultPackage and "" or (picked.dest.displayName or ""),
              root = project_root,
            }
            M.preview_edit(move_result.edit, bufnr, function(plan)
              return M._validate_move_plan(plan, expected)
            end)
          end)
        end, bufnr)
      end)
    end)
  end, bufnr)
end

local BLOCK_MODE = "\22" -- <C-v>

---@class VisualCtx
---@field bufnr number
---@field mode string "v" | "V" | "<C-v>"
---@field start_line number 0-based
---@field start_col number 0-based
---@field end_line number 0-based
---@field end_col number 0-based (last selected character)
---@field tick number changedtick at capture time

---Capture the current Visual selection (before any picker).
---@return VisualCtx|nil
local function capture_visual()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= BLOCK_MODE then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local anchor = vim.fn.getpos("v") -- 1-based
  local cursor = vim.fn.getpos(".") -- 1-based
  local a = { anchor[2], anchor[3] }
  local b = { cursor[2], cursor[3] }

  if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then
    a, b = b, a
  end

  local start_line, start_col = a[1] - 1, a[2] - 1
  local end_line, end_col = b[1] - 1, b[2] - 1

  if mode == "V" then
    start_col = 0
    local line = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1] or ""
    end_col = math.max(0, #line - 1)
  end

  return {
    bufnr = bufnr,
    mode = mode,
    start_line = start_line,
    start_col = start_col,
    end_line = end_line,
    end_col = end_col,
    tick = vim.b[bufnr].changedtick,
  }
end

---Leave Visual mode without relying on mappings.
local function leave_visual()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
end

---Reapply the captured selection and run `fn`.
---@param ctx VisualCtx
---@param fn fun()
local function with_selection(ctx, fn)
  if not ui.same_buffer(ctx.bufnr) then
    return
  end
  if vim.b[ctx.bufnr].changedtick ~= ctx.tick then
    ui.notify("the buffer changed since the selection — run Extract again", vim.log.levels.WARN)
    return
  end
  -- buffer marks in the format make_given_range_params consumes:
  -- 1-based line, 0-based column
  vim.api.nvim_buf_set_mark(ctx.bufnr, "<", ctx.start_line + 1, ctx.start_col, {})
  vim.api.nvim_buf_set_mark(ctx.bufnr, ">", ctx.end_line + 1, ctx.end_col, {})
  ui.with_indent(ctx.bufnr, fn)
end

---Extract at the cursor (no Visual selection): jc uses vim.ui.select when
---jdtls infers more than one expression. Here only the picker is replaced by
---Snacks; the request and edit application follow jc's protocol, with
---buffer/tick checks before changing anything. Any inference failure falls
---back to jc's flow (same messages).
local EXTRACT_CURSOR = {
  extract_variable = "extractVariable",
  extract_variable_all = "extractVariableAllOccurrence",
  extract_constant = "extractConstant",
}

---@param fn_name string
---@param bufnr number
local function run_extract_cursor(fn_name, bufnr)
  local jc = require("jc.refactor")
  local command = EXTRACT_CURSOR[fn_name]
  if not command or type(jc[fn_name]) ~= "function" then
    return
  end
  if not ui.same_buffer(bufnr) then
    return
  end

  local client, client_reason = lsp.client_or_reason(bufnr)
  if not client then
    ui.notify(client_reason or "jdtls is not attached to this buffer", vim.log.levels.ERROR)
    return
  end

  local function jc_fallback()
    local guard = lsp.jc_global_reason("Extract")
    if guard then
      ui.notify(guard, vim.log.levels.WARN)
      return
    end
    return jc[fn_name](false)
  end

  local tick = vim.b[bufnr].changedtick
  local encoding = client.offset_encoding
  local context = vim.lsp.util.make_range_params(0, encoding)
  context.context = { diagnostics = {} }
  local params = {
    command = command,
    context = context,
    options = {
      tabSize = vim.lsp.util.get_effective_tabstop(),
      insertSpaces = vim.bo.expandtab,
    },
  }

  local function execute(selection)
    if not ui.same_buffer(bufnr) then
      return
    end
    if vim.b[bufnr].changedtick ~= tick then
      ui.notify("the buffer changed during extraction — run the operation again", vim.log.levels.WARN)
      return
    end
    params.commandArguments = { selection }
    client:request("java/getRefactorEdit", params, function(err, result)
      vim.schedule(function()
        if err then
          ui.notify("extraction refused by jdtls: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
          return
        end
        if type(result) ~= "table" then
          return
        end
        if result.edit then
          vim.lsp.util.apply_workspace_edit(result.edit, encoding)
        end
        if result.command then
          client:request("workspace/executeCommand", result.command, function() end, bufnr)
        end
      end)
    end, bufnr)
  end

  client:request("java/inferSelection", params, function(err, selections)
    vim.schedule(function()
      if err or type(selections) ~= "table" or #selections == 0 then
        return jc_fallback()
      end
      if #selections == 1 then
        return execute(selections[1])
      end

      local labels, by_label = {}, {}
      for index, selection in ipairs(selections) do
        local label = (selection.name or ("selection " .. index))
          .. "  ("
          .. tostring(selection.length or "?")
          .. " chars)"
        labels[#labels + 1] = label
        by_label[label] = selection
      end
      ui.pick_one(labels, "Java: Refactor — extract (choose the expression)", function(choice)
        local selection = by_label[choice]
        if selection then
          execute(selection)
        end
      end)
    end)
  end, bufnr)
end

---@param fn_name string extract_variable | extract_variable_all | extract_constant | extract_method
local function run_extract(ctx, fn_name)
  local jc = require("jc.refactor")
  if ctx then
    -- the Visual flow uses jc.refactor, which resolves the client globally
    local guard = lsp.jc_global_reason("Extract (Visual)")
    if guard then
      ui.notify(guard, vim.log.levels.WARN)
      return
    end
    with_selection(ctx, function()
      jc[fn_name](true)
    end)
  else
    run_extract_cursor(fn_name, M._bufnr or vim.api.nvim_get_current_buf())
  end
end

---Range of the identifier under the cursor, already in LSP coordinates.
---For `Math.max` with the cursor on `Math`, returns the range of `max`: the
---jdtls quick assist is offered on the member name.
---@param bufnr number
---@param encoding string
---@return table|nil range
local function identifier_range(bufnr, encoding)
  local win = vim.fn.bufwinid(bufnr)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2] + 1 -- 1-based byte index
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local function is_word(char)
    return char ~= "" and char:match("[%w_$]") ~= nil
  end

  if not is_word(line:sub(col, col)) and line:sub(col, col) == "." then
    col = col + 1
  end
  if not is_word(line:sub(col, col)) then
    return nil
  end

  local start_col, end_col = col, col
  while start_col > 1 and is_word(line:sub(start_col - 1, start_col - 1)) do
    start_col = start_col - 1
  end
  while end_col <= #line and is_word(line:sub(end_col, end_col)) do
    end_col = end_col + 1
  end

  -- cursor on the qualifier (`Math`) of `Math.max`: the assist targets the member
  if line:sub(end_col, end_col) == "." then
    local member_start = end_col + 1
    if is_word(line:sub(member_start, member_start)) then
      local member_end = member_start
      while member_end <= #line and is_word(line:sub(member_end, member_end)) do
        member_end = member_end + 1
      end
      start_col, end_col = member_start, member_end
    end
  end

  return {
    start = { line = row, character = vim.lsp.util.character_offset(bufnr, row, start_col - 1, encoding) },
    ["end"] = { line = row, character = vim.lsp.util.character_offset(bufnr, row, end_col - 1, encoding) },
  }
end

---Apply a jdtls code action (direct edit, refactoring or command).
---@param client vim.lsp.Client
---@param bufnr number
---@param action table
---@param on_result fun(found: boolean)|nil
local function apply_static_import_action(client, bufnr, action, on_result)
  local function finish(found)
    if on_result then
      on_result(found)
    end
  end

  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
    finish(true)
    return
  end

  local command = action.command
  if type(command) == "table" then
    if command.command == "java.action.applyRefactoringCommand" then
      local ok = require("jc.refactor").apply_command(command, function()
        finish(true)
      end)
      if ok then
        return
      end
    end
    client:request("workspace/executeCommand", command, function()
      finish(true)
    end, bufnr)
    return
  end

  -- action not resolved yet: resolve and apply again
  client:request("codeAction/resolve", action, function(err, resolved)
    vim.schedule(function()
      if err or type(resolved) ~= "table" then
        finish(false)
        return
      end
      apply_static_import_action(client, bufnr, resolved, on_result)
    end)
  end, bufnr)
end

---"Convert to static import" using the identifier range instead of an empty
---cursor. jdtls 1.63 offers the quick assist only when the range covers the
---member name; jc.nvim asks for an empty range, hence this dedicated path.
---@param all boolean prefere "replace all occurrences"
local function static_import(all, bufnr)
  local client, client_reason = lsp.client_or_reason(bufnr)
  if not client then
    ui.notify(client_reason or "jdtls is not attached to this buffer", vim.log.levels.ERROR)
    return
  end
  local range = identifier_range(bufnr, client.offset_encoding)
  if not range then
    ui.notify("place the cursor on a static method or field name", vim.log.levels.WARN)
    return
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = range,
    context = { diagnostics = {} },
  }

  client:request("textDocument/codeAction", params, function(err, actions)
    vim.schedule(function()
      local match
      for _, action in ipairs(actions or {}) do
        local title = (action.title or ""):lower()
        if title:find("static import", 1, true) then
          local is_all = title:find("all occurrences", 1, true) ~= nil
          if all == is_all then
            match = action
            break
          end
          match = match or action
        end
      end
      if match then
        apply_static_import_action(client, bufnr, match)
        return
      end
      if err then
        ui.notify(vim.inspect(err), vim.log.levels.ERROR)
      end
      ui.notify("no static-import conversion at this position", vim.log.levels.WARN)
    end)
  end, bufnr)
end

local RUNNERS = {
  extract_variable = function(ctx)
    run_extract(ctx, "extract_variable")
  end,
  extract_variable_all = function(ctx)
    run_extract(ctx, "extract_variable_all")
  end,
  extract_constant = function(ctx)
    run_extract(ctx, "extract_constant")
  end,
  extract_method = function(ctx)
    run_extract(ctx, "extract_method")
  end,
  static_import = function()
    local guard = lsp.jc_global_reason("Static Import")
    if guard then
      ui.notify(guard, vim.log.levels.WARN)
      return
    end
    static_import(true, M._bufnr or vim.api.nvim_get_current_buf())
  end,
  static_import_enum = function()
    local guard = lsp.jc_global_reason("Static Import Enum")
    if guard then
      ui.notify(guard, vim.log.levels.WARN)
      return
    end
    require("jc.jdtls").static_import_enum()
  end,
  flip_args = function()
    require("jc.refactor").flip_call_args()
  end,
  change_signature = function()
    signature.change_signature(M._bufnr, function(edit)
      M.preview_edit(edit, M._bufnr)
    end)
  end,
  rename = function()
    rename_symbol(M._bufnr)
  end,
  move_class = function()
    move_class(M._bufnr)
  end,
}

---@param ctx VisualCtx|nil
---@param bufnr number
---@param rename_ready boolean|nil
---@param rename_reason string|nil
local function entries(ctx, bufnr, rename_ready, rename_reason)
  local attached = ui.jdtls_attached(bufnr)
  local parser = ui.has_parser(bufnr, "java")
  local no_jdtls = "jdtls is not attached to this buffer"

  local has_selection = ctx ~= nil and (ctx.start_line ~= ctx.end_line or ctx.start_col ~= ctx.end_col)
  local block = ctx ~= nil and ctx.mode == BLOCK_MODE

  local method_reason
  if not attached then
    method_reason = no_jdtls
  elseif block then
    method_reason = "block selection (<C-v>) is not supported"
  elseif not has_selection then
    method_reason = "select the range in Visual mode before <leader>jr"
  end

  return {
    { key = "extract_variable", label = "Extract Variable", enabled = attached, reason = no_jdtls },
    {
      key = "extract_variable_all",
      label = "Extract Variable (all occurrences)",
      enabled = attached,
      reason = no_jdtls,
    },
    { key = "extract_constant", label = "Extract Constant", enabled = attached, reason = no_jdtls },
    {
      key = "extract_method",
      label = "Extract Method",
      enabled = attached and has_selection and not block,
      reason = method_reason,
    },
    { key = "static_import", label = "Static Import", enabled = attached, reason = no_jdtls },
    {
      key = "static_import_enum",
      label = "Static Import Enum",
      enabled = attached and parser,
      reason = (not attached and no_jdtls) or "Java Tree-sitter parser is not installed",
    },
    {
      key = "flip_args",
      label = "Flip Arguments",
      enabled = parser,
      reason = "Java Tree-sitter parser is not installed",
    },
    {
      key = "rename",
      label = "Rename Symbol",
      enabled = attached and rename_ready == true,
      reason = (not attached and no_jdtls) or rename_reason or "place the cursor on a renameable symbol",
    },
    {
      key = "move_class",
      label = "Move Class",
      enabled = attached,
      reason = no_jdtls,
    },
    {
      key = "change_signature",
      label = "Change Method Signature",
      enabled = attached,
      reason = no_jdtls,
    },
    {
      key = "rename_package",
      label = "Rename Package",
      enabled = false,
      reason = 'jdtls 1.63 does not support it: prepareRename answers "Renaming this element is not supported" and rename only creates/removes a .temp file',
    },
    {
      key = "move_package",
      label = "Move Package",
      enabled = false,
      reason = "jdtls exposes no moveKind for packages (only moveResource for files, moveInstanceMethod, moveStaticMember and moveTypeToNewFile)",
    },
  }
end

---Confirm that jdtls imported every aggregator module before a refactoring
---that may cross modules. Returns nil when everything is covered.
local function coverage_problem(bufnr, cb)
  local root = project.root(bufnr)
  if not root then
    return cb(nil)
  end

  local modules = project.modules(root)
  if #modules <= 1 then
    return cb(nil) -- single-module project: coverage is the root itself
  end

  local client = lsp.client_or_reason(bufnr)
  if not client then
    return cb("jdtls is not attached to this buffer")
  end

  client:request(
    "workspace/executeCommand",
    { command = "java.project.listSourcePaths", arguments = {} },
    function(err, res)
      vim.schedule(function()
        if err or type(res) ~= "table" or type(res.data) ~= "table" then
          return cb("could not confirm which modules jdtls imported")
        end

        local paths = {}
        for _, entry in ipairs(res.data) do
          if type(entry.path) == "string" then
            paths[#paths + 1] = entry.path
          end
        end

        local missing = {}
        for _, mod in ipairs(modules) do
          local found = false
          for _, path in ipairs(paths) do
            if path == mod or path:sub(1, #mod + 1) == mod .. "/" then
              found = true
              break
            end
          end
          if not found then
            missing[#missing + 1] = vim.fs.basename(mod)
          end
        end

        if #missing > 0 then
          return cb(
            "modules not imported by jdtls: "
              .. table.concat(missing, ", ")
              .. " — open one of their files (or restart Neovim) before refactoring"
          )
        end
        cb(nil)
      end)
    end,
    bufnr
  )
end

---Real preview of a WorkspaceEdit (rename/move/change signature) before any
---change. `validate(plan)` may block the plan with a reason.
---@param edit table
---@param bufnr number
---@param validate fun(plan: table): boolean, string|nil
function M.preview_edit(edit, bufnr, validate)
  local root = project.root(bufnr)
  if not root then
    ui.notify("outside a Java project (pom/gradle): refactoring blocked", vim.log.levels.WARN)
    return
  end

  coverage_problem(bufnr, function(problem)
    if problem then
      ui.notify("refactoring blocked: " .. problem, vim.log.levels.ERROR)
      return
    end

    local plan, err = preview.plan(edit, { encoding = encoding(bufnr), root = root })
    if not plan then
      ui.notify("preview blocked: " .. err, vim.log.levels.ERROR)
      return
    end

    if validate then
      local ok, reason = validate(plan)
      if not ok then
        ui.notify("preview blocked: " .. (reason or "invalid destination"), vim.log.levels.ERROR)
        return
      end
    end

    preview.review(plan, function() end)
  end)
end

---Entry point of `<leader>jr` (normal or visual).
function M.refactor()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "java" then
    ui.notify("Refactor requires a Java buffer", vim.log.levels.WARN)
    return
  end

  -- capture before opening the picker
  local ctx = capture_visual()
  if ctx then
    leave_visual()
  end

  M._bufnr = bufnr

  -- validate rename at the current position (async) before building the menu
  local function open(rename_ready, rename_reason)
    if not ui.same_buffer(bufnr) then
      return
    end
    ui.menu(entries(ctx, bufnr, rename_ready, rename_reason), "Java: Refactor", function(entry)
      local runner = RUNNERS[entry.key]
      if runner then
        runner(ctx)
      end
    end)
  end

  if not ui.jdtls_attached(bufnr) then
    open(false, "jdtls is not attached to this buffer")
    return
  end

  local client, client_reason = lsp.client_or_reason(bufnr)
  if not client then
    ui.notify(client_reason or "jdtls is not attached to this buffer", vim.log.levels.WARN)
    return
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/prepareRename", params, function(err, result)
    vim.schedule(function()
      if err then
        open(false, "rename unavailable: " .. (err.message or vim.inspect(err)))
      elseif type(result) ~= "table" then
        open(false, "jdtls does not recognize a renameable symbol at the cursor")
      else
        open(true, nil)
      end
    end)
  end, bufnr)
end

-- exposed for tests
M._capture_visual = capture_visual
M._entries = entries
M._static_import = static_import
M._identifier_range = identifier_range
M._run_extract = run_extract

return M
