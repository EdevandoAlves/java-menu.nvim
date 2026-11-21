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

local available, available_reason = deps.available(buf)
assert(available == true and available_reason == nil, "projeto Maven deveria permitir Dependencies")

local empty_dir = tempdir("empty")
local prev_cwd = vim.uv.cwd()
vim.cmd.cd(vim.fn.fnameescape(empty_dir))
local empty_buf = vim.api.nvim_create_buf(false, true)
local unavailable, unavailable_reason = deps.available(empty_buf)
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

-- Kotlin DSL: parse estático seguro + catálogo + cobertura parcial honesta
local kts_dir = tempdir("kts")
write_raw(kts_dir .. "/settings.gradle.kts", 'rootProject.name = "kts"\n')
write_raw(
  kts_dir .. "/build.gradle.kts",
  table.concat({
    "dependencies {",
    '  implementation("org.slf4j:slf4j-api:2.0.20")',
    "  testImplementation(libs.junit.jupiter)",
    '  implementation(project(":core"))',
    "}",
    "",
  }, "\n")
)
write_raw(kts_dir .. "/gradle/libs.versions.toml", catalog_text)
local kts_buf = buffer_for(kts_dir .. "/build.gradle.kts")
local kts_target = deps._resolve_target(kts_buf)
assert(kts_target and kts_target.tool == "gradle", "projeto Gradle não resolvido")
assert(kts_target.is_kotlin_dsl == true, "build.gradle.kts não marcado como Kotlin DSL")
assert(kts_target.catalog_file ~= nil, "libs.versions.toml não encontrado")
local kts_report = table.concat(deps._report_lines(kts_target), "\n")
assert(kts_report:find("Build file: build.gradle.kts", 1, true), "build file .kts ausente no relatório")
assert(
  kts_report:find("Dependencies: 2 (static parse of build.gradle.kts)", 1, true),
  "contagem de dependências .kts divergiu:\n" .. kts_report
)
assert(kts_report:find("implementation org.slf4j:slf4j-api:2.0.20", 1, true), "dep literal .kts ausente")
assert(kts_report:find("testImplementation org.junit.jupiter:junit-jupiter:5.10.0", 1, true), "alias .kts ausente")
assert(kts_report:find("Coverage: partial", 1, true), "marcador de cobertura parcial ausente no .kts")
assert(kts_report:find("Note: project dependency not resolved", 1, true), "nota de project() ausente no .kts")
assert(kts_report:find("Version catalog", 1, true), "catálogo ausente no relatório .kts")
assert(kts_report:find("junit-jupiter", 1, true), "libraries do catálogo ausentes no relatório .kts")

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

