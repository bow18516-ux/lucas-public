# Windows installation

Use the current host and tool schemas. Search the software catalog and installed inventory
before downloading. A catalog miss does not establish that Windows support is unavailable.
Obtain the installer from the verified publisher website, respecting architecture and version.
For non-cataloged software, discover available browser/desktop tools; do not invent a catalog ID.

Use system.download.start and system.download.get; proceed only after a succeeded download.
Use windows_executable for an EXE and windows_installer_package for an MSI. Do not pass a
web page, ZIP, macOS package, or incomplete download as an installer.

Call system.software.install.prepare with the catalog softwareID and artifact path.
Updates require replaceExisting=true and an independently verified expectedVersion.
Review plan warnings and requested scope. Execute the returned plan once, retain its operation ID,
and inspect system.software.operation.get. Windows opens the vendor installer; opening the UI
is not success. Complete supported desktop UI steps, selecting the requested installation scope.
If UAC or vendor UI requires the user, report that precise action and retain the operation ID.
Do not repeatedly execute the same installer or poll unchanged waiting states.

Recheck the same operation after UI completion. Success requires Windows installed-product
registration matching the catalog product and publisher, plus expectedVersion when supplied.
An old version does not prove an update completed. If the registration is missing or ambiguous,
report that verification remains incomplete rather than claiming success. Launching, login,
and activation require separate observations if requested. Uninstall uses Windows installed-app
settings and verifies removal of the selected registration; do not delete application directories.
