-- java_menu/ui.lua
-- Shared UI components for the Java menus (Snacks when available, without
-- replacing the global vim.ui.select/input functions).

local M = {}

function M.notify(msg, level)
  vim.notify("Java: " .. msg, level or vim.log.levels.INFO)
end

function M.snacks()
  local ok, mod = pcall(require, "snacks")
  if ok and mod.picker and type(mod.picker.pick) == "function" then
    return mod
  end
end

---Single-choice picker. Without Snacks the operation still works through
---vim.ui.select, without replacing the global function.
function M.pick_one(items, prompt, on_choice)
  local mod = M.snacks()
  if not mod then
    vim.ui.select(items, { prompt = prompt }, function(choice)
      if choice ~= nil then
        on_choice(choice)
      end
    end)
    return
  end
  mod.picker.select(items, { prompt = prompt }, function(choice)
    if choice ~= nil then
      on_choice(choice)
    end
  end)
end

---Multi-choice picker (Snacks): Space/Tab toggles, Enter confirms.
---Nothing selected returns {} (optional steps can be skipped).
---Items may be strings or `{ text = "…", value = … }`; the callback receives
---the values (or the text itself).
---@param items (string|{text:string, value:any})[]
---@param prompt string
---@param on_confirm fun(selected:any[])
---@param opts { fallback: boolean|nil, help: boolean|nil }|nil
--- fallback = Enter with no selection uses the item under the cursor
--- help = show the short key hint in the title (default: true)
function M.pick_many(items, prompt, on_confirm, opts)
  opts = opts or {}

  local entries = {}
  local by_text = {}
  for i, item in ipairs(items) do
    local text = type(item) == "table" and item.text or tostring(item)
    local value = type(item) == "table" and item.value or item
    by_text[text] = value
    entries[#entries + 1] = { text = text, item = { text = text, value = value, idx = i } }
  end

  local mod = M.snacks()
  if not mod or type(mod.picker.pick) ~= "function" then
    -- no-Snacks fallback: comma-separated list
    vim.ui.input({ prompt = prompt .. " (comma-separated; empty = none): " }, function(value)
      if value == nil then
        return
      end
      local out = {}
      for part in value:gmatch("[^,]+") do
        local text = vim.trim(part)
        if text ~= "" then
          out[#out + 1] = by_text[text] or text
        end
      end
      on_confirm(out)
    end)
    return
  end

  local title = prompt
  if opts.help ~= false then
    title = prompt .. "  ·  Space/Tab · Enter · Esc"
  end

  mod.picker.pick({
    title = title,
    source = "java_menu_multi",
    -- same frame as the single pickers, without internal data preview
    layout = { preset = "select", preview = false },
    finder = function()
      return vim.deepcopy(entries)
    end,
    -- "text" returns highlight chunks; a plain string would break rendering
    format = "text",
    win = {
      input = {
        keys = {
          -- Tab marks without leaving the search field; Space stays available
          -- for filtering
          ["<Tab>"] = { "select_and_next", mode = { "n", "i" } },
        },
      },
      list = {
        keys = {
          ["<Space>"] = "select_and_next",
          ["<Tab>"] = "select_and_next",
        },
      },
    },
    confirm = function(picker)
      local selected = picker:selected({ fallback = opts.fallback == true })
      picker:close()
      table.sort(selected, function(a, b)
        return (a.item and a.item.idx or 0) < (b.item and b.item.idx or 0)
      end)
      local out = {}
      for _, entry in ipairs(selected) do
        if entry.item and entry.item.value ~= nil then
          out[#out + 1] = entry.item.value
        end
      end
      vim.schedule(function()
        on_confirm(out)
      end)
    end,
  })
end

---Central text input (Snacks), with vim.ui.input fallback.
function M.ask(prompt, default, on_confirm)
  local mod = M.snacks()
  if mod and mod.input and type(mod.input.input) == "function" then
    return mod.input.input({ prompt = prompt, default = default or "" }, on_confirm)
  end
  return vim.ui.input({ prompt = prompt, default = default or "" }, on_confirm)
end

---Central menu with available/unavailable states.
---@param entries table[] { key, label, enabled, reason }
---@param prompt string
---@param on_choice fun(entry: table)
function M.menu(entries, prompt, on_choice)
  local labels, by_label = {}, {}
  for _, entry in ipairs(entries) do
    local text = entry.label
    -- only mark unavailable when explicitly requested (enabled == false)
    if entry.enabled == false then
      text = text .. "  (unavailable: " .. (entry.reason or "no reason") .. ")"
    end
    labels[#labels + 1] = text
    by_label[text] = entry
  end

  M.pick_one(labels, prompt, function(choice)
    local entry = by_label[choice]
    if not entry then
      return
    end
    if entry.enabled == false then
      M.notify(entry.reason or "operation unavailable", vim.log.levels.WARN)
      return
    end
    on_choice(entry)
  end)
end

function M.jdtls_attached(bufnr)
  return #vim.lsp.get_clients({ name = "jdtls", bufnr = bufnr }) > 0
end

---Is a Tree-sitter parser for the language available?
function M.has_parser(bufnr, lang)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  return ok and parser ~= nil
end

---Indentation unit of the file (first indented line).
local function detect_indent(bufnr)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 200, false)) do
    local spaces = line:match("^( +)%S")
    if spaces then
      return #spaces
    end
  end
  return vim.bo[bufnr].shiftwidth > 0 and vim.bo[bufnr].shiftwidth or 4
end

---Match shiftwidth to the file's real indentation during `fn` and restore it
---afterwards (jdtls formats generated/refactored code with this value).
function M.with_indent(bufnr, fn)
  local sw, ts, et = vim.bo[bufnr].shiftwidth, vim.bo[bufnr].tabstop, vim.bo[bufnr].expandtab
  local unit = detect_indent(bufnr)
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].shiftwidth = unit
  vim.bo[bufnr].tabstop = unit
  local ok, err = pcall(fn)
  vim.bo[bufnr].shiftwidth, vim.bo[bufnr].tabstop, vim.bo[bufnr].expandtab = sw, ts, et
  if not ok then
    M.notify(tostring(err), vim.log.levels.ERROR)
  end
end

---Is the target buffer still the current one? (avoids acting on the wrong file)
function M.same_buffer(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    M.notify("the target buffer no longer exists", vim.log.levels.WARN)
    return false
  end
  if vim.api.nvim_get_current_buf() ~= bufnr then
    M.notify("the buffer changed since the menu was opened — run the operation again", vim.log.levels.WARN)
    return false
  end
  return true
end

return M
