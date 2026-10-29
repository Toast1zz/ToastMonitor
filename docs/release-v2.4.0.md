## New

- Choose when the quota alert fires: Settings → General now offers 10%, 20%, 30% or 50% left. The default is still 20%.

## Fixed

- Claude and Grok quotas no longer stop updating after Homebrew upgrades the `claude` or `grok` command line tool.
- A data source that keeps failing is retried less often instead of on every scan. Refreshing by hand still retries it right away.
- Clearing an OpenRouter or OpenCode Go key from the command line now reports an error if the key could not be removed from the Keychain.

## Changed

- Backups take about a fifth of the space. ToastMonitor keeps the last 4 weekly backups, one per month for 3 more months, and the last 3 taken before clearing or restoring data. Your existing backups are converted on the first launch and keep their dates.
- The menu bar icon no longer shows a tooltip.
- Crash logs now include the app version.
