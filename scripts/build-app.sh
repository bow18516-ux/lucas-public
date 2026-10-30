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

if [ -n "${LUCAS_VERSION:-}" ]; then
    VERSION="$LUCAS_VERSION"
else
    VERSION="$(sed -n 's/.*static let marketing = "\([^"]*\)".*/\1/p' "$ROOT/Sources/JaplosProtocol/ProductVersion.swift")"
fi
if [ -z "$VERSION" ]; then
    echo "cannot read ProductVersion.marketing" >&2
    exit 1
fi
BUILD_NUMBER="${LUCAS_BUILD:-$(date +%Y%m%d%H%M)}"
# Local ./scripts/build-app.sh often runs without publish.sh; still pick up the
# real feed from Config/release.env so 检查更新 does not hit example.com.
if [ -z "${LUCAS_FEED_URL:-}" ] && [ -f "$ROOT/Config/release.env" ]; then
    _feed="$(awk -F= '/^LUCAS_FEED_URL=/{
        sub(/^LUCAS_FEED_URL=/, "")
        gsub(/^"/, ""); gsub(/"$/, "")
        print
        exit
    }' "$ROOT/Config/release.env")"
    if [ -n "$_feed" ]; then
        LUCAS_FEED_URL="$_feed"
    fi
fi
FEED_URL="${LUCAS_FEED_URL:-https://updates.example.com/lucas/appcast.xml}"
if [[ "$FEED_URL" == *"example.com"* ]]; then
    echo "warning: SUFeedURL is still the placeholder ($FEED_URL); 检查更新 will fail until Config/release.env sets LUCAS_FEED_URL" >&2
fi
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

# SPM resource bundle required by Bundle.module (lucasd seeds prompts/skills).
# Without this, lucasd fatals: unable to find bundle named JaplosClone_JaplosRuntime
RUNTIME_BUNDLE=""
for cand in \
    "$BIN_DIR/JaplosClone_JaplosRuntime.bundle" \
    "$ROOT/.build/out/Products/$( [ "$CONFIG" = release ] && echo Release || echo Debug )/JaplosClone_JaplosRuntime.bundle" \
    "$ROOT/.build/$CONFIG/JaplosClone_JaplosRuntime.bundle"
do
    if [ -d "$cand" ]; then RUNTIME_BUNDLE="$cand"; break; fi
done
if [ -n "$RUNTIME_BUNDLE" ]; then
    rm -rf "$CONTENTS/Resources/JaplosClone_JaplosRuntime.bundle"
    cp -R "$RUNTIME_BUNDLE" "$CONTENTS/Resources/JaplosClone_JaplosRuntime.bundle"
    # CLI fallback when Bundle.main is the executable directory
    rm -rf "$CONTENTS/MacOS/JaplosClone_JaplosRuntime.bundle"
    cp -R "$RUNTIME_BUNDLE" "$CONTENTS/MacOS/JaplosClone_JaplosRuntime.bundle"
else
    echo "warning: JaplosClone_JaplosRuntime.bundle not found; lucasd may crash on start" >&2
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

sign_inside_out() {
    local identity="$1"
    local entitlements="${2:-}"
    local flags=(--force --sign "$identity")
    if [ "$identity" != "-" ]; then
        flags+=(--options runtime --timestamp)
    fi
    local extra=()
    if [ -n "$entitlements" ]; then
        extra=(--entitlements "$entitlements")
    fi
    # Sign nested code first. --deep is not a substitute for this order.
    if [ -d "$CONTENTS/Frameworks" ]; then
        while IFS= read -r -d '' item; do
            codesign "${flags[@]}" "$item"
        done < <(find "$CONTENTS/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' -o -type f -perm +111 \) -print0)
    fi
    if [ -d "$CONTENTS/MacOS" ]; then
        while IFS= read -r -d '' item; do
            [ "$item" = "$CONTENTS/MacOS/Lucas" ] && continue
            [ "$item" = "$CONTENTS/MacOS/JaplosApp" ] && continue
            codesign "${flags[@]}" "$item"
        done < <(find "$CONTENTS/MacOS" -type f -perm +111 -print0)
    fi
    codesign "${flags[@]}" "${extra[@]}" "$APP"
}

if [ -n "${LUCAS_SIGN_IDENTITY:-}" ]; then
    echo "signing with: $LUCAS_SIGN_IDENTITY"
    sign_inside_out "$LUCAS_SIGN_IDENTITY" "$ROOT/Config/Lucas.entitlements"
    codesign --verify --strict --verbose=2 "$APP"
else
    echo "warning: ad-hoc signing; Sparkle updates will not install until the app is signed with a Developer ID" >&2
    sign_inside_out - "$ROOT/Config/Lucas.entitlements" >/dev/null 2>&1 || true
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
