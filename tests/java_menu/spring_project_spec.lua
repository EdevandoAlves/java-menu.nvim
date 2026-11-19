-- 7B.2: projetos Spring Boot via Spring Initializr. Cobre o CORE puro (pré-
-- requisitos de ferramentas, URL, metadata, validação de listagem do zip,
-- extração em staging + publicação) e o SHELL (wizard com metadata/download
-- stubados, cancelamentos, retry e caminho felizes).
--
-- 100% offline: nenhuma requisição real. Os zips de teste são criados
-- localmente com python3 e extraídos com o unzip REAL da máquina.
--
-- Run:
--   tests/java_menu/run.sh fast

local create = require("java_menu.create")

local real_notify = vim.notify
local notices = {}
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = tostring(msg), level = level }
end

local real_select = vim.ui.select
local real_input = vim.ui.input
local real_fetch = create._fetch_spring_metadata
local real_download = create._download_spring_zip

local dirs = {}
local zips = {}
local function new_parent(label)
  local dir = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-spring-" .. label)
  vim.fn.mkdir(dir, "p")
  dirs[#dirs + 1] = dir
  return dir
end

local function entries(dir)
  return vim.fn.readdir(dir) or {}
end

local function exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

local function spring_opts(parent, name)
  local project = name or "demo"
  return {
    kind = "spring",
    parent = parent,
    name = project,
    pkg = "com.example.demo",
    release = "21",
    group = "com.example",
    artifact = project,
    build_type = "maven-project",
    boot_version = "4.1.2",
    packaging = "jar",
    dependencies = {},
  }
end

-- ---------- zips reais (python3 + unzip) ----------

local PY_ZIP = table.concat({
  "import json, stat, sys, zipfile",
  "spec = json.loads(sys.argv[2])",
  "z = zipfile.ZipFile(sys.argv[1], 'w')",
  "kinds = {'file': (stat.S_IFREG, 0o644), 'dir': (stat.S_IFDIR, 0o755), 'symlink': (stat.S_IFLNK, 0o777)}",
  "for entry in spec:",
  "    kind = entry.get('kind', 'file')",
  "    type_bit, perm = kinds[kind]",
  "    info = zipfile.ZipInfo(entry['name'])",
  "    info.create_system = 3",
  "    info.external_attr = (type_bit | perm) << 16",
  "    if entry['name'].endswith('/'):",
  "        info.external_attr |= 0x10",
  "    z.writestr(info, entry.get('data', ''))",
  "z.close()",
}, "\n")

local zip_tools = vim.fn.executable("python3") == 1 and vim.fn.executable("unzip") == 1

local function make_zip(path, spec)
  local res = vim.system({ "python3", "-c", PY_ZIP, path, vim.json.encode(spec) }, { text = true }):wait()
  assert(res.code == 0, "não foi possível criar o zip de teste: " .. tostring(res.stderr))
  zips[#zips + 1] = path
  return path
end

-- entradas de um projeto Maven/Gradle mínimo (o suficiente para a publicação)
local function maven_entries()
  return {
    { name = "pom.xml", data = "<project/>" },
    { name = "mvnw", data = "#!/bin/sh\n" },
    { name = "src/", kind = "dir" },
    { name = "src/main/", kind = "dir" },
    { name = "src/main/java/", kind = "dir" },
    { name = "src/main/java/com/", kind = "dir" },
    { name = "src/main/java/com/example/", kind = "dir" },
    { name = "src/main/java/com/example/demo/", kind = "dir" },
    { name = "src/main/java/com/example/demo/DemoApplication.java", data = "class DemoApplication {}" },
  }
end

local function gradle_entries()
  return {
    { name = "build.gradle", data = "plugins {}\n" },
    { name = "gradlew", data = "#!/bin/sh\n" },
    { name = "src/main/java/com/example/demo/DemoApplication.java", data = "class DemoApplication {}" },
  }
end

-- ---------- 1. _spring_tools ----------

local function has(list)
  local set = {}
  for _, tool in ipairs(list) do
    set[tool] = true
  end
  return function(tool)
    return set[tool] and 1 or 0
  end
end

local tools = create._spring_tools(has({ "curl", "unzip" }))
assert(
  tools.ok == true and tools.http == "curl" and tools.unzip == true,
  "curl+unzip deveria habilitar: " .. vim.inspect(tools)
)
assert(tools.reason == nil, "sucesso não deveria carregar motivo")

tools = create._spring_tools(has({ "wget", "unzip" }))
assert(
  tools.ok == true and tools.http == "wget" and tools.unzip == true,
  "wget deveria ser o fallback: " .. vim.inspect(tools)
)

tools = create._spring_tools(has({ "curl" }))
assert(tools.ok == false and tools.http == "curl" and tools.unzip == false, "sem unzip deveria ficar indisponível")
assert(tools.reason and tools.reason:find("unzip", 1, true), "motivo deveria citar unzip: " .. tostring(tools.reason))

tools = create._spring_tools(has({ "unzip" }))
assert(tools.ok == false and tools.http == nil and tools.unzip == true, "sem cliente HTTP deveria ficar indisponível")
assert(tools.reason and tools.reason:find("curl", 1, true), "motivo deveria citar curl: " .. tostring(tools.reason))

tools = create._spring_tools(has({}))
assert(tools.ok == false and tools.http == nil and tools.unzip == false, "sem ferramentas deveria ficar indisponível")
assert(
  tools.reason and tools.reason:find("curl", 1, true) and tools.reason:find("unzip", 1, true),
  "motivo incompleto: " .. tostring(tools.reason)
)

-- has_exe pode devolver booleanos, não só 1/0
tools = create._spring_tools(function(tool)
  return tool == "curl" or tool == "unzip"
end)
assert(tools.ok == true and tools.http == "curl", "has_exe booleano não foi aceito")

-- premissas reais desta máquina (o resto do spec depende delas)
assert(
  create._spring_tools().unzip == (vim.fn.executable("unzip") == 1),
  "_spring_tools real divergiu de unzip no PATH"
)

-- ---------- 2. _url_encode e _spring_url ----------

assert(create._url_encode("a b") == "a%20b", "espaço não codificado: " .. create._url_encode("a b"))
assert(
  create._url_encode("a+b&c=d") == "a%2Bb%26c%3Dd",
  "reservados não codificados: " .. create._url_encode("a+b&c=d")
)
assert(create._url_encode("com.example.demo") == "com.example.demo", "não-reservados foram codificados")
assert(create._url_encode("a-b_c.d~e") == "a-b_c.d~e", "não-reservados foram codificados")

local url_parent = new_parent("url")
local url_opts = spring_opts(url_parent, "demo")
local expected_url = table.concat({
  "https://start.spring.io/starter.zip?type=maven-project&language=java",
  "&bootVersion=4.1.2&groupId=com.example&artifactId=demo&name=demo",
  "&packageName=com.example.demo&javaVersion=21&packaging=jar",
})
assert(create._spring_url(url_opts) == expected_url, "URL inesperada: " .. create._spring_url(url_opts))

-- a ordem dos parâmetros não depende de como a tabela foi montada
local reordered = {
  packaging = "jar",
  boot_version = "4.1.2",
  artifact = "demo",
  kind = "spring",
  pkg = "com.example.demo",
  release = "21",
  group = "com.example",
  name = "demo",
  build_type = "maven-project",
  parent = url_parent,
  dependencies = {},
}
assert(create._spring_url(reordered) == expected_url, "URL não determinística: " .. create._spring_url(reordered))

url_opts.dependencies = { "web", "data-jpa" }
local with_deps = create._spring_url(url_opts)
assert(with_deps:find("&dependencies=web,data-jpa", 1, true), "dependências ausentes na URL: " .. with_deps)

url_opts.dependencies = nil
assert(create._spring_url(url_opts) == expected_url, "dependencies nil deveria ser omitido")

url_opts.dependencies = {}
assert(create._spring_url(url_opts) == expected_url, "dependencies vazio deveria ser omitido")

assert(
  create._spring_url(url_opts, "https://example.test/starter.zip"):match("^https://example%.test/starter%.zip%?") ~= nil,
  "base customizada ignorada"
)

-- ---------- 3. _parse_metadata ----------

local META_JSON = vim.json.encode({
  type = {
    default = "gradle-project",
    values = {
      { id = "gradle-project", name = "Gradle - Groovy" },
      { id = "gradle-project-kotlin", name = "Gradle - Kotlin" },
      { id = "gradle-build", name = "Gradle Config" },
      { id = "maven-project", name = "Maven" },
      { id = "maven-build", name = "Maven POM" },
    },
  },
  bootVersion = {
    default = "4.1.2",
    values = { { id = "4.2.0-SNAPSHOT", name = "4.2.0-SNAPSHOT" }, { id = "4.1.2", name = "4.1.2" } },
  },
  packaging = { default = "jar", values = { { id = "war", name = "War" }, { id = "jar", name = "Jar" } } },
  javaVersion = {
    default = "17",
    values = { { id = "27", name = "27" }, { id = "21", name = "21" }, { id = "17", name = "17" } },
  },
  dependencies = {
    values = {
      { name = "Web", values = { { id = "web", name = "Spring Web", description = "Build web apps" } } },
      {
        name = "SQL",
        values = {
          { id = "data-jpa", name = "Spring Data JPA", description = "JPA" },
          { id = "jdbc", name = "JDBC API", description = "JDBC" },
        },
      },
    },
  },
})

local meta, meta_err = create._parse_metadata(META_JSON)
assert(meta ~= nil, "metadata válida rejeitada: " .. tostring(meta_err))
assert(#meta.types == 3, "tipos filtrados incorretamente: " .. vim.inspect(meta.types))
assert(meta.types[1].id == "maven-project", "maven-project deveria vir primeiro: " .. vim.inspect(meta.types))
local type_ids = {}
for _, value in ipairs(meta.types) do
  type_ids[value.id] = true
end
assert(type_ids["gradle-project"] and type_ids["gradle-project-kotlin"], "projetos Gradle ausentes")
assert(not type_ids["maven-build"] and not type_ids["gradle-build"], "os tipos *-build deveriam ser filtrados")
assert(
  meta.boot_default == "4.1.2" and meta.boot_versions[1].id == "4.1.2",
  "default do bootVersion não veio primeiro"
)
assert(meta.packaging_default == "jar" and meta.packagings[1].id == "jar", "default do packaging não veio primeiro")
assert(meta.java_default == "17", "default de javaVersion divergiu: " .. tostring(meta.java_default))
assert(#meta.dependencies == 3, "dependências não achatadas: " .. vim.inspect(meta.dependencies))
assert(meta.dependencies[1].id == "web" and meta.dependencies[1].group == "Web", "primeira dependência divergiu")
assert(meta.dependencies[2].id == "data-jpa" and meta.dependencies[2].group == "SQL", "grupo perdido no achatamento")
assert(meta.dependencies[2].description == "JPA", "descrição perdida no achatamento")

for _, bad in ipairs({ "", "   ", "not json", "[]", "42" }) do
  local parsed, err = create._parse_metadata(bad)
  assert(parsed == nil and type(err) == "string" and err ~= "", "input inválido aceito: " .. vim.inspect(bad))
end

local function decode_meta()
  return vim.json.decode(META_JSON)
end

local without_boot = decode_meta()
without_boot.bootVersion = nil
local parsed, err = create._parse_metadata(vim.json.encode(without_boot))
assert(parsed == nil and err:find("bootVersion", 1, true) ~= nil, "seção ausente não reportada: " .. tostring(err))

local no_deps = decode_meta()
no_deps.dependencies = { values = {} }
parsed, err = create._parse_metadata(vim.json.encode(no_deps))
assert(
  parsed == nil and err:find("dependencies", 1, true) ~= nil,
  "dependências vazias não reportadas: " .. tostring(err)
)

local only_build = decode_meta()
only_build.type.values = { { id = "maven-build", name = "Maven POM" } }
parsed, err = create._parse_metadata(vim.json.encode(only_build))
assert(
  parsed == nil and err:find("project types", 1, true) ~= nil,
  "tipos *-build deveriam esvaziar a lista: " .. tostring(err)
)

-- ---------- 4. _validate: kind spring ----------

local valid_parent = new_parent("validate")
local valid = spring_opts(valid_parent, "demo")
assert(create._validate(valid) == nil, "opts spring válidas rejeitadas: " .. tostring(create._validate(valid)))

local kotlin = spring_opts(valid_parent, "demo")
kotlin.build_type = "gradle-project-kotlin"
assert(create._validate(kotlin) == nil, "gradle-project-kotlin deveria ser aceito")

local with_deps_opts = spring_opts(valid_parent, "demo")
with_deps_opts.dependencies = { "web", "data-jpa" }
assert(create._validate(with_deps_opts) == nil, "lista de dependências válida rejeitada")

for _, bad in ipairs({ "", "maven-build", "Maven-Project", "-project", "project", "maven_project", nil }) do
  local opts = spring_opts(valid_parent, "demo")
  opts.build_type = bad
  local reason = create._validate(opts)
  assert(
    reason and reason:find("invalid Spring project type", 1, true),
    "tipo '" .. tostring(bad) .. "' não rejeitado: " .. tostring(reason)
  )
end

for _, bad in ipairs({ "", "4.1 2", "4.1.2;", nil, 42 }) do
  local opts = spring_opts(valid_parent, "demo")
  opts.boot_version = bad
  local reason = create._validate(opts)
  assert(
    reason and reason:find("invalid Spring Boot version", 1, true),
    "versão '" .. tostring(bad) .. "' não rejeitada: " .. tostring(reason)
  )
end

for _, bad in ipairs({ "", "zip", "JAR", nil }) do
  local opts = spring_opts(valid_parent, "demo")
  opts.packaging = bad
  local reason = create._validate(opts)
  assert(
    reason and reason:find("invalid packaging", 1, true),
    "packaging '" .. tostring(bad) .. "' não rejeitado: " .. tostring(reason)
  )
end

local bad_dep = spring_opts(valid_parent, "demo")
bad_dep.dependencies = { "web", "bad id" }
assert(create._validate(bad_dep):find("invalid dependency id", 1, true), "dependency id inválido não rejeitado")

local bad_dep_list = spring_opts(valid_parent, "demo")
bad_dep_list.dependencies = "web"
assert(create._validate(bad_dep_list):find("invalid dependencies", 1, true), "dependencies não-lista não rejeitada")

local bad_group = spring_opts(valid_parent, "demo")
bad_group.group = "com.1bad"
assert(create._validate(bad_group):find("invalid groupId", 1, true), "groupId inválido não rejeitado")

local bad_artifact = spring_opts(valid_parent, "demo")
bad_artifact.artifact = " bad"
assert(create._validate(bad_artifact):find("invalid artifactId", 1, true), "artifactId inválido não rejeitado")

-- as checagens compartilhadas continuam valendo para spring
local bad_pkg = spring_opts(valid_parent, "demo")
bad_pkg.pkg = "com..example"
assert(create._validate(bad_pkg):find("invalid package", 1, true), "package inválido não rejeitado")

local bad_name = spring_opts(valid_parent, "bad/name")
assert(create._validate(bad_name):find("invalid project name", 1, true), "nome inválido não rejeitado")

local bad_release = spring_opts(valid_parent, "demo")
bad_release.release = "abc"
assert(create._validate(bad_release):find("invalid Java release", 1, true), "release inválida não rejeitada")

local occupied_parent = new_parent("occupied")
vim.fn.mkdir(occupied_parent .. "/demo", "p")
vim.fn.writefile({ "keep" }, occupied_parent .. "/demo/keep.txt")
assert(
  create._validate(spring_opts(occupied_parent, "demo")):find("not empty", 1, true),
  "target ocupado não rejeitado para spring"
)

vim.fn.mkdir(valid_parent .. "/.demo.java-menu-stage", "p")
assert(
  create._validate(spring_opts(valid_parent, "demo")):find("stale staging directory", 1, true),
  "staging pré-existente não rejeitado para spring"
)
vim.fn.delete(valid_parent .. "/.demo.java-menu-stage", "rf")

-- _run não gera Spring localmente
local run_ok, run_err = create._run(spring_opts(valid_parent, "demo"))
assert(not run_ok and run_err:find("Spring Initializr", 1, true), "_run deveria recusar spring: " .. tostring(run_err))
assert(#entries(valid_parent) == 0, "_run(spring) escreveu algo: " .. vim.inspect(entries(valid_parent)))

-- ---------- 5. _summary_lines: spring ----------

local resolved_valid = vim.uv.fs_realpath(valid_parent) or valid_parent
local summary = create._summary_lines(spring_opts(valid_parent, "demo"))
local summary_text = table.concat(summary, "\n")
assert(summary_text:find("Kind: Spring Boot (Maven)", 1, true), "kind ausente no resumo:\n" .. summary_text)
assert(
  summary_text:find("Target: " .. resolved_valid .. "/demo", 1, true),
  "target ausente no resumo:\n" .. summary_text
)
assert(summary_text:find("Spring Boot version: 4.1.2", 1, true), "versão ausente no resumo")
assert(summary_text:find("Packaging: jar", 1, true), "packaging ausente no resumo")
assert(summary_text:find("Java release: 21", 1, true), "release ausente no resumo")
assert(summary_text:find("groupId: com.example", 1, true), "groupId ausente no resumo")
assert(summary_text:find("artifactId: demo", 1, true), "artifactId ausente no resumo")
assert(summary_text:find("Package: com.example.demo", 1, true), "package ausente no resumo")
assert(summary_text:find("Dependencies: (none)", 1, true), "dependências vazias mal representadas:\n" .. summary_text)

local with_deps_summary = spring_opts(valid_parent, "demo")
with_deps_summary.dependencies = { "web", "data-jpa" }
assert(
  table.concat(create._summary_lines(with_deps_summary), "\n"):find("Dependencies: web, data-jpa", 1, true),
  "dependências não listadas no resumo"
)

local kotlin_summary = spring_opts(valid_parent, "demo")
kotlin_summary.build_type = "gradle-project-kotlin"
assert(
  table.concat(create._summary_lines(kotlin_summary), "\n"):find("Kind: Spring Boot (Gradle (Kotlin))", 1, true),
  "build type kotlin mal rotulado no resumo"
)

local warning_parent = new_parent("warning")
vim.fn.mkdir(warning_parent .. "/demo", "p")
assert(
  table
    .concat(create._summary_lines(spring_opts(warning_parent, "demo")), "\n")
    :find("WARNING: target already exists", 1, true),
  "aviso de target existente ausente"
)

-- ---------- 6. _validate_zip_listing ----------

local MODE_FILE = "-rw-r--r--  2.0 unx       10 b- stor 26-Nov-19 11:52 "
local MODE_DIR = "drwxr-xr-x  2.0 unx        0 b- stor 26-Nov-19 11:52 "

local listing_ok, listing_reason = create._validate_zip_listing(
  { "pom.xml", "src/", "src/main/java/com/example/demo/DemoApplication.java" },
  { MODE_FILE .. "pom.xml", MODE_DIR .. "src/", MODE_FILE .. "src/main/java/com/example/demo/DemoApplication.java" }
)
assert(listing_ok == true, "listagem válida rejeitada: " .. tostring(listing_reason))

listing_ok, listing_reason = create._validate_zip_listing({}, {})
assert(
  listing_ok == false and listing_reason:find("empty archive", 1, true),
  "arquivo vazio não rejeitado: " .. tostring(listing_reason)
)

listing_ok, listing_reason = create._validate_zip_listing({ "pom.xml", "mvnw" }, { MODE_FILE .. "pom.xml" })
assert(
  listing_ok == false and listing_reason:find("inconsistent", 1, true),
  "descompasso de contagem não rejeitado: " .. tostring(listing_reason)
)

listing_ok, listing_reason = create._validate_zip_listing(
  { "pom.xml" },
  { MODE_FILE .. "pom.xml", MODE_FILE .. "extra" }
)
assert(
  listing_ok == false and listing_reason:find("inconsistent", 1, true),
  "descompasso de contagem não rejeitado (inverso)"
)

local unsafe_entries = {
  { "", "empty entry path" },
  { "/etc/passwd", "absolute path" },
  { "\\windows\\system32", "absolute path" },
  { "C:/temp/evil.txt", "Windows drive path" },
  { "dir\\file.txt", "backslash" },
  { "../escape.txt", "escapes" },
  { "src/../../escape.txt", "escapes" },
  { "..", "escapes" },
  { "src/e\0vil.txt", "NUL byte" },
}
for _, case in ipairs(unsafe_entries) do
  local ok, reason = create._validate_zip_listing({ case[1] }, { MODE_FILE .. tostring(case[1]) })
  assert(ok == false, "entrada insegura aceita: " .. vim.inspect(case[1]))
  assert(
    reason:find(case[2], 1, true) ~= nil,
    "motivo inesperado para " .. vim.inspect(case[1]) .. ": " .. tostring(reason)
  )
end

-- nomes com ".." apenas como parte do nome (não é traversal) continuam válidos
listing_ok, listing_reason = create._validate_zip_listing({ "src/..hidden/file.txt" }, { MODE_FILE .. "x" })
assert(listing_ok == true, "nome com '..' inofensivo foi rejeitado: " .. tostring(listing_reason))

for _, kind_char in ipairs({ "l", "p", "b", "c", "s", "?" }) do
  local mode = kind_char .. "rw-r--r--  2.0 unx       10 b- stor 26-Nov-19 11:52 secret"
  local ok, reason = create._validate_zip_listing({ "secret" }, { mode })
  assert(ok == false, "tipo de entrada '" .. kind_char .. "' aceito")
  assert(reason:find("unsupported type", 1, true), "motivo sem tipo: " .. tostring(reason))
  assert(reason:find("secret", 1, true), "motivo não nomeia a entrada: " .. tostring(reason))
end

-- ---------- 7. zip real: _inspect_zip, extração e publicação ----------

if not zip_tools then
  print("spring_project_spec: nota — python3/unzip ausentes, seção de zip real pulada")
end

-- _verify_staged_tree é puro (só leitura)
do
  local stage_parent = new_parent("verify")
  local stage = stage_parent .. "/stage"
  vim.fn.mkdir(stage, "p")
  local ok, err = create._verify_staged_tree(stage)
  assert(ok == false and err:find("no files", 1, true), "staging vazio aceito: " .. tostring(err))
  vim.fn.writefile({ "x" }, stage .. "/file.txt")
  assert(create._verify_staged_tree(stage) == true, "staging com arquivo rejeitado")
  vim.uv.fs_symlink("/etc/passwd", stage .. "/link")
  ok, err = create._verify_staged_tree(stage)
  assert(ok == false and err:find("unsupported type", 1, true), "symlink no staging aceito: " .. tostring(err))
  assert(create._verify_staged_tree(stage_parent .. "/missing") == false, "staging inexistente aceito")
end

if zip_tools then
  -- 7.1 zip válido -> extração em staging + publicação
  local extract_parent = new_parent("extract")
  local valid_zip = make_zip(vim.fn.tempname() .. ".zip", maven_entries())
  local inspected, names = create._inspect_zip(valid_zip)
  assert(inspected == true, "_inspect_zip falhou num zip válido: " .. tostring(names))
  assert(type(names) == "table" and #names == #maven_entries(), "listagem inesperada: " .. vim.inspect(names))

  local ok, err = create._extract_spring_zip(valid_zip, spring_opts(extract_parent, "demo"))
  assert(ok, "extração válida falhou: " .. tostring(err))
  assert(exists(extract_parent .. "/demo/pom.xml"), "pom.xml não publicado")
  assert(exists(extract_parent .. "/demo/mvnw"), "mvnw não publicado")
  assert(
    exists(extract_parent .. "/demo/src/main/java/com/example/demo/DemoApplication.java"),
    "classe da aplicação não publicada"
  )
  assert(not exists(extract_parent .. "/.demo.java-menu-stage"), "staging sobrou após a publicação")
  assert(
    vim.deep_equal(entries(extract_parent), { "demo" }),
    "lixo no parent: " .. vim.inspect(entries(extract_parent))
  )

  -- 7.2 traversal -> rejeitado antes de extrair, nada escrito
  local traversal_parent = new_parent("traversal")
  local traversal_zip = make_zip(vim.fn.tempname() .. ".zip", {
    { name = "pom.xml", data = "<project/>" },
    { name = "../escape.txt", data = "pwned" },
  })
  local escaped_path = vim.fs.normalize(traversal_parent .. "/../escape.txt")
  ok, err = create._extract_spring_zip(traversal_zip, spring_opts(traversal_parent, "demo"))
  assert(ok == false and err:find("escapes", 1, true), "traversal não rejeitado: " .. tostring(err))
  assert(#entries(traversal_parent) == 0, "traversal escreveu no parent: " .. vim.inspect(entries(traversal_parent)))
  assert(not exists(escaped_path), "traversal escapou do parent: " .. escaped_path)

  -- 7.3 symlink -> rejeitado antes de extrair, nada escrito
  local symlink_parent = new_parent("symlink")
  local symlink_zip = make_zip(vim.fn.tempname() .. ".zip", {
    { name = "pom.xml", data = "<project/>" },
    { name = "evil", kind = "symlink", data = "/etc/passwd" },
  })
  ok, err = create._extract_spring_zip(symlink_zip, spring_opts(symlink_parent, "demo"))
  assert(ok == false and err:find("unsupported type", 1, true), "symlink não rejeitado: " .. tostring(err))
  assert(#entries(symlink_parent) == 0, "symlink escreveu no parent: " .. vim.inspect(entries(symlink_parent)))

  -- 7.4 target existente e não vazio -> recusado, arquivo existente intacto
  local busy_parent = new_parent("busy")
  vim.fn.mkdir(busy_parent .. "/demo", "p")
  vim.fn.writefile({ "keep" }, busy_parent .. "/demo/keep.txt")
  ok, err = create._extract_spring_zip(valid_zip, spring_opts(busy_parent, "demo"))
  assert(ok == false and err:find("not empty", 1, true), "target não vazio foi aceito: " .. tostring(err))
  assert(vim.fn.readfile(busy_parent .. "/demo/keep.txt")[1] == "keep", "arquivo pré-existente foi alterado")
  assert(not exists(busy_parent .. "/demo/pom.xml"), "extração escreveu no target não vazio")
  assert(not exists(busy_parent .. "/.demo.java-menu-stage"), "staging sobrou no target não vazio")

  -- 7.5 target existente e vazio -> publicado entrada por entrada
  local empty_parent = new_parent("emptytarget")
  vim.fn.mkdir(empty_parent .. "/demo", "p")
  ok, err = create._extract_spring_zip(valid_zip, spring_opts(empty_parent, "demo"))
  assert(ok, "publicação em target vazio falhou: " .. tostring(err))
  assert(exists(empty_parent .. "/demo/pom.xml"), "pom.xml não publicado no target vazio")
  assert(exists(empty_parent .. "/demo/src/main/java/com/example/demo/DemoApplication.java"), "src não publicado")
  assert(not exists(empty_parent .. "/.demo.java-menu-stage"), "staging sobrou no target vazio")
  assert(#entries(empty_parent) == 1, "lixo ao lado do target vazio: " .. vim.inspect(entries(empty_parent)))

  -- 7.6 arquivo que não é zip -> rejeitado sem escrever nada
  local bogus_parent = new_parent("bogus")
  local bogus_zip = vim.fn.tempname() .. ".zip"
  vim.fn.writefile({ "esto não é um zip" }, bogus_zip)
  zips[#zips + 1] = bogus_zip
  ok, err = create._extract_spring_zip(bogus_zip, spring_opts(bogus_parent, "demo"))
  assert(ok == false and type(err) == "string" and err ~= "", "arquivo não-zip aceito")
  assert(#entries(bogus_parent) == 0, "arquivo não-zip escreveu no parent: " .. vim.inspect(entries(bogus_parent)))

  local inspected_bogus, inspect_err = create._inspect_zip(bogus_zip)
  assert(inspected_bogus == false and type(inspect_err) == "string", "_inspect_zip aceitou um não-zip")

  local inspected_missing = create._inspect_zip(bogus_parent .. "/missing.zip")
  assert(inspected_missing == false, "_inspect_zip aceitou um caminho inexistente")

  -- 7.7 _extract_spring_zip revalida as opções (nada é escrito)
  local revalidate_parent = new_parent("revalidate")
  local bad_opts = spring_opts(revalidate_parent, "demo")
  bad_opts.packaging = "zip"
  ok, err = create._extract_spring_zip(valid_zip, bad_opts)
  assert(
    ok == false and err:find("invalid packaging", 1, true),
    "opções inválidas não rejeitadas: " .. tostring(err)
  )
  assert(#entries(revalidate_parent) == 0, "opções inválidas escreveram no parent")
end

-- ---------- 8. wizard: stubs de UI, metadata e download ----------

local FAKE_META = {
  types = {
    { id = "maven-project", name = "Maven" },
    { id = "gradle-project", name = "Gradle - Groovy" },
    { id = "gradle-project-kotlin", name = "Gradle - Kotlin" },
  },
  boot_versions = { { id = "4.1.2", name = "4.1.2" }, { id = "4.0.9", name = "4.0.9" } },
  boot_default = "4.1.2",
  packagings = { { id = "jar", name = "Jar" }, { id = "war", name = "War" } },
  packaging_default = "jar",
  java_versions = { { id = "21", name = "21" }, { id = "17", name = "17" } },
  java_default = "17",
  dependencies = {
    { id = "web", name = "Spring Web", group = "Web", description = "web" },
    { id = "data-jpa", name = "Spring Data JPA", group = "SQL", description = "jpa" },
  },
}

local select_queue, input_queue
local calls

local function stub_ui()
  vim.ui.select = function(items, opts, on_choice)
    calls.selects[#calls.selects + 1] = { items = vim.deepcopy(items), prompt = opts and opts.prompt }
    on_choice(table.remove(select_queue, 1))
  end
  vim.ui.input = function(opts, on_confirm)
    calls.inputs[#calls.inputs + 1] = { prompt = opts and opts.prompt, default = opts and opts.default }
    on_confirm(table.remove(input_queue, 1))
  end
end

local function reset_ui(selects, inputs)
  select_queue = selects
  input_queue = inputs
  calls = { selects = {}, inputs = {} }
  stub_ui()
end

local function select_items(index)
  local call = calls.selects[index]
  return call and table.concat(call.items, "\n") or ""
end

local function line_of(text, needle)
  for line in text:gmatch("[^\n]+") do
    if line:find(needle, 1, true) then
      return line
    end
  end
end

-- 8.1 ferramentas ausentes: entrada Spring Boot desabilitada com motivo
do
  local notools_parent = new_parent("notools")
  local original_tools = create._spring_tools
  create._spring_tools = function()
    return { ok = false, http = nil, unzip = false, reason = "unzip is required to extract the Spring Boot project" }
  end
  reset_ui({ nil }, {})
  create.create()
  create._spring_tools = original_tools

  assert(#calls.selects == 1, "o seletor de kind não foi aberto")
  assert(
    calls.selects[1].prompt == "Java: New Project — kind",
    "prompt do kind divergiu: " .. tostring(calls.selects[1].prompt)
  )
  local items = select_items(1)
  local plain_line = line_of(items, "Plain Java")
  assert(
    plain_line and not plain_line:find("unavailable", 1, true),
    "Plain Java deveria estar habilitado: " .. tostring(plain_line)
  )
  assert(line_of(items, "Maven") ~= nil, "Maven ausente do seletor")
  local spring_line = line_of(items, "Spring Boot")
  assert(spring_line ~= nil, "Spring Boot ausente do seletor")
  assert(spring_line:find("(unavailable:", 1, true), "Spring Boot deveria estar desabilitado: " .. spring_line)
  assert(spring_line:find("unzip", 1, true), "motivo do Spring Boot ausente: " .. spring_line)
  assert(#entries(notools_parent) == 0, "o seletor desabilitado escreveu algo")
end

-- 8.2 cancelar em cada etapa não escreve nada
do
  create._fetch_spring_metadata = function(on_done)
    on_done(FAKE_META, nil)
  end
  local downloads = 0
  create._download_spring_zip = function(_, _, on_done)
    downloads = downloads + 1
    on_done(false, "não deveria ser chamado")
  end

  -- (a) no build tool
  local early_parent = new_parent("cancel-early")
  reset_ui({ "Spring Boot", nil }, {})
  create.create()
  assert(#entries(early_parent) == 0, "cancelamento no build tool escreveu: " .. vim.inspect(entries(early_parent)))

  -- (b) no diretório pai
  local parent_cancel = new_parent("cancel-parent")
  reset_ui({ "Spring Boot", "Maven", "4.1.2", "Jar", "21" }, { nil })
  create.create()
  assert(#entries(parent_cancel) == 0, "cancelamento no parent escreveu algo")

  -- (c) nas dependências (último campo de texto)
  local deps_cancel = new_parent("cancel-deps")
  reset_ui(
    { "Spring Boot", "Maven", "4.1.2", "Jar", "21" },
    { deps_cancel, "demo", "com.example", "demo", "com.example.demo", nil }
  )
  create.create()
  assert(#entries(deps_cancel) == 0, "cancelamento nas dependências escreveu: " .. vim.inspect(entries(deps_cancel)))

  -- (d) no resumo
  local summary_cancel = new_parent("cancel-summary")
  reset_ui(
    { "Spring Boot", "Maven", "4.1.2", "Jar", "21", "✖ Cancel" },
    { summary_cancel, "demo", "com.example", "demo", "com.example.demo", "" }
  )
  create.create()
  assert(#entries(summary_cancel) == 0, "cancelamento no resumo escreveu: " .. vim.inspect(entries(summary_cancel)))
  assert(downloads == 0, "o download começou antes da confirmação")

  -- o resumo mostra os dados coletados e as dependências
  local summary_items = select_items(6)
  assert(summary_items:find("Kind: Spring Boot (Maven)", 1, true), "resumo sem o kind:\n" .. summary_items)
  assert(summary_items:find("Spring Boot version: 4.1.2", 1, true), "resumo sem a versão:\n" .. summary_items)
  assert(summary_items:find("Dependencies: (none)", 1, true), "resumo sem as dependências:\n" .. summary_items)
  assert(summary_items:find("✖ Cancel", 1, true), "resumo sem o cancelar")

  -- os seletores vieram da metadata (sem *-build)
  local build_items = select_items(2)
  assert(
    build_items:find("Maven", 1, true) and build_items:find("Gradle - Kotlin", 1, true),
    "build tools ausentes:\n" .. build_items
  )
  assert(
    #vim.split(build_items, "\n", { plain = true }) == 3,
    "apenas 3 project types deveriam aparecer:\n" .. build_items
  )
  local boot_items = select_items(3)
  assert(
    vim.split(boot_items, "\n", { plain = true })[1] == "4.1.2",
    "default do boot deveria vir primeiro:\n" .. boot_items
  )
  local java_items = select_items(5)
  assert(
    vim.split(java_items, "\n", { plain = true })[1] == "21",
    "Java 21 deveria vir primeiro quando disponível:\n" .. java_items
  )
end

-- 8.3 falha de metadata: Retry refaz a busca; Cancel não escreve nada
do
  local attempts = 0
  create._fetch_spring_metadata = function(on_done)
    attempts = attempts + 1
    if attempts == 1 then
      on_done(nil, "timeout")
    else
      on_done(FAKE_META, nil)
    end
  end

  local retry_parent = new_parent("meta-retry")
  reset_ui(
    { "Spring Boot", "Retry", "Maven", "4.1.2", "Jar", "21", "✖ Cancel" },
    { retry_parent, "demo", "com.example", "demo", "com.example.demo", "" }
  )
  notices = {}
  create.create()
  assert(attempts == 2, "Retry não refez a busca de metadata: " .. attempts)
  assert(#entries(retry_parent) == 0, "Retry+Cancel escreveu algo: " .. vim.inspect(entries(retry_parent)))
  assert(
    #notices > 0 and notices[1].msg:find("Spring Initializr", 1, true),
    "erro de metadata não notificado: " .. vim.inspect(notices)
  )
  assert(notices[1].level == vim.log.levels.ERROR, "erro de metadata deveria ser ERROR")

  local cancel_parent = new_parent("meta-cancel")
  attempts = 0
  create._fetch_spring_metadata = function(on_done)
    attempts = attempts + 1
    on_done(nil, "offline")
  end
  reset_ui({ "Spring Boot", "Cancel" }, {})
  notices = {}
  create.create()
  assert(attempts == 1, "Cancel não deveria refazer a busca: " .. attempts)
  assert(#entries(cancel_parent) == 0, "Cancel escreveu algo")
  assert(
    #notices == 1 and notices[1].msg:find("offline", 1, true),
    "motivo ausente na notificação: " .. vim.inspect(notices)
  )
end

-- 8.4 falha de download: Retry refaz tudo; Cancel deixa zero arquivos
do
  create._fetch_spring_metadata = function(on_done)
    on_done(FAKE_META, nil)
  end

  local attempts = 0
  local captured_opts, captured_dest
  create._download_spring_zip = function(opts, dest, on_done)
    attempts = attempts + 1
    captured_opts, captured_dest = opts, dest
    if attempts == 1 then
      -- simula um download parcial: o wizard precisa limpar o temporário
      vim.fn.writefile({ "PK" }, dest)
      on_done(false, "connection reset")
      return
    end
    make_zip(dest, maven_entries())
    on_done(true, nil)
  end

  local retry_parent = new_parent("download-retry")
  reset_ui(
    { "Spring Boot", "Maven", "4.1.2", "Jar", "21", "✔ Create project", "Retry" },
    { retry_parent, "demo", "com.acme", "demo", "com.acme.demo", "web,data-jpa" }
  )
  notices = {}
  create.create()
  assert(attempts == 2, "Retry não refez o download: " .. attempts)
  assert(captured_opts.dependencies and #captured_opts.dependencies == 2, "dependências não chegaram ao download")
  assert(
    captured_opts.dependencies[1] == "web" and captured_opts.dependencies[2] == "data-jpa",
    "ids de dependência divergiram"
  )
  assert(exists(retry_parent .. "/demo/pom.xml"), "Retry não publicou o projeto")
  assert(not exists(captured_dest), "zip temporário sobrou após o sucesso: " .. tostring(captured_dest))
  assert(not exists(retry_parent .. "/.demo.java-menu-stage"), "staging sobrou após o Retry")
  assert(
    notices[1].level == vim.log.levels.ERROR and notices[1].msg:find("download failed", 1, true),
    "erro de download não notificado"
  )
  local resolved_retry = vim.uv.fs_realpath(retry_parent) or retry_parent
  assert(
    notices[#notices].msg:find("created " .. resolved_retry .. "/demo", 1, true),
    "sucesso não notificado: " .. notices[#notices].msg
  )

  local cancel_parent = new_parent("download-cancel")
  attempts = 0
  create._download_spring_zip = function(_, dest, on_done)
    attempts = attempts + 1
    vim.fn.writefile({ "PK" }, dest)
    on_done(false, "connection reset")
  end
  reset_ui(
    { "Spring Boot", "Maven", "4.1.2", "Jar", "21", "✔ Create project", "Cancel" },
    { cancel_parent, "demo", "com.acme", "demo", "com.acme.demo", "" }
  )
  create.create()
  assert(attempts == 1, "Cancel não deveria refazer o download: " .. attempts)
  assert(#entries(cancel_parent) == 0, "Cancel deixou arquivos: " .. vim.inspect(entries(cancel_parent)))
  assert(not exists(cancel_parent .. "/.demo.java-menu-stage"), "Cancel deixou staging")
end

-- 8.5 caminho feliz Maven: abre o pom.xml e notifica o caminho
do
  create._fetch_spring_metadata = function(on_done)
    on_done(FAKE_META, nil)
  end
  create._download_spring_zip = function(_, dest, on_done)
    make_zip(dest, maven_entries())
    on_done(true, nil)
  end

  local happy_parent = new_parent("happy-maven")
  reset_ui(
    { "Spring Boot", "Maven", "4.1.2", "Jar", "21", "✔ Create project" },
    { happy_parent, "springapp", "com.acme", "springapp", "com.acme.springapp", "" }
  )
  notices = {}
  create.create()

  local target = happy_parent .. "/springapp"
  assert(exists(target .. "/pom.xml"), "pom.xml não criado")
  assert(exists(target .. "/mvnw"), "mvnw não criado")
  assert(exists(target .. "/src/main/java/com/example/demo/DemoApplication.java"), "classe da aplicação não criada")
  assert(not exists(happy_parent .. "/.springapp.java-menu-stage"), "staging sobrou")
  assert(
    vim.deep_equal(entries(happy_parent), { "springapp" }),
    "lixo no parent: " .. vim.inspect(entries(happy_parent))
  )
  assert(
    vim.api.nvim_buf_get_name(0):find("pom.xml", 1, true) ~= nil,
    "pom.xml criado não foi aberto: " .. vim.api.nvim_buf_get_name(0)
  )
  local last = notices[#notices].msg
  local resolved_happy = vim.uv.fs_realpath(happy_parent) or happy_parent
  assert(last:find("created " .. resolved_happy .. "/springapp", 1, true), "caminho criado não notificado: " .. last)
  assert(last:find("./mvnw spring-boot:run", 1, true), "hint do Maven ausente: " .. last)
end

-- 8.6 caminho feliz Gradle: abre o build.gradle e sugere o ./gradlew
do
  create._fetch_spring_metadata = function(on_done)
    on_done(FAKE_META, nil)
  end
  create._download_spring_zip = function(_, dest, on_done)
    make_zip(dest, gradle_entries())
    on_done(true, nil)
  end

  local gradle_parent = new_parent("happy-gradle")
  reset_ui(
    { "Spring Boot", "Gradle - Groovy", "4.0.9", "War", "21", "✔ Create project" },
    { gradle_parent, "gradleapp", "com.acme", "gradleapp", "com.acme.gradleapp", "" }
  )
  notices = {}
  create.create()

  local target = gradle_parent .. "/gradleapp"
  assert(exists(target .. "/build.gradle"), "build.gradle não criado")
  assert(not exists(target .. "/pom.xml"), "pom.xml inesperado num projeto Gradle")
  assert(
    vim.api.nvim_buf_get_name(0):find("build.gradle", 1, true) ~= nil,
    "build.gradle criado não foi aberto: " .. vim.api.nvim_buf_get_name(0)
  )
  local last = notices[#notices].msg
  local resolved_gradle = vim.uv.fs_realpath(gradle_parent) or gradle_parent
  assert(last:find("created " .. resolved_gradle .. "/gradleapp", 1, true), "caminho criado não notificado: " .. last)
  assert(last:find("./gradlew bootRun", 1, true), "hint do Gradle ausente: " .. last)
end

-- ---------- restauração ----------

vim.ui.select = real_select
vim.ui.input = real_input
vim.notify = real_notify
create._fetch_spring_metadata = real_fetch
create._download_spring_zip = real_download
for _, dir in ipairs(dirs) do
  vim.fn.delete(dir, "rf")
end
for _, zip in ipairs(zips) do
  vim.fn.delete(zip)
end

print("spring_project_spec: OK (tools, URL, metadata, zip seguro, staging, wizard e retry)")
vim.cmd("qa!")
