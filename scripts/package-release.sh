#!/bin/bash
# Build release artifacts for GitHub Releases.
#
# Default: a single arm64-only app (the appcast points here). Apple Silicon
# users — by far the majority, including all M-series Macs — must receive the
# arm64 build because the universal (x86_64) slice is linked against the
# macOS 14 SDK, which makes macOS 26/27 serve legacy compatibility UI controls
# (no system Liquid Glass).
#
# Set TM_ALSO_UNIVERSAL=1 to additionally produce the universal (arm64+x86_64)
# app as an optional manual-download asset for the rare Intel Mac. It is never
# the appcast's default target.
#
# Usage: ./scripts/package-release.sh
# Produces dist/release/ToastMonitor-<version>-arm64.zip
#   (+ dist/release/ToastMonitor-<version>-universal.zip when TM_ALSO_UNIVERSAL=1)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Only an exact tag hit is a release version (see build-app.sh); untagged
# commits package as 1.0 rather than impersonating the last release.
TAG_VERSION="$(git describe --tags --match 'v[0-9]*' --exact-match 2>/dev/null || true)"
VERSION="${TAG_VERSION#v}"
if [[ -z "$VERSION" ]]; then VERSION="1.0"; fi
echo "== packaging ToastMonitor v$VERSION =="
rm -rf dist/release
mkdir -p dist/release

ARCHS="arm64"
if [[ "${TM_ALSO_UNIVERSAL:-0}" == "1" ]]; then
    ARCHS="arm64 universal"
fi
for arch in $ARCHS; do
    echo ""
    echo "== building $arch =="
    case "$arch" in
        arm64)     TM_ARCHS="arm64" ;;
        universal) TM_ARCHS="arm64 x86_64" ;;
    esac
    TM_ARCHS="$TM_ARCHS" TM_SKIP_INSTALL=1 ./scripts/build-app.sh
    file dist/ToastMonitor.app/Contents/MacOS/ToastMonitor
    ZIP="dist/release/ToastMonitor-${VERSION}-${arch}.zip"
    ditto -c -k --sequesterRsrc --keepParent dist/ToastMonitor.app "$ZIP"
    echo "== $ZIP ($(du -sh "$ZIP" | cut -f1)) =="
done

echo ""
echo "== artifacts =="
ls -la dist/release/
echo ""
echo "上传到 GitHub Release："
echo "  gh release create v$VERSION dist/release/*.zip --title 'ToastMonitor v$VERSION' --generate-notes"
echo ""
echo "生成签名更新清单（appcast 默认指向 arm64）："
echo "  ./scripts/sign-update-manifest.sh $VERSION dist/release/ToastMonitor-${VERSION}-arm64.zip"
