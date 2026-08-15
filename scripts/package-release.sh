#!/bin/bash
# Build release artifacts for GitHub Releases: one arm64-only app and one
# universal (arm64 + x86_64) app, both signed and zipped.
#
# Usage: ./scripts/package-release.sh
# Produces dist/release/ToastMonitor-<version>-{arm64,universal}.zip
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

for arch in arm64 universal; do
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
