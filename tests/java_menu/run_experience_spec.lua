-- 7D: Run Experience (run_config.lua + build.lua).
-- Cobre:
--   1. Descoberta contextual de profiles (application*.{yml,yaml,properties})
--   2. Parsing seguro de .env (sem execução de shell, avisos sem vazar valores)
--   3. Redação literal de segredos em output, notificações e display de comando
--   4. Persistência isolada por projeto (mesmo basename / mesmo cwd não colidem;
--      nenhum segredo persistido em disco; JSON corrompido tratado com segurança)
--   5. Fluxos de menu (Run Spring Boot, Run Main Class, Run Settings, Restart)
--      com processo real, injeção de .env via jobstart, substituição segura
--      em Restart e confirmação entre projetos.
--
-- Run:
--   nvim --headless -u NONE -n \
--     -c "set rtp+=." -c "set rtp+=~/.local/share/nvim/lazy/jc.nvim" \
--     -c 'lua dofile("tests/java_menu/run_experience_spec.lua")' -c qa!

local run_config = require("java_menu.run_config")
local build = require("java_menu.build")
local ui = require("java_menu.ui")
local lsp = require("java_menu.lsp")
local fixtures = require("tests.java_menu.fixtures")

-- Isola persistência dos testes em diretório temporário (não suja stdpath("data") real)
local temp_dirs = {}
local data_dir = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-7d-data")
vim.fn.mkdir(data_dir, "p")
temp_dirs[#temp_dirs + 1] = data_dir
run_config._base_dir = data_dir

local function tempdir(label)
  local dir = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-7d-" .. label)
  vim.fn.mkdir(dir, "p")
  temp_dirs[#temp_dirs + 1] = dir
  return dir
end

local function read_raw(path)
  local fd = assert(vim.uv.fs_open(path, "r", 420))
  local stat = assert(vim.uv.fs_fstat(fd))
  local data = stat.size > 0 and assert(vim.uv.fs_read(fd, stat.size, 0)) or ""
  vim.uv.fs_close(fd)
  return data
end

local function pid_alive(pid)
  if not pid or pid <= 0 then
    return false
  end
  vim.fn.system({ "kill", "-0", tostring(pid) })
  return vim.v.shell_error == 0
end

-- Stubs de UI
local real_notify = ui.notify
local real_ask = ui.ask
local real_menu = ui.menu
local real_pick_one = ui.pick_one
local real_client_or_reason = lsp.client_or_reason
local real_get_clients = vim.lsp.get_clients

local notices = {}
local menu_entries, menu_cb
local pick_script = {}
local ask_script = {}

ui.notify = function(msg, level)
  notices[#notices + 1] = { msg = tostring(msg), level = level }
end
ui.menu = function(entries, _, on_choice)
  menu_entries, menu_cb = entries, on_choice
end
ui.pick_one = function(items, _, on_choice)
  local want = table.remove(pick_script, 1)
  if want == false or want == nil then
    return
  end
  for _, item in ipairs(items) do
    if item == want or item:find(want, 1, true) then
      return on_choice(item)
    end
  end
  error("stub pick_one: nenhuma entrada casou com '" .. tostring(want) .. "' em " .. vim.inspect(items))
end
ui.ask = function(_, _, on_confirm)
  local val = table.remove(ask_script, 1)
  if val == false or val == nil then
    return on_confirm(nil)
  end
  return on_confirm(val)
end

local function has_notice(needle)
  for _, n in ipairs(notices) do
    if n.msg:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function any_notice_contains(secret)
  for _, n in ipairs(notices) do
    if n.msg:find(secret, 1, true) then
      return true
    end
  end
  return false
end

local function buf_text(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function entry(key)
  for _, item in ipairs(menu_entries or {}) do
    if item.key == key then
      return item
    end
  end
end

local function open_file(path)
  pcall(vim.cmd, "silent! only")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "java"
end

-- ========== 1. Descoberta contextual de profiles ==========

do
  local root = fixtures.maven_nested("profiles")
  fixtures.write(root .. "/src/main/resources/application.yml", { "server:", "  port: 8080" })
  fixtures.write(root .. "/src/main/resources/application-dev.yml", { "spring:", "  foo: bar" })
  fixtures.write(root .. "/src/main/resources/application-dev.properties", { "foo=bar" })
  fixtures.write(root .. "/src/main/resources/config/application-staging.yaml", { "x: 1" })
  fixtures.write(root .. "/services/api/src/main/resources/application-api-local.properties", { "a=1" })
  fixtures.write(root .. "/services/worker/src/main/resources/application-worker-only.yml", { "w: 1" })

  local api_scan = run_config.scan_profiles(root, root .. "/services/api")
  assert(api_scan.has_default == true, "application.yml deveria marcar has_default")
  assert(
    vim.deep_equal(api_scan.profiles, { "api-local", "dev", "staging" }),
    "scan contextual do módulo api divergiu: " .. vim.inspect(api_scan.profiles)
  )

  local all_scan = run_config.scan_profiles(root)
  assert(
    vim.deep_equal(all_scan.profiles, { "api-local", "dev", "staging", "worker-only" }),
    "scan agregado divergiu: " .. vim.inspect(all_scan.profiles)
  )
end

-- ========== 2. Parsing seguro de .env (sem execução) e redação ==========

do
  local proj = tempdir("env-parse")
  local marker_file = proj .. "/pwned.txt"
  local secret_a = "s3cr3t.a+b*c[1](2)%3?$"
  local secret_b = "s3cr3t"
  local cmd_sub = "$(touch " .. marker_file .. ")"
  local backtick_sub = "`touch " .. marker_file .. "`"

  fixtures.write(proj .. "/.env", {
    "# comentário inicial",
    "",
    "API_SECRET=" .. secret_a .. "\r",
    "SHORT_PREFIX=" .. secret_b,
    'QUOTED_VAL="hello world"',
    "SINGLE_HASH='abc#def'",
    "CMD_SUB=" .. cmd_sub,
    "BACKTICK_SUB=" .. backtick_sub,
    "SHORT_FLAG=1",
    "export LEAKED_EXPORT=must_not_appear_in_warning",
    "BAD_LINE_WITHOUT_EQUALS_secret_value_here",
  })

  local res = run_config.load_env(proj)
  assert(res.exists == true, ".env deveria ser detectado")
  assert(vim.fn.filereadable(marker_file) == 0, ".env NÃO pode executar comandos de shell!")
  assert(res.env.API_SECRET == secret_a, "API_SECRET divergiu")
  assert(res.env.SHORT_PREFIX == secret_b, "SHORT_PREFIX divergiu")
  assert(res.env.QUOTED_VAL == "hello world", "QUOTED_VAL divergiu")
  assert(res.env.SINGLE_HASH == "abc#def", "SINGLE_HASH com # não deve ser truncado")
  assert(res.env.CMD_SUB == cmd_sub, "CMD_SUB deve permanecer literal")
  assert(res.env.BACKTICK_SUB == backtick_sub, "BACKTICK_SUB deve permanecer literal")
  assert(res.env.LEAKED_EXPORT == nil, "linha com export deveria ser ignorada")
  assert(#res.warnings == 2, "deveria haver 2 avisos de sintaxe: " .. vim.inspect(res.warnings))

  for _, w in ipairs(res.warnings) do
    assert(not w:find("must_not_appear_in_warning", 1, true), "aviso vazou valor de linha export: " .. w)
    assert(not w:find("secret_value_here", 1, true), "aviso vazou conteúdo de linha inválida: " .. w)
  end

  local redactions = run_config.collect_redactions(res.env)
  for i = 1, #redactions - 1 do
    assert(#redactions[i] >= #redactions[i + 1], "segredos devem ser ordenados do maior para o menor")
  end
  local idx_a, idx_b
  for i, v in ipairs(redactions) do
    if v == secret_a then
      idx_a = i
    elseif v == secret_b then
      idx_b = i
    end
  end
  assert(idx_a and idx_b and idx_a < idx_b, "secret_a deve vir antes de secret_b na ordenação")
  local redacted =
    run_config.redact(("token=%s prefix=%s exit 1 cmd=%s"):format(secret_a, secret_b, cmd_sub), redactions)
  assert(not redacted:find(secret_a, 1, true), "secret_a não foi redigido")
  assert(not redacted:find(secret_b, 1, true), "secret_b não foi redigido")
  assert(not redacted:find(cmd_sub, 1, true), "cmd_sub não foi redigido")
  assert(not redacted:find("exit 1", 1, true), "valores curtos também devem ser protegidos")
  assert(run_config.redact("A REDACTED", run_config.collect_redactions({ S = "A" })) == "[REDACTED] RED[REDACTED]CTED")
end

-- ========== 3. split_args sem shell ==========

do
  local a, err = run_config.split_args("-Xmx512m -Dmsg=\"hello world\" --tag='v 1'")
  assert(err == nil and vim.deep_equal(a, { "-Xmx512m", "-Dmsg=hello world", "--tag=v 1" }), vim.inspect(a))
  local b, berr = run_config.split_args('-Dbad="unclosed')
  assert(b == nil and berr ~= nil, "aspas abertas deveriam falhar")
end

-- ========== 4. Persistência isolada por projeto (mesmo basename!) ==========

do
  local parent1 = tempdir("same-name-1")
  local parent2 = tempdir("same-name-2")
  local p1 = parent1 .. "/service"
  local p2 = parent2 .. "/service"
  vim.fn.mkdir(p1, "p")
  vim.fn.mkdir(p2, "p")

  assert(run_config.storage_path(p1) ~= run_config.storage_path(p2), "mesmo basename colidiu no storage_path")
  assert(run_config.save(p1, { profile = "dev", jvm_args = "-Xmx1g", app_args = "--port=8081", use_env = true }))
  assert(run_config.save(p2, { profile = "prod", jvm_args = "-Xmx2g", app_args = "--port=8082", use_env = false }))

  local c1 = run_config.load(p1)
  local c2 = run_config.load(p2)
  assert(c1.profile == "dev" and c1.jvm_args == "-Xmx1g" and c1.use_env == true, "config p1 divergiu")
  assert(c2.profile == "prod" and c2.jvm_args == "-Xmx2g" and c2.use_env == false, "config p2 divergiu")

  -- JSON corrompido retorna defaults + aviso sem lançar erro
  local bad_path = run_config.storage_path(p1)
  fixtures.write(bad_path, { "{broken json" })
  local fallback, load_err = run_config.load(p1)
  assert(fallback.profile == "" and load_err ~= nil, "JSON inválido deveria cair em defaults com aviso")
  assert(run_config.reset(p1))
  assert(run_config.reset(p2))
end

-- ========== 5. Fluxo Spring Boot + .env + proteção de segredos + Restart ==========

local secret_token = "TopSecret_$uper!Token#9988"
local root_a, main_a = fixtures.maven_project("run7d-alpha", "com.demo.alpha", "App")
local root_b, main_b = fixtures.maven_project("run7d-beta", "com.demo.beta", "App")

-- Adiciona spring-boot ao pom.xml de A e profiles contextuais
fixtures.write(root_a .. "/pom.xml", {
  '<project xmlns="http://maven.apache.org/POM/4.0.0">',
  "  <modelVersion>4.0.0</modelVersion>",
  "  <groupId>com.demo</groupId>",
  "  <artifactId>alpha</artifactId>",
  "  <version>1.0</version>",
  "  <dependencies>",
  "    <dependency>",
  "      <groupId>org.springframework.boot</groupId>",
  "      <artifactId>spring-boot-starter</artifactId>",
  "    </dependency>",
  "  </dependencies>",
  "</project>",
})
fixtures.write(root_a .. "/src/main/resources/application.yml", { "spring: {}" })
fixtures.write(root_a .. "/src/main/resources/application-dev.yml", { "server: { port: 8081 }" })
fixtures.write(root_a .. "/src/main/resources/application-prod.properties", { "server.port=8082" })
fixtures.write(root_a .. "/.env", {
  "API_SECRET=" .. secret_token,
  "SHORT_TAG=xy",
})

local env_len_file = root_a .. "/child_seen_len.txt"
fixtures.write(root_a .. "/mvnw", {
  "#!/bin/sh",
  'printf "%s" "${#API_SECRET}" > ' .. vim.fn.shellescape(env_len_file),
  'printf "stdout token=%s\\n" "$API_SECRET"',
  'printf "stderr token=%s\\n" "$API_SECRET" >&2',
  'printf "split="',
  'printf "%s\\n" "$API_SECRET"',
  'echo "args=$*"',
  "exec sleep 30",
})
vim.fn.system({ "chmod", "+x", root_a .. "/mvnw" })

-- Fake mvnw para projeto B
fixtures.write(root_b .. "/mvnw", { "#!/bin/sh", "exec sleep 30" })
vim.fn.system({ "chmod", "+x", root_b .. "/mvnw" })

-- 5a. Cancelamento em Run Spring Boot não persiste nada nem inicia processo
open_file(main_a)
notices = {}
build.build()
assert(entry("restart").enabled == false, "restart deveria iniciar desabilitado em A")
assert(entry("restart").reason:find("no previous command", 1, true), "motivo do restart divergiu")
pick_script = { "dev" }
ask_script = { "-Xmx256m", false } -- cancela no último prompt
menu_cb(entry("run_spring"))
assert(not build._state.running, "cancelamento não deve iniciar processo")
assert(run_config.load(root_a).profile == "", "cancelamento não deve persistir profile")

-- 5b. Run Spring Boot completo com profile contextual, JVM args, app args e .env
notices = {}
build.build()
pick_script = { "dev" }
ask_script = { "-Xmx512m", "--server.port=9091" }
menu_cb(entry("run_spring"))

assert(
  fixtures.wait_for(10000, function()
    return build._state.running and build._state.job ~= nil
  end),
  "Run Spring Boot não iniciou"
)

local cmd_str = table.concat(build._state.cmd, " ")
assert(cmd_str:find("-Dspring-boot.run.profiles=dev", 1, true), "profile dev ausente: " .. cmd_str)
assert(cmd_str:find("-Dspring-boot.run.jvmArguments=-Xmx512m", 1, true), "jvmArguments ausente: " .. cmd_str)
assert(cmd_str:find("-Dspring-boot.run.arguments=--server.port=9091", 1, true), "arguments ausente: " .. cmd_str)
assert(not cmd_str:find(secret_token, 1, true), "segredo vazou no cmd")

-- Aguarda o processo imprimir stdout/stderr e o arquivo de comprimento
assert(
  fixtures.wait_for(10000, function()
    local text = buf_text(build._state.buf)
    return vim.fn.filereadable(env_len_file) == 1
      and text:find("stdout token=", 1, true) ~= nil
      and text:find("stderr token=", 1, true) ~= nil
      and text:find("split=[REDACTED]", 1, true) ~= nil
  end),
  "saída do processo filho não chegou ao buffer"
)

assert(
  tonumber(read_raw(env_len_file)) == #secret_token,
  "processo filho não recebeu API_SECRET correto via jobstart env"
)

local out_text = buf_text(build._state.buf)
assert(out_text:find(".env loaded (2 variable(s), values hidden)", 1, true), "cabeçalho .env ausente")
assert(out_text:find("stdout token=[REDACTED]", 1, true), "stdout não redigiu segredo: " .. out_text)
assert(out_text:find("stderr token=[REDACTED]", 1, true), "stderr não redigiu segredo: " .. out_text)
assert(out_text:find("split=[REDACTED]", 1, true), "saída fragmentada não redigiu segredo: " .. out_text)
assert(not out_text:find(secret_token, 1, true), "SEGREDO VAZOU no buffer de saída!")
assert(not any_notice_contains(secret_token), "SEGREDO VAZOU nas notificações!")

-- Verifica persistência em disco (apenas não-segredos)
local persisted_raw = read_raw(run_config.storage_path(root_a))
assert(not persisted_raw:find(secret_token, 1, true), "SEGREDO VAZOU no arquivo persistido!")
local saved_a = run_config.load(root_a)
assert(saved_a.profile == "dev" and saved_a.jvm_args == "-Xmx512m" and saved_a.app_args == "--server.port=9091")

-- 5c. Restart no mesmo projeto: encerra PID anterior, reinicia comando gravado, mantém sigilo do .env
local old_pid = build._state.pid
local old_seq = build._state.seq
assert(pid_alive(old_pid), "PID inicial deveria estar vivo")
vim.fn.delete(env_len_file)
notices = {}
build.build()
local restart_entry = entry("restart")
assert(restart_entry and restart_entry.enabled, "Restart deveria estar habilitado em A")
menu_cb(restart_entry)

assert(
  fixtures.wait_for(10000, function()
    return build._state.running
      and build._state.seq > old_seq
      and build._state.pid ~= nil
      and build._state.pid ~= old_pid
      and vim.fn.filereadable(env_len_file) == 1
  end),
  "Restart não iniciou novo processo em A"
)
assert(not pid_alive(old_pid), "PID antigo sobreviveu ao Restart!")
assert(tonumber(read_raw(env_len_file)) == #secret_token, "Restart não reinjetou .env!")
assert(not buf_text(build._state.buf):find(secret_token, 1, true), "SEGREDO VAZOU no output após Restart!")
assert(not any_notice_contains(secret_token), "SEGREDO VAZOU em notificação após Restart!")
assert(
  vim.deep_equal(build._state.cmd, build._last_runs[run_config.canonical(root_a)].cmd),
  "Restart não usou o comando gravado"
)

-- 5d. Isolamento entre projetos: projeto B não vê comando de A, nem seus settings
open_file(main_b)
build.build()
assert(entry("restart").enabled == false, "Projeto B não deveria herdar restart de A")
assert(run_config.load(root_b).profile == "", "Projeto B não deveria herdar profile de A")

-- Para A com confirmação a partir de B, grava comando em B e testa confirmação em Restart entre projetos
pick_script = { "Yes" }
menu_cb(entry("stop"))
assert(
  fixtures.wait_for(10000, function()
    return not build._state.running
  end),
  "stop de A a partir de B não concluiu"
)

build.build()
menu_cb(entry("compile"))
assert(
  fixtures.wait_for(10000, function()
    return build._state.running and build._state.root == vim.uv.fs_realpath(root_b)
  end),
  "compile de B não iniciou"
)
build.stop(true)
assert(
  fixtures.wait_for(10000, function()
    return not build._state.running
  end),
  "stop de B não concluiu"
)

-- Inicia A novamente e testa Restart em B pedindo confirmação antes de parar A
open_file(main_a)
build.restart()
assert(
  fixtures.wait_for(10000, function()
    return build._state.running and build._state.root == vim.uv.fs_realpath(root_a)
  end),
  "restart de A não iniciou"
)
local a_pid = build._state.pid

open_file(main_b)
build.build()
assert(entry("restart").enabled == true, "B deveria ter seu próprio comando gravado")
assert(entry("restart").reason:find("another project", 1, true), "Restart em B deveria avisar sobre outro projeto")
pick_script = { "No" }
menu_cb(entry("restart"))
assert(build._state.running and build._state.pid == a_pid and pid_alive(a_pid), "Restart recusado matou processo de A!")

pick_script = { "Yes" }
build.build()
menu_cb(entry("restart"))
assert(
  fixtures.wait_for(10000, function()
    return build._state.running and build._state.root == vim.uv.fs_realpath(root_b)
  end),
  "Restart confirmado em B não assumiu após parar A"
)
assert(not pid_alive(a_pid), "processo de A sobreviveu após confirmação de Restart em B")

-- Para B limpamente
build.stop(true)
assert(
  fixtures.wait_for(10000, function()
    return not build._state.running
  end),
  "stop de B não concluiu"
)
assert(#build._state.redactions == 0, "redactions deveria ser limpo após término")

-- ========== 6. Run Settings menu (toggle .env, editar profile/JVM args, reset) ==========

open_file(main_a)
notices = {}
build.run_settings()
assert(entry("use_env").enabled == true, "use_env deveria estar habilitado quando .env existe")
assert(entry("use_env").label:find("values hidden", 1, true), "label .env deve ocultar valores")
assert(not entry("use_env").label:find(secret_token, 1, true), "label .env vazou segredo")
menu_cb(entry("use_env"))
assert(run_config.load(root_a).use_env == false, "toggle .env deveria desabilitar use_env")
assert(not any_notice_contains(secret_token), "notificação de Run Settings vazou segredo")

build.run_settings()
pick_script = { "prod" }
menu_cb(entry("profile"))
assert(run_config.load(root_a).profile == "prod", "Run Settings deveria atualizar profile para prod")

build.run_settings()
ask_script = { "-Xms64m -Xmx1g" }
menu_cb(entry("jvm_args"))
assert(run_config.load(root_a).jvm_args == "-Xms64m -Xmx1g", "Run Settings deveria atualizar jvm_args")

build.run_settings()
menu_cb(entry("reset"))
local reset_a = run_config.load(root_a)
assert(reset_a.profile == "" and reset_a.jvm_args == "" and reset_a.use_env == true, "reset falhou em Run Settings")

-- ========== 7. Run Main Class com JVM args + app args + .env ==========

local root_m, main_m = fixtures.maven_project("run7d-main", "com.demo.m", "Main")
fixtures.write(main_m, {
  "package com.demo.m;",
  "",
  "public class Main {",
  "  public static void main(String[] args) {}",
  "}",
})
local fake_vm = tempdir("fake-jdk")
local fake_java = fake_vm .. "/bin/java"
local java_capture = root_m .. "/java_args.txt"
fixtures.write(fake_java, {
  "#!/bin/sh",
  'printf "%s\\n" "$@" > ' .. vim.fn.shellescape(java_capture),
  'printf "MAIN_TOKEN=%s\\n" "$MAIN_SECRET"',
})
vim.fn.system({ "chmod", "+x", fake_java })
fixtures.write(root_m .. "/.env", { "MAIN_SECRET=MainSecret#4321" })

-- Stub de cliente JDTLS apenas para este bloco
vim.lsp.get_clients = function(filter)
  if filter and filter.name == "jdtls" then
    return { { id = 99, name = "jdtls" } }
  end
  return real_get_clients(filter)
end
lsp.client_or_reason = function()
  return {
    request = function(_, _, params, cb)
      if params.command == "java.project.getClasspaths" then
        cb(nil, {
          classpaths = { root_m .. "/target/classes" },
          projectRoot = vim.uri_from_fname(root_m),
        })
      elseif params.command == "java.project.getSettings" then
        cb(nil, { ["org.eclipse.jdt.ls.core.vm.location"] = fake_vm })
      end
    end,
  }
end

open_file(main_m)
notices = {}
build.build()
assert(entry("run_main").enabled == true, "run_main deveria estar habilitado com cliente stubado")
pick_script = { "com.demo.m.Main" }
ask_script = { "-Xmx128m -ea", '--msg="hello world"' }
menu_cb(entry("run_main"))

assert(
  fixtures.wait_for(10000, function()
    return not build._state.running and build._state.status == "success" and vim.fn.filereadable(java_capture) == 1
  end),
  "Run Main não concluiu"
)

local captured_args = read_raw(java_capture)
assert(captured_args:find("-Xmx128m", 1, true), "JVM arg ausente: " .. captured_args)
assert(captured_args:find("-ea", 1, true), "JVM arg -ea ausente: " .. captured_args)
assert(captured_args:find("-cp", 1, true), "-cp ausente: " .. captured_args)
assert(captured_args:find("com.demo.m.Main", 1, true), "main class ausente: " .. captured_args)
assert(captured_args:find("--msg=hello world", 1, true), "app arg com aspas ausente: " .. captured_args)

local main_out = buf_text(build._state.buf)
assert(main_out:find("MAIN_TOKEN=[REDACTED]", 1, true), "segredo do Run Main não foi redigido: " .. main_out)
assert(not main_out:find("MainSecret#4321", 1, true), "segredo vazou no output de Run Main")
assert(not any_notice_contains("MainSecret#4321"), "segredo vazou em notificação de Run Main")

-- ========== 8. Regression (1): Descendente resistente a SIGTERM no Restart ==========

do
  local root_r, main_r = fixtures.maven_project("run7d-term-resist", "com.demo.r", "App")
  local child_pid_file = root_r .. "/resistant_child.pid"
  local launch_count_file = root_r .. "/launch_count.txt"
  fixtures.write(root_r .. "/mvnw", {
    "#!/bin/sh",
    'printf "1\\n" >> ' .. vim.fn.shellescape(launch_count_file),
    '(trap "" TERM; exec sleep 30) &',
    "cpid=$!",
    'printf "%s" "$cpid" > ' .. vim.fn.shellescape(child_pid_file),
    "wait",
  })
  vim.fn.system({ "chmod", "+x", root_r .. "/mvnw" })

  -- Processo externo não relacionado não pode ser afetado
  local external_job = vim.fn.jobstart({ "sleep", "30" })
  assert(external_job > 0, "processo externo de teste não iniciou")
  local external_pid = vim.fn.jobpid(external_job)

  open_file(main_r)
  build.build()
  menu_cb(entry("compile"))
  assert(
    fixtures.wait_for(10000, function()
      return build._state.running and vim.fn.filereadable(child_pid_file) == 1
    end),
    "processo com filho resistente não iniciou"
  )
  local first_child_pid = tonumber(read_raw(child_pid_file))
  local first_seq = build._state.seq
  assert(first_child_pid and pid_alive(first_child_pid), "filho resistente deveria estar vivo")

  -- 8a. Timeout de restart antes do grace period recusa relançar enquanto o grupo sobrevive
  local orig_grace = build._stop_grace_ms
  local orig_timeout = build._restart_timeout_ms
  build._stop_grace_ms = 5000
  build._restart_timeout_ms = 250
  notices = {}
  build.restart()

  assert(
    fixtures.wait_for(3000, function()
      return not build._state.restarting and has_notice("did not exit in time")
    end),
    "restart deveria ter sido cancelado enquanto filho resistente sobrevivia"
  )
  assert(build._state.seq == first_seq, "restart NÃO pode iniciar novo processo enquanto grupo anterior sobrevive!")
  assert(pid_alive(first_child_pid), "filho resistente deveria continuar vivo durante a recusa")
  assert(build._is_draining(), "grupo anterior ainda drenando deveria ser detectado")

  -- start() direto também deve recusar enquanto grupo anterior sobrevive
  notices = {}
  build.build()
  menu_cb(entry("compile"))
  assert(not build._state.running and build._state.seq == first_seq, "novo compile não pode iniciar durante drenagem")
  assert(has_notice("still exiting"), "start() deveria avisar que grupo anterior ainda está saindo")

  -- 8b. Com grace period normal, Restart envia SIGKILL ao grupo após grace e só lança depois do grupo morrer
  build._stop_grace_ms = 250
  build._restart_timeout_ms = 5000
  vim.fn.delete(child_pid_file)
  notices = {}
  build.restart()

  assert(
    fixtures.wait_for(10000, function()
      return build._state.running and build._state.seq > first_seq and vim.fn.filereadable(child_pid_file) == 1
    end),
    "Restart não relançou após encerramento completo do grupo resistente"
  )
  assert(not pid_alive(first_child_pid), "filho resistente antigo sobreviveu ao Restart!")
  assert(pid_alive(external_pid), "Restart matou processo externo não relacionado!")

  local second_child_pid = tonumber(read_raw(child_pid_file))
  build.stop(true)
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "stop final do projeto resistente não concluiu"
  )
  assert(not pid_alive(second_child_pid), "segundo filho resistente sobreviveu ao stop")
  assert(pid_alive(external_pid), "stop matou processo externo não relacionado!")

  vim.fn.jobstop(external_job)
  build._stop_grace_ms = orig_grace
  build._restart_timeout_ms = orig_timeout
end

-- ========== 9. Regression (2): Callbacks de confirmação stale em M.stop / M.restart ==========

do
  local root_s1, main_s1 = fixtures.maven_project("run7d-stale-1", "com.demo.s1", "App")
  local root_s2, main_s2 = fixtures.maven_project("run7d-stale-2", "com.demo.s2", "App")
  local root_s3, main_s3 = fixtures.maven_project("run7d-stale-3", "com.demo.s3", "App")
  for _, r in ipairs({ root_s1, root_s2, root_s3 }) do
    fixtures.write(r .. "/mvnw", { "#!/bin/sh", "exec sleep 30" })
    vim.fn.system({ "chmod", "+x", r .. "/mvnw" })
  end

  -- Registra comandos prévios em s2 e s3 para permitir M.restart()
  for _, pair in ipairs({ { root_s2, main_s2 }, { root_s3, main_s3 } }) do
    open_file(pair[2])
    build.build()
    menu_cb(entry("compile"))
    assert(fixtures.wait_for(5000, function()
      return build._state.running
    end))
    build.stop(true)
    assert(fixtures.wait_for(5000, function()
      return not build._state.running
    end))
  end

  -- Inicia processo em s1
  open_file(main_s1)
  build.build()
  menu_cb(entry("compile"))
  assert(fixtures.wait_for(5000, function()
    return build._state.running
  end))
  local seq_s1 = build._state.seq

  -- Captura callbacks pendentes de M.stop e M.restart a partir de s2 sem responder ainda
  local captured_stop_cb, captured_restart_cb
  local saved_pick = ui.pick_one
  ui.pick_one = function(_, _, on_choice)
    captured_stop_cb = on_choice
  end
  open_file(main_s2)
  build.stop()
  assert(type(captured_stop_cb) == "function", "M.stop deveria abrir confirmação")

  ui.pick_one = function(_, _, on_choice)
    captured_restart_cb = on_choice
  end
  build.restart()
  assert(type(captured_restart_cb) == "function", "M.restart deveria abrir confirmação")
  ui.pick_one = saved_pick

  -- Troca s1 -> s3 (novo processo, nova seq e novo projeto!)
  build.stop(true)
  assert(fixtures.wait_for(5000, function()
    return not build._state.running
  end))
  open_file(main_s3)
  build.build()
  menu_cb(entry("compile"))
  assert(fixtures.wait_for(5000, function()
    return build._state.running
  end))
  local pid_s3 = build._state.pid
  local seq_s3 = build._state.seq
  assert(seq_s3 > seq_s1)

  -- Callback stale de M.stop não pode parar s3!
  notices = {}
  captured_stop_cb("Yes — stop the run7d-stale-1 project process")
  assert(build._state.running and build._state.seq == seq_s3 and pid_alive(pid_s3), "callback stale de stop matou s3!")
  assert(has_notice("stale"), "callback stale de stop deveria avisar")

  -- Callback stale de M.restart (seq diferente) não pode parar s3 nem reiniciar s2!
  notices = {}
  captured_restart_cb("Yes — stop the run7d-stale-1 project process and restart")
  assert(
    build._state.running and build._state.seq == seq_s3 and pid_alive(pid_s3) and not build._state.restarting,
    "callback stale de restart afetou s3!"
  )
  assert(has_notice("stale"), "callback stale de restart deveria avisar")

  build.stop(true)
  assert(fixtures.wait_for(5000, function()
    return not build._state.running
  end))

  -- Callback stale por mudança de projeto do buffer mesmo quando seq original ainda roda
  open_file(main_s1)
  build.build()
  menu_cb(entry("compile"))
  assert(fixtures.wait_for(5000, function()
    return build._state.running
  end))
  local pid_s1_b = build._state.pid
  local seq_s1_b = build._state.seq

  local cb_buf_switch
  ui.pick_one = function(_, _, on_choice)
    cb_buf_switch = on_choice
  end
  open_file(main_s2)
  build.restart()
  ui.pick_one = saved_pick
  assert(type(cb_buf_switch) == "function")

  -- Troca o buffer para s3 antes de confirmar o prompt aberto em s2
  open_file(main_s3)
  notices = {}
  cb_buf_switch("Yes — stop the run7d-stale-1 project process and restart")
  assert(
    build._state.running and build._state.seq == seq_s1_b and pid_alive(pid_s1_b) and not build._state.restarting,
    "callback de restart em buffer trocado não pode agir!"
  )
  assert(has_notice("stale"), "mudança de projeto deveria invalidar confirmação")

  build.stop(true)
  assert(fixtures.wait_for(5000, function()
    return not build._state.running
  end))
end

-- ========== 10. Regression (3): Args com aspas preservados no Repeat Last sem tocar jc build-last ==========

do
  -- Roundtrip format_args <-> split_args
  local samples = {
    { "clean", "package" },
    { "-Dmsg=hello world", "--tag=v 1", "test" },
    { '-Dquote="hi there"', "it's ok", "mix\"and'both", "" },
  }
  for _, argv in ipairs(samples) do
    local formatted = run_config.format_args(argv)
    local parsed, perr = run_config.split_args(formatted)
    assert(
      perr == nil and vim.deep_equal(parsed, argv),
      "roundtrip divergiu: " .. vim.inspect({ formatted, parsed, argv })
    )
  end
  assert(run_config.format_args({ "clean", "package" }) == "clean package", "args simples devem permanecer sem aspas")

  -- format_jc_args: só serializa quando parser por %s+ do jc reproduz fielmente
  assert(run_config.format_jc_args({ "clean", "package" }) == "clean package", "format_jc_args falhou em args simples")
  assert(
    run_config.format_jc_args({ "-Dmsg=hello world", "compile" }) == nil,
    "arg com espaço não é compatível com jc"
  )
  assert(run_config.format_jc_args({ '-Dx="quoted"' }) == nil, "arg com aspas não é compatível com jc")
  assert(run_config.format_jc_args({ "" }) == nil, "arg vazio não é compatível com jc")
  assert(run_config.format_jc_args({ "a\nb" }) == nil, "arg com newline não é compatível com jc")

  local jc_store = { ["build-last"] = "verify" }
  local jc_reads, jc_writes = 0, 0
  local prev_jc_settings = package.loaded["jc.settings"]
  package.loaded["jc.settings"] = {
    read_project = function(name)
      jc_reads = jc_reads + 1
      return jc_store[name]
    end,
    write_project = function(name, value)
      jc_writes = jc_writes + 1
      jc_store[name] = value
    end,
  }

  local root_q, main_q = fixtures.maven_project("run7d-quotes", "com.demo.q", "App")
  local q_capture = root_q .. "/quoted_args.txt"
  fixtures.write(root_q .. "/mvnw", {
    "#!/bin/sh",
    'printf "%s\\n" "$@" > ' .. vim.fn.shellescape(q_capture),
  })
  vim.fn.system({ "chmod", "+x", root_q .. "/mvnw" })

  open_file(main_q)
  notices = {}
  build.build()
  ask_script = { "-Dmsg=\"hello world\" --note='two  spaces' compile" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and vim.fn.filereadable(q_capture) == 1
    end),
    "choose_goal com aspas não concluiu"
  )
  local expected_lines = "-Dmsg=hello world\n--note=two  spaces\ncompile\n"
  assert(read_raw(q_capture) == expected_lines, "choose_goal inicial divergiu: " .. read_raw(q_capture))
  assert(jc_store["build-last"] == "verify", "jc build-last NÃO pode ser sobrescrito pelo Java Menu")
  assert(jc_reads == 0 and jc_writes == 0, "Java Menu Repeat não deve ler nem gravar jc.settings")

  -- Repeat in-session preserva argv exato
  vim.fn.delete(q_capture)
  build.build()
  assert(entry("repeat").enabled == true)
  menu_cb(entry("repeat"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and vim.fn.filereadable(q_capture) == 1
    end),
    "repeat in-session com aspas não concluiu"
  )
  assert(read_raw(q_capture) == expected_lines, "repeat in-session perdeu aspas: " .. read_raw(q_capture))

  -- Simula nova sessão (sem _last_builds em memória): repeat próprio ainda preserva argv exato sem depender de jc
  build._last_builds[run_config.canonical(root_q)] = nil
  vim.fn.delete(q_capture)
  build.build()
  assert(entry("repeat").enabled == true)
  menu_cb(entry("repeat"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and vim.fn.filereadable(q_capture) == 1
    end),
    "repeat persistido do java_menu com aspas não concluiu"
  )
  assert(
    read_raw(q_capture) == expected_lines,
    "repeat próprio perdeu aspas após limpar memória: " .. read_raw(q_capture)
  )

  -- Args simples sem aspas/espaços também usam apenas histórico próprio e preservam jc build-last intacto
  vim.fn.delete(q_capture)
  build.build()
  ask_script = { "clean package" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and vim.fn.filereadable(q_capture) == 1
    end),
    "choose_goal simples não concluiu"
  )
  assert(jc_store["build-last"] == "verify", "args simples do Java Menu não devem sobrescrever jc build-last")
  assert(jc_reads == 0 and jc_writes == 0, "args simples não devem ler nem gravar jc.settings")

  package.loaded["jc.settings"] = prev_jc_settings
end

-- ========== 11. Regression (4): Valores .env (inclusive curtos) não são persistidos/retidos, sem falso positivo no executável ==========

do
  local secret_val = "SuperEnvSecret!7766"
  local root_sec, main_sec = fixtures.maven_project("run7d-secret-args", "com.demo.sec", "App")
  fixtures.write(root_sec .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.demo</groupId>",
    "  <artifactId>sec</artifactId>",
    "  <version>1.0</version>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>org.springframework.boot</groupId>",
    "      <artifactId>spring-boot-starter</artifactId>",
    "    </dependency>",
    "  </dependencies>",
    "</project>",
  })
  fixtures.write(root_sec .. "/.env", {
    "MY_TOKEN=" .. secret_val,
    "SHORT_PIN=9",
    "SHORT_PW=ab",
    "EXE_WORD=java",
    "BIN_WORD=bin",
  })
  fixtures.write(root_sec .. "/mvnw", { "#!/bin/sh", 'echo "ok"' })
  vim.fn.system({ "chmod", "+x", root_sec .. "/mvnw" })

  -- Substrings curtas de .env também são protegidas (aceitando falsos positivos como --server.port=9091)
  local env_map = run_config.load_env(root_sec).env
  assert(
    run_config.overlaps_env("--server.port=9091", env_map),
    "--server.port=9091 contém substring '9' e deve ser protegido"
  )
  assert(run_config.overlaps_env("--pin=9", env_map), "--pin=9 deveria colidir com SHORT_PIN=9")
  assert(run_config.overlaps_env("-Dpw=xab12", env_map), "substring curta 'ab' deve ser protegida")
  assert(run_config.overlaps_env({ "-Dflag=ab12" }, env_map), "substring curta 'ab' em argv deve ser protegida")
  assert(run_config.overlaps_env("-Dapi.key=" .. secret_val, env_map), "valor secreto deveria colidir")

  -- Persistência direta via run_config.save recusa segredo (inclusive curto) e preserva config segura anterior
  assert(
    run_config.save(root_sec, { profile = "dev", jvm_args = "-Xmx512m", app_args = "--port=8080", use_env = true })
  )
  local ok_short_save, short_save_err =
    run_config.save(root_sec, { profile = "dev", jvm_args = "-Dpw=ab12", app_args = "", use_env = true })
  assert(not ok_short_save and short_save_err ~= nil, "run_config.save deveria recusar substring curta do .env")
  local ok_bad_save, bad_save_err =
    run_config.save(root_sec, { profile = "dev", jvm_args = "-Dkey=" .. secret_val, app_args = "", use_env = true })
  assert(not ok_bad_save and bad_save_err ~= nil, "run_config.save deveria recusar segredo do .env")
  local disk_after_refusal = read_raw(run_config.storage_path(root_sec))
  assert(not disk_after_refusal:find(secret_val, 1, true), "segredo vazou no disco após recusa!")
  assert(not disk_after_refusal:find("ab12", 1, true), "substring curta do .env vazou no disco após recusa!")
  assert(run_config.load(root_sec).jvm_args == "-Xmx512m", "config segura anterior deveria permanecer intacta")

  -- Run Main: executável/caminho (/.../bin/java) e -cp não são tratados como argumentos do usuário
  fixtures.write(main_sec, {
    "package com.demo.sec;",
    "",
    "public class App {",
    "  public static void main(String[] args) {}",
    "}",
  })
  local prev_get_clients_sec = vim.lsp.get_clients
  local prev_client_or_reason_sec = lsp.client_or_reason
  local sec_fake_vm = tempdir("sec-fake-jdk")
  local sec_fake_java = sec_fake_vm .. "/bin/java"
  fixtures.write(sec_fake_java, { "#!/bin/sh", 'echo "main ok"' })
  vim.fn.system({ "chmod", "+x", sec_fake_java })
  vim.lsp.get_clients = function(filter)
    if filter and filter.name == "jdtls" then
      return { { id = 100, name = "jdtls" } }
    end
    return prev_get_clients_sec(filter)
  end
  lsp.client_or_reason = function()
    return {
      request = function(_, _, params, cb)
        if params.command == "java.project.getClasspaths" then
          cb(nil, {
            classpaths = { root_sec .. "/target/classes" },
            projectRoot = vim.uri_from_fname(root_sec),
          })
        elseif params.command == "java.project.getSettings" then
          cb(nil, { ["org.eclipse.jdt.ls.core.vm.location"] = sec_fake_vm })
        end
      end,
    }
  end
  build._state.java = sec_fake_java
  open_file(main_sec)
  notices = {}
  local seq_before_main = build._state.seq
  build.build()
  pick_script = { "com.demo.sec.App" }
  ask_script = { "-Xmx512m", "--port=8080" }
  menu_cb(entry("run_main"))
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_before_main and not build._state.running and build._state.status == "success"
    end),
    "Run Main com EXE_WORD=java no .env não concluiu"
  )
  assert(not has_notice("overlap"), "executável java/path não deve disparar falso positivo de overlap com .env")
  assert(
    build._last_runs[run_config.canonical(root_sec)] ~= nil,
    "last_runs deve ser gravado quando apenas executável/path casa com valor curto do .env"
  )
  build._last_runs[run_config.canonical(root_sec)] = nil
  vim.lsp.get_clients = prev_get_clients_sec
  lsp.client_or_reason = prev_client_or_reason_sec

  -- Run Settings recusa editar jvm_args com valor do .env
  open_file(main_sec)
  notices = {}
  build.run_settings()
  ask_script = { "-Dtoken=" .. secret_val }
  menu_cb(entry("jvm_args"))
  assert(not any_notice_contains(secret_val), "notificação de Run Settings vazou segredo")
  assert(has_notice("overlap"), "Run Settings deveria avisar sobre sobreposição com .env")
  assert(run_config.load(root_sec).jvm_args == "-Xmx512m", "Run Settings não pode persistir segredo")

  -- Run Spring com segredo copiado em app_args: roda com redação, NÃO persiste nem grava em _last_runs
  local jc_sec_store = { ["build-last"] = "clean" }
  local prev_jc_settings = package.loaded["jc.settings"]
  package.loaded["jc.settings"] = {
    read_project = function(name)
      return jc_sec_store[name]
    end,
    write_project = function(name, value)
      jc_sec_store[name] = value
    end,
  }

  notices = {}
  build.build()
  ask_script = { "dev", "-Xmx256m", "--token=" .. secret_val }
  menu_cb(entry("run_spring"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running
    end),
    "run_spring com arg secreto não concluiu"
  )
  assert(not buf_text(build._state.buf):find(secret_val, 1, true), "segredo vazou no buffer")
  assert(not any_notice_contains(secret_val), "segredo vazou em notificações")
  assert(build._state.cmd == nil, "_state.cmd não deveria reter comando após término")
  assert(build._last_runs[run_config.canonical(root_sec)] == nil, "_last_runs não pode reter segredo para Restart")
  assert(
    not read_raw(run_config.storage_path(root_sec)):find(secret_val, 1, true),
    "segredo foi persistido após run_spring"
  )
  assert(has_notice("overlap"), "usuário deveria ser avisado quando args sobrepõem .env")

  -- Choose Goal com substring curta do .env: NÃO grava _last_builds, _last_runs ou jc build-last
  notices = {}
  build.build()
  ask_script = { "compile -Dpw=xab12" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running
    end),
    "choose_goal com substring curta do .env não concluiu"
  )
  assert(
    build._last_builds[run_config.canonical(root_sec)] == nil,
    "_last_builds não pode reter substring curta do .env"
  )
  assert(build._last_runs[run_config.canonical(root_sec)] == nil, "_last_runs não pode reter substring curta do .env")
  assert(jc_sec_store["build-last"] == "clean", "jc build-last não pode ser sobrescrito com substring curta!")
  assert(has_notice("overlap"), "usuário deveria ser avisado em choose_goal com substring curta")

  -- Choose Goal com segredo completo copiado em build args: NÃO grava _last_builds, _last_runs ou jc build-last
  notices = {}
  build.build()
  ask_script = { "compile -Dsecret=" .. secret_val }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running
    end),
    "choose_goal com arg secreto não concluiu"
  )
  assert(not buf_text(build._state.buf):find(secret_val, 1, true), "segredo vazou no buffer do choose_goal")
  assert(not any_notice_contains(secret_val), "segredo vazou em notificação do choose_goal")
  assert(build._last_builds[run_config.canonical(root_sec)] == nil, "_last_builds não pode reter segredo")
  assert(build._last_runs[run_config.canonical(root_sec)] == nil, "_last_runs não pode reter segredo")
  assert(jc_sec_store["build-last"] == "clean", "jc build-last não pode ser sobrescrito com segredo!")
  assert(has_notice("overlap"), "usuário deveria ser avisado em choose_goal com segredo")

  package.loaded["jc.settings"] = prev_jc_settings
