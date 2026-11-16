-- M4: Debug Main só com launch configs do projeto correto (achado M4),
-- configuração ambígua (G) e sem regressão de JUnit/Attach (H) no nível do
-- menu, com nvim-dap simulado (module injetado).
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "luafile tests/java_menu/debug_project_spec.lua" -c qa

local ui = require("java_menu.ui")
local debug_menu = require("java_menu.debug")

-- dois projetos reais em disco (para project.root e os metadados cwd baterem)
local base = vim.fs.normalize(vim.fn.tempname())
local root = base .. "/dbgproj"
local other_root = base .. "/dbgproj2"
vim.fn.mkdir(root .. "/src/main/java/com/demo", "p")
vim.fn.mkdir(other_root .. "/src/main/java/com/other", "p")
vim.fn.writefile({
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>com.demo</groupId><artifactId>dbgproj</artifactId><version>1.0</version>",
  "</project>",
}, root .. "/pom.xml")
vim.fn.writefile({
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>com.other</groupId><artifactId>dbgproj2</artifactId><version>1.0</version>",
  "</project>",
}, other_root .. "/pom.xml")
local main_file = root .. "/src/main/java/com/demo/Main.java"
vim.fn.writefile({ "package com.demo;", "", "public class Main {}" }, main_file)
vim.fn.writefile(
  { "package com.other;", "", "public class OtherMain {}" },
  other_root .. "/src/main/java/com/other/OtherMain.java"
)

