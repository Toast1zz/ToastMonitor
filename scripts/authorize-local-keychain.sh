#!/bin/bash
# Allow local ToastMonitor builds signed by the same Apple Development Team
# to reuse the existing generic-password items without a prompt per rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${TM_APP_PATH:-$ROOT/dist/ToastMonitor.app}"
KEYCHAIN="${TM_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"

if [[ ! -d "$APP" ]]; then
    echo "error: app bundle not found: $APP" >&2
    echo "       run ./scripts/build-app.sh first" >&2
    exit 1
fi
if [[ ! -f "$KEYCHAIN" ]]; then
    echo "error: login keychain not found: $KEYCHAIN" >&2
    exit 1
fi

# macOS ships bash 3.2, which mis-parses a multi-line `case` inside a
# command substitution; a plain sed pipeline is version-proof.
TEAM_ID="$(codesign -d --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
if [[ -z "$TEAM_ID" || ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "error: app is not signed by an Apple Development/Developer ID Team: $APP" >&2
    echo "       build with an identity that has a TeamIdentifier first" >&2
    exit 1
fi

echo "将 ToastMonitor 钥匙串条目授权给 Team ID: $TEAM_ID"
echo "macOS 会要求输入一次登录钥匙串密码；之后同一 Team ID 的新版本不再逐次询问。"
security set-generic-password-partition-list \
    -s ToastMonitor \
    -S "apple-tool:,teamid:$TEAM_ID" \
    "$KEYCHAIN"
echo "done"
