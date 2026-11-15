-- java_menu/imports.lua
-- <leader>ji: operações de imports sobre as APIs do jc.nvim.
--
-- Todas as operações agem apenas no buffer atual. Onde o jc abre um seletor
-- interno, não substituímos vim.ui.* globalmente: preset de estilo e
-- Replace Import usam Snacks; o chooser de imports ambíguos do organize-imports
-- continua bloqueante/nativo porque roda dentro de um comando síncrono do jdtls.

local ui = require("java_menu.ui")
local lsp = require("java_menu.lsp")
local jca = require("java_menu.jc")

local M = {}

local NO_WILDCARDS = "no wildcards"

local function cursor_on_type()
  local word = vim.fn.expand("<cword>")
  return word ~= "" and word:match("^%u[%w_$]*$") ~= nil
end

---Replace Import com o seletor central, reutilizando as internas do jc
---(via adaptador, com contrato validado). Se a versão do jc não expõe mais
---essas internas, cai no fluxo nativo do jc (JCimportsReplace) sob o guard
---de cliente global da 6B.1; com o cliente correto por buffer usa o caminho
---direto, sem passar pela resolução global.
---@param bufnr number
local function replace_import(bufnr)
  local parts, parts_err = jca.replace_import_api()
  if not parts then
    ui.notify(parts_err, vim.log.levels.WARN)
    if parts_err:find("indisponível", 1, true) then
      return -- jc ausente/incompatível por inteiro: sem fallback possível
    end
    local guard = lsp.jc_global_reason("Replace Import (fallback jc)")
    if guard then
      ui.notify(guard, vim.log.levels.WARN)
      return
    end
    return require("jc.jdtls").replace_import()
  end

  local name = vim.fn.expand("<cword>")
  if name == "" or not name:match("^%u[%w_$]*$") then
    ui.notify("posicione o cursor sobre um nome de tipo (ex.: List)", vim.log.levels.WARN)
    return
  end
  if not ui.same_buffer(bufnr) then
    return
  end

  local client, client_reason = lsp.client_or_reason(bufnr)
  if not client then
    ui.notify(client_reason or "jdtls não está anexado a este buffer", vim.log.levels.ERROR)
    return
  end

  local tick = vim.b[bufnr].changedtick
  client:request("workspace/symbol", { query = name }, function(err, result)
    vim.schedule(function()
      if err or type(result) ~= "table" then
        ui.notify("não consegui buscar tipos para " .. name, vim.log.levels.WARN)
        return
      end
      local fqns, filter_err = parts.filter_type_symbols(result, name)
      if not fqns then
        ui.notify(filter_err, vim.log.levels.ERROR)
        return
      end
      if #fqns == 0 then
        ui.notify("nenhum tipo importável chamado " .. name, vim.log.levels.WARN)
        return
      end
      fqns, filter_err = parts.prioritize_types(fqns, bufnr)
      if not fqns then
        ui.notify(filter_err, vim.log.levels.ERROR)
        return
      end
      ui.pick_one(fqns, "Java: Imports — importar " .. name .. " de", function(choice)
        if not choice then
          return
        end
        if not ui.same_buffer(bufnr) then
          return
        end
        if vim.b[bufnr].changedtick ~= tick then
          ui.notify("o buffer mudou desde a busca — refaça o Replace Import", vim.log.levels.WARN)
          return
        end
        local ok, set_err = parts.set_import(bufnr, name, choice)
        if not ok then
          ui.notify(set_err, vim.log.levels.ERROR)
          return
        end
        local remembered, remember_err = parts.remember_regular(name, choice)
        if not remembered then
          ui.notify(remember_err, vim.log.levels.WARN)
        end
      end)
    end)
  end)
end