end

-- ========== 12. Regression (5): PGID não verificado recusa Restart automático e reporta motivo ==========

do
  local p_bad, _, reason_zero = build._verify_own_pgid(0)
  assert(p_bad == nil and type(reason_zero) == "string" and reason_zero ~= "", "PID inválido deve retornar motivo")
  local p_self, _, reason_self = build._verify_own_pgid(vim.uv.os_getpid())
  assert(
    p_self == nil and type(reason_self) == "string" and reason_self:find("editor process group", 1, true),
    "PGID compartilhado com editor deve reportar motivo: " .. tostring(reason_self)
  )

  local root_pg, main_pg = fixtures.maven_project("run7d-unverified-pgid", "com.demo.pg", "App")
  fixtures.write(root_pg .. "/mvnw", { "#!/bin/sh", "exec sleep 30" })
  vim.fn.system({ "chmod", "+x", root_pg .. "/mvnw" })

  -- Registra comando prévio válido em last_runs
  open_file(main_pg)
  build.build()
  menu_cb(entry("compile"))
  assert(fixtures.wait_for(5000, function()
    return build._state.running
  end))
  build.stop(true)
  assert(fixtures.wait_for(5000, function()
    return not build._state.running
  end))

  -- Simula falha de verificação de PGID no próximo processo ativo
  local real_verify = build._verify_own_pgid
  build._verify_own_pgid = function()
    return nil, nil, "simulated shared PGID"
  end

  build.build()
  menu_cb(entry("compile"))
  assert(fixtures.wait_for(5000, function()
    return build._state.running
  end))
  local unverified_pid = build._state.pid
  local unverified_seq = build._state.seq
  assert(build._state.pgid == nil and build._state.pgid_reason == "simulated shared PGID")

  build.build()
  assert(entry("restart").enabled == false, "Restart no menu deve ficar desabilitado com PGID não verificado")
  assert(entry("restart").reason:find("simulated shared PGID", 1, true), "motivo no menu deve incluir causa do PGID")

  notices = {}
  build.restart()
  assert(
    build._state.running and build._state.seq == unverified_seq and pid_alive(unverified_pid),
    "Restart automático não pode parar nem sobrepor processo com PGID não verificado"
  )
  assert(not build._state.restarting, "estado restarting deve permanecer false")
  assert(has_notice("simulated shared PGID"), "Restart recusado deve reportar motivo do PGID")

  build._verify_own_pgid = real_verify
  build.stop(true)
  assert(fixtures.wait_for(5000, function()
    return not build._state.running
  end))
  assert(not pid_alive(unverified_pid), "stop manual deve conseguir encerrar processo mesmo sem PGID")
