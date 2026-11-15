-- java_menu/jc.lua
-- Adaptador fino para as superfícies do jc.nvim usadas pelo Java Menu.
--
-- O jc.nvim é dependência obrigatória; APIs públicas estáveis (jc.jdtls
-- generate_*/organize_*, jc.refactor.extract_*, jc.test.run_*, jc
-- .neotest_adapter...) continuam sendo chamadas direto nos módulos. Aqui
-- ficam apenas: (1) as funções internas (underscore) efetivamente usadas,
-- com verificação de disponibilidade e contrato validado; (2) jc.settings e
-- jc.import_style com contrato checado; (3) mensagens claras quando o jc
-- instalado diverge do esperado. Nenhum monkey patch; o jc.nvim não é
-- modificado nem copiado.

local M = {}

---Carrega um módulo do jc com erro claro.
---@param name string
---@return table|nil mod, string|nil err
local function jc_module(name)
  local ok, mod = pcall(require, name)
  if not ok or type(mod) ~= "table" then
    return nil, ('jc.nvim indisponível ou incompatível: módulo "%s" não carregou (%s)'):format(name, tostring(mod))
  end
  return mod
end

local function mod_fn(mod, name)
  return type(mod) == "table" and type(mod[name]) == "function" and mod[name] or nil
end

-- ---------- Replace Import (internas do jc.jdtls) ----------

---API validada do Replace Import. Encapsula as quatro internas do jc.jdtls
---usadas pelo menu (`_filter_type_symbols`, `_prioritize_types`,
---`_set_import`, `_remember_regular`). Devolve nil + motivo quando o jc
---instalado não as expõe (versão incompatível) — o menu cai no fluxo nativo
---do jc (JCimportsReplace), com o guard de cliente global da 6B.1.
---@return table|nil api, string|nil err
function M.replace_import_api()
  local mod, err = jc_module("jc.jdtls")
  if not mod then
    return nil, err
  end
  local parts = {}
  for _, name in ipairs({ "_filter_type_symbols", "_prioritize_types", "_set_import", "_remember_regular" }) do
    local f = mod_fn(mod, name)
    if not f then
      return nil, ("jc.nvim sem jc.jdtls.%s (API interna mudou nesta versão)"):format(name)
    end
    parts[name] = f
  end

  return {
    ---workspace/symbol → lista de FQNs importáveis.
    ---@return string[]|nil fqns, string|nil err
    filter_type_symbols = function(result, name)
      local ok, fqns = pcall(parts._filter_type_symbols, result, name, true)
      if not ok then
        return nil, ("jc._filter_type_symbols falhou: %s"):format(tostring(fqns))
      end
      if type(fqns) ~= "table" then
        return nil, "jc._filter_type_symbols devolveu tipo inesperado (esperava lista de FQNs)"
      end
      return fqns
    end,
    ---Reordena os FQNs segundo as preferências do jc.
    ---@return string[]|nil fqns, string|nil err
    prioritize_types = function(fqns, bufnr)
      local ok, ordered = pcall(parts._prioritize_types, fqns, bufnr)
      if not ok then
        return nil, ("jc._prioritize_types falhou: %s"):format(tostring(ordered))
      end
      if type(ordered) ~= "table" then
        return nil, "jc._prioritize_types devolveu tipo inesperado (esperava lista)"
      end
      return ordered
    end,
    ---Insere o import no buffer (sem gravar).
    ---@return boolean ok, string|nil err
    set_import = function(bufnr, name, fqn)
      local ok, e = pcall(parts._set_import, bufnr, name, fqn)
      if not ok then
        return false, ("jc._set_import falhou: %s"):format(tostring(e))
      end
      return true
    end,
    ---Guarda a escolha como preferência regular do jc.
    ---@return boolean ok, string|nil err
    remember_regular = function(name, fqn)
      local ok, e = pcall(parts._remember_regular, name, fqn)
      if not ok then
        return false, ("jc._remember_regular falhou: %s"):format(tostring(e))
      end
      return true
    end,
  }
end

-- build-last é o mesmo estado do JCbuildLast do jc; a chave do projeto é
-- resolvida pelo cwd (detalhe de implementação do jc.settings).
---Args do último build persistidos pelo jc (string ou nil).
---@return string|nil value, string|nil err
function M.read_build_last()
  local mod, err = jc_module("jc.settings")
  if not mod then
    return nil, err
  end
  local read = mod_fn(mod, "read_project")
  if not read then
    return nil, "jc.nvim sem jc.settings.read_project"
  end
  local ok, value = pcall(read, "build-last")
  if not ok then
    return nil, ("jc.settings.read_project falhou: %s"):format(tostring(value))
  end
  if value ~= nil and type(value) ~= "string" then
    return nil, "jc.settings devolveu build-last inesperado (esperava string)"
  end
  return value