local function kotlin_dsl_spec()
  -- ---------- 12b. Kotlin DSL: mascaramento, literais, catálogo, multiline e formas dinâmicas ----------

  -- 1) Mascaramento de comentários e preservação de strings/chars
  local raw_kts = table.concat({
    '/* outer /* nested implementation("fake:nested:1.0") */ still comment */',
    'val url = "https://example.com/*not-comment*/"',
    'val escaped = "quote \\" // not comment"',
    'val rawStr = """// keep inside raw string /* keep */"""',
    "val ch = '\"'",
    '// implementation("fake:line:1.0")',
    "dependencies {",
    '  implementation("org.slf4j:slf4j-api:2.0.20") // inline comment',
    "}",
  }, "\n")
  local masked_kts, has_unterm = deps._mask_kotlin(raw_kts)
  assert(has_unterm == false, "comentário fechado foi marcado como não terminado")
  assert(#masked_kts == #raw_kts, "mascaramento Kotlin mudou o tamanho em bytes")
  local _, raw_nl = raw_kts:gsub("\n", "")
  local _, mask_nl = masked_kts:gsub("\n", "")
  assert(raw_nl == mask_nl, "mascaramento Kotlin não preservou quebras de linha")
  assert(masked_kts:find("fake:nested", 1, true) == nil, "comentário aninhado vazou")
  assert(masked_kts:find("fake:line", 1, true) == nil, "comentário de linha vazou")
  assert(masked_kts:find("https://example.com/*not-comment*/", 1, true) ~= nil, "string com // e /* foi mascarada")
  assert(masked_kts:find("// keep inside raw string", 1, true) ~= nil, "raw string com // foi mascarada")

  local unterm_kts, unterm_flag = deps._mask_kotlin('dependencies {\n  /* unclosed\n  implementation("x:y:1")\n}')
  assert(unterm_flag == true, "comentário não terminado não foi sinalizado")
  assert(#unterm_kts == #'dependencies {\n  /* unclosed\n  implementation("x:y:1")\n}')
  assert(unterm_kts:find("x:y:1", 1, true) == nil, "comentário não terminado não foi mascarado")

  -- 2) Literais, multiline, argumentos nomeados/posicionais, blocos e catálogo
  local mixed_catalog = deps._parse_version_catalog(table.concat({
    "[versions]",
    'junit = "5.10.0"',
    "",
    "[libraries]",
    'junit-jupiter = { module = "org.junit.jupiter:junit-jupiter", version.ref = "junit" }',
    'spring-boot_starter-web = { group = "org.springframework.boot", name = "spring-boot-starter-web" }',
    'slf4j = "org.slf4j:slf4j-api:2.0.20"',
  }, "\n"))

  local full_kts = table.concat({
    "plugins {",
    "  java",
    "  alias(libs.plugins.spring.boot)",
    "}",
    "",
    "buildscript {",
    "  dependencies {",
    '    classpath("com.example:build-plugin:1.2.3")',
    "  }",
    "}",
    "",
    "configurations {",
    "  implementation {",
    '    exclude(group = "ch.qos.logback")',
    "  }",
    "}",
    "",
    'val fake = "dependencies { implementation(\\"fake:in-string:9.9\\") }"',
    "",
    "subprojects {",
    "  dependencies {",
    '    implementation("com.sub:sub-only:1.0.0")',
    "  }",
    "}",
    "",
    "dependencies {",
    '  implementation("org.slf4j:slf4j-api:2.0.20")',
    '  api("org.projectlombok:lombok")',
    '  implementation("""com.google.guava:guava:33.0.0-jre""")',
    "  implementation(",
    "      // multiline com vírgula final e comentário",
    '      "org.apache.commons:commons-lang3:3.14.0",',
    "  )",
    "  testImplementation(",
    '      group = "org.junit.jupiter",',
    '      name = "junit-jupiter-api",',
    '      version = "5.10.0",',
    "  ) {",
    "      isTransitive = false",
    "  }",
    '  compileOnlyApi("com.example", "pos-lib", "2.1.0")',
    '  developmentOnly("com.example:escaped\\$dollar:1.0.0")',
    "  testImplementation(libs.junit.jupiter)",
    "  implementation(libs.spring.boot.starter.web)",
    "  constraints {",
    '    implementation("org.apache.logging.log4j:log4j-core:2.20.0")',
    "  }",
    '  if (hasProperty("extra")) {',
    '    runtimeOnly("com.example:conditional:1.0.0")',
    "  }",
    "}",
  }, "\n")

  local kdeps, knotes = deps._parse_kotlin_gradle_dependencies(full_kts, mixed_catalog)
  local function kfind(group, artifact)
    for _, entry in ipairs(kdeps) do
      if entry.groupId == group and entry.artifactId == artifact then
        return entry
      end
    end
  end

  assert(kfind("com.example", "build-plugin").configuration == "classpath", "buildscript classpath não lido")
  assert(kfind("org.slf4j", "slf4j-api").version == "2.0.20", "literal básico .kts não lido")
  assert(kfind("org.projectlombok", "lombok").version == nil, "literal sem versão ganhou versão")
  assert(kfind("com.google.guava", "guava").version == "33.0.0-jre", "triple-quoted string não lida")
  assert(kfind("org.apache.commons", "commons-lang3").version == "3.14.0", "chamada multiline com vírgula falhou")
  local junit_api = kfind("org.junit.jupiter", "junit-jupiter-api")
  assert(
    junit_api
      and junit_api.configuration == "testImplementation"
      and junit_api.version == nil
      and junit_api.declared_version == "5.10.0"
      and junit_api.has_configuration_lambda == true,
    "argumentos nomeados multiline + lambda falharam"
  )
  local pos_lib = kfind("com.example", "pos-lib")
  assert(
    pos_lib and pos_lib.configuration == "compileOnlyApi" and pos_lib.version == "2.1.0",
    "posicional 3-args falhou"
  )
  assert(
    kfind("com.example", "escaped$dollar") ~= nil,
    "cifrão escapado \\$ não deveria ser tratado como interpolação"
  )
  assert(kfind("org.junit.jupiter", "junit-jupiter").version == "5.10.0", "alias libs.junit.jupiter falhou")
  local boot_web = kfind("org.springframework.boot", "spring-boot-starter-web")
  assert(boot_web and boot_web.version == nil, "alias misto spring-boot_starter-web sem versão falhou")

  assert(kfind("fake", "in-string") == nil, "string simulando dependencies {} vazou")
  assert(kfind("com.sub", "sub-only") == nil, "dependência de subprojects vazou para o módulo raiz")
  assert(kfind("org.apache.logging.log4j", "log4j-core") == nil, "constraints vazou como dependência direta")
  assert(kfind("com.example", "conditional") == nil, "dependência dentro de if() vazou")

  local joined_notes = table.concat(knotes, "\n")
  assert(
    joined_notes:find("scoped or conditional dependencies block not resolved", 1, true),
    "nota de subprojects ausente"
  )
  assert(joined_notes:find("dependency constraints block not resolved", 1, true), "nota de constraints ausente")
  assert(joined_notes:find("conditional or loop block in dependencies not resolved", 1, true), "nota de if() ausente")
  assert(
    joined_notes:find("dependency configuration lambda not evaluated", 1, true),
    "nota de lambda de configuração ausente"
  )

  -- 3) Formas dinâmicas, interpoladas e não suportadas: sempre parciais, nunca inventam dependências
  local dynamic_kts = table.concat({
    "dependencies {",
    '  val ver = "1.0.0"',
    '  implementation("com.dyn:interp:$ver")',
    '  implementation("com.dyn:braced:${libs.versions.junit.get()}")',
    '  implementation("com.dyn:escaped-slash:\\\\$ver")',
    '  implementation("""com.dyn:raw-interp:$ver""")',
    '  implementation("com.dyn:concat:" + ver)',
    '  implementation(group = "com.dyn", name = "named-var", version = ver)',
    '  implementation(platform("org.springframework.boot:spring-boot-dependencies:3.2.0"))',
    "  implementation(enforcedPlatform(libs.junit.jupiter))",
    '  implementation(project(":core"))',
    "  implementation(projects.shared)",
    '  implementation(testFixtures(project(":common")))',
    '  runtimeOnly(files("libs/local.jar"))',
    '  runtimeOnly(fileTree("libs"))',
    '  implementation(kotlin("stdlib"))',
    "  implementation(libs.bundles.testing)",
    "  implementation(libs.unknown.alias)",
    "  implementation('com.groovy:single-quoted:1.0.0')",
    '  customConfig("com.custom:thing:1.0.0")',
    "}",
  }, "\n")

  local dyn_deps, dyn_notes = deps._parse_kotlin_gradle_dependencies(dynamic_kts, mixed_catalog)
  assert(#dyn_deps == 0, "formas dinâmicas/não suportadas não podem virar dependências: " .. vim.inspect(dyn_deps))
  local dyn_joined = table.concat(dyn_notes, "\n")
  for _, expected_note in ipairs({
    "dynamic version or variable not resolved: com.dyn:interp:$ver",
    "dynamic version or variable not resolved: com.dyn:braced:${libs.versions.junit.get()}",
    "escaped-slash",
    "raw-interp",
    "concat",
    "named-var",
    "platform/BOM dependency not resolved",
    'project dependency not resolved: implementation(project(":core"))',
    "project dependency not resolved: implementation(projects.shared)",
    "testFixtures dependency not resolved",
    "file dependency not resolved",
    "file-tree dependency not resolved",
    "kotlin() dependency helper not resolved",
    "catalog bundle not resolved: libs.bundles.testing",
    "catalog alias not resolved (no libs.versions.toml entry): libs.unknown.alias",
    "single-quoted",
    "customConfig",
  }) do
    assert(dyn_joined:find(expected_note, 1, true), "nota esperada ausente: " .. expected_note .. "\n" .. dyn_joined)
  end
end

kotlin_dsl_spec()

local function kotlin_repair_spec()
  -- 1) Trailing configuration lambdas: report partial and never present a misleading effective version
  local lambda_catalog = deps._parse_version_catalog(table.concat({
    "[libraries]",
    'junit-jupiter = "org.junit.jupiter:junit-jupiter:5.10.0"',
  }, "\n"))
  local lambda_kts = table.concat({
    "dependencies {",
    '  implementation("com.example:override:1.0.0") {',
    "    version {",
    '      strictly("2.0.0")',
    "    }",
    "  }",
    "  testImplementation(libs.junit.jupiter) {",
    "    isTransitive = false",
    "  }",
    '  api(group = "com.example", name = "named-lambda", version = "1.2.0") {',
    "    isForce = true",
    "  }",
    '  runtimeOnly("com.example:no-declared") {',
    "    version {",
    '      require("3.0.0")',
    "    }",
    "  }",
    "}",
  }, "\n")
  local ldeps, lnotes = deps._parse_kotlin_gradle_dependencies(lambda_kts, lambda_catalog)
  assert(#ldeps == 4, "esperava 4 deps com lambda de configuração: " .. #ldeps)
  assert(#lnotes == 4, "esperava 4 notas de lambda de configuração: " .. #lnotes)
  local function lfind(group, artifact)
    for _, entry in ipairs(ldeps) do
      if entry.groupId == group and entry.artifactId == artifact then
        return entry
      end
    end
  end
  local override_dep = lfind("com.example", "override")
  assert(
    override_dep
      and override_dep.version == nil
      and override_dep.declared_version == "1.0.0"
      and override_dep.has_configuration_lambda == true
  )
  local cat_lambda_dep = lfind("org.junit.jupiter", "junit-jupiter")
  assert(
    cat_lambda_dep
      and cat_lambda_dep.version == nil
      and cat_lambda_dep.declared_version == "5.10.0"
      and cat_lambda_dep.has_configuration_lambda == true
  )
  local named_lambda_dep = lfind("com.example", "named-lambda")
  assert(
    named_lambda_dep
      and named_lambda_dep.version == nil
      and named_lambda_dep.declared_version == "1.2.0"
      and named_lambda_dep.has_configuration_lambda == true
  )
  local no_decl_dep = lfind("com.example", "no-declared")
  assert(
    no_decl_dep
      and no_decl_dep.version == nil
      and no_decl_dep.declared_version == nil
      and no_decl_dep.has_configuration_lambda == true
  )

  local lambda_dir = tempdir("kts-lambda")
  write_raw(lambda_dir .. "/settings.gradle.kts", 'rootProject.name = "kts-lambda"\n')
  write_raw(lambda_dir .. "/build.gradle.kts", lambda_kts .. "\n")
  write_raw(
    lambda_dir .. "/gradle/libs.versions.toml",
    '[libraries]\njunit-jupiter = "org.junit.jupiter:junit-jupiter:5.10.0"\n'
  )
  local lambda_target = deps._resolve_target(buffer_for(lambda_dir .. "/build.gradle.kts"))
  local lambda_report = table.concat(deps._report_lines(lambda_target), "\n")
  assert(
    lambda_report:find("Coverage: partial", 1, true),
    "lambda não deveria alegar cobertura total:\n" .. lambda_report
  )
  assert(
    lambda_report:find(
      "  - implementation com.example:override  (declared version=1.0.0, configuration lambda not evaluated)",
      1,
      true
    ),
    "versão declarada com lambda mal formatada:\n" .. lambda_report
  )
  assert(
    lambda_report:find("  - runtimeOnly com.example:no-declared  (configuration lambda not evaluated)", 1, true),
    "dep sem versão declarada + lambda mal formatada:\n" .. lambda_report
  )
  assert(
    not lambda_report:find("  - implementation com.example:override:1.0.0", 1, true),
    "versão declarada apresentada como efetiva:\n" .. lambda_report
  )

  -- 2) val/var containing dependency registration must surface partial (never silently disappear)
  local decl_kts = table.concat({
    "dependencies {",
    '  val dep = add("implementation", "com.example:added:1.0.0")',
    '  var other = implementation("com.example:assigned:2.0.0")',
    "}",
    'val topDep = dependencies.add("implementation", "com.example:top-add:3.0.0")',
    "val topBlock = dependencies {",
    '  implementation("com.example:top-block:4.0.0")',
    "}",
  }, "\n")
  local decl_deps, decl_notes = deps._parse_kotlin_gradle_dependencies(decl_kts, nil)
  assert(#decl_deps == 0, "declarações val/var não devem gerar deps: " .. vim.inspect(decl_deps))
  assert(#decl_notes == 4, "esperava 4 notas para val/var: " .. vim.inspect(decl_notes))
  local decl_joined = table.concat(decl_notes, "\n")
  assert(decl_joined:find('val dep = add("implementation", "com.example:added:1.0.0")', 1, true))
  assert(decl_joined:find('var other = implementation("com.example:assigned:2.0.0")', 1, true))
  assert(decl_joined:find('val topDep = dependencies.add("implementation", "com.example:top-add:3.0.0")', 1, true))
  assert(decl_joined:find("val topBlock = dependencies", 1, true))

  local decl_dir = tempdir("kts-decl")
  write_raw(decl_dir .. "/settings.gradle.kts", 'rootProject.name = "kts-decl"\n')
  write_raw(decl_dir .. "/build.gradle.kts", decl_kts .. "\n")
  local decl_report =
    table.concat(deps._report_lines(deps._resolve_target(buffer_for(decl_dir .. "/build.gradle.kts"))), "\n")
  assert(decl_report:find("Coverage: partial", 1, true), "val/var não reportou partial:\n" .. decl_report)

  -- 3) Qualified other.dependencies blocks/receivers must not be assumed current project
  local scoped_kts = table.concat({
    "buildscript {",
    "  dependencies {",
    '    classpath("com.current:plugin:1.0.0")',
    "  }",
    "  other.dependencies {",
    '    classpath("com.other:buildscript-other:9.9.9")',
    "  }",
    "}",
    "other.dependencies {",
    '  implementation("com.other:direct:1.0.0")',
    "}",
    'project(":core").dependencies {',
    '  implementation("com.other:proj:1.0.0")',
    "}",
    "other",
    "  .dependencies {",
    '    implementation("com.other:multiline-dot-next:1.0.0")',
    "  }",
    "other.",
    "  dependencies {",
    '    implementation("com.other:multiline-dot-prev:1.0.0")',
    "  }",
    'other.dependencies.implementation("com.other:dot-call:1.0.0")',
    "subprojects {",
    '  dependencies.implementation("com.other:sub-dot-call:1.0.0")',
    "}",
    "dependencies {",
    '  implementation("com.current:ok:2.0.0")',
    "}",
  }, "\n")
  local sdeps, snotes = deps._parse_kotlin_gradle_dependencies(scoped_kts, nil)
  assert(#sdeps == 2, "esperava apenas 2 deps do projeto atual: " .. vim.inspect(sdeps))
  assert(sdeps[1].groupId == "com.current" and sdeps[1].artifactId == "plugin")
  assert(sdeps[2].groupId == "com.current" and sdeps[2].artifactId == "ok")
  assert(#snotes == 7, "esperava 7 notas para receptores scoped: " .. vim.inspect(snotes))
  local snotes_joined = table.concat(snotes, "\n")
  assert(snotes_joined:find("scoped dependencies receiver not resolved: other.dependencies", 1, true))
  assert(snotes_joined:find('scoped dependencies receiver not resolved: project(":core").dependencies', 1, true))
  assert(snotes_joined:find("scoped dependencies receiver not resolved: other .dependencies", 1, true))
  assert(snotes_joined:find("scoped dependencies receiver not resolved: other. dependencies", 1, true))
  assert(
    snotes_joined:find(
      'scoped dependencies receiver not resolved: other.dependencies.implementation("com.other:dot-call:1.0.0")',
      1,
      true
    )
  )
  assert(snotes_joined:find("scoped or conditional dependencies block not resolved (subprojects)", 1, true))

  -- 4) Ambiguous catalog aliases (same Gradle normalized accessor) for both Kotlin and Groovy
  local amb_toml_a = table.concat({
    "[libraries]",
    'foo-bar = "com.example:foo-dash:1.0.0"',
    'foo_bar = "com.example:foo-under:2.0.0"',
    'ok-lib = "com.example:ok:3.0.0"',
  }, "\n")
  local amb_toml_b = table.concat({
    "[libraries]",
    'foo_bar = "com.example:foo-under:2.0.0"',
    'foo-bar = "com.example:foo-dash:1.0.0"',
    'ok-lib = "com.example:ok:3.0.0"',
  }, "\n")
  local amb_cat_a = deps._parse_version_catalog(amb_toml_a)
  local amb_cat_b = deps._parse_version_catalog(amb_toml_b)
  assert(
    #amb_cat_a.notes == 1
      and amb_cat_a.notes[1] == "ambiguous catalog accessor libs.foo.bar (aliases: foo-bar, foo_bar)",
    "nota de catálogo ambíguo divergiu: " .. vim.inspect(amb_cat_a.notes)
  )
  assert(
    #amb_cat_b.notes == 1 and amb_cat_b.notes[1] == amb_cat_a.notes[1],
    "nota de catálogo ambíguo não é determinística entre ordens"
  )

  local amb_kts = table.concat({
    "dependencies {",
    "  implementation(libs.foo.bar)",
    "  api(libs.ok.lib)",
    "}",
  }, "\n")
  for _, cat in ipairs({ amb_cat_a, amb_cat_b }) do
    local ak_deps, ak_notes = deps._parse_kotlin_gradle_dependencies(amb_kts, cat)
    assert(#ak_deps == 1 and ak_deps[1].artifactId == "ok", "alias não ambíguo deveria resolver e ambíguo não")
    assert(
      #ak_notes == 1 and ak_notes[1] == "ambiguous catalog alias libs.foo.bar (matches: foo-bar, foo_bar)",
      "ambiguidade Kotlin divergiu: " .. vim.inspect(ak_notes)
    )
  end

  local amb_groovy = table.concat({
    "dependencies {",
    "  implementation(libs.foo.bar)",
    "  testImplementation libs.foo.bar",
    "  api libs.ok.lib",
    "}",
  }, "\n")
  for _, cat in ipairs({ amb_cat_a, amb_cat_b }) do
    local ag_deps, ag_notes = deps._parse_gradle_dependencies(amb_groovy, cat)
    assert(
      #ag_deps == 1 and ag_deps[1].artifactId == "ok",
      "Groovy: alias não ambíguo deveria resolver e ambíguo não"
    )
    assert(#ag_notes == 2, "Groovy: esperava 2 notas de ambiguidade: " .. vim.inspect(ag_notes))
    assert(ag_notes[1] == "ambiguous catalog alias libs.foo.bar (matches: foo-bar, foo_bar)")
    assert(ag_notes[2] == "ambiguous catalog alias libs.foo.bar (matches: foo-bar, foo_bar)")
  end

  -- Colisão de 3 aliases normalizados (hífen, ponto e sublinhado)
  local amb_toml_3 = table.concat({
    "[libraries]",
    'foo.bar = "com.example:foo-dot:1.0.0"',
    'foo_bar = "com.example:foo-under:2.0.0"',
    'foo-bar = "com.example:foo-dash:3.0.0"',
  }, "\n")
  local amb_cat_3 = deps._parse_version_catalog(amb_toml_3)
  local _, k3_notes = deps._parse_kotlin_gradle_dependencies("dependencies { implementation(libs.foo.bar) }", amb_cat_3)
  local _, g3_notes = deps._parse_gradle_dependencies("dependencies {\n  implementation libs.foo.bar\n}", amb_cat_3)
  assert(k3_notes[1] == "ambiguous catalog alias libs.foo.bar (matches: foo-bar, foo.bar, foo_bar)")
  assert(g3_notes[1] == "ambiguous catalog alias libs.foo.bar (matches: foo-bar, foo.bar, foo_bar)")

  local amb_dir = tempdir("kts-ambig")
  write_raw(amb_dir .. "/settings.gradle.kts", 'rootProject.name = "kts-ambig"\n')
  write_raw(amb_dir .. "/build.gradle.kts", amb_kts .. "\n")
  write_raw(amb_dir .. "/gradle/libs.versions.toml", amb_toml_a .. "\n")
  local amb_report =
    table.concat(deps._report_lines(deps._resolve_target(buffer_for(amb_dir .. "/build.gradle.kts"))), "\n")
  assert(amb_report:find("Coverage: partial", 1, true), "catálogo ambíguo não reportou partial:\n" .. amb_report)
  assert(amb_report:find("Note: ambiguous catalog alias libs.foo.bar (matches: foo-bar, foo_bar)", 1, true))
  assert(amb_report:find("  - api com.example:ok:3.0.0", 1, true))
  assert(not amb_report:find("  - implementation com.example:foo-", 1, true))
end

kotlin_repair_spec()

local function kotlin_followup_spec()
  -- 1) TOML inline ref (`version = { ref = "..." }`) e inline rich version (`version = { require = "..." }`)
  local rich_toml = table.concat({
    "[versions]",
    'junit = "5.10.0"',
    "",
    "[libraries]",
    'inline-ref = { module = "com.example:inline-ref", version = { ref = "junit" } }',
    'inline-ref-gn = { group = "com.example", name = "inline-ref-gn", version = { ref = "junit" } }',
    'missing-inline-ref = { module = "com.example:missing-inline-ref", version = { ref = "missingVer" } }',
    'rich-require = { module = "com.example:rich-require", version = { require = "1.2.3" } }',
    'rich-range = { group = "com.example", name = "rich-range", version = { require = "[1.0, 2.0)", prefer = "1.5.0", reject = ["1.4.0"] } }',
    'dotted-rich = { module = "com.example:dotted-rich", version.strictly = "2.0.0" }',
  }, "\n")
  local rich_cat = deps._parse_version_catalog(rich_toml)
  assert(rich_cat.by_alias["inline-ref"].version == "5.10.0" and rich_cat.by_alias["inline-ref"].note == nil)
  assert(rich_cat.by_alias["inline-ref-gn"].version == "5.10.0" and rich_cat.by_alias["inline-ref-gn"].note == nil)
  assert(
    rich_cat.by_alias["missing-inline-ref"].version == nil
      and rich_cat.by_alias["missing-inline-ref"].note == "unresolved version.ref: missingVer"
  )
  assert(
    rich_cat.by_alias["rich-require"].version == nil
      and rich_cat.by_alias["rich-require"].note == "rich version constraint not resolved"
  )
  assert(
    rich_cat.by_alias["rich-range"].version == nil
      and rich_cat.by_alias["rich-range"].note == "rich version constraint not resolved"
  )
  assert(
    rich_cat.by_alias["dotted-rich"].version == nil
      and rich_cat.by_alias["dotted-rich"].note == "rich version constraint not resolved"
  )

  local rich_kts = table.concat({
    "dependencies {",
    "  implementation(libs.inline.ref)",
    "  api(libs.inline.ref.gn)",
    "  testImplementation(libs.missing.inline.ref)",
    "  implementation(libs.rich.require)",
    "  runtimeOnly(libs.rich.range)",
    "  compileOnly(libs.dotted.rich)",
    "}",
  }, "\n")
  local rk_deps, rk_notes = deps._parse_kotlin_gradle_dependencies(rich_kts, rich_cat)
  assert(#rk_deps == 6, "esperava 6 deps do catálogo no Kotlin: " .. #rk_deps)
  assert(rk_deps[1].version == "5.10.0" and rk_deps[2].version == "5.10.0")
  assert(
    rk_deps[3].version == nil and rk_deps[4].version == nil and rk_deps[5].version == nil and rk_deps[6].version == nil
  )
  local rk_joined = table.concat(rk_notes, "\n")
  assert(rk_joined:find("libs.missing.inline.ref: unresolved version.ref: missingVer", 1, true))
  assert(rk_joined:find("libs.rich.require: rich version constraint not resolved", 1, true))
  assert(rk_joined:find("libs.rich.range: rich version constraint not resolved", 1, true))
  assert(rk_joined:find("libs.dotted.rich: rich version constraint not resolved", 1, true))

  local rich_groovy = table.concat({
    "dependencies {",
    "  implementation libs.inline.ref",
    "  api(libs.inline.ref.gn)",
    "  testImplementation libs.missing.inline.ref",
    "  implementation(libs.rich.require)",
    "  runtimeOnly libs.rich.range",
    "  compileOnly libs.dotted.rich",
    "}",
  }, "\n")
  local rg_deps, rg_notes = deps._parse_gradle_dependencies(rich_groovy, rich_cat)
  assert(#rg_deps == 6, "esperava 6 deps do catálogo no Groovy: " .. #rg_deps)
  assert(rg_deps[1].version == "5.10.0" and rg_deps[2].version == "5.10.0")
  assert(
    rg_deps[3].version == nil and rg_deps[4].version == nil and rg_deps[5].version == nil and rg_deps[6].version == nil
  )
  local rg_joined = table.concat(rg_notes, "\n")
  assert(rg_joined:find("libs.missing.inline.ref: unresolved version.ref: missingVer", 1, true))
  assert(rg_joined:find("libs.rich.require: rich version constraint not resolved", 1, true))
  assert(rg_joined:find("libs.rich.range: rich version constraint not resolved", 1, true))
  assert(rg_joined:find("libs.dotted.rich: rich version constraint not resolved", 1, true))

  local rich_kts_dir = tempdir("kts-rich-toml")
  write_raw(rich_kts_dir .. "/settings.gradle.kts", 'rootProject.name = "kts-rich-toml"\n')
  write_raw(rich_kts_dir .. "/build.gradle.kts", rich_kts .. "\n")
  write_raw(rich_kts_dir .. "/gradle/libs.versions.toml", rich_toml .. "\n")
  local rich_kts_report =
    table.concat(deps._report_lines(deps._resolve_target(buffer_for(rich_kts_dir .. "/build.gradle.kts"))), "\n")
  assert(rich_kts_report:find("Coverage: partial", 1, true), "relatório .kts rich TOML deve ser parcial")
  assert(rich_kts_report:find("  - implementation com.example:inline-ref:5.10.0", 1, true))
  assert(
    rich_kts_report:find("  - implementation com.example:rich-require  (rich version constraint not resolved)", 1, true),
    "dep rich-require sem indicação no relatório .kts:\n" .. rich_kts_report
  )
  assert(
    rich_kts_report:find("  - rich-require com.example:rich-require  (rich version constraint not resolved)", 1, true),
    "catálogo rich-require sem indicação no relatório .kts:\n" .. rich_kts_report
  )

  local rich_groovy_dir = tempdir("groovy-rich-toml")
  write_raw(rich_groovy_dir .. "/settings.gradle", 'rootProject.name = "groovy-rich-toml"\n')
  write_raw(rich_groovy_dir .. "/build.gradle", rich_groovy .. "\n")
  write_raw(rich_groovy_dir .. "/gradle/libs.versions.toml", rich_toml .. "\n")
  local rich_groovy_report =
    table.concat(deps._report_lines(deps._resolve_target(buffer_for(rich_groovy_dir .. "/build.gradle"))), "\n")
  assert(rich_groovy_report:find("Coverage: partial", 1, true), "relatório Groovy rich TOML deve ser parcial")
  assert(rich_groovy_report:find("Note: libs.rich.require: rich version constraint not resolved", 1, true))
  assert(
    rich_groovy_report:find(
      "  - testImplementation com.example:missing-inline-ref  (unresolved version.ref: missingVer)",
      1,
      true
    )
  )

  -- 2) Formas Kotlin `dependencies({ ... })`, `with(dependencies) { ... }` e variantes
  local scope_forms_kts = table.concat({
    "dependencies({",
    '  implementation("com.example:in-parens:1.0.0")',
    "})",
    "with(dependencies) {",
    '  implementation("com.example:in-with:1.0.0")',
    "}",
    "with(project.dependencies) {",
    '  api("com.example:in-with-proj:1.0.0")',
    "}",
    "with(dependencies, {",
    '  runtimeOnly("com.example:in-with-arg:1.0.0")',
    "})",
    "dependencies.apply {",
    '  implementation("com.example:in-apply:1.0.0")',
    "}",
    "dependencies {",
    '  implementation("com.example:normal:1.0.0")',
    "}",
  }, "\n")
  local sf_deps, sf_notes = deps._parse_kotlin_gradle_dependencies(scope_forms_kts, nil)
  assert(
    #sf_deps == 1 and sf_deps[1].artifactId == "normal",
    "formas não suportadas inventaram deps: " .. vim.inspect(sf_deps)
  )
  assert(#sf_notes == 5, "esperava 5 notas para formas de dependencies(): " .. vim.inspect(sf_notes))
  local sf_joined = table.concat(sf_notes, "\n")
  assert(sf_joined:find("dependencies({", 1, true), "nota ausente para dependencies({ ... }):\n" .. sf_joined)
  assert(sf_joined:find("with(dependencies)", 1, true), "nota ausente para with(dependencies):\n" .. sf_joined)
  assert(
    sf_joined:find("with(project.dependencies)", 1, true),
    "nota ausente para with(project.dependencies):\n" .. sf_joined
  )
  assert(sf_joined:find("with(dependencies, {", 1, true), "nota ausente para with(dependencies, {...}):\n" .. sf_joined)
  assert(sf_joined:find("dependencies.apply", 1, true), "nota ausente para dependencies.apply:\n" .. sf_joined)

  local sf_dir = tempdir("kts-scope-forms")
  write_raw(sf_dir .. "/settings.gradle.kts", 'rootProject.name = "kts-scope-forms"\n')
  write_raw(sf_dir .. "/build.gradle.kts", scope_forms_kts .. "\n")
  local sf_report =
    table.concat(deps._report_lines(deps._resolve_target(buffer_for(sf_dir .. "/build.gradle.kts"))), "\n")
  assert(
    sf_report:find("Coverage: partial", 1, true),
    "relatório de formas scoped não marcou partial:\n" .. sf_report
  )
  assert(sf_report:find("Dependencies: 1 (static parse of build.gradle.kts)", 1, true))

  -- 3) Script externo `apply(from = "deps.gradle.kts")` e `apply { from(...) }`: reporta partial sem executar
  local apply_dir = tempdir("kts-apply-from")
  write_raw(apply_dir .. "/settings.gradle.kts", 'rootProject.name = "kts-apply-from"\n')
  write_raw(
    apply_dir .. "/deps.gradle.kts",
    'dependencies {\n  implementation("com.external:should-not-execute:9.9.9")\n}\n'
  )
  write_raw(
    apply_dir .. "/build.gradle.kts",
    table.concat({
      'apply(plugin = "java")',
      'apply(from = "deps.gradle.kts")',
      "apply {",
      '  from("extra.gradle.kts")',
      "}",
      'project.apply(mapOf("from" to "more.gradle.kts"))',
      "dependencies {",
      '  implementation("com.example:local:1.0.0")',
      "}",
      "",
    }, "\n")
  )
  local apply_report =
    table.concat(deps._report_lines(deps._resolve_target(buffer_for(apply_dir .. "/build.gradle.kts"))), "\n")
  assert(apply_report:find("Coverage: partial", 1, true), "apply(from=...) não marcou partial:\n" .. apply_report)
  assert(apply_report:find("Dependencies: 1 (static parse of build.gradle.kts)", 1, true))
  assert(apply_report:find("  - implementation com.example:local:1.0.0", 1, true))
  assert(not apply_report:find("should-not-execute", 1, true), "script externo não pode ser executado/inventado")
  assert(
    apply_report:find('Note: external script apply(from = ...) not resolved: apply(from = "deps.gradle.kts")', 1, true)
  )
  assert(
    apply_report:find(
      'Note: external script apply(from = ...) not resolved: apply { from("extra.gradle.kts") }',
      1,
      true
    )
  )
  assert(
    apply_report:find(
      'Note: external script apply(from = ...) not resolved: project.apply(mapOf("from" to "more.gradle.kts"))',
      1,
      true
    )
  )
  assert(
    not apply_report:find('apply(plugin = "java")', 1, true),
    "apply(plugin = ...) não deveria gerar falso positivo de script externo"
  )
end

kotlin_followup_spec()

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

  -- ---------- 14. shell: menu (Gradle estático habilita Add, parcial/dinâmico desabilita; Maven habilita) ----------

  local gradle_before_menu = read_raw(gradle_root .. "/build.gradle")
  stub_ui({ "Add dependency" }, {})
  notices = {}
  deps.menu(gradle_buf)
  assert(#select_calls == 2, "menu Gradle estático deveria abrir menu + submenu add: " .. #select_calls)
  local gradle_menu = table.concat(select_calls[1].items, "\n")
  assert(
    not gradle_menu:find("Add dependency…  (unavailable", 1, true),
    "Add dependency deveria estar habilitado em Gradle estático: " .. gradle_menu
  )
  assert(gradle_menu:find("Open build.gradle\n", 1, true) or gradle_menu:find("Open build.gradle", 1, true))
  assert(not gradle_menu:find("Open build.gradle[^\n]*(unavailable", 1), "Open build file deveria estar habilitado")
  assert(
    gradle_menu:find("Sync JDTLS  (unavailable: jdtls is not attached to this buffer)", 1, true),
    "Sync deveria estar desabilitado sem cliente"
  )
  assert(read_raw(gradle_root .. "/build.gradle") == gradle_before_menu, "cancelar no submenu add escreveu em disco")

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

  -- Kotlin DSL estático: menu habilita Add e List abre relatório estático
  local kts_before_menu = read_raw(kts_dir .. "/build.gradle.kts")
  stub_ui({ "Add dependency" }, {})
  notices = {}
  deps.menu(kts_buf)
  assert(#select_calls == 2, "menu Kotlin DSL estático deveria abrir menu + submenu add")
  local kts_menu = table.concat(select_calls[1].items, "\n")
  assert(
    not kts_menu:find("Add dependency…  (unavailable", 1, true),
    "Add dependency deveria estar habilitado no Kotlin DSL estático: " .. kts_menu
  )
  assert(kts_menu:find("Open build.gradle.kts", 1, true), "Open build.gradle.kts ausente no menu")
  assert(read_raw(kts_dir .. "/build.gradle.kts") == kts_before_menu, "cancelar no submenu .kts escreveu em disco")

  -- Kotlin DSL com construto dinâmico/não suportado: Add fica desabilitado com motivo claro
  local dyn_menu_dir = tempdir("kts-dyn-menu")
  write_raw(dyn_menu_dir .. "/settings.gradle.kts", 'rootProject.name = "dyn-menu"\n')
  local dyn_menu_text = table.concat({
    "dependencies {",
    '  implementation("org.slf4j:slf4j-api:2.0.20")',
    '  implementation("com.dyn:$ver")',
    "}",
    "",
  }, "\n")
  write_raw(dyn_menu_dir .. "/build.gradle.kts", dyn_menu_text)
  local dyn_menu_buf = buffer_for(dyn_menu_dir .. "/build.gradle.kts")
  stub_ui({ "Add dependency" }, {})
  notices = {}
  deps.menu(dyn_menu_buf)
  assert(#select_calls == 1, "menu Kotlin DSL dinâmico deveria abrir apenas o menu principal")
  local dyn_menu_str = table.concat(select_calls[1].items, "\n")
  assert(
    dyn_menu_str:find("Add dependency…  (unavailable: dynamic version or variable not resolved", 1, true),
    "Add dependency deveria estar desabilitado em projeto dinâmico: " .. dyn_menu_str
  )
  assert(has_notice("dynamic version or variable not resolved"), "escolher Add desabilitado deveria avisar")
  assert(read_raw(dyn_menu_dir .. "/build.gradle.kts") == dyn_menu_text, "arquivo dinâmico foi alterado")

  stub_ui({ "List dependencies" }, {})
  deps.menu(kts_buf)
  local kts_list_buf = vim.api.nvim_get_current_buf()
  local kts_list_lines = table.concat(vim.api.nvim_buf_get_lines(kts_list_buf, 0, -1, false), "\n")
  vim.cmd("close")
  assert(kts_list_lines:find("Build file: build.gradle.kts", 1, true), "List não abriu o relatório .kts")
  assert(kts_list_lines:find("implementation org.slf4j:slf4j-api:2.0.20", 1, true), "dep .kts ausente no buffer")
  assert(kts_list_lines:find("Coverage: partial", 1, true), "cobertura parcial ausente no buffer .kts")

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

local function maven_profiles_provenance_spec()
  -- ---------- 19. Maven: perfis, proveniência gerenciada, parent/BOM, comentários e versões ausentes ----------

  -- A) POM rico com parent, BOM import, dependencyManagement com/sem versão, comentários,
  --    propriedades, build dentro de profile e perfis com versões/BOM próprios
  local rich_pom = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <parent>",
    "    <groupId>com.corp</groupId>",
    "    <artifactId>corp-parent</artifactId>",
    "    <!-- <version>0.0.1-comment</version> -->",
    "    <version>3.1.0</version>",
    "    <relativePath>../parent/pom.xml</relativePath>",
    "  </parent>",
    "  <artifactId>service</artifactId>",
    "  <dependencyManagement>",
    "    <dependencies>",
    "      <dependency>",
    "        <groupId>org.junit</groupId>",
    "        <artifactId>junit-bom</artifactId>",
    "        <version>5.10.2</version>",
    "        <type>pom</type>",
    "        <scope>import</scope>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.fasterxml.jackson.core</groupId>",
    "        <artifactId>jackson-databind</artifactId>",
    "        <version>2.17.1</version>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>dm-no-version</artifactId>",
    "        <!-- <version>9.9.9</version> -->",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>prop-managed</artifactId>",
    "        <version>${prop.ver}</version>",
    "      </dependency>",
    "    </dependencies>",
    "  </dependencyManagement>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>com.fasterxml.jackson.core</groupId>",
    "      <artifactId>jackson-databind</artifactId>",
    "      <!-- <version>0.9.9</version> -->",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>org.junit.jupiter</groupId>",
    "      <artifactId>junit-jupiter-api</artifactId>",
    "      <scope>test</scope>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>dm-no-version</artifactId>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>prop-dep</artifactId>",
    "      <version>${direct.ver}</version>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>override-dm</artifactId>",
    "      <version>2.18.0</version>",
    "    </dependency>",
    "  </dependencies>",
    "  <profiles>",
    "    <!-- <profile>",
    "      <id>commented-out</id>",
    "      <dependencies>",
    "        <dependency><groupId>fake.comment</groupId><artifactId>nope</artifactId><version>1.0</version></dependency>",
    "      </dependencies>",
    "    </profile> -->",
    "    <profile>",
    "      <repositories>",
    "        <repository><id>corp-repo</id></repository>",
    "      </repositories>",
    "      <!-- <id>fake-id</id> -->",
    "      <id>dev</id>",
    "      <activation>",
    "        <!-- <activeByDefault>false</activeByDefault> -->",
    "        <activeByDefault>true</activeByDefault>",
    "        <property><name>env</name></property>",
    "      </activation>",
    "      <dependencyManagement>",
    "        <dependencies>",
    "          <dependency>",
    "            <groupId>com.fasterxml.jackson.core</groupId>",
    "            <artifactId>jackson-databind</artifactId>",
    "            <version>2.18.0-rc1</version>",
    "          </dependency>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>dev-managed</artifactId>",
    "            <version>4.2.0</version>",
    "          </dependency>",
    "        </dependencies>",
    "      </dependencyManagement>",
    "      <build>",
    "        <plugins>",
    "          <plugin>",
    "            <artifactId>maven-surefire-plugin</artifactId>",
    "            <dependencies>",
    "              <dependency>",
    "                <groupId>plugin.inside.profile</groupId>",
    "                <artifactId>leak</artifactId>",
    "                <version>1.0</version>",
    "              </dependency>",
    "            </dependencies>",
    "          </plugin>",
    "        </plugins>",
    "      </build>",
    "      <dependencies>",
    "        <dependency>",
    "          <groupId>com.fasterxml.jackson.core</groupId>",
    "          <artifactId>jackson-databind</artifactId>",
    "        </dependency>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>dev-managed</artifactId>",
    "        </dependency>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>prop-managed</artifactId>",
    "        </dependency>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>dev-explicit</artifactId>",
    "          <version>1.5.0-dev</version>",
    "          <scope>runtime</scope>",
    "        </dependency>",
    "      </dependencies>",
    "    </profile>",
    "    <profile>",
    "      <activation>",
    "        <jdk>21</jdk>",
    "      </activation>",
    "      <dependencies>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>unnamed-profile-dep</artifactId>",
    "          <version>9.0.0</version>",
    "        </dependency>",
    "      </dependencies>",
    "    </profile>",
    "  </profiles>",
    "</project>",
  }, "\n")

  local rich_parsed = deps._parse_pom(rich_pom)
  assert(rich_parsed.has_parent == true)
  assert(
    rich_parsed.parent
      and rich_parsed.parent.groupId == "com.corp"
      and rich_parsed.parent.artifactId == "corp-parent"
      and rich_parsed.parent.version == "3.1.0"
      and rich_parsed.parent.relativePath == "../parent/pom.xml",
    "parent com comentário mal lido: " .. vim.inspect(rich_parsed.parent)
  )
  assert(#rich_parsed.deps == 5, "esperava 5 deps no projeto: " .. #rich_parsed.deps)
  assert(rich_parsed.deps[1].version == nil, "comentário de versão dentro de <dependency> vazou")
  assert(#rich_parsed.managed == 4, "esperava 4 managed entries: " .. #rich_parsed.managed)
  assert(rich_parsed.managed[3].version == nil, "comentário de versão em dependencyManagement vazou")
  assert(rich_parsed.has_bom == true and #(rich_parsed.bom_imports or {}) == 1)
  assert(rich_parsed.has_profiles == true and #(rich_parsed.profiles or {}) == 2)

  local dev_prof = rich_parsed.profiles[1]
  assert(dev_prof.id == "dev", "id do profile foi sequestrado por repository ou comentário: " .. tostring(dev_prof.id))
  assert(dev_prof.activation and dev_prof.activation.active_by_default == true, "activeByDefault comentado interferiu")
  assert(dev_prof.activation.triggers[1] == "property")
  assert(#dev_prof.managed == 2, "esperava 2 managed entries no profile dev: " .. #dev_prof.managed)
  assert(#dev_prof.deps == 4, "plugin dentro de profile vazou ou dep faltou: " .. #dev_prof.deps)
  for _, d in ipairs(dev_prof.deps) do
    assert(d.groupId ~= "plugin.inside.profile", "dependência de plugin dentro de profile vazou")
    assert(d.groupId ~= "fake.comment", "profile comentado vazou")
  end
  assert(rich_parsed.profiles[2].id == nil, "profile sem <id> deveria ter id nil")
  assert(rich_parsed.profiles[2].activation.triggers[1] == "jdk")

  -- Preservação de duplicata e inserção: dep exclusiva de profile NÃO bloqueia inserção no projeto
  local prof_insert_ok, _, prof_insert_err = deps._insert_maven_dependency(rich_pom, {
    groupId = "com.example",
    artifactId = "dev-explicit",
    version = "1.0.0",
  })
  assert(prof_insert_ok and not prof_insert_err, "dep exclusiva de profile não pode bloquear inserção no projeto")

  local rich_dir = tempdir("maven-rich-report")
  local rich_pom_path = rich_dir .. "/pom.xml"
  write_raw(rich_pom_path, rich_pom)
  local rich_report = table.concat(
    deps._report_lines({
      root = rich_dir,
      tool = "maven",
      modules = { rich_dir },
      module = rich_dir,
      build_file = rich_pom_path,
      is_kotlin_dsl = false,
    }),
    "\n"
  )

  -- O relatório nunca pode alterar o pom.xml
  assert(read_raw(rich_pom_path) == rich_pom, "relatório alterou pom.xml em disco")

  assert(
    rich_report:find(
      "Parent: com.corp:corp-parent:3.1.0 (declared in pom.xml; relativePath=../parent/pom.xml — inherited dependencies and dependencyManagement are not resolved)",
      1,
      true
    ),
    "linha de parent divergiu:\n" .. rich_report
  )
  assert(
    rich_report:find(
      "BOM: import detected (1 in project <dependencyManagement> — imported POMs are not resolved; textual inspection cannot prove per-artifact coverage)",
      1,
      true
    ),
    "linha de BOM divergiu:\n" .. rich_report
  )
  assert(
    rich_report:find("Profiles: present (2 declared — conditional; activation is not evaluated)", 1, true),
    "resumo de profiles divergiu:\n" .. rich_report
  )
  assert(
    rich_report:find(
      '  - com.fasterxml.jackson.core:jackson-databind  (managed candidate in project <dependencyManagement>: 2.17.1; conditional override in profile <dependencyManagement>: "dev" (2.18.0-rc1) (activation not evaluated) — effective version not proven)',
      1,
      true
    ),
    "precedência/incerteza condicional do project dependencyManagement ausente:\n" .. rich_report
  )
  assert(
    not rich_report:find("- com.fasterxml.jackson.core:jackson-databind  (version=2.17.1", 1, true),
    "versão efetiva não comprovada foi afirmada para jackson-databind:\n" .. rich_report
  )
  assert(
    rich_report:find(
      "  - org.junit.jupiter:junit-jupiter-api  (scope=test, version unspecified locally; unverified: <parent>, project BOM import(s) not resolved)",
      1,
      true
    ),
    "limitação de BOM/parent ausente:\n" .. rich_report
  )
  assert(
    rich_report:find(
      "  - com.example:dm-no-version  (version unspecified locally; matched in project <dependencyManagement> without <version>; unverified: <parent>, project BOM import(s) not resolved)",
      1,
      true
    ),
    "entrada gerenciada sem versão deveria manter honestidade:\n" .. rich_report
  )
  assert(
    rich_report:find("  - com.example:prop-dep:${direct.ver}  (version property not evaluated)", 1, true),
    "nota de propriedade não avaliada ausente:\n" .. rich_report
  )
  assert(
    rich_report:find(
      "  - org.junit:junit-bom:5.10.2  (type=pom, scope=import, BOM import — managed artifacts not resolved)",
      1,
      true
    ),
    "nota de BOM em Managed entries ausente:\n" .. rich_report
  )
  assert(
    rich_report:find("  - Profile: dev  (activation: activeByDefault=true, property — not evaluated)", 1, true),
    "contexto do profile dev ausente:\n" .. rich_report
  )
  assert(
    rich_report:find(
      '      - com.fasterxml.jackson.core:jackson-databind:2.18.0-rc1  (provenance: profile "dev" <dependencyManagement>, overrides project <dependencyManagement> 2.17.1 when active)',
      1,
      true
    ),
    "override de dependencyManagement no profile ausente:\n" .. rich_report
  )
  assert(
    rich_report:find(
      '      - com.fasterxml.jackson.core:jackson-databind  (version=2.18.0-rc1, managed by profile "dev" <dependencyManagement>; conditional; overrides project <dependencyManagement> 2.17.1)',
      1,
      true
    ),
    "proveniência de versão específica do profile ausente:\n" .. rich_report
  )
  assert(
    rich_report:find(
      '      - com.example:dev-managed  (version=4.2.0, managed by profile "dev" <dependencyManagement>; conditional)',
      1,
      true
    ),
    "versão gerenciada pelo próprio profile ausente:\n" .. rich_report
  )
  assert(
    rich_report:find(
      "      - com.example:prop-managed  (version=${prop.ver}, managed by project <dependencyManagement>; version property not evaluated)",
      1,
      true
    ),
    "fallback para project dependencyManagement dentro do profile falhou:\n" .. rich_report
  )
  assert(
    rich_report:find("      - com.example:dev-explicit:1.5.0-dev  (scope=runtime)", 1, true),
    "versão explícita no profile ausente:\n" .. rich_report
  )
  assert(
    rich_report:find("  - Profile: (unnamed)  (activation: jdk — not evaluated)", 1, true),
    "profile sem id não exibido:\n" .. rich_report
  )
  assert(not rich_report:find("fake.comment", 1, true), "profile comentado vazou no relatório")
  assert(not rich_report:find("plugin.inside.profile", 1, true), "plugin de profile vazou no relatório")
  assert(not rich_report:find("9.9.9", 1, true), "versão comentada vazou no relatório")

  -- B) Sem parent e sem BOM de projeto: versão ausente, match condicional só em profile,
  --    e BOM import declarado apenas dentro de profile (nunca promove para o projeto!)
  local isolated_pom = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.isolated</groupId>",
    "  <artifactId>app</artifactId>",
    "  <version>1.0</version>",
    "  <!-- <parent><groupId>fake</groupId><artifactId>p</artifactId><version>1</version></parent> -->",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>truly-missing</artifactId>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>only-profile-managed</artifactId>",
    "    </dependency>",
    "  </dependencies>",
    "  <profiles>",
    "    <profile>",
    "      <id>ci</id>",
    "      <dependencyManagement>",
    "        <dependencies>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>only-profile-managed</artifactId>",
    "            <version>7.1.0</version>",
    "          </dependency>",
    "          <dependency>",
    "            <groupId>org.springframework.boot</groupId>",
    "            <artifactId>spring-boot-dependencies</artifactId>",
    "            <version>3.2.5</version>",
    "            <type>pom</type>",
    "            <scope>import</scope>",
    "          </dependency>",
    "        </dependencies>",
    "      </dependencyManagement>",
    "      <dependencies>",
    "        <dependency>",
    "          <groupId>org.springframework.boot</groupId>",
    "          <artifactId>spring-boot-starter-web</artifactId>",
    "        </dependency>",
    "      </dependencies>",
    "    </profile>",
    "  </profiles>",
    "</project>",
  }, "\n")

  local iso_parsed = deps._parse_pom(isolated_pom)
  assert(iso_parsed.has_parent == false, "<parent> comentado foi detectado")
  assert(iso_parsed.has_bom == false, "BOM apenas de profile não pode contar como BOM de projeto")
  assert(
    deps._is_exact_managed(iso_parsed, "com.example", "only-profile-managed") == false,
    "dependencyManagement de profile não pode contar como gerenciamento incondicional do projeto"
  )
  -- Inserção no projeto sem <version> continua recusada mesmo com BOM/DM em profile
  local iso_ins, _, iso_ins_err = deps._insert_maven_dependency(isolated_pom, {
    groupId = "com.example",
    artifactId = "only-profile-managed",
  })
  assert(iso_ins == nil and iso_ins_err and iso_ins_err:find("<version> is required", 1, true))

  local iso_dir = tempdir("maven-isolated-report")
  local iso_pom_path = iso_dir .. "/pom.xml"
  write_raw(iso_pom_path, isolated_pom)
  local iso_report = table.concat(
    deps._report_lines({
      root = iso_dir,
      tool = "maven",
      modules = { iso_dir },
      module = iso_dir,
      build_file = iso_pom_path,
      is_kotlin_dsl = false,
    }),
    "\n"
  )
  assert(iso_report:find("Parent: none", 1, true), "parent comentado vazou:\n" .. iso_report)
  assert(
    iso_report:find(
      "BOM: none at project level (import detected in profile ci — conditional; imported POMs are not resolved; textual inspection cannot prove per-artifact coverage)",
      1,
      true
    ),
    "BOM de profile mal reportado:\n" .. iso_report
  )
  assert(
    iso_report:find(
      '  - com.example:truly-missing  (version unspecified locally; unverified: profile "ci" BOM import(s) (conditional) not resolved)',
      1,
      true
    ),
    "BOM condicional de profile não sinalizado na dependência de projeto:\n" .. iso_report
  )
  assert(
    not iso_report:find("no <version>, exact <dependencyManagement>, BOM import, or <parent> in pom.xml", 1, true),
    "não pode afirmar ausência de BOM quando existe BOM em profile:\n" .. iso_report
  )
  assert(
    iso_report:find(
      '  - com.example:only-profile-managed  (version unspecified locally; unverified: profile "ci" BOM import(s) (conditional) not resolved; conditional match in profile <dependencyManagement>: "ci" (7.1.0) (activation not evaluated))',
      1,
      true
    ),
    "match condicional em profile e BOM condicional não sinalizados:\n" .. iso_report
  )
  assert(
    iso_report:find(
      '      - org.springframework.boot:spring-boot-starter-web  (version unspecified locally; unverified: profile "ci" BOM import(s) not resolved)',
      1,
      true
    ),
    "dependência coberta só por BOM de profile deve permanecer não verificada:\n" .. iso_report
  )

  -- C) Tags auto-fechadas e <profiles> vazio ou só com comentários não quebram o parsing
  local self_closing_pom = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.sc</groupId>",
    "  <artifactId>sc</artifactId>",
    "  <version>1.0</version>",
    "  <build/>",
    "  <profiles><!-- <profile><id>ghost</id></profile> --></profiles>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>org.slf4j</groupId>",
    "      <artifactId>slf4j-api</artifactId>",
    "      <version>2.0.13</version>",
    "    </dependency>",
    "  </dependencies>",
    "</project>",
  }, "\n")
  local sc_parsed = deps._parse_pom(self_closing_pom)
  assert(#sc_parsed.deps == 1 and sc_parsed.deps[1].artifactId == "slf4j-api", "<build/> engoliu <dependencies>")
  assert(sc_parsed.has_profiles == true and #sc_parsed.profiles == 0)

  local sc_dir = tempdir("maven-self-closing")
  write_raw(sc_dir .. "/pom.xml", self_closing_pom)
  local sc_report = table.concat(
    deps._report_lines({
      root = sc_dir,
      tool = "maven",
      modules = { sc_dir },
      module = sc_dir,
      build_file = sc_dir .. "/pom.xml",
      is_kotlin_dsl = false,
    }),
    "\n"
  )
  assert(
    sc_report:find("Profiles: present (0 declared — empty or commented-only <profiles> section)", 1, true),
    "profiles vazio/comentado mal reportado:\n" .. sc_report
  )

  -- D) Fluxo List dependencies no buffer mostra o relatório read-only sem tocar no pom.xml
  local list_buf = buffer_for(rich_pom_path)
  stub_ui({ "List dependencies" }, {})
  deps.menu(list_buf)
  local out_buf = vim.api.nvim_get_current_buf()
  local out_text = table.concat(vim.api.nvim_buf_get_lines(out_buf, 0, -1, false), "\n")
  vim.cmd("close")
  assert(out_text:find("Profile declarations (conditional — activation not evaluated):", 1, true))
  assert(out_text:find("managed by profile", 1, true))
  assert(read_raw(rich_pom_path) == rich_pom, "List dependencies alterou pom.xml")
end

maven_profiles_provenance_spec()

local function maven_review_repairs_spec()
  local function report_for_pom(label, pom_text)
    local dir = tempdir(label)
    local pom_path = dir .. "/pom.xml"
    write_raw(pom_path, pom_text)
    return table.concat(
      deps._report_lines({
        root = dir,
        tool = "maven",
        modules = { dir },
        module = dir,
        build_file = pom_path,
        is_kotlin_dsl = false,
      }),
      "\n"
    )
  end

  -- 1) Sem BOM em nenhum lugar (nem projeto nem profile) + BOM em profile afetando projeto com DM
  local plain_no_bom_pom = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.plain</groupId>",
    "  <artifactId>app</artifactId>",
    "  <version>1.0</version>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>missing</artifactId>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>only-prof-dm</artifactId>",
    "    </dependency>",
    "  </dependencies>",
    "  <profiles>",
    "    <profile>",
    "      <id>p1</id>",
    "      <dependencyManagement>",
    "        <dependencies>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>only-prof-dm</artifactId>",
    "            <version>1.2.3</version>",
    "          </dependency>",
    "        </dependencies>",
    "      </dependencyManagement>",
    "    </profile>",
    "  </profiles>",
    "</project>",
  }, "\n")
  local plain_report = report_for_pom("maven-plain-no-bom", plain_no_bom_pom)
  assert(
    plain_report:find(
      "  - com.example:missing  (version missing (no <version>, exact <dependencyManagement>, BOM import, or <parent> in pom.xml))",
      1,
      true
    ),
    "versão ausente sem BOM em lugar algum divergiu:\n" .. plain_report
  )
  assert(
    plain_report:find(
      '  - com.example:only-prof-dm  (version missing at project level; conditional match in profile <dependencyManagement>: "p1" (1.2.3) (activation not evaluated))',
      1,
      true
    ),
    "match condicional sem BOM divergiu:\n" .. plain_report
  )

  local proj_dm_and_profile_bom_pom = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.pbom</groupId>",
    "  <artifactId>app</artifactId>",
    "  <version>1.0</version>",
    "  <dependencyManagement>",
    "    <dependencies>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>managed-proj</artifactId>",
    "        <version>1.0.0</version>",
    "      </dependency>",
    "    </dependencies>",
    "  </dependencyManagement>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>managed-proj</artifactId>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>unmanaged-proj</artifactId>",
    "    </dependency>",
    "  </dependencies>",
    "  <profiles>",
    "    <profile>",
    "      <id>bom-only</id>",
    "      <dependencyManagement>",
    "        <dependencies>",
    "          <dependency>",
    "            <groupId>org.springframework.boot</groupId>",
    "            <artifactId>spring-boot-dependencies</artifactId>",
    "            <version>3.2.5</version>",
    "            <type>pom</type>",
    "            <scope>import</scope>",
    "          </dependency>",
    "        </dependencies>",
    "      </dependencyManagement>",
    "    </profile>",
    "  </profiles>",
    "</project>",
  }, "\n")
  local pbom_report = report_for_pom("maven-proj-dm-prof-bom", proj_dm_and_profile_bom_pom)
  assert(
    pbom_report:find(
      '  - com.example:unmanaged-proj  (version unspecified locally; unverified: profile "bom-only" BOM import(s) (conditional) not resolved)',
      1,
      true
    ),
    "BOM de profile deve deixar projeto não resolvido condicionalmente:\n" .. pbom_report
  )
  assert(
    pbom_report:find(
      '  - com.example:managed-proj  (managed candidate in project <dependencyManagement>: 1.0.0; unverified: profile "bom-only" BOM import(s) (conditional) not resolved — effective version not proven)',
      1,
      true
    ),
    "BOM de profile deve impedir afirmação de versão efetiva:\n" .. pbom_report
  )
  assert(
    not pbom_report:find("  - com.example:managed-proj  (version=1.0.0", 1, true),
    "não pode afirmar version=1.0.0 com BOM condicional em profile:\n" .. pbom_report
  )
  local pbom_ins, _, pbom_ins_err = deps._insert_maven_dependency(proj_dm_and_profile_bom_pom, {
    groupId = "com.example",
    artifactId = "unmanaged-proj",
  })
  assert(pbom_ins == nil and pbom_ins_err and pbom_ins_err:find("<version> is required", 1, true))

  -- 2) Dependência em um profile gerenciada por outro profile + precedência profile > projeto
  local cross_profile_pom = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.cross</groupId>",
    "  <artifactId>app</artifactId>",
    "  <version>1.0</version>",
    "  <dependencyManagement>",
    "    <dependencies>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>shared</artifactId>",
    "        <version>1.0.0</version>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>multi-prof</artifactId>",
    "        <version>1.0.0</version>",
    "      </dependency>",
    "    </dependencies>",
    "  </dependencyManagement>",
    "  <profiles>",
    "    <profile>",
    "      <id>alpha</id>",
    "      <dependencyManagement>",
    "        <dependencies>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>alpha-only</artifactId>",
    "            <version>2.0.0</version>",
    "          </dependency>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>multi-prof</artifactId>",
    "            <version>5.0.0</version>",
    "          </dependency>",
    "        </dependencies>",
    "      </dependencyManagement>",
    "      <dependencies>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>shared</artifactId>",
    "        </dependency>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>only-beta</artifactId>",
    "        </dependency>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>multi-prof</artifactId>",
    "        </dependency>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>alpha-only</artifactId>",
    "        </dependency>",
    "      </dependencies>",
    "    </profile>",
    "    <profile>",
    "      <id>beta</id>",
    "      <dependencyManagement>",
    "        <dependencies>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>shared</artifactId>",
    "            <version>3.0.0</version>",
    "          </dependency>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>only-beta</artifactId>",
    "            <version>4.0.0</version>",
    "          </dependency>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>multi-prof</artifactId>",
    "            <version>6.0.0</version>",
    "          </dependency>",
    "        </dependencies>",
    "      </dependencyManagement>",
    "    </profile>",
    "  </profiles>",
    "</project>",
  }, "\n")
  local cross_report = report_for_pom("maven-cross-profile", cross_profile_pom)
  assert(
    cross_report:find(
      '      - com.example:shared  (managed candidate in project <dependencyManagement>: 1.0.0; conditional override in profile <dependencyManagement>: "beta" (3.0.0) (activation not evaluated) — effective version not proven)',
      1,
      true
    ),
    "override de outro profile sobre project DM dentro de alpha divergiu:\n" .. cross_report
  )
  assert(
    not cross_report:find("      - com.example:shared  (version=1.0.0", 1, true),
    "não pode afirmar version=1.0.0 quando beta pode sobrescrever:\n" .. cross_report
  )
  assert(
    cross_report:find(
      '      - com.example:only-beta  (version missing in profile "alpha" and project; conditional match in profile <dependencyManagement>: "beta" (4.0.0) (activation not evaluated))',
      1,
      true
    ),
    "dependência em alpha gerenciada só por beta divergiu:\n" .. cross_report
  )
  assert(
    cross_report:find(
      '      - com.example:multi-prof  (managed candidate in profile "alpha" <dependencyManagement>: 5.0.0 (conditional; overrides project <dependencyManagement> 1.0.0); other active profile(s) may also manage/override: "beta" (6.0.0) — effective version not proven)',
      1,
      true
    ),
    "conflito entre dois profiles gerenciando a mesma dependência divergiu:\n" .. cross_report
  )
  assert(
    not cross_report:find("      - com.example:multi-prof  (version=5.0.0", 1, true),
    "não pode afirmar version=5.0.0 quando beta também gerencia:\n" .. cross_report
  )
  assert(
    cross_report:find(
      '      - com.example:alpha-only  (version=2.0.0, managed by profile "alpha" <dependencyManagement>; conditional)',
      1,
      true
    ),
    "dependência exclusiva de alpha sem conflito divergiu:\n" .. cross_report
  )

  -- Profile com BOM + outro profile gerenciando dependência
  local cross_bom_pom = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.crossbom</groupId>",
    "  <artifactId>app</artifactId>",
    "  <version>1.0</version>",
    "  <profiles>",
    "    <profile>",
    "      <id>alpha</id>",
    "      <dependencyManagement>",
    "        <dependencies>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>alpha-item</artifactId>",
    "            <version>2.0.0</version>",
    "          </dependency>",
    "        </dependencies>",
    "      </dependencyManagement>",
    "      <dependencies>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>alpha-item</artifactId>",
    "        </dependency>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>unmanaged-in-alpha</artifactId>",
    "        </dependency>",
    "      </dependencies>",
    "    </profile>",
    "    <profile>",
    "      <id>gamma</id>",
    "      <dependencyManagement>",
    "        <dependencies>",
    "          <dependency>",
    "            <groupId>org.junit</groupId>",
    "            <artifactId>junit-bom</artifactId>",
    "            <version>5.10.2</version>",
    "            <type>pom</type>",
    "            <scope>import</scope>",
    "          </dependency>",
    "        </dependencies>",
    "      </dependencyManagement>",
    "    </profile>",
    "  </profiles>",
    "</project>",
  }, "\n")
  local cross_bom_report = report_for_pom("maven-cross-bom", cross_bom_pom)
  assert(
    cross_bom_report:find(
      '      - com.example:alpha-item  (managed candidate in profile "alpha" <dependencyManagement>: 2.0.0 (conditional); unverified: profile "gamma" BOM import(s) (conditional) not resolved — effective version not proven)',
      1,
      true
    ),
    "BOM de outro profile deve tornar versão condicional não comprovada:\n" .. cross_bom_report
  )
  assert(
    cross_bom_report:find(
      '      - com.example:unmanaged-in-alpha  (version unspecified locally; unverified: profile "gamma" BOM import(s) (conditional) not resolved)',
      1,
      true
    ),
    "BOM de outro profile deve aparecer como não resolvido condicional:\n" .. cross_bom_report
  )

  -- 3) Matching GATC (groupId, artifactId, type, classifier) + default jar/empty + duplicata conservadora
  local gatc_pom = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.gatc</groupId>",
    "  <artifactId>app</artifactId>",
    "  <version>1.0</version>",
    "  <dependencyManagement>",
    "    <dependencies>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>widget</artifactId>",
    "        <version>1.0.0</version>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>widget</artifactId>",
    "        <version>2.0.0</version>",
    "        <type>test-jar</type>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>widget</artifactId>",
    "        <version>3.0.0</version>",
    "        <classifier>tests</classifier>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>widget</artifactId>",
    "        <version>4.0.0</version>",
    "        <type>test-jar</type>",
    "        <classifier>shaded</classifier>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>explicit-jar</artifactId>",
    "        <version>1.1.0</version>",
    "        <type>jar</type>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>only-test-jar</artifactId>",
    "        <version>5.0.0</version>",
    "        <type>test-jar</type>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>only-classifier</artifactId>",
    "        <version>6.0.0</version>",
    "        <classifier>tests</classifier>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>com.example</groupId>",
    "        <artifactId>no-ver-entry</artifactId>",
    "      </dependency>",
    "    </dependencies>",
    "  </dependencyManagement>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>widget</artifactId>",
    "      <type>jar</type>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>explicit-jar</artifactId>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>widget</artifactId>",
    "      <type>test-jar</type>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>widget</artifactId>",
    "      <classifier>tests</classifier>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>widget</artifactId>",
    "      <type>war</type>",
    "    </dependency>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>widget</artifactId>",
    "      <type>test-jar</type>",
    "      <classifier>other</classifier>",
    "    </dependency>",
    "  </dependencies>",
    "  <profiles>",
    "    <profile>",
    "      <id>p-gatc</id>",
    "      <dependencyManagement>",
    "        <dependencies>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>widget</artifactId>",
    "            <version>9.9.9</version>",
    "            <classifier>linux-x86_64</classifier>",
    "          </dependency>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>explicit-jar</artifactId>",
    "            <version>1.9.0</version>",
    "          </dependency>",
    "          <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>only-test-jar</artifactId>",
    "            <version>5.5.0</version>",
    "            <type>test-jar</type>",
    "          </dependency>",
    "        </dependencies>",
    "      </dependencyManagement>",
    "      <dependencies>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>widget</artifactId>",
    "          <classifier>linux-x86_64</classifier>",
    "        </dependency>",
    "        <dependency>",
    "          <groupId>com.example</groupId>",
    "          <artifactId>only-test-jar</artifactId>",
    "        </dependency>",
    "      </dependencies>",
    "    </profile>",
    "  </profiles>",
    "</project>",
  }, "\n")

  local gatc_parsed = deps._parse_pom(gatc_pom)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "widget") == true)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "widget", "jar", "") == true)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "widget", "test-jar") == true)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "widget", nil, "tests") == true)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "widget", "test-jar", "shaded") == true)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "widget", "war") == false)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "widget", "test-jar", "other") == false)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "explicit-jar") == true)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "only-test-jar") == false)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "only-test-jar", "test-jar") == true)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "only-classifier") == false)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "only-classifier", nil, "tests") == true)
  assert(deps._is_exact_managed(gatc_parsed, "com.example", "no-ver-entry") == false)

  -- Omissão de versão só funciona quando GATC exato (com <version>) existe
  local bad_omit_type, _, bad_omit_type_err = deps._insert_maven_dependency(gatc_pom, {
    groupId = "com.example",
    artifactId = "only-test-jar",
    type = "jar",
  })
  assert(bad_omit_type == nil and bad_omit_type_err and bad_omit_type_err:find("<version> is required", 1, true))

  local ok_omit_type, ok_omit_meta, ok_omit_err = deps._insert_maven_dependency(gatc_pom, {
    groupId = "com.example",
    artifactId = "only-test-jar",
    type = "test-jar",
  })
  assert(ok_omit_type and ok_omit_meta.version_omitted == true and ok_omit_err == nil)
  assert(ok_omit_type:find("<type>test-jar</type>", 1, true), "type não emitido na inserção")

  local bad_omit_cls, _, bad_omit_cls_err = deps._insert_maven_dependency(gatc_pom, {
    groupId = "com.example",
    artifactId = "only-classifier",
  })
  assert(bad_omit_cls == nil and bad_omit_cls_err and bad_omit_cls_err:find("<version> is required", 1, true))

  local ok_omit_cls, ok_cls_meta, ok_cls_err = deps._insert_maven_dependency(gatc_pom, {
    groupId = "com.example",
    artifactId = "only-classifier",
    classifier = "tests",
  })
  assert(ok_omit_cls and ok_cls_meta.version_omitted == true and ok_cls_err == nil)
  assert(ok_omit_cls:find("<classifier>tests</classifier>", 1, true), "classifier não emitido na inserção")

  local bad_no_ver, _, bad_no_ver_err = deps._insert_maven_dependency(gatc_pom, {
    groupId = "com.example",
    artifactId = "no-ver-entry",
  })
  assert(bad_no_ver == nil and bad_no_ver_err and bad_no_ver_err:find("<version> is required", 1, true))

  -- Preserva comportamento conservador de duplicata por GA
  assert(deps._find_duplicate(gatc_parsed, "com.example", "widget") ~= nil)
  local dup_gatc, _, dup_gatc_err = deps._insert_maven_dependency(gatc_pom, {
    groupId = "com.example",
    artifactId = "widget",
    type = "test-jar",
    classifier = "sources",
    version = "9.0.0",
  })
  assert(dup_gatc == nil and dup_gatc_err and dup_gatc_err:find("already declared", 1, true))

  local gatc_report = report_for_pom("maven-gatc", gatc_pom)
  assert(
    gatc_report:find(
      "  - com.example:widget  (type=jar, version=1.0.0, managed by project <dependencyManagement>)",
      1,
      true
    ),
    "type=jar explícito deve casar com default omitido no DM:\n" .. gatc_report
  )
  assert(
    gatc_report:find(
      '  - com.example:explicit-jar  (managed candidate in project <dependencyManagement>: 1.1.0; conditional override in profile <dependencyManagement>: "p-gatc" (1.9.0) (activation not evaluated) — effective version not proven)',
      1,
      true
    ),
    "default omitido deve casar com type=jar explícito e reconhecer override de profile:\n" .. gatc_report
  )
  assert(
    gatc_report:find(
      "  - com.example:widget  (type=test-jar, version=2.0.0, managed by project <dependencyManagement>)",
      1,
      true
    ),
    "type=test-jar deve casar apenas com entrada test-jar:\n" .. gatc_report
  )
  assert(
    gatc_report:find(
      "  - com.example:widget  (classifier=tests, version=3.0.0, managed by project <dependencyManagement>)",
      1,
      true
    ),
    "classifier=tests deve casar apenas com entrada classifier=tests:\n" .. gatc_report
  )
  assert(
    gatc_report:find(
      "  - com.example:widget  (type=war, version missing (no <version>, exact <dependencyManagement>, BOM import, or <parent> in pom.xml))",
      1,
      true
    ),
    "type=war não pode alegar cobertura do DM de jar/test-jar:\n" .. gatc_report
  )
  assert(
    gatc_report:find(
      "  - com.example:widget  (type=test-jar, classifier=other, version missing (no <version>, exact <dependencyManagement>, BOM import, or <parent> in pom.xml))",
      1,
      true
    ),
    "classifier divergente não pode alegar cobertura:\n" .. gatc_report
  )
  assert(
    gatc_report:find(
      '      - com.example:widget:9.9.9  (classifier=linux-x86_64, provenance: profile "p-gatc" <dependencyManagement>)',
      1,
      true
    ),
    "classifier diferente no profile não pode afirmar override do projeto:\n" .. gatc_report
  )
  assert(
    not gatc_report:find(
      '9.9.9  (classifier=linux-x86_64, provenance: profile "p-gatc" <dependencyManagement>, overrides',
      1,
      true
    ),
    "classifier diferente no profile alegou override indevido:\n" .. gatc_report
  )
  assert(
    gatc_report:find(
      '      - com.example:explicit-jar:1.9.0  (provenance: profile "p-gatc" <dependencyManagement>, overrides project <dependencyManagement> 1.1.0 when active)',
      1,
      true
    ),
    "default jar no profile deve detectar override do type=jar do projeto:\n" .. gatc_report
  )
  assert(
    gatc_report:find(
      '      - com.example:widget  (classifier=linux-x86_64, version=9.9.9, managed by profile "p-gatc" <dependencyManagement>; conditional)',
      1,
      true
    ),
    "dependência no profile com classifier=linux-x86_64 deve casar com entrada do profile:\n" .. gatc_report
  )
  assert(
    gatc_report:find(
      "      - com.example:only-test-jar  (version missing (no <version>, exact <dependencyManagement>, BOM import, or <parent> in pom.xml))",
      1,
      true
    ),
    "dependência default jar no profile não pode casar com entrada test-jar:\n" .. gatc_report
  )