end

-- ========== 13. Regression (6): Saída ordinária com grupo em background não bloqueia indefinidamente ==========

do
  local root_bg, main_bg = fixtures.maven_project("run7d-bg-exit", "com.demo.bg", "App")
  local bg_pid_file = root_bg .. "/bg_child.pid"
  local bg_gate_file = root_bg .. "/bg_child.gate"
  fixtures.write(root_bg .. "/mvnw", {
    "#!/bin/sh",
    "sleep 30 &",
    "bpid=$!",
    'printf "%s" "$bpid" > ' .. vim.fn.shellescape(bg_pid_file),
    "while [ ! -f " .. vim.fn.shellescape(bg_gate_file) .. " ]; do sleep 0.02; done",
    "exit 0",
  })
  vim.fn.system({ "chmod", "+x", root_bg .. "/mvnw" })

  local orig_bg_grace = build._background_grace_ms
  build._background_grace_ms = 150

  open_file(main_bg)
  notices = {}
  build.build()
  menu_cb(entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return build._state.running and vim.fn.filereadable(bg_pid_file) == 1
    end),
    "processo líder deveria ter iniciado filho em background"
  )
  build.build()
  fixtures.write(bg_gate_file, { "go" })
  assert(
    fixtures.wait_for(5000, function()
      return not build._state.running and build._state.status == "success" and vim.fn.filereadable(bg_pid_file) == 1
    end),
    "processo líder deveria ter saído com sucesso"
  )
  local bg_pid = tonumber(read_raw(bg_pid_file))
  assert(bg_pid and pid_alive(bg_pid), "filho em background deveria estar vivo após saída do líder")

  -- Monitor libera o lock após _background_grace_ms sem matar o processo em background
  assert(
    fixtures.wait_for(3000, function()
      return not build._is_draining() and has_notice("surviving background group")
    end),
    "monitor deveria liberar bloqueio após saída ordinária com grupo sobrevivente"
  )
  assert(pid_alive(bg_pid), "saída ordinária com código 0 não deveria matar processo em background")

  -- Novo build não fica bloqueado!
  vim.fn.delete(bg_pid_file)
  fixtures.write(root_bg .. "/mvnw", { "#!/bin/sh", "exit 0" })
  vim.fn.system({ "chmod", "+x", root_bg .. "/mvnw" })
  local prev_seq = build._state.seq
  notices = {}
  build.build()
  menu_cb(entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return build._state.seq > prev_seq and not build._state.running and build._state.status == "success"
    end),
    "novo build não deveria ficar bloqueado após liberação de grupo em background"
  )
  assert(not has_notice("still exiting"), "não deveria bloquear com mensagem 'still exiting'")

  vim.fn.system({ "kill", "-KILL", tostring(bg_pid) })
  build._background_grace_ms = orig_bg_grace
end

-- ========== 14. Regression (7): Histórico de Repeat só é gravado após lançamento bem-sucedido ==========

do
  local jc_hist_store = { ["build-last"] = "jc-sentinel" }
  local jc_reads, jc_writes = 0, 0
  local prev_jc_settings = package.loaded["jc.settings"]
  package.loaded["jc.settings"] = {
    read_project = function(name)
      jc_reads = jc_reads + 1
      return jc_hist_store[name]
    end,
    write_project = function(name, value)
      jc_writes = jc_writes + 1
      jc_hist_store[name] = value
    end,
  }

  local root_h, main_h = fixtures.maven_project("run7d-hist-only-launched", "com.demo.h", "App")
  fixtures.write(root_h .. "/mvnw", { "#!/bin/sh", "exec sleep 30" })
  vim.fn.system({ "chmod", "+x", root_h .. "/mvnw" })

  local canon_h = run_config.canonical(root_h)
  open_file(main_h)

  -- 14a. Primeiro build válido grava histórico próprio sem ler/gravar jc.settings
  build.build()
  menu_cb(entry("compile"))
  assert(fixtures.wait_for(5000, function()
    return build._state.running
  end))
  assert(vim.deep_equal(build._last_builds[canon_h], { "compile" }), "compile lançado deveria gravar _last_builds")
  assert(jc_hist_store["build-last"] == "jc-sentinel", "compile lançado não pode sobrescrever jc build-last")
  assert(jc_reads == 0 and jc_writes == 0, "compile lançado não deve ler nem gravar jc.settings")
  assert(
    vim.deep_equal(run_config.load_last_build(canon_h), { "compile" }),
    "compile lançado deveria persistir last_build"
  )

  -- 14b. Tentativa rejeitada porque já há processo rodando NÃO altera histórico
  notices = {}
  build.build()
  ask_script = { "package" }
  menu_cb(entry("choose_goal"))
  assert(has_notice("already running"), "tentativa concorrente deveria ser rejeitada")
  assert(
    vim.deep_equal(build._last_builds[canon_h], { "compile" }),
    "tentativa rejeitada (running) não pode alterar _last_builds"
  )
  assert(jc_hist_store["build-last"] == "jc-sentinel", "tentativa rejeitada (running) não pode alterar jc build-last")
  assert(
    vim.deep_equal(run_config.load_last_build(canon_h), { "compile" }),
    "tentativa rejeitada (running) não pode alterar last_build em disco"
  )

  build.stop(true)
  assert(fixtures.wait_for(5000, function()
    return not build._state.running
  end))

  -- 14c. Falha em jobstart (job <= 0) NÃO altera histórico
  local real_jobstart = vim.fn.jobstart
  vim.fn.jobstart = function()
    return 0
  end
  notices = {}
  build.build()
  ask_script = { "verify" }
  menu_cb(entry("choose_goal"))
  vim.fn.jobstart = real_jobstart

  assert(has_notice("could not start"), "falha em jobstart deveria notificar erro")
  assert(vim.deep_equal(build._last_builds[canon_h], { "compile" }), "jobstart<=0 não pode alterar _last_builds")
  assert(jc_hist_store["build-last"] == "jc-sentinel", "jobstart<=0 não pode alterar jc build-last")
  assert(
    vim.deep_equal(run_config.load_last_build(canon_h), { "compile" }),
    "jobstart<=0 não pode alterar last_build em disco"
  )

  package.loaded["jc.settings"] = prev_jc_settings
end

-- ========== 15. Regression: Repeat usa histórico canônico próprio (sem jc.settings) ==========

do
  local project = require("java_menu.project")
  local prev_jc_settings = package.loaded["jc.settings"]
  local prev_cwd = vim.uv.cwd()

  local function make_gradle_stub(label, capture_file, explicit_root)
    local root = explicit_root or tempdir(label)
    fixtures.write(root .. "/settings.gradle", { "rootProject.name = '" .. label .. "'" })
    fixtures.write(root .. "/build.gradle", { "plugins { id 'java' }" })
    local lines = { "#!/bin/sh" }
    if capture_file then
      lines[#lines + 1] = 'printf "%s\\n" "$@" > ' .. vim.fn.shellescape(capture_file)
    end
    lines[#lines + 1] = "exit 0"
    fixtures.write(root .. "/gradlew", lines)
    vim.fn.system({ "chmod", "+x", root .. "/gradlew" })
    local main_file = root .. "/src/main/java/com/demo/" .. label .. "/App.java"
    fixtures.write(main_file, {
      "package com.demo." .. label .. ";",
      "public class App {}",
    })
    return root, main_file
  end

  local function jc_norm(path)
    return (path:gsub("[\\/:;.]", "_"))
  end

  -- 15a. Mock plano de jc.settings: histórico nunca é lido nem sobrescrito pelo Java Menu Repeat
  local flat_jc = { ["build-last"] = "external-sentinel" }
  local flat_reads, flat_writes = 0, 0
  package.loaded["jc.settings"] = {
    read_project = function(name)
      flat_reads = flat_reads + 1
      return flat_jc[name]
    end,
    write_project = function(name, value)
      flat_writes = flat_writes + 1
      flat_jc[name] = value
    end,
  }

  local root_a = tempdir("isoa")
  local capture_a = root_a .. "/capture_a.txt"
  local _, main_a = make_gradle_stub("isoa", capture_a, root_a)
  local root_b = tempdir("isob")
  local capture_b = root_b .. "/capture_b.txt"
  local _, main_b = make_gradle_stub("isob", capture_b, root_b)
  local canon_a = run_config.canonical(root_a)
  local canon_b = run_config.canonical(root_b)

  open_file(main_a)
  build.build()
  assert(entry("repeat").enabled == false, "Repeat no Projeto A não pode ler build-last externo do jc.settings")
  ask_script = { "compileJava" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "build no Projeto A não concluiu"
  )
  assert(flat_jc["build-last"] == "external-sentinel", "Projeto A não pode sobrescrever jc build-last")
  assert(flat_reads == 0 and flat_writes == 0, "Projeto A não deve ler nem gravar jc.settings")

  open_file(main_b)
  build.build()
  local repeat_b = entry("repeat")
  assert(repeat_b.enabled == false, "Repeat deveria estar desabilitado no Projeto B com mock plano de jc.settings")
  assert(repeat_b.reason:find("no previous build", 1, true), "motivo do Repeat no Projeto B divergiu")

  -- 15b. Históricos de mesmo valor entre projetos e entre sessões ficam estritamente isolados
  flat_jc["build-last"] = "compileJava" -- mesmo valor do último build de A
  build.build()
  assert(
    entry("repeat").enabled == false,
    "Repeat no Projeto B não pode habilitar quando jc.settings tem o mesmo valor do Projeto A"
  )

  ask_script = { "compileJava" } -- B executa exatamente o mesmo valor que A
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "build mesmo-valor no Projeto B não concluiu"
  )
  -- Agora B executa outro comando e simulamos nova sessão limpando _last_builds em memória
  ask_script = { "jar" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "segundo build no Projeto B não concluiu"
  )
  flat_jc["build-last"] = "clean"
  build._last_builds[canon_a] = nil
  build._last_builds[canon_b] = nil

  vim.fn.delete(capture_a)
  open_file(main_a)
  build.build()
  assert(entry("repeat").enabled == true, "Repeat do Projeto A deveria carregar do disco por raiz canônica")
  menu_cb(entry("repeat"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(capture_a) == 1
    end),
    "repeat cross-session no Projeto A não concluiu"
  )
  assert(read_raw(capture_a) == "compileJava\n", "Repeat de A deveria manter compileJava: " .. read_raw(capture_a))

  vim.fn.delete(capture_b)
  open_file(main_b)
  build.build()
  assert(entry("repeat").enabled == true, "Repeat do Projeto B deveria carregar do disco por raiz canônica")
  menu_cb(entry("repeat"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(capture_b) == 1
    end),
    "repeat cross-session no Projeto B não concluiu"
  )
  assert(read_raw(capture_b) == "jar\n", "Repeat de B deveria manter jar: " .. read_raw(capture_b))
  assert(flat_jc["build-last"] == "clean", "Repeat não pode tocar jc.settings")
  assert(flat_reads == 0 and flat_writes == 0, "históricos de mesmo valor não devem consultar jc.settings")

  -- 15c. Colisão de normalização de raiz no estilo jc.settings (foo.bar vs foo/bar -> mesmo prefixo normalizado)
  local collide_base = tempdir("collide")
  local root_dot = collide_base .. "/foo.bar"
  local capture_dot = root_dot .. "/capture_dot.txt"
  local _, main_dot = make_gradle_stub("dot", capture_dot, root_dot)
  local root_slash = collide_base .. "/foo/bar"
  local capture_slash = root_slash .. "/capture_slash.txt"
  local _, main_slash = make_gradle_stub("slash", capture_slash, root_slash)
  local canon_dot = run_config.canonical(root_dot)
  local canon_slash = run_config.canonical(root_slash)

  local shared_jc_key = jc_norm(canon_dot .. "/build.gradle")
  assert(
    shared_jc_key == jc_norm(canon_slash .. "/build.gradle"),
    "fixture de colisão deveria gerar mesma chave normalizada estilo jc.settings"
  )
  local collided_jc = { [shared_jc_key] = "jc-collided-sentinel" }
  local collided_reads, collided_writes = 0, 0
  local function current_collided_key()
    local cur_root = project.root(0)
    return cur_root and jc_norm(run_config.canonical(cur_root) .. "/build.gradle") or "cwd"
  end
  package.loaded["jc.settings"] = {
    read_project = function(_)
      collided_reads = collided_reads + 1
      return collided_jc[current_collided_key()]
    end,
    write_project = function(_, value)
      collided_writes = collided_writes + 1
      collided_jc[current_collided_key()] = value
    end,
  }

  open_file(main_dot)
  build.build()
  assert(entry("repeat").enabled == false, "foo.bar não pode ler entrada colidida do jc.settings")
  ask_script = { "compileJava" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "build em foo.bar não concluiu"
  )
  assert(collided_jc[shared_jc_key] == "jc-collided-sentinel", "foo.bar não pode sobrescrever slot colidido no jc")

  open_file(main_slash)
  build.build()
  assert(entry("repeat").enabled == false, "foo/bar não pode herdar histórico de foo.bar via chave normalizada")
  ask_script = { "jar" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "build em foo/bar não concluiu"
  )
  assert(collided_jc[shared_jc_key] == "jc-collided-sentinel", "foo/bar não pode sobrescrever slot colidido no jc")
  assert(collided_reads == 0 and collided_writes == 0, "colisão normalizada não deve acessar jc.settings")

  -- Cross-session (limpa memória): cada projeto preserva sua própria história canônica sem colisão
  build._last_builds[canon_dot] = nil
  build._last_builds[canon_slash] = nil
  vim.fn.delete(capture_dot)
  open_file(main_dot)
  build.build()
  menu_cb(entry("repeat"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(capture_dot) == 1
    end),
    "repeat de foo.bar após colisão não concluiu"
  )
  assert(read_raw(capture_dot) == "compileJava\n", "foo.bar divergiu após colisão: " .. read_raw(capture_dot))

  vim.fn.delete(capture_slash)
  open_file(main_slash)
  build.build()
  menu_cb(entry("repeat"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(capture_slash) == 1
    end),
    "repeat de foo/bar após colisão não concluiu"
  )
  assert(read_raw(capture_slash) == "jar\n", "foo/bar divergiu após colisão: " .. read_raw(capture_slash))

  -- 15d. Stub determinístico para contexto de output buffer e submódulo sem build.gradle na raiz
  local ctx_store = { ["build-last"] = "cwd-sentinel" }
  local ctx_reads, ctx_writes = 0, 0
  package.loaded["jc.settings"] = {
    read_project = function(name)
      ctx_reads = ctx_reads + 1
      return ctx_store[name]
    end,
    write_project = function(name, value)
      ctx_writes = ctx_writes + 1
      ctx_store[name] = value
    end,
  }

  local _, main_c = fixtures.maven_project("iso-outbuf", "com.demo.outbuf", "AppC")
  local root_c = project.root(vim.fn.bufnr(main_c, true))
  fixtures.write(root_c .. "/mvnw", { "#!/bin/sh", "exit 0" })
  vim.fn.system({ "chmod", "+x", root_c .. "/mvnw" })

  open_file(main_c)
  build.build() -- registra last_code_buf = AppC
  assert(entry("repeat").enabled == false, "AppC novo não deveria ter Repeat")
  assert(build._state.last_output and vim.api.nvim_buf_is_valid(build._state.last_output))
  vim.api.nvim_set_current_buf(build._state.last_output)

  build.build()
  assert(entry("repeat").enabled == false, "Repeat no output buffer não pode ler build-last do cwd")
  menu_cb(entry("compile"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "build disparado do output buffer não concluiu"
  )
  assert(ctx_store["build-last"] == "cwd-sentinel", "build no output buffer não pode alterar jc.settings")

  local root_sub = tempdir("iso-submod")
  local sub_capture = root_sub .. "/sub_capture.txt"
  fixtures.write(root_sub .. "/settings.gradle", {
    "rootProject.name = 'iso-submod'",
    "include(':services:api')",
  })
  fixtures.write(root_sub .. "/gradlew", {
    "#!/bin/sh",
    'printf "%s\\n" "$@" > ' .. vim.fn.shellescape(sub_capture),
  })
  vim.fn.system({ "chmod", "+x", root_sub .. "/gradlew" })
  fixtures.write(root_sub .. "/services/api/build.gradle", { "plugins { id 'java' }" })
  local sub_main = root_sub .. "/services/api/src/main/java/com/demo/sub/SubApp.java"
  fixtures.write(sub_main, { "package com.demo.sub;", "public class SubApp {}" })

  open_file(sub_main)
  local canon_sub = run_config.canonical(root_sub)
  assert(run_config.canonical(project.root(0)) == canon_sub, "raiz do projeto aninhado divergiu")
  build.build()
  assert(entry("repeat").enabled == false, "submódulo sem build prévio não pode habilitar Repeat")
  ask_script = { "help" }
  pick_script = { "services/api" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(sub_capture) == 1
    end),
    "build em projeto com submódulo não concluiu"
  )
  build._last_builds[canon_sub] = nil
  vim.fn.delete(sub_capture)
  build.build()
  assert(entry("repeat").enabled == true, "Repeat próprio por canon_root deveria estar habilitado após build")
  menu_cb(entry("repeat"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(sub_capture) == 1
    end),
    "repeat do submódulo não concluiu"
  )
  assert(read_raw(sub_capture) == ":services:api:help\n", "repeat do submódulo divergiu: " .. read_raw(sub_capture))
  assert(ctx_store["build-last"] == "cwd-sentinel", "submódulo não pode sobrescrever jc.settings")
  assert(ctx_reads == 0 and ctx_writes == 0, "output buffer e submódulo não devem acessar jc.settings")

  -- 15e. project_root#find ausente (E117) nunca permite leitura nem escrita inverificável no jc.settings
  local prev_rtp = vim.o.runtimepath
  for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
    if p:find("jc.nvim", 1, true) then
      vim.opt.rtp:remove(p)
    end
  end
  vim.cmd("silent! delfunction project_root#find")
  local ok_finder, finder_err = pcall(vim.fn["project_root#find"])
  assert(
    not ok_finder and tostring(finder_err):find("E117", 1, true),
    "fixture deveria simular E117 em project_root#find"
  )

  local missing_store = { ["build-last"] = "missing-sentinel" }
  local missing_reads, missing_writes = 0, 0
  package.loaded["jc.settings"] = {
    read_project = function(name)
      missing_reads = missing_reads + 1
      return missing_store[name]
    end,
    write_project = function(name, value)
      missing_writes = missing_writes + 1
      missing_store[name] = value
    end,
  }

  local root_miss = tempdir("iso-missing-finder")
  local miss_capture = root_miss .. "/miss_capture.txt"
  local _, main_miss = make_gradle_stub("miss", miss_capture, root_miss)
  local canon_miss = run_config.canonical(root_miss)
  open_file(main_miss)
  build.build()
  assert(entry("repeat").enabled == false, "com finder ausente, Repeat não pode ler jc.settings")
  ask_script = { "compileJava" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(miss_capture) == 1
    end),
    "build com finder ausente não concluiu"
  )
  assert(
    missing_store["build-last"] == "missing-sentinel",
    "com finder ausente, Java Menu não pode gravar jc.settings"
  )
  assert(
    missing_reads == 0 and missing_writes == 0,
    "com finder ausente, não deve haver leitura/escrita em jc.settings"
  )

  build._last_builds[canon_miss] = nil
  vim.fn.delete(miss_capture)
  build.build()
  assert(entry("repeat").enabled == true, "Repeat próprio deveria funcionar mesmo sem project_root#find")
  menu_cb(entry("repeat"))
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(miss_capture) == 1
    end),
    "repeat sem finder não concluiu"
  )
  assert(read_raw(miss_capture) == "compileJava\n", "repeat sem finder divergiu: " .. read_raw(miss_capture))

  vim.o.runtimepath = prev_rtp
  assert(vim.uv.cwd() == prev_cwd, "cwd global nunca pode ser alterado")
  package.loaded["jc.settings"] = prev_jc_settings
