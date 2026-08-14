# Database Backup & Migration Strategy

Version: 2026-08-09

## 1. Current state

- Real DB: `~/Library/Application Support/ToastMonitor/toastmonitor.db` (WAL).
- Contains: turns / sessions / scan_state / session_totals / openrouter_snapshots / opencodego_snapshots / subscriptions / settings.
- Migrations must never delete or reset the user's database; when the user explicitly invokes a clear/rebuild API, a protected backup must be created first and rolled back on failure.

## 2. Backup & restore

- The app's backup directory is `~/Library/Application Support/ToastMonitor/Backups/` with directory permissions 0700; database backup files are 0600.
- `DataMaintenance.createBackup(label:)` uses an online SQLite backup snapshot and keeps the most recent 7; `exportDatabase(to:)` exports a full snapshot and sets the target file to 0600.
- `DataMaintenance.clearAllData()` clears turns, sessions, scan_state, session_totals, quota snapshots and subscriptions, but keeps settings and Keychain credentials; a `pre-clear` backup is forced before execution and rolled back on failure.
- A protected backup is always created before repair/clear; on failure the original database is never further modified.

## 3. Manual diagnostics

Export/diagnostic files go to a user-chosen path with permissions kept at 0600; exports never include Keychain keys/cookies and never record prompts.

## 4. Migration mechanism

- `PRAGMA user_version` versioned migrations run inside a `BEGIN IMMEDIATE` transaction. Idempotent `ensureColumn` ALTERs (e.g. `subscriptions.end_date`, `scan_state.context`) run outside transactions — safe to retry on failure, not part of versioned migration.
- New columns use idempotent `ensureColumn`; the database uses a recursive lock so migration/collection transactions can call it safely. The `turns` legacy unique-constraint rebuild and event-index creation also run inside the same `BEGIN IMMEDIATE` transaction — failure rolls back and keeps `user_version=0` for retry.
- Replay of each historical version should start the app against an old-schema copy and verify `user_version`, key tables and duplicate-event counts; CI's migration replay gate covers representative old versions.
