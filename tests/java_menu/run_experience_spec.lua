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

-- ========== 10. Regression (3): Args com aspas preservados no Repeat Last e jc ==========

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
  local prev_jc_settings = package.loaded["jc.settings"]
  package.loaded["jc.settings"] = {
    read_project = function(name)
      return jc_store[name]
    end,
    write_project = function(name, value)
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
  assert(jc_store["build-last"] == "verify", "jc build-last NÃO pode receber serialização incompatível com aspas!")
  assert(has_notice("incompatible with jc build-last"), "deveria avisar que escrita incompatível no jc foi evitada")

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

  -- Args simples sem aspas/espaços continuam gravando jc build-last normalmente
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
  assert(jc_store["build-last"] == "clean package", "args simples deveriam atualizar jc build-last")

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
  fixtures.write(root_bg .. "/mvnw", {
    "#!/bin/sh",
    "sleep 30 &",
    "bpid=$!",
    'printf "%s" "$bpid" > ' .. vim.fn.shellescape(bg_pid_file),
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
  local jc_hist_store = {}
  local prev_jc_settings = package.loaded["jc.settings"]
  package.loaded["jc.settings"] = {
    read_project = function(name)
      return jc_hist_store[name]
    end,
    write_project = function(name, value)
      jc_hist_store[name] = value
    end,
  }

  local root_h, main_h = fixtures.maven_project("run7d-hist-only-launched", "com.demo.h", "App")
  fixtures.write(root_h .. "/mvnw", { "#!/bin/sh", "exec sleep 30" })
  vim.fn.system({ "chmod", "+x", root_h .. "/mvnw" })

  local canon_h = run_config.canonical(root_h)
  open_file(main_h)

  -- 14a. Primeiro build válido grava histórico
  build.build()
  menu_cb(entry("compile"))
  assert(fixtures.wait_for(5000, function()
    return build._state.running
  end))
  assert(vim.deep_equal(build._last_builds[canon_h], { "compile" }), "compile lançado deveria gravar _last_builds")
  assert(jc_hist_store["build-last"] == "compile", "compile lançado deveria gravar jc build-last")
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
  assert(jc_hist_store["build-last"] == "compile", "tentativa rejeitada (running) não pode alterar jc build-last")
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
  assert(jc_hist_store["build-last"] == "compile", "jobstart<=0 não pode alterar jc build-last")
  assert(
    vim.deep_equal(run_config.load_last_build(canon_h), { "compile" }),
    "jobstart<=0 não pode alterar last_build em disco"
  )

  package.loaded["jc.settings"] = prev_jc_settings
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
