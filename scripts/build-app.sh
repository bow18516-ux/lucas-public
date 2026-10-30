#!/bin/bash
# Builds Lucas.app from the SwiftPM package.
#
# Environment:
#   LUCAS_VERSION        marketing version (default 0.4.0)
#   LUCAS_BUILD          CFBundleVersion, must increase per release
#   LUCAS_FEED_URL       Sparkle appcast URL embedded in Info.plist
#   LUCAS_SIGN_IDENTITY  e.g. "Developer ID Application: Name (TEAMID)"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Lucas.app"
CONTENTS="$APP/Contents"

VERSION="${LUCAS_VERSION:-0.4.0}"
BUILD_NUMBER="${LUCAS_BUILD:-$(date +%Y%m%d%H%M)}"
FEED_URL="${LUCAS_FEED_URL:-https://updates.example.com/lucas/appcast.xml}"
AUTO_CHECKS="false"
if [ -n "${LUCAS_ENABLE_AUTO_UPDATES:-}" ]; then AUTO_CHECKS="true"; fi
PUBLIC_KEY="$(tr -d '\n' < "$ROOT/Config/sparkle_public_key.txt" 2>/dev/null || true)"
if [ -z "$PUBLIC_KEY" ]; then
    echo "warning: Config/sparkle_public_key.txt is missing; updates will not verify" >&2
fi

cd "$ROOT"
swift build --disable-sandbox -c "$CONFIG" --product JaplosApp
swift build --disable-sandbox -c "$CONFIG" --product lucasd

BIN_DIR="$ROOT/.build/$CONFIG"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"

cp "$BIN_DIR/JaplosApp" "$CONTENTS/MacOS/Lucas"
cp "$BIN_DIR/lucasd" "$CONTENTS/MacOS/lucasd"
if [ -f "$ROOT/Assets/AppIcon.icns" ]; then
    cp "$ROOT/Assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# Modular Japlos prompt pack + scenes (also embedded via SPM Bundle.module in lucasd)
PROMPT_SRC="$ROOT/Sources/JaplosRuntime/Resources"
if [ -d "$PROMPT_SRC/Prompts" ]; then
    rm -rf "$CONTENTS/Resources/Prompts"
    cp -R "$PROMPT_SRC/Prompts" "$CONTENTS/Resources/Prompts"
fi
if [ -d "$PROMPT_SRC/Injection" ]; then
    rm -rf "$CONTENTS/Resources/Injection"
    cp -R "$PROMPT_SRC/Injection" "$CONTENTS/Resources/Injection"
fi
if [ -d "$PROMPT_SRC/BuiltinSkills" ]; then
    rm -rf "$CONTENTS/Resources/BuiltinSkills"
    cp -R "$PROMPT_SRC/BuiltinSkills" "$CONTENTS/Resources/BuiltinSkills"
fi

# First-run guidance tones (optional preview in onboarding)
AWAKEN_SRC="$ROOT/Sources/JaplosApp/Resources/Awakening"
if [ -d "$AWAKEN_SRC" ]; then
    rm -rf "$CONTENTS/Resources/Awakening"
    cp -R "$AWAKEN_SRC" "$CONTENTS/Resources/Awakening"
fi
chmod +x "$CONTENTS/MacOS/Lucas" "$CONTENTS/MacOS/lucasd"

# Sparkle ships as a framework next to the executable.
if [ -d "$BIN_DIR/Sparkle.framework" ]; then
    cp -R "$BIN_DIR/Sparkle.framework" "$CONTENTS/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/Lucas" 2>/dev/null || true
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/lucasd" 2>/dev/null || true
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Lucas Agent</string>
    <key>CFBundleDisplayName</key>
    <string>Lucas Agent</string>
    <key>CFBundleIdentifier</key>
    <string>com.lucas.app</string>
    <key>CFBundleExecutable</key>
    <string>Lucas</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Lucas 把你的语音转成文字，用于对话。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Lucas 根据你的请求操作其他应用。</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Lucas 根据你的请求截取屏幕。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Lucas 使用麦克风进行语音输入。</string>
    <key>SUFeedURL</key>
    <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <${AUTO_CHECKS}/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
</dict>
</plist>
PLIST

# Local HTTP feeds are only for development; production uses HTTPS.
if [[ "$FEED_URL" == http://* ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUAllowsInsecureUpdates bool true" "$CONTENTS/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$CONTENTS/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$CONTENTS/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$CONTENTS/Info.plist" 2>/dev/null || true
fi

if [ -n "${LUCAS_SIGN_IDENTITY:-}" ]; then
    echo "signing with: $LUCAS_SIGN_IDENTITY"
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ROOT/Config/Lucas.entitlements" \
        --sign "$LUCAS_SIGN_IDENTITY" "$APP" >/dev/null
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    echo "warning: ad-hoc signing; Sparkle updates will not install until the app is signed with a Developer ID" >&2
    codesign --force --deep --entitlements "$ROOT/Config/Lucas.entitlements" --sign - "$APP" >/dev/null 2>&1 || true
fi

# Rebuilding replaces the bundle inode; refresh LaunchServices so Finder and
# `open` resolve the new copy instead of a stale record.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

echo "built: $APP"
echo "version: $VERSION ($BUILD_NUMBER)"
echo "feed: $FEED_URL"
echo "launch: open \"$APP\""