end

maven_review_repairs_spec()

local function maven_self_closing_dependencies_spec()
  -- 1) Expansão cirúrgica de <dependencies/> preservando comentários, trailing newline e follow-up/duplicata GA
  local sc_basic = table.concat({
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.sc</groupId>",
    "  <artifactId>app</artifactId>",
    "  <version>1.0</version>",
    "  <!-- keep above -->",
    "  <dependencies/>",
    "  <!-- keep below -->",
    "</project>",
    "",
  }, "\n")

  local exp_text, exp_meta, exp_err = deps._insert_maven_dependency(sc_basic, {
    groupId = "org.slf4j",
    artifactId = "slf4j-api",
    version = "2.0.13",
  })
  assert(exp_err == nil, "inserção em <dependencies/> falhou: " .. tostring(exp_err))
  assert(exp_meta.created_section == false, "expansão de <dependencies/> não cria nova seção")

  local exp_expected = table.concat({
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.sc</groupId>",
    "  <artifactId>app</artifactId>",
    "  <version>1.0</version>",
    "  <!-- keep above -->",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>org.slf4j</groupId>",
    "      <artifactId>slf4j-api</artifactId>",
    "      <version>2.0.13</version>",
    "    </dependency>",
    "  </dependencies>",
    "  <!-- keep below -->",
    "</project>",
    "",
  }, "\n")
  assert(exp_text == exp_expected, "expansão de <dependencies/> divergiu:\n" .. tostring(exp_text))

  -- Segunda inserção no POM já expandido + política conservadora de duplicata por GA
  local second_text, second_meta, second_err = deps._insert_maven_dependency(exp_text, {
    groupId = "junit",
    artifactId = "junit",
    version = "4.13.2",
    scope = "test",
  })
  assert(
    second_err == nil and second_meta.created_section == false,
    "segunda inserção falhou: " .. tostring(second_err)
  )
  assert(second_text:find("<artifactId>junit</artifactId>", 1, true) ~= nil)

  local dup_sc, dup_sc_meta, dup_sc_err = deps._insert_maven_dependency(exp_text, {
    groupId = "org.slf4j",
    artifactId = "slf4j-api",
    type = "test-jar",
    classifier = "tests",
    version = "2.0.16",
  })
  assert(dup_sc == nil and dup_sc_meta == nil)
  assert(
    dup_sc_err and dup_sc_err:find("already declared", 1, true),
    "duplicata GA conservadora falhou: " .. tostring(dup_sc_err)
  )

  -- 2) Variações: <dependencies /> com 4 espaços, multiline com tabs, atributos, inline, comentários na mesma linha, sem newline final
  local sc_4space = table.concat({
    "<project>",
    "    <dependencies />",
    "</project>",
  }, "\n")
  local out_4space, meta_4space, err_4space = deps._insert_maven_dependency(sc_4space, {
    groupId = "com.example",
    artifactId = "lib4",
    version = "1.0",
  })
  assert(err_4space == nil and meta_4space.created_section == false)
  assert(out_4space == table.concat({
    "<project>",
    "    <dependencies>",
    "        <dependency>",
    "            <groupId>com.example</groupId>",
    "            <artifactId>lib4</artifactId>",
    "            <version>1.0</version>",
    "        </dependency>",
    "    </dependencies>",
    "</project>",
  }, "\n"), "variação 4 espaços sem trailing newline divergiu:\n" .. tostring(out_4space))

  local sc_tabs_multiline = table.concat({
    "<project>",
    "\t<modelVersion>4.0.0</modelVersion>",
    "\t<dependencies",
    "\t\t/>",
    "</project>",
  }, "\n")
  local out_tabs, meta_tabs, err_tabs = deps._insert_maven_dependency(sc_tabs_multiline, {
    groupId = "com.example",
    artifactId = "tablib",
    version = "1.2",
  })
  assert(err_tabs == nil and meta_tabs.created_section == false)
  assert(out_tabs == table.concat({
    "<project>",
    "\t<modelVersion>4.0.0</modelVersion>",
    "\t<dependencies>",
    "\t\t<dependency>",
    "\t\t\t<groupId>com.example</groupId>",
    "\t\t\t<artifactId>tablib</artifactId>",
    "\t\t\t<version>1.2</version>",
    "\t\t</dependency>",
    "\t</dependencies>",
    "</project>",
  }, "\n"), "variação multiline/tabs divergiu:\n" .. tostring(out_tabs))

  local sc_attrs = '<project>\n  <dependencies xml:space="preserve" />\n</project>'
  local out_attrs, _, err_attrs = deps._insert_maven_dependency(sc_attrs, {
    groupId = "com.example",
    artifactId = "attrlib",
    version = "1.0",
  })
  assert(err_attrs == nil)
  assert(
    out_attrs:find('<dependencies xml:space="preserve">\n    <dependency>', 1, true) ~= nil,
    "atributos de <dependencies /> não preservados:\n" .. tostring(out_attrs)
  )

  local sc_inline_comments = "<project>\n  <!-- lead --><dependencies/> <!-- trail -->\n</project>"
  local out_inline_comments, _, err_inline_comments = deps._insert_maven_dependency(sc_inline_comments, {
    groupId = "com.example",
    artifactId = "inline",
    version = "1.0",
  })
  assert(err_inline_comments == nil)
  assert(out_inline_comments == table.concat({
    "<project>",
    "  <!-- lead --><dependencies>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>inline</artifactId>",
    "      <version>1.0</version>",
    "    </dependency>",
    "  </dependencies> <!-- trail -->",
    "</project>",
  }, "\n"), "comentários na mesma linha de <dependencies/> divergiram:\n" .. tostring(out_inline_comments))

  local sc_single_line = "<project><dependencies/></project>"
  local out_single_line, meta_single_line, err_single_line = deps._insert_maven_dependency(sc_single_line, {
    groupId = "com.example",
    artifactId = "single",
    version = "1.0",
  })
  assert(err_single_line == nil and meta_single_line.created_section == false)
  assert(out_single_line == table.concat({
    "<project><dependencies>",
    "    <dependency>",
    "      <groupId>com.example</groupId>",
    "      <artifactId>single</artifactId>",
    "      <version>1.0</version>",
    "    </dependency>",
    "  </dependencies></project>",
  }, "\n"), "single-line <project><dependencies/></project> divergiu:\n" .. tostring(out_single_line))

  -- 3) Preservação estrita de CRLF (\r\n)
  local sc_crlf = sc_basic:gsub("\n", "\r\n")
  local out_crlf, meta_crlf, err_crlf = deps._insert_maven_dependency(sc_crlf, {
    groupId = "org.slf4j",
    artifactId = "slf4j-api",
    version = "2.0.13",
  })
  assert(err_crlf == nil and meta_crlf.created_section == false)
  assert(out_crlf:find("[^\r]\n") == nil, "expansão CRLF introduziu LF puro")
  assert(out_crlf == exp_expected:gsub("\n", "\r\n"), "expansão CRLF divergiu")

  -- 4) Não editar <build>, <profiles>, <dependencyManagement> ou comentários com <dependencies/>
  local non_project_sc = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <!-- <dependencies/> -->",
    "  <dependencyManagement>",
    "    <dependencies/>",
    "  </dependencyManagement>",
    "  <build>",
    "    <plugins>",
    "      <plugin>",
    "        <artifactId>p</artifactId>",
    "        <dependencies/>",
    "      </plugin>",
    "    </plugins>",
    "  </build>",
    "  <profiles>",
    "    <profile>",
    "      <id>extra</id>",
    "      <dependencies/>",
    "    </profile>",
    "  </profiles>",
    "</project>",
  }, "\n")
  local np_out, np_meta, np_err = deps._insert_maven_dependency(non_project_sc, {
    groupId = "com.example",
    artifactId = "proj-only",
    version = "1.0",
  })
  assert(
    np_err == nil and np_meta.created_section == true,
    "deveria criar seção de projeto ignorando <dependencies/> não-projeto"
  )
  assert(np_out:find("  <!-- <dependencies/> -->", 1, true) ~= nil)
  assert(np_out:find("  <dependencyManagement>\n    <dependencies/>\n  </dependencyManagement>", 1, true) ~= nil)
  assert(np_out:find("        <dependencies/>\n      </plugin>", 1, true) ~= nil)
  assert(np_out:find("      <id>extra</id>\n      <dependencies/>\n    </profile>", 1, true) ~= nil)

  local both_sc = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <!-- <dependencies/> -->",
    "  <build>",
    "    <plugins>",
    "      <plugin>",
    "        <artifactId>p</artifactId>",
    "        <dependencies/>",
    "      </plugin>",
    "    </plugins>",
    "  </build>",
    "  <profiles>",
    "    <profile>",
    "      <id>extra</id>",
    "      <dependencies/>",
    "    </profile>",
    "  </profiles>",
    "  <dependencies/>",
    "</project>",
  }, "\n")
  local both_out, both_meta, both_err = deps._insert_maven_dependency(both_sc, {
    groupId = "com.example",
    artifactId = "proj-sc",
    version = "1.0",
  })
  assert(both_err == nil and both_meta.created_section == false)
  assert(both_out:find("        <dependencies/>\n      </plugin>", 1, true) ~= nil, "<build> foi alterado")
  assert(
    both_out:find("      <id>extra</id>\n      <dependencies/>\n    </profile>", 1, true) ~= nil,
    "<profile> foi alterado"
  )
  assert(
    both_out:find(
      "  <dependencies>\n    <dependency>\n      <groupId>com.example</groupId>\n      <artifactId>proj-sc</artifactId>\n      <version>1.0</version>\n    </dependency>\n  </dependencies>\n</project>",
      1,
      true
    ) ~= nil
  )

  -- 5) Comportamento managed / BOM / parent com <dependencies/>
  local dm_sc = table.concat({
    "<project>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <dependencyManagement>",
    "    <dependencies>",
    "      <dependency>",
    "        <groupId>com.fasterxml.jackson.core</groupId>",
    "        <artifactId>jackson-databind</artifactId>",
    "        <version>2.17.0</version>",
    "      </dependency>",
    "      <dependency>",
    "        <groupId>org.junit</groupId>",
    "        <artifactId>junit-bom</artifactId>",
    "        <version>5.10.0</version>",
    "        <type>pom</type>",
    "        <scope>import</scope>",
    "      </dependency>",
    "    </dependencies>",
    "  </dependencyManagement>",
    "  <dependencies/>",
    "</project>",
  }, "\n")

  local dm_out, dm_meta, dm_err = deps._insert_maven_dependency(dm_sc, {
    groupId = "com.fasterxml.jackson.core",
    artifactId = "jackson-databind",
  })
  assert(dm_err == nil and dm_meta.created_section == false)
  assert(dm_meta.version_omitted == true and dm_meta.bom_note == nil)
  assert(dm_out:find("<artifactId>jackson-databind</artifactId>\n    </dependency>\n  </dependencies>", 1, true) ~= nil)

  local bom_out, bom_meta, bom_err = deps._insert_maven_dependency(dm_sc, {
    groupId = "org.junit.jupiter",
    artifactId = "junit-jupiter-api",
  })
  assert(bom_err == nil and bom_meta.created_section == false and bom_meta.version_omitted == true)
  assert(bom_meta.bom_note and bom_meta.bom_note:find("BOM", 1, true) ~= nil)
  assert(
    bom_out:find("<artifactId>junit-jupiter-api</artifactId>\n    </dependency>\n  </dependencies>", 1, true) ~= nil
  )

  local unm_out, _, unm_err = deps._insert_maven_dependency(sc_basic, {
    groupId = "com.x",
    artifactId = "y",
  })
  assert(unm_out == nil and unm_err and unm_err:find("<version> is required", 1, true) ~= nil)

  local parent_sc = table.concat({
    "<project>",
    "  <parent>",
    "    <groupId>com.corp</groupId>",
    "    <artifactId>parent</artifactId>",
    "    <version>1</version>",
    "  </parent>",
    "  <modelVersion>4.0.0</modelVersion>",
    "  <artifactId>child</artifactId>",
    "  <dependencies/>",
    "</project>",
  }, "\n")
  local parent_out, parent_meta, parent_err = deps._insert_maven_dependency(parent_sc, {
    groupId = "com.x",
    artifactId = "y",
  })
  assert(parent_err == nil and parent_meta.created_section == false and parent_meta.version_omitted == true)
  assert(parent_meta.bom_note and parent_meta.bom_note:find("<parent>", 1, true) ~= nil)
  assert(
    parent_out:find(
      "  <dependencies>\n    <dependency>\n      <groupId>com.x</groupId>\n      <artifactId>y</artifactId>\n    </dependency>\n  </dependencies>",
      1,
      true
    ) ~= nil
  )

  -- 6) Tag malformada (sem </dependencies> e não auto-fechada) continua falhando com erro claro
  local unclosed_open, _, unclosed_open_err = deps._insert_maven_dependency("<project>\n  <dependencies>\n</project>", {
    groupId = "com.x",
    artifactId = "y",
    version = "1.0",
  })
  assert(
    unclosed_open == nil
      and unclosed_open_err
      and unclosed_open_err:find("could not find the closing </dependencies>", 1, true) ~= nil
  )
  local unclosed_gt, _, unclosed_gt_err = deps._insert_maven_dependency("<project>\n  <dependencies\n</project>", {
    groupId = "com.x",
    artifactId = "y",
    version = "1.0",
  })
  assert(
    unclosed_gt == nil
      and unclosed_gt_err
      and unclosed_gt_err:find("could not find the closing </dependencies>", 1, true) ~= nil
  )

  -- 7) Fluxo interativo M.add + recusa com buffer modificado em POM com <dependencies/>
  local dir = tempdir("sc-add")
  local pom_path = dir .. "/pom.xml"
  write_raw(pom_path, sc_basic)
  local pom_b = buffer_for(pom_path)
  vim.api.nvim_buf_set_lines(pom_b, 0, -1, false, vim.split(sc_basic, "\n", { plain = true }))
  vim.bo[pom_b].modified = true

  notices = {}
  stub_ui(
    { "Enter coordinates manually", "compile (default)", "Add dependency" },
    { "org.slf4j", "slf4j-api", "2.0.13" }
  )
  deps.add(pom_b)
  assert(has_notice("unsaved changes"), "M.add deveria recusar escrita com buffer modificado")
  assert(read_raw(pom_path) == sc_basic, "pom.xml com <dependencies/> foi alterado apesar de buffer modificado")

  vim.bo[pom_b].modified = false
  notices = {}
  stub_ui(
    { "Enter coordinates manually", "compile (default)", "Add dependency" },
    { "org.slf4j", "slf4j-api", "2.0.13" }
  )
  deps.add(pom_b)
  assert(read_raw(pom_path) == exp_expected, "M.add não expandiu <dependencies/> corretamente em disco")
  assert(
    table.concat(vim.api.nvim_buf_get_lines(pom_b, 0, -1, false), "\n") .. "\n" == exp_expected,
    "buffer limpo não foi recarregado após expansão de <dependencies/>"
  )
  vim.api.nvim_buf_delete(pom_b, { force = true })
