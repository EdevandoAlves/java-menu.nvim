-- Integração: sync real do JDTLS após editar o pom.xml (H1).
--
-- Valida o contrato usado por deps.lua: a reimportação da configuração do
-- projeto é a request LSP `java/projectConfigurationUpdate` com o URI do build
-- file, enviada ao cliente anexado ao buffer (não é
-- workspace/executeCommand "java.project.update"). O request precisa concluir
-- sem erro LSP contra um JDTLS real e o servidor precisa emitir o progresso de
-- "Updating project configurations" (evidência de que o job de reimportação
-- rodou de fato).
--
-- Run:
--   tests/java_menu/run.sh integration
--   (ou, manualmente, no mesmo formato de lsp_clients_spec.lua)

local deps = require("java_menu.deps")
local fixtures = require("tests.java_menu.fixtures")

-- helpers de arquivo (bytes preservados)
local function read_raw(path)
  local fd = assert(vim.uv.fs_open(path, "r", 420))
  local stat = assert(vim.uv.fs_fstat(fd))
  local data = stat.size > 0 and assert(vim.uv.fs_read(fd, stat.size, 0)) or ""
  vim.uv.fs_close(fd)
  return data
end

local ok_jdtls, jdtls = pcall(require, "jdtls")
assert(ok_jdtls and type(jdtls.start_or_attach) == "function", "nvim-jdtls indisponível")

local jdtls_bin = vim.fn.exepath("jdtls")
if jdtls_bin == "" then
  local mason = vim.fn.stdpath("data") .. "/mason/bin/jdtls"
  if vim.fn.filereadable(mason) == 1 then
    jdtls_bin = mason
  end
end
assert(jdtls_bin ~= "", "jdtls não está no PATH nem no Mason")

-- progresso do job de reimportação: begin/report/end por token
local update_active, update_begins, update_ends = 0, 0, 0
local real_progress = vim.lsp.handlers["$/progress"]
vim.lsp.handlers["$/progress"] = function(err, params, ctx)
  local value = params and params.value
  if value and value.title and tostring(value.title):find("Updating project configurations", 1, true) then
    if value.kind == "begin" then
      update_active, update_begins = update_active + 1, update_begins + 1
    elseif value.kind == "end" then
      update_active, update_ends = math.max(0, update_active - 1), update_ends + 1
    end
  end
  if real_progress then
    pcall(real_progress, err, params, ctx)
  end
end

local root, main_path = fixtures.maven_project("deps-sync", "com.demo.sync", "App")
local pom_path = root .. "/pom.xml"
local data_dir = root .. "-data"

vim.cmd("edit " .. vim.fn.fnameescape(main_path))
jdtls.start_or_attach({
  cmd = { jdtls_bin, "-data", data_dir },
  root_dir = root,
})

local attached = fixtures.wait_for(30000, function()
  return require("java_menu.lsp").client(0) ~= nil
end)
assert(attached, "JDTLS não anexou ao projeto de teste")

-- ---------- edição cirúrgica do pom.xml ----------

local before = read_raw(pom_path)
local new_text, meta, insert_err = deps._insert_maven_dependency(before, {
  groupId = "org.slf4j",
  artifactId = "slf4j-api",
  version = "2.0.20",
})
assert(new_text, "inserção da dependência falhou: " .. tostring(insert_err))
assert(meta and meta.created_section == true, "o pom mínimo deveria ganhar a seção <dependencies>")

local written, write_err = deps._write_pom(pom_path, new_text)
assert(written, "escrita do pom.xml falhou: " .. tostring(write_err))
assert(read_raw(pom_path) == new_text, "conteúdo em disco divergiu do texto inserido")

local parsed = deps._parse_pom(read_raw(pom_path))
assert(#parsed.deps == 1, "o pom.xml reescrito não tem exatamente 1 dependência: " .. #parsed.deps)
assert(parsed.deps[1].groupId == "org.slf4j" and parsed.deps[1].artifactId == "slf4j-api")

-- ---------- sync real (H1) ----------

local bufnr = vim.fn.bufnr(main_path)
local begins_before = update_begins
local result
local started, reason = deps._sync_jdtls(bufnr, pom_path, function(ok, err)
  result = { ok = ok, err = err }
end)
assert(started == true, "o sync deveria iniciar com o cliente real anexado: " .. tostring(reason))

-- o handler do jdtls >= 1.63 é void: a request volta imediatamente e o job de
-- reimportação roda em background. A evidência observável é o progresso
-- "Updating project configurations" começar depois da request.
local finished = fixtures.wait_for(120000, function()
  return result ~= nil and update_begins > begins_before
end)
assert(finished, "java/projectConfigurationUpdate não disparou a reimportação em 120s")
assert(
  result.ok == true and result.err == nil,
  "java/projectConfigurationUpdate retornou erro: " .. tostring(result.err)
)
assert(update_begins > begins_before, "o JDTLS não emitiu o progresso de reimportação")

-- ---------- limpeza ----------

local client = require("java_menu.lsp").client(bufnr)
if client then
  pcall(function()
    client:stop()
  end)
  fixtures.wait_for(15000, function()
    return #vim.lsp.get_clients({ name = "jdtls" }) == 0
  end)
end

pcall(vim.cmd, "silent! bunload " .. bufnr)
pcall(vim.fn.delete, root, "rf")
pcall(vim.fn.delete, data_dir, "rf")

print("deps_sync_real_spec: OK (java/projectConfigurationUpdate sem erro + progresso de reimportação)")
vim.cmd("qa!")
