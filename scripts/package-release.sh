#!/bin/bash
# Build release artifacts for GitHub Releases.
#
# Default: both arm64 and universal apps. The architecture-aware appcast
# selects arm64 for Apple Silicon and universal for Intel. build-app.sh
# builds each universal slice separately and merges them with lipo, so both
# artifacts record the current SDK and get the native macOS 26/27 look.
#
# Set TM_ARM64_ONLY=1 for a local/internal arm64-only package.
#
# Usage: ./scripts/package-release.sh
# Produces dist/release/ToastMonitor-<version>-arm64.zip
#   and dist/release/ToastMonitor-<version>-universal.zip (unless TM_ARM64_ONLY=1)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty; package from a clean checkout" >&2
    exit 1
fi

# Only an exact tag hit is a release version (see build-app.sh). Packaging an
# untagged commit as 1.0 would hand existing users a downgrade if those zips
# were signed into a manifest, so that path is refused unless overridden.
TAG_VERSION="$(git describe --tags --match 'v[0-9]*' --exact-match 2>/dev/null || true)"
RAW_VERSION="${TM_VERSION:-${TAG_VERSION#v}}"
VERSION="${RAW_VERSION#v}"
if [[ -z "$VERSION" ]]; then
    NEAREST_TAG="$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"
    if [[ "${TM_ALLOW_UNTAGGED:-0}" == "1" ]]; then
        VERSION="1.0"
        echo "warning: HEAD is not tagged — packaging as $VERSION${NEAREST_TAG:+, not ${NEAREST_TAG#v}}." >&2
    else
        echo "error: HEAD is not an exact v* tag; refusing to package as 1.0." >&2
        if [[ -n "$NEAREST_TAG" ]]; then
            echo "       Build the tag: git checkout $NEAREST_TAG && ./scripts/package-release.sh" >&2
        fi
        echo "       Or set TM_VERSION, or TM_ALLOW_UNTAGGED=1 for a local 1.0 package." >&2
        exit 1
    fi
fi
if [[ -n "$TAG_VERSION" ]]; then
    if [[ "$(git cat-file -t "$TAG_VERSION" 2>/dev/null || true)" != "tag" ]]; then
        echo "warning: $TAG_VERSION is a lightweight tag; prefer an annotated tag (git tag -a)." >&2
    fi
fi
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "error: invalid release version: $VERSION" >&2
    exit 1
fi
RELEASE_DIR="${TM_RELEASE_PATH:-$ROOT/dist/release}"
APP="${TM_APP_PATH:-$ROOT/dist/ToastMonitor.app}"
echo "== packaging ToastMonitor v$VERSION =="
mkdir -p "$RELEASE_DIR"

ARCHS="arm64 universal"
if [[ "${TM_ARM64_ONLY:-0}" == "1" ]]; then
    ARCHS="arm64"
fi
for arch in $ARCHS; do
    echo ""
    echo "== building $arch =="
    case "$arch" in
        arm64)     TM_ARCHS="arm64" ;;
        universal) TM_ARCHS="arm64 x86_64" ;;
    esac
    TM_VERSION="$VERSION" TM_APP_PATH="$APP" TM_ARCHS="$TM_ARCHS" TM_SKIP_INSTALL=1 ./scripts/build-app.sh
    file "$APP/Contents/MacOS/ToastMonitor"
    ZIP="$RELEASE_DIR/ToastMonitor-${VERSION}-${arch}.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "== $ZIP ($(du -sh "$ZIP" | cut -f1)) =="
done

echo ""
echo "== checksums =="
(
    cd "$RELEASE_DIR"
    shasum -a 256 ToastMonitor-${VERSION}-*.zip > "SHA256SUMS-${VERSION}.txt"
)
echo ""
echo "== artifacts =="
ls -la "$RELEASE_DIR/"
echo ""
echo "Upload to the GitHub release:"
echo "  gh release create v$VERSION dist/release/*.zip --title \"ToastMonitor v$VERSION\" --notes-file docs/release-v$VERSION.md"
echo ""
echo "生成架构感知签名更新清单："
echo "  ./scripts/sign-update-manifest.sh $VERSION dist/release/ToastMonitor-${VERSION}-arm64.zip dist/release/ToastMonitor-${VERSION}-universal.zip"