end

-- Distinct canonical paths must never share a persisted build record or run
-- settings file, even when legacy workspace_id encoding collides.
do
  local project = require("java_menu.project")
  local base = tempdir("percent-collision")
  local a, b = base .. "/a%/b", base .. "/a/%b"
  vim.fn.mkdir(a, "p")
  vim.fn.mkdir(b, "p")
  local canon_a = run_config.canonical(a)
  local canon_b = run_config.canonical(b)
  assert(project.workspace_id(a) == project.workspace_id(b))

  -- Build history isolation + forged owner check
  assert(run_config.last_build_path(a) ~= run_config.last_build_path(b))
  assert(run_config.save_last_build(a, { "alpha" }))
  assert(run_config.load_last_build(b) == nil)
  assert(run_config.save_last_build(b, { "beta" }))
  assert(vim.deep_equal(run_config.load_last_build(a), { "alpha" }))
  assert(vim.deep_equal(run_config.load_last_build(b), { "beta" }))
  vim.fn.writefile({ vim.json.encode({ root = canon_a, args = { "wrong" } }) }, run_config.last_build_path(b))
  assert(run_config.load_last_build(b) == nil, "a record owned by another root must be ignored")

  -- Legacy unowned settings file (keyed by colliding workspace_id) must never
  -- be imported or deleted by load/save/reset for either root.
  local legacy_path = vim.fs.joinpath(data_dir, project.workspace_id(canon_a) .. ".json")
  local legacy_content = vim.json.encode({
    version = 1,
    profile = "legacy-profile",
    jvm_args = "-Xmx3g",
    app_args = "--legacy",
    use_env = false,
  })
  vim.fn.writefile({ legacy_content }, legacy_path)
  assert(run_config.storage_path(a) ~= legacy_path)
  assert(run_config.storage_path(b) ~= legacy_path)
  assert(run_config.storage_path(a) ~= run_config.storage_path(b))

  local legacy_a, legacy_a_err = run_config.load(a)
  local legacy_b, legacy_b_err = run_config.load(b)
  assert(legacy_a_err == nil and legacy_a.profile == "" and legacy_a.jvm_args == "" and legacy_a.use_env == true)
  assert(legacy_b_err == nil and legacy_b.profile == "" and legacy_b.jvm_args == "" and legacy_b.use_env == true)
  assert(vim.fn.filereadable(legacy_path) == 1 and vim.trim(read_raw(legacy_path)) == legacy_content)

  -- Scoped save/load/reset isolation between colliding canonical roots
  assert(run_config.save(a, { profile = "dev", jvm_args = "-Xmx1g", app_args = "--alpha", use_env = true }))
  local saved_disk_a = vim.json.decode(read_raw(run_config.storage_path(a)))
  assert(saved_disk_a.version == 2 and saved_disk_a.root == canon_a)

  local unloaded_b, unloaded_b_err = run_config.load(b)
  assert(unloaded_b_err == nil and unloaded_b.profile == "" and unloaded_b.jvm_args == "")

  assert(run_config.save(b, { profile = "prod", jvm_args = "-Xmx2g", app_args = "--beta", use_env = false }))
  local cfg_a = run_config.load(a)
  local cfg_b = run_config.load(b)
  assert(
    cfg_a.profile == "dev" and cfg_a.jvm_args == "-Xmx1g" and cfg_a.app_args == "--alpha" and cfg_a.use_env == true
  )
  assert(
    cfg_b.profile == "prod" and cfg_b.jvm_args == "-Xmx2g" and cfg_b.app_args == "--beta" and cfg_b.use_env == false
  )
  assert(vim.fn.filereadable(legacy_path) == 1 and vim.trim(read_raw(legacy_path)) == legacy_content)

  -- Reset removes only the target root's scoped settings, leaving sibling and legacy intact
  assert(run_config.reset(a))
  local after_reset_a, reset_a_err = run_config.load(a)
  assert(reset_a_err == nil and after_reset_a.profile == "" and after_reset_a.jvm_args == "")
  assert(run_config.load(b).profile == "prod")
  assert(vim.fn.filereadable(legacy_path) == 1 and vim.trim(read_raw(legacy_path)) == legacy_content)

  -- Forged owner or unowned record at scoped storage_path must be rejected
  vim.fn.writefile({
    vim.json.encode({
      version = 2,
      root = canon_a,
      profile = "forged",
      jvm_args = "-Dforged=1",
      app_args = "--forged",
      use_env = false,
    }),
  }, run_config.storage_path(b))
  local forged_b, forged_b_err = run_config.load(b)
  assert(
    forged_b_err ~= nil
      and forged_b.profile == ""
      and forged_b.jvm_args == ""
      and forged_b.app_args == ""
      and forged_b.use_env == true,
    "run settings owned by another root must be ignored"
  )

  vim.fn.writefile({
    vim.json.encode({
      version = 1,
      profile = "unowned",
      jvm_args = "-Xmx512m",
      app_args = "--unowned",
      use_env = false,
    }),
  }, run_config.storage_path(b))
  local unowned_b, unowned_b_err = run_config.load(b)
  assert(
    unowned_b_err ~= nil
      and unowned_b.profile == ""
      and unowned_b.jvm_args == ""
      and unowned_b.app_args == ""
      and unowned_b.use_env == true,
    "unowned run settings without root metadata must be ignored"
  )

  assert(run_config.reset(b))
  assert(vim.fn.filereadable(legacy_path) == 1 and vim.trim(read_raw(legacy_path)) == legacy_content)
end

-- ========== 16. Issue #6: Overlapping, chunked, derived, short-value & limit tests ==========

do
  -- 16a. NUL byte em .env real no disco + UTF-8 BOM sem executar shell
  local nul_dir = tempdir("env-nul-bom")
  local pwn_marker = nul_dir .. "/should_not_exist.txt"
  local env_path = nul_dir .. "/.env"
  local fd = assert(vim.uv.fs_open(env_path, "w", 384))
  local raw_env = "\239\187\191VALID_KEY=SafeVal_123\n"
    .. "BAD_NUL=before\0secret_nul_after\n"
    .. "CMD_SUB=$(touch "
    .. pwn_marker
    .. ")\n"
  assert(vim.uv.fs_write(fd, raw_env, 0))
  vim.uv.fs_close(fd)

  local nul_res = run_config.load_env(nul_dir)
  assert(nul_res.exists == true)
  assert(vim.fn.filereadable(pwn_marker) == 0, ".env com BOM/NUL não pode executar comandos")
  assert(nul_res.env.VALID_KEY == "SafeVal_123", "UTF-8 BOM na linha 1 não deveria quebrar VALID_KEY")
  assert(nul_res.env.BAD_NUL == nil, "linha com byte NUL no disco deveria ser rejeitada")
  assert(#nul_res.warnings == 1, "deveria emitir exatamente 1 aviso para byte NUL: " .. vim.inspect(nul_res.warnings))
  assert(nul_res.warnings[1]:find("NUL byte", 1, true), "aviso de NUL divergiu: " .. nul_res.warnings[1])
  assert(not nul_res.warnings[1]:find("secret_nul_after", 1, true), "aviso de NUL vazou valor!")

  -- 16b. Segredos sobrepostos e auto-sobrepostos não vazam sufixos
  local overlap_reds = run_config.collect_redactions({
    LEFT = "ab_cd",
    RIGHT = "cd_secret_xyz",
    NUM_A = "12345",
    NUM_B = "45678",
    SELF = "ababa",
    ADJ_A = "foo",
    ADJ_B = "bar",
  })
  assert(run_config.redact("ab_cd_secret_xyz", overlap_reds) == "[REDACTED]", "sobreposição vazou sufixo")
  assert(run_config.redact("x=12345678!", overlap_reds) == "x=[REDACTED]!", "sobreposição numérica vazou sufixo")
  assert(run_config.redact("abababa", overlap_reds) == "[REDACTED]", "auto-sobreposição vazou sufixo")
  assert(
    run_config.redact("foobar", overlap_reds) == "[REDACTED][REDACTED]",
    "segredos adjacentes não-sobrepostos devem redigir ambos"
  )

  -- 16c. Variantes percent-encoded e JSON-escaped (>= 6 chars) vs valores curtos (< 6 chars)
  local derived_reds = run_config.collect_redactions({
    DB_PASS = "p@ss#1/a+b=c",
    JSON_PASS = 'sec"ret\\val',
    SHORT_SYM = "@",
  })
  local url_redacted = run_config.redact("url=p%40ss%231%2Fa%2Bb%3Dc lower=p%40ss%231%2fa%2bb%3dc", derived_reds)
  assert(
    url_redacted == "url=[REDACTED] lower=[REDACTED]",
    "URL percent-encoded deveria ser redigido: " .. url_redacted
  )
  local json_redacted = run_config.redact('{"pw":"sec\\"ret\\\\val"}', derived_reds)
  assert(json_redacted == '{"pw":"[REDACTED]"}', "JSON-escaped deveria ser redigido: " .. json_redacted)
  assert(
    run_config.redact("email%40example.com a@b", derived_reds) == "email%40example.com a[REDACTED]b",
    "valor curto (< 6) não deve gerar variantes %XX e causar falso positivo em %40"
  )

  -- 16d. Valor .env com espaço dividido entre tokens de argv (table)
  local space_env = { PHRASE = "hello world", SHORT = "42" }
  assert(run_config.overlaps_env({ "hello", "world" }, space_env), "table argv com frase dividida deve colidir")
  assert(
    run_config.overlaps_env({ "-Dmsg=hello", "world" }, space_env),
    "table argv com frase parcial+seguinte deve colidir"
  )
  local space_root = tempdir("space-env")
  fixtures.write(space_root .. "/.env", { 'PHRASE="hello world"' })
  local ok_space_build, space_err = run_config.save_last_build(space_root, { "hello", "world" })
  assert(not ok_space_build and space_err ~= nil, "save_last_build não pode persistir frase .env dividida em argv")

  -- 16e. Bufferização determinística por chunks (_feed / _finish): split lines, CRLF, EOF sem newline, seq stale
  local test_buf = vim.api.nvim_create_buf(false, true)
  build._state.seq = build._state.seq + 1
  local cur_seq = build._state.seq
  build._state.buf = test_buf
  build._state.running = true
  build._state.kind = "build"
  build._reset_streams()

  local chunk_reds = run_config.collect_redactions({
    TOK = "TopSecret_9988",
    OV_A = "left_mid",
    OV_B = "mid_right_secret",
  })
  -- Chunk 1 & 2: linha incompleta ainda não vai para o buffer
  build._feed(cur_seq, test_buf, "stdout", { "pre_Top" }, chunk_reds)
  build._feed(cur_seq, test_buf, "stdout", { "Secret_" }, chunk_reds)
  vim.wait(30, function()
    return false
  end)
  assert(buf_text(test_buf) == "", "chunk incompleto não deve vazar antes de newline/EOF: " .. buf_text(test_buf))
  assert(
    build._pending_text("stdout") == "pre_TopSecret_",
    "pending.stdout divergiu: " .. build._pending_text("stdout")
  )

  -- Chunk 3: completa a linha + inicia segunda linha com CRLF dividido + linha de sobreposição
  build._feed(cur_seq, test_buf, "stdout", { "9988_post", "crlf=TopSecret_9988\r" }, chunk_reds)
  build._feed(cur_seq, test_buf, "stdout", { "", "ov=left_mid_right_secret", "eof_tail=Top" }, chunk_reds)
  build._feed(cur_seq, test_buf, "stdout", { "Secret_9988" }, chunk_reds)
  -- Chunk stale de outra seq deve ser ignorado
  build._feed(cur_seq - 1, test_buf, "stdout", { "stale_TopSecret_9988", "" }, chunk_reds)

  assert(
    fixtures.wait_for(2000, function()
      return buf_text(test_buf):find("ov=[REDACTED]", 1, true) ~= nil
    end),
    "linhas completas de _feed não chegaram ao buffer: " .. buf_text(test_buf)
  )
  -- EOF sem newline: _finish deve descarregar e redigir pending.stdout
  build._finish(cur_seq, 0, chunk_reds)
  local fed_text = buf_text(test_buf)
  assert(fed_text:find("pre_[REDACTED]_post", 1, true), "segredo em 3 chunks não foi redigido: " .. fed_text)
  assert(fed_text:find("crlf=[REDACTED]\r", 1, true), "segredo com CRLF dividido não foi redigido: " .. fed_text)
  assert(fed_text:find("ov=[REDACTED]", 1, true), "sobreposição cross-chunk não foi redigida: " .. fed_text)
  assert(fed_text:find("eof_tail=[REDACTED]", 1, true), "cauda no EOF sem newline não foi redigida: " .. fed_text)
  assert(not fed_text:find("TopSecret_9988", 1, true), "segredo vazou no teste determinístico de chunks!")
  assert(not fed_text:find("right_secret", 1, true), "sufixo sobreposto vazou no teste de chunks!")
  assert(not fed_text:find("stale_", 1, true), "chunk de seq stale foi aplicado!")
  vim.api.nvim_buf_delete(test_buf, { force = true })

  -- 16f. Processo real (jobstart): chunks temporizados, EOF sem newline, URL/JSON, curto (falso positivo) e limites documentados
  local root_i6, main_i6 = fixtures.maven_project("run7d-issue6", "com.demo.i6", "App")
  local api_tok = "TopSecret/A+B=C#99"
  local json_sec = 'sec"ret\\val'
  fixtures.write(root_i6 .. "/.env", {
    "API_TOKEN=" .. api_tok,
    "OV_L=left_mid",
    "OV_R=mid_right_secret",
    "JSON_SEC=" .. json_sec,
    "CROSS_STREAM=cross1_cross2",
    "SHORT_CODE=42",
    "RUNNER_WORD=mvnw",
  })
  fixtures.write(root_i6 .. "/mvnw", {
    "#!/bin/sh",
    'printf "chunk="',
    "sleep 0.05",
    'printf "TopSecret/A+B"',
    "sleep 0.05",
    'printf "=C#99\\n"',
    'printf "overlap=left_mid_right_secret\\n"',
    'printf "url_u=TopSecret%%2FA%%2BB%%3DC%%2399 url_l=TopSecret%%2fA%%2bB%%3dC%%2399\\n"',
    "printf '%s\\n' 'json={\"k\":" .. vim.json.encode(json_sec) .. "}'",
    'printf "ordinary port 4200\\n"',
    'printf "split_nl_a=TopSecret/A+B\\nsplit_nl_b==C#99\\n"',
    'printf "cross_a=cross1_\\n"',
    'printf "cross_b=cross2\\n" >&2',
    'printf "eof_nolf=%s" "TopSecret/A+B=C#99"',
  })
  vim.fn.system({ "chmod", "+x", root_i6 .. "/mvnw" })

  open_file(main_i6)
  notices = {}
  local seq_i6 = build._state.seq
  build.build()
  ask_script = { "compile" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_i6 and not build._state.running and not build._is_draining()
    end),
    "build real do issue #6 não concluiu"
  )

  local out_i6 = buf_text(build._state.buf)
  assert(out_i6:find("chunk=[REDACTED]", 1, true), "chunk temporizado real não redigiu segredo: " .. out_i6)
  assert(out_i6:find("overlap=[REDACTED]", 1, true), "sobreposição real não redigiu completo: " .. out_i6)
  assert(out_i6:find("url_u=[REDACTED] url_l=[REDACTED]", 1, true), "URL-encoded real não redigiu: " .. out_i6)
  assert(out_i6:find('json={"k":"[REDACTED]"}', 1, true), "JSON-escaped real não redigiu: " .. out_i6)
  assert(out_i6:find("eof_nolf=[REDACTED]", 1, true), "EOF sem newline real não redigiu: " .. out_i6)
  assert(not out_i6:find(api_tok, 1, true), "API_TOKEN vazou no output real!")
  assert(not out_i6:find("right_secret", 1, true), "OV_R vazou no output real!")
  assert(not out_i6:find('sec\\"ret\\\\val', 1, true), "JSON_SEC vazou no output real!")

  -- Trade-off de valor curto: saída comum contendo '42' é redigida, mas 'compile' sem '42'/'mvnw' nos user_args persiste
  assert(
    out_i6:find("ordinary port [REDACTED]00", 1, true),
    "trade-off de falso positivo em saída com valor curto divergiu: " .. out_i6
  )
  assert(not has_notice("overlap"), "RUNNER_WORD=mvnw no .env não deve causar falso positivo em user_args={compile}")
  assert(
    vim.deep_equal(build._last_builds[run_config.canonical(root_i6)], { "compile" }),
    "compile limpo deveria ser gravado mesmo com RUNNER_WORD=mvnw no .env"
  )

  -- Trade-off de valor curto em argumentos do usuário: --port=4200 colide com SHORT_CODE=42 e não sobrescreve histórico
  notices = {}
  local seq_i6_fp = build._state.seq
  build.build()
  ask_script = { "compile -Dport=4200" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_i6_fp and not build._state.running and not build._is_draining()
    end),
    "choose_goal com falso positivo curto não concluiu"
  )
  assert(has_notice("overlap"), "SHORT_CODE=42 deveria sinalizar overlap em -Dport=4200")
  assert(
    vim.deep_equal(build._last_builds[run_config.canonical(root_i6)], { "compile" }),
    "histórico anterior não pode ser sobrescrito por arg com substring curta"
  )

  -- Limites inerentes documentados: fragmentos separados por '\n' ou entre stdout/stderr não são reconstruídos
  assert(
    out_i6:find("split_nl_a=TopSecret/A+B\nsplit_nl_b==C#99", 1, true),
    "comportamento esperado (limite): linhas separadas por \\n permanecem independentes"
  )
  assert(
    out_i6:find("cross_a=cross1_", 1, true) and out_i6:find("cross_b=cross2", 1, true),
    "comportamento esperado (limite): fluxos stdout/stderr permanecem independentes: " .. out_i6
  )
