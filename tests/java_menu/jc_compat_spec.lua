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

print("jc_compat_spec: OK")
vim.cmd("qa!")
