# java-menu.nvim

Menus de produtividade Java para Neovim, **complementar** ao
[jc.nvim](https://github.com/artur-shaik/jc.nvim) — que é **dependência
obrigatória**. Este plugin não inicia nem configura o JDTLS: ele detecta o
cliente que **você** já anexou ao projeto (nvim-jdtls, lspconfig, Mason —
por sua conta) e adiciona os menus sobre ele.

- New / Generate / Refactor / Imports / Build / Tests / Debug
- Preview de WorkspaceEdit antes de aplicar (rename/move com arquivos)
- Descoberta de módulos Maven/Gradle aninhados e Build isolado por projeto

## Requisitos

| Componente | Papel |
| --- | --- |
| jc.nvim | obrigatório — motor de operações Java (organize imports, generate, templates, descoberta de testes) |
| cliente JDTLS | obrigatório para operações semânticas — iniciado pela SUA configuração (nvim-jdtls/lspconfig); o plugin nunca cria um segundo servidor |
| snacks.nvim | opcional — seletores; sem ele cai em `vim.ui.select` |
| which-key.nvim | opcional — rótulo do grupo `<leader>j` |
| neotest + adaptador do jc.nvim | opcional — grupo Tests |
| nvim-dap + java-debug | opcional — grupo Debug |

## Instalação (lazy.nvim)

```lua
{
  "artur-shaik/jc.nvim",
  ft = { "java" },
  config = function() ... end, -- configuração do jc é sua
},
{
  "voce/java-menu.nvim",
  dependencies = { "artur-shaik/jc.nvim" },
  keys = {
    { "<leader>jn", function() require("java_menu").trigger("new") end, desc = "Java: New" },
    -- ou simplesmente:
    -- { "<leader>j", function() require("java_menu").setup() end, desc = "Java Menu" },
  },
},
```

O `setup()` do Java Menu não chama `setup()` do jc.nvim nem cria cliente
LSP — a configuração do jdtls/Mason/DAP continua no seu config.

## Configuração

```lua
require("java_menu").setup({
  prefix = "<leader>j",   -- prefixo dos atalhos
  groups = {              -- habilitar/desabilitar grupos
    new = true,
    generate = true,
    refactor = true,
    imports = true,
    build = true,
    tests = true,
    debug = true,
  },
  which_key = true,       -- registra rótulo do grupo se which-key existir
})
```

`setup()` é idempotente: reexecutar limpa os próprios atalhos/comando antes
de recriar. Atalhos de terceiros no mesmo `<leader>x` são **preservados** e
o conflito é informado via `vim.notify`. Nenhum módulo Java é carregado no
`setup()` — cada atalho exige seu módulo sob demanda.

Os atalhos são globais (não só `ft=java`): o menu funciona em `pom.xml`,
`build.gradle(.kts)` e em qualquer diretório de projeto Java.

## Comandos

| Atalho (padrão) | Grupo |
| --- | --- |
| `<leader>jn` | New (class/interface/record/enum/test...) |
| `<leader>jg` | Generate (constructor, getters/setters, toString, equals/hashCode, abstract methods) |
| `<leader>jr` | Refactor (rename, move, change signature — com preview) |
| `<leader>ji` | Imports (style, replace import) |
| `<leader>jb` | Build/Run (por projeto, módulos Maven/Gradle) |
| `<leader>jt` | Tests (neotest + adaptador do jc.nvim) |
| `<leader>jd` | Debug (nvim-dap + java-debug) |

`:JavaMenu [new|generate|refactor|imports|build|tests|debug]` — mesmo
acesso via comando.

## Testes

```sh
tests/java_menu/run.sh fast         # specs rápidos (sem JDTLS real)
tests/java_menu/run.sh integration  # JDTLS/DAP/Maven reais
tests/java_menu/run.sh all
```

Detalhes em `tests/java_menu/README.md`.

## Status

Extração inicial (6C.1) a partir de dotfiles pessoais. Sem publicação,
sem CI, sem remote. jc.nvim não é forkado nem modificado.
