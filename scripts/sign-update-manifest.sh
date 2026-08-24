#!/bin/bash
# Sign an update manifest (appcast.json) with the release Ed25519 private key.
#
# Usage:
#   ./scripts/sign-update-manifest.sh <version> <arm64.zip> <universal.zip> [output]
#   ./scripts/sign-update-manifest.sh <version> <artifact.zip> [download_url] [output]
#
# The download URL defaults to the tag-pinned GitHub release asset name so a
# freshly uploaded release just works:
#   https://github.com/Toast1zz/ToastMonitor/releases/download/v<version>/<basename>
#
# The first form writes an architecture-aware manifest. It keeps the
# universal artifact in the legacy `download_url` fields so older clients can
# bootstrap; newer clients select the signed `artifacts` entry for their
# running architecture. The second form remains supported for old/single-
# artifact releases.
#
# Output defaults to appcast.json in the repository root; pass an explicit
# fourth argument in the architecture-aware form (e.g. dist/release/appcast.json)
# or fourth argument after a custom URL in the legacy form.
# The private key lives at ~/.config/toastmonitor/update-key.pem (0600, never
# committed). It travels to the signer as an argv argument — never via an
# environment variable, which `ps e` would expose to same-uid observers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: sign-update-manifest.sh <version> <artifact.zip> [download_url] [output]}"
ARCHIVE="${2:?missing artifact zip}"
KEY="$HOME/.config/toastmonitor/update-key.pem"
[[ -f "$KEY" ]] || { echo "update key not found: $KEY" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
[[ -f "$ARCHIVE" ]] || { echo "artifact not found: $ARCHIVE" >&2; exit 1; }

UNIVERSAL_ARCHIVE=""
if [[ -n "${3:-}" && -f "$3" ]]; then
    UNIVERSAL_ARCHIVE="$3"
    OUT="${4:-appcast.json}"
    ARM64_URL="https://github.com/Toast1zz/ToastMonitor/releases/download/v$VERSION/ToastMonitor-$VERSION-arm64.zip"
    UNIVERSAL_URL="https://github.com/Toast1zz/ToastMonitor/releases/download/v$VERSION/ToastMonitor-$VERSION-universal.zip"
    LEGACY_ARCHIVE="$UNIVERSAL_ARCHIVE"
    LEGACY_URL="$UNIVERSAL_URL"
else
    OUT="${4:-appcast.json}"
    if [[ -n "${3:-}" ]]; then
        LEGACY_URL="$3"
    else
    # Fixed per-release URL: `/releases/latest/...` depends on GitHub's latest
    # resolution, which can lag a freshly published release. A tag-pinned URL
    # is stable forever and still redirects to the object store over HTTPS.
    # Note the leading "v": git tags are v1.2.2 while VERSION is 1.2.2.
    #
        LEGACY_URL="https://github.com/Toast1zz/ToastMonitor/releases/download/v$VERSION/ToastMonitor-$VERSION-arm64.zip"
    fi
    LEGACY_ARCHIVE="$ARCHIVE"
fi
[[ "$LEGACY_URL" == https://* ]] || { echo "download URL must be HTTPS" >&2; exit 1; }

SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ -n "$UNIVERSAL_ARCHIVE" ]]; then
    [[ -f "$UNIVERSAL_ARCHIVE" ]] || { echo "universal artifact not found: $UNIVERSAL_ARCHIVE" >&2; exit 1; }
    UNIVERSAL_SHA256="$(shasum -a 256 "$UNIVERSAL_ARCHIVE" | awk '{print $1}')"
fi
echo "version:    $VERSION"
echo "artifact:   $ARCHIVE"
echo "sha256:     $SHA256"
echo "download:   $LEGACY_URL"
if [[ -n "$UNIVERSAL_ARCHIVE" ]]; then
    echo "universal:  $UNIVERSAL_ARCHIVE"
    echo "sha256:     $UNIVERSAL_SHA256"
fi
echo "output:     $OUT"

# payload JSON -> base64 -> Ed25519 signature over the base64 text.
# The payload's hex sha256 keeps the app-side hex parser simple.
if [[ -n "$UNIVERSAL_ARCHIVE" ]]; then
    # Keep the legacy fields pointed at universal so v1.5.2-and-earlier
    # clients can cross the bootstrap boundary on both CPU families.
    PAYLOAD=$(printf '{"version":"%s","download_url":"%s","sha256":"%s","artifacts":{"arm64":{"download_url":"%s","sha256":"%s"},"x86_64":{"download_url":"%s","sha256":"%s"}}}' \
        "$VERSION" "$LEGACY_URL" "$UNIVERSAL_SHA256" \
        "$ARM64_URL" "$SHA256" "$UNIVERSAL_URL" "$UNIVERSAL_SHA256")
else
    PAYLOAD=$(printf '{"version":"%s","download_url":"%s","sha256":"%s"}' \
        "$VERSION" "$LEGACY_URL" "$SHA256")
fi
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