end

-- ========== 17. Issue #6 review fixes: parsed token join, mixed-case percent-encoding & span-arg state.cmd ==========

do
  -- 17a. overlaps_env em string deve checar junção de tokens parseados e forma bruta (save/load)
  local join_root = tempdir("issue6-token-join")
  fixtures.write(join_root .. "/.env", {
    'PHRASE="hello world"',
    'RAW_QUOTED="alpha" "beta"',
  })
  local join_env = run_config.load_env(join_root).env

  assert(
    run_config.overlaps_env('"hello" "world"', join_env),
    'overlaps_env(string) deve detectar junção de tokens parseados: "hello" "world"'
  )
  assert(
    run_config.overlaps_env('-Dmsg="hello" "world"', join_env),
    "overlaps_env(string) deve detectar junção com prefixo de flag"
  )
  assert(
    run_config.overlaps_env("hello   world", join_env),
    "overlaps_env(string) deve detectar múltiplos espaços normalizados pela junção de tokens"
  )
  assert(
    run_config.overlaps_env('"alpha" "beta"', join_env),
    "overlaps_env(string) deve continuar checando entrada bruta além dos tokens parseados"
  )
  assert(
    not run_config.overlaps_env('"HELLO" "world"', join_env),
    "overlaps_env deve manter comparação case-sensitive para tokens parseados"
  )

  -- save/load recusam/limpam strings como '"hello" "world"'
  assert(
    run_config.save(join_root, { profile = "dev", jvm_args = "-Xmx512m", app_args = "--port=8080", use_env = true })
  )
  local ok_join_save, join_save_err =
    run_config.save(join_root, { profile = "dev", jvm_args = '"hello" "world"', app_args = "", use_env = true })
  assert(not ok_join_save and join_save_err ~= nil, 'run_config.save deve recusar jvm_args=\'"hello" "world"\'')
  assert(
    not read_raw(run_config.storage_path(join_root)):find('"hello"', 1, true),
    "fragmento recusado não pode vazar para o disco"
  )
  assert(run_config.load(join_root).jvm_args == "-Xmx512m", "config segura anterior deve permanecer intacta")

  local canon_join = run_config.canonical(join_root)
  vim.fn.writefile({
    vim.json.encode({
      version = 2,
      root = canon_join,
      profile = "dev",
      jvm_args = '"hello" "world"',
      app_args = '--tag="alpha" "beta"',
      use_env = true,
    }),
  }, run_config.storage_path(join_root))
  local loaded_join, loaded_join_err = run_config.load(join_root)
  assert(loaded_join_err ~= nil, "run_config.load deve avisar ao limpar configurações com overlap por token join")
  assert(loaded_join.jvm_args == "", 'run_config.load deve limpar jvm_args=\'"hello" "world"\'')
  assert(loaded_join.app_args == "", "run_config.load deve limpar app_args com overlap em entrada bruta")
  assert(loaded_join.profile == "dev", "campo sem overlap deve ser preservado")

  -- 17b. Percent-encoding misto por escape (apenas dígitos hex case-insensitive; bytes ao redor case-sensitive)
  local pct_root = tempdir("issue6-mixed-pct")
  local many_special = string.rep("/+", 25) -- 50 chars especiais -> evitaria explosão 2^50
  fixtures.write(pct_root .. "/.env", {
    "MIXED_TOK=abc/+def",
    "LIT_PCT=ab%2Fcd",
    "SHORT_PCT=a/+b",
    "MANY_PCT=" .. many_special,
  })
  local pct_env = run_config.load_env(pct_root).env
  local pct_reds = run_config.collect_redactions(pct_env)
  assert(#pct_reds <= 16, "collect_redactions não pode gerar explosão combinatória: " .. tostring(#pct_reds))

  local mixed_out =
    run_config.redact("m1=abc%2F%2bdef m2=abc%2f%2Bdef u=ABC%2F%2bDEF p=abc%2F%2bDEF lit=ab%2fcd sh=a%2F%2bb", pct_reds)
  assert(
    mixed_out == "m1=[REDACTED] m2=[REDACTED] u=ABC%2F%2bDEF p=abc%2F%2bDEF lit=ab%2fcd sh=a%2F%2bb",
    "redação mixed-case percent-encoded divergiu: " .. mixed_out
  )

  local many_mixed = many_special:gsub("/%+", "%%2F%%2b")
  assert(
    run_config.redact("big=" .. many_mixed .. "!", pct_reds) == "big=[REDACTED]!",
    "redação não-combinatória deveria casar sequência longa com hex misto"
  )

  -- Limites documentados: partial percent-encoding não casa
  assert(
    run_config.redact("part=abc/%2bdef unres=%61bc%2F%2bdef", pct_reds) == "part=abc/%2bdef unres=%61bc%2F%2bdef",
    "limite documentado: encoding parcial não deve casar"
  )

  -- Histórico / overlaps_env / save / load / last_build com hex misto e bytes ao redor case-sensitive
  assert(run_config.overlaps_env("abc%2F%2bdef", pct_env), "overlaps_env(string) deve detectar hex misto %2F%2b")
  assert(run_config.overlaps_env("abc%2f%2Bdef", pct_env), "overlaps_env(string) deve detectar hex misto %2f%2B")
  assert(
    run_config.overlaps_env({ "compile", "-Durl=https://x/abc%2F%2bdef" }, pct_env),
    "overlaps_env(table) deve detectar hex misto"
  )
  assert(
    not run_config.overlaps_env("ABC%2F%2bDEF", pct_env),
    "bytes planos ao redor devem permanecer case-sensitive em overlaps_env"
  )
  assert(
    not run_config.overlaps_env("ab%2fcd", pct_env),
    "valor literal ab%2Fcd no .env não deve tornar %2F case-insensitive fora de escapes derivados"
  )

  local ok_pct_save, pct_save_err =
    run_config.save(pct_root, { profile = "", jvm_args = "-Dcb=abc%2F%2bdef", app_args = "", use_env = true })
  assert(not ok_pct_save and pct_save_err ~= nil, "run_config.save deve recusar escape percent-encoded misto")
  local ok_pct_build, pct_build_err = run_config.save_last_build(pct_root, { "compile", "-Dcb=abc%2f%2Bdef" })
  assert(not ok_pct_build and pct_build_err ~= nil, "save_last_build deve recusar escape percent-encoded misto")

  local canon_pct = run_config.canonical(pct_root)
  vim.fn.writefile({
    vim.json.encode({
      version = 2,
      root = canon_pct,
      profile = "",
      jvm_args = "",
      app_args = "--cb=abc%2F%2bdef",
      use_env = true,
    }),
  }, run_config.storage_path(pct_root))
  local loaded_pct, loaded_pct_err = run_config.load(pct_root)
  assert(loaded_pct_err ~= nil and loaded_pct.app_args == "", "run_config.load deve limpar hex misto persistido")

  vim.fn.writefile({
    vim.json.encode({ version = 2, root = canon_pct, args = { "compile", "-Dcb=abc%2f%2Bdef" } }),
  }, run_config.last_build_path(pct_root))
  local loaded_pct_build, loaded_pct_build_err = run_config.load_last_build(pct_root)
  assert(
    loaded_pct_build == nil and loaded_pct_build_err ~= nil,
    "load_last_build deve ignorar histórico persistido com hex misto"
  )

  -- 17c. Processo real com segredo dividido entre args: state.cmd nunca retém fragmentos reconstruíveis
  local span_root, span_main = fixtures.maven_project("run7d-span-cmd", "com.demo.span", "App")
  local span_canon = run_config.canonical(span_root)
  local span_capture = span_root .. "/span_args.txt"
  local span_ready = span_root .. "/span_ready.txt"
  fixtures.write(span_root .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.demo</groupId>",
    "  <artifactId>span</artifactId>",
    "  <version>1.0</version>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>org.springframework.boot</groupId>",
    "      <artifactId>spring-boot-starter</artifactId>",
    "    </dependency>",
    "  </dependencies>",
    "</project>",
  })
  fixtures.write(span_root .. "/.env", {
    'SPAN_SECRET="fragAlpha fragBeta"',
    "MIXED_TOK=abc/+def",
  })
  fixtures.write(span_root .. "/mvnw", {
    "#!/bin/sh",
    'printf "%s\\n" "$@" > ' .. vim.fn.shellescape(span_capture),
    'printf "ready\\n" > ' .. vim.fn.shellescape(span_ready),
    'printf "out_mix=abc%%2F%%2bdef\\n"',
    "exec sleep 30",
  })
  vim.fn.system({ "chmod", "+x", span_root .. "/mvnw" })

  open_file(span_main)
  notices = {}
  local seq_span = build._state.seq
  build.build()
  ask_script = { "compile fragAlpha fragBeta -Dcb=abc%2F%2bdef" }
  menu_cb(entry("choose_goal"))

  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_span
        and build._state.running
        and vim.fn.filereadable(span_ready) == 1
        and buf_text(build._state.buf):find("out_mix=[REDACTED]", 1, true) ~= nil
    end),
    "processo real com segredo entre args não iniciou ou não redigiu saída"
  )

  -- Enquanto o processo real está em execução, state.cmd não pode reter fragmentos crus (fragAlpha / fragBeta / abc%2F%2bdef)
  assert(type(build._state.cmd) == "table", "state.cmd deve existir enquanto processo roda")
  local active_cmd_str = table.concat(build._state.cmd, " ")
  assert(not active_cmd_str:find("fragAlpha", 1, true), "state.cmd vazou fragAlpha em execução: " .. active_cmd_str)
  assert(not active_cmd_str:find("fragBeta", 1, true), "state.cmd vazou fragBeta em execução: " .. active_cmd_str)
  assert(
    not active_cmd_str:find("abc%2F%2bdef", 1, true),
    "state.cmd vazou hex misto em execução: " .. active_cmd_str
  )
  assert(
    vim.deep_equal(build._state.cmd, { span_root .. "/mvnw", "[REDACTED]" }),
    "state.cmd deveria redigir metadados inteiros do comando: " .. vim.inspect(build._state.cmd)
  )

  local span_buf_text = buf_text(build._state.buf)
  assert(not span_buf_text:find("fragAlpha", 1, true), "buffer vazou fragAlpha!")
  assert(not span_buf_text:find("fragBeta", 1, true), "buffer vazou fragBeta!")
  assert(not span_buf_text:find("abc%2F%2bdef", 1, true), "buffer vazou hex misto!")
  assert(not any_notice_contains("fragAlpha"), "notificação vazou fragAlpha!")
  assert(not any_notice_contains("fragBeta"), "notificação vazou fragBeta!")
  assert(not any_notice_contains("abc%2F%2bdef"), "notificação vazou hex misto!")
  assert(has_notice("overlap"), "usuário deve ser avisado do overlap")

  -- Processo real ainda recebeu os argumentos reais intactos
  local span_received = read_raw(span_capture)
  assert(
    span_received == "compile\nfragAlpha\nfragBeta\n-Dcb=abc%2F%2bdef\n",
    "processo real não recebeu argumentos esperados: " .. span_received
  )

  build.stop(true)
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "stop do processo com segredo entre args não concluiu"
  )
  assert(build._state.cmd == nil, "state.cmd deve ser limpo após saída")
  assert(build._last_builds[span_canon] == nil, "_last_builds não pode registrar comando com segredo entre args")
  assert(build._last_runs[span_canon] == nil, "_last_runs não pode registrar comando com segredo entre args")
  assert(run_config.load_last_build(span_canon) == nil, "last_build em disco não pode ser salvo")

  -- Também verifica run_spring com segredo espalhado entre jvm_args ('"fragAlpha"') e app_args ('"fragBeta"')
  vim.fn.delete(span_ready)
  vim.fn.delete(span_capture)
  notices = {}
  local seq_spring_span = build._state.seq
  build.build()
  ask_script = { "", '"fragAlpha"', '"fragBeta"' }
  menu_cb(entry("run_spring"))
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_spring_span and build._state.running and vim.fn.filereadable(span_ready) == 1
    end),
    "run_spring com segredo entre campos não iniciou"
  )
  local spring_cmd_str = table.concat(build._state.cmd, " ")
  assert(not spring_cmd_str:find("fragAlpha", 1, true), "run_spring state.cmd vazou fragAlpha: " .. spring_cmd_str)
  assert(not spring_cmd_str:find("fragBeta", 1, true), "run_spring state.cmd vazou fragBeta: " .. spring_cmd_str)
  assert(not buf_text(build._state.buf):find("fragAlpha", 1, true), "run_spring buffer vazou fragAlpha!")
  assert(not buf_text(build._state.buf):find("fragBeta", 1, true), "run_spring buffer vazou fragBeta!")
  assert(not any_notice_contains("fragAlpha"), "run_spring notificação vazou fragAlpha!")
  assert(not any_notice_contains("fragBeta"), "run_spring notificação vazou fragBeta!")
  assert(build._last_runs[span_canon] == nil, "run_spring com segredo entre campos não pode gravar _last_runs")

  build.stop(true)
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "stop do run_spring com segredo entre campos não concluiu"
  )
end

-- ========== 18. Issue #6 re-review: split cfg save/load & bounded long-line stream policy ==========

