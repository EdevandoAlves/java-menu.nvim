-- 6B.4A: compatibilidade com jc.nvim via adaptador java_menu/jc.
-- jc.nvim REAL para disponibilidade/contrato e descoberta de testes;
-- mocks para função interna ausente, retorno inesperado e erro em API.
--
-- Run:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "set rtp+=~/.local/share/nvim/lazy/jc.nvim" \
--     -c "luafile tests/java_menu/jc_compat_spec.lua" -c qa

local jca = require("java_menu.jc")
local fixtures = require("tests.java_menu.fixtures")

-- ---------- 1. jc presente e compatível (jc.nvim REAL) ----------

local parts, parts_err = jca.replace_import_api()
assert(parts, "jc real sem a API do Replace Import: " .. tostring(parts_err))
assert(type(parts.filter_type_symbols) == "function", "filter_type_symbols ausente")
assert(type(parts.prioritize_types) == "function", "prioritize_types ausente")
assert(type(parts.set_import) == "function", "set_import ausente")
assert(type(parts.remember_regular) == "function", "remember_regular ausente")

local style, style_err = jca.import_style()
assert(style, "jc real sem import_style: " .. tostring(style_err))
assert(type(style.order) == "table" and #style.order >= 1, "order do estilo vazia")
local current_style = style.load()
assert(current_style == nil or type(current_style) == "string", "load devolveu estilo inesperado")
local no_wildcards = style.no_wildcards()
assert(no_wildcards == true or no_wildcards == false, "no_wildcards deveria ser booleano")

local disco, disco_err = jca.test_discovery_api()
assert(disco, "jc real sem test_discovery_api: " .. tostring(disco_err))

local last_build, last_err = jca.read_build_last()
assert(last_err == nil, "read_build_last real falhou: " .. tostring(last_err))
assert(last_build == nil or type(last_build) == "string", "build-last real com tipo inesperado")

local busy = jca.jdtls_busy()
assert(busy == true or busy == false, "jdtls_busy deveria ser booleano")

-- ---------- 2. test discovery REAL (projeto temporário, sem jdtls) ----------

local root, _ = fixtures.maven_project("jc-compat", "com.compat", "Service")
fixtures.write(root .. "/src/main/java/com/compat/Service.java", {
  "package com.compat;",
  "",
  "public class Service {}",
})
fixtures.write(root .. "/src/test/java/com/compat/ServiceTest.java", {
  "package com.compat;",
  "",
  "public class ServiceTest {}",
})
fixtures.write(root .. "/src/test/java/com/compat/OtherScenarioTest.java", {
  "package com.compat;",
  "",
  "public class OtherScenarioTest {}",
})
local main_path = root .. "/src/main/java/com/compat/Service.java"
local test_path = root .. "/src/test/java/com/compat/ServiceTest.java"

local package_tests, tests_err = disco.package_tests(main_path)
assert(
  package_tests and #package_tests == 2,
  "package_tests real divergiu: " .. vim.inspect(tests_err or package_tests)
)
assert(disco.nothing_to_run(main_path) == true, "main sem teste pareado deveria ser nothing_to_run")
assert(disco.nothing_to_run(test_path) == false, "arquivo de teste deveria ser rodável")

-- ---------- 3. função interna ausente (mock) ----------

package.loaded["jc.jdtls"] = { organize_imports = function() end }
local _, missing = jca.replace_import_api()
assert(missing and missing:find("_filter_type_symbols", 1, true), "ausência não relatada: " .. tostring(missing))
package.loaded["jc.jdtls"] = {
  _filter_type_symbols = function()
    return {}
  end,
  _prioritize_types = function()
    return {}
  end,
  _remember_regular = function() end,
}
local _, missing_set = jca.replace_import_api()
assert(missing_set and missing_set:find("_set_import", 1, true), "ausência do _set_import não relatada")
package.loaded["jc.jdtls"] = nil

package.loaded["jc.jdtls"] = {
  _filter_type_symbols = function()
    return {}
  end,
  _prioritize_types = function()
    return {}
  end,
  _set_import = function() end,
}
local _, missing_remember = jca.replace_import_api()
assert(
  missing_remember and missing_remember:find("_remember_regular", 1, true),
  "ausência do _remember_regular não relatada"
)
package.loaded["jc.jdtls"] = nil

package.loaded["jc.test"] = {
  _nothing_to_run = function()
    return true
  end,
}
local _, disco_missing = jca.test_discovery_api()
assert(disco_missing and disco_missing:find("_package_tests", 1, true), "ausência no jc.test não relatada")
package.loaded["jc.test"] = nil

-- ---------- 4. retorno inesperado (mock) ----------

package.loaded["jc.jdtls"] = {
  _filter_type_symbols = function()
    return "oops"
  end,
  _prioritize_types = function()
    return {}
  end,
  _set_import = function() end,
  _remember_regular = function() end,
}
local bad_parts = jca.replace_import_api()
local bad_fqns, bad_err = bad_parts.filter_type_symbols({}, "List")
assert(
  bad_fqns == nil and bad_err:find("unexpected", 1, true),
  "contrato de retorno não validado: " .. tostring(bad_err)
)
package.loaded["jc.jdtls"] = nil

package.loaded["jc.jdtls"] = {
  _filter_type_symbols = function()
    return {}
  end,
  _prioritize_types = function()
    return "oops"
  end,
  _set_import = function()
    error("buffer changed")
  end,
  _remember_regular = function()
    error("settings readonly")
  end,
}
local guarded_parts = jca.replace_import_api()
local _, prioritize_err = guarded_parts.prioritize_types({}, 1)
assert(prioritize_err and prioritize_err:find("unexpected", 1, true), "contrato de _prioritize_types não validado")
local set_ok, set_err = guarded_parts.set_import(1, "List", "java.util.List")
assert(not set_ok and set_err:find("buffer changed", 1, true), "falha de _set_import não foi segura")
local remember_ok, remember_err = guarded_parts.remember_regular("List", "java.util.List")
assert(
  not remember_ok and remember_err:find("settings readonly", 1, true),
  "falha de _remember_regular não foi segura"
)
package.loaded["jc.jdtls"] = nil

package.loaded["jc.test"] = {
  _nothing_to_run = function()
    return true
  end,
  _package_tests = function()
    return 42
  end,
}
local _, pkg_err = jca.test_discovery_api().package_tests("/x")
assert(pkg_err and pkg_err:find("unexpected", 1, true), "contrato do _package_tests não validado")
package.loaded["jc.test"] = nil

package.loaded["jc.import_style"] = { order = { 42 } }
local _, order_err = jca.import_style()
assert(order_err and order_err:find("non-string", 1, true), "order não-string não validada")
package.loaded["jc.import_style"] = nil

package.loaded["jc.settings"] = {
  read_project = function()
    return 42
  end,
  write_project = function() end,
}
local _, settings_err = jca.read_build_last()
assert(settings_err and settings_err:find("unexpected", 1, true), "build-last não-string não validado")
package.loaded["jc.settings"] = nil

-- ---------- 5. erro em API interna (mock) ----------

package.loaded["jc.jdtls"] = {
  _filter_type_symbols = function()
    error("boom")
  end,
  _prioritize_types = function()
    return {}
  end,
  _set_import = function() end,
  _remember_regular = function() end,
}
local err_parts = jca.replace_import_api()
local _, boom = err_parts.filter_type_symbols({}, "List")
assert(
  boom and boom:find("boom", 1, true) and boom:find("failed", 1, true),
  "erro interno sem mensagem clara: " .. tostring(boom)
)
package.loaded["jc.jdtls"] = nil

package.loaded["jc.settings"] = {
  read_project = function()
    error("disk")
  end,
  write_project = function() end,
}
local _, disk_err = jca.read_build_last()
assert(
  disk_err and disk_err:find("disk", 1, true) and disk_err:find("failed", 1, true),
  "erro do jc.settings sem mensagem clara"
)
package.loaded["jc.settings"] = nil

-- write rejeita contrato inválido
local wok, werr = jca.write_build_last(42)
assert(not wok and werr:find("string", 1, true), "write_build_last aceitou não-string")

-- ---------- 6. roundtrip de build-last e save de estilo com mock ----------

local store = {}
package.loaded["jc.settings"] = {
  read_project = function(name)
    return store[name]
  end,
  write_project = function(name, value)
    store[name] = value
  end,
}
assert(jca.write_build_last("clean package"), "write_build_last falhou no mock")
assert(jca.read_build_last() == "clean package", "roundtrip do build-last divergiu")
package.loaded["jc.settings"] = nil

package.loaded["jc.import_style"] = {
  order = { "Eclipse" },
  load = function()
    return "Eclipse"
  end,
  save = function()
    error("readonly")
  end,
  no_wildcards = function()
    return false
  end,
}
local mock_style = jca.import_style()
local ok_save, save_err = pcall(mock_style.save, "Eclipse", true)
assert(not ok_save and tostring(save_err):find("readonly", 1, true), "erro do save não propagou com mensagem clara")
package.loaded["jc.import_style"] = nil

-- jdtls_busy ausente → false (comportamento preservado)
package.loaded["jc.lsp"] = {}
assert(jca.jdtls_busy() == false, "jdtls_busy ausente deveria devolver false")
package.loaded["jc.lsp"] = nil

-- ---------- 7. falhas adicionais de módulo, contrato e fallback (mock) ----------

local function with_mock(mod_name, value_or_loader, fn)
  local orig_loaded = package.loaded[mod_name]
  local orig_preload = package.preload[mod_name]
  if type(value_or_loader) == "function" then
    package.loaded[mod_name] = nil
    package.preload[mod_name] = value_or_loader
  else
    package.loaded[mod_name] = value_or_loader
    package.preload[mod_name] = nil
  end
  local ok, err = pcall(fn)
  package.loaded[mod_name] = orig_loaded
  package.preload[mod_name] = orig_preload
  if not ok then
    error(err, 0)
  end
end

-- módulos jc.* indisponíveis ou com tipo inválido
with_mock("jc.jdtls", function()
  error("module missing")
end, function()
  local api, err = jca.replace_import_api()
  assert(
    api == nil and err:find("unavailable", 1, true) and err:find("jc.jdtls", 1, true),
    "falha ao carregar jc.jdtls não relatada: " .. tostring(err)
  )
end)

with_mock("jc.jdtls", "not-a-table", function()
  local api, err = jca.replace_import_api()
  assert(api == nil and err:find("unavailable", 1, true), "jc.jdtls não-tabela não rejeitado: " .. tostring(err))
end)

with_mock("jc.jdtls", function()
  return false
end, function()
  local api, err = jca.replace_import_api()
  assert(api == nil and err:find("unavailable", 1, true), "jc.jdtls false não rejeitado: " .. tostring(err))
end)

with_mock("jc.settings", function()
  error("settings missing")
end, function()
  local val, rerr = jca.read_build_last()
  assert(
    val == nil and rerr:find("unavailable", 1, true) and rerr:find("jc.settings", 1, true),
    "falha ao carregar jc.settings em read não relatada: " .. tostring(rerr)
  )
  local ok, werr = jca.write_build_last("package")
  assert(not ok and werr:find("unavailable", 1, true), "falha ao carregar jc.settings em write não relatada")
end)

with_mock("jc.import_style", function()
  error("style missing")
end, function()
  local style_api, err = jca.import_style()
  assert(
    style_api == nil and err:find("unavailable", 1, true) and err:find("jc.import_style", 1, true),
    "falha ao carregar jc.import_style não relatada: " .. tostring(err)
  )
end)

with_mock("jc.test", function()
  error("test missing")
end, function()
  local api, err = jca.test_discovery_api()
  assert(
    api == nil and err:find("unavailable", 1, true) and err:find("jc.test", 1, true),
    "falha ao carregar jc.test não relatada: " .. tostring(err)
  )
end)

with_mock("jc.lsp", function()
  error("lsp missing")
end, function()
  assert(jca.jdtls_busy() == false, "jdtls_busy deveria retornar false se jc.lsp falhar ao carregar")
end)

-- funções ausentes nos módulos restantes
with_mock("jc.jdtls", {
  _filter_type_symbols = function()
    return {}
  end,
  _set_import = function() end,
  _remember_regular = function() end,
}, function()
  local api, err = jca.replace_import_api()
  assert(
    api == nil and err:find("_prioritize_types", 1, true),
    "ausência de _prioritize_types não relatada: " .. tostring(err)
  )
end)

with_mock("jc.test", {
  _package_tests = function()
    return {}
  end,
}, function()
  local api, err = jca.test_discovery_api()
  assert(
    api == nil and err:find("_nothing_to_run", 1, true),
    "ausência de _nothing_to_run não relatada: " .. tostring(err)
  )
end)

with_mock("jc.settings", {}, function()
  local _, rerr = jca.read_build_last()
  assert(rerr and rerr:find("read_project", 1, true), "ausência de read_project não relatada")
  local ok, werr = jca.write_build_last("test")
  assert(not ok and werr:find("write_project", 1, true), "ausência de write_project não relatada")
end)

with_mock("jc.import_style", {
  order = {},
  load = function() end,
  save = function() end,
  no_wildcards = function()
    return false
  end,
}, function()
  local style_api, err = jca.import_style()
  assert(style_api == nil and err:find("order", 1, true), "order vazia não rejeitada: " .. tostring(err))
end)

with_mock("jc.import_style", { order = { "Eclipse" } }, function()
  local style_api, err = jca.import_style()
  assert(
    style_api == nil and err:find("load/save/no_wildcards", 1, true),
    "funções ausentes em jc.import_style não relatadas: " .. tostring(err)
  )
end)

-- erros e retornos inesperados adicionais nas chamadas
with_mock("jc.settings", {
  read_project = function()
    return nil
  end,
  write_project = function()
    error("disk full")
  end,
}, function()
  local ok, err = jca.write_build_last("test")
  assert(
    not ok and err:find("disk full", 1, true) and err:find("failed", 1, true),
    "erro de write_project não propagado claramente: " .. tostring(err)
  )
end)

with_mock("jc.test", {
  _nothing_to_run = function()
    error("bad path")
  end,
  _package_tests = function()
    error("scan error")
  end,
}, function()
  local api = jca.test_discovery_api()
  local nothing, nerr = api.nothing_to_run("/x")
  assert(
    nothing == false and nerr and nerr:find("bad path", 1, true) and nerr:find("failed", 1, true),
    "erro de _nothing_to_run não capturado: " .. tostring(nerr)
  )
  local files, perr = api.package_tests("/x")
  assert(
    files == nil and perr and perr:find("scan error", 1, true) and perr:find("failed", 1, true),
    "erro de _package_tests não capturado: " .. tostring(perr)
  )
end)

with_mock("jc.test", {
  _nothing_to_run = function()
    return false
  end,
  _package_tests = function()
    return nil
  end,
}, function()
  local files, perr = jca.test_discovery_api().package_tests("/x")
  assert(type(files) == "table" and #files == 0 and perr == nil, "nil em _package_tests deveria normalizar para {}")
end)

with_mock("jc.import_style", {
  order = { "Eclipse" },
  load = function()
    error("corrupt")
  end,
  save = function() end,
  no_wildcards = function()
    error("io")
  end,
}, function()
  local style_api = jca.import_style()
  local ok_load, err_load = pcall(style_api.load)
  assert(not ok_load and tostring(err_load):find("corrupt", 1, true), "erro de style.load não propagou")
  local ok_nw, err_nw = pcall(style_api.no_wildcards)
  assert(not ok_nw and tostring(err_nw):find("io", 1, true), "erro de style.no_wildcards não propagou")
end)

with_mock("jc.import_style", {
  order = { "Eclipse" },
  load = function()
    return 123
  end,
  save = function() end,
  no_wildcards = function()
    return false
  end,
}, function()
  local style_api = jca.import_style()
  local ok_load, err_load = pcall(style_api.load)
  assert(not ok_load and tostring(err_load):find("unexpected style", 1, true), "load() não-string não rejeitado")
end)

with_mock("jc.lsp", {
  jdtls_busy = function()
    error("lsp down")
  end,
}, function()
  assert(jca.jdtls_busy() == false, "erro em jc.lsp.jdtls_busy deveria retornar false")
end)

with_mock("jc.lsp", {
  jdtls_busy = function()
    return "yes"
  end,
}, function()
  assert(jca.jdtls_busy() == false, "retorno não-booleano em jdtls_busy deveria retornar false")
end)

-- fallback determinístico quando jc.templates falha
local create = require("java_menu.create")
with_mock("jc.templates", function()
  error("templates missing")
end, function()
  local body = create._main_body("com.compat", "Demo")
  assert(body:find("package com.compat;", 1, true), "fallback sem package")
  assert(body:find("static void main", 1, true), "fallback sem main")
  assert(body:find("Hello from Demo!", 1, true), "fallback sem saudação")
end)

with_mock("jc.templates", {
  get = function()
    return {}
  end,
  render = function()
    error("render boom")
  end,
}, function()
  local body = create._main_body("com.compat", "Demo")
  assert(body:find("Hello from Demo!", 1, true), "fallback após erro em render falhou")
end)

vim.fn.delete(root, "rf")

print("jc_compat_spec: OK")
vim.cmd("qa!")
