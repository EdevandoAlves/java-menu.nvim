#!/usr/bin/env bash
# Runner único dos testes do Java Menu.
#
# Uso (de qualquer diretório):
#   tests/java_menu/run.sh fast         # só os testes rápidos (sem JDTLS real)
#   tests/java_menu/run.sh integration  # só os testes com JDTLS/DAP/Maven reais
#   tests/java_menu/run.sh all          # fast + integration
#
# Variáveis de ambiente opcionais:
#   NVIM                                binário nvim (padrão: nvim no PATH)
#   JAVA_MENU_TEST_TIMEOUT_FAST         timeout por spec FAST em segundos (180)
#   JAVA_MENU_TEST_TIMEOUT_INTEGRATION  timeout por spec INTEGRATION em segundos (900)
#   JAVA_MENU_TEST_LOG_DIR              diretório de logs (/tmp/opencode/java-menu-tests/...)
#
# Cada spec roda em uma sessão própria de nvim --headless -u NONE -n
# (sem shada/viminfo), logo não há dependência de estado de sessões
# anteriores. Falhas imprimem a saída completa do nvim (stack trace
# incluído) e o runner termina com exit code != 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GROUP="${1:-fast}"

case "$GROUP" in
  fast | integration | all) ;;
  *)
    echo "uso: $0 [fast|integration|all]" >&2
    exit 2
    ;;
esac

NVIM="${NVIM:-nvim}"
command -v "$NVIM" >/dev/null 2>&1 || {
  echo "nvim não encontrado no PATH (ajuste NVIM=...)" >&2
  exit 2
}

LAZY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
LOG_DIR="${JAVA_MENU_TEST_LOG_DIR:-/tmp/opencode/java-menu-tests/run-$(date +%Y%m%d-%H%M%S)-$$}"
mkdir -p "$LOG_DIR"

TMO_FAST="${JAVA_MENU_TEST_TIMEOUT_FAST:-180}"
TMO_INTEGRATION="${JAVA_MENU_TEST_TIMEOUT_INTEGRATION:-900}"

TIMEOUT_BIN="timeout"
command -v timeout >/dev/null 2>&1 || TIMEOUT_BIN=""

# --- ambiente (registrado no início de cada execução) ----------------------

nvim_version="$("$NVIM" --headless -u NONE -n -c 'lua io.write(string.format("%d.%d.%d", vim.version().major, vim.version().minor, vim.version().patch), "\n")' -c qa! 2>/dev/null)"
jc_rev="ausente"
if [ -d "$LAZY_DIR/jc.nvim" ]; then
  jc_rev="$(git -C "$LAZY_DIR/jc.nvim" describe --tags --always 2>/dev/null \
    || git -C "$LAZY_DIR/jc.nvim" rev-parse --short HEAD 2>/dev/null \
    || echo "revisão desconhecida")"
fi
jdtls_path="$("$NVIM" --headless -u NONE -n -c 'lua io.write(vim.fn.exepath("jdtls") ~= "" and vim.fn.exepath("jdtls") or (vim.fn.stdpath("data").."/mason/bin/jdtls"), "\n")' -c qa! 2>/dev/null)"
[ -f "$jdtls_path" ] || jdtls_path="$jdtls_path (AUSENTE)"
mvn_state="$(command -v mvn >/dev/null 2>&1 && echo "$(command -v mvn)" || echo "AUSENTE")"

echo "== java_menu tests =="
echo "repo:      $REPO_DIR"
echo "nvim:      $nvim_version"
echo "jc.nvim:   $jc_rev"
echo "jdtls:     $jdtls_path"
echo "mvn:       $mvn_state"
echo "logs:      $LOG_DIR"
echo

# --- specs ------------------------------------------------------------------

# FAST: nada de servidor JDTLS real. jc.nvim real entra via rtp quando
# instalado (adaptador e jc.templates); mocks só simulam APIs ausentes.
FAST_SPECS=(
  capabilities_spec
  modules_spec
  setup_spec
  jc_compat_spec
  debug_project_spec
  move_destination_label_spec
  new_template_indent_spec
  preview_paths_spec
  preview_workspaceedit_spec
  project_gradle_spec
  project_nested_spec
  project_workspace_spec
)

# INTEGRATION: JDTLS real (lsp_clients, refactor_lsp, jdtls_projects inclui
# DAP attach) e processos Maven reais (build_isolation).
INTEGRATION_SPECS=(
  lsp_clients_spec
  refactor_lsp_spec
  jdtls_projects_spec
  build_isolation_spec
)

# --- execução ----------------------------------------------------------------

