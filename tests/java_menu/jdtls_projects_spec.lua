-- B4 (real): dois projetos com o mesmo basename em paths distintos, cada um
-- com workspace JDTLS exclusivo; D (reabrir preserva identidade) e E (dois
-- projetos simultâneos). 6B.4A: Replace Import e Generate Constructor reais
-- com 2 clientes, e bloqueio de ambiguidade. Ao final, Attach JVM real via
-- nvim-dap + java-debug (H).
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/Projects/java-menu.nvim" \
--     -c "set rtp+=~/.local/share/nvim/lazy/nvim-jdtls" \
--     -c "set rtp+=~/.local/share/nvim/lazy/nvim-lspconfig" \
--     -c "set rtp+=~/.local/share/nvim/lazy/nvim-dap" \
--     -c "set rtp+=~/.local/share/nvim/lazy/jc.nvim" \
--     -c "luafile tests/java_menu/jdtls_projects_spec.lua" -c qa

local lsp = require("java_menu.lsp")
local project = require("java_menu.project")
local fixtures = require("tests.java_menu.fixtures")

local ok_jdtls, jdtls = pcall(require, "jdtls")
assert(ok_jdtls and type(jdtls.start_or_attach) == "function", "nvim-jdtls indisponível")
local jdtls_bin = vim.fn.exepath("jdtls")
if jdtls_bin == "" then
  jdtls_bin = vim.fn.stdpath("data") .. "/mason/bin/jdtls"
end
assert(vim.fn.filereadable(jdtls_bin) == 1, "jdtls não está disponível")

local debug_jar = vim.fn.stdpath("data") .. "/mason/share/java-debug-adapter/com.microsoft.java.debug.plugin.jar"
assert(vim.fn.filereadable(debug_jar) == 1, "java-debug não está instalado no mason")

local ws = "/tmp/opencode/jdtls-ws-" .. tostring(vim.fn.getpid())
vim.fn.system({ "rm", "-rf", ws })
local a = ws .. "/wsa/alpha"
local b = ws .. "/wsb/alpha"
vim.fn.mkdir(a .. "/src/main/java/com/wsa", "p")
vim.fn.mkdir(b .. "/src/main/java/com/wsb", "p")

local function pom(path, name)
  vim.fn.writefile({
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.ws</groupId>",
    "  <artifactId>" .. name .. "</artifactId>",
    "  <version>1.0</version>",
    "  <properties><maven.compiler.release>21</maven.compiler.release></properties>",
    "</project>",
  }, path)
end

pom(a .. "/pom.xml", "alpha-wsa")
pom(b .. "/pom.xml", "alpha-wsb")
local main_a = a .. "/src/main/java/com/wsa/Main.java"
local main_b = b .. "/src/main/java/com/wsb/Main.java"
vim.fn.writefile({ "package com.wsa;", "", "public class Main {}" }, main_a)
vim.fn.writefile({ "package com.wsb;", "", "public class Main {}" }, main_b)

-- mesmo caminho de cmd usado pelo handler em plugins/java.lua
local wdir_a = project.workspace_dir(a)
local wdir_b = project.workspace_dir(b)
assert(wdir_a ~= wdir_b, "C: workspaces de projetos com mesmo basename colidiram")
assert(vim.fn.fnamemodify(wdir_a, ":t") ~= "alpha", "workspace voltou ao esquema de basename")
assert(vim.fn.fnamemodify(wdir_b, ":t") ~= "alpha", "workspace voltou ao esquema de basename")

local function jdtls_clients()
  return vim.lsp.get_clients({ name = "jdtls" })
end

local function client_for(bufnr)
  local client = lsp.client(bufnr)
  assert(client, "jdtls não anexou ao buffer " .. bufnr)
  return client
end

