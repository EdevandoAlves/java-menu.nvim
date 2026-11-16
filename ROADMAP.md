# Roadmap

This is a short direction document, not a product specification. The README
documents what exists today.

## Completed

- **6E — Stability.** Fixed `Generate → toString()` and `equals()`/`hashCode()`,
  validated Move Class package/directory/reference handling, added Explicit
  Static Import integration, confirmed Extract Constant in an eligible
  scenario, and added Constructor (Select Fields), All-Args and No-Args flows.
- **6F — Standardization.** English-only UI, documentation and comments,
  consistent terminology, README/help refresh and validation notes.

## Planned

- **7A — Architecture.** Clarify module boundaries and reduce coupling where
  the current behavior allows it without changing the UX.
- **7B — Project Management.** Project-level actions and workspace awareness.
- **7C — Dependency Management.** Inspect and explain project dependencies from
  the build files, without becoming a build tool.
- **7D — Run Experience.** Improve run/debug output and process lifecycle.
- **7E — IDE Workflow Ergonomics.** Small workflow improvements that fit
  Neovim rather than copying IntelliJ.

## Known limitations

- Rename Package and Move Package remain disabled: current jdtls exposes no
  supported path for them.
- Static Import depends on a jdtls quick assist that requires a selected
  member range; the menu provides that range, but upstream behavior is still
  the controlling factor.
- Gradle module discovery is static; dynamic `settings.gradle(.kts)` logic is
  reported as partial instead of being evaluated.
- The plugin intentionally continues to build on jc.nvim while it provides
  concrete value, rather than reimplementing its Java engine.

## Principles

- Workflow-first.
- Integration over reinvention.
- Neovim-native.
- No pursuit of IntelliJ parity.
- Keep leveraging jc.nvim where it is the better implementation.