# rtp: config do Java Menu + plugins reais quando instalados. Diretórios
# ausentes são simplesmente omitidos (specs que dependem deles falham com
# mensagem clara ou pulam, conforme o próprio spec).
RTP=(-c "set rtp+=$REPO_DIR")
for p in nvim-jdtls nvim-lspconfig nvim-dap jc.nvim; do
  [ -d "$LAZY_DIR/$p" ] && RTP+=(-c "set rtp+=$LAZY_DIR/$p")
done

PASS=0
FAIL=0
FAILED_NAMES=()

# Processos dos testes: a linha de comando só casa com recursos criados pelos
# próprios specs (fixtures java-menu-* e workspaces jdtls-ws-*), nunca com um
# launcher jdtls genérico. Um processo é encerrado somente se (a) NÃO existia
# no snapshot anterior ao spec e (b) sobreviveu ao fim dele — ou seja, órfão
# nosso. Servidores de outras sessões existem antes do snapshot e nunca são
# tocados; processos sem identidade de teste conhecida nunca são mortos.
JDTLS_PAT='jdtls-ws-|java-menu-'

snapshot_pids() {
  pgrep -f "$JDTLS_PAT" 2>/dev/null | sort >"$1"
}

# Encerra somente PIDs novos (pós-spec) que não existiam no snapshot prévio.
kill_new_test_jdtls() {
  local pre="$1" post="$2" name="$3" killed=0
  local new_pids
  new_pids="$(comm -13 "$pre" "$post")"
  for pid in $new_pids; do
    kill "$pid" 2>/dev/null || continue
    killed=$((killed + 1))
  done
  if [ "$killed" -gt 0 ]; then
    sleep 1
    for pid in $new_pids; do
      kill -9 "$pid" 2>/dev/null || true
    done
    echo "aviso: $killed processo(s) jdtls órfão(s) do spec $name foram encerrados" >&2
  fi
}

run_spec() {
  local name="$1" timeout_s="$2"
  local log="$LOG_DIR/$name.log"
  local pre_pids="$LOG_DIR/$name.pre.pids"
  local post_pids="$LOG_DIR/$name.post.pids"
  printf '%-34s' "$name"
  snapshot_pids "$pre_pids"
  local t0 t1 rc
  t0=$(date +%s)
  # O spec roda via pcall(dofile): erro de assert NÃO pode ser mascarado por
  # um qa! posterior (com `-c luafile` + `-c qa!` o nvim sai 0 mesmo com
  # E5113 — falso PASS). Em falha: stack trace completo no log + cquit 1.
  local inner="local name_spec = '$name'
local ok, err = pcall(dofile, [[$SCRIPT_DIR/$name.lua]])
if ok then return end
io.stderr:write('[SPEC_ERROR] ' .. name_spec .. '\n' .. tostring(err) .. '\n')
vim.cmd('cquit 1')"
  if [ -n "$TIMEOUT_BIN" ]; then
    (cd "$REPO_DIR" && timeout --foreground "$timeout_s" "$NVIM" --headless -u NONE -n \
      "${RTP[@]}" -c "lua $inner" -c "qa!") >"$log" 2>&1
  else
    (cd "$REPO_DIR" && "$NVIM" --headless -u NONE -n \
      "${RTP[@]}" -c "lua $inner" -c "qa!") >"$log" 2>&1
  fi
  rc=$?
  t1=$(date +%s)
  snapshot_pids "$post_pids"
  kill_new_test_jdtls "$pre_pids" "$post_pids" "$name"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "PASS ($((t1 - t0))s)"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    echo "FAIL (exit=$rc, $((t1 - t0))s)"
    echo "---- saída completa: $name ----"
    cat "$log"
    echo "----------------------------------------------"
  fi
}

run_group() {
  local label="$1" timeout_s="$2"
  shift 2
  echo "== $label =="
  local name
  for name in "$@"; do
    run_spec "$name" "$timeout_s"
  done
  echo
}

# A limpeza de processos órfãos é por spec (snapshot-diff em run_spec) e só
# encerra processos iniciados pelos próprios testes.
if [ "$GROUP" = fast ] || [ "$GROUP" = all ]; then
  run_group "FAST (${#FAST_SPECS[@]} specs)" "$TMO_FAST" "${FAST_SPECS[@]}"
fi
if [ "$GROUP" = integration ] || [ "$GROUP" = all ]; then
  run_group "INTEGRATION (${#INTEGRATION_SPECS[@]} specs)" "$TMO_INTEGRATION" "${INTEGRATION_SPECS[@]}"
fi

echo "== resumo =="
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "falhas: ${FAILED_NAMES[*]}"
  echo "logs completos em $LOG_DIR"
  exit 1
fi
exit 0
