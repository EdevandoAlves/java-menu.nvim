-- java_menu/init.lua
-- API pública do java-menu.nvim: require("java_menu").setup(opts).
--
-- O plugin é uma camada de menus sobre jc.nvim (dependência obrigatória)
-- e sobre o cliente JDTLS que o USUÁRIO já iniciou: aqui nada de servidor,
-- Mason, blink.cmp ou configuração pessoal. Os atalhos são globais (não só
-- ft=java), então o menu continua acessível em pom.xml, build.gradle(.kts)
-- e em qualquer diretório de projeto Java.
--
-- Os módulos Java carregam sob demanda: o callback de cada atalho exige o
-- módulo apenas quando a tecla é usada (nenhum módulo é carregado pelo
-- setup()).

local M = {}

-- Ações do menu: nome → tecla (sufixo do prefixo), módulo, modos e rótulo.
-- A função pública de entrada de cada módulo mantém a responsabilidade que
-- já tinha (new.new, build.build, ...).
M.actions = {
  new = { key = "n", module = "java_menu.new", entry = "new", modes = { "n" }, desc = "New" },
  generate = { key = "g", module = "java_menu.generate", entry = "generate", modes = { "n" }, desc = "Generate" },
  refactor = { key = "r", module = "java_menu.refactor", entry = "refactor", modes = { "n", "x" }, desc = "Refactor" },
  imports = { key = "i", module = "java_menu.imports", entry = "imports", modes = { "n" }, desc = "Imports" },
  build = { key = "b", module = "java_menu.build", entry = "build", modes = { "n" }, desc = "Build/Run" },
  tests = { key = "t", module = "java_menu.tests", entry = "tests", modes = { "n" }, desc = "Tests" },
  debug = { key = "d", module = "java_menu.debug", entry = "debug", modes = { "n" }, desc = "Debug" },
}

M.config = {
  prefix = "<leader>j",
  -- habilitar/desabilitar grupos (chaves de M.actions); true por padrão
  groups = {},
  -- registrar o rótulo do grupo no which-key quando disponível (opcional)
  which_key = true,
}

-- Mapas e comando criados pela última chamada de setup() — base da
-- idempotência: re-executar setup() limpa os próprios registros antes de
-- recriar, nunca duplicando.
local registered = {
  maps = {}, -- { { mode, lhs }, ... }
  command = nil,
}

local DESC_PREFIX = "Java Menu: "

local function desc_for(action)
  return DESC_PREFIX .. action.desc
end

---Exige jc.nvim (dependência obrigatória) com erro claro e acionável.
local function require_jc()
  local ok, jc_jdtls = pcall(require, "jc.jdtls")
  if not ok or type(jc_jdtls) ~= "table" then
    error(
      "java-menu.nvim: jc.nvim é dependência obrigatória e não foi encontrado "
        .. "(require('jc.jdtls') falhou: "
        .. tostring(jc_jdtls)
        .. "). Instale artur-shaik/jc.nvim junto a este plugin."
    )
  end
end

---Remove os registros criados por um setup() anterior (idempotência).
local function clear_previous()
  for _, m in ipairs(registered.maps) do
    pcall(vim.keymap.del, m.mode, m.lhs)
  end
  registered.maps = {}
  if registered.command then
    pcall(vim.api.nvim_del_user_command, registered.command)
    registered.command = nil
  end
end

---Atalhos já existentes de terceiros não são sobrescritos: são preservados
---e o conflito é informado uma vez, com o atalho afetado. Um mapeamento com
---a nossa descrição (registro próprio que sobreviveu ao cleanup) é tratado
---como nosso e pode ser recriado.
local function conflicting(lhs, mode, want_desc)
  local existing = vim.fn.maparg(lhs, mode, false, true)
  if type(existing) ~= "table" or vim.tbl_isempty(existing) then
    return false
  end
  return existing.desc ~= want_desc
end

local function apply_keymaps(prefix, groups, conflicts)
  for name, action in pairs(M.actions) do
    if groups[name] then
      local lhs = prefix .. action.key
      local want_desc = desc_for(action)
      for _, mode in ipairs(action.modes) do
        if conflicting(lhs, mode, want_desc) then
          conflicts[#conflicts + 1] = ("%s (%s): já mapeado para outro propósito — atalho preservado, grupo '%s' não registrado"):format(
            lhs,
            mode,
            name
          )
        else
          vim.keymap.set(mode, lhs, function()
            local mod = require(action.module)
            mod[action.entry]()
          end, { desc = want_desc, silent = true })
          registered.maps[#registered.maps + 1] = { mode = mode, lhs = lhs }
        end
      end
    end
  end
end

local function sorted_action_names()
  local names = {}
  for name in pairs(M.actions) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---Executa um grupo do menu sob demanda — ponto de entrada para `keys` do
---gerenciador de plugins (carrega só o módulo da ação pedida).
---@param name string
function M.trigger(name)
  local action = M.actions[name]
  if not action then
    error(
      "java-menu.nvim: ação desconhecida '"
        .. tostring(name)
        .. "' — opções: "
        .. table.concat(sorted_action_names(), ", ")
    )
  end
  require(action.module)[action.entry]()
end

local function apply_command()
  local names = sorted_action_names()
  vim.api.nvim_create_user_command("JavaMenu", function(ev)
    local name = ev.args ~= "" and ev.args or nil
    if not name then
      vim.notify("java-menu.nvim: use :JavaMenu <" .. table.concat(names, "|") .. ">", vim.log.levels.INFO)
      return
    end
    M.trigger(name)
  end, {
    nargs = "?",
    complete = function()
      return names
    end,
    desc = "Abre um grupo do menu Java",
  })
  registered.command = "JavaMenu"
end

local function apply_which_key(prefix)
  if not M.config.which_key then
    return
  end
  -- integração opcional: ausência de which-key não é erro
  local ok, wk = pcall(require, "which-key")
  if ok and type(wk.add) == "function" then
    pcall(wk.add, { { prefix, group = "Java" } })
  end
end

---Configura o plugin. Idempotente: re-executar limpa os próprios atalhos e
---o próprio comando antes de recriar; atalhos de terceiros são preservados
---e conflitos são informados. Nenhum módulo Java é carregado aqui.
---@param opts { prefix?: string, groups?: table<string, boolean>, which_key?: boolean }|nil
function M.setup(opts)
  opts = opts or {}
  if opts.prefix ~= nil and type(opts.prefix) ~= "string" then
    error("java-menu.nvim: opts.prefix deve ser string, recebi " .. type(opts.prefix))
  end
  if opts.groups ~= nil and type(opts.groups) ~= "table" then
    error("java-menu.nvim: opts.groups deve ser tabela, recebi " .. type(opts.groups))
  end

  require_jc()

  M.config.prefix = opts.prefix or M.config.prefix
  if opts.groups then
    for k, v in pairs(opts.groups) do
      M.config.groups[k] = v
    end
  end
  if opts.which_key ~= nil then
    M.config.which_key = opts.which_key
  end

  clear_previous()

  local conflicts = {}
  apply_keymaps(M.config.prefix, M.config.groups, conflicts)
  apply_command()
  apply_which_key(M.config.prefix)

  if #conflicts > 0 then
    vim.notify("java-menu.nvim: " .. table.concat(conflicts, "; "), vim.log.levels.WARN)
  end
end

return M