-- E/C. primeiro projeto (alpha em wsa), com java-debug no cliente (para o DAP)
vim.cmd("edit " .. vim.fn.fnameescape(main_a))
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", wdir_a },
  root_dir = a,
  capabilities = lsp.capabilities(),
  init_options = { bundles = { debug_jar } },
})
assert(
  fixtures.wait_for(60000, function()
    return lsp.client(0) ~= nil
  end),
  "jdtls do projeto A não anexou"
)
local client_a = client_for(0)
assert(client_a.config.root_dir == a, "root do cliente A diverge")
assert(project.client_workspace_dir(client_a) == wdir_a, "cliente A usa outro workspace")
assert(#jdtls_clients() == 1, "cliente extra inesperado")

-- D. reabrir o mesmo projeto (outro arquivo) preserva cliente e identidade
local util_a = a .. "/src/main/java/com/wsa/Util.java"
vim.fn.writefile({ "package com.wsa;", "", "public class Util {}" }, util_a)
vim.cmd("edit " .. vim.fn.fnameescape(util_a))
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", wdir_a },
  root_dir = a,
  capabilities = lsp.capabilities(),
  init_options = { bundles = { debug_jar } },
})
fixtures.wait_for(3000, function()
  return false
end)
assert(#jdtls_clients() == 1, "D: reabrir o mesmo projeto criou um segundo cliente")
local client_a2 = lsp.client(vim.fn.bufnr(util_a))
assert(client_a2.id == client_a.id, "D: cliente do projeto mudou na reabertura")
assert(project.client_workspace_dir(client_a2) == wdir_a, "D: identidade do workspace mudou")

-- E. segundo projeto com o MESMO basename, simultâneo
vim.cmd("edit " .. vim.fn.fnameescape(main_b))
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", wdir_b },
  root_dir = b,
  capabilities = lsp.capabilities(),
})
assert(
  fixtures.wait_for(60000, function()
    local client = nil
    for _, c in ipairs(jdtls_clients()) do
      if c.config.root_dir == b then
        client = c
      end
    end
    return client ~= nil
  end),
  "jdtls do projeto B não anexou"
)
assert(#jdtls_clients() == 2, "E: esperava 2 clientes simultâneos, recebi " .. #jdtls_clients())
local client_b = client_for(vim.fn.bufnr(main_b))
assert(client_b.config.root_dir == b, "root do cliente B diverge")
assert(project.client_workspace_dir(client_b) == wdir_b, "cliente B usa outro workspace")
assert(client_b.id ~= client_a.id, "clientes A/B deveriam ser distintos")
assert(lsp.client(vim.fn.bufnr(main_a)).id == client_a.id, "buffer do projeto A perdeu o cliente certo")

-- ---------- 6B.4A: compat jc com clientes reais ----------

local ui = require("java_menu.ui")
local imports = require("java_menu.imports")
local compat_notices = {}
ui.notify = function(msg, _)
  compat_notices[#compat_notices + 1] = tostring(msg)
end

local function compat_has(text)
  for _, notice in ipairs(compat_notices) do
    if notice:find(text, 1, true) then
      return true
    end
  end
  return false
end

-- bloqueio de ambiguidade: operação do jc com cliente global e 2 projetos
vim.cmd("edit " .. vim.fn.fnameescape(main_a))
vim.bo.filetype = "java"
local imports_menu_cb
ui.menu = function(_, _, on_choice)
  imports_menu_cb = on_choice
end
imports.imports()
imports_menu_cb({ key = "organize_smart", label = "Organize Imports (smart)" })
assert(
  compat_has("unavailable with 2 Java projects"),
  "bloqueio de ambiguidade não ocorreu: " .. table.concat(compat_notices, "; ")
)
-- o mesmo guard protege o Generate (runner de generate.lua)
assert(lsp.jc_global_reason("Generate") ~= nil, "guard do Generate ausente com 2 clientes")

-- Replace Import REAL com 2 clientes anexados: prova de cliente por buffer
-- (a chamada workspace/symbol vai para o cliente do buffer do projeto A)
local user_list = a .. "/src/main/java/com/wsa/Using.java"
vim.fn.mkdir(vim.fs.dirname(user_list), "p")
vim.fn.writefile({
  "package com.wsa;",
  "",
  "public class Using {",
  "    List names;",
  "}",
}, user_list)
vim.cmd("edit " .. vim.fn.fnameescape(user_list))
vim.bo.filetype = "java"
-- no Neovim real o handler FileType chama start_or_attach novamente e anexa
-- o buffer novo; reproduzimos o mesmo caminho aqui
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", wdir_a },
  root_dir = a,
  capabilities = lsp.capabilities(),
  init_options = { bundles = { debug_jar } },
})
assert(
  fixtures.wait_for(30000, function()
    return lsp.client(vim.fn.bufnr(user_list)) ~= nil
  end),
  "buffer Using.java não anexou ao jdtls"
)
vim.api.nvim_win_set_cursor(0, { 4, 4 })
local pick_labels, pick_choice, pick_chosen
ui.pick_one = function(items, prompt, on_choice)
  pick_labels = items
  pick_choice = prompt
  for _, item in ipairs(items) do
    if item:find("java%.util%.List") then
      pick_chosen = item
      return on_choice(item)
    end
  end
  pick_chosen = items[1]
  return on_choice(items[1])
end
imports.imports()
imports_menu_cb({ key = "replace", label = "Replace Import" })
local using_buf = vim.fn.bufnr(user_list)
assert(
  fixtures.wait_for(30000, function()
    if not (using_buf ~= -1 and vim.api.nvim_buf_is_loaded(using_buf)) then
      return false
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(using_buf, 0, -1, false), "\n")
    return text:find("import java.util.List;", 1, true) ~= nil
  end),
  "Replace Import real não inseriu o import (labels: "
    .. vim.inspect(pick_labels)
    .. ", escolhido: "
    .. tostring(pick_chosen)
    .. "; buffer: "
    .. vim.inspect(using_buf ~= -1 and vim.api.nvim_buf_get_lines(using_buf, 0, -1, false) or "sem buffer")
    .. "; notices: "
    .. table.concat(compat_notices, "; ")
    .. ")"
)
assert(vim.bo[using_buf].modified, "Replace Import deveria deixar o buffer pendente (sem salvar)")

