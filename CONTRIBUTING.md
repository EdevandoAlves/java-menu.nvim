# Contributing

Contributions are welcome. Start with an [open issue](https://github.com/EdevandoAlves/java-menu.nvim/issues), including those labeled `good first issue` or `help wanted`. For larger changes, describe the intended approach in the issue before starting so the scope and compatibility trade-offs can be discussed.

java-menu.nvim aims for workflows that feel native to Neovim. It integrates with jc.nvim and a user-managed JDTLS rather than replacing them. Keep existing keymaps and user configuration intact, expose unavailable actions with a useful reason, and favor small changes that work with existing tools.

## Development prerequisites

The fast suite needs Neovim and jc.nvim. It searches for jc.nvim under `${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/jc.nvim`. The CI workflow pins the versions used for its checks; consult `.github/workflows/ci.yml` if reproducing CI. Optional dependencies and their effects are listed in the README.

## Checks

Run these from the repository root:

```sh
tests/java_menu/run.sh fast
stylua --check lua tests
XDG_CONFIG_HOME=/tmp/java-menu-empty-config XDG_DATA_HOME=/tmp/java-menu-empty-data \
  nvim --headless -u NONE -n -c "set rtp+=$PWD" \
  -c "lua local ok, err = pcall(dofile, 'tests/java_menu/help_check.lua'); if not ok then print(err); vim.cmd('cquit 1') end" -c "qa!"
```

The integration suite is optional for documentation-only changes and exercises real tools:

```sh
tests/java_menu/run.sh integration
```

It may require a JDK, Maven, Gradle, JDTLS, nvim-dap and the java-debug bundle; the Spring Initializr test also needs network access, `curl` or `wget`, and `unzip`. Some checks explicitly skip when optional tools or network access are unavailable. Read the runner summary and logs: a skip is not a pass. Do not install or run extra services just to contribute a small change.

## Pull requests

Describe the problem and resulting behavior, link the relevant issue, and include the checks you ran. Report skips, missing tools, platform constraints and any manual steps accurately. Add focused tests when changing behavior, keep documentation and help consistent, and avoid unrelated reformatting. If a feature depends on upstream JDTLS or jc.nvim behavior, explain which contract and versions you verified.
