# Contributing to ToastMonitor

Thanks for considering a contribution. This project is a native macOS menu-bar app with **zero third-party dependencies**, and every change should keep it that way.

## Development setup

- macOS 13+ with Xcode (SwiftPM toolchain 5.9+)
- `zstd` CLI is optional (Homebrew: `brew install zstd`) — without it the DSH collector falls back to cache mode and the zstd tests are skipped

```bash
swift build                  # debug build
swift test                   # full test suite
swift test --filter DSHParserTests   # a single suite
```

Builds in this repo are normally run with `swift build --disable-sandbox` on the host; CI uses a plain `swift build`.

## Constraints

- **No third-party dependencies.** Everything ships with the system frameworks (AppKit, SwiftUI, sqlite3, Security). If you're adding a library, reconsider — almost everything here is a small amount of system-API code.
- **Local-only privacy default.** User data stays on the Mac unless the user explicitly enables a remote feed or quota service. Never add analytics, telemetry or implicit network calls.
- **Credentials never in plaintext.** API keys and cookies belong in the macOS Keychain (see `KeychainStore`). Never log, print or store secrets in SQLite/plists.
- **Background Keychain reads never prompt.** `kSecUseAuthenticationUI` and `LAContext.interactionNotAllowed` are honoured only by the data-protection keychain; login-keychain items ignore both and open a SecurityAgent password sheet on an ACL miss. Route every unattended read through `KeychainStore.withoutUserInteraction`, and keep the interactive path behind an explicit `allowPrompt: true` the user asked for.

## What to touch

- Parsers live in `Sources/ToastMonitor/Collect/` (one per tool: `ClaudeCodeParser`, `CodexParser`, `DSHParser`, …). Each uses the shared `scan_state` incremental machinery — a new source should follow the same cursor + idempotent-insert pattern.
- Row semantics are documented in [`docs/data-semantics.md`](docs/data-semantics.md) and [`docs/token-collection.md`](docs/token-collection.md) — keep them in sync when you change accounting.
- Every parser ships with fixtures + tests in `Tests/ToastMonitorTests/` (see `Fixtures/`).

## Pull request workflow

1. Branch from `main`; keep the change focused.
2. Add or update tests for behavior changes — the CI gates (migration replay, duplicate-import) are mandatory.
3. Run `swift build` and `swift test` locally; make sure the whole suite passes.
4. Open a PR with a short description: what changed, why, and any data-semantics implications.

## Commit messages

Use concise imperative subject lines, e.g.:

```
Add DeepSeek Harness token source with log/cache dual mode
```

Prefer a few focused commits over one giant one.

## Reporting issues

Use the issue templates. Include: app version (`--version`), macOS version, reproduction steps and sanitized logs. **Never** attach tokens, cookies, API keys, project paths or raw session content.
