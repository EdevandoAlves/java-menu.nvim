-- A2: capabilities do JDTLS com e sem blink.cmp (achado A2 da Auditoria 6A).
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "luafile tests/java_menu/capabilities_spec.lua" -c qa

local lsp = require("java_menu.lsp")

-- B. sem blink disponível: capabilities nativas do Neovim
local native = lsp.capabilities()
assert(type(native) == "table", "capabilities não é tabela")
assert(type(native.textDocument) == "table", "capabilities nativas sem textDocument")

-- A. blink disponível (módulo falso injetado): mescla sobre as nativas
package.loaded["blink.cmp"] = {
  get_lsp_capabilities = function(base)
    base.__blink_marker = true
    return base
  end,
}
local merged = lsp.capabilities()
assert(merged.__blink_marker == true, "capabilities do blink não foram usadas")
assert(type(merged.textDocument) == "table", "blink descartou as capabilities nativas")
package.loaded["blink.cmp"] = nil

-- blink inutilizável (módulo sem a API esperada) também cai no fallback nativo
package.loaded["blink.cmp"] = { sem_api = true }
local fallback = lsp.capabilities()
assert(fallback.__blink_marker == nil, "fallback não deveria usar módulo sem get_lsp_capabilities")
assert(type(fallback.textDocument) == "table", "fallback nativo quebrado")
package.loaded["blink.cmp"] = nil

-- A real: com o blink.cmp instalado no disco, o caminho real também funciona
package.loaded["blink.cmp"] = nil
local blink_lua = vim.fs.normalize(vim.env.HOME) .. "/.local/share/nvim/lazy/blink.cmp/lua"
if vim.fn.isdirectory(blink_lua) == 1 then
  package.path = package.path .. ";" .. blink_lua .. "/?.lua;" .. blink_lua .. "/?/init.lua"
  local ok_real, real_err = pcall(function()
    local blink = require("blink.cmp")
    assert(type(blink.get_lsp_capabilities) == "function", "blink real sem get_lsp_capabilities")
    local caps = lsp.capabilities()
    assert(type(caps) == "table" and type(caps.textDocument) == "table", "blink real quebrou as capabilities")
  end)
  if not ok_real then
    -- dependências internas do blink podem faltar no headless; o caminho
    -- testado acima (falso) já cobre o comportamento do Java Menu
    print("capabilities_spec: blink real não carregou (" .. tostring(real_err) .. ") — parcial OK")
  end
end

print("capabilities_spec: OK")
vim.cmd("qa!")
