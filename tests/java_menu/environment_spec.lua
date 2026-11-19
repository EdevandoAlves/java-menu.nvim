-- 7B.1/7B.2: Environment (read-only). O relatório cobre Neovim/JDK/build tools/
-- JDTLS/wrappers/plugins opcionais sem instalar, iniciar ou compilar nada, e
-- (7B.2) os pré-requisitos do Spring Boot: curl/wget e unzip.
-- Nesta sessão -u NONE: snacks/which-key/neotest ficam fora do rtp (ausentes);
-- nvim-dap pode estar no rtp (o runner o adiciona quando instalado), então a
-- linha é aceita nos dois estados. Nada é escrito no cwd.
--
-- Run:
--   tests/java_menu/run.sh fast

local diagnostics = require("java_menu.diagnostics")

local function line_with(lines, prefix)
  for _, line in ipairs(lines) do
    if line:sub(1, #prefix) == prefix then
      return line
    end
  end
end

local function assert_line(lines, prefix)
  local line = line_with(lines, prefix)
  assert(line ~= nil, "linha ausente no relatório: " .. prefix .. "\n" .. vim.inspect(lines))
  return line
end

-- ---------- 1. _collect: todas as seções presentes ----------

local lines = diagnostics._collect()
for _, prefix in ipairs({
  "Neovim: ",
  "Java: ",
  "javac: ",
  "JAVA_HOME: ",
  "Maven: ",
  "Gradle: ",
  "unzip: ",
  "Maven wrapper: ",
  "Gradle wrapper: ",
  "JDTLS: ",
  "jc.nvim: ",
  "snacks.nvim: ",
  "which-key.nvim: ",
  "neotest: ",
  "nvim-dap: ",
}) do
  assert_line(lines, prefix)
end

-- Java/javac são tolerantes ao ambiente: presença ou "not found"
local java = assert_line(lines, "Java: ")
assert(java:find("not found", 1, true) or java:find("(", 1, true), "linha de Java incoerente: " .. java)
local javac = assert_line(lines, "javac: ")
assert(javac:find("not found", 1, true) or javac:find("(", 1, true), "linha de javac incoerente: " .. javac)

-- jc.nvim está no rtp dos specs → obrigatório e disponível
assert(
  line_with(lines, "jc.nvim: ") == "jc.nvim: available",
  "jc.nvim deveria estar disponível: " .. tostring(line_with(lines, "jc.nvim: "))
)

-- Opcionais fora do rtp nesta sessão
assert(line_with(lines, "snacks.nvim: "):find("not found", 1, true), "snacks não deveria estar disponível")
assert(line_with(lines, "which-key.nvim: "):find("not found", 1, true), "which-key não deveria estar disponível")
assert(line_with(lines, "neotest: "):find("not found", 1, true), "neotest não deveria estar disponível")

-- nvim-dap: o runner pode adicioná-lo ao rtp; os dois estados são válidos
local dap = line_with(lines, "nvim-dap: ")
assert(dap:find("available", 1, true) or dap:find("not found", 1, true), "linha de nvim-dap incoerente: " .. dap)

-- sem projeto no cwd: wrappers indicam "no project"
assert(line_with(lines, "Maven wrapper: ") == "Maven wrapper: no project", "wrapper Maven sem projeto divergiu")
assert(line_with(lines, "Gradle wrapper: ") == "Gradle wrapper: no project", "wrapper Gradle sem projeto divergiu")

-- ---------- 2. 7B.2: cliente HTTP e unzip (Spring Boot) ----------

-- curl tem preferência; wget é o fallback. Sem nenhum dos dois a linha do
-- curl aparece com "not found" e a criação Spring fica indisponível.
local http = line_with(lines, "curl: ") or line_with(lines, "wget: ")
assert(http ~= nil, "linha do cliente HTTP (curl/wget) ausente:\n" .. vim.inspect(lines))
assert(http:find("not found", 1, true) or http:find("(", 1, true), "linha HTTP incoerente: " .. http)

local unzip = assert_line(lines, "unzip: ")
assert(unzip:find("not found", 1, true) or unzip:find("(", 1, true), "linha de unzip incoerente: " .. unzip)

-- ---------- 3. Report: buffer read-only e fechável com q ----------

diagnostics.report()
local buf = vim.api.nvim_get_current_buf()
assert(vim.bo[buf].buftype == "nofile", "relatório não é um buffer nofile")
assert(vim.bo[buf].modifiable == false, "relatório deveria ser read-only")
assert(vim.bo[buf].swapfile == false, "relatório não deveria ter swapfile")
local q = vim.fn.maparg("q", "n", false, true)
assert(type(q) == "table" and q.buffer == 1, "mapeamento q ausente no relatório")
local report_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(vim.deep_equal(report_lines, diagnostics._collect()), "relatório divergiu de _collect()")
vim.cmd("close")

-- ---------- 4. Sem efeitos colaterais: nada escrito no cwd ----------

local empty = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(empty, "p")
local prev_cwd = vim.uv.cwd()
vim.cmd("cd " .. vim.fn.fnameescape(empty))
local blank = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(blank)

local before = vim.fn.readdir(empty)
local collected = diagnostics._collect()
assert(#collected > 0, "_collect não retornou linhas")
diagnostics.report()
vim.cmd("close")
local after = vim.fn.readdir(empty)
assert(vim.deep_equal(before, after), "o relatório escreveu no cwd: " .. vim.inspect(after))

-- ---------- restauração ----------

vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
vim.fn.delete(empty, "rf")

print("environment_spec: OK (seções presentes, report read-only, sem efeitos colaterais)")
vim.cmd("qa!")