do
  -- 18a. cfg save/load: segredos .env divididos entre profile, jvm_args e app_args (argv parseado + bruto)
  local split_root, split_main = fixtures.maven_project("run7d-cfg-split", "com.demo.csplit", "App")
  local split_canon = run_config.canonical(split_root)
  fixtures.write(split_root .. "/pom.xml", {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.demo</groupId>",
    "  <artifactId>csplit</artifactId>",
    "  <version>1.0</version>",
    "  <dependencies>",
    "    <dependency>",
    "      <groupId>org.springframework.boot</groupId>",
    "      <artifactId>spring-boot-starter</artifactId>",
    "    </dependency>",
    "  </dependencies>",
    "</project>",
  })
  fixtures.write(split_root .. "/.env", {
    'SPAN_SECRET="fragAlpha fragBeta"',
    'TRI_SECRET="triOne triTwo triThree"',
    'RAW_QUOTED="rawA" "rawB"',
    "TIGHT_SECRET=TightLeftTightRight",
  })
  local split_ready = split_root .. "/split_ready.txt"
  fixtures.write(split_root .. "/mvnw", {
    "#!/bin/sh",
    'printf "ready\\n" > ' .. vim.fn.shellescape(split_ready),
    "exec sleep 30",
  })
  vim.fn.system({ "chmod", "+x", split_root .. "/mvnw" })

  -- Salva baseline seguro no disco
  assert(
    run_config.save(split_root, { profile = "dev", jvm_args = "-Xmx512m", app_args = "--port=8080", use_env = true })
  )
  local cfg_path = run_config.storage_path(split_root)

  local rejected_cases = {
    {
      name = "jvm_args + app_args parsed argv",
      cfg = { profile = "dev", jvm_args = '"fragAlpha"', app_args = '"fragBeta"', use_env = true },
      leaks = { "fragAlpha", "fragBeta" },
    },
    {
      name = "profile + jvm_args parsed argv",
      cfg = { profile = "fragAlpha", jvm_args = '"fragBeta"', app_args = "--port=8080", use_env = true },
      leaks = { "fragAlpha", "fragBeta" },
    },
    {
      name = "profile + app_args parsed argv with unrelated jvm_args",
      cfg = { profile = "fragAlpha", jvm_args = "-Xmx512m", app_args = '"fragBeta"', use_env = true },
      leaks = { "fragAlpha", "fragBeta" },
    },
    {
      name = "all three fields parsed argv",
      cfg = { profile = "triOne", jvm_args = '"triTwo"', app_args = '"triThree"', use_env = true },
      leaks = { "triOne", "triTwo", "triThree" },
    },
    {
      name = "raw quoted across fields",
      cfg = { profile = "dev", jvm_args = '"rawA"', app_args = '"rawB"', use_env = true },
      leaks = { "rawA", "rawB" },
    },
    {
      name = "tight concat across fields",
      cfg = { profile = "dev", jvm_args = '"TightLeft"', app_args = '"TightRight"', use_env = true },
      leaks = { "TightLeft", "TightRight" },
    },
  }

  for _, tc in ipairs(rejected_cases) do
    local ok_s, err_s = run_config.save(split_root, tc.cfg)
    assert(not ok_s and type(err_s) == "string" and err_s ~= "", "save deveria recusar: " .. tc.name)
    local disk = read_raw(cfg_path)
    for _, leak in ipairs(tc.leaks) do
      assert(not err_s:find(leak, 1, true), "erro de save vazou " .. leak .. " em " .. tc.name)
      assert(not disk:find(leak, 1, true), "disco vazou " .. leak .. " após recusa de " .. tc.name)
    end
    local intact = run_config.load(split_root)
    assert(
      intact.profile == "dev" and intact.jvm_args == "-Xmx512m" and intact.app_args == "--port=8080",
      "config segura anterior foi alterada após recusa: " .. tc.name
    )
  end

  -- load: limpa apenas os campos afetados preservando campos não envolvidos, sem vazar valores
  local load_cases = {
    {
      name = "load clears jvm+app preserving profile",
      disk = { profile = "dev", jvm_args = '-Dmsg="fragAlpha"', app_args = '"fragBeta"', use_env = true },
      expect = { profile = "dev", jvm_args = "", app_args = "" },
      leaks = { "fragAlpha", "fragBeta" },
    },
    {
      name = "load clears profile+jvm preserving app",
      disk = { profile = '"fragAlpha"', jvm_args = '"fragBeta"', app_args = "--port=8080", use_env = false },
      expect = { profile = "", jvm_args = "", app_args = "--port=8080" },
      leaks = { "fragAlpha", "fragBeta" },
    },
    {
      name = "load clears profile+app preserving jvm",
      disk = { profile = "fragAlpha", jvm_args = "-Xmx512m", app_args = '"fragBeta"', use_env = true },
      expect = { profile = "", jvm_args = "-Xmx512m", app_args = "" },
      leaks = { "fragAlpha", "fragBeta" },
    },
    {
      name = "load clears all 3 when all required",
      disk = { profile = "triOne", jvm_args = '"triTwo"', app_args = '"triThree"', use_env = true },
      expect = { profile = "", jvm_args = "", app_args = "" },
      leaks = { "triOne", "triTwo", "triThree" },
    },
    {
      name = "load clears raw quoted across jvm+app",
      disk = { profile = "dev", jvm_args = '"rawA"', app_args = '"rawB"', use_env = true },
      expect = { profile = "dev", jvm_args = "", app_args = "" },
      leaks = { "rawA", "rawB" },
    },
    {
      name = "load clears tampered unclosed quote split across jvm+app",
      disk = { profile = "dev", jvm_args = '-Dx="fragAlpha', app_args = 'fragBeta"', use_env = true },
      expect = { profile = "dev", jvm_args = "", app_args = "" },
      leaks = { "fragAlpha", "fragBeta" },
    },
  }

  for _, tc in ipairs(load_cases) do
    vim.fn.writefile({
      vim.json.encode({
        version = 2,
        root = split_canon,
        profile = tc.disk.profile,
        jvm_args = tc.disk.jvm_args,
        app_args = tc.disk.app_args,
        use_env = tc.disk.use_env,
      }),
    }, cfg_path)
    local loaded, load_err = run_config.load(split_root)
    assert(type(load_err) == "string" and load_err ~= "", "load deveria avisar em: " .. tc.name)
    for _, leak in ipairs(tc.leaks) do
      assert(not load_err:find(leak, 1, true), "aviso de load vazou " .. leak .. " em " .. tc.name)
    end
    assert(loaded.profile == tc.expect.profile, tc.name .. " profile divergiu: " .. loaded.profile)
    assert(loaded.jvm_args == tc.expect.jvm_args, tc.name .. " jvm_args divergiu: " .. loaded.jvm_args)
    assert(loaded.app_args == tc.expect.app_args, tc.name .. " app_args divergiu: " .. loaded.app_args)
    assert(loaded.use_env == tc.disk.use_env, tc.name .. " use_env não deveria ser alterado")
  end

  -- Fluxo real run_spring com segredo dividido entre profile e app_args (com jvm_args no meio):
  -- não persiste em disco, mantém config segura anterior, e não grava last_runs/state.cmd
  assert(
    run_config.save(split_root, { profile = "dev", jvm_args = "-Xmx512m", app_args = "--port=8080", use_env = true })
  )
  open_file(split_main)
  notices = {}
  local seq_sp = build._state.seq
  build.build()
  ask_script = { "fragAlpha", "-Xmx256m", '"fragBeta"' }
  menu_cb(entry("run_spring"))
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_sp and build._state.running and vim.fn.filereadable(split_ready) == 1
    end),
    "run_spring com segredo split profile+app não iniciou"
  )
  local active_sp_cmd = table.concat(build._state.cmd, " ")
  assert(not active_sp_cmd:find("fragAlpha", 1, true), "state.cmd vazou fragAlpha: " .. active_sp_cmd)
  assert(not active_sp_cmd:find("fragBeta", 1, true), "state.cmd vazou fragBeta: " .. active_sp_cmd)
  assert(not buf_text(build._state.buf):find("fragAlpha", 1, true), "buffer vazou fragAlpha")
  assert(not buf_text(build._state.buf):find("fragBeta", 1, true), "buffer vazou fragBeta")
  assert(not any_notice_contains("fragAlpha") and not any_notice_contains("fragBeta"), "notice vazou segredo split")
  assert(has_notice("overlap"), "usuário deve ser avisado do overlap entre campos")
  assert(build._last_runs[split_canon] == nil, "_last_runs não pode registrar run_spring com segredo split")
  local persisted_sp = run_config.load(split_root)
  assert(
    persisted_sp.profile == "dev" and persisted_sp.jvm_args == "-Xmx512m" and persisted_sp.app_args == "--port=8080",
    "run_spring com segredo split sobrescreveu config segura em disco"
  )
  build.stop(true)
  assert(fixtures.wait_for(10000, function()
    return not build._state.running and not build._is_draining()
  end))

  -- 18b. Unitário: redact_prefix e política limitada de linha longa (>1MiB sem newline, segredo na fronteira, EOF, streams/seq)
  local b_reds = run_config.collect_redactions({
    TOK = "BoundarySecret_9988",
    ENC = "p@ss/1+2",
    OV_A = "left_mid",
    OV_B = "mid_right_secret",
  })

  -- Secret straddling prefix_len = 16
  local rp_cross = run_config.redact_prefix("0123456789BoundarySecret_9988zzzz", b_reds, 16)
  assert(rp_cross == "0123456789[REDACTED]", "redact_prefix vazou fragmento na fronteira: " .. rp_cross)
  -- Secret starting right at prefix_len = 11
  local rp_at = run_config.redact_prefix("0123456789BoundarySecret_9988zzzz", b_reds, 11)
  assert(rp_at == "0123456789[REDACTED]", "redact_prefix vazou primeiro byte no limite: " .. rp_at)
  -- Secret starting AFTER prefix_len = 10
  local rp_after = run_config.redact_prefix("0123456789BoundarySecret_9988zzzz", b_reds, 10)
  assert(rp_after == "0123456789", "redact_prefix não deveria emitir bytes após limite: " .. rp_after)
  -- Mixed-case percent-encoded secret straddling prefix_len = 16
  local rp_pct = run_config.redact_prefix("0123456789p%40ss%2f1%2B2zzzz", b_reds, 16)
  assert(rp_pct == "0123456789[REDACTED]", "redact_prefix vazou %XX misto na fronteira: " .. rp_pct)
  -- Overlapping secrets straddling prefix_len = 15
  local rp_ov = run_config.redact_prefix("0123456789left_mid_right_secretzzzz", b_reds, 15)
  assert(rp_ov == "0123456789[REDACTED]", "redact_prefix vazou sobreposição na fronteira: " .. rp_ov)

  -- Simulação determinística com limite pequeno (32 bytes) + >1MiB sem newline e segredo na fronteira
  local orig_limit = build._max_line_bytes
  local orig_look = build._max_lookahead_bytes
  build._max_line_bytes = 32
  build._max_lookahead_bytes = 64

  local long_buf = vim.api.nvim_create_buf(false, true)
  build._state.seq = build._state.seq + 1
  local lseq = build._state.seq
  build._state.buf = long_buf
  build._state.running = true
  build._state.kind = "build"
  build._reset_streams()
  notices = {}

  -- Segredo BoundarySecret_9988 começa no byte 25 e termina no byte 43 (cruzando limite 32!)
  build._feed(lseq, long_buf, "stdout", { ("a"):rep(24) .. "Boundary" }, b_reds)
  assert(buf_text(long_buf) == "", "chunk exatamente no limite 32 com lookahead não pode vazar fragmento!")
  build._feed(lseq, long_buf, "stdout", { "Secret_9988" .. ("b"):rep(100) }, b_reds)
  -- Alimenta > 1 MiB adicional sem newline (em chunks de 64 KiB)
  local big_chunk = ("x"):rep(65536)
  for _ = 1, 17 do
    build._feed(lseq, long_buf, "stdout", { big_chunk }, b_reds)
  end
  assert(
    #build._pending_text("stdout") == 0 and build._pending.stdout.dropping == true,
    "pending.stdout deve permanecer limitado em memória durante supressão"
  )
  assert(build._pending.stdout.dropped_bytes > 1048576, "dropped_bytes deveria contabilizar >1MiB suprimido")

  -- Stream stderr independente continua funcionando normalmente enquanto stdout suprime
  build._feed(lseq, long_buf, "stderr", { "err=BoundarySecret_9988", "" }, b_reds)
  -- Entradas inválidas / stale seq são ignoradas sem erro
  build._feed(lseq, long_buf, "invalid_stream", { "BoundarySecret_9988", "" }, b_reds)
  build._feed(lseq, long_buf, "stdout", "not-a-table", b_reds)
  build._feed(lseq - 1, long_buf, "stdout", { "stale_BoundarySecret_9988", "" }, b_reds)

  -- Newline encerra supressão de stdout e permite próxima linha normal + teste síncrono feed+finish
  build._feed(lseq, long_buf, "stdout", { "tail_dropped", "after=p%40ss%2f1%2B2", "eof_tok=Boundary" }, b_reds)
  build._feed(lseq, long_buf, "stdout", { "Secret_9988" }, b_reds)
  -- Sem wait_for antes de _finish: _finish deve drenar fila pendente em ordem antes do EOF e banner
  build._finish(lseq, 0, b_reds)
  -- Chamada duplicada de _finish após running=false deve ser ignorada
  build._finish(lseq, 1, b_reds)
  -- _feed tardio após _finish (running=false) deve ser ignorado
  build._feed(lseq, long_buf, "stdout", { "late_after_finish", "" }, b_reds)

  local unit_out = buf_text(long_buf)
  assert(
    unit_out:find(("a"):rep(24) .. "%[REDACTED%] %.%.%. %[line truncated at 32 bytes; remainder suppressed%]"),
    "linha truncada na fronteira divergiu: " .. unit_out
  )
  assert(not unit_out:find("Boundary", 1, true), "prefixo Boundary vazou no unitário!")
  assert(not unit_out:find("Secret_9988", 1, true), "sufixo Secret_9988 vazou no unitário!")
  assert(not unit_out:find("bbbb", 1, true) and not unit_out:find("xxxx", 1, true), "resto suprimido vazou no buffer!")
  assert(unit_out:find("err=[REDACTED]", 1, true), "stderr independente não recebeu/redigiu linha: " .. unit_out)
  assert(unit_out:find("after=[REDACTED]", 1, true), "linha pós-newline não recuperou após supressão: " .. unit_out)
  assert(unit_out:find("eof_tok=[REDACTED]", 1, true), "EOF sem newline pós-supressão falhou: " .. unit_out)
  assert(not unit_out:find("stale_", 1, true), "chunk stale vazou!")
  assert(not unit_out:find("late_after_finish", 1, true), "chunk após finish vazou!")
  local _, exit_count = unit_out:gsub("%[build%] exit ", "")
  assert(exit_count == 1, "finish duplicado emitiu múltiplos banners de exit: " .. tostring(exit_count))
  assert(has_notice("line exceeded 32 bytes"), "notificação clara de truncamento ausente")
  local trunc_notices = 0
  for _, n in ipairs(notices) do
    if n.msg:find("line exceeded", 1, true) then
      trunc_notices = trunc_notices + 1
    end
  end
  assert(trunc_notices == 1, "notificação de truncamento não pode spammar: " .. tostring(trunc_notices))
  vim.api.nvim_buf_delete(long_buf, { force = true })

  -- EOF dentro da janela de lookahead (limit < len < trigger_len)
  local eof_buf = vim.api.nvim_create_buf(false, true)
  build._state.seq = build._state.seq + 1
  local eseq = build._state.seq
  build._state.buf = eof_buf
  build._state.running = true
  build._state.kind = "build"
  build._reset_streams()
  notices = {}
  -- len = 24 + 19 = 43 (> 32, < 32 + 18 = 50)
  build._feed(eseq, eof_buf, "stdout", { ("a"):rep(24) .. "BoundarySecret_9988" }, b_reds)
  build._finish(eseq, 0, b_reds)
  local eof_out = buf_text(eof_buf)
  assert(
    eof_out:find(("a"):rep(24) .. "%[REDACTED%] %.%.%. %[line truncated at 32 bytes; remainder suppressed%]"),
    "EOF na janela de lookahead divergiu: " .. eof_out
  )
  assert(not eof_out:find("Boundary", 1, true) and not eof_out:find("Secret_9988", 1, true), "EOF vazou fragmento!")
  assert(has_notice("line exceeded 32 bytes"), "EOF truncado deveria notificar")
  vim.api.nvim_buf_delete(eof_buf, { force = true })

  -- Segredo maior que (limit + max_lookahead): nunca vaza bytes crus ao truncar
  local huge_reds = run_config.collect_redactions({ HUGE = ("S"):rep(120) })
  local huge_buf = vim.api.nvim_create_buf(false, true)
  build._state.seq = build._state.seq + 1
  local hseq = build._state.seq
  build._state.buf = huge_buf
  build._state.running = true
  build._state.kind = "build"
  build._reset_streams()
  build._feed(hseq, huge_buf, "stdout", { ("S"):rep(150) }, huge_reds)
  build._finish(hseq, 0, huge_reds)
  local huge_out = buf_text(huge_buf)
  assert(not huge_out:find("SSSS", 1, true), "segredo maior que buffer vazou bytes crus: " .. huge_out)
  assert(huge_out:find("line truncated", 1, true), "deveria sinalizar truncamento para segredo gigante")
  vim.api.nvim_buf_delete(huge_buf, { force = true })

  -- Callback agendado com seq antiga não pode escrever após nova seq
  local stale_buf = vim.api.nvim_create_buf(false, true)
  build._state.seq = build._state.seq + 1
  local old_s = build._state.seq
  build._state.buf = stale_buf
  build._state.running = true
  build._reset_streams()
  build._feed(old_s, stale_buf, "stdout", { "must_not_appear_stale", "" }, b_reds)
  build._state.seq = old_s + 1
  vim.wait(40, function()
    return false
  end)
  assert(buf_text(stale_buf) == "", "vim.schedule de seq antiga escreveu após troca de seq!")
  build._state.running = false
  build._reset_streams()
  vim.api.nvim_buf_delete(stale_buf, { force = true })

  build._max_line_bytes = orig_limit
  build._max_lookahead_bytes = orig_look

  -- 18c. Processo real (>1.1 MiB sem newline) + segredo na fronteira de 64 KiB + recuperação pós-newline + infinito + stop
  local root_huge, main_huge = fixtures.maven_project("run7d-huge-nolf", "com.demo.huge", "App")
  local boundary_tok = "BoundaryRealSecret_64KiB!"
  local pct_boundary = "enc@a/b+c" -- percent-encoded: enc%40a%2Fb%2Bc (17 bytes)
  fixtures.write(root_huge .. "/.env", {
    "BOUNDARY_TOK=" .. boundary_tok,
    "PCT_BOUNDARY=" .. pct_boundary,
  })
  -- Emite:
  -- 1) prefix=BOUNDARY_TOK + 'a' até byte 65530 + BOUNDARY_TOK cruzando byte 65536 + >1.1 MiB 'b' sem \n
  -- 2) \n + "after_nl_pct=enc%40a%2fB%2bc\n" (ou enc%40a%2fb%2Bc)
  -- 3) stderr com BOUNDARY_TOK
  fixtures.write(root_huge .. "/mvnw", {
    "#!/bin/sh",
    'TOK="BoundaryRealSecret_64KiB!"',
    'awk -v tok="$TOK" \'BEGIN {',
    '  head = "start=" tok "_";',
    '  printf "%s", head;',
    "  pad = 65530 - length(head);",
    '  for (i = 0; i < int(pad / 10); i++) printf "aaaaaaaaaa";',
    '  for (i = 0; i < (pad % 10); i++) printf "a";',
    '  printf "%s", tok;',
    '  for (i = 0; i < 18000; i++) printf "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";',
    '  printf "\\nafter_nl_ok=%s\\n", tok;',
    "}'",
    'awk -v tok="$TOK" \'BEGIN {',
    '  for (i = 0; i < 6553; i++) printf "cccccccccc";',
    '  printf "enc%%40a%%2fb%%2Bc";',
    '  for (i = 0; i < 18000; i++) printf "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";',
    '  printf "\\nstderr_ok=%s\\n", tok;',
    "}' >&2",
  })
  vim.fn.system({ "chmod", "+x", root_huge .. "/mvnw" })

  open_file(main_huge)
  notices = {}
  local seq_huge = build._state.seq
  build.build()
  ask_script = { "compile" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_huge and not build._state.running and not build._is_draining()
    end),
    "processo real >1MiB sem newline não concluiu a tempo"
  )

  local huge_real_out = buf_text(build._state.buf)
  assert(#huge_real_out < 140000, "buffer cresceu além do limite esperado: " .. tostring(#huge_real_out))
  assert(huge_real_out:find("start=[REDACTED]_", 1, true), "segredo no início da linha longa não foi redigido")
  assert(
    huge_real_out:find("[REDACTED] ... [line truncated at 65536 bytes; remainder suppressed]", 1, true),
    "segredo cruzando fronteira de 64 KiB deveria virar [REDACTED] antes do marcador de truncamento"
  )
  assert(
    not huge_real_out:find("BoundaryRealSecret", 1, true),
    "prefixo do segredo na fronteira vazou no processo real!"
  )
  assert(not huge_real_out:find("64KiB!", 1, true), "sufixo do segredo na fronteira vazou no processo real!")
  assert(not huge_real_out:find("enc%40a", 1, true), "prefixo percent-encoded na fronteira vazou no stderr real!")
  assert(not huge_real_out:find("%2fb%2Bc", 1, true), "sufixo percent-encoded na fronteira vazou no stderr real!")
  assert(not huge_real_out:find("bbbbbbbb", 1, true), "MBs suprimidos do stdout vazaram para o buffer!")
  assert(not huge_real_out:find("dddddddd", 1, true), "MBs suprimidos do stderr vazaram para o buffer!")
  assert(huge_real_out:find("after_nl_ok=[REDACTED]", 1, true), "stdout pós-newline não recuperou!")
  assert(huge_real_out:find("stderr_ok=[REDACTED]", 1, true), "stderr pós-newline não recuperou!")
  assert(
    has_notice("stdout line exceeded 65536 bytes"),
    "processo real >1MiB deveria emitir notificação de truncamento stdout"
  )
  assert(
    has_notice("stderr line exceeded 65536 bytes"),
    "processo real >1MiB deveria emitir notificação de truncamento stderr"
  )

  -- Processo real com saída infinita sem newline: permanece responsivo, limitado e é encerrado por stop(true)
  fixtures.write(root_huge .. "/mvnw", {
    "#!/bin/sh",
    "exec awk 'BEGIN { while (1) printf \"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\" }'",
  })
  vim.fn.system({ "chmod", "+x", root_huge .. "/mvnw" })
  notices = {}
  local seq_inf = build._state.seq
  build.build()
  ask_script = { "compile" }
  menu_cb(entry("choose_goal"))
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_inf
        and build._state.running
        and has_notice("line exceeded 65536 bytes")
        and buf_text(build._state.buf):find("line truncated at 65536 bytes", 1, true) ~= nil
    end),
    "processo real infinito sem newline não disparou truncamento limitado"
  )
  local inf_pid = build._state.pid
  assert(#buf_text(build._state.buf) < 131072, "processo infinito excedeu limite de buffer")
  build.stop(true)
  assert(
    fixtures.wait_for(10000, function()
      return not build._state.running and not build._is_draining()
    end),
    "stop do processo infinito sem newline não concluiu"
  )
  assert(not pid_alive(inf_pid), "processo infinito sobreviveu ao stop!")
end

-- Bound completed-line output and avoid cutting a UTF-8 codepoint in half.
do
  local original_limit = build._max_output_bytes
  local original_line_limit = build._max_line_bytes
  build._max_output_bytes = 256
  build._max_line_bytes = 2
  local buf = vim.api.nvim_create_buf(false, true)
  build._state.seq = build._state.seq + 1
  local seq = build._state.seq
  build._state.buf = buf
  build._state.running = true
  build._state.kind = "run_main"
  build._reset_streams()
  build._feed(seq, buf, "stdout", { "€xxxx\n" }, {})
  build._feed(seq, buf, "stdout", { ("x\n"):rep(10000) }, {})
  build._finish(seq, 0, {})
  local output = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(not output:find("\226\130", 1, true), "truncation left an incomplete UTF-8 sequence")
  assert(output:find("output limit reached", 1, true), "missing total output limit marker")
  assert(#output < 512, "output exceeded the bounded capture limit")
  build._max_output_bytes = original_limit
  build._max_line_bytes = original_line_limit
end

-- ========== 19. Issue #7: Safer process lifecycle (surviving background group, stubborn child, cross-project & PID reuse) ==========

do
  local root_7a, main_7a = fixtures.maven_project("run7d-i7-alpha", "com.demo.i7a", "App")
  local root_7b, main_7b = fixtures.maven_project("run7d-i7-beta", "com.demo.i7b", "App")
  local root_7c, main_7c = fixtures.maven_project("run7d-i7-gamma", "com.demo.i7c", "App")

  local stubborn_bg_pid_file = root_7a .. "/stubborn_bg.pid"
  local stubborn_bg_gate_file = root_7a .. "/stubborn_bg.gate"
  fixtures.write(root_7a .. "/mvnw", {
    "#!/bin/sh",
    '(trap "" TERM; exec sleep 30) &',
    "bpid=$!",
    'printf "%s" "$bpid" > ' .. vim.fn.shellescape(stubborn_bg_pid_file),
    "while [ ! -f " .. vim.fn.shellescape(stubborn_bg_gate_file) .. " ]; do sleep 0.02; done",
    "exit 0",
  })
  vim.fn.system({ "chmod", "+x", root_7a .. "/mvnw" })

  fixtures.write(root_7b .. "/mvnw", { "#!/bin/sh", "exit 0" })
  vim.fn.system({ "chmod", "+x", root_7b .. "/mvnw" })
  fixtures.write(root_7c .. "/mvnw", { "#!/bin/sh", "exit 0" })
  vim.fn.system({ "chmod", "+x", root_7c .. "/mvnw" })

  local orig_bg_grace = build._background_grace_ms
  local orig_stop_grace = build._stop_grace_ms
  local orig_restart_timeout = build._restart_timeout_ms
  build._background_grace_ms = 120
  build._stop_grace_ms = 200
  build._restart_timeout_ms = 5000

  local ext_job = vim.fn.jobstart({ "sleep", "30" })
  assert(ext_job > 0, "processo externo de controle não iniciou")
  local ext_pid = vim.fn.jobpid(ext_job)

  -- 19a. Líder sai com exit 0 deixando filho resistente em background; lock libera mas grupo continua rastreado
  open_file(main_7a)
  notices = {}
  build.build()
  menu_cb(entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return build._state.running and vim.fn.filereadable(stubborn_bg_pid_file) == 1
    end),
    "líder de alpha deveria ter iniciado filho resistente"
  )
  build.build()
  fixtures.write(stubborn_bg_gate_file, { "go" })
  assert(
    fixtures.wait_for(5000, function()
      return not build._state.running
        and build._state.status == "success"
        and vim.fn.filereadable(stubborn_bg_pid_file) == 1
    end),
    "líder de alpha deveria ter saído deixando filho resistente"
  )
  local bg_stubborn_pid = tonumber(read_raw(stubborn_bg_pid_file))
  assert(bg_stubborn_pid and pid_alive(bg_stubborn_pid), "filho resistente em background deveria estar vivo")

  assert(
    fixtures.wait_for(3000, function()
      return not build._is_draining() and has_notice("surviving background group")
    end),
    "monitor deveria liberar o build lock após _background_grace_ms"
  )
  assert(pid_alive(bg_stubborn_pid), "saída normal do líder não pode matar grupo sobrevivente")
  assert(#build._background_groups >= 1, "grupo sobrevivente deve permanecer rastreado após liberar lock")

  -- 19b. Novo build em outro projeto (beta) não fica bloqueado e NÃO apaga o rastreamento do grupo de alpha
  open_file(main_7b)
  local seq_b = build._state.seq
  notices = {}
  build.build()
  menu_cb(entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return build._state.seq > seq_b and not build._state.running and build._state.status == "success"
    end),
    "build em beta deveria rodar normalmente sem ser bloqueado pelo background de alpha"
  )
  assert(pid_alive(bg_stubborn_pid), "build em beta não pode matar grupo em background de alpha")

  -- Menu em beta ainda expõe Stop identificando o projeto de origem (alpha) e avisando sobre confirmação
  build.build()
  local stop_entry_b = entry("stop")
  assert(
    stop_entry_b and stop_entry_b.enabled,
    "Stop deve continuar habilitado para grupo em background após novo build"
  )
  assert(
    stop_entry_b.label:find("i7-alpha", 1, true),
    "Stop deveria identificar o projeto de origem (alpha), obteve: " .. tostring(stop_entry_b.label)
  )
  assert(
    stop_entry_b.reason:find("another project", 1, true),
    "Stop deveria avisar que é de outro projeto: " .. tostring(stop_entry_b.reason)
  )

  -- 19c. Confirmação stale de stop em background (mudança de projeto antes de responder) não age
  local captured_bg_stop_cb
  local saved_pick_i7 = ui.pick_one
  ui.pick_one = function(_, _, on_choice)
    captured_bg_stop_cb = on_choice
  end
  build.stop()
  ui.pick_one = saved_pick_i7
  assert(type(captured_bg_stop_cb) == "function", "Stop de background de outro projeto deveria pedir confirmação")

  open_file(main_7c)
  notices = {}
  captured_bg_stop_cb("Yes — stop the run7d-i7-alpha project background process")
  assert(pid_alive(bg_stubborn_pid), "callback stale após troca para projeto gamma matou background de alpha!")
  assert(has_notice("stale"), "callback stale deveria notificar")

  -- 19d. Em beta: escolher No mantém vivo; escolher Yes envia SIGTERM -> SIGKILL após grace no filho resistente
  open_file(main_7b)
  notices = {}
  pick_script = { "No" }
  build.build()
  menu_cb(entry("stop"))
  assert(pid_alive(bg_stubborn_pid), "escolha No matou grupo em background de alpha!")
  assert(has_notice("kept running"), "escolha No deveria informar que foi mantido")

  notices = {}
  pick_script = { "Yes" }
  build.build()
  menu_cb(entry("stop"))
  assert(
    fixtures.wait_for(5000, function()
      return not build._is_draining() and not pid_alive(bg_stubborn_pid)
    end),
    "Stop confirmado de outro projeto deveria encerrar filho resistente em background via SIGKILL após grace"
  )
  assert(has_notice("background process was stopped"), "Stop de outro projeto deveria informar origem")
  assert(pid_alive(ext_pid), "Stop de background matou processo externo não relacionado!")

  build.build()
  assert(entry("stop").enabled == false, "Stop deveria ficar desabilitado após encerramento do grupo em background")

  -- 19e. Saída natural posterior do grupo em background faz pruning automático e nunca mata PID reutilizado/não relacionado
  local short_bg_pid_file = root_7a .. "/short_bg.pid"
  local short_bg_gate_file = root_7a .. "/short_bg.gate"
  fixtures.write(root_7a .. "/mvnw", {
    "#!/bin/sh",
    "sleep 0.5 &",
    "bpid=$!",
    'printf "%s" "$bpid" > ' .. vim.fn.shellescape(short_bg_pid_file),
    "while [ ! -f " .. vim.fn.shellescape(short_bg_gate_file) .. " ]; do sleep 0.02; done",
    "exit 0",
  })
  vim.fn.system({ "chmod", "+x", root_7a .. "/mvnw" })
  open_file(main_7a)
  build.build()
  menu_cb(entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return build._state.running and vim.fn.filereadable(short_bg_pid_file) == 1
    end),
    "build com filho curto não iniciou"
  )
  build.build()
  fixtures.write(short_bg_gate_file, { "go" })
  assert(
    fixtures.wait_for(5000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(short_bg_pid_file) == 1
    end),
    "build com filho curto em background não concluiu release"
  )
  local short_bg_pid = tonumber(read_raw(short_bg_pid_file))
  assert(
    fixtures.wait_for(3000, function()
      return not pid_alive(short_bg_pid)
    end),
    "filho curto deveria ter saído naturalmente"
  )
  notices = {}
  build.build()
  assert(entry("stop").enabled == false, "grupo encerrado naturalmente deveria ser removido do menu")
  build.stop(true)
  assert(has_notice("no Java process is running"), "stop após saída natural não deveria encontrar processo")

  -- Proteção contra PID/PGID reutilizado (líder vivo com start_ticks distinto)
  local reuse_job = vim.fn.jobstart({ "sleep", "30" })
  assert(reuse_job > 0)
  local reuse_pid = vim.fn.jobpid(reuse_job)
  local reuse_info = build._read_proc_info(reuse_pid)
  assert(
    reuse_info and reuse_info.pgid == reuse_pid and reuse_info.start_ticks,
    "processo de teste deveria ter PGID e start_ticks próprios"
  )
  table.insert(build._background_groups, {
    seq = 999991,
    pgid = reuse_info.pgid,
    start_ticks = reuse_info.start_ticks - 50,
    sid = reuse_info.sid,
    members = { [reuse_pid] = reuse_info.start_ticks - 50 },
    root = root_7a,
    canon_root = run_config.canonical(root_7a),
    kind = "compile",
    exit_code = 0,
    stopping = false,
  })
  notices = {}
  build.stop(true)
  assert(pid_alive(reuse_pid), "NUNCA pode matar processo com start_ticks diferente (PID reutilizado)!")
  assert(has_notice("no Java process is running"), "entrada com PID reutilizado deveria ser descartada com segurança")
  vim.fn.jobstop(reuse_job)

  -- Proteção contra PID reutilizado quando líder já saiu deixando filho não relacionado (leader == nil, members sem correspondência)
  local orphan_child_file = root_7a .. "/orphan_unrelated.pid"
  local orphan_parent_file = root_7a .. "/orphan_parent.pid"
  local orphan_job = vim.fn.jobstart({
    "sh",
    "-c",
    'printf "%s" "$$" > '
      .. vim.fn.shellescape(orphan_parent_file)
      .. '; sleep 30 & printf "%s" "$!" > '
      .. vim.fn.shellescape(orphan_child_file),
  })
  assert(orphan_job > 0)
  assert(
    fixtures.wait_for(5000, function()
      return vim.fn.filereadable(orphan_parent_file) == 1 and vim.fn.filereadable(orphan_child_file) == 1
    end),
    "processo órfão não relacionado não gravou PIDs"
  )
  local unrelated_parent_pid = tonumber(read_raw(orphan_parent_file))
  local unrelated_child_pid = tonumber(read_raw(orphan_child_file))
  assert(
    fixtures.wait_for(5000, function()
      return not pid_alive(unrelated_parent_pid) and pid_alive(unrelated_child_pid)
    end),
    "líder órfão não saiu mantendo filho vivo"
  )
  table.insert(build._background_groups, {
    seq = 999992,
    pgid = unrelated_parent_pid,
    start_ticks = 1,
    sid = unrelated_parent_pid,
    members = { [999998] = 1 },
    root = root_7a,
    canon_root = run_config.canonical(root_7a),
    kind = "compile",
    exit_code = 0,
    stopping = false,
  })
  notices = {}
  build.stop(true)
  assert(
    pid_alive(unrelated_child_pid),
    "NUNCA pode matar filho remanescente quando nenhum membro rastreado corresponde!"
  )
  assert(has_notice("no Java process is running"))
  vim.fn.system({ "kill", "-KILL", tostring(unrelated_child_pid) })

  -- 19f. Restart no mesmo projeto para grupo sobrevivente em background (inclusive filho resistente)
  local restart_bg_pid_file = root_7a .. "/restart_bg.pid"
  local restart_bg_gate_file = root_7a .. "/restart_bg.gate"
  fixtures.write(root_7a .. "/mvnw", {
    "#!/bin/sh",
    '(trap "" TERM; exec sleep 30) &',
    "bpid=$!",
    'printf "%s" "$bpid" > ' .. vim.fn.shellescape(restart_bg_pid_file),
    "while [ ! -f " .. vim.fn.shellescape(restart_bg_gate_file) .. " ]; do sleep 0.02; done",
    "exit 0",
  })
  vim.fn.system({ "chmod", "+x", root_7a .. "/mvnw" })

  open_file(main_7a)
  build.build()
  menu_cb(entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return build._state.running and vim.fn.filereadable(restart_bg_pid_file) == 1
    end),
    "build inicial para teste de restart em background não iniciou"
  )
  build.build()
  fixtures.write(restart_bg_gate_file, { "go" })
  assert(
    fixtures.wait_for(5000, function()
      return not build._state.running and not build._is_draining() and vim.fn.filereadable(restart_bg_pid_file) == 1
    end),
    "build inicial para teste de restart em background não liberou"
  )
  local first_restart_bg_pid = tonumber(read_raw(restart_bg_pid_file))
  assert(first_restart_bg_pid and pid_alive(first_restart_bg_pid))

  -- Timeout antes do grace period cancela restart mantendo o grupo vivo sem relançar duplicata
  build._stop_grace_ms = 5000
  build._restart_timeout_ms = 180
  local seq_before_cancel = build._state.seq
  notices = {}
  build.restart()
  assert(
    fixtures.wait_for(3000, function()
      return not build._state.restarting and has_notice("did not exit in time")
    end),
    "restart sobre grupo em background resistente deveria cancelar no timeout"
  )
  assert(build._state.seq == seq_before_cancel, "restart cancelado não pode lançar novo processo")
  assert(pid_alive(first_restart_bg_pid), "grupo em background deveria permanecer vivo após cancelamento")

  -- Com grace normal, restart envia SIGKILL, espera drenagem e relança o comando do projeto
  build._stop_grace_ms = 200
  build._restart_timeout_ms = 5000
  vim.fn.delete(restart_bg_pid_file)
  vim.fn.delete(restart_bg_gate_file)
  notices = {}
  build.restart()
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_before_cancel
        and build._state.running
        and vim.fn.filereadable(restart_bg_pid_file) == 1
    end),
    "restart em alpha não relançou após drenar grupo sobrevivente em background"
  )
  build.build()
  fixtures.write(restart_bg_gate_file, { "go" })
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > seq_before_cancel
        and not build._state.running
        and not build._is_draining()
        and vim.fn.filereadable(restart_bg_pid_file) == 1
    end),
    "restart em alpha não concluiu release após relançar"
  )
  local second_restart_bg_pid = tonumber(read_raw(restart_bg_pid_file))
  assert(not pid_alive(first_restart_bg_pid), "primeiro filho resistente sobreviveu ao Restart!")
  assert(second_restart_bg_pid and second_restart_bg_pid ~= first_restart_bg_pid and pid_alive(second_restart_bg_pid))

  build.stop(true)
  assert(
    fixtures.wait_for(5000, function()
      return not build._state.running and not build._is_draining() and not pid_alive(second_restart_bg_pid)
    end),
    "stop final do grupo relançado não concluiu"
  )
  assert(pid_alive(ext_pid), "processo externo foi afetado durante os testes de ciclo de vida!")
  vim.fn.jobstop(ext_job)

  build._background_grace_ms = orig_bg_grace
  build._stop_grace_ms = orig_stop_grace
  build._restart_timeout_ms = orig_restart_timeout

  -- Unverified PGIDs/PIDs are never accepted as process identity.
  assert(not build._group_alive(reuse_info.pgid, nil), "PGID without a captured start time must fail closed")
  assert(
    not build._group_alive(reuse_info.pgid, nil, { [reuse_pid] = reuse_info.start_ticks }),
    "PGID without leader start time must fail closed even with a member table"
  )
  local unverified_kill_job = vim.fn.jobstart({ "sleep", "30" })
  local unverified_kill_pid = vim.fn.jobpid(unverified_kill_job)
  local saved_proc_reader = build._read_proc_info
  build._read_proc_info = function(p)
    if p == unverified_kill_pid then
      return { pid = p, ppid = vim.uv.os_getpid(), pgid = p, sid = nil, start_ticks = nil }
    end
    return saved_proc_reader(p)
  end
  local no_ticks_pgid, _, no_ticks_reason = build._verify_own_pgid(unverified_kill_pid)
  assert(
    no_ticks_pgid == nil and type(no_ticks_reason) == "string" and no_ticks_reason:find("start time", 1, true),
    "verify_own_pgid must fail closed when /proc start time is unavailable: " .. tostring(no_ticks_reason)
  )
  build._read_proc_info = function()
    return nil
  end
  build._kill_tree(unverified_kill_pid, "KILL", nil)
  build._read_proc_info = saved_proc_reader
  assert(pid_alive(unverified_kill_pid), "PID fallback must not signal when /proc identity is unavailable")
  vim.fn.jobstop(unverified_kill_job)

  -- A background confirmation captures the exact set; a later group for that
  -- project is not added to the confirmed stop. Per-group timers also survive
  -- pruning one group while another target is still draining.
  local function add_test_background(root)
    local job = vim.fn.jobstart({ "sh", "-c", 'trap "" TERM; exec sleep 30' })
    assert(job > 0)
    local pid = vim.fn.jobpid(job)
    local info = build._read_proc_info(pid)
    assert(info and info.pgid == pid and info.start_ticks, "test background group needs verifiable identity")
    local bg = {
      seq = 999900 + #build._background_groups,
      pgid = info.pgid,
      start_ticks = info.start_ticks,
      sid = info.sid,
      members = { [pid] = info.start_ticks },
      root = root,
      canon_root = run_config.canonical(root),
      kind = "compile",
      stopping = false,
    }
    build._background_groups[#build._background_groups + 1] = bg
    return job, pid, bg
  end
  local first_job, first_pid = add_test_background(root_7a)
  local second_job, second_pid = add_test_background(root_7a)
  open_file(main_7b)
  local captured_stop
  local saved_pick = ui.pick_one
  ui.pick_one = function(_, _, callback)
    captured_stop = callback
  end
  build.stop()
  ui.pick_one = saved_pick
  assert(type(captured_stop) == "function", "cross-project background stop should request confirmation")
  local late_job, late_pid = add_test_background(root_7a)
  captured_stop("Yes — stop the i7-alpha project background process")
  assert(pid_alive(late_pid), "confirmation must not expand to groups added after the prompt")
  -- Remove one tracked member while the other group is still draining. Its
  -- timer must not be the sole timer shared by the remaining group.
  vim.uv.kill(first_pid, "sigkill")
  assert(
    fixtures.wait_for(5000, function()
      return not pid_alive(first_pid) and not pid_alive(second_pid)
    end),
    "pruning one background group must not cancel the other group's drain timer"
  )
  assert(pid_alive(late_pid), "late background group was incorrectly included in confirmed stop")
  vim.uv.kill(late_pid, "sigkill")
  vim.fn.jobstop(first_job)
  vim.fn.jobstop(second_job)
  vim.fn.jobstop(late_job)

  -- If one captured background group exits before confirmation, the remaining
  -- captured group still stops, while any late group stays untouched.
  local partial_a_job, partial_a_pid = add_test_background(root_7a)
  local partial_b_job, partial_b_pid = add_test_background(root_7a)
  open_file(main_7b)
  local captured_partial_stop
  saved_pick = ui.pick_one
  ui.pick_one = function(_, _, callback)
    captured_partial_stop = callback
  end
  build.stop()
  ui.pick_one = saved_pick
  assert(type(captured_partial_stop) == "function")
  local late_partial_job, late_partial_pid = add_test_background(root_7a)
  vim.uv.kill(partial_a_pid, "sigkill")
  assert(
    fixtures.wait_for(3000, function()
      return not pid_alive(partial_a_pid)
    end),
    "first captured group should exit before confirmation"
  )
  captured_partial_stop("Yes — stop the i7-alpha project background process")
  assert(
    fixtures.wait_for(5000, function()
      return not pid_alive(partial_b_pid)
    end),
    "remaining captured group must still stop after sibling exited"
  )
  assert(pid_alive(late_partial_pid), "late group must not be stopped after partial sibling exit")
  vim.uv.kill(late_partial_pid, "sigkill")
  vim.fn.jobstop(partial_a_job)
  vim.fn.jobstop(partial_b_job)
  vim.fn.jobstop(late_partial_job)

  -- Pruning a draining background group via _is_draining() before the timer
  -- ticks must not cancel the monitor and deadlock restart launch.
  local prune_bg_job, prune_bg_pid = add_test_background(root_7b)
  open_file(main_7b)
  local prune_restart_seq = build._state.seq
  build.restart()
  assert(build._state.restarting, "restart should enter draining state for background group")
  vim.uv.kill(prune_bg_pid, "sigkill")
  assert(
    fixtures.wait_for(2000, function()
      return not pid_alive(prune_bg_pid)
    end),
    "draining background group did not exit"
  )
  local _ = build._is_draining()
  assert(
    fixtures.wait_for(5000, function()
      return build._state.seq > prune_restart_seq and not build._state.running and not build._state.restarting
    end),
    "pruning draining group before timer tick must not deadlock restart launch"
  )
  vim.fn.jobstop(prune_bg_job)

  -- A confirmed restart from alpha into beta must also drain beta's existing
  -- background groups before launching beta's remembered command.
  local dest_job, dest_pid = add_test_background(root_7b)
  fixtures.write(root_7a .. "/mvnw", { "#!/bin/sh", "exec sleep 30" })
  vim.fn.system({ "chmod", "+x", root_7a .. "/mvnw" })
  open_file(main_7a)
  build.build()
  menu_cb(entry("compile"))
  assert(
    fixtures.wait_for(5000, function()
      return build._state.running and build._state.root == root_7a
    end),
    "foreground process for cross-project restart did not start"
  )
  local restart_seq = build._state.seq
  open_file(main_7b)
  local captured_restart
  saved_pick = ui.pick_one
  ui.pick_one = function(_, _, callback)
    captured_restart = callback
  end
  build.restart()
  ui.pick_one = saved_pick
  assert(type(captured_restart) == "function", "cross-project restart should request confirmation")
  captured_restart("Yes — stop the i7-alpha project process and restart")
  assert(
    fixtures.wait_for(10000, function()
      return build._state.seq > restart_seq
        and not build._state.running
        and build._state.root == root_7b
        and not pid_alive(dest_pid)
    end),
    "cross-project restart must drain destination groups before relaunching beta"
  )
  vim.fn.jobstop(dest_job)

  -- Regression (1): finish() must refresh via refresh_verified_members with
  -- previous members and retain old identities when there is no intersection,
  -- never signaling an uncertain group.
  do
    build._background_grace_ms = 80
    build._stop_grace_ms = 80
    build._restart_timeout_ms = 240

    local dis_parent_file = root_7a .. "/finish_disjoint_parent.pid"
    local dis_child_file = root_7a .. "/finish_disjoint_child.pid"
    local dis_job = vim.fn.jobstart({
      "sh",
      "-c",
      'printf "%s" "$$" > '
        .. vim.fn.shellescape(dis_parent_file)
        .. '; (trap "" TERM; exec sleep 30) & printf "%s" "$!" > '
        .. vim.fn.shellescape(dis_child_file),
    })
    assert(dis_job > 0)
    assert(
      fixtures.wait_for(5000, function()
        return vim.fn.filereadable(dis_parent_file) == 1 and vim.fn.filereadable(dis_child_file) == 1
      end),
      "disjoint finish test failed to write pid files"
    )
    local dis_leader_pid = tonumber(read_raw(dis_parent_file))
    local dis_child_pid = tonumber(read_raw(dis_child_file))
    assert(
      fixtures.wait_for(5000, function()
        return not pid_alive(dis_leader_pid) and pid_alive(dis_child_pid)
      end),
      "disjoint finish leader did not exit while child stayed alive"
    )
    local child_info = build._read_proc_info(dis_child_pid)
    assert(
      child_info and child_info.pgid == dis_leader_pid and type(child_info.start_ticks) == "number",
      "disjoint finish child must share exited leader PGID"
    )
    local stale_leader_ticks = math.max(1, child_info.start_ticks - 1)
    local orig_uv_kill = vim.uv.kill
    local signaled = {}
    vim.uv.kill = function(target, sig)
      if sig ~= 0 and (target == -dis_leader_pid or target == dis_child_pid or target == dis_leader_pid) then
        signaled[#signaled + 1] = { target = target, sig = sig }
      end
      return orig_uv_kill(target, sig)
    end

    local finish_buf = vim.api.nvim_create_buf(false, true)
    local finish_seq = build._state.seq + 1
    build._state.seq = finish_seq
    build._state.running = true
    build._state.stopping = false
    build._state.restarting = false
    build._state.buf = finish_buf
    build._state.root = root_7a
    build._state.kind = "compile"
    build._state.pgid = dis_leader_pid
    build._state.pgid_start_ticks = stale_leader_ticks
    build._state.pgid_sid = child_info.sid
    build._state.pgid_members = { [dis_leader_pid] = stale_leader_ticks }
    build._reset_streams()

    build._finish(finish_seq, 0, {})
    assert(build._state.pgid_uncertain == true, "finish() must classify disjoint PGID as uncertain")
    assert(
      build._state.pgid_members
        and build._state.pgid_members[dis_leader_pid] == stale_leader_ticks
        and build._state.pgid_members[dis_child_pid] == nil,
      "finish() must retain old verified identities when snapshot has no intersection"
    )
    assert(
      fixtures.wait_for(2000, function()
        return not build._is_draining()
      end),
      "uncertain disjoint group did not release from foreground drain monitor"
    )
    assert(pid_alive(dis_child_pid), "uncertain disjoint group must not be signaled on background release")
    assert(#signaled == 0, "finish() / drain monitor signaled an uncertain group: " .. vim.inspect(signaled))
    local recorded_bg = nil
    for _, bg in ipairs(build._background_groups) do
      if bg.seq == finish_seq and bg.pgid == dis_leader_pid then
        recorded_bg = bg
        break
      end
    end
    assert(recorded_bg and recorded_bg.uncertain == true, "recorded background group must remain uncertain")
    assert(
      recorded_bg.members
        and recorded_bg.members[dis_leader_pid] == stale_leader_ticks
        and recorded_bg.members[dis_child_pid] == nil,
      "recorded background group must retain old verified identities"
    )
    build.stop(true)
    assert(pid_alive(dis_child_pid), "stop() must not signal uncertain background group")
    assert(#signaled == 0, "stop() signaled uncertain background group")

    -- Also verify finish() when stopping=true never replaces members or signals uncertain group.
    for i = #build._background_groups, 1, -1 do
      if build._background_groups[i].seq == finish_seq then
        table.remove(build._background_groups, i)
      end
    end
    local finish_stop_seq = build._state.seq + 1
    build._state.seq = finish_stop_seq
    build._state.running = true
    build._state.stopping = true
    build._state.restarting = true
    build._state.buf = finish_buf
    build._state.root = root_7a
    build._state.kind = "compile"
    build._state.pgid = dis_leader_pid
    build._state.pgid_start_ticks = stale_leader_ticks
    build._state.pgid_sid = child_info.sid
    build._state.pgid_members = { [dis_leader_pid] = stale_leader_ticks }
    build._reset_streams()
    notices = {}
    build._finish(finish_stop_seq, 0, {})
    assert(build._state.pgid_uncertain == true)
    assert(
      build._state.pgid_members
        and build._state.pgid_members[dis_leader_pid] == stale_leader_ticks
        and build._state.pgid_members[dis_child_pid] == nil,
      "stopping finish() must retain old verified identities"
    )
    assert(
      fixtures.wait_for(2000, function()
        return not build._state.restarting
          and build._state.drain_timer == nil
          and has_notice("identity became uncertain while stopping")
      end),
      "stopping drain monitor for uncertain group did not settle at timeout"
    )
    assert(pid_alive(dis_child_pid), "stopping drain monitor must not signal uncertain group")
    assert(#signaled == 0, "stopping drain monitor signaled uncertain group: " .. vim.inspect(signaled))

    vim.uv.kill = orig_uv_kill
    vim.uv.kill(dis_child_pid, "sigkill")
    assert(
      fixtures.wait_for(2000, function()
        return not pid_alive(dis_child_pid) and not build._is_draining()
      end),
      "draining state did not clear after manual kill of uncertain group"
    )
    vim.fn.jobstop(dis_job)
    pcall(vim.api.nvim_buf_delete, finish_buf, { force = true })
  end

  -- Regression (2a): foreground start_drain_monitor must not mark sigkill_sent
  -- while uncertain, and must send SIGKILL if identity recovers before timeout.
  do
    build._stop_grace_ms = 120
    build._restart_timeout_ms = 2000
    fixtures.write(root_7a .. "/mvnw", { "#!/bin/sh", 'trap "" TERM', "exec sleep 30" })
    vim.fn.system({ "chmod", "+x", root_7a .. "/mvnw" })
    open_file(main_7a)
    build.build()
    menu_cb(entry("compile"))
    assert(
      fixtures.wait_for(5000, function()
        return build._state.running and build._state.pgid ~= nil
      end),
      "stubborn foreground process for uncertain recovery test did not start"
    )
    local fg_pid = build._state.pid
    local fg_pgid = build._state.pgid
    local orig_proc_reader = build._read_proc_info
    local orig_uv_kill = vim.uv.kill
    local fg_obscured = false
    local fg_sigkills = 0
    build._read_proc_info = function(p)
      if fg_obscured and p == fg_pid then
        return nil
      end
      return orig_proc_reader(p)
    end
    vim.uv.kill = function(target, sig)
      if target == -fg_pgid and sig == "sigkill" then
        fg_sigkills = fg_sigkills + 1
      end
      return orig_uv_kill(target, sig)
    end

    build.stop(true)
    fg_obscured = true
    assert(
      fixtures.wait_for(1000, function()
        return build._state.pgid_uncertain == true
      end),
      "foreground drain monitor did not enter uncertain state"
    )
    vim.wait(220, function()
      return false
    end)
    assert(fg_sigkills == 0, "foreground monitor marked/sent SIGKILL while status was uncertain")
    assert(pid_alive(fg_pid), "foreground process should still be alive while identity is uncertain")

    fg_obscured = false
    assert(
      fixtures.wait_for(2000, function()
        return not build._state.running and not build._is_draining() and not pid_alive(fg_pid)
      end),
      "foreground monitor must re-evaluate and send SIGKILL when identity recovers before timeout"
    )
    assert(fg_sigkills == 1, "expected exactly 1 SIGKILL after foreground identity recovery, got " .. fg_sigkills)
    assert(build._state.pgid_uncertain == false, "pgid_uncertain should clear after exit")

    build._read_proc_info = orig_proc_reader
    vim.uv.kill = orig_uv_kill
  end

  -- Regression (2b): multi-group start_bg_drain_monitor tracks sigkill_sent per
  -- target only after a verifiable attempt and re-evaluates recovering targets.
  do
    build._stop_grace_ms = 120
    build._restart_timeout_ms = 2000
    local bg1_job, bg1_pid, bg1 = add_test_background(root_7a)
    local bg2_job, bg2_pid, bg2 = add_test_background(root_7a)
    local orig_proc_reader = build._read_proc_info
    local orig_uv_kill = vim.uv.kill
    local bg2_obscured = false
    local sigkill_counts = {}
    build._read_proc_info = function(p)
      if bg2_obscured and p == bg2_pid then
        return nil
      end
      return orig_proc_reader(p)
    end
    vim.uv.kill = function(target, sig)
      if sig == "sigkill" then
        sigkill_counts[target] = (sigkill_counts[target] or 0) + 1
      end
      return orig_uv_kill(target, sig)
    end

    open_file(main_7a)
    notices = {}
    build.stop(true)
    bg2_obscured = true
    assert(
      fixtures.wait_for(2000, function()
        return not pid_alive(bg1_pid) and bg2.uncertain == true
      end),
      "verifiable sibling bg1 should exit via SIGKILL while bg2 becomes uncertain"
    )
    vim.wait(220, function()
      return false
    end)
    assert(sigkill_counts[-bg1.pgid] == 1, "verifiable target bg1 should receive exactly 1 SIGKILL")
    assert((sigkill_counts[-bg2.pgid] or 0) == 0, "uncertain target bg2 must not receive SIGKILL")
    assert(pid_alive(bg2_pid), "uncertain target bg2 must remain alive while identity is unverified")

    bg2_obscured = false
    assert(
      fixtures.wait_for(2000, function()
        return not build._is_draining() and not pid_alive(bg2_pid)
      end),
      "bg drain monitor must re-evaluate and SIGKILL bg2 once identity recovers before timeout"
    )
    assert(sigkill_counts[-bg1.pgid] == 1, "already-signaled target bg1 must not be re-signaled")
    assert(sigkill_counts[-bg2.pgid] == 1, "recovered target bg2 should receive exactly 1 SIGKILL")
    assert(not has_notice("automatic SIGKILL skipped"), "recovered target should not report skipped SIGKILL")

    build._read_proc_info = orig_proc_reader
    vim.uv.kill = orig_uv_kill
    vim.fn.jobstop(bg1_job)
    vim.fn.jobstop(bg2_job)
  end

  -- Regression (3a): monitor A (uncertain, ignored by first_stopping_bg) finishing
  -- before restart B's monitor must not steal/launch restart B prematurely or
  -- clear restart B's state while B's target is still draining.
  do
    build._stop_grace_ms = 5000
    build._restart_timeout_ms = 5000
    local bg_a_job, bg_a_pid, bg_a = add_test_background(root_7a)
    local bg_b_job, bg_b_pid, bg_b = add_test_background(root_7b)
    local orig_proc_reader = build._read_proc_info
    local bg_a_obscured = false
    build._read_proc_info = function(p)
      if bg_a_obscured and p == bg_a_pid then
        return nil
      end
      return orig_proc_reader(p)
    end

    open_file(main_7a)
    build.stop(true)
    bg_a_obscured = true
    assert(
      fixtures.wait_for(2000, function()
        return bg_a.uncertain == true and bg_a.drain_monitor ~= nil
      end),
      "monitor A did not enter uncertain state"
    )
    assert(not build._is_draining(), "first_stopping_bg should ignore uncertain monitor A")
    assert(not build._state.restarting, "stop on monitor A should not set restarting")

    open_file(main_7b)
    local seq_before = build._state.seq
    build.restart()
    assert(build._state.restarting, "restart B should enter restarting state")
    assert(bg_b.drain_monitor ~= nil, "restart B should start independent monitor B")

    -- Finish monitor A before monitor B while bg_b is still alive.
    bg_a_obscured = false
    vim.uv.kill(bg_a_pid, "sigkill")
    assert(
      fixtures.wait_for(2000, function()
        return not pid_alive(bg_a_pid) and bg_a.drain_monitor == nil
      end),
      "monitor A did not finish after bg_a exit"
    )
    vim.wait(120, function()
      return false
    end)
    assert(build._state.restarting, "monitor A exit must not clear restart B's restarting state")
    assert(build._state.seq == seq_before, "monitor A exit must not prematurely launch restart B")
    assert(pid_alive(bg_b_pid) and bg_b.drain_monitor ~= nil, "monitor B must remain active for bg_b")

    vim.uv.kill(bg_b_pid, "sigkill")
    assert(
      fixtures.wait_for(5000, function()
        return build._state.seq > seq_before
          and not build._state.running
          and not build._state.restarting
          and build._state.root == root_7b
      end),
      "restart B did not launch after bg_b exited"
    )

    build._read_proc_info = orig_proc_reader
    vim.fn.jobstop(bg_a_job)
    vim.fn.jobstop(bg_b_job)
  end

  -- Regression (3b): monitor A (uncertain, ignored by first_stopping_bg) timing out
  -- before restart B's monitor must not cancel restart B or emit restart cancelled.
  do
    build._stop_grace_ms = 5000
    build._restart_timeout_ms = 450
    local bg_a_job, bg_a_pid, bg_a = add_test_background(root_7a)
    local bg_b_job, bg_b_pid, bg_b = add_test_background(root_7b)
    local orig_proc_reader = build._read_proc_info
    local bg_a_obscured = false
    build._read_proc_info = function(p)
      if bg_a_obscured and p == bg_a_pid then
        return nil
      end
      return orig_proc_reader(p)
    end

    open_file(main_7a)
    build.stop(true)
    bg_a_obscured = true
    assert(
      fixtures.wait_for(2000, function()
        return bg_a.uncertain == true and bg_a.drain_monitor ~= nil
      end),
      "monitor A did not enter uncertain state before timeout test"
    )
    -- Give monitor A a deterministic head start so it expires before monitor B.
    vim.wait(220, function()
      return false
    end)

    open_file(main_7b)
    notices = {}
    local seq_before = build._state.seq
    build.restart()
    assert(build._state.restarting, "restart B should be active while monitor A is pending")
    assert(bg_b.drain_monitor ~= nil, "restart B should have its own monitor B")

    assert(
      fixtures.wait_for(2000, function()
        return not bg_a.stopping and bg_a.drain_monitor == nil
      end),
      "monitor A did not time out as expected"
    )
    build._restart_timeout_ms = 5000
    assert(build._state.restarting, "monitor A timeout must not cancel restart B")
    assert(build._state.seq == seq_before, "monitor A timeout must not alter restart B seq")
    assert(not has_notice("restart cancelled"), "non-restart monitor A timeout must not notify restart cancelled")
    assert(has_notice("automatic SIGKILL skipped"), "monitor A timeout should report skipped SIGKILL")
    assert(pid_alive(bg_b_pid) and bg_b.drain_monitor ~= nil, "monitor B must stay active after monitor A timeout")

    vim.uv.kill(bg_b_pid, "sigkill")
    assert(
      fixtures.wait_for(5000, function()
        return build._state.seq > seq_before
          and not build._state.running
          and not build._state.restarting
          and build._state.root == root_7b
      end),
      "restart B must still complete after monitor A timed out"
    )

    bg_a_obscured = false
    build._read_proc_info = orig_proc_reader
    vim.uv.kill(bg_a_pid, "sigkill")
    assert(
      fixtures.wait_for(2000, function()
        return not pid_alive(bg_a_pid) and not build._is_draining()
      end),
      "cleanup of bg_a failed after timeout test"
    )
    vim.fn.jobstop(bg_a_job)
    vim.fn.jobstop(bg_b_job)
  end

  -- Regression (3c): an obsolete restart monitor (cancelled by a subsequent stop
  -- on another group) finishing before a newer restart B must neither invoke its
  -- stale callback nor launch/clear restart B prematurely.
  do
    build._stop_grace_ms = 5000
    build._restart_timeout_ms = 5000
    local stale_flag = root_7a .. "/stale_restart_a.flag"
    vim.fn.delete(stale_flag)
    fixtures.write(root_7a .. "/mvnw", {
      "#!/bin/sh",
      "printf '1' > " .. vim.fn.shellescape(stale_flag),
      "exit 0",
    })
    vim.fn.system({ "chmod", "+x", root_7a .. "/mvnw" })
    open_file(main_7a)
    build.build()
    menu_cb(entry("compile"))
    assert(
      fixtures.wait_for(5000, function()
        return vim.fn.filereadable(stale_flag) == 1 and not build._state.running
      end),
      "failed to record alpha command for obsolete restart test"
    )
    vim.fn.delete(stale_flag)

    local bg_a_job, bg_a_pid, bg_a = add_test_background(root_7a)
    local orig_proc_reader = build._read_proc_info
    local bg_a_obscured = false
    build._read_proc_info = function(p)
      if bg_a_obscured and p == bg_a_pid then
        return nil
      end
      return orig_proc_reader(p)
    end

    open_file(main_7a)
    build.restart()
    assert(build._state.restarting and bg_a.drain_monitor ~= nil, "restart A should start monitor A")
    bg_a_obscured = true
    assert(
      fixtures.wait_for(2000, function()
        return bg_a.uncertain == true
      end),
      "monitor A did not become uncertain"
    )

    -- Cancel restart A by stopping an unrelated background group on beta, leaving
    -- monitor A running with an obsolete restart operation.
    local bg_c_job, bg_c_pid = add_test_background(root_7b)
    open_file(main_7b)
    build.stop(true)
    assert(not build._state.restarting, "stop on beta should cancel pending restart A")
    vim.uv.kill(bg_c_pid, "sigkill")
    assert(
      fixtures.wait_for(2000, function()
        return not pid_alive(bg_c_pid) and not build._is_draining()
      end),
      "bg_c stop did not finish"
    )

    local bg_b_job, bg_b_pid, bg_b = add_test_background(root_7b)
    local seq_before = build._state.seq
    build.restart()
    assert(build._state.restarting and bg_b.drain_monitor ~= nil, "restart B should start monitor B")

    -- Finish obsolete monitor A while monitor B is still draining bg_b.
    bg_a_obscured = false
    vim.uv.kill(bg_a_pid, "sigkill")
    assert(
      fixtures.wait_for(2000, function()
        return not pid_alive(bg_a_pid) and bg_a.drain_monitor == nil
      end),
      "obsolete monitor A did not finish"
    )
    vim.wait(120, function()
      return false
    end)
    assert(vim.fn.filereadable(stale_flag) == 0, "obsolete monitor A must not invoke stale restart A callback")
    assert(build._state.restarting, "obsolete monitor A must not clear restart B")
    assert(build._state.seq == seq_before, "obsolete monitor A must not prematurely launch restart B")
    assert(pid_alive(bg_b_pid) and bg_b.drain_monitor ~= nil, "monitor B must remain active")

    vim.uv.kill(bg_b_pid, "sigkill")
    assert(
      fixtures.wait_for(5000, function()
        return build._state.seq > seq_before
          and not build._state.running
          and not build._state.restarting
          and build._state.root == root_7b
      end),
      "restart B did not complete after bg_b exited"
    )
    assert(vim.fn.filereadable(stale_flag) == 0, "stale restart A callback must never execute")

    build._read_proc_info = orig_proc_reader
    vim.fn.jobstop(bg_a_job)
    vim.fn.jobstop(bg_b_job)
    vim.fn.jobstop(bg_c_job)
  end

  build._background_grace_ms = orig_bg_grace
  build._stop_grace_ms = orig_stop_grace
  build._restart_timeout_ms = orig_restart_timeout
end

-- A callback queued by an old timer must not close its replacement.
do
  local original_new_timer = vim.uv.new_timer
  local original_schedule_wrap = vim.schedule_wrap
  local timers = {}
  vim.uv.new_timer = function()
    local timer = { closed = false }
    function timer:start(_, _, callback)
      self.callback = callback
    end
    function timer:stop() end
    function timer:close()
      self.closed = true
    end
    timers[#timers + 1] = timer
    return timer
  end
  vim.schedule_wrap = function(callback)
    return callback
  end
  local seq = build._state.seq
  build._start_drain_monitor(seq, nil, nil, {})
  build._start_drain_monitor(seq, nil, nil, {})
  assert(timers[1].closed, "old drain timer should be closed")
  timers[1].callback()
  assert(build._state.drain_timer == timers[2] and not timers[2].closed, "stale callback closed the new timer")
  timers[2].callback()
  assert(timers[2].closed, "current drain timer did not finish")
  vim.uv.new_timer = original_new_timer
  vim.schedule_wrap = original_schedule_wrap
end

-- Limpeza e restauração
ui.notify = real_notify
ui.ask = real_ask
ui.menu = real_menu
ui.pick_one = real_pick_one
lsp.client_or_reason = real_client_or_reason
vim.lsp.get_clients = real_get_clients
run_config._base_dir = nil
for _, d in ipairs(temp_dirs) do
  vim.fn.delete(d, "rf")
end

print("run_experience_spec: OK")
