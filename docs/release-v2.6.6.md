## Fixed

- **Collector & Parser Reliability**: Prevented partial SQLite read failures in `OpenCodeParser` from advancing `session_totals` without committed turns, eliminated a post-commit signature TOCTOU in `CollectorEngine`, checked `SQLITE_DONE` and ordering in `PerfCollector.scanOpenCode`, persisted `ClaudeCodeParser` and `DSHParser` context across incremental scans, and reported `HermesParser`/`DSHParser` read errors properly.
- **Database & Backup Integrity**: Split `backfillCosts()` so routine scans use `idx_turns_backfill` without full-table scans, added `tool` filtering to `deleteRecountedSessions`, fixed `Database.restore()` rollback when reopening fails, enforced `integrity_check` and read-only WAL safety on recovery, and ensured Settings backup restores reload all in-memory settings and open panes.
- **UI, Performance & Quota Clients**: Removed the synchronous nested `RunLoop.main.run` stall in Settings, serialized async settings writes, stopped hidden Dashboard tabs from background-reloading or flashing spinners on `PerformanceView`, fixed `WindowManager` popover visibility signaling, separated HTTP 403 backoff from 401 CLI renewal in `ClaudeQuotaClient`, fixed `CommandCodeQuotaClient` parse-failure backoff/timestamps, and preserved prior `CodexQuotaClient` snapshots on malformed responses.

## Security & Reliability

- Pinned CI GitHub Actions to commit SHAs, enforced signing identity and `codesign --verify` checks in `package-release.sh`, isolated `ClaudeCLIRefresher` probe directories per run (`0700`), and hardened `UpdateManager` unzip timeouts and `sign-update-manifest.sh` JSON serialization/key checks.