end

---Grava o build-last do projeto (string). Nunca lança.
---@param args string
---@return boolean ok, string|nil err
function M.write_build_last(args)
  if type(args) ~= "string" then
    return false, "build-last deveria ser string, veio " .. type(args)
  end
  local mod, err = jc_module("jc.settings")
  if not mod then
    return false, err
  end
  local write = mod_fn(mod, "write_project")
  if not write then
    return false, "jc.nvim sem jc.settings.write_project"
  end
  local ok, e = pcall(write, "build-last", args)
  if not ok then
    return false, ("jc.settings.write_project falhou: %s"):format(tostring(e))
  end
  return true
end

---Estilo de imports do jc (order/load/save/no_wildcards) com contrato checado.
---@return table|nil style, string|nil err
function M.import_style()
  local mod, err = jc_module("jc.import_style")
  if not mod then
    return nil, err
  end
  local order = mod.order
  if type(order) ~= "table" or #order == 0 then
    return nil, "jc.import_style.order inesperado (esperava lista de presets)"
  end
  for _, name in ipairs(order) do
    if type(name) ~= "string" then
      return nil, "jc.import_style.order com nomes não-string"
    end
  end
  local load_fn, save_fn, nw_fn = mod_fn(mod, "load"), mod_fn(mod, "save"), mod_fn(mod, "no_wildcards")
  if not (load_fn and save_fn and nw_fn) then
    return nil, "jc.nvim sem jc.import_style.load/save/no_wildcards"
  end
  return {
    order = order,
    load = function()
      local ok, current = pcall(load_fn)
      if not ok then
        error("jc.import_style.load falhou: " .. tostring(current), 0)
      end
      if current ~= nil and type(current) ~= "string" then
        error("jc.import_style.load devolveu estilo inesperado", 0)
      end
      return current
    end,
    save = function(name, no_wildcards)
      local ok, e = pcall(save_fn, name, no_wildcards)
      if not ok then
        error("jc.import_style.save falhou: " .. tostring(e), 0)
      end
    end,
    no_wildcards = function()
      local ok, v = pcall(nw_fn)
      if not ok then
        error("jc.import_style.no_wildcards falhou: " .. tostring(v), 0)
      end
      return v == true
    end,
  }
end

---Internas de descoberta do jc.test usadas pelo Run Nearest (testes do
---package quando não há teste pareado). nil + motivo se a versão do jc
---não as expõe — o menu segue para jc.test.run_at_cursor.
---@return table|nil api, string|nil err
function M.test_discovery_api()
  local mod, err = jc_module("jc.test")
  if not mod then
    return nil, err
  end
  local ntr, pt = mod_fn(mod, "_nothing_to_run"), mod_fn(mod, "_package_tests")
  if not (ntr and pt) then
    return nil, "jc.nvim sem jc.test._nothing_to_run/_package_tests (API interna mudou nesta versão)"
  end
  return {
    ---true quando o arquivo não tem teste rodável (pareado/package).
    ---@return boolean nothing, string|nil err
    nothing_to_run = function(path)
      local ok, v = pcall(ntr, path)
      if not ok then
        return false, ("jc._nothing_to_run falhou: %s"):format(tostring(v))
      end
      return v == true
    end,
    ---Classes de teste do package de `path` (mesmo módulo).
    ---@return string[]|nil files, string|nil err
    package_tests = function(path)
      local ok, files = pcall(pt, path)
      if not ok then
        return nil, ("jc._package_tests falhou: %s"):format(tostring(files))
      end
      if files == nil then
        return {}, nil
      end
      if type(files) ~= "table" then
        return nil, "jc._package_tests devolveu tipo inesperado (esperava lista de arquivos)"
      end
      return files
    end,
  }
end

---jc está no meio de uma operação longa (habilita Abstract Methods).
---Ausência/erro do jc.lsp conta como "não ocupado" (comportamento preservado).
---@return boolean
function M.jdtls_busy()
  local mod = jc_module("jc.lsp")
  local busy = mod and mod_fn(mod, "jdtls_busy")
  if not busy then
    return false
  end
  local ok, v = pcall(busy)
  return ok and v == true
end

return M
