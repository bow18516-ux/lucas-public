---
name: install-application
description: Install or update Windows or macOS applications and verify the result. Use for requests to download and install software, finish an installation, or add a website as a web app (安装应用、安装软件、下载安装、更新应用、网页应用). Does not cover download-only requests, installing development dependencies, creating skills, uninstalling apps, or questions that only ask whether an app exists.
---

# Install an application

Take the requested application from a verified source to an observed installation result.
Preserve the requested product, version, browser, installation channel, and existing user data.
An installation request authorizes its ordinary steps; do not ask again before every tool call.
This workflow does not grant additional tool permissions.
If the user narrows the task to downloading only, stop after verifying the saved artifact;
do not open the installer or install the application.

## Establish the target

- Use `system.software.catalog.search` for the product name or alias, and
  `system.software.installed.list` to check existing copies. Resolve localized names through
  the catalog, then query the returned bundle identifiers or display name. A truncated list
  cannot establish absence. Reuse a suitable installed copy; distinguish installation,
  updating, and an explicitly requested reinstall.
- The catalog is a maintained identity map, not a live app store or an exhaustive list.
  No match means the product is not cataloged, not that a compatible version does not exist.
  Discover web search/browser tools and check the publisher's official site or store listing.
  Verify current host OS support, processor architecture, minimum OS, and the requested version.
  Read host information through available tools when compatibility is not already known.
- Distinguish an official native app, a third-party client, and a web app. If the requested
  native client is unavailable, explain the alternative and obtain the user's preference
  unless the conversation already authorizes it. Do not hardcode availability for products
  such as YouTube, or silently substitute a similarly named third-party application.

## Choose an available route

Tool names below are the fullTrust Kernel tools. If a tool is not exposed, use
`runtime.tool.search` to discover the capability and read its current schema. A skill or
catalog source does not prove an execution tool is available; never invent a tool or ID.

- On Windows, read [Windows installation](references/windows-install.md) for `.exe` or `.msi` installers. Do not use macOS routes on Windows.
- On macOS, for a cataloged `.app`, `.dmg`, or `.pkg`, read
  [Native installation](references/native-install.md) and use the dedicated software tools.
- For App Store, Homebrew, browser web apps, or a product outside the catalog, read
  [Other installation routes](references/other-routes.md) only when that route is needed.
- Prefer the user's chosen channel. Otherwise choose a supported official route compatible
  with the host and existing installation. Do not install an extra package manager or browser
  merely to avoid using an available installation route.

## Complete and report

Retain the download ID, plan ID, operation ID, target identity, and observed state in the
conversation so a follow-up can resume verification without starting another installation.
Check the current schema and state before acting on an old identifier. If it no longer
exists, inspect the installed target before preparing another operation.

Report the actual outcome: downloaded, waiting for a specific user action, installed and
verified, or failed with the next useful step. Include the installed path and version when
returned, and identify a web app as such. Installation verification does not establish that
login, activation, or first-run setup is complete. When the request includes opening or using
the app, launch the verified target and observe the result before reporting it usable.
