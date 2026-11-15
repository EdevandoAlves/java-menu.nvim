-- java_menu/project.lua
-- Detecção de projeto Java por arquivos de build (Maven/Gradle).
-- .git NÃO é considerado marcador de projeto Java.

local M = {}

M.markers = {
  "pom.xml",
  "build.gradle",
  "build.gradle.kts",
  "settings.gradle",
  "settings.gradle.kts",
}

-- arquivos que caracterizam um módulo (o settings.* só existe na raiz)
M.build_files = { "pom.xml", "build.gradle", "build.gradle.kts" }

---Forward declaration: definida na seção de módulos (M3) abaixo.
local topmost_aggregator

local function isfile(path)
  return vim.fn.filereadable(path) == 1
end

local function isdir(path)
  return vim.fn.isdirectory(path) == 1
end

local function has_any(dir, list)
  for _, file in ipairs(list) do
    if isfile(dir .. "/" .. file) then
      return true
    end
  end
  return false
end

---Caminho de referência do buffer (arquivo, diretório do netrw ou cwd).
---@param buf number|nil
---@return string
function M.start_path(buf)
  buf = buf and buf > 0 and buf or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return vim.fs.normalize(vim.uv.cwd())
  end
  return vim.fs.normalize(name)
end

---`parent` declara `child` como módulo (Maven <module> / Gradle include)?
---@param parent string
---@param child string
---@return boolean
local function declares_module(parent, child)
  local pom = parent .. "/pom.xml"
  if isfile(pom) then
    -- lê o arquivo inteiro: vários <module> podem estar na mesma linha
    local text = table.concat(vim.fn.readfile(pom), "\n")
    for mod in text:gmatch("<module%s*>%s*([^<%s]+)%s*</module>") do
      mod = mod:gsub("/+$", "")
      if vim.fs.basename(mod) == child then
        return true
      end
    end
    return false
  end

  -- Gradle: leitura tolerante de settings.gradle(.kts)
  for _, file in ipairs({ "settings.gradle", "settings.gradle.kts" }) do
    local settings = parent .. "/" .. file
    if isfile(settings) then
      local text = table.concat(vim.fn.readfile(settings), "\n")
      if
        text:find('"' .. child .. '"', 1, true)
        or text:find("'" .. child .. "'", 1, true)
        or text:find(":" .. child, 1, true)
      then
        return true
      end
    end
  end
  return false
end

---Sobe até o diretório que contém um arquivo de build.
---Em projeto multimódulo sobe até o agregador (o pai que declara o módulo).
---@param buf number|nil
---@return string|nil
function M.root(buf)
  local start = M.start_path(buf)
  local dir = isdir(start) and start or vim.fs.dirname(start)
  local found

  while dir and dir ~= "" do
    if has_any(dir, M.markers) then
      found = dir
      local parent = vim.fs.dirname(dir)
      if not parent or parent == dir then
        return found
      end
      if has_any(parent, M.markers) and declares_module(parent, vim.fs.basename(dir)) then
        dir = parent -- agrega; o source root preferido é resolvido depois
      else
        -- M3: um agregador mais acima pode declarar este módulo com caminho
        -- aninhado (<module>libraries/core</module> / :libraries:core)
        local ancestor = topmost_aggregator(dir)
        return ancestor or found
      end
    else
      local parent = vim.fs.dirname(dir)
      if not parent or parent == dir then
        return nil
      end
      dir = parent
    end
  end
  return found
end

---@param buf number|nil
---@return boolean
function M.is_java_project(buf)
  return M.root(buf) ~= nil
end

-- ---------- módulos (M3: agregadores com módulos aninhados) ----------

---Caminho canônico (realpath + normalizado) ou nil quando não existe.
local function canonical(path)
  local real = vim.uv.fs_realpath(path)
  return real and vim.fs.normalize(real) or nil
end