end

maven_self_closing_dependencies_spec()

local function gradle_edit_core_spec()
  -- ---------- 20. Gradle editing core: Groovy + Kotlin, comentários, estilo, CRLF, catálogo, recusa segura ----------

  local cat_toml = table.concat({
    "[versions]",
    'junit = "5.10.2"',
    'guava = "33.1.0-jre"',
    "",
    "[libraries]",
    'junit-jupiter = { module = "org.junit.jupiter:junit-jupiter", version.ref = "junit" }',
    'guava = { group = "com.google.guava", name = "guava", version.ref = "guava" }',
    'slf4j-api = "org.slf4j:slf4j-api:2.0.20"',
    'bundles-placeholder = "com.example:placeholder:1.0.0"',
    "",
    "[bundles]",
    'testing = ["junit-jupiter"]',
  }, "\n")
  local cat = deps._parse_version_catalog(cat_toml)

  -- A) Groovy DSL: inserção preservando comentários, buildscript, indentação e estilo
  local groovy_src = table.concat({
    "// header comment",
    "plugins {",
    "    id 'java'",
    "}",
    "",
    "buildscript {",
    "    dependencies {",
    "        classpath 'com.example:plugin:1.0.0'",
    "    }",
    "}",
    "",
    "/* block comment before dependencies",
    "   dependencies { implementation 'fake:commented:1.0' } */",
    "dependencies { // keep opening comment",
    "    // keep leading comment",
    "    implementation 'org.slf4j:slf4j-api:2.0.20' // keep inline",
    "    testImplementation(libs.junit.jupiter)",
    "    implementation group: 'com.fasterxml.jackson.core', name: 'jackson-core', version: '2.17.1'",
    "    implementation project(':core')",
    "    // keep trailing comment",
    "} // keep closing comment",
    "",
  }, "\n")

  local g_out, g_meta, g_err = deps._insert_gradle_dependency(groovy_src, {
    groupId = "com.google.guava",
    artifactId = "guava",
    version = "33.1.0-jre",
    configuration = "api",
  }, { is_kotlin_dsl = false, catalog = cat, build_file = "build.gradle" })
  assert(g_err == nil and g_out, "inserção Groovy falhou: " .. tostring(g_err))
  assert(g_meta.created_section == false and g_meta.version_omitted == false)
  assert(g_meta.configuration == "api")
  assert(g_meta.rendered_line == "    api 'com.google.guava:guava:33.1.0-jre'")
  assert(g_meta.catalog_note and g_meta.catalog_note:find("libs.guava", 1, true))
  local g_expected = groovy_src:gsub(
    "    // keep trailing comment\n} // keep closing comment",
    "    // keep trailing comment\n    api 'com.google.guava:guava:33.1.0-jre'\n} // keep closing comment",
    1
  )
  assert(g_out == g_expected, "inserção Groovy alterou bytes fora do alvo:\n" .. g_out)

  -- Groovy estilos: parens + aspas duplas, tabs, bloco vazio e inline
  local groovy_parens_dq = table.concat({
    "dependencies {",
    '  implementation("org.slf4j:slf4j-api:2.0.20")',
    "}",
    "",
  }, "\n")
  local gp_out = deps._insert_gradle_dependency(groovy_parens_dq, {
    groupId = "junit",
    artifactId = "junit",
    version = "4.13.2",
    configuration = "testImplementation",
  }, { is_kotlin_dsl = false })
  assert(
    gp_out
      == 'dependencies {\n  implementation("org.slf4j:slf4j-api:2.0.20")\n  testImplementation("junit:junit:4.13.2")\n}\n',
    "estilo Groovy parens+dq não foi preservado: " .. tostring(gp_out)
  )

  local groovy_tabs = "plugins {\n\tid 'java'\n}\ndependencies {}\n"
  local gt_out = deps._insert_gradle_dependency(groovy_tabs, {
    groupId = "com.example",
    artifactId = "tabbed",
    version = "1.0.0",
  }, { is_kotlin_dsl = false })
  assert(
    gt_out == "plugins {\n\tid 'java'\n}\ndependencies {\n\timplementation 'com.example:tabbed:1.0.0'\n}\n",
    "expansão de dependencies {} com tabs divergiu: " .. tostring(gt_out)
  )

  local groovy_inline = "dependencies { implementation 'a:b:1.0' }\n"
  local gi_out = deps._insert_gradle_dependency(groovy_inline, {
    groupId = "c",
    artifactId = "d",
    version = "2.0",
  }, { is_kotlin_dsl = false })
  assert(
    gi_out == "dependencies { implementation 'a:b:1.0' \n  implementation 'c:d:2.0'\n}\n",
    "expansão de dependencies inline divergiu: " .. tostring(gi_out)
  )

  local groovy_inline_ws = "  dependencies { implementation 'a:b:1.0'\t  } // keep\n"
  local gi_ws_out = deps._insert_gradle_dependency(groovy_inline_ws, {
    groupId = "c",
    artifactId = "d",
    version = "2.0",
  }, { is_kotlin_dsl = false })
  assert(
    gi_ws_out == "  dependencies { implementation 'a:b:1.0'\t  \n    implementation 'c:d:2.0'\n  } // keep\n",
    "trailing whitespace antes de } não preservado em bloco inline: " .. tostring(gi_ws_out)
  )

  local groovy_empty_ws = "dependencies {   }\n"
  local gew_out = deps._insert_gradle_dependency(groovy_empty_ws, {
    groupId = "c",
    artifactId = "d",
    version = "2.0",
  }, { is_kotlin_dsl = false })
  assert(
    gew_out == "dependencies {   \n  implementation 'c:d:2.0'\n}\n",
    "trailing whitespace antes de } não preservado em bloco vazio com espaços: " .. tostring(gew_out)
  )

  -- Criação de nova seção dependencies quando ausente (sem alterar buildscript)
  local no_deps_groovy = table.concat({
    "plugins {",
    "    id 'java'",
    "}",
    "buildscript {",
    "    dependencies {",
    "        classpath 'com.example:tool:1.0'",
    "    }",
    "}",
    "",
  }, "\n")
  local nd_out, nd_meta, nd_err = deps._insert_gradle_dependency(no_deps_groovy, {
    groupId = "org.slf4j",
    artifactId = "slf4j-api",
    version = "2.0.20",
  }, { is_kotlin_dsl = false })
  assert(nd_err == nil and nd_meta.created_section == true)
  assert(
    nd_out == no_deps_groovy .. "\ndependencies {\n    implementation 'org.slf4j:slf4j-api:2.0.20'\n}\n",
    "criação de seção dependencies falhou:\n" .. tostring(nd_out)
  )

  -- B) Kotlin DSL: comentários aninhados, CRLF, argumentos nomeados/posicionais, platform/BOM
  local kts_src = table.concat({
    '/* outer /* nested dependencies { implementation("x:y:1") } */ end */',
    "plugins {",
    '    id("java")',
    "}",
    "",
    "dependencies {",
    '    implementation("org.slf4j:slf4j-api:2.0.20") // inline',
    "    testImplementation(libs.junit.jupiter)",
    '    api(group = "com.example", name = "named-lib", version = "1.1.0")',
    '    compileOnly("com.example", "pos-lib", "2.0.0")',
    '    implementation(project(":shared"))',
    "}",
    "",
  }, "\n")
  local kts_crlf = kts_src:gsub("\n", "\r\n")
  local k_out, k_meta, k_err = deps._insert_gradle_dependency(kts_crlf, {
    groupId = "com.google.guava",
    artifactId = "guava",
    version = "33.1.0-jre",
    configuration = "runtimeOnly",
  }, { is_kotlin_dsl = true, catalog = cat, build_file = "build.gradle.kts" })
  assert(k_err == nil and k_out, "inserção Kotlin CRLF falhou: " .. tostring(k_err))
  assert(k_out:find("[^\r]\n") == nil, "inserção Kotlin CRLF introduziu LF puro")
  assert(k_meta.rendered_line == '    runtimeOnly("com.google.guava:guava:33.1.0-jre")')
  assert(
    k_out:find(
      '    implementation(project(":shared"))\r\n    runtimeOnly("com.google.guava:guava:33.1.0-jre")\r\n}',
      1,
      true
    ),
    "bloco Kotlin CRLF mal posicionado:\n" .. k_out
  )

  -- CRLF na criação de nova seção
  local kts_no_deps_crlf = 'plugins {\r\n  kotlin("jvm")\r\n}'
  local knd_out, knd_meta = deps._insert_gradle_dependency(kts_no_deps_crlf, {
    groupId = "org.slf4j",
    artifactId = "slf4j-api",
    version = "2.0.20",
  }, { is_kotlin_dsl = true })
  assert(knd_out and knd_meta.created_section == true)
  assert(knd_out:find("[^\r]\n") == nil, "criação de seção CRLF introduziu LF puro")
  assert(
    knd_out
      == 'plugins {\r\n  kotlin("jvm")\r\n}\r\n\r\ndependencies {\r\n  implementation("org.slf4j:slf4j-api:2.0.20")\r\n}',
    "criação de seção CRLF sem newline final divergiu"
  )

  -- Platform/BOM permite omitir versão com ressalva honesta; sem BOM exige versão
  local _, _, no_ver_err = deps._insert_gradle_dependency(kts_src, {
    groupId = "com.example",
    artifactId = "unmanaged",
  }, { is_kotlin_dsl = true, catalog = cat })
  assert(no_ver_err and no_ver_err:find("version is required", 1, true))

  local bom_kts = table.concat({
    "dependencies {",
    '  implementation(platform("org.springframework.boot:spring-boot-dependencies:3.2.5"))',
    "}",
    "",
  }, "\n")
  local bom_out, bom_meta, bom_err = deps._insert_gradle_dependency(bom_kts, {
    groupId = "org.springframework.boot",
    artifactId = "spring-boot-starter-web",
  }, { is_kotlin_dsl = true })
  assert(bom_err == nil and bom_out and bom_meta.version_omitted == true)
  assert(bom_meta.bom_note and bom_meta.bom_note:find("platform/BOM", 1, true))
  assert(bom_out:find('  implementation("org.springframework.boot:spring-boot-starter-web")\n', 1, true))
  local bom_dup, _, bom_dup_err = deps._insert_gradle_dependency(bom_kts, {
    groupId = "org.springframework.boot",
    artifactId = "spring-boot-dependencies",
    version = "3.2.5",
  }, { is_kotlin_dsl = true })
  assert(bom_dup == nil and bom_dup_err and bom_dup_err:find("already declared", 1, true))

  -- C) Dedupe (literal, catálogo libs.*, map/named/posicional, platform)
  for _, dup in ipairs({
    { groupId = "org.slf4j", artifactId = "slf4j-api", version = "2.0.99" },
    { groupId = "org.junit.jupiter", artifactId = "junit-jupiter", version = "5.11.0" },
    { groupId = "com.fasterxml.jackson.core", artifactId = "jackson-core", version = "2.18.0" },
  }) do
    local res, _, err = deps._insert_gradle_dependency(groovy_src, dup, { is_kotlin_dsl = false, catalog = cat })
    assert(
      res == nil and err and err:find("already declared", 1, true),
      "duplicata Groovy não recusada: " .. tostring(err)
    )
  end
  for _, dup in ipairs({
    { groupId = "org.slf4j", artifactId = "slf4j-api", version = "2.0.99" },
    { groupId = "org.junit.jupiter", artifactId = "junit-jupiter", version = "5.11.0" },
    { groupId = "com.example", artifactId = "named-lib", version = "9.9.9" },
    { groupId = "com.example", artifactId = "pos-lib", version = "9.9.9" },
  }) do
    local res, _, err = deps._insert_gradle_dependency(kts_src, dup, { is_kotlin_dsl = true, catalog = cat })
    assert(
      res == nil and err and err:find("already declared", 1, true),
      "duplicata Kotlin não recusada: " .. tostring(err)
    )
  end

  -- D) Validação / bloqueio de injeção e configuração inválida
  for _, bad in ipairs({
    { groupId = "com.bad$x", artifactId = "a", version = "1.0" },
    { groupId = 'com.bad"x', artifactId = "a", version = "1.0" },
    { groupId = "com.bad'x", artifactId = "a", version = "1.0" },
    { groupId = "com.bad:x", artifactId = "a", version = "1.0" },
    { groupId = "com.bad", artifactId = "a", version = "1.0", configuration = "classpath" },
    { groupId = "com.bad", artifactId = "a", version = "1.0", configuration = "weirdConfig" },
  }) do
    local res, _, err = deps._insert_gradle_dependency(kts_src, bad, { is_kotlin_dsl = true })
    assert(res == nil and err ~= nil, "entrada inválida aceita: " .. vim.inspect(bad))
  end

  -- E) Recusa de construtos ambíguos, dinâmicos e parciais não suportados (Groovy e Kotlin)
  local amb_cat = deps._parse_version_catalog('[libraries]\nfoo-bar = "com.example:a:1"\nfoo_bar = "com.example:b:2"\n')
  local unsupported_cases = {
    {
      "multiple blocks",
      false,
      "dependencies {\n  implementation 'a:b:1'\n}\ndependencies {\n  implementation 'c:d:2'\n}\n",
    },
    {
      "multiple blocks kts",
      true,
      'dependencies {\n  implementation("a:b:1")\n}\ndependencies {\n  implementation("c:d:2")\n}\n',
    },
    { "subprojects", false, "subprojects {\n  dependencies {\n    implementation 'a:b:1'\n  }\n}\n" },
    { "allprojects", true, 'allprojects {\n  dependencies {\n    implementation("a:b:1")\n  }\n}\n' },
    { "qualified receiver", true, 'other.dependencies {\n  implementation("a:b:1")\n}\n' },
    { "dependencies.apply", true, 'dependencies.apply {\n  implementation("a:b:1")\n}\n' },
    { "with(dependencies)", true, 'with(dependencies) {\n  implementation("a:b:1")\n}\n' },
    { "dependencies({ ... })", true, 'dependencies({\n  implementation("a:b:1")\n})\n' },
    { "apply from groovy", false, "apply from: 'deps.gradle'\ndependencies {\n  implementation 'a:b:1'\n}\n" },
    { "apply(from) kts", true, 'apply(from = "deps.gradle.kts")\ndependencies {\n  implementation("a:b:1")\n}\n' },
    { "apply { from }", false, "apply {\n  from 'deps.gradle'\n}\ndependencies {\n  implementation 'a:b:1'\n}\n" },
    { "dynamic interpolation groovy", false, 'dependencies {\n  implementation "com.dyn:$ver"\n}\n' },
    {
      "dynamic interpolation kts",
      true,
      'dependencies {\n  implementation("org.slf4j:slf4j-api:2.0.20")\n  implementation("com.dyn:${ver}")\n}\n',
    },
    { "concat kts", true, 'dependencies {\n  implementation("com.dyn:a:" + ver)\n}\n' },
    {
      "if inside deps",
      true,
      'dependencies {\n  implementation("org.slf4j:slf4j-api:2.0.20")\n  if (hasProperty("x")) {\n    implementation("a:b:1")\n  }\n}\n',
    },
    { "val inside deps", true, 'dependencies {\n  val v = "1.0"\n  implementation("a:b:1")\n}\n' },
    { "def inside deps", false, "dependencies {\n  def v = '1.0'\n  implementation 'a:b:1'\n}\n" },
    {
      "constraints block",
      true,
      'dependencies {\n  implementation("org.slf4j:slf4j-api:2.0.20")\n  constraints {\n    implementation("a:b:1")\n  }\n}\n',
    },
    {
      "files()",
      false,
      "dependencies {\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n  runtimeOnly files('libs/a.jar')\n}\n",
    },
    { "bundle accessor", true, "dependencies {\n  implementation(libs.bundles.testing)\n}\n" },
    { "unknown catalog alias", true, "dependencies {\n  implementation(libs.missing.alias)\n}\n" },
    { "ambiguous catalog alias", true, "dependencies {\n  implementation(libs.foo.bar)\n}\n", amb_cat },
    { "custom configuration", true, 'dependencies {\n  customConfig("a:b:1")\n}\n' },
    { "unterminated comment", true, 'dependencies {\n  /* unclosed\n  implementation("a:b:1")\n}\n' },
    { "unterminated string", false, "dependencies {\n  implementation 'a:b:1\n}\n" },
    { "unbalanced brace", true, 'dependencies {\n  implementation("a:b:1")\n' },
  }

  for _, case in ipairs(unsupported_cases) do
    local label, is_kts, text, custom_cat = case[1], case[2], case[3], case[4] or cat
    local out, _, err = deps._insert_gradle_dependency(text, {
      groupId = "com.example",
      artifactId = "safe",
      version = "1.0.0",
    }, { is_kotlin_dsl = is_kts, catalog = custom_cat })
    assert(
      out == nil and type(err) == "string" and err ~= "",
      ("caso não suportado '%s' deveria ter sido recusado"):format(label)
    )
  end