-- nvim-dap simulado com configs de projetos distintos
local launched = {}
local dap_configurations
local fake_dap
fake_dap = {
  adapters = { java = {} },
  session = function()
    return nil
  end,
  configurations = setmetatable({}, {
    __index = function(_, key)
      return dap_configurations and dap_configurations[key] or nil
    end,
    __newindex = function(_, key, value)
      dap_configurations = dap_configurations or {}
      dap_configurations[key] = value
    end,
  }),
  run = function(config)
    launched[#launched + 1] = config
  end,
  continue = function() end,
}
fake_dap.configurations.java = {
  {
    name = "Launch dbgproj: com.demo.Main",
    type = "java",
    request = "launch",
    mainClass = "com.demo.Main",
    projectName = "dbgproj",
    cwd = root,
    classPaths = { root .. "/target/classes" },
  },
  {
    name = "Launch dbgproj2: com.other.OtherMain",
    type = "java",
    request = "launch",
    mainClass = "com.other.OtherMain",
    projectName = "dbgproj2",
    cwd = other_root,
    classPaths = { other_root .. "/target/classes" },
  },
  {
    -- mesmo nome de classe do projeto atual, mas de OUTRO projeto:
    -- class name nunca pode ser critério de pertencimento
    name = "Launch dbgproj2: com.demo.Main (clone)",
    type = "java",
    request = "launch",
    mainClass = "com.demo.Main",
    projectName = "dbgproj2",
    cwd = other_root,
    classPaths = { other_root .. "/target/classes" },
  },
  {
    name = "Launch dbgproj2: runner",
    type = "java",
    request = "launch",
    mainClass = "com.microsoft.java.test.runner.Launcher",
    projectName = "dbgproj2",
    cwd = other_root,
  },
  {
    -- sem cwd/classPaths/projectName: ambígua
    name = "Launch ghost",
    type = "java",
    request = "launch",
    mainClass = "com.ghost.Ghost",
  },
}
package.loaded["dap"] = fake_dap

-- stubs de UI
local notices = {}
local menu_entries, menu_cb
local pick_labels, pick_choice, pick_cb
local asks = { "127.0.0.1", "5005" }

ui.notify = function(msg, _)
  notices[#notices + 1] = tostring(msg)
end
ui.jdtls_attached = function(_)
  return true
end
ui.menu = function(entries, _, on_choice)
  menu_entries, menu_cb = entries, on_choice
end
ui.pick_one = function(items, _, on_choice)
  pick_labels, pick_cb = items, on_choice
  if pick_choice then
    on_choice(pick_choice)
  end
end
ui.ask = function(_, _, cb)
  cb(table.remove(asks, 1))
end

local function has_notice(text)
  for _, notice in ipairs(notices) do
    if notice:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function entry(key)
  for _, item in ipairs(menu_entries or {}) do
    if item.key == key then
      return item
    end
  end
end

-- buffer de contexto: Main.java do projeto dbgproj
vim.cmd("edit " .. vim.fn.fnameescape(main_file))
vim.bo.filetype = "java"

-- F. só configs do projeto do buffer ficam disponíveis
local own, other, ambiguous = debug_menu._project_configs(0)
assert(#own == 1, "esperava 1 config do próprio projeto, recebi " .. #own)
assert(own[1].mainClass == "com.demo.Main", "config errada marcada como própria")
assert(#other == 3, "esperava 3 configs de outros projetos, recebi " .. #other)
assert(#ambiguous == 1, "esperava 1 config ambígua, recebi " .. #ambiguous)

-- nome de classe igual ao nosso não torna config de outro projeto "own"
local roots = debug_menu._current_roots(0)
assert(
  debug_menu._classify_config({ request = "launch", cwd = other_root, mainClass = "com.demo.Main" }, roots) == "other",
  "class name foi usado como critério de pertencimento"
)
-- projectName sozinho não prova pertencimento (nomes podem coincidir)
assert(
  debug_menu._classify_config({ request = "launch", projectName = "dbgproj" }, roots) == "ambiguous",
  "projectName sozinho deveria ser ambíguo"
)

-- F. launch pelo menu só oferece a main do próprio projeto e nunca inicia outra
debug_menu.debug()
local main_entry = entry("main")
assert(main_entry.enabled == true, "Debug Main deveria estar habilitado com config do projeto")
menu_cb(main_entry)
assert(
  type(pick_labels) == "table" and #pick_labels == 1,
  "menu ofereceu configs de outros projetos: " .. vim.inspect(pick_labels)
)
assert(pick_labels[1]:find("dbgproj:", 1, true), "rótulo do próprio projeto ausente: " .. tostring(pick_labels[1]))
pick_cb(pick_labels[1])
assert(#launched == 1, "config não foi lançada")
assert(launched[1].mainClass == "com.demo.Main" and launched[1].cwd == root, "main de projeto errado foi iniciada")

-- G. configuração ambígua: desabilitada e nunca iniciada
launched = {}
pick_labels, pick_choice = nil, nil
fake_dap.configurations.java = {
  { name = "Launch ghost", type = "java", request = "launch", mainClass = "com.ghost.Ghost" },
  { name = "Launch byproject", type = "java", request = "launch", mainClass = "com.x.Y", projectName = "dbgproj" },
}
debug_menu.debug()
main_entry = entry("main")
assert(main_entry.enabled == false, "Debug Main deveria estar desabilitado sem configs do projeto")
assert(
  main_entry.reason:find("without project metadata", 1, true),
  "motivo da ambiguidade ausente: " .. tostring(main_entry.reason)
)
menu_cb(main_entry)
assert(has_notice("nothing was started"), "configuração ambígua não avisou: " .. vim.inspect(notices))
assert(#launched == 0, "configuração ambígua foi iniciada")

-- H. Debug JUnit e Attach sem regressões (entradas e fluxo intactos)
launched = {}
fake_dap.configurations.java = {}
debug_menu.debug()
assert(entry("test_nearest").enabled == true, "Debug Nearest JUnit Test regrediu")
assert(entry("test_class").enabled == true, "Debug JUnit Test Class regrediu")
assert(entry("attach").enabled == true, "Attach JVM regrediu")
menu_cb(entry("attach"))
assert(#launched == 1, "attach não foi lançado")
assert(launched[1].request == "attach", "attach veio como launch")
assert(launched[1].hostName == "127.0.0.1" and launched[1].port == 5005, "attach com alvo errado")
assert(vim.fs.basename(launched[1].mainClass or "") ~= "Main", "attach deveria ser request attach puro")

print("debug_project_spec: OK")
vim.cmd("qa!")
