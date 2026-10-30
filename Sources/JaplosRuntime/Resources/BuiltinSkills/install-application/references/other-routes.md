# Other installation routes

Use the route authorized by the user and supported by tools discovered in this session.
The native software executor accepts cataloged `.app`, `.pkg`, and `.dmg` artifacts only.
Do not pass a website, App Store URL, Homebrew cask name, or invented softwareID as an artifact.

## Browser web app

Check the website's current official offering and the chosen browser's installation support
on this host. Use available browser or desktop UI tools to create the web app through the
browser's supported interface. Use the existing preferred browser when it supports the route.

Identify the official HTTPS origin, observe the installation command and dialog, and inspect
existing entries before creating another. Verify that the resulting launch entry exists and
opens the intended origin in its app window. A bookmark, downloaded HTML file, or normal browser
tab is not proof that a web app was installed. Report the browser and web app explicitly;
native-client features such as offline access must not be assumed.

## App Store

Verify the listing's publisher and macOS compatibility. Open the exact listing using available
tools and observe installation progress. Account login, purchase, or system confirmation may
require the user; retain the target and resume observation afterward. Opening a store listing
does not establish installation. Check the resulting installed app's identity and version.

## Homebrew

Use an already available Homebrew installation when this is the selected route. Resolve the
exact cask and check its current publisher, homepage, artifact, and installed state before
running commands through a discovered tool. Do not guess a cask name from the product name,
install a new package manager implicitly, or upgrade unrelated packages. Verify both the
package-manager result and the installed application; command success alone is insufficient.

## Product outside the software catalog

Continue source research through the official publisher. Do not modify the maintained catalog
or invent catalog identities during a user's install task. If an available, authorized browser,
UI, or package-manager route supports the installation, use it and verify the resulting target.
If no supported route is available, report the exact missing capability and a verified next
step. Distinguish an unavailable tool from an unavailable Mac application. Do not repeatedly
try the catalog-only executor with an unknown product.
