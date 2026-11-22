# Phase 8 navigation evaluation

## Scope and evidence

The following checks use local Neovim and a real JDTLS server, with temporary,
synthetic Maven projects; they are not observations from a contributor's
existing application or a human usability study.

- `call_hierarchy_real_spec.lua` exercises incoming and outgoing calls through
  the plugin's picker, including two isolated JDTLS projects, and probes virtual
  JDK source URIs.
- `type_hierarchy_real_spec.lua` exercises supertype and subtype navigation
  through the picker, with interfaces, inheritance and two isolated projects.
- `hierarchy_multimodule_real_spec.lua` builds an `api` / `service` Maven
  reactor offline, starts JDTLS on the aggregator, and navigates in both
  directions across modules using incoming calls, outgoing calls, supertypes,
  subtypes and implementations. The test checks destination files and cursor
  positions. Its picker selections are scripted rather than made by a person.
- `calls_spec.lua` and `types_spec.lua` cover cancellation, stale callbacks,
  unsupported capabilities, errors and multiple clients with simulated LSP
  responses. Their cancellation checks do not establish JDTLS performance or
  server-side cancellation behavior on large projects.

On the local Linux test environment, the real menu flows completed within their
15-second result waits after the JDTLS index became ready. These are test
bounds, not latency measurements or guarantees; performance in large projects,
Gradle composite builds and remote environments remains unmeasured. Test
runners report missing JDTLS prerequisites as skips.

## Findings and decision

The scripted menus displayed a symbol, module-relative path and source position
sufficient to select the expected result in the test fixtures. No human
participant evaluated the clarity of those labels, and no contributor feedback
was available for this assessment. Existing limitations around JDTLS indexing,
virtual `jdt://` buffers, and partial platform coverage are documented in the
README.

No additional navigation UI is justified by these observations alone. In
particular, defer persistent trees and filtering until a concrete project or
user report demonstrates a need. Gather feedback and test a larger existing
project before proposing changes; create a separate issue for any independently
verified problem or accepted enhancement.