end

gradle_edit_core_spec()

local function gradle_edit_interactive_spec()
  -- ---------- 21. Gradle editing shell: preview, confirmação, cancelamentos, unsaved, symlinks, multi-módulo ----------

  local real_client = lsp.client
  local real_search = deps._search_maven

  -- A) Groovy DSL fluxo interativo completo + preview + no-overwrite + cancelamentos
  local g_dir = tempdir("gradle-edit-groovy")
  write_raw(g_dir .. "/settings.gradle", 'rootProject.name = "groovy-edit"\n')
  local g_initial = table.concat({
    "// keep top comment",
    "plugins {",
    "  id 'java'",
    "}",
    "",
    "dependencies {",
    "  // keep existing comment",
    "  implementation 'org.slf4j:slf4j-api:2.0.20'",
    "}",
    "",
  }, "\n")
  local g_build = g_dir .. "/build.gradle"
  write_raw(g_build, g_initial)
  local g_buf = buffer_for(g_build)

  -- Cancelamento na confirmação final não altera nada em disco
  stub_ui(
    { "Add dependency", "Enter coordinates manually", "testImplementation", "✖ Cancel" },
    { "junit", "junit", "4.13.2" }
  )
  notices = {}
  deps.menu(g_buf)
  assert(read_raw(g_build) == g_initial, "cancelar na confirmação alterou build.gradle")
  assert(not has_notice("added "), "cancelamento não pode notificar sucesso")
  local confirm_items = table.concat(select_calls[4].items, "\n")
  assert(confirm_items:find("configuration: testImplementation", 1, true), "preview sem configuration")
  assert(
    confirm_items:find("preview: testImplementation 'junit:junit:4.13.2'", 1, true),
    "preview sem linha renderizada"
  )
  assert(confirm_items:find("target: build.gradle", 1, true), "preview sem target")

  -- Cancelamento no meio (Esc na versão) não altera nada
  stub_ui({ "Add dependency", "Enter coordinates manually" }, { "junit", "junit", false })
  deps.menu(g_buf)
  assert(read_raw(g_build) == g_initial, "cancelar na versão alterou build.gradle")

  -- Confirmação insere cirurgicamente preservando comentários + recarrega buffer limpo
  stub_ui(
    { "Add dependency", "Enter coordinates manually", "testImplementation", "✔ Add dependency" },
    { "junit", "junit", "4.13.2" }
  )
  notices = {}
  deps.menu(g_buf)
  local g_after = read_raw(g_build)
  assert(g_after:find("// keep top comment", 1, true), "comentário de topo perdido")
  assert(
    g_after:find(
      "  // keep existing comment\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n  testImplementation 'junit:junit:4.13.2'\n}",
      1,
      true
    )
  )
  assert(has_notice("added junit:junit:4.13.2 to build.gradle"), "sucesso Groovy não notificado: " .. last_notice())

  -- Buffer modificado (unsaved) recusa escrita sem tocar o arquivo
  vim.bo[g_buf].modified = true
  notices = {}
  stub_ui({ "Enter coordinates manually", "api", "✔ Add dependency" }, { "com.example", "unsaved-block", "1.0.0" })
  deps.add(g_buf)
  assert(has_notice("unsaved changes"), "buffer modificado em Gradle não foi recusado: " .. last_notice())
  assert(read_raw(g_build) == g_after, "build.gradle foi modificado apesar de buffer unsaved")
  vim.bo[g_buf].modified = false

  -- B) Kotlin DSL + Version Catalog (read-only) + Maven Central search + JDTLS sync
  local k_dir = tempdir("gradle-edit-kts")
  write_raw(k_dir .. "/settings.gradle.kts", 'rootProject.name = "kts-edit"\n')
  local k_cat_initial = table.concat({
    "[versions]",
    'slf4j = "2.0.20"',
    "",
    "[libraries]",
    'slf4j-api = { module = "org.slf4j:slf4j-api", version.ref = "slf4j" }',
    'guava = "com.google.guava:guava:33.1.0-jre"',
    "",
  }, "\n")
  write_raw(k_dir .. "/gradle/libs.versions.toml", k_cat_initial)
  local k_initial = table.concat({
    "plugins {",
    "  java",
    "}",
    "",
    "dependencies {",
    "  implementation(libs.slf4j.api)",
    "}",
    "",
  }, "\n")
  local k_build = k_dir .. "/build.gradle.kts"
  write_raw(k_build, k_initial)
  local k_buf = buffer_for(k_build)

  -- Duplicata de dependência declarada via libs.slf4j.api é recusada sem escrever
  stub_ui({ "Enter coordinates manually", "implementation (default)" }, { "org.slf4j", "slf4j-api", "2.0.21" })
  notices = {}
  deps.add(k_buf)
  assert(has_notice("already declared"), "duplicata via libs.slf4j.api não foi recusada: " .. last_notice())
  assert(read_raw(k_build) == k_initial, "duplicata alterou build.gradle.kts")
  assert(read_raw(k_dir .. "/gradle/libs.versions.toml") == k_cat_initial, "catálogo foi alterado")

  -- Busca Maven Central + nota de catálogo + JDTLS sync quando cliente anexado
  deps._search_maven = function(_, on_done)
    on_done({ { groupId = "com.google.guava", artifactId = "guava", version = "33.1.0-jre", packaging = "jar" } }, nil)
  end
  local synced_req
  lsp.client = function()
    return {
      request = function(_, method, params, handler, request_buf)
        synced_req = { method = method, params = params, buf = request_buf }
        handler(nil)
      end,
    }
  end
  stub_ui({ "Add dependency", "Search Maven Central", "guava:", "api", "✔ Add dependency" }, { "guava" })
  notices = {}
  deps.menu(k_buf)
  deps._search_maven = real_search
  assert(
    vim.wait(2000, function()
      return synced_req ~= nil
    end),
    "sync JDTLS não disparou após edição Gradle"
  )
  assert(synced_req.method == "java/projectConfigurationUpdate")
  assert(synced_req.params.uri == vim.uri_from_fname(k_build))
  lsp.client = real_client
  local k_after = read_raw(k_build)
  assert(
    k_after:find('  api("com.google.guava:guava:33.1.0-jre")', 1, true),
    "busca Maven Central não inseriu em .kts"
  )
  assert(read_raw(k_dir .. "/gradle/libs.versions.toml") == k_cat_initial, "libs.versions.toml não pode ser alterado")

  -- C) Symlinks: recusa symlink no arquivo de build e detecta buffer modificado via caminho symlinkado
  local sym_dir = tempdir("gradle-symlink")
  local outside_target = tempdir("gradle-symlink-outside") .. "/shared.gradle"
  write_raw(outside_target, "dependencies {\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n}\n")
  write_raw(sym_dir .. "/settings.gradle", 'rootProject.name = "sym"\n')
  assert(vim.uv.fs_symlink(outside_target, sym_dir .. "/build.gradle"), "falha ao criar symlink de teste")
  local sym_buf = buffer_for(sym_dir .. "/build.gradle")
  local can_edit_sym, sym_reason = deps._can_edit_target(deps._resolve_target(sym_buf))
  assert(can_edit_sym == false and sym_reason and sym_reason:find("symlink", 1, true), "symlink deveria ser recusado")
  notices = {}
  deps.add(sym_buf)
  assert(has_notice("symlink"), "M.add deveria recusar symlink: " .. last_notice())
  assert(
    read_raw(outside_target) == "dependencies {\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n}\n",
    "alvo externo do symlink foi modificado"
  )
  local _, write_sym_err = deps._write_build_file(sym_dir .. "/build.gradle", "corrupted")
  assert(write_sym_err and write_sym_err:find("symlink", 1, true), "_write_build_file não recusou symlink")

  -- Symlink quebrado (dangling) em build.gradle.kts também é recusado
  local dangling_dir = tempdir("gradle-dangling-sym")
  write_raw(dangling_dir .. "/settings.gradle.kts", 'rootProject.name = "dangling"\n')
  assert(vim.uv.fs_symlink(dangling_dir .. "/nonexistent.kts", dangling_dir .. "/build.gradle.kts"))
  local dangling_buf = buffer_for(dangling_dir .. "/build.gradle.kts")
  notices = {}
  deps.add(dangling_buf)
  assert(has_notice("symlink"), "symlink quebrado deveria ser recusado: " .. last_notice())
  assert(vim.uv.fs_lstat(dangling_dir .. "/nonexistent.kts") == nil, "destino inexistente foi criado")

  -- Buffer modificado aberto por diretório symlinkado ainda bloqueia _write_build_file
  local real_dir = tempdir("gradle-dir-real")
  local link_parent = tempdir("gradle-dir-link-parent")
  local link_dir = link_parent .. "/link"
  local real_build = real_dir .. "/build.gradle"
  write_raw(real_build, "dependencies {\n}\n")
  assert(vim.uv.fs_symlink(real_dir, link_dir), "falha ao criar symlink de diretório")
  local via_link_buf = buffer_for(link_dir .. "/build.gradle")
  vim.bo[via_link_buf].modified = true
  local ok_link, err_link = deps._write_build_file(real_build, "dependencies {\n  implementation 'a:b:1'\n}\n")
  assert(
    ok_link == nil and err_link and err_link:find("unsaved changes", 1, true),
    "buffer modificado via symlink não bloqueou"
  )
  assert(read_raw(real_build) == "dependencies {\n}\n")
  vim.bo[via_link_buf].modified = false
  vim.api.nvim_buf_delete(via_link_buf, { force = true })

  -- D) Diretório ambíguo com build.gradle E build.gradle.kts recusa edição
  local both_dir = tempdir("gradle-both-dsl")
  write_raw(both_dir .. "/settings.gradle", 'rootProject.name = "both"\n')
  write_raw(both_dir .. "/build.gradle", "dependencies {}\n")
  write_raw(both_dir .. "/build.gradle.kts", "dependencies {}\n")
  local both_buf = buffer_for(both_dir .. "/build.gradle")
  notices = {}
  deps.add(both_buf)
  assert(has_notice("ambiguous"), "ambos DSL no mesmo módulo deveriam ser recusados: " .. last_notice())
  assert(read_raw(both_dir .. "/build.gradle") == "dependencies {}\n")
  assert(read_raw(both_dir .. "/build.gradle.kts") == "dependencies {}\n")

  -- E) Parcial não suportado via M.add: recusa e preserva 100% do arquivo
  local partial_dir = tempdir("gradle-partial-add")
  write_raw(partial_dir .. "/settings.gradle", 'rootProject.name = "partial"\n')
  local partial_text = table.concat({
    "dependencies {",
    "  implementation 'org.slf4j:slf4j-api:2.0.20'",
    "  if (project.hasProperty('extra')) {",
    "    implementation 'com.example:extra:1.0.0'",
    "  }",
    "}",
    "",
  }, "\n")
  write_raw(partial_dir .. "/build.gradle", partial_text)
  local partial_buf = buffer_for(partial_dir .. "/build.gradle")
  notices = {}
  deps.add(partial_buf)
  assert(has_notice("dynamic or conditional"), "parcial não suportado não foi recusado: " .. last_notice())
  assert(read_raw(partial_dir .. "/build.gradle") == partial_text, "arquivo parcial foi alterado")

  -- F) Multi-módulo Gradle: edita apenas o módulo escolhido; módulo sem build file próprio é recusado
  local mm_dir = tempdir("gradle-multimod")
  write_raw(mm_dir .. "/settings.gradle.kts", 'rootProject.name = "mm"\ninclude(":app", ":lib", ":nobuild")\n')
  write_raw(mm_dir .. "/build.gradle.kts", "// root\n")
  local app_build = mm_dir .. "/app/build.gradle.kts"
  local lib_build = mm_dir .. "/lib/build.gradle.kts"
  write_raw(app_build, 'dependencies {\n  implementation(project(":lib"))\n}\n')
  write_raw(lib_build, "dependencies {}\n")
  vim.fn.mkdir(mm_dir .. "/nobuild/src/main/java", "p")
  write_raw(mm_dir .. "/nobuild/src/main/java/Empty.java", "public class Empty {}\n")

  local app_buf = buffer_for(app_build)
  stub_ui({
    "app (current)",
    "Add dependency",
    "Enter coordinates manually",
    "implementation (default)",
    "✔ Add dependency",
  }, { "com.example", "app-only", "1.0.0" })
  deps.menu(app_buf)
  assert(read_raw(app_build):find('implementation("com.example:app-only:1.0.0")', 1, true), "módulo :app não editado")
  assert(read_raw(lib_build) == "dependencies {}\n", "módulo irmão :lib foi alterado indevidamente")
  assert(read_raw(mm_dir .. "/build.gradle.kts") == "// root\n", "root foi alterado indevidamente")

  local nobuild_buf = buffer_for(mm_dir .. "/nobuild/src/main/java/Empty.java")
  notices = {}
  deps.add(nobuild_buf)
  assert(
    has_notice("no build.gradle or build.gradle.kts"),
    "submódulo sem build file deveria recusar: " .. last_notice()
  )
  assert(read_raw(mm_dir .. "/build.gradle.kts") == "// root\n", "root foi alterado por submódulo sem build file")
