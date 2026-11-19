-- 7B.2 (INTEGRATION): projeto Spring Boot real baixado do Spring Initializr.
-- Exercita a metadata, o download, a validação do zip, a extração em staging e
-- a compilação real (mvn test-compile). Sem curl/wget/unzip, ou com a rede
-- indisponível, o spec PULA com mensagem clara e sai 0 — ambiente offline não
-- é uma falha. Apaga somente os diretórios que ele próprio criou.
--
-- Run:
--   tests/java_menu/run.sh integration

local create = require("java_menu.create")

local dirs = {}
local function new_parent(label)
  local dir = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-spring-real-" .. label)
  vim.fn.mkdir(dir, "p")
  dirs[#dirs + 1] = dir
  return dir
end

local function cleanup()
  for _, dir in ipairs(dirs) do
    vim.fn.delete(dir, "rf")
  end
end

local function skip(reason)
  cleanup()
  print("spring_project_real_spec: SKIP (" .. tostring(reason) .. ")")
  vim.cmd("qa!")
end

local tools = create._spring_tools()
if not tools.ok then
  return skip(tools.reason)
end

-- ---------- 1. metadata real ----------

local meta, meta_err, meta_done = nil, nil, false
create._fetch_spring_metadata(function(fetched, err)
  meta, meta_err, meta_done = fetched, err, true
end)
vim.wait(30000, function()
  return meta_done
end, 50)

if not meta then
  return skip("Spring Initializr indisponível: " .. tostring(meta_err))
end

assert(#meta.types > 0, "metadata real sem project types")
assert(#meta.java_versions > 0 and #meta.packagings > 0, "metadata real incompleta")
assert(#meta.dependencies > 0, "metadata real sem dependências")
for _, value in ipairs(meta.types) do
  assert(
    value.id:match("%-project$") ~= nil or value.id:match("%-project%-kotlin$") ~= nil,
    "project type não filtrado: " .. value.id
  )
end

local function has_id(values, id)
  for _, value in ipairs(values) do
    if value.id == id then
      return true
    end
  end
  return false
end

-- Maven favorecido (o spec compila com mvn); Java 21 quando o serviço oferece
local build_type = has_id(meta.types, "maven-project") and "maven-project" or meta.types[1].id
local java_release = has_id(meta.java_versions, "21") and "21" or meta.java_default

local parent = new_parent("initializr")
local opts = {
  kind = "spring",
  parent = parent,
  name = "realapp",
  pkg = "com.real.app",
  release = java_release,
  group = "com.real",
  artifact = "realapp",
  build_type = build_type,
  boot_version = meta.boot_default,
  packaging = "jar",
  dependencies = {},
}

local reason = create._validate(opts)
assert(reason == nil, "opções reais rejeitadas: " .. tostring(reason))

local url = create._spring_url(opts)
assert(url:match("^https://start%.spring%.io/starter%.zip%?") ~= nil, "URL base inesperada: " .. url)
assert(url:find("type=" .. build_type, 1, true) ~= nil, "type ausente na URL: " .. url)
assert(url:find("javaVersion=" .. java_release, 1, true) ~= nil, "javaVersion ausente na URL: " .. url)
assert(url:find("dependencies=", 1, true) == nil, "URL sem dependências não deveria ter o parâmetro")

-- ---------- 2. download real ----------

local zip_path = vim.fn.tempname() .. ".zip"
local dl_ok, dl_err, dl_done = nil, nil, false
create._download_spring_zip(opts, zip_path, function(ok, err)
  dl_ok, dl_err, dl_done = ok, err, true
end)
vim.wait(60000, function()
  return dl_done
end, 100)

if not dl_ok then
  return skip("download do starter.zip falhou: " .. tostring(dl_err))
end

local zip_stat = vim.uv.fs_stat(zip_path)
assert(zip_stat ~= nil and zip_stat.size > 1000, "starter.zip vazio ou minúsculo: " .. vim.inspect(zip_stat))

-- ---------- 3. listagem validada + extração em staging ----------

local inspected, names = create._inspect_zip(zip_path)
assert(inspected == true, "zip real rejeitado pela validação: " .. tostring(names))
assert(type(names) == "table" and #names > 0, "listagem real vazia")

local ok, err = create._extract_spring_zip(zip_path, opts)
vim.fn.delete(zip_path)
assert(ok, "extração do projeto real falhou: " .. tostring(err))

local target = parent .. "/realapp"
assert(vim.fn.filereadable(target .. "/pom.xml") == 1, "pom.xml ausente no projeto real")
assert(vim.fn.filereadable(target .. "/mvnw") == 1, "mvnw ausente no projeto real")
assert(not vim.uv.fs_lstat(parent .. "/.realapp.java-menu-stage"), "staging sobrou após publicar")

local apps = vim.fn.glob(target .. "/src/main/java/**/*Application.java", false, true)
assert(type(apps) == "table" and #apps == 1, "classe *Application.java ausente: " .. vim.inspect(apps))

local pom = table.concat(vim.fn.readfile(target .. "/pom.xml"), "\n")
assert(pom:find("spring-boot-starter-parent", 1, true) ~= nil, "pom real sem spring-boot-starter-parent")
assert(pom:find("<artifactId>realapp</artifactId>", 1, true) ~= nil, "artifactId divergiu no pom real")
assert(pom:find("<groupId>com.real</groupId>", 1, true) ~= nil, "groupId divergiu no pom real")

local wrapper = table.concat(vim.fn.readfile(target .. "/mvnw"), "\n")
assert(wrapper:find("maven", 1, true) ~= nil, "mvnw inesperado: " .. wrapper:sub(1, 80))

-- ---------- 4. compilação real (quando mvn está disponível) ----------

local compiled = "não executado (mvn ausente)"
if vim.fn.executable("mvn") == 1 then
  local res = vim
    .system({ "mvn", "-q", "-B", "-f", target .. "/pom.xml", "test-compile" }, {
      text = true,
      cwd = target,
      timeout = 600000,
    })
    :wait()
  local output = tostring(res.stdout or "") .. tostring(res.stderr or "")
  assert(res.code == 0, "mvn test-compile falhou (exit " .. tostring(res.code) .. "):\n" .. output:sub(-4000))
  assert(vim.fn.isdirectory(target .. "/target/classes") == 1, "target/classes não gerado pelo Maven")
  compiled = "mvn test-compile OK"
end

-- ---------- limpeza (somente os temporários deste spec) ----------

cleanup()

print(
  ("spring_project_real_spec: OK (Initializr %s, %s, Java %s, %d entradas no zip, %s)"):format(
    tostring(meta.boot_default),
    build_type,
    java_release,
    #names,
    compiled
  )
)
vim.cmd("qa!")