---`path` está dentro da subárvore de `parent` (ambos canônicos)?
local function subtree(parent, path)
  return parent == path or path:sub(1, #parent + 1) == parent .. "/"
end

---Declarações `<module>` das seções `<modules>` de um POM (agregação Maven).
---Herança (`<parent>`) não é agregação e não é considerada aqui.
---Os caminhos devolvidos são relativos ao diretório do POM que declara.
---@param pom string
---@return string[]
local function pom_module_decls(pom)
  local text = table.concat(vim.fn.readfile(pom), "\n")
  local decls = {}
  for block in text:gmatch("<modules>(.-)</modules>") do
    for mod in block:gmatch("<module%s*>([^<]+)</module>") do
      mod = vim.trim(mod):gsub("/+$", "")
      if mod ~= "" then
        decls[#decls + 1] = mod
      end
    end
  end
  return decls
end

---Módulos Maven declarados recursivamente a partir do agregador `root`.
---Cada caminho é resolvido relativo ao POM que o declara, depois canonizado;
---módulos fora da subárvore do agregador, symlinks para fora, ciclos,
---duplicados e pastas com pom.xml não declaradas ficam de fora.
---@param root string raiz canônica do agregador
---@param seen table<string, boolean> canônicos já visitados
---@param depth integer
---@return string[]
local function maven_modules(root, seen, depth)
  depth = depth or 0
  if depth >= 16 then
    return {}
  end
  local out = {}
  for _, decl in ipairs(pom_module_decls(root .. "/pom.xml")) do
    local candidate = decl:sub(1, 1) == "/" and decl or (root .. "/" .. decl)
    local dir = canonical(candidate)
    if dir and dir ~= root and subtree(root, dir) and not seen[dir] then
      seen[dir] = true
      if isfile(dir .. "/pom.xml") then
        out[#out + 1] = dir
        vim.list_extend(out, maven_modules(dir, seen, depth + 1))
      end
    end
  end
  return out
end

---Strings literais ('...' ou "...") de um trecho de script Gradle.
local function quoted_strings(text)
  local out = {}
  for _, val in text:gmatch("(['\"])([^'\"]*)(['\"])") do
    out[#out + 1] = val
  end
  return out
end

---Normaliza um caminho lógico Gradle (`:services:api`, `services:api`)
---para `services/api`. Devolve nil quando não é uma declaração simples
---(interpolação `$`, caracteres inesperados).
---@param logical string
---@return string|nil rel, string|nil reason
local function normalize_gradle_logical(logical)
  if logical:find("$", 1, true) then
    return nil, "interpolação não avaliada: " .. logical
  end
  local rel = vim.trim(logical):gsub("^:+", ""):gsub(":+$", "")
  if rel == "" then
    return nil
  end
  if not rel:match("^[%w%-%_%.%:/]+$") then
    return nil, "declaração não simples: " .. logical
  end
  return (rel:gsub(":", "/"))
end

---Módulos Gradle declarados estaticamente em settings.gradle(.kts).
---O script NÃO é avaliado: só includes e projectDir com literais.
---Com declaração dinâmica, devolve o que dá para interpretar e uma nota
---de descoberta parcial (integração futura: ferramentas oficiais do Gradle).
---@param root string raiz canônica
---@return string[] dirs, string|nil note, table<string,string> logical_by_dir
local function gradle_modules(root)
  local settings = root .. "/settings.gradle"
  local kts = root .. "/settings.gradle.kts"
  local path = isfile(settings) and settings or (isfile(kts) and kts or nil)
  if not path then
    return {}, nil, {}
  end

  local text = table.concat(vim.fn.readfile(path), "\n"):gsub("/%*.-%*/", " ")
  local order, seen_rel = {}, {}
  local explicit_dirs = {}
  local notes = {}

  local function add_logical(raw)
    local rel, reason = normalize_gradle_logical(raw)
    if reason then
      notes[#notes + 1] = reason
    end
    if rel and not seen_rel[rel] then
      seen_rel[rel] = true
      order[#order + 1] = rel
    end
    return rel
  end

  for line in text:gmatch("[^\r\n]+") do
    local code = vim.trim((line:match("^(.-)//") or line))
    local args_part = code:match("^include%s*%((.*)%)%s*$") or code:match("^include%s+(.+)$")
    if args_part then
      -- texto fora das strings literais indica concatenação/variável: o
      -- literal sozinho não é uma declaração completa, então não inventa módulo
      local leftover = args_part:gsub("['\"][^'\"]*['\"]", " ")
      if leftover:find("[%w_%$]") then
        notes[#notes + 1] = "include dinâmico não interpretado"
      else
        for _, val in ipairs(quoted_strings(args_part)) do
          add_logical(val)
        end
      end
    end

    -- projectDir estático: project(":nome").projectDir = file("dir/relativo")
    local logical, dir_val =
      code:match("project%s*%(%s*['\"]([^'\"]+)['\"]%s*%)%s*%.projectDir%s*=%s*file%s*%(%s*['\"]([^'\"]+)['\"]%s*%)")
    if logical and dir_val then
      if dir_val:find("$", 1, true) then
        -- sem o dir físico não há mapeamento seguro: não inventa módulo
        notes[#notes + 1] = "projectDir com interpolação não avaliada: " .. dir_val
      else
        local rel = add_logical(logical)
        if rel then
          explicit_dirs[rel] = dir_val:sub(1, 1) == "/" and dir_val or (root .. "/" .. dir_val)
        end
      end
    end
  end

  local dirs, seen_dir, logical_by_dir = {}, {}, {}
  for _, rel in ipairs(order) do
    local candidate = explicit_dirs[rel] or (root .. "/" .. rel)
    local dir = canonical(candidate)
    if dir and isdir(dir) and subtree(root, dir) and not seen_dir[dir] then
      seen_dir[dir] = true
      dirs[#dirs + 1] = dir
      logical_by_dir[dir] = ":" .. (rel:gsub("/", ":"))
    elseif dir and not subtree(root, dir) then
      notes[#notes + 1] = "projectDir/include fora do agregador: " .. rel
    end
  end
  table.sort(dirs)

  local note
  if #notes > 0 then
    note = ("descoberta parcial de módulos Gradle (%s) — integração futura com ferramentas oficiais do Gradle"):format(
      table.concat(notes, "; ")
    )
  end
  return dirs, note, logical_by_dir
end

---Agregador mais acima cujo reactor declara `dir` como módulo (direta ou
---transitivamente). Necessário para caminhos aninhados declarados com o
---caminho completo a partir do topo (<module>libraries/core</module>).
---@param dir string
---@return string|nil
function topmost_aggregator(dir)
  local target = canonical(dir)
  if not target then
    return nil
  end
  local top, depth = nil, 0
  local cur = vim.fs.dirname(target)
  while cur and #cur > 3 and depth < 16 do
    depth = depth + 1
    local declared
    if isfile(cur .. "/pom.xml") then
      declared = maven_modules(cur, {})
    elseif isfile(cur .. "/settings.gradle") or isfile(cur .. "/settings.gradle.kts") then
      declared = gradle_modules(cur)
    end
    if declared then
      for _, mod in ipairs(declared) do
        if mod == target then
          top = cur
          break
        end
      end
    end
    cur = vim.fs.dirname(cur)
  end
  return top
end

---Módulos do projeto: a raiz mais os módulos declarados no build
---(Maven: <modules> dos agregadores, recursivo; Gradle: includes estáticos
---do settings.gradle(.kts)). Sem declarações: só a raiz (single-module).
---Pastas com pom.xml não declaradas não são módulos do reactor.
---@param root string
---@return string[]
local function modules(root)
  root = canonical(root) or root
  local list = { root }
  if isfile(root .. "/pom.xml") then
    vim.list_extend(list, maven_modules(root, { [root] = true }, 0))
  else
    local declared = gradle_modules(root)
    vim.list_extend(list, declared)
  end
  return list
end

---Módulos do projeto (raiz + submódulos declarados, recursivo).
---@param root string
---@return string[]
function M.modules(root)
  return modules(root)
end

---Limitação da descoberta de módulos (nil quando a descoberta é completa).
---Hoje só ocorre com Gradle dinâmico (o script não é avaliado).
---@param root string
---@return string|nil note
function M.discovery_limitation(root)
  root = canonical(root) or root
  if isfile(root .. "/pom.xml") then
    return nil
  end
  local _, note = gradle_modules(root)
  return note
end

---Caminho lógico Gradle do módulo (`:services:api`), para tarefas
---(`:services:api:build`). Com projectDir estático, o lógico vem do settings
---(`:custom` mesmo com dir físico `libs/custom-dir`). Fallback: relativo.
---@param root string
---@param dir string
---@return string
function M.gradle_path(root, dir)
  root = canonical(root) or root
  dir = canonical(dir) or dir
  local _, _, logical_by_dir = gradle_modules(root)
  if logical_by_dir[dir] then
    return logical_by_dir[dir]
  end
  local rel = vim.fs.relpath(root, dir)
  if rel and rel ~= "." and not rel:match("^%.%.") then
    return ":" .. (rel:gsub("/", ":"))
  end
  return ":" .. vim.fs.basename(dir)
end

---Source roots existentes (src/main/java, src/test/java) de cada módulo.
---@param root string
---@return table[] { path, module, set, label }
function M.source_roots(root)
  local out = {}
  for _, mod in ipairs(modules(root)) do
    for _, set in ipairs({ "main", "test" }) do
      local path = mod .. "/src/" .. set .. "/java"
      if isdir(path) then
        local name = vim.fs.basename(mod)
        out[#out + 1] = {
          path = path,
          module = name,
          set = set,
          -- rótulo curto; a raiz do projeto não repete o nome do módulo
          label = (mod == root and "" or (name .. " · ")) .. "src/" .. set .. "/java",
        }
      end
    end
  end
  return out
end

---Source root que contém o buffer, com preferência para src/main/java.
---@param roots table[]
---@param buf number|nil
---@return table|nil
function M.preferred(roots, buf)
  local name = M.start_path(buf)
  for _, r in ipairs(roots) do
    if r.set == "main" and name:sub(1, #r.path + 1) == r.path .. "/" then
      return r
    end
  end
  for _, r in ipairs(roots) do
    if r.set == "main" then
      return r
    end
  end
  return roots[1]
end

---Packages já existentes sob um source root (para sugestão).
---@param source_root string
---@param limit integer|nil
---@return string[]
function M.packages(source_root, limit)
  local seen, out = {}, {}
  local files = vim.fs.find(function(name)
    return name:sub(-5) == ".java"
  end, { path = source_root, type = "file", limit = 500 })

  for _, file in ipairs(files) do
    local rel = vim.fs.relpath(source_root, vim.fs.dirname(file))
    if rel and rel ~= "" and rel ~= "." and not rel:match("^%.%.") then
      local pkg = rel:gsub("/", ".")
      if not seen[pkg] then
        seen[pkg] = true
        out[#out + 1] = pkg
      end
    end
  end

  table.sort(out)
  if limit and #out > limit then
    return vim.list_slice(out, 1, limit)
  end
  return out
end

---Package sugerido para um buffer dentro de um source root.
---Também funciona para diretórios (netrw).
---@param buf number|nil
---@param source_root string
---@return string
function M.package_for(buf, source_root)
  buf = buf and buf > 0 and buf or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return ""
  end

  if not isdir(name) and vim.bo[buf].filetype == "java" then
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, 30, false)) do
      local pkg = line:match("^%s*package%s+([%w_%.]+)%s*;")
      if pkg then
        return pkg
      end
    end
  end

  local dir = isdir(name) and name or vim.fs.dirname(name)
  local rel = vim.fs.relpath(source_root, dir)
  if rel and rel ~= "" and rel ~= "." and not rel:match("^%.%.") then
    return (rel:gsub("/", "."))
  end
  return ""
end

-- ---------- workspace JDTLS exclusivo por projeto ----------

---Identificador estável do workspace JDTLS derivado do caminho canônico
---completo da raiz. O escape é injetivo (`%` → `%%`, `/` → `%`), então
---projetos diferentes nunca colidem — nem com mesmo basename — e o mesmo
---projeto sempre gera o mesmo identificador (determinístico entre processos,
---sem hash). Ex.: `/tmp/a/proj` → `%tmp%a%proj`.
---Ao mudar de basename para identificador completo, o JDTLS cria um workspace
---novo na primeira vez; o diretório antigo (`<data>/jdtls/<basename>`) não é
---apagado nem migrado automaticamente.
---@param root string
---@return string
function M.workspace_id(root)
  local real = vim.uv.fs_realpath(root) or root
  local canonical = vim.fs.normalize(real)
  return (canonical:gsub("%%", "%%%%"):gsub("/", "%%"))
end

---Diretório `-data` exclusivo do projeto (o JDTLS cria se não existir).
---@param root string
---@return string
function M.workspace_dir(root)
  return vim.fs.joinpath(vim.fn.stdpath("data"), "jdtls", M.workspace_id(root))
end

---Diretório `-data` usado pelo cliente JDTLS ativo, lido do cmd do cliente.
---@param client vim.lsp.Client|nil
---@return string|nil
function M.client_workspace_dir(client)
  local cmd = client and client.config and client.config.cmd
  if type(cmd) ~= "table" then
    return nil
  end
  for i, arg in ipairs(cmd) do
    if arg == "-data" and cmd[i + 1] then
      return cmd[i + 1]
    end
  end
  return nil
end

return M
