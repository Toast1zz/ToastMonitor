#!/bin/bash
# Sign an update manifest (appcast.json) with the release Ed25519 private key.
#
# Usage:
#   ./scripts/sign-update-manifest.sh <version> <artifact.zip> [download_url] [output]
#
# The download URL defaults to the tag-pinned GitHub release asset name so a
# freshly uploaded release just works:
#   https://github.com/Toast1zz/ToastMonitor/releases/download/v<version>/<basename>
#
# Output defaults to appcast.json in the repository root; pass an explicit
# fourth argument (e.g. dist/release/appcast.json) to place it elsewhere.
# The private key lives at ~/.config/toastmonitor/update-key.pem (0600, never
# committed). It travels to the signer as an argv argument — never via an
# environment variable, which `ps e` would expose to same-uid observers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: sign-update-manifest.sh <version> <artifact.zip> [download_url] [output]}"
ARCHIVE="${2:?missing artifact zip}"
OUT="${4:-appcast.json}"
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
    # Note the leading "v": git tags are v1.2.2 while VERSION is 1.2.2.
    #
    # The appcast points at the arm64-only artifact by default. The universal
    # build links the x86_64 slice against the macOS 14 SDK, which makes the
    # system serve legacy (compatibility) UI controls on macOS 26/27 — so
    # Apple Silicon users must not receive it. Pass the universal zip plus an
    # explicit download URL as $2/$3 to publish a universal build instead
    # (rare: Intel Macs only).
    DOWNLOAD_URL="https://github.com/Toast1zz/ToastMonitor/releases/download/v$VERSION/ToastMonitor-$VERSION-arm64.zip"
fi
[[ "$DOWNLOAD_URL" == https://* ]] || { echo "download URL must be HTTPS" >&2; exit 1; }

SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
echo "version:    $VERSION"
echo "artifact:   $ARCHIVE"
echo "sha256:     $SHA256"
echo "download:   $DOWNLOAD_URL"
echo "output:     $OUT"

# payload JSON -> base64 -> Ed25519 signature over the base64 text.
# The payload's hex sha256 keeps the app-side hex parser simple.
PAYLOAD=$(printf '{"version":"%s","download_url":"%s","sha256":"%s"}' \
    "$VERSION" "$DOWNLOAD_URL" "$SHA256")
B64=$(printf '%s' "$PAYLOAD" | base64 | tr -d '\n')

# Throwaway 0600 input file (unique per run — no fixed /tmp path that another
# run or a symlink could clobber). The key path is passed as argv.
INPUT="$(mktemp -t tm-sign-input.XXXXXX)"
trap 'rm -f "$INPUT"' EXIT
chmod 600 "$INPUT"
printf '%s' "$B64" > "$INPUT"

# Fail loudly on signing errors (missing swift, invalid key): the empty
# SIGN guard below would otherwise publish an appcast the app rejects.
SIGN="$(swift -e '
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
let keyPath = CommandLine.arguments[1]
let inputPath = CommandLine.arguments[2]
let hex = try! String(contentsOfFile: keyPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: hex))
let payload = try! String(contentsOfFile: inputPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
// Loop-back: verify the signature with the derived public key so a broken
// key or signing path can never emit an appcast the app would reject.
let signature = try key.signature(for: Data(payload.utf8))
guard key.publicKey.isValidSignature(signature, for: Data(payload.utf8)) else {
    exit(2)
}
print(signature.base64EncodedString())
' "$KEY" "$INPUT")"
[[ -n "$SIGN" ]] || { echo "signing failed (swift missing or key invalid)" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
printf '{"payload":"%s","signature":"%s"}\n' "$B64" "$SIGN" > "$OUT"
echo "== $OUT written =="
python3 -c "import json; d=json.load(open('$OUT')); print('payload bytes:', len(d['payload']), '| signature bytes:', len(d['signature']))"