---Seletor central do preset de ordenação (equivalente ao JCimportsStyle).
local function pick_style(bufnr)
  local style, style_err = jca.import_style()
  if not style then
    ui.notify(style_err, vim.log.levels.ERROR)
    return
  end

  local current = style.load()
  local no_wildcards = style.no_wildcards()

  local names = vim.list_extend({}, style.order)
  names[#names + 1] = NO_WILDCARDS

  local labels = {}
  for _, name in ipairs(names) do
    if name == NO_WILDCARDS then
      labels[#labels + 1] = (no_wildcards and "[x] " or "[ ] ") .. name .. " (single-type imports only)"
    else
      labels[#labels + 1] = name == current and (name .. "  (current)") or name
    end
  end

  ui.pick_one(labels, "Java: Imports — estilo", function(choice)
    local idx = vim.fn.index(labels, choice) + 1
    local name = names[idx]
    if not name then
      return
    end
    if not ui.same_buffer(bufnr) then
      return
    end
    local ok, save_err = pcall(function()
      if name == NO_WILDCARDS then
        if not current then
          ui.notify("escolha um estilo antes do toggle de wildcards", vim.log.levels.WARN)
          return
        end
        style.save(current, not no_wildcards)
      else
        style.save(name, no_wildcards)
      end
    end)
    if not ok then
      ui.notify(tostring(save_err), vim.log.levels.ERROR)
      return
    end
    -- mesmo pós-passo do jc: reorganiza o buffer com o novo preset
    require("jc.jdtls").organize_imports(bufnr, false)
  end)
end

local RUNNERS = {
  organize_smart = function(bufnr)
    require("jc.jdtls").organize_imports(bufnr, true)
  end,
  organize_choose = function(bufnr)
    require("jc.jdtls").organize_imports(bufnr, false)
  end,
  add_missing = function()
    require("jc.jdtls").add_missing_imports()
  end,
  remove_unused = function()
    require("jc.jdtls").remove_unused_imports()
  end,
  organize_nosort = function()
    require("jc.jdtls").organize_imports_nosort()
  end,
  replace = replace_import,
  style = pick_style,
  expand_star = function()
    require("jc.jdtls").expand_star_imports()
  end,
}

---@param bufnr number
local function entries(bufnr)
  local attached = ui.jdtls_attached(bufnr)
  local no_jdtls = "jdtls não está anexado a este buffer"
  local on_type = cursor_on_type()

  return {
    { key = "organize_smart", label = "Organize Imports (smart)", enabled = attached, reason = no_jdtls },
    {
      key = "organize_choose",
      label = "Organize Imports (escolher tipos)",
      enabled = attached,
      reason = no_jdtls,
    },
    { key = "add_missing", label = "Add Missing Imports", enabled = attached, reason = no_jdtls },
    { key = "remove_unused", label = "Remove Unused Imports", enabled = attached, reason = no_jdtls },
    { key = "organize_nosort", label = "Organize Without Sorting", enabled = attached, reason = no_jdtls },
    {
      key = "replace",
      label = "Replace Import",
      enabled = attached and on_type,
      reason = (not attached and no_jdtls) or "posicione o cursor sobre um nome de tipo (ex.: List)",
    },
    { key = "style", label = "Import Style", enabled = attached, reason = no_jdtls },
    { key = "expand_star", label = "Expand Wildcard Imports", enabled = attached, reason = no_jdtls },
  }
end

---Entrada do `<leader>ji`.
function M.imports()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "java" then
    ui.notify("Imports exige um buffer Java", vim.log.levels.WARN)
    return
  end

  ui.menu(entries(bufnr), "Java: Imports", function(entry)
    local runner = RUNNERS[entry.key]
    if not runner then
      return
    end
    -- operações que abrem um segundo picker (style) verificam o buffer lá
    if entry.key ~= "style" and not ui.same_buffer(bufnr) then
      return
    end
    -- organize/add/remove/expand/style chamam jc.jdtls, que resolve o cliente
    -- globalmente; Replace Import é direto no cliente do buffer.
    if entry.key ~= "replace" then
      local jc_guard = lsp.jc_global_reason("Imports")
      if jc_guard then
        ui.notify(jc_guard, vim.log.levels.WARN)
        return
      end
    end
    runner(bufnr)
  end)
end

-- expostos para testes
M._entries = entries

return M
