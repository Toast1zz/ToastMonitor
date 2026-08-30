#!/bin/bash
# Assemble ToastMonitor.app from the SwiftPM release build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# TM_DEPLOY_MIN controls the installability floor in Info.plist
# (LSMinimumSystemVersion). The source and SwiftPM minimum are already macOS
# 13.0, so the default build is a Ventura-compatible artifact; setting
# TM_DEPLOY_MIN=14.0 raises only the install gate for a future 14+-only
# release, leaving the binary (and its 13.0 minos) unchanged.

# TM_ARCHS ("arm64", "arm64 x86_64", ...) overrides the host architecture so
# releases can ship a universal binary. Defaults to the build machine.
if [[ -n "${TM_ARCHS:-}" ]]; then
    for arch in $TM_ARCHS; do SWIFT_BUILD+=(--arch "$arch"); done
fi
BIN="$("${SWIFT_BUILD[@]}" -c release --show-bin-path)/ToastMonitor"
APP="$ROOT/dist/ToastMonitor.app"
INSTALL_APP="${TM_INSTALL_PATH:-/Applications/ToastMonitor.app}"
SKIP_INSTALL="${TM_SKIP_INSTALL:-0}"

# A release's marketing version is sourced from the tag (v1.0, v1.2.3, ...).
# CI may inject TM_VERSION after checking out an exact tag.  Untagged source
# remains explicitly a development build at 1.0; commit hashes never become a
# user-facing CFBundleShortVersionString.
# Only an exact tag hit (HEAD == vX.Y.Z) or an explicit TM_VERSION is a
# release build. `git describe --abbrev=0` would return the NEAREST REACHABLE
# tag for untagged commits, making dev builds masquerade as the last release
# (and silently disabling update checks via a fake current version).
TAG_VERSION="$(git describe --tags --match 'v[0-9]*' --exact-match 2>/dev/null || true)"
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

# The 1.0 fallback above is deliberate, but it is a trap immediately after a
# release: the tag sits on the release commit while HEAD is the "Publish
# update manifest" commit that follows it, so a plain build on main quietly
# installs 1.0 over a 1.9.x install. The in-app updater then sees the
# published release as newer and offers it — one click from replacing the
# build you just made. Never change the version to compensate; just say so.
# Silent in CI, where nothing is installed and the version is irrelevant.
if [[ -z "$TAG_VERSION" && -z "${TM_VERSION:-}" && "${CI:-}" != "true" ]]; then
    NEAREST_TAG="$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"
    if [[ -n "$NEAREST_TAG" ]]; then
        AHEAD="$(git rev-list --count "$NEAREST_TAG..HEAD" 2>/dev/null || echo '?')"
        # Anything changed since the tag other than the published manifest.
        NON_MANIFEST="$(git diff --name-only "$NEAREST_TAG..HEAD" 2>/dev/null \
            | grep -v '^\(docs/\)\?appcast\.json$' || true)"
        echo "warning: HEAD is $AHEAD commit(s) past $NEAREST_TAG — development build $VERSION" >&2
        if [[ -z "$NON_MANIFEST" ]]; then
            echo "         (HEAD only publishes ${NEAREST_TAG}'s update manifest; the code is ${NEAREST_TAG}'s)" >&2
        fi
        if [[ "$SKIP_INSTALL" != "1" ]]; then
            echo "         Installing this reports $VERSION, below the published ${NEAREST_TAG#v}, so the" >&2
            echo "         in-app updater will offer that release and one click reverts this build." >&2
        fi
        echo "         For a real version: git checkout $NEAREST_TAG && ./scripts/build-app.sh" >&2
        echo "         (or tag this commit, or set TM_VERSION explicitly)" >&2
    fi
fi

echo "== building (if needed) =="
"${SWIFT_BUILD[@]}" -c release

