# Native installation

## Acquire the artifact

1. Resolve a real `softwareID` from `system.software.catalog.search`. Use the official source
   to resolve the current installer for the host. A homepage URL is not a download URL, and
   a package filename alone is not evidence of its version or publisher.
2. For a remote installer, use `system.download.start` with its actual schema, retain its ID,
   and check `system.download.get`. Only pass a succeeded download's `destinationPath` to
   installation. On an existing paused download, discover the resume capability instead of
   starting a duplicate. For a user-provided local artifact, inspect that file directly.
3. Choose `artifact.kind` from the actual artifact: `macos_application_bundle` for an unpacked
   `.app`, `macos_disk_image` for a `.dmg`, and `macos_installer_package` for a `.pkg`.
   An archive such as ZIP needs extraction and inspection through available tools first;
   changing its extension or labeling the archive as an application does not unpack it.

## Prepare and execute

Call `system.software.install.prepare` with `softwareID` and
`artifact: {kind, path, expectedVersion?}`. Supply `expectedVersion` only from verified release
metadata or the inspected artifact; interactive updates require it to distinguish the old app
from the requested version. Use the schema's scope values, not a guessed destination field.

Review the returned mechanism, destination, warnings, replacement and application-quit
requirements. Respect existing authorization for updating or closing the selected app; resolve
unexpected loss of work or a different destination before proceeding. Missing expected signing
identity in the catalog is a verification limitation, not proof of a trusted publisher. A valid
DMG checksum establishes integrity, not the publisher identity of its contents.

Use `system.software.install.execute` with the returned `planID` once. It starts an operation;
the returned operation ID is used by `system.software.operation.get`. Do not repeatedly execute
or prepare new plans merely to check progress. An expired, unexecuted plan needs fresh preparation.

## Observe completion

- `running`: continue observing the same operation with bounded waits under the task deadline.
  A tool returning successfully does not mean installation has finished.
- `waiting_for_user`: the current DMG/PKG executor opens the file in macOS and waits for the
  installed target to be observed. Inspect the actual window with available UI tools and
  continue ordinary authorized steps when supported. If system authentication or another
  user-only action is required, name the action and retain the operation ID. Stop polling
  unchanged state while waiting for input. Do not request passwords in chat.
- After the interaction, call `system.software.operation.get` on the same operation to verify.
  Merely opening an installer, mounting an image, closing a window, or obtaining exit code 0
  is not proof of installation.
- `succeeded`: use the verified result's application identity, path, and version in the response.
- `failed` or `cancelled`: inspect the failure and any recovery information. A non-retryable
  failure ends this attempt; do not restart the same action in the run. Retry a recoverable
  operation only after resolving its cause, and inspect the target first to avoid duplicates.

Never respond to an identity mismatch or denied operation by disabling platform checks,
removing quarantine, re-signing the publisher's app, or routing the same denied mutation through
a shell. Discovering an execution tool does not override Kernel authorization.
