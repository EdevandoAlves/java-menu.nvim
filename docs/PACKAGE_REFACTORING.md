# Package refactoring investigation

Issue #10 investigated whether Java package rename and move can be offered
through supported JDTLS APIs. The menu keeps both actions disabled pending a
verified Java-aware operation; moving a class is a separate supported flow.

The existing local JDTLS 1.63 investigation found that package
`prepareRename` rejected the operation and a direct rename did not produce a
usable package refactoring. Those observations are specific to that version
and scenario, not a claim that all future servers will behave identically.

The upstream JDTLS [MoveHandler at commit
`99f2f2f`](https://github.com/eclipse-jdtls/eclipse.jdt.ls/blob/99f2f2f05bac1476f4e270cb79a4b7711d327ed9/org.eclipse.jdt.ls.core/src/org/eclipse/jdt/ls/core/internal/handlers/MoveHandler.java)
lists resource, method, member and type move kinds, but no package move kind.
Its resource move path handles compilation units. A package destination for a
class move is not evidence of a package refactoring. The upstream
[RenameHandler at the same commit](https://github.com/eclipse-jdtls/eclipse.jdt.ls/blob/99f2f2f05bac1476f4e270cb79a4b7711d327ed9/org.eclipse.jdt.ls.core/src/org/eclipse/jdt/ls/core/internal/handlers/RenameHandler.java)
implements the generic text-document rename request; inspection did not
establish a package-specific text-document rename path. However, the JDTLS
[file-event handler at the same commit](https://github.com/eclipse-jdtls/eclipse.jdt.ls/blob/99f2f2f05bac1476f4e270cb79a4b7711d327ed9/org.eclipse.jdt.ls.core/src/org/eclipse/jdt/ls/core/internal/handlers/FileEventHandler.java)
handles renamed source folders via `workspace/willRenameFiles` and computes
package rename edits using JDT's rename processor, with reference and
subpackage updates. This is a candidate for package rename, subject to
capability negotiation and validation against a real JDTLS server. The source
distinguishes this from moving a package to another package, which it says JDT
does not support. The
[nvim-jdtls documentation](https://github.com/mfussenegger/nvim-jdtls#extensions)
does not document a separate package-refactoring API. Upstream discussion of
the original client-side question is tracked in [JDTLS discussion
#3269](https://github.com/eclipse-jdtls/eclipse.jdt.ls/discussions/3269).
A filesystem rename or a `RenameFile` edit
alone does not demonstrate Java-aware package and reference updates.

Validate the file-rename request with a real JDTLS workspace containing
references, subpackages and multiple source roots. Determine whether the
returned edits include file operations or require a separately planned folder
rename; do not apply either before review. A local probe against JDTLS
`1.63.0-SNAPSHOT` returned text edits for package declarations and references,
including a subpackage and references in another source root, but no resource
operation to rename the directory. Applying only those edits left the source
files under their original path. The probe is evidence for the candidate API,
not a complete safe implementation. A future implementation must negotiate
`workspace.fileOperations.willRename`, validate the old and new directories,
request the edits before any filesystem change, combine them with a planned
directory rename, and show both in the existing preview. Its integration
tests should exercise the returned edits and directory operation together in
an isolated workspace, including subpackages, references in another source
root and non-Java resources. Require a complete reviewable WorkspaceEdit and
directory operation, check destination and
package declarations, and test collisions, cancellation, modified buffers and
stale plans before enabling the menu actions. If no supported operation exists,
keep the actions disabled with a clear reason.
