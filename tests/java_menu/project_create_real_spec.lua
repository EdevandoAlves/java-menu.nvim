-- 7B.1 (INTEGRATION): scaffolding real com Maven e javac instalados. Cria
-- projetos temporários, compila e executa a Main gerada; apaga somente os
-- diretórios que este spec criou. Sem mvn/javac, pula com mensagem clara.
--
-- Run:
--   tests/java_menu/run.sh integration

if vim.fn.executable("mvn") == 0 or vim.fn.executable("javac") == 0 then
  print("project_create_real_spec: SKIP (mvn e/ou javac ausentes no PATH)")
  vim.cmd("qa!")
  return
end

local create = require("java_menu.create")

local dirs = {}
local function new_parent(label)
  local dir = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-real-" .. label)
  vim.fn.mkdir(dir, "p")
  dirs[#dirs + 1] = dir
  return dir
end

local function system(cmd)
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error
end

-- ---------- 1. Maven real: mvn package + java -cp ----------

local maven_parent = new_parent("maven")
local maven_opts = {
  kind = "maven",
  parent = maven_parent,
  name = "realapp",
  pkg = "com.real.app",
  release = "21",
  group = "com.real",
  artifact = "realapp",
}
local ok, err = create._run(maven_opts)
assert(ok, "criação Maven real falhou: " .. tostring(err))

local maven_target = maven_parent .. "/realapp"
local pom = maven_target .. "/pom.xml"
local build_out, build_code = system({ "mvn", "-q", "-B", "-f", pom, "package" })
assert(build_code == 0, "mvn package falhou (exit " .. tostring(build_code) .. "):\n" .. build_out)
assert(
  vim.fn.filereadable(maven_target .. "/target/classes/com/real/app/Main.class") == 1,
  "Main.class não gerado pelo Maven"
)

local run_out, run_code = system({ "java", "-cp", maven_target .. "/target/classes", "com.real.app.Main" })
assert(run_code == 0, "java -cp (Maven) falhou (exit " .. tostring(run_code) .. "):\n" .. run_out)
assert(run_out:find("Hello from realapp!", 1, true), "saída inesperada do Main Maven: " .. run_out)

-- ---------- 2. Plain real: javac -d + java -cp ----------

local plain_parent = new_parent("plain")
local plain_opts = {
  kind = "plain",
  parent = plain_parent,
  name = "plainapp",
  pkg = "com.real.plain",
  release = "21",
}
ok, err = create._run(plain_opts)
assert(ok, "criação plain real falhou: " .. tostring(err))

local plain_target = plain_parent .. "/plainapp"
local main_path = plain_target .. "/src/main/java/com/real/plain/Main.java"
local classes = plain_parent .. "/classes"
vim.fn.mkdir(classes, "p")

local javac_out, javac_code = system({ "javac", "--release", "21", "-d", classes, main_path })
assert(javac_code == 0, "javac falhou (exit " .. tostring(javac_code) .. "):\n" .. javac_out)

local plain_out, plain_code = system({ "java", "-cp", classes, "com.real.plain.Main" })
assert(plain_code == 0, "java -cp (plain) falhou (exit " .. tostring(plain_code) .. "):\n" .. plain_out)
assert(plain_out:find("Hello from plainapp!", 1, true), "saída inesperada do Main plain: " .. plain_out)

-- ---------- limpeza (somente os temporários deste spec) ----------

for _, dir in ipairs(dirs) do
  vim.fn.delete(dir, "rf")
end

print("project_create_real_spec: OK (mvn package + java, javac + java)")
vim.cmd("qa!")
