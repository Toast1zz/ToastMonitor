#!/bin/bash
# Sign an update manifest (appcast.json) with the release Ed25519 private key.
#
# Usage:
#   ./scripts/sign-update-manifest.sh <version> <artifact.zip> [download_url]
#
# The download URL defaults to the GitHub latest-release asset name so a
# freshly uploaded release just works:
#   https://github.com/Toast1zz/ToastMonitor/releases/latest/download/<basename>
#
# Outputs appcast.json (the signed envelope) to the current directory and
# prints the path. The private key lives at ~/.config/toastmonitor/update-key.pem
# (0600, never committed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: sign-update-manifest.sh <version> <artifact.zip> [download_url]}"
ARCHIVE="${2:?missing artifact zip}"
KEY="$HOME/.config/toastmonitor/update-key.pem"
[[ -f "$KEY" ]] || { echo "update key not found: $KEY" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
[[ -f "$ARCHIVE" ]] || { echo "artifact not found: $ARCHIVE" >&2; exit 1; }

if [[ -n "${3:-}" ]]; then
    DOWNLOAD_URL="$3"
else
    # Fixed per-release URL: `/releases/latest/...` depends on GitHub's latest
    # resolution, which can lag a freshly published release. A tag-pinned URL
    # is stable forever and still redirects to the object store over HTTPS.
    DOWNLOAD_URL="https://github.com/Toast1zz/ToastMonitor/releases/download/$VERSION/$(basename "$ARCHIVE")"
fi
[[ "$DOWNLOAD_URL" == https://* ]] || { echo "download URL must be HTTPS" >&2; exit 1; }

SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
echo "version:    $VERSION"
echo "artifact:   $ARCHIVE"
echo "sha256:     $SHA256"
echo "download:   $DOWNLOAD_URL"

# payload JSON -> base64 -> Ed25519 signature over the base64 text.
# The payload's hex sha256 keeps the app-side hex parser simple.
PAYLOAD=$(printf '{"version":"%s","download_url":"%s","sha256":"%s"}' \
    "$VERSION" "$DOWNLOAD_URL" "$SHA256")
B64=$(printf '%s' "$PAYLOAD" | base64 | tr -d '\n')

SIGN=$(cat > /tmp/tm-sign-input.txt <<< "$B64"; TM_KEY="$KEY" swift -e '
import CryptoKit
import Foundation
extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        self.init(bytes)
    }
}
let keyPath = ProcessInfo.processInfo.environment["TM_KEY"]!
let hex = try! String(contentsOfFile: keyPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: hex))
let payload = try! String(contentsOfFile: "/tmp/tm-sign-input.txt", encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
print(try! key.signature(for: Data(payload.utf8)).base64EncodedString())
' 2>/dev/null | tail -1)

printf '{"payload":"%s","signature":"%s"}\n' "$B64" "$SIGN" > appcast.json
echo "== appcast.json written =="
python3 -c "import json; d=json.load(open('appcast.json')); print('payload bytes:', len(d['payload']), '| signature bytes:', len(d['signature']))"