end

gradle_edit_interactive_spec()

local function review_findings_regression_spec()
  -- ---------- 22. Regressões de revisão: stale snapshot, temp único, permissões, slashy/dollar-slashy, stat/inexistente ----------

  -- 1) Non-existing path, directory stat e remoção zero de arquivos previsíveis de usuário
  local reg_dir = tempdir("review-write")
  local missing_path = reg_dir .. "/missing-pom.xml"
  local miss_ok, miss_err = deps._write_build_file(missing_path, "<project/>")
  assert(miss_ok == nil and miss_err and miss_err:find("does not exist", 1, true), "caminho inexistente deveria falhar")
  assert(vim.uv.fs_lstat(missing_path) == nil, "caminho inexistente não deve ser criado")

  local dir_ok, dir_err = deps._write_build_file(reg_dir, "bad")
  assert(dir_ok == nil and dir_err and dir_err:find("not a regular file", 1, true), "diretório deveria ser recusado")

  local pom_path = reg_dir .. "/pom.xml"
  write_raw(pom_path, MINIMAL_POM)
  local predictable_tmp = pom_path .. ".java-menu-tmp"
  write_raw(predictable_tmp, "USER DATA DO NOT DELETE")
  local expected_pom = MINIMAL_POM .. "\n<!-- safe -->"
  local ok_pred, err_pred = deps._write_build_file(pom_path, expected_pom)
  assert(ok_pred == true and err_pred == nil, "escrita deveria ignorar caminho previsível: " .. tostring(err_pred))
  assert(
    read_raw(predictable_tmp) == "USER DATA DO NOT DELETE",
    "arquivo .java-menu-tmp do usuário foi apagado/alterado"
  )

  -- Também quando .java-menu-tmp é symlink, não é tocado nem bloqueia a escrita
  vim.uv.fs_unlink(predictable_tmp)
  assert(vim.uv.fs_symlink(reg_dir .. "/outside.txt", predictable_tmp))
  write_raw(reg_dir .. "/outside.txt", "KEEP OUTSIDE")
  local ok_pred_sym, err_pred_sym = deps._write_build_file(pom_path, MINIMAL_POM)
  assert(
    ok_pred_sym == true and err_pred_sym == nil,
    "symlink previsível não deveria bloquear nem ser apagado: " .. tostring(err_pred_sym)
  )
  assert(vim.uv.fs_lstat(predictable_tmp).type == "link", "symlink .java-menu-tmp foi removido")
  assert(read_raw(reg_dir .. "/outside.txt") == "KEEP OUTSIDE", "alvo do symlink previsível foi alterado")

  -- Nenhum arquivo temporário .java-menu-* permanece após sucesso ou erro
  local function count_temp_files(dir)
    local count = 0
    for name in vim.fs.dir(dir) do
      if name:find("%.java%-menu") then
        count = count + 1
      end
    end
    return count
  end
  assert(count_temp_files(reg_dir) == 1, "sobraram arquivos temporários além do pom.xml.java-menu-tmp pré-existente")

  -- 2) Preservação de permissões (0600 e modos não padrão 0640 / 0750) em atomic replace e M.add
  local perm_dir = tempdir("review-perms")
  local perm_pom = perm_dir .. "/pom.xml"
  local function assert_perm_preserved(mode_octal, label)
    write_raw(perm_pom, MINIMAL_POM)
    assert(vim.uv.fs_chmod(perm_pom, mode_octal), "falha ao aplicar chmod " .. label)
    local wrote_ok, wrote_err = deps._write_build_file(perm_pom, MINIMAL_POM .. "\n<!-- " .. label .. " -->")
    assert(wrote_ok, "falha ao escrever com modo " .. label .. ": " .. tostring(wrote_err))
    local st = assert(vim.uv.fs_lstat(perm_pom))
    local got = st.mode % 512
    assert(got == mode_octal, ("permissão %s não preservada: esperado %o, obtido %o"):format(label, mode_octal, got))
  end
  assert_perm_preserved(tonumber("600", 8), "0600")
  assert_perm_preserved(tonumber("640", 8), "0640")
  assert_perm_preserved(tonumber("750", 8), "0750")

  -- Também via M.add em build.gradle com 0600
  local perm_gradle_dir = tempdir("review-perms-gradle")
  write_raw(perm_gradle_dir .. "/settings.gradle", 'rootProject.name = "perm-gradle"\n')
  local perm_gradle = perm_gradle_dir .. "/build.gradle"
  write_raw(perm_gradle, "dependencies {\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n}\n")
  assert(vim.uv.fs_chmod(perm_gradle, tonumber("600", 8)))
  local perm_g_buf = buffer_for(perm_gradle)
  stub_ui(
    { "Enter coordinates manually", "implementation (default)", "✔ Add dependency" },
    { "junit", "junit", "4.13.2" }
  )
  deps.add(perm_g_buf)
  local pg_stat = assert(vim.uv.fs_lstat(perm_gradle))
  assert((pg_stat.mode % 512) == tonumber("600", 8), "M.add não preservou permissão 0600 em build.gradle")
  vim.api.nvim_buf_delete(perm_g_buf, { force = true })

  -- 3) Stale snapshot direto em _write_build_file e durante M.add (Maven + Gradle) + buffer modificado no meio do fluxo
  local stale_dir = tempdir("review-stale")
  local stale_pom = stale_dir .. "/pom.xml"
  write_raw(stale_pom, MINIMAL_POM)
  local stale_ok, stale_err = deps._write_build_file(stale_pom, "<project/>", { expected_text = "different" })
  assert(stale_ok == nil and stale_err and stale_err:find("changed on disk", 1, true))
  assert(read_raw(stale_pom) == MINIMAL_POM, "snapshot obsoleto sobrescreveu pom.xml")
  assert(count_temp_files(stale_dir) == 0, "arquivo temporário sobrou após recusa de snapshot obsoleto")

  -- Alteração externa no disco entre leitura inicial e confirmação de M.add (Maven)
  local race_mvn_dir = tempdir("review-race-mvn")
  local race_pom = race_mvn_dir .. "/pom.xml"
  write_raw(race_pom, MINIMAL_POM)
  local race_pom_buf = buffer_for(race_pom)
  local external_mvn = MINIMAL_POM:gsub("</project>", "  <!-- external edit -->\n</project>")
  local real_sel_save, real_inp_save = vim.ui.select, vim.ui.input
  local mvn_inputs = { "com.example", "demo", "1.0.0" }
  local mvn_selects = { "Enter coordinates manually", "compile (default)", "✔ Add dependency" }
  vim.ui.input = function(_, on_confirm)
    on_confirm(table.remove(mvn_inputs, 1))
  end
  vim.ui.select = function(items, opts, on_choice)
    local want = table.remove(mvn_selects, 1)
    if opts and opts.prompt and opts.prompt:find("summary", 1, true) then
      write_raw(race_pom, external_mvn)
    end
    for _, item in ipairs(items) do
      if item:find(want, 1, true) then
        return on_choice(item)
      end
    end
  end
  notices = {}
  deps.add(race_pom_buf)
  vim.ui.select, vim.ui.input = real_sel_save, real_inp_save
  assert(has_notice("changed on disk"), "M.add Maven deveria abortar com snapshot obsoleto: " .. last_notice())
  assert(read_raw(race_pom) == external_mvn, "M.add Maven sobrescreveu edição externa após confirmação")

  -- Buffer modificado durante o fluxo (após início de M.add, antes da confirmação)
  write_raw(race_pom, MINIMAL_POM)
  vim.api.nvim_buf_call(race_pom_buf, function()
    vim.cmd("silent edit!")
  end)
  local mod_inputs = { "com.example", "demo", "1.0.0" }
  local mod_selects = { "Enter coordinates manually", "compile (default)", "✔ Add dependency" }
  vim.ui.input = function(_, on_confirm)
    on_confirm(table.remove(mod_inputs, 1))
  end
  vim.ui.select = function(items, opts, on_choice)
    local want = table.remove(mod_selects, 1)
    if opts and opts.prompt and opts.prompt:find("summary", 1, true) then
      vim.bo[race_pom_buf].modified = true
    end
    for _, item in ipairs(items) do
      if item:find(want, 1, true) then
        return on_choice(item)
      end
    end
  end
  notices = {}
  deps.add(race_pom_buf)
  vim.ui.select, vim.ui.input = real_sel_save, real_inp_save
  assert(has_notice("unsaved changes"), "modificação de buffer durante M.add deveria abortar: " .. last_notice())
  assert(read_raw(race_pom) == MINIMAL_POM, "M.add sobrescreveu arquivo com buffer modificado durante prompt")
  vim.bo[race_pom_buf].modified = false
  vim.api.nvim_buf_delete(race_pom_buf, { force = true })

  -- 4) Duas interações assíncronas concorrentes (Maven e Gradle): primeira vence, segunda aborta sem sobrescrever
  local function run_two_concurrent_adds(build_file, initial_text, setup_fn)
    local dir = tempdir("review-concurrent-" .. (build_file:match("%.gradle") and "gradle" or "maven"))
    local path = dir .. "/" .. build_file
    setup_fn(dir, path, initial_text)
    local buf = buffer_for(path)

    local pending = {}
    local queue_idx = 0
    local sessions = {
      {
        selects = { "Enter coordinates manually", "default", "✔ Add dependency" },
        inputs = { "com.first", "one", "1.0.0" },
      },
      {
        selects = { "Enter coordinates manually", "default", "✔ Add dependency" },
        inputs = { "com.second", "two", "2.0.0" },
      },
    }
    -- Para Gradle, o item é "implementation (default)" e para Maven "compile (default)"; ambos casam com "default".
    local active_session
    vim.ui.input = function(_, on_confirm)
      local val = table.remove(active_session.inputs, 1)
      on_confirm(val)
    end
    vim.ui.select = function(items, opts, on_choice)
      local want = table.remove(active_session.selects, 1)
      local matched
      for _, item in ipairs(items) do
        if item:find(want, 1, true) then
          matched = item
          break
        end
      end
      assert(matched, "concorrência: item não encontrado para " .. tostring(want))
      if opts and opts.prompt and opts.prompt:find("summary", 1, true) then
        -- Pausa na confirmação final para permitir que ambas as sessões leiam o mesmo snapshot inicial
        pending[#pending + 1] = function()
          on_choice(matched)
        end
        return
      end
      on_choice(matched)
    end

    local real_client = lsp.client
    local sync_calls = 0
    lsp.client = function()
      return {
        request = function(_, _, _, handler)
          sync_calls = sync_calls + 1
          handler(nil)
        end,
      }
    end

    notices = {}
    queue_idx = 1
    active_session = sessions[queue_idx]
    deps.add(buf)
    queue_idx = 2
    active_session = sessions[queue_idx]
    deps.add(buf)

    assert(#pending == 2, "ambas as interações concorrentes deveriam aguardar confirmação")
    -- Primeira confirma e grava
    pending[1]()
    local after_first = read_raw(path)
    assert(after_first:find("com.first", 1, true) and after_first:find("one", 1, true), "primeira interação falhou")
    assert(sync_calls == 1, "primeira interação deveria sincronizar JDTLS")

    -- Segunda confirma com snapshot antigo: deve abortar sem sobrescrever a primeira nem sincronizar JDTLS
    notices = {}
    pending[2]()
    assert(has_notice("changed on disk"), "segunda interação concorrente deveria abortar: " .. last_notice())
    assert(read_raw(path) == after_first, "segunda interação sobrescreveu a primeira")
    assert(not read_raw(path):find("com.second", 1, true), "segunda dependência vazou para disco")
    assert(sync_calls == 1, "segunda interação abortada não deve disparar sync JDTLS")

    vim.ui.select, vim.ui.input = real_sel_save, real_inp_save
    lsp.client = real_client
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  run_two_concurrent_adds("pom.xml", MINIMAL_POM, function(_, path, text)
    write_raw(path, text)
  end)
  run_two_concurrent_adds(
    "build.gradle",
    "dependencies {\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n}\n",
    function(dir, path, text)
      write_raw(dir .. "/settings.gradle", 'rootProject.name = "concurrent-g"\n')
      write_raw(path, text)
    end
  )

  -- 5) Groovy slashy (/.../) e dollar-slashy ($/.../$) tratados com segurança: recusa antes de qualquer mutação
  local slashy_cases = {
    {
      "dollar-slashy containing dependencies block",
      "def tmpl = $/\ndependencies {\n  implementation 'com.trap:inside:1.0'\n}\n/$\n",
    },
    {
      "dollar-slashy with comment-like tokens + real dependencies",
      "def s = $/hello /* not comment /$\ndependencies {\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n}\n",
    },
    {
      "unterminated dollar-slashy",
      "def s = $/unclosed\ndependencies {\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n}\n",
    },
    {
      "slashy regex containing dependencies block",
      "def re = /dependencies { implementation 'com.trap:inside:1.0' }/\n",
    },
    {
      "command expression slashy string",
      "println /dependencies { implementation 'com.trap:inside:1.0' }/\n",
    },
    {
      "slashy with embedded quote + real dependencies",
      "def re = /foo \"bar/\ndependencies {\n  implementation 'org.slf4j:slf4j-api:2.0.20'\n}\n",
    },
  }
  for _, case in ipairs(slashy_cases) do
    local label, src = case[1], case[2]
    local out, _, err = deps._insert_gradle_dependency(src, {
      groupId = "com.example",
      artifactId = "safe",
      version = "1.0.0",
    }, { is_kotlin_dsl = false })
    assert(
      out == nil and type(err) == "string" and err:find("slashy", 1, true),
      ("caso Groovy '%s' deveria ser recusado com segurança, obtido err=%s"):format(label, tostring(err))
    )
  end

  -- Também no fluxo interativo M.add: arquivo com dollar-slashy não é mutado
  local sl_dir = tempdir("review-slashy")
  write_raw(sl_dir .. "/settings.gradle", 'rootProject.name = "slashy"\n')
  local sl_src = "def tmpl = $/\ndependencies {\n  implementation 'com.trap:inside:1.0'\n}\n/$\n"
  local sl_build = sl_dir .. "/build.gradle"
  write_raw(sl_build, sl_src)
  local sl_buf = buffer_for(sl_build)
  local can_sl, sl_reason = deps._can_edit_target(deps._resolve_target(sl_buf))
  assert(can_sl == false and sl_reason and sl_reason:find("slashy", 1, true), "can_edit deveria recusar dollar-slashy")
  notices = {}
  deps.add(sl_buf)
  assert(has_notice("slashy"), "M.add deveria recusar dollar-slashy: " .. last_notice())
  assert(read_raw(sl_build) == sl_src, "arquivo com dollar-slashy foi alterado")
  vim.api.nvim_buf_delete(sl_buf, { force = true })

  -- URLs dentro de aspas, comentários e divisão em Kotlin DSL continuam permitidos
  local groovy_url_ok, _, groovy_url_err = deps._insert_gradle_dependency(
    "// https://example.com\nrepositories { maven { url 'https://repo.example.com/maven2' } }\ndependencies {\n  implementation 'a:b:1.0'\n}\n",
    { groupId = "c", artifactId = "d", version = "2.0" },
    { is_kotlin_dsl = false }
  )
  assert(groovy_url_ok ~= nil and groovy_url_err == nil, "URL em string Groovy não pode disparar recusa slashy")

  local kts_div_ok, _, kts_div_err = deps._insert_gradle_dependency(
    'val ratio = 10 / 2\ndependencies {\n  implementation("a:b:1.0")\n}\n',
    { groupId = "c", artifactId = "d", version = "2.0" },
    { is_kotlin_dsl = true }
  )
  assert(kts_div_ok ~= nil and kts_div_err == nil, "divisão em Kotlin DSL não pode disparar recusa slashy")
end

review_findings_regression_spec()

local function write_build_file_race_regression_spec()
  -- ---------- 23. Regressões de TOCTOU em _write_build_file (fd aberto, recheck de destino/temp, sem unlink estrangeiro) ----------
  local function with_uv_mocks(overrides, fn)
    local saved = {}
    for k, v in pairs(overrides) do
      saved[k] = vim.uv[k]
      vim.uv[k] = v
    end
    local ok, err = pcall(fn, saved)
    for k, orig in pairs(saved) do
      vim.uv[k] = orig
    end
    if not ok then
      error(err, 0)
    end
  end

  local mode_0600 = tonumber("600", 8)

  -- 1) tmp_fd permanece aberto durante fs_rename e é fechado depois (sucesso e falha), preservando 0600 e arquivos do usuário
  do
    local dir = tempdir("race-fd-lifecycle")
    local pom = dir .. "/pom.xml"
    local user_keep = dir .. "/pom.xml.java-menu-tmp"
    local user_dot_keep = dir .. "/.pom.xml.java-menu-user"
    write_raw(pom, MINIMAL_POM)
    assert(vim.uv.fs_chmod(pom, mode_0600))
    write_raw(user_keep, "USER KEEP 1")
    write_raw(user_dot_keep, "USER KEEP 2")

    local captured_fd, closed_before_rename, closed_after_rename, rename_called
    local real_mkstemp = vim.uv.fs_mkstemp
    local real_close = vim.uv.fs_close
    local real_rename = vim.uv.fs_rename
    with_uv_mocks({
      fs_mkstemp = function(tmpl)
        local fd, path, err = real_mkstemp(tmpl)
        if fd then
          captured_fd = fd
        end
        return fd, path, err
      end,
      fs_close = function(fd)
        if captured_fd and fd == captured_fd then
          if not rename_called then
            closed_before_rename = true
          else
            closed_after_rename = true
          end
        end
        return real_close(fd)
      end,
      fs_rename = function(src, dst)
        rename_called = true
        assert(not closed_before_rename, "tmp_fd não deveria ter sido fechado antes de fs_rename")
        return real_rename(src, dst)
      end,
    }, function()
      local next_pom = MINIMAL_POM .. "\n<!-- fd-open-ok -->"
      local ok, err = deps._write_build_file(pom, next_pom)
      assert(ok == true and err == nil, "escrita deveria suceder: " .. tostring(err))
      assert(rename_called, "fs_rename deveria ter sido chamado")
      assert(not closed_before_rename, "tmp_fd foi fechado antes de fs_rename")
      assert(closed_after_rename, "tmp_fd deveria ser fechado após fs_rename")
      assert(read_raw(pom) == next_pom)
      assert((assert(vim.uv.fs_lstat(pom)).mode % 512) == mode_0600, "permissão 0600 não preservada")
      assert(read_raw(user_keep) == "USER KEEP 1", "arquivo pré-existente do usuário foi alterado")
      assert(read_raw(user_dot_keep) == "USER KEEP 2", "arquivo .java-menu pré-existente do usuário foi alterado")
    end)

    -- Também em erro de fs_rename: tmp_fd estava aberto na entrada de fs_rename e é fechado após cleanup
    captured_fd, closed_before_rename, closed_after_rename, rename_called = nil, false, false, false
    local before_fail = read_raw(pom)
    with_uv_mocks({
      fs_mkstemp = function(tmpl)
        local fd, path, err = real_mkstemp(tmpl)
        if fd then
          captured_fd = fd
        end
        return fd, path, err
      end,
      fs_close = function(fd)
        if captured_fd and fd == captured_fd then
          if not rename_called then
            closed_before_rename = true
          else
            closed_after_rename = true
          end
        end
        return real_close(fd)
      end,
      fs_rename = function()
        rename_called = true
        assert(not closed_before_rename, "tmp_fd fechado antes de fs_rename em caso de falha")
        return nil, "EIO: simulated"
      end,
    }, function()
      local ok, err = deps._write_build_file(pom, "<project/>")
      assert(
        ok == nil and err and err:find("could not replace", 1, true),
        "falha de rename esperada: " .. tostring(err)
      )
      assert(closed_after_rename, "tmp_fd deveria ser fechado no cleanup após erro de rename")
      assert(read_raw(pom) == before_fail)
      assert((assert(vim.uv.fs_lstat(pom)).mode % 512) == mode_0600)
    end)
  end

  -- 2) Destino alterado imediatamente antes do rename (após fs_fsync): conteúdo diferente e mesmo tamanho/metadata simulado
  do
    local dir = tempdir("race-dest-changed")
    local pom = dir .. "/pom.xml"
    write_raw(pom, MINIMAL_POM)
    assert(vim.uv.fs_chmod(pom, mode_0600))
    local concurrent_pom = MINIMAL_POM:gsub("</project>", "  <!-- concurrent -->\n</project>")
    local real_fsync = vim.uv.fs_fsync
    local rename_called = false
    with_uv_mocks({
      fs_fsync = function(fd)
        local ok, err = real_fsync(fd)
        write_raw(pom, concurrent_pom)
        assert(vim.uv.fs_chmod(pom, mode_0600))
        return ok, err
      end,
      fs_rename = function()
        rename_called = true
        return true
      end,
    }, function()
      local ok, err = deps._write_build_file(pom, MINIMAL_POM .. "\n<!-- stale -->")
      assert(
        ok == nil and err and err:find("changed concurrently", 1, true),
        "deveria abortar mudança concorrente: " .. tostring(err)
      )
      assert(not rename_called, "fs_rename não deveria ser chamado após mudança no destino")
      assert(read_raw(pom) == concurrent_pom, "conteúdo concorrente foi sobrescrito")
      assert((assert(vim.uv.fs_lstat(pom)).mode % 512) == mode_0600)
    end)

    -- Mesmo tamanho + mesmos metadados (simula fs_read devolvendo conteúdo modificado na releitura pré-rename)
    local same_len_a = "<project><!-- AAAA --></project>\n"
    local same_len_b = "<project><!-- BBBB --></project>\n"
    write_raw(pom, same_len_a)
    assert(vim.uv.fs_chmod(pom, mode_0600))
    local real_read = vim.uv.fs_read
    local fsync_done = false
    rename_called = false
    with_uv_mocks({
      fs_fsync = function(fd)
        fsync_done = true
        return real_fsync(fd)
      end,
      fs_read = function(fd, size, offset)
        local data, err = real_read(fd, size, offset)
        if fsync_done and data == same_len_a then
          return same_len_b, nil
        end
        return data, err
      end,
      fs_rename = function()
        rename_called = true
        return true
      end,
    }, function()
      local ok, err = deps._write_build_file(pom, "<project><!-- MINE --></project>\n")
      assert(
        ok == nil and err and err:find("changed concurrently", 1, true),
        "releitura de conteúdo deveria abortar: " .. tostring(err)
      )
      assert(not rename_called, "fs_rename não deveria rodar quando releitura diverge")
    end)
    assert(read_raw(pom) == same_len_a)
  end

  -- 3) Destino trocado por symlink imediatamente antes do rename (após fs_fsync)
  do
    local dir = tempdir("race-dest-symlink")
    local pom = dir .. "/pom.xml"
    local outside = dir .. "/outside.xml"
    write_raw(pom, MINIMAL_POM)
    write_raw(outside, "OUTSIDE KEEP")
    local real_fsync = vim.uv.fs_fsync
    local rename_called = false
    with_uv_mocks({
      fs_fsync = function(fd)
        local ok, err = real_fsync(fd)
        assert(vim.uv.fs_unlink(pom))
        assert(vim.uv.fs_symlink(outside, pom))
        return ok, err
      end,
      fs_rename = function()
        rename_called = true
        return true
      end,
    }, function()
      local ok, err = deps._write_build_file(pom, MINIMAL_POM .. "\n<!-- x -->")
      assert(
        ok == nil and err and err:find("symlink", 1, true),
        "deveria recusar destino trocado para symlink: " .. tostring(err)
      )
      assert(not rename_called, "fs_rename não deveria rodar quando destino virou symlink")
      assert(vim.uv.fs_lstat(pom).type == "link")
      assert(read_raw(outside) == "OUTSIDE KEEP")
    end)
  end

  -- 4) Temp trocado por symlink antes do rename: recusa sem sobrescrever build nem remover symlink/alvo
  do
    local dir = tempdir("race-tmp-symlink-prerename")
    local pom = dir .. "/pom.xml"
    local victim = dir .. "/victim.txt"
    write_raw(pom, MINIMAL_POM)
    assert(vim.uv.fs_chmod(pom, mode_0600))
    write_raw(victim, "VICTIM KEEP")

    local captured_tmp_path, captured_fd
    local fd_closed, rename_called = false, false
    local real_mkstemp = vim.uv.fs_mkstemp
    local real_fsync = vim.uv.fs_fsync
    local real_close = vim.uv.fs_close
    with_uv_mocks({
      fs_mkstemp = function(tmpl)
        local fd, path, err = real_mkstemp(tmpl)
        if fd then
          captured_fd, captured_tmp_path = fd, path
        end
        return fd, path, err
      end,
      fs_fsync = function(fd)
        local ok, err = real_fsync(fd)
        if fd == captured_fd then
          assert(vim.uv.fs_unlink(captured_tmp_path))
          assert(vim.uv.fs_symlink(victim, captured_tmp_path))
        end
        return ok, err
      end,
      fs_close = function(fd)
        if fd == captured_fd then
          fd_closed = true
        end
        return real_close(fd)
      end,
      fs_rename = function()
        rename_called = true
        return true
      end,
    }, function()
      local ok, err = deps._write_build_file(pom, MINIMAL_POM .. "\n<!-- hijack -->")
      assert(ok == nil and err and err:find("symlink", 1, true), "temp symlink deveria abortar: " .. tostring(err))
      assert(not rename_called, "fs_rename não pode ser chamado com temp symlink")
      assert(read_raw(pom) == MINIMAL_POM, "pom.xml foi alterado")
      assert((assert(vim.uv.fs_lstat(pom)).mode % 512) == mode_0600)
      assert(vim.uv.fs_lstat(captured_tmp_path).type == "link", "symlink estrangeiro no temp_path foi removido")
      assert(read_raw(victim) == "VICTIM KEEP", "alvo do symlink foi alterado")
      assert(fd_closed, "tmp_fd deveria ser fechado após abortar")
    end)
  end

  -- 5) Temp trocado por arquivo regular estrangeiro antes do rename: aborta e nunca remove arquivo estrangeiro
  do
    local dir = tempdir("race-tmp-foreign-prerename")
    local pom = dir .. "/pom.xml"
    write_raw(pom, MINIMAL_POM)
    assert(vim.uv.fs_chmod(pom, mode_0600))

    local captured_tmp_path, captured_fd
    local fd_closed, rename_called = false, false
    local real_mkstemp = vim.uv.fs_mkstemp
    local real_fsync = vim.uv.fs_fsync
    local real_close = vim.uv.fs_close
    with_uv_mocks({
      fs_mkstemp = function(tmpl)
        local fd, path, err = real_mkstemp(tmpl)
        if fd then
          captured_fd, captured_tmp_path = fd, path
        end
        return fd, path, err
      end,
      fs_fsync = function(fd)
        local ok, err = real_fsync(fd)
        if fd == captured_fd then
          assert(vim.uv.fs_unlink(captured_tmp_path))
          write_raw(captured_tmp_path, "FOREIGN USER FILE")
        end
        return ok, err
      end,
      fs_close = function(fd)
        if fd == captured_fd then
          fd_closed = true
        end
        return real_close(fd)
      end,
      fs_rename = function()
        rename_called = true
        return true
      end,
    }, function()
      local ok, err = deps._write_build_file(pom, MINIMAL_POM .. "\n<!-- foreign -->")
      assert(
        ok == nil and err and err:find("replaced", 1, true),
        "temp substituído deveria abortar: " .. tostring(err)
      )
      assert(not rename_called, "fs_rename não pode rodar com temp substituído")
      assert(read_raw(pom) == MINIMAL_POM)
      assert(read_raw(captured_tmp_path) == "FOREIGN USER FILE", "arquivo estrangeiro no temp_path foi apagado")
      assert(fd_closed)
    end)
  end

  -- 6) Temp trocado no boundary de falha de fs_rename (symlink e arquivo estrangeiro): cleanup nunca apaga caminho alheio
  for _, kind in ipairs({ "symlink", "foreign" }) do
    local dir = tempdir("race-cleanup-" .. kind)
    local pom = dir .. "/pom.xml"
    local victim = dir .. "/victim.txt"
    write_raw(pom, MINIMAL_POM)
    write_raw(victim, "KEEP TARGET")

    local captured_tmp_path, captured_fd
    local fd_closed = false
    local real_mkstemp = vim.uv.fs_mkstemp
    local real_close = vim.uv.fs_close
    with_uv_mocks({
      fs_mkstemp = function(tmpl)
        local fd, path, err = real_mkstemp(tmpl)
        if fd then
          captured_fd, captured_tmp_path = fd, path
        end
        return fd, path, err
      end,
      fs_rename = function(src)
        assert(src == captured_tmp_path)
        assert(vim.uv.fs_unlink(src))
        if kind == "symlink" then
          assert(vim.uv.fs_symlink(victim, src))
        else
          write_raw(src, "FOREIGN AT CLEANUP")
        end
        return nil, "EACCES: simulated"
      end,
      fs_close = function(fd)
        if fd == captured_fd then
          fd_closed = true
        end
        return real_close(fd)
      end,
    }, function()
      local ok, err = deps._write_build_file(pom, MINIMAL_POM .. "\n<!-- rename-fail -->")
      assert(ok == nil and err and err:find("could not replace", 1, true))
      assert(read_raw(pom) == MINIMAL_POM)
      if kind == "symlink" then
        assert(vim.uv.fs_lstat(captured_tmp_path).type == "link", "cleanup removeu symlink no boundary do rename")
        assert(read_raw(victim) == "KEEP TARGET")
      else
        assert(
          read_raw(captured_tmp_path) == "FOREIGN AT CLEANUP",
          "cleanup removeu arquivo estrangeiro no boundary do rename"
        )
      end
      assert(fd_closed)
    end)
  end

  -- 7) Falha fechada quando não é possível provar propriedade do arquivo temporário (fs_fstat(tmp_fd) == nil)
  do
    local dir = tempdir("race-tmp-no-ownership")
    local pom = dir .. "/pom.xml"
    write_raw(pom, MINIMAL_POM)

    local captured_tmp_path, captured_fd
    local fd_closed, unlink_called, rename_called = false, false, false
    local real_mkstemp = vim.uv.fs_mkstemp
    local real_fstat = vim.uv.fs_fstat
    local real_unlink = vim.uv.fs_unlink
    local real_close = vim.uv.fs_close
    with_uv_mocks({
      fs_mkstemp = function(tmpl)
        local fd, path, err = real_mkstemp(tmpl)
        if fd then
          captured_fd, captured_tmp_path = fd, path
        end
        return fd, path, err
      end,
      fs_fstat = function(fd)
        if captured_fd and not fd_closed and fd == captured_fd then
          return nil
        end
        return real_fstat(fd)
      end,
      fs_unlink = function(path)
        if path == captured_tmp_path then
          unlink_called = true
        end
        return real_unlink(path)
      end,
      fs_close = function(fd)
        if captured_fd and not fd_closed and fd == captured_fd then
          fd_closed = true
        end
        return real_close(fd)
      end,
      fs_rename = function()
        rename_called = true
        return true
      end,
    }, function()
      local ok, err = deps._write_build_file(pom, MINIMAL_POM .. "\n<!-- no-own -->")
      assert(
        ok == nil and err and err:find("ownership", 1, true),
        "deveria falhar fechado sem propriedade: " .. tostring(err)
      )
      assert(not rename_called)
      assert(not unlink_called, "não deve fazer unlink quando propriedade não foi estabelecida")
      assert(vim.uv.fs_lstat(captured_tmp_path) ~= nil)
      assert(fd_closed)
    end)
    assert(read_raw(pom) == MINIMAL_POM)
  end
end

write_build_file_race_regression_spec()

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
    .. "Maven Central, Gradle estático + edição segura Groovy/Kotlin, sync só com cliente, add/menu sem escrita ao cancelar)"
)
vim.cmd("qa!")
