#!/bin/bash
# Assemble ToastMonitor.app from the SwiftPM release build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Xcode 27's default SwiftPM build engine currently writes the deployment
# target into LC_BUILD_VERSION's SDK field. AppKit interprets that as a legacy
# SDK link and deliberately serves compatibility controls. The native engine
# preserves the macOS 14 deployment target while correctly recording the
# Xcode 27 SDK, which enables system Liquid Glass on macOS 26/27.
SWIFT_BUILD=(swift build --build-system native)
BIN="$("${SWIFT_BUILD[@]}" -c release --show-bin-path)/ToastMonitor"
APP="$ROOT/dist/ToastMonitor.app"

# A release's marketing version is sourced from the tag (v1.0, v1.2.3, ...).
# CI may inject TM_VERSION after checking out an exact tag.  Untagged source
# remains explicitly a development build at 1.0; commit hashes never become a
# user-facing CFBundleShortVersionString.
TAG_VERSION="$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"
RAW_VERSION="${TM_VERSION:-${TAG_VERSION#v}}"
VERSION="${RAW_VERSION#v}"
if [[ -z "$VERSION" ]]; then VERSION="1.0"; fi
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "error: TM_VERSION/tag must be semantic numeric version (for example 1.0 or 1.2.3): $VERSION" >&2
    exit 1
fi
BUILD_VERSION="${TM_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || true)}"
if [[ -z "$BUILD_VERSION" || ! "$BUILD_VERSION" =~ ^[0-9]+$ || "$BUILD_VERSION" == "0" ]]; then
    BUILD_VERSION="1"
fi
VERSION_SOURCE="${TM_VERSION_SOURCE:-${TAG_VERSION:-development}}"

echo "== building (if needed) =="
"${SWIFT_BUILD[@]}" -c release

SDK_VERSION="$(vtool -show-build "$BIN" | awk '/^[[:space:]]*sdk / { print $2; exit }')"
SDK_MAJOR="${SDK_VERSION%%.*}"
if [[ -z "$SDK_VERSION" || ! "$SDK_MAJOR" =~ ^[0-9]+$ || "$SDK_MAJOR" -lt 26 ]]; then
    echo "error: release binary is linked as SDK ${SDK_VERSION:-unknown}; macOS 26+ UI requires SDK 26 or newer" >&2
    exit 1
fi
echo "linked SDK: $SDK_VERSION"

echo "== assembling bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ToastMonitor</string>
    <key>CFBundleDisplayName</key><string>ToastMonitor</string>
    <key>CFBundleIdentifier</key><string>com.toast.toastmonitor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>ToastMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Local networking is permitted for explicitly configured private
             feeds; clients still validate the URL before making a request. -->
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
    <key>NSHumanReadableCopyright</key><string>© 2026 Toast</string>
</dict>
</plist>
PLIST

# Replace only the numeric bundle fields after validating the source above.
echo "version: $VERSION (build $BUILD_VERSION; source $VERSION_SOURCE)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$APP/Contents/Info.plist"

cp "$BIN" "$APP/Contents/MacOS/ToastMonitor"

echo "== installing supplied icon =="
ICON_SOURCE="${TM_ICON_PATH:-}"
if [[ -z "$ICON_SOURCE" ]]; then
    for candidate in \
        "$ROOT/artifacts/ToastMonitor.icns" \
        "$ROOT/artifacts/ToastMonitor-Icon/ToastMonitor.icns"; do
        if [[ -f "$candidate" ]]; then ICON_SOURCE="$candidate"; break; fi
    done
fi
if [[ -z "$ICON_SOURCE" || ! -f "$ICON_SOURCE" ]]; then
    echo "error: supplied artifacts/ToastMonitor.icns is missing" >&2
    exit 1
fi
cp "$ICON_SOURCE" "$APP/Contents/Resources/AppIcon.icns"
echo "icon: $ICON_SOURCE"
echo "== code signing =="
# Unlocking a keychain with a password on the command line leaks that secret
# to process observers. Release tooling must unlock/select the keychain before
# invoking this script.
SIGNING_IDENTITY="${TM_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    # Prefer an Apple Development identity locally: its Team ID gives
    # Keychain ACLs a stable partition across rebuilt binaries. CI/release
    # callers still provide TM_SIGNING_IDENTITY explicitly.
    while IFS= read -r identity_line; do
        if [[ "$identity_line" == *'"Apple Development:'* ]]; then
            SIGNING_IDENTITY="${identity_line#*\"}"
            SIGNING_IDENTITY="${SIGNING_IDENTITY%%\"*}"
            break
        fi
    done <<< "$AVAILABLE_IDENTITIES"
    if [[ -z "$SIGNING_IDENTITY" && "$AVAILABLE_IDENTITIES" == *'"Spotoast Local Dev"'* ]]; then
        SIGNING_IDENTITY="Spotoast Local Dev"
    fi
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "error: no stable signing identity found; refusing ad-hoc signing" >&2
    echo "       set TM_SIGNING_IDENTITY to a Developer ID identity" >&2
    exit 1
fi
echo "signing identity: $SIGNING_IDENTITY"
TIMESTAMP_FLAG=(--timestamp)
if [[ "${TM_CODESIGN_TIMESTAMP:-}" == "none" ]]; then
    TIMESTAMP_FLAG=(--timestamp=none)
fi
codesign --force --options runtime "${TIMESTAMP_FLAG[@]}" --sign "$SIGNING_IDENTITY" "$APP"

echo "== installing to /Applications =="
if [[ "${CI:-}" == "true" ]]; then
    echo "skipping install to /Applications (CI environment)"
else
    WAS_RUNNING=0
    if pgrep -x ToastMonitor >/dev/null; then
        WAS_RUNNING=1
        echo "ToastMonitor is running; quitting before install"
        pkill -x ToastMonitor || true
        # pkill returns before the process is actually gone; wait for it.
        for _ in 1 2 3 4 5; do
            pgrep -x ToastMonitor >/dev/null || break
            sleep 1
        done
    fi
    ditto "$APP" /Applications/ToastMonitor.app
    echo "installed: /Applications/ToastMonitor.app"
    if [[ "$WAS_RUNNING" == "1" ]]; then
        echo "relaunching ToastMonitor"
        open -a /Applications/ToastMonitor.app
    fi
fi

echo "== done: $APP =="
