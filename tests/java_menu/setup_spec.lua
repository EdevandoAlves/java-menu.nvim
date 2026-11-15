-- 6C.1: API pública require("java_menu").setup(opts).
-- setup executa; repetido não duplica; atalhos/comando registrados; carregam
-- módulos sob demanda; atalho de terceiros é preservado com aviso; grupos
-- podem ser desabilitados; prefixo customizável; jc.nvim ausente → erro
-- claro (nunca PASS falso).
--
-- Run:
--   tests/java_menu/run.sh fast

local jm = require("java_menu")

local prefix = "<leader>j"

-- captura de notificações (restaurado ao final — isolamento)
local real_notify = vim.notify
local notices = {}
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = tostring(msg), level = level }
end
local function last_notice()
  return notices[#notices] and notices[#notices].msg or ""
end

local function count_ours(mode, pre)
  local n = 0
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if type(m.desc) == "string" and m.desc:find("^Java Menu: ", 1, true) and (not pre or m.lhs:find(pre, 1, true)) then
      n = n + 1
    end
  end
  return n
end

local enabled_n = 0
for _, action in pairs(jm.actions) do
  for _, mode in ipairs(action.modes) do
    if mode == "n" then
      enabled_n = enabled_n + 1
    end
  end
end

-- ---------- 1. setup() executa e registra atalhos + comando ----------

jm.setup({ prefix = prefix })

for name, action in pairs(jm.actions) do
  for _, mode in ipairs(action.modes) do
    local m = vim.fn.maparg(prefix .. action.key, mode, false, true)
    assert(
      type(m) == "table" and not vim.tbl_isempty(m),
      "atalho " .. prefix .. action.key .. " (" .. mode .. ") não registrado"
    )
    assert(m.desc == "Java Menu: " .. action.desc, "desc inesperada para " .. name .. ": " .. tostring(m.desc))
    assert(type(m.rhs) == "string" or type(m.rhs) == "function", "rhs inesperado para " .. name)
  end
end
assert(vim.fn.exists(":JavaMenu") == 2, "comando :JavaMenu não registrado")

-- ---------- 2. carregamento sob demanda ----------

assert(package.loaded["java_menu.new"] == nil, "setup carregou java_menu.new eager")
assert(package.loaded["java_menu.build"] == nil, "setup carregou java_menu.build eager")

-- ---------- 3. setup() repetido não duplica ----------

jm.setup({ prefix = prefix })
assert(count_ours("n") == enabled_n, "setup repetido duplicou mapas n: " .. count_ours("n") .. " != " .. enabled_n)
assert(count_ours("x") == 1, "setup repetido duplicou mapa x (refactor)")

-- ---------- 4. atalho de terceiros é preservado + conflito informado ----------

vim.keymap.del("n", prefix .. "n")
vim.keymap.set("n", prefix .. "n", function() end, { desc = "meu mapa pessoal" })
notices = {}
jm.setup({ prefix = prefix })
assert(
  last_notice():find("conflito", 1, true) ~= nil and last_notice():find(prefix .. "n", 1, true) ~= nil,
  "conflito não informado: " .. last_notice()
)
local mine = vim.fn.maparg(prefix .. "n", "n", false, true)
assert(type(mine) == "table" and mine.desc == "meu mapa pessoal", "atalho de terceiros foi sobrescrito")

-- ---------- 5. prefixo customizável ----------

jm.setup({ prefix = "<leader>J" })
assert(vim.fn.maparg("<leader>Jn", "n", false, true).desc == "Java Menu: New", "prefixo customizado não registrado")
assert(vim.fn.maparg("<leader>Jr", "x", false, true).desc == "Java Menu: Refactor", "refactor sem prefixo customizado")
assert(vim.fn.maparg("<leader>Jn", "n", false, true).desc ~= nil, "sanidade do prefixo J")
mine = vim.fn.maparg(prefix .. "n", "n", false, true)
assert(type(mine) == "table" and mine.desc == "meu mapa pessoal", "prefixo novo apagou atalho do prefixo antigo")

-- ---------- 6. grupos desabilitáveis ----------

jm.setup({ prefix = prefix, groups = { tests = false } })
assert(vim.fn.maparg(prefix .. "t", "n") == "", "grupo tests desabilitado continua mapeado")
assert(
  vim.fn.maparg(prefix .. "b", "n", false, true).desc == "Java Menu: Build/Run",
  "grupo build sumiu ao desabilitar tests"
)

-- comando: sem args → orientação; args inválidos → erro claro (sem UI)
notices = {}
vim.cmd("JavaMenu")
assert(last_notice():find("JavaMenu <", 1, true) ~= nil, ":JavaMenu sem args não orientou o uso")
local ok_trig, err_trig = pcall(jm.trigger, "inexistente")
assert(
  not ok_trig and tostring(err_trig):find("ação desconhecida", 1, true),
  "trigger de ação desconhecida não falhou claramente"
)

-- ---------- 7. validação de opts ----------

local ok, err = pcall(jm.setup, { prefix = 42 })
assert(
  not ok and tostring(err):find("prefix deve ser string", 1, true),
  "prefix não-string não rejeitado: " .. tostring(err)
)

-- ---------- 8. jc.nvim ausente → erro claro (nunca PASS falso) ----------

local jc_loaded = package.loaded["jc.jdtls"]
package.loaded["jc.jdtls"] = nil
package.preload["jc.jdtls"] = function()
  error("not found (simulado)", 0)
end
ok, err = pcall(jm.setup, { prefix = prefix })
package.preload["jc.jdtls"] = nil
if jc_loaded ~= nil then
  package.loaded["jc.jdtls"] = jc_loaded
end
assert(not ok, "setup sem jc.nvim deveria falhar")
assert(
  tostring(err):find("dependência obrigatória", 1, true) ~= nil and tostring(err):find("jc.nvim", 1, true) ~= nil,
  "erro sem jc.nvim não é claro: " .. tostring(err)
)

-- ---------- restauração ----------

vim.notify = real_notify

-- which-key ausente nesta sessão (-u NONE): setup não errou em nenhum passo
-- acima, provando que a integração é opcional.
print("[setup_spec] OK: setup idempotente, atalhos/comando registrados, conflitos preservados, jc obrigatório")
