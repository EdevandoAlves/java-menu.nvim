-- Valida a documentação nativa (doc/java-menu.txt) sem configuração pessoal.
-- Usado pelo CI e localmente:
--   nvim --headless -u NONE -c "set rtp+=<repo>" -c "luafile tests/java_menu/help_check.lua"
-- Falha (exit != 0) quando tags obrigatórias estão ausentes ou o conteúdo
-- esperado não é encontrado.

local script_path = debug.getinfo(1, "S").source:sub(2)
if script_path:sub(1, 1) ~= "/" then -- invocação com caminho relativo ao cwd
  script_path = vim.fs.joinpath(vim.uv.cwd(), script_path)
end
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script_path))))

-- nenhuma configuração pessoal pode estar no rtp
for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
  assert(not p:find("/.config/nvim", 1, true), "config pessoal no rtp: " .. p)
end

vim.cmd("helptags " .. vim.fn.fnameescape(repo .. "/doc"))
assert(vim.fn.filereadable(repo .. "/doc/tags") == 1, "doc/tags não foi gerado")

-- tags obrigatórias e uma âncora de conteúdo de cada seção
local expectations = {
  ["java-menu"] = "Contextual Java menus",
  ["java-menu-intro"] = "contextual menu layer",
  ["java-menu-requirements"] = "jc.nvim",
  ["java-menu-install"] = "helptags ALL",
  ["java-menu-setup"] = 'require("java_menu").setup',
  ["java-menu-opts"] = "which_key",
  ["java-menu-commands"] = ":JavaMenu",
  ["java-menu-javamenu"] = ":JavaMenu [group]",
  ["java-menu-keymaps"] = "Global keymaps",
  ["java-menu-groups"] = "MENU GROUPS",
  ["java-menu-new"] = "Wizard for Class",
  ["java-menu-generate"] = "duplicate detection",
  ["java-menu-refactor"] = "preview workflow",
  ["java-menu-imports"] = "wildcard imports",
  ["java-menu-build"] = "One build process",
  ["java-menu-tests"] = "neotest with jc.nvim's adapter",
  ["java-menu-debug"] = "java-debug bundle",
  ["java-menu-preview"] = "never",
  ["java-menu-limitations"] = "LIMITATIONS",
  ["java-menu-troubleshooting"] = "TROUBLESHOOTING",
  ["java-menu-credits"] = "Artur Shaik",
  ["java-menu-project"] = "New Project",
  ["java-menu-calls"] = "Call Hierarchy",
  ["java-menu-types"] = "Type Hierarchy",
  ["java-menu-stacktrace"] = "Stack Trace",
}

for tag, needle in pairs(expectations) do
  vim.cmd("help " .. tag)
  assert(vim.bo.filetype == "help", tag .. ": filetype não é help")
  assert(
    vim.api.nvim_buf_get_name(0):find("java%-menu%.txt", 1, false),
    tag .. ": abriu arquivo errado: " .. vim.api.nvim_buf_get_name(0)
  )
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(text:find(needle, 1, true) ~= nil, "tag " .. tag .. ": conteúdo '" .. needle .. "' não encontrado")
end

-- tag inexistente deve falhar (garante que a checagem não bate sempre)
local ok = pcall(vim.cmd, "help java-menu-tag-que-nao-existe")
assert(not ok, "tag inexistente deveria falhar")

print("[help_check] OK — " .. #vim.tbl_keys(expectations) .. " tags validadas")