-- Generate Constructor REAL (jc.jdtls.generate_constructor). O caminho do jc
-- resolve o cliente globalmente, então — como na produção (guard em
-- generate.lua) — o cenário suportado é cliente único: encerramos o cliente B.
client_b:stop()
if not fixtures.wait_for(60000, function()
  return #vim.lsp.get_clients({ name = "jdtls" }) == 1
end) then
  -- jdtls pode não responder ao shutdown no headless: kill forçado
  pcall(vim.lsp.stop_client, client_b.id, true)
  assert(
    fixtures.wait_for(30000, function()
      return #vim.lsp.get_clients({ name = "jdtls" }) == 1
    end),
    "cliente B não encerrou nem com kill forçado"
  )
end
assert(lsp.jc_global_reason("Generate") == nil, "guard deveria liberar com cliente único")
local fielded = a .. "/src/main/java/com/wsa/Fielded.java"
vim.fn.writefile({
  "package com.wsa;",
  "",
  "public class Fielded {",
  "    private String name;",
  "}",
}, fielded)
vim.cmd("edit " .. vim.fn.fnameescape(fielded))
vim.bo.filetype = "java"
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", wdir_a },
  root_dir = a,
  capabilities = lsp.capabilities(),
  init_options = { bundles = { debug_jar } },
})
assert(
  fixtures.wait_for(30000, function()
    return lsp.client(vim.fn.bufnr(fielded)) ~= nil
  end),
  "buffer Fielded.java não anexou ao jdtls"
)
vim.api.nvim_win_set_cursor(0, { 4, 4 })
-- o jdtls precisa ter analisado o arquivo novo; tenta até o construtor surgir.
-- Caminho canônico do JCgenerateConstructorDefault: status → default.
vim.wait(3000)
local jc_notices = {}
vim.notify = function(msg, _)
  jc_notices[#jc_notices + 1] = tostring(msg)
end
local fielded_buf = vim.fn.bufnr(fielded)
local inserted = false
for _ = 1, 4 do
  require("jc.jdtls").generate_constructor(nil, nil, { default = true })
  if
    fixtures.wait_for(20000, function()
      if not (fielded_buf ~= -1 and vim.api.nvim_buf_is_loaded(fielded_buf)) then
        return false
      end
      local text = table.concat(vim.api.nvim_buf_get_lines(fielded_buf, 0, -1, false), "\n")
      return text:find("public Fielded()", 1, true) ~= nil
    end)
  then
    inserted = true
    break
  end
end
assert(inserted, "Generate Constructor real não inseriu o construtor; jc avisou: " .. table.concat(jc_notices, "; "))

-- ---------- DAP attach real (H) ----------

local dap_ok, dap = pcall(require, "dap")
assert(dap_ok, "nvim-dap indisponível para o teste de Attach")
jdtls.setup_dap({})

local debug_root = ws .. "/attach"
vim.fn.mkdir(debug_root .. "/src", "p")
vim.fn.writefile({
  "public class Sleeper {",
  "  public static void main(String[] a) throws Exception {",
  "    Thread.sleep(60000);",
  "  }",
  "}",
}, debug_root .. "/src/Sleeper.java")
local job = vim.fn.jobstart({
  "java",
  "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005",
  "-cp",
  debug_root .. "/src",
  "Sleeper",
})
assert(job > 0, "não consegui lançar a JVM alvo")

-- espera a porta JDWP abrir (via /dev/tcp do bash; portátil e sem ss)
local function port_open(port)
  vim.fn.system({ "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/" .. port .. " && exec 3>&-" })
  return vim.v.shell_error == 0
end
assert(
  vim.wait(20000, function()
    return port_open(5005)
  end, 300),
  "porta JDWP 5005 não abriu"
)

local notices = {}
local ui = require("java_menu.ui")
ui.notify = function(msg, _)
  notices[#notices + 1] = tostring(msg)
end
ui.jdtls_attached = function(_)
  return true
end
local ask_values = { "127.0.0.1", "5005" }
ui.ask = function(_, _, cb)
  cb(table.remove(ask_values, 1))
end
local menu_cb
ui.menu = function(_, _, on_choice)
  menu_cb = on_choice
end

-- o cliente usado pelo java-debug é o do buffer atual (precisa ser do projeto A,
-- que carrega o bundle java-debug)
vim.cmd("edit " .. vim.fn.fnameescape(main_a))
local debug_menu = require("java_menu.debug")
debug_menu.debug()
menu_cb({ key = "attach" })
assert(
  fixtures.wait_for(30000, function()
    return dap.session() ~= nil
  end),
  "sessão DAP não iniciou: " .. table.concat(notices, "; ")
)
assert(dap.session().config.request == "attach", "sessão não é attach")
assert(dap.session().config.hostName == "127.0.0.1" and dap.session().config.port == 5005, "alvo do attach diverge")

pcall(dap.disconnect, { terminateDebuggee = true })
assert(
  fixtures.wait_for(15000, function()
    return dap.session() == nil
  end),
  "sessão DAP não encerrou"
)
vim.fn.jobstop(job)

print("jdtls_projects_spec: OK")
vim.cmd("qa!")
