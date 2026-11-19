-- 7C: Dependency Management (deps.lua). Cobre o CORE puro (mascaramento de
-- comentários, parsing do POM, inserção cirúrgica byte-a-byte, validação,
-- catalogs Gradle estáticos, helpers do Maven Central) e o SHELL interativo
-- (menu, add manual, fallback de busca offline, cancelamento sem escrita e
-- sync JDTLS apenas com cliente anexado). 100% offline: nenhuma busca de rede
-- é executada (os helpers assíncronos são injetados).
--
-- Run:
--   tests/java_menu/run.sh fast

local deps = require("java_menu.deps")
local lsp = require("java_menu.lsp")
local fixtures = require("tests.java_menu.fixtures")

-- ---------- stubs globais (restaurados no final) ----------

local real_notify = vim.notify
local notices = {}
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = tostring(msg), level = level }
end
local function has_notice(needle)
  for _, notice in ipairs(notices) do
    if notice.msg:find(needle, 1, true) then
      return true
    end
  end
  return false
end
local function last_notice()
  return notices[#notices] and notices[#notices].msg or ""
end

local real_select = vim.ui.select
local real_input = vim.ui.input
local select_calls, input_calls = {}, {}

---Fila determinística de respostas para vim.ui.select / vim.ui.input.
---`false` cancela (Esc); fila vazia também cancela.
local function stub_ui(selects, inputs)
  local select_queue = vim.deepcopy(selects or {})
  local input_queue = vim.deepcopy(inputs or {})
  select_calls, input_calls = {}, {}

  vim.ui.select = function(items, opts, on_choice)
    select_calls[#select_calls + 1] = { items = vim.deepcopy(items), prompt = opts and opts.prompt }
    if #select_queue == 0 then
      return
    end
    local want = table.remove(select_queue, 1)
    if want == false then
      return
    end
    for _, item in ipairs(items) do
      if item == want or (type(item) == "string" and item:find(want, 1, true)) then
        return on_choice(item)
      end
    end
    error("stub_ui: nenhuma entrada casou com '" .. tostring(want) .. "'")
  end

  vim.ui.input = function(opts, on_confirm)
    input_calls[#input_calls + 1] = opts and opts.prompt
    if #input_queue == 0 then
      return on_confirm(nil)
    end
    local value = table.remove(input_queue, 1)
    on_confirm(value == false and nil or value)
  end
end

-- ---------- helpers de arquivo ----------

local temp_dirs = {}

local function tempdir(label)
  local dir = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-deps-" .. label)
  vim.fn.mkdir(dir, "p")
  temp_dirs[#temp_dirs + 1] = dir
  return dir
end

local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(vim.uv.fs_open(path, "w", 420))
  assert(vim.uv.fs_write(fd, text, 0))
  vim.uv.fs_close(fd)
end

local function read_raw(path)
  local fd = assert(vim.uv.fs_open(path, "r", 420))
  local stat = assert(vim.uv.fs_fstat(fd))
  local data = stat.size > 0 and assert(vim.uv.fs_read(fd, stat.size, 0)) or ""
  vim.uv.fs_close(fd)
  return data
end

local function buffer_for(path)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, path)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

-- ---------- fixtures de POM ----------

local BIG_POM = table.concat({
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>com.demo</groupId>",
  "  <artifactId>demo</artifactId>",
  "  <version>1.0</version>",
  "",
  "  <!-- <dependencies>",
  "    <dependency>",
  "      <groupId>commented.out</groupId>",
  "      <artifactId>gone</artifactId>",
  "    </dependency>",
  "  </dependencies> -->",
  "",
  "  <properties>",
  "    <maven.compiler.release>21</maven.compiler.release>",
  "  </properties>",
  "",
  "  <dependencyManagement>",
  "    <dependencies>",
  "      <dependency>",
  "        <groupId>org.junit</groupId>",
  "        <artifactId>junit-bom</artifactId>",
  "        <version>5.10.0</version>",
  "        <type>pom</type>",
  "        <scope>import</scope>",
  "      </dependency>",
  "      <dependency>",
  "        <groupId>com.fasterxml.jackson.core</groupId>",
  "        <artifactId>jackson-databind</artifactId>",
  "        <version>2.17.0</version>",
  "      </dependency>",
  "    </dependencies>",
  "  </dependencyManagement>",
  "",
  "  <build>",
  "    <plugins>",
  "      <plugin>",
  "        <groupId>org.apache.maven.plugins</groupId>",
  "        <artifactId>maven-compiler-plugin</artifactId>",
  "        <dependencies>",
  "          <dependency>",
  "            <groupId>plugin.dep</groupId>",
  "            <artifactId>hidden</artifactId>",
  "          </dependency>",
  "        </dependencies>",
  "      </plugin>",
  "    </plugins>",
  "  </build>",
  "",
  "  <profiles>",
  "    <profile>",
  "      <id>extra</id>",
  "      <dependencies>",
  "        <dependency>",
  "          <groupId>profile.dep</groupId>",
  "          <artifactId>hidden</artifactId>",
  "        </dependency>",
  "      </dependencies>",
  "    </profile>",
  "  </profiles>",
  "",
  "  <dependencies>",
  "    <dependency>",
  "      <groupId>org.slf4j</groupId>",
  "      <artifactId>slf4j-api</artifactId>",
  "      <version>2.0.13</version>",
  "    </dependency>",
  "    <!-- <dependency>",
  "      <groupId>commented.inside</groupId>",
  "      <artifactId>gone</artifactId>",
  "    </dependency> -->",
  "    <dependency>",
  "      <groupId>junit</groupId>",
  "      <artifactId>junit</artifactId>",
  "      <version>4.13.2</version>",
  "      <scope>test</scope>",
  "    </dependency>",
  "  </dependencies>",
  "</project>",
}, "\n")

local MINIMAL_POM = table.concat({
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>com.java.menu.test</groupId>",
  "  <artifactId>minimal</artifactId>",
  "  <version>1.0</version>",
  "  <properties>",
  "    <maven.compiler.release>21</maven.compiler.release>",
  "  </properties>",
  "</project>",
}, "\n")

-- ---------- 1. mascaramento igual em tamanho ----------

local masked = deps._mask_xml(BIG_POM)
assert(#masked == #BIG_POM, "máscara de comentário mudou o tamanho do texto")
assert(masked:find("<!--", 1, true) == nil, "comentário XML sobreviveu à máscara")
assert(masked:find("commented.out", 1, true) == nil, "conteúdo comentado sobreviveu à máscara")
local _, orig_newlines = BIG_POM:gsub("\n", "")
local _, mask_newlines = masked:gsub("\n", "")
assert(orig_newlines == mask_newlines, "quebras de linha não foram preservadas na máscara")

local unclosed = "<project>\n<!-- nada fecha\n</project>"
local masked_unclosed = deps._mask_xml(unclosed)
assert(#masked_unclosed == #unclosed, "comentário não terminado mudou o tamanho")
assert(masked_unclosed:find("nada fecha") == nil, "comentário não terminado não foi mascarado")

local np = deps._mask_non_project_deps(BIG_POM)
assert(#np == #BIG_POM, "máscara de blocos mudou o tamanho do texto")
assert(np:find("dependencyManagement", 1, true) == nil, "dependencyManagement permaneceu visível")
assert(np:find("plugin.dep", 1, true) == nil, "dependência de plugin permaneceu visível")
assert(np:find("profile.dep", 1, true) == nil, "dependência de profile permaneceu visível")
assert(np:find("</project>", 1, true) ~= nil, "</project> foi mascarado indevidamente")
local _, top_level_blocks = np:gsub("<dependencies>", "")
assert(top_level_blocks == 1, "esperava um único bloco <dependencies> visível: " .. top_level_blocks)

-- ---------- 2. _parse_pom ----------

local parsed = deps._parse_pom(BIG_POM)
assert(#parsed.deps == 2, "esperava 2 dependências de projeto: " .. #parsed.deps)
assert(parsed.deps[1].groupId == "org.slf4j" and parsed.deps[1].artifactId == "slf4j-api")
assert(parsed.deps[1].version == "2.0.13")
assert(parsed.deps[2].groupId == "junit" and parsed.deps[2].scope == "test")
assert(#parsed.managed == 2, "esperava 2 entradas em dependencyManagement: " .. #parsed.managed)
assert(parsed.has_bom == true, "BOM import não detectado")
assert(parsed.has_parent == false, "<parent> inexistente foi detectado")
assert(parsed.has_profiles == true, "<profiles> não detectado")

assert(deps._is_exact_managed(parsed, "com.fasterxml.jackson.core", "jackson-databind") == true)
assert(deps._is_exact_managed(parsed, "org.junit", "junit-bom") == false, "o próprio BOM não conta como cobertura")
assert(deps._is_exact_managed(parsed, "org.junit.jupiter", "junit-jupiter-api") == false)
assert(deps._find_duplicate(parsed, "org.slf4j", "slf4j-api") ~= nil)
assert(deps._find_duplicate(parsed, "org.slf4j", "slf4j-simple") == nil)

for _, dep in ipairs(parsed.deps) do
  assert(dep.groupId ~= "plugin.dep", "dependência de plugin vazou para o projeto")
  assert(dep.groupId ~= "profile.dep", "dependência de profile vazou para o projeto")
  assert(dep.groupId ~= "commented.out" and dep.groupId ~= "commented.inside", "dependência comentada foi lida")
end

local minimal_parsed = deps._parse_pom(MINIMAL_POM)
assert(#minimal_parsed.deps == 0 and #minimal_parsed.managed == 0)
assert(minimal_parsed.has_parent == false and minimal_parsed.has_bom == false)
assert(minimal_parsed.has_profiles == false)

-- ---------- 3. inserção preservando bytes/comentários (LF e CRLF) ----------

local function inserted_before(original, anchor_pattern, block_lines)
  local at = original:match(".*()\n" .. anchor_pattern)
  assert(at, "âncora não encontrada: " .. anchor_pattern)
  return original:sub(1, at) .. table.concat(block_lines, "\n") .. "\n" .. original:sub(at + 1)
end

local new_text, meta, insert_err = deps._insert_maven_dependency(BIG_POM, {
  groupId = "com.example",
  artifactId = "greeter",
  version = "1.0.0",
  scope = "test",
})
assert(insert_err == nil, "inserção falhou: " .. tostring(insert_err))
assert(meta.created_section == false, "seção não deveria ter sido criada")
assert(meta.version_omitted == false and meta.bom_note == nil)

local expected = inserted_before(BIG_POM, "  </dependencies>", {
  "    <dependency>",
  "      <groupId>com.example</groupId>",
  "      <artifactId>greeter</artifactId>",
  "      <version>1.0.0</version>",
  "      <scope>test</scope>",
  "    </dependency>",
})
assert(new_text == expected, "inserção alterou bytes fora do ponto de inserção")

-- CRLF: nenhum LF puro pode aparecer e o bloco usa o mesmo terminador
local crlf_pom = BIG_POM:gsub("\n", "\r\n")
local crlf_new, crlf_meta = deps._insert_maven_dependency(crlf_pom, {
  groupId = "com.example",
  artifactId = "crlf",
  version = "2.0",
})
assert(crlf_new and crlf_meta, "inserção em CRLF falhou")
assert(crlf_new:find("[^\r]\n") == nil, "inserção introduziu LF puro em arquivo CRLF")
assert(crlf_new:find("</dependency>\r\n  </dependencies>", 1, true) ~= nil, "bloco CRLF mal posicionado")
assert(crlf_new:find("      <version>2.0</version>\r\n", 1, true) ~= nil, "linha do bloco não usa CRLF")

-- ---------- 4. indentação (2, 4 espaços e tabs) ----------

local space2 = table.concat({
  "<project>",
  "  <modelVersion>4.0.0</modelVersion>",
  "  <dependencies>",
  "    <dependency>",
  "      <groupId>org.old</groupId>",
  "      <artifactId>old</artifactId>",
  "    </dependency>",
  "  </dependencies>",
  "</project>",
}, "\n")
local unit2, section2, dep2 = deps._detect_indent(space2)
assert(unit2 == "  " and section2 == "  " and dep2 == "    ", "indentação de 2 espaços divergiu")

local space4 = table.concat({
  "<project>",
  "    <modelVersion>4.0.0</modelVersion>",
  "    <dependencies>",
  "        <dependency>",
  "            <groupId>org.old</groupId>",
  "            <artifactId>old</artifactId>",
  "        </dependency>",
  "    </dependencies>",
  "</project>",
}, "\n")
local unit4, section4, dep4 = deps._detect_indent(space4)
assert(unit4 == "    " and section4 == "    " and dep4 == "        ", "indentação de 4 espaços divergiu")
local out4 = deps._insert_maven_dependency(space4, { groupId = "com.new", artifactId = "lib", version = "2.0" })
assert(out4, "inserção em 4 espaços falhou")
assert(
  out4:find("        <dependency>\n            <groupId>com.new</groupId>\n", 1, true),
  "bloco não seguiu a indentação de 4 espaços: " .. out4
)

local tabs = table.concat({
  "<project>",
  "\t<modelVersion>4.0.0</modelVersion>",
  "\t<dependencies>",
  "\t\t<dependency>",
  "\t\t\t<groupId>org.old</groupId>",
  "\t\t\t<artifactId>old</artifactId>",
  "\t\t</dependency>",
  "\t</dependencies>",
  "</project>",
}, "\n")
local tab_unit, tab_section, tab_dep = deps._detect_indent(tabs)
assert(tab_unit == "\t" and tab_section == "\t" and tab_dep == "\t\t", "indentação com tabs divergiu")
local tab_out = deps._insert_maven_dependency(tabs, { groupId = "com.new", artifactId = "lib", version = "2.0" })
assert(tab_out, "inserção com tabs falhou")
assert(
  tab_out:find("\t\t<dependency>\n\t\t\t<groupId>com.new</groupId>\n", 1, true),
  "bloco não usou tabs: " .. tab_out
)

-- default: POM sem indentação nenhuma -> 2 espaços
local flat = "<project>\n<modelVersion>4.0.0</modelVersion>\n</project>"
local flat_unit, flat_section = deps._detect_indent(flat)
assert(flat_unit == "  " and flat_section == "  ", "default de indentação deveria ser 2 espaços")

-- ---------- 5. criação de <dependencies> antes de </project> ----------

local created, created_meta, created_err = deps._insert_maven_dependency(MINIMAL_POM, {
  groupId = "com.example",
  artifactId = "lib",
  version = "1.0",
})
assert(created_err == nil, "criação de seção falhou: " .. tostring(created_err))
assert(created_meta.created_section == true, "seção criada não foi sinalizada")
local created_expected = inserted_before(MINIMAL_POM, "</project>", {
  "  <dependencies>",
  "    <dependency>",
  "      <groupId>com.example</groupId>",
  "      <artifactId>lib</artifactId>",
  "      <version>1.0</version>",
  "    </dependency>",
  "  </dependencies>",
})
assert(created == created_expected, "seção criada alterou bytes fora do ponto de inserção")

-- comentário e dependencyManagement com </dependencies> não podem ser usados
local tricky = table.concat({
  "<project>",
  "  <modelVersion>4.0.0</modelVersion>",
  "  <dependencyManagement>",
  "    <dependencies>",
  "      <dependency>",
  "        <groupId>org.junit</groupId>",
  "        <artifactId>junit-bom</artifactId>",
  "        <version>5.10.0</version>",
  "        <type>pom</type>",
  "        <scope>import</scope>",
  "      </dependency>",
  "    </dependencies>",
  "  </dependencyManagement>",
  "  <!-- </dependencies> -->",
  "  <build>",
  "    <plugins>",
  "      <plugin>",
  "        <artifactId>p</artifactId>",
  "        <dependencies>",
  "          <dependency>",
  "            <groupId>plugin.dep</groupId>",
  "            <artifactId>hidden</artifactId>",
  "          </dependency>",
  "        </dependencies>",
  "      </plugin>",
  "    </plugins>",
  "  </build>",
  "</project>",
}, "\n")
local tricky_out, tricky_meta, tricky_err = deps._insert_maven_dependency(tricky, {
  groupId = "org.junit.jupiter",
  artifactId = "junit-jupiter-api",
})
assert(tricky_err == nil, "inserção no POM tricky falhou: " .. tostring(tricky_err))
assert(tricky_meta.created_section == true, "deveria criar a seção de projeto")
assert(tricky_meta.bom_note ~= nil and tricky_meta.bom_note:find("BOM", 1, true), "nota do BOM ausente")
local tricky_expected = inserted_before(tricky, "</project>", {
  "  <dependencies>",
  "    <dependency>",
  "      <groupId>org.junit.jupiter</groupId>",
  "      <artifactId>junit-jupiter-api</artifactId>",
  "    </dependency>",
  "  </dependencies>",
})
assert(tricky_out == tricky_expected, "bloco foi inserido no lugar errado (comentário/dependencyManagement/build)")

-- ---------- 6. dedupe, version gerenciada e BOM/parent ----------

local dup_text, dup_meta, dup_err = deps._insert_maven_dependency(BIG_POM, {
  groupId = "org.slf4j",
  artifactId = "slf4j-api",
  version = "2.0.20",
})
assert(dup_text == nil and dup_meta == nil)
assert(dup_err and dup_err:find("already declared", 1, true), "duplicata não rejeitada: " .. tostring(dup_err))

local managed_text, managed_meta, managed_err = deps._insert_maven_dependency(BIG_POM, {
  groupId = "com.fasterxml.jackson.core",
  artifactId = "jackson-databind",
})
assert(managed_text, "versão omitida deveria ser aceita para artefato gerenciado: " .. tostring(managed_err))
assert(managed_meta.version_omitted == true)
assert(managed_meta.bom_note == nil, "cobertura exata não deveria gerar ressalva")
assert(
  managed_text:find("<artifactId>jackson-databind</artifactId>\n    </dependency>", 1, true),
  "bloco gerenciado deveria sair sem <version>"
)

local bom_text, bom_meta, bom_err = deps._insert_maven_dependency(BIG_POM, {
  groupId = "org.junit.jupiter",
  artifactId = "junit-jupiter-api",
})
assert(bom_text, "versão omitida deveria ser aceita com BOM: " .. tostring(bom_err))
assert(bom_meta.version_omitted == true)
assert(type(bom_meta.bom_note) == "string" and bom_meta.bom_note:find("BOM", 1, true))

local unmanaged_text, _, unmanaged_err = deps._insert_maven_dependency(MINIMAL_POM, {
  groupId = "com.x",
  artifactId = "y",
})
assert(unmanaged_text == nil and unmanaged_err, "versão vazia sem cobertura deveria ser recusada")
assert(unmanaged_err:find("<version> is required", 1, true), "motivo da recusa divergiu: " .. unmanaged_err)

local PARENT_POM = table.concat({
  "<project>",
  "  <parent>",
  "    <groupId>com.corp</groupId>",
  "    <artifactId>parent</artifactId>",
  "    <version>1</version>",
  "  </parent>",
  "  <modelVersion>4.0.0</modelVersion>",
  "  <artifactId>child</artifactId>",
  "</project>",
}, "\n")
assert(deps._parse_pom(PARENT_POM).has_parent == true, "<parent> não detectado")
local parent_text, parent_meta, parent_err = deps._insert_maven_dependency(PARENT_POM, {
  groupId = "com.x",
  artifactId = "y",
})
assert(parent_text, "versão omitida deveria ser aceita com <parent>: " .. tostring(parent_err))
assert(parent_meta.bom_note and parent_meta.bom_note:find("<parent>", 1, true), "ressalva do parent ausente")

-- ---------- 7. validação ----------

assert(deps._validate_dep({ groupId = "com.example", artifactId = "lib", version = "1" }) == true)
for _, bad in ipairs({
  { groupId = "com<b", artifactId = "lib", version = "1" },
  { groupId = "com.example", artifactId = "li&b", version = "1" },
  { groupId = 'com"x', artifactId = "lib", version = "1" },
  { groupId = "com x", artifactId = "lib", version = "1" },
  { groupId = "com.example", artifactId = "lib", version = "1>0" },
  { groupId = "com.example", artifactId = "lib", version = "1'0" },
}) do
  local passed, err = deps._validate_dep(bad, nil)
  assert(not passed and err and err:find("invalid", 1, true), "valor inválido aceito: " .. vim.inspect(bad))
end

local _, scope_err = deps._validate_dep({ groupId = "a", artifactId = "b", version = "1", scope = "weird" })
assert(scope_err and scope_err:find("invalid scope", 1, true), "scope inválido aceito")
assert(deps._validate_dep({ groupId = "a", artifactId = "b", version = "1", scope = "" }) == true)
assert(deps._validate_dep({ groupId = "a", artifactId = "b", version = "1", scope = "provided" }) == true)

-- ---------- 8. _write_pom (buffer modificado e escrita atômica) ----------

local write_dir = tempdir("write")
local write_pom = write_dir .. "/pom.xml"
write_raw(write_pom, MINIMAL_POM)

local pom_buf = buffer_for(write_pom)
vim.api.nvim_buf_set_lines(pom_buf, 0, -1, false, { "<project>", "</project>" })
vim.bo[pom_buf].modified = true

local refused, refused_err = deps._write_pom(write_pom, "alterado")
assert(refused == nil, "escrita deveria ser recusada com buffer modificado")
assert(
  refused_err and refused_err:find("unsaved changes", 1, true),
  "motivo da recusa divergiu: " .. tostring(refused_err)
)
assert(read_raw(write_pom) == MINIMAL_POM, "arquivo em disco foi alterado apesar da recusa")

vim.bo[pom_buf].modified = false
local sentinel = MINIMAL_POM .. "\n<!-- sentinel -->"
local wrote, wrote_err = deps._write_pom(write_pom, sentinel)
assert(wrote, "escrita atômica falhou: " .. tostring(wrote_err))
assert(read_raw(write_pom) == sentinel, "conteúdo em disco divergiu do texto escrito")
assert(vim.uv.fs_stat(write_pom .. ".java-menu-tmp") == nil, "arquivo temporário ficou para trás")
local reloaded = table.concat(vim.api.nvim_buf_get_lines(pom_buf, 0, -1, false), "\n")
assert(reloaded:find("sentinel", 1, true), "buffer limpo não foi recarregado do disco")
vim.api.nvim_buf_delete(pom_buf, { force = true })

-- ---------- 9. Maven Central (helpers puros) ----------

assert(deps._http_tool(function()
  return false
end) == nil)
assert(deps._http_tool(function(exe)
  return exe == "wget"
end) == "wget")
assert(deps._http_tool(function(exe)
  return exe == "curl"
end) == "curl")

assert(
  deps._maven_search_url("junit") == "https://search.maven.org/solrsearch/select?q=junit&rows=15&wt=json",
  "URL de busca divergiu: " .. deps._maven_search_url("junit")
)
local gav_url = deps._maven_search_url("g:org.junit.jupiter AND a:junit-jupiter-api", { gav = true })
assert(
  gav_url:find("q=g%3Aorg.junit.jupiter+AND+a%3Ajunit-jupiter-api", 1, true),
  "query gav não foi codificada: " .. gav_url
)
assert(gav_url:find("core=gav", 1, true) and gav_url:find("rows=20", 1, true), "parâmetros gav ausentes: " .. gav_url)

local results, parse_err = deps._parse_maven_search(
  '{"response":{"numFound":1,"docs":[{"g":"org.slf4j","a":"slf4j-api","latestVersion":"2.0.20","p":"jar"}]}}'
)
assert(parse_err == nil, "parse falhou: " .. tostring(parse_err))
assert(#results == 1 and results[1].groupId == "org.slf4j" and results[1].artifactId == "slf4j-api")
assert(results[1].version == "2.0.20" and results[1].packaging == "jar")

local gav_results = deps._parse_maven_search('{"response":{"docs":[{"g":"x","a":"y","v":"1.1"}]}}')
assert(gav_results and gav_results[1].version == "1.1", "campo v do core=gav não lido")

local empty_results, empty_err = deps._parse_maven_search('{"response":{"numFound":0,"docs":[]}}')
assert(empty_err == nil and #empty_results == 0, "resposta vazia deveria ser lista vazia")

local bad_results, bad_err = deps._parse_maven_search("não é json")
assert(bad_results == nil and bad_err and bad_err:find("invalid", 1, true), "JSON inválido aceito")

local empty_doc, empty_doc_err = deps._parse_maven_search("")
assert(empty_doc == nil and empty_doc_err ~= nil, "resposta vazia deveria falhar")
local unexpected, unexpected_err = deps._parse_maven_search('{"error":"x"}')
assert(unexpected == nil and unexpected_err ~= nil, "resposta sem response.docs aceita")

-- ---------- 10. catalogs e Gradle estático ----------

local catalog_text = table.concat({
  "[versions]",
  'junit = "5.10.0"',
  'jackson = "2.17.0"',
  "",
  "[libraries]",
  'junit-jupiter = { module = "org.junit.jupiter:junit-jupiter", version.ref = "junit" }',
  'jackson-databind = { group = "com.fasterxml.jackson.core", name = "jackson-databind", version.ref = "jackson" }',
  'slf4j = "org.slf4j:slf4j-api:2.0.20"',
  'managed = "com.example:managed"',
  'broken = { module = "only-group" }',
  "",
  "[bundles]",
  "testing = []",
}, "\n")

local catalog = deps._parse_version_catalog(catalog_text)
assert(catalog.versions.junit == "5.10.0" and catalog.versions.jackson == "2.17.0")
assert(#catalog.libraries == 5, "esperava 5 libraries: " .. #catalog.libraries)
assert(catalog.by_alias["junit-jupiter"].groupId == "org.junit.jupiter")
assert(catalog.by_alias["junit-jupiter"].version == "5.10.0")
assert(catalog.by_alias["jackson-databind"].groupId == "com.fasterxml.jackson.core")
assert(catalog.by_alias["jackson-databind"].version == "2.17.0")
assert(catalog.by_alias["slf4j"].version == "2.0.20")
assert(catalog.by_alias["managed"].version == nil, "coordenada sem versão ganhou versão")
assert(catalog.by_alias["broken"].note ~= nil, "entrada inválida do catálogo sem nota")

local gradle_catalog = deps._parse_version_catalog(table.concat({
  "[versions]",
  'junit = "5.10.0"',
  "",
  "[libraries]",
  'junit-jupiter = { module = "org.junit.jupiter:junit-jupiter", version.ref = "junit" }',
  'jackson-databind = "com.fasterxml.jackson.core:jackson-databind:2.17.0"',
}, "\n"))

local build_gradle = table.concat({
  "plugins {",
  "  id 'java'",
  "}",
  "/* implementation 'ignored:a:1.0' */",
  "dependencies {",
  "  implementation 'org.slf4j:slf4j-api:2.0.20'",
  '  api("com.google.guava:guava:33.0.0-jre")',
  "  // testImplementation 'commented:out:1.0'",
  "  compileOnly 'org.projectlombok:lombok'",
  "  testImplementation(libs.junit.jupiter)",
  "  implementation libs.jackson.databind",
  "  implementation platform('org.springframework.boot:spring-boot-dependencies:3.2.0')",
  "  implementation project(':core')",
  '  runtimeOnly "com.dyn:$version"',
  "  runtimeOnly files('libs/local.jar')",
  "}",
}, "\n")

local gradle_deps, gradle_notes = deps._parse_gradle_dependencies(build_gradle, gradle_catalog)
local function gradle_find(list, group, artifact)
  for _, entry in ipairs(list) do
    if entry.groupId == group and entry.artifactId == artifact then
      return entry
    end
  end
end

assert(gradle_find(gradle_deps, "org.slf4j", "slf4j-api").version == "2.0.20", "aspa simples não lida")
assert(
  gradle_find(gradle_deps, "com.google.guava", "guava").version == "33.0.0-jre",
  "aspa dupla com parênteses não lida"
)
assert(
  gradle_find(gradle_deps, "org.projectlombok", "lombok").version == nil,
  "coordenada sem versão deveria continuar sem versão"
)
local resolved_junit = gradle_find(gradle_deps, "org.junit.jupiter", "junit-jupiter")
assert(resolved_junit and resolved_junit.version == "5.10.0", "alias libs.junit.jupiter não resolvido no catálogo")
local resolved_jackson = gradle_find(gradle_deps, "com.fasterxml.jackson.core", "jackson-databind")
assert(resolved_jackson and resolved_jackson.version == "2.17.0", "alias libs.jackson.databind não resolvido")
assert(resolved_junit.configuration == "testImplementation", "configuração não registrada")
assert(gradle_find(gradle_deps, "ignored", "a") == nil, "comentário de bloco foi lido")
assert(gradle_find(gradle_deps, "commented", "out") == nil, "comentário de linha foi lido")

for _, needle in ipairs({ "platform", "project", "variable", "file" }) do
  local found = false
  for _, note in ipairs(gradle_notes) do
    if note:find(needle, 1, true) then
      found = true
      break
    end
  end
  assert(found, "nota ausente para '" .. needle .. "': " .. vim.inspect(gradle_notes))
end

-- alias sem catálogo: relata limitação em vez de inventar coordenadas
local no_catalog_deps, no_catalog_notes = deps._parse_gradle_dependencies("implementation libs.unknown.alias", nil)
assert(#no_catalog_deps == 0, "alias sem catálogo não pode virar dependência")
assert(#no_catalog_notes == 1 and no_catalog_notes[1]:find("catalog alias not resolved", 1, true))

-- ---------- 11. resolução de alvo ----------

local root, main_path = fixtures.maven_project("deps", "com.deps", "App")
local buf = buffer_for(main_path)
local target = deps._resolve_target(buf)
local real_root = vim.fs.normalize(vim.uv.fs_realpath(root))
assert(target, "target não resolvido para projeto Maven")
assert(target.tool == "maven", "tool divergiu: " .. tostring(target.tool))
assert(target.root == real_root, "root divergiu: " .. tostring(target.root))
assert(target.module == real_root, "module divergiu: " .. tostring(target.module))
assert(target.build_file == real_root .. "/pom.xml", "build_file divergiu: " .. tostring(target.build_file))
assert(target.is_kotlin_dsl == false and target.catalog_file == nil)
assert(#target.modules == 1, "esperava um módulo: " .. #target.modules)

local available, available_reason = deps._available(buf)
assert(available == true and available_reason == nil, "projeto Maven deveria permitir Dependencies")

local empty_dir = tempdir("empty")
local prev_cwd = vim.uv.cwd()
vim.cmd.cd(vim.fn.fnameescape(empty_dir))
local empty_buf = vim.api.nvim_create_buf(false, true)
local unavailable, unavailable_reason = deps._available(empty_buf)
assert(unavailable == false, "diretório vazio deveria desabilitar Dependencies")
assert(
  unavailable_reason and unavailable_reason:find("no Maven/Gradle project", 1, true),
  "motivo divergiu: " .. tostring(unavailable_reason)
)
assert(deps._resolve_target(empty_buf) == nil, "target inventado sem projeto")
vim.cmd.cd(vim.fn.fnameescape(prev_cwd))

local nested_root, mods = fixtures.maven_nested("deps")
local api_buf = buffer_for(mods.api .. "/src/main/java/com/nest/api/Thing.java")
local nested_target = deps._resolve_target(api_buf)
local api_real = vim.fs.normalize(vim.uv.fs_realpath(mods.api))
assert(nested_target.module == api_real, "módulo mais específico não escolhido: " .. nested_target.module)
assert(#nested_target.modules == 5, "esperava 5 módulos: " .. #nested_target.modules)
local explicit = deps._resolve_target(api_buf, mods.core)
assert(
  explicit.module == vim.fs.normalize(vim.uv.fs_realpath(mods.core)),
  "módulo explícito não respeitado: " .. explicit.module
)
assert(explicit.build_file == explicit.module .. "/pom.xml")

-- ---------- 12. relatório (read-only) ----------

local report_dir = tempdir("report")
write_raw(report_dir .. "/pom.xml", BIG_POM)
local report_target = {
  root = report_dir,
  tool = "maven",
  modules = { report_dir },
  module = report_dir,
  build_file = report_dir .. "/pom.xml",
  is_kotlin_dsl = false,
}
local report_text = table.concat(deps._report_lines(report_target), "\n")
assert(report_text:find("Root: " .. report_dir, 1, true), "root ausente no relatório")
assert(report_text:find("Build file: pom.xml", 1, true), "build file ausente no relatório")
assert(report_text:find("Parent: none", 1, true), "parent divergiu no relatório")
assert(report_text:find("Dependency management: 2 entries", 1, true), "dependencyManagement divergiu")
assert(report_text:find("BOM: import detected", 1, true), "BOM ausente no relatório")
assert(report_text:find("Profiles: present", 1, true), "profiles ausente no relatório")
assert(report_text:find("Dependencies: 2", 1, true), "contagem de dependências divergiu")
assert(report_text:find("org.slf4j:slf4j-api:2.0.13", 1, true), "dependência ausente no relatório")
assert(report_text:find("scope=test", 1, true), "scope ausente no relatório")

local minimal_report = table.concat(
  deps._report_lines({
    root = write_dir,
    tool = "maven",
    modules = { write_dir },
    module = write_dir,
    build_file = write_pom,
    is_kotlin_dsl = false,
  }),
  "\n"
)
assert(minimal_report:find("Dependencies: 0", 1, true))
assert(minimal_report:find("  (none)", 1, true))

-- Kotlin DSL: limitação honesta + catálogo ainda visível
local kts_dir = tempdir("kts")
write_raw(kts_dir .. "/settings.gradle.kts", 'rootProject.name = "kts"\n')
write_raw(kts_dir .. "/build.gradle.kts", 'dependencies {\n  implementation("org.slf4j:slf4j-api:2.0.20")\n}\n')
write_raw(kts_dir .. "/gradle/libs.versions.toml", catalog_text)
local kts_buf = buffer_for(kts_dir .. "/build.gradle.kts")
local kts_target = deps._resolve_target(kts_buf)
assert(kts_target and kts_target.tool == "gradle", "projeto Gradle não resolvido")
assert(kts_target.is_kotlin_dsl == true, "build.gradle.kts não marcado como Kotlin DSL")
assert(kts_target.catalog_file ~= nil, "libs.versions.toml não encontrado")
local kts_report = table.concat(deps._report_lines(kts_target), "\n")
assert(kts_report:find("Kotlin DSL", 1, true), "limitação do Kotlin DSL ausente")
assert(kts_report:find("Version catalog", 1, true), "catálogo ausente no relatório .kts")
assert(kts_report:find("junit-jupiter", 1, true), "libraries do catálogo ausentes no relatório .kts")
assert(not kts_report:find("implementation org.slf4j", 1, true), "relatório fingiu parsear build.gradle.kts")

-- Gradle Groovy via fixtures
local gradle_root = fixtures.gradle_project("deps", { 'rootProject.name = "deps-gradle"' })
write_raw(gradle_root .. "/build.gradle", "dependencies {\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n}\n")
local gradle_buf = buffer_for(gradle_root .. "/build.gradle")
local gradle_target = deps._resolve_target(gradle_buf)
assert(gradle_target and gradle_target.tool == "gradle" and gradle_target.is_kotlin_dsl == false)
local gradle_report = table.concat(deps._report_lines(gradle_target), "\n")
assert(
  gradle_report:find("implementation org.slf4j:slf4j-api:2.0.20", 1, true),
  "dependência Groovy ausente no relatório: " .. gradle_report
)
assert(gradle_report:find("Version catalog: none", 1, true))

-- Estes testes interativos vivem em uma função própria: o chunk principal já
-- usa o limite de 200 variáveis locais do Lua.
local function interactive_spec()
  -- ---------- 13. sync JDTLS (H1) ----------

  local scratch = vim.api.nvim_create_buf(false, true)
  local sync_done
  local started, reason = deps._sync_jdtls(scratch, "/tmp/nao-existe/pom.xml", function(ok, err)
    sync_done = { ok = ok, err = err }
  end)
  assert(started == false, "sync deveria falhar sem cliente")
  assert(reason and reason:find("not attached", 1, true), "motivo sem cliente divergiu: " .. tostring(reason))
  assert(sync_done and sync_done.ok == false and sync_done.err == reason, "callback sem cliente não recebeu o motivo")

  local real_client = lsp.client
  local captured_request
  local stub_client = {
    request = function(_, method, params, handler, request_buf)
      captured_request = { method = method, params = params, buf = request_buf }
      handler(nil)
    end,
  }
  lsp.client = function()
    return stub_client
  end

  local pom_to_sync = real_root .. "/pom.xml"
  local done
  local started_ok = deps._sync_jdtls(buf, pom_to_sync, function(ok, err)
    done = { ok = ok, err = err }
  end)
  assert(started_ok == true, "sync deveria iniciar com cliente anexado")
  assert(captured_request, "request não foi disparado")
  assert(
    captured_request.method == "java/projectConfigurationUpdate",
    "método LSP divergiu: " .. tostring(captured_request.method)
  )
  assert(captured_request.params.uri == vim.uri_from_fname(pom_to_sync), "URI do build file divergiu")
  assert(captured_request.buf == buf, "request não foi direcionado ao buffer")
  assert(
    vim.wait(2000, function()
      return done ~= nil
    end),
    "callback do sync não rodou"
  )
  assert(done.ok == true and done.err == nil, "erro no callback do sync: " .. tostring(done.err))

  local failing_client = {
    request = function(_, _, _, handler)
      handler({ message = "boom" })
    end,
  }
  lsp.client = function()
    return failing_client
  end
  local failed
  deps._sync_jdtls(buf, pom_to_sync, function(ok, err)
    failed = { ok = ok, err = err }
  end)
  assert(
    vim.wait(2000, function()
      return failed ~= nil
    end),
    "callback de erro não rodou"
  )
  assert(failed.ok == false and failed.err == "boom", "erro do LSP não foi propagado")
  lsp.client = real_client

  -- jdtls >= 1.63 declara o handler como void: o request volta com "Internal
  -- error" de framing, mas o job de reimportação começou. Isso não é falha.
  local void_client = {
    request = function(_, _, _, handler)
      handler({
        code = -32603,
        message = "Internal error.",
        data = "java.lang.IllegalStateException: Local endpoint returned null from its request method, whereas an instance of CompletableFuture is expected\n",
      })
    end,
  }
  lsp.client = function()
    return void_client
  end
  local void_result
  deps._sync_jdtls(buf, pom_to_sync, function(ok, err)
    void_result = { ok = ok, err = err }
  end)
  assert(
    vim.wait(2000, function()
      return void_result ~= nil
    end),
    "callback do handler void não rodou"
  )
  assert(
    void_result.ok == true and void_result.err == nil,
    "erro de framing do handler void não deveria ser reportado como falha: " .. tostring(void_result.err)
  )
  lsp.client = real_client

  -- ---------- 14. shell: menu (Gradle desabilita Add, Maven habilita) ----------

  stub_ui({ "Add dependency" }, {})
  notices = {}
  deps.menu(gradle_buf)
  assert(#select_calls == 1, "menu Gradle deveria abrir uma vez: " .. #select_calls)
  local gradle_menu = table.concat(select_calls[1].items, "\n")
  assert(
    gradle_menu:find("Add dependency…  (unavailable: Gradle build file editing is not supported", 1, true),
    "Add dependency deveria estar desabilitado no Gradle: " .. gradle_menu
  )
  assert(gradle_menu:find("Open build.gradle\n", 1, true) or gradle_menu:find("Open build.gradle", 1, true))
  assert(not gradle_menu:find("Open build.gradle[^\n]*(unavailable", 1), "Open build file deveria estar habilitado")
  assert(
    gradle_menu:find("Sync JDTLS  (unavailable: jdtls is not attached to this buffer)", 1, true),
    "Sync deveria estar desabilitado sem cliente"
  )
  assert(has_notice("read-only MVP"), "escolher a entrada desabilitada deveria avisar: " .. last_notice())

  vim.api.nvim_set_current_buf(buf)
  stub_ui({ "List dependencies" }, {})
  deps.menu(buf)
  local report_buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[report_buf].buftype == "nofile", "List deveria abrir um buffer nofile")
  assert(vim.bo[report_buf].modifiable == false, "relatório deveria ser read-only")
  local list_lines = table.concat(vim.api.nvim_buf_get_lines(report_buf, 0, -1, false), "\n")
  vim.cmd("close")
  assert(list_lines:find("Build file: pom.xml", 1, true), "List não abriu o relatório do POM")
  assert(list_lines:find("Dependencies: 0", 1, true))

  -- cancelar no menu não escreve nada
  local menu_cancel_root, menu_cancel_main = fixtures.maven_project("deps-menu-cancel", "com.deps.mc", "App")
  local menu_cancel_buf = buffer_for(menu_cancel_main)
  local menu_cancel_pom = menu_cancel_root .. "/pom.xml"
  local menu_cancel_before = read_raw(menu_cancel_pom)
  stub_ui({}, {})
  deps.menu(menu_cancel_buf)
  assert(#select_calls == 1, "menu deveria ter sido exibido")
  assert(read_raw(menu_cancel_pom) == menu_cancel_before, "cancelar no menu escreveu no pom.xml")

  -- ---------- 15. shell: add manual ----------

  local add_root, add_main = fixtures.maven_project("deps-add", "com.deps.add", "App")
  local add_buf = buffer_for(add_main)
  local add_pom = add_root .. "/pom.xml"
  local add_before = read_raw(add_pom)

  stub_ui(
    { "Add dependency", "Enter coordinates manually", "test", "✔ Add dependency" },
    { "com.example", "greeter", "1.0.0" }
  )
  notices = {}
  deps.menu(add_buf)

  local add_after = read_raw(add_pom)
  assert(add_after ~= add_before, "pom.xml não foi alterado")
  assert(add_after:find("<artifactId>greeter</artifactId>", 1, true), "artifactId não foi escrito")
  assert(add_after:find("<version>1.0.0</version>", 1, true), "versão não foi escrita")
  assert(add_after:find("<scope>test</scope>", 1, true), "scope test não foi escrito")
  assert(add_after:find("  <dependencies>", 1, true), "seção de dependências não foi criada")
  assert(add_after:find("<artifactId>deps-add</artifactId>", 1, true), "resto do POM foi perdido")
  assert(has_notice("added com.example:greeter:1.0.0"), "sucesso não notificado: " .. last_notice())
  assert(not has_notice("JDTLS"), "sync não deveria rodar sem cliente: " .. last_notice())
  assert(#input_calls == 3, "esperava 3 prompts de texto: " .. #input_calls)

  -- cancelar (Esc) no groupId não escreve nada
  local cancel_root, cancel_main = fixtures.maven_project("deps-cancel", "com.deps.cancel", "App")
  local cancel_buf = buffer_for(cancel_main)
  local cancel_pom = cancel_root .. "/pom.xml"
  local cancel_before = read_raw(cancel_pom)
  stub_ui({ "Add dependency", "Enter coordinates manually" }, { false })
  notices = {}
  deps.menu(cancel_buf)
  assert(read_raw(cancel_pom) == cancel_before, "cancelar no groupId escreveu no pom.xml")
  assert(not has_notice("added "), "cancelamento não pode notificar sucesso")

  -- ---------- 16. shell: fallback da busca online ----------

  local real_search = deps._search_maven
  local search_root, search_main = fixtures.maven_project("deps-search", "com.deps.search", "App")
  local search_buf = buffer_for(search_main)
  local search_pom = search_root .. "/pom.xml"
  local search_before = read_raw(search_pom)

  deps._search_maven = function(_, on_done)
    on_done(nil, "no network")
  end
  stub_ui({ "Add dependency", "Search Maven Central", "Cancel" }, { "junit" })
  notices = {}
  deps.menu(search_buf)
  assert(read_raw(search_pom) == search_before, "falha de busca + Cancel escreveu no pom.xml")
  assert(has_notice("search failed"), "falha de rede não notificada: " .. last_notice())

  -- falha de busca -> entradas manuais continuam disponíveis
  deps._search_maven = function(_, on_done)
    on_done(nil, "no network")
  end
  stub_ui(
    { "Add dependency", "Search Maven Central", "Enter manually", "compile (default)", "✔ Add dependency" },
    { "junit", "org.junit.jupiter", "junit-jupiter-api", "5.10.0" }
  )
  deps.menu(search_buf)
  assert(
    read_raw(search_pom):find("<artifactId>junit-jupiter-api</artifactId>", 1, true),
    "fallback manual após falha de busca não escreveu"
  )

  -- busca com resultados (injetada, sem rede): versão vem do resultado
  local result_root, result_main = fixtures.maven_project("deps-result", "com.deps.result", "App")
  local result_buf = buffer_for(result_main)
  local result_pom = result_root .. "/pom.xml"
  deps._search_maven = function(_, on_done)
    on_done({ { groupId = "org.slf4j", artifactId = "slf4j-api", version = "2.0.20", packaging = "jar" } }, nil)
  end
  stub_ui({ "Add dependency", "Search Maven Central", "slf4j-api:", "runtime", "✔ Add dependency" }, { "slf4j" })
  deps.menu(result_buf)
  deps._search_maven = real_search
  local result_text = read_raw(result_pom)
  assert(result_text:find("<artifactId>slf4j-api</artifactId>", 1, true), "resultado da busca não foi usado")
  assert(result_text:find("<version>2.0.20</version>", 1, true), "versão do resultado não foi usada")
  assert(result_text:find("<scope>runtime</scope>", 1, true), "scope runtime não foi escrito")

  -- ---------- 17. shell: add com cliente JDTLS anexado dispara o sync ----------

  local sync_add_root, sync_add_main = fixtures.maven_project("deps-sync-add", "com.deps.sync", "App")
  local sync_add_buf = buffer_for(sync_add_main)
  local sync_add_pom = sync_add_root .. "/pom.xml"
  local requested
  local add_client = {
    request = function(_, method, params, handler, request_buf)
      requested = { method = method, params = params, buf = request_buf }
      handler(nil)
    end,
  }
  lsp.client = function()
    return add_client
  end

  stub_ui(
    { "Add dependency", "Enter coordinates manually", "compile (default)", "✔ Add dependency" },
    { "com.example", "synced", "2.0" }
  )
  deps.menu(sync_add_buf)
  assert(
    vim.wait(2000, function()
      return requested ~= nil
    end),
    "sync não foi disparado após o add"
  )
  assert(requested.method == "java/projectConfigurationUpdate", "método do sync divergiu")
  assert(requested.params.uri == vim.uri_from_fname(sync_add_pom), "URI do sync divergiu")
  assert(requested.buf == sync_add_buf, "sync não foi direcionado ao buffer")
  lsp.client = real_client
  local synced_text = read_raw(sync_add_pom)
  assert(synced_text:find("<artifactId>synced</artifactId>", 1, true))
  assert(not synced_text:find("<scope>compile</scope>", 1, true), "scope default não deveria ser escrito")

  -- ---------- 18. menu multi-módulo oferece escolha ----------

  stub_ui({ "libraries/core" }, {})
  deps.menu(api_buf)
  assert(#select_calls == 2, "escolha de módulo + menu do módulo: " .. #select_calls)
  local module_picker = table.concat(select_calls[1].items, "\n")
  assert(module_picker:find("services/api (current)", 1, true), "módulo atual não marcado: " .. module_picker)
  assert(module_picker:find("libraries/core", 1, true), "outros módulos não listados")
  assert(select_calls[1].items[1]:find("(current)", 1, true), "módulo atual deveria vir primeiro")
end

interactive_spec()

-- ---------- restauração ----------

vim.ui.select = real_select
vim.ui.input = real_input
vim.notify = real_notify
lsp.client = real_client
for _, dir in ipairs(temp_dirs) do
  vim.fn.delete(dir, "rf")
end

print(
  "deps_spec: OK (parsing/dedupe/BOM, inserção byte-a-byte LF+CRLF+indentação, escrita atômica, "
    .. "Maven Central, Gradle estático, sync só com cliente, add/menu sem escrita ao cancelar)"
)
vim.cmd("qa!")
