-- J (6B.4B): disponibilidade dos módulos/menus do Java Menu.
-- Cada módulo de lua/java_menu deve carregar em sessão limpa e expor suas
-- entradas públicas; o adaptador jc (quando jc.nvim está no rtp) deve estar
-- disponível. Os mapeamentos <leader>j ficam em lua/plugins/java.lua e
-- dependem do gerenciador de plugins — fora do escopo desta suíte (roda com
-- -u NONE).
--
-- Run:
--   tests/java_menu/run.sh fast

local jca = require("java_menu.jc")

local checked = 0

local function expect_fn(mod, name, label)
  assert(type(mod[name]) == "function", label .. ": " .. name .. " ausente ou não é função")
  checked = checked + 1
end

-- ---------- menus (entradas públicas usadas por <leader>j*) ----------

local new = require("java_menu.new")
expect_fn(new, "new", "menu New")
assert(type(new.kinds) == "table" and #new.kinds > 0, "new.kinds vazio")
for _, kind in ipairs(new.kinds) do
  assert(type(kind.label) == "string" and kind.label ~= "", "kind sem label")
  assert(type(kind.template) == "string", "kind sem template")
end

local generate = require("java_menu.generate")
expect_fn(generate, "generate", "menu Generate")

local refactor = require("java_menu.refactor")
expect_fn(refactor, "refactor", "menu Refactor")

local imports = require("java_menu.imports")
expect_fn(imports, "imports", "menu Imports")

local build = require("java_menu.build")
expect_fn(build, "build", "menu Build")
expect_fn(build, "output_provenance", "menu Build")

local tests_menu = require("java_menu.tests")
expect_fn(tests_menu, "tests", "menu Tests")
expect_fn(tests_menu, "inspect_results", "menu Tests")

local debug = require("java_menu.debug")
expect_fn(debug, "debug", "menu Debug")

local signature = require("java_menu.signature")
expect_fn(signature, "change_signature", "menu Change Signature")

local calls = require("java_menu.calls")
for _, name in ipairs({ "calls", "incoming", "outgoing", "cancel" }) do
  expect_fn(calls, name, "menu Call Hierarchy")
end

local types = require("java_menu.types")
for _, name in ipairs({ "types", "supertypes", "subtypes", "implementations", "cancel" }) do
  expect_fn(types, name, "menu Type Hierarchy")
end

local stacktrace = require("java_menu.stacktrace")
for _, name in ipairs({ "stacktrace", "cancel" }) do
  expect_fn(stacktrace, name, "menu Stack Trace")
end

-- ---------- infraestrutura ----------

local ui = require("java_menu.ui")
for _, name in ipairs({ "notify", "pick_one", "pick_many", "ask", "menu", "jdtls_attached", "has_parser" }) do
  expect_fn(ui, name, "ui")
end

local lsp = require("java_menu.lsp")
for _, name in ipairs({
  "clients",
  "client",
  "client_or_reason",
  "encoding",
  "capabilities",
  "jc_global_reason",
  "global_count",
}) do
  expect_fn(lsp, name, "lsp")
end

local preview = require("java_menu.preview")
for _, name in ipairs({ "plan", "review", "apply" }) do
  expect_fn(preview, name, "preview")
end

local project = require("java_menu.project")
for _, name in ipairs({
  "root",
  "modules",
  "discovery_limitation",
  "gradle_path",
  "source_roots",
  "workspace_id",
  "workspace_dir",
  "is_java_project",
}) do
  expect_fn(project, name, "project")
end

-- ---------- adaptador jc.nvim ----------

for _, name in ipairs({
  "replace_import_api",
  "read_build_last",
  "write_build_last",
  "import_style",
  "test_discovery_api",
  "jdtls_busy",
}) do
  expect_fn(jca, name, "java_menu.jc")
end

local ok_jc, jc = pcall(require, "jc.jdtls")
if ok_jc and type(jc) == "table" then
  -- jc.nvim real no rtp: adaptador precisa reportar disponibilidade e
  -- contratos válidos.
  local parts, err = jca.replace_import_api()
  assert(parts, "adaptador rejeitou o jc.nvim real: " .. tostring(err))
  local style, style_err = jca.import_style()
  assert(style, "adaptador sem import_style do jc real: " .. tostring(style_err))
  assert(
    type(style) == "table" and type(style.order) == "table" and #style.order > 0,
    "import_style sem lista de presets"
  )
  assert(type(style.load) == "function" and type(style.save) == "function", "import_style sem load/save chamáveis")
  local busy = jca.jdtls_busy()
  assert(busy == true or busy == false, "jdtls_busy deveria ser booleano")
else
  -- sem jc.nvim: adaptador deve reportar indisponibilidade com erro claro
  -- (nunca retorno parcial).
  local parts, err = jca.replace_import_api()
  assert(parts == nil and type(err) == "string" and #err > 0, "sem jc, replace_import_api deveria devolver nil,erro")
  print("[modules_spec] jc.nvim ausente — verificação de contratos pulada")
end

print(string.format("[modules_spec] OK: %d entradas públicas verificadas", checked))