# Multi-arch builds take the highest SDK across slices; SwiftPM links both
# slices of an arm64+x86_64 build against the 14.0 compatibility layer, so
# the strict SDK 26 check applies to single-arch (arm64) artifacts only.
SDK_VERSION="$(vtool -show-build "$BIN" | awk '/^[[:space:]]*sdk / { print $2 }' | sort -n | tail -1)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if [[ -z "$SDK_VERSION" || ! "$SDK_MAJOR" =~ ^[0-9]+$ || "$SDK_MAJOR" -lt 26 ]]; then
    if [[ "$TM_ARCHS" == *"x86_64"* ]]; then
        echo "warning: universal build links as SDK $SDK_VERSION (SwiftPM multi-arch limitation); macOS 26+ UI falls back to compatibility controls, functionality unaffected" >&2
    else
        echo "error: release binary is linked as SDK ${SDK_VERSION:-unknown}; macOS 26+ UI requires SDK 26 or newer" >&2
        exit 1
    fi
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
    <key>LSMinimumSystemVersion</key><string>13.0</string>
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
DEPLOY_MIN="${TM_DEPLOY_MIN:-13.0}"
if [[ ! "$DEPLOY_MIN" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "error: TM_DEPLOY_MIN must be X.Y (e.g. 13.0), got: $DEPLOY_MIN" >&2
    exit 1
fi
plutil -replace LSMinimumSystemVersion -string "$DEPLOY_MIN" "$APP/Contents/Info.plist"

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
# A locked login keychain would block codesign on an invisible password
# sheet. Fail fast with guidance instead; the one-time authorization also
# unlocks the keychain, so after `scripts/authorize-local-keychain.sh` has
# been run once, rebuilds stay silent.
KEYCHAIN="${TM_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
if [[ ! -f "$KEYCHAIN" ]]; then
    echo "error: keychain not found: $KEYCHAIN" >&2
    exit 1
fi
if ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
    echo "error: keychain is locked: $KEYCHAIN" >&2
    echo "       run ./scripts/authorize-local-keychain.sh once to unlock and authorize rebuilds" >&2
    exit 1
fi
# Unlocking a keychain with a password on the command line leaks that secret
# to process observers. Release tooling must unlock/select the keychain before
# invoking this script.
SIGNING_IDENTITY="${TM_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    # Prefer a stable Apple Development Team identity. ToastMonitor's three
    # login-keychain items authorize this Team ID, so rebuilt binaries remain
    # trusted even though their CDHash changes. A self-signed identity has no
    # Team ID and falls back to a per-build CDHash, causing one password sheet
    # per credential after every install.
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

echo "== installing locally =="
if [[ "${CI:-}" == "true" ]]; then
    echo "skipping install (CI environment)"
elif [[ "$SKIP_INSTALL" == "1" ]]; then
    echo "skipping install (TM_SKIP_INSTALL=1)"
else
    TARGET_EXECUTABLE="$INSTALL_APP/Contents/MacOS/ToastMonitor"
    RUNNING_PIDS=()
    while read -r pid command; do
        if [[ "$command" == "$TARGET_EXECUTABLE" ]]; then
            RUNNING_PIDS+=("$pid")
        fi
    done < <(ps -axo pid=,comm=)
    WAS_RUNNING=0
    if [[ "${#RUNNING_PIDS[@]}" -gt 0 ]]; then
        WAS_RUNNING=1
        echo "ToastMonitor is running; quitting before install"
        kill "${RUNNING_PIDS[@]}" || true
        # SIGTERM returns before the target bundle's process is actually gone.
        for _ in 1 2 3 4 5; do
            STILL_RUNNING=0
            for pid in "${RUNNING_PIDS[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then STILL_RUNNING=1; fi
            done
            [[ "$STILL_RUNNING" == "0" ]] && break
            sleep 1
        done
    fi
    mkdir -p "$(dirname "$INSTALL_APP")"
    ditto "$APP" "$INSTALL_APP"
    echo "installed: $INSTALL_APP"
    if [[ "$WAS_RUNNING" == "1" ]]; then
        echo "relaunching ToastMonitor"
        open "$INSTALL_APP"
    fi
fi

echo "== done: $APP =="
