## Fixed

- Prevent database exports from overwriting the active database or its journal files, including destinations reached through symbolic links or hard links.
- Reject invalid token counters before arithmetic, preventing malformed usage records from overflowing parser calculations.
- Discard stale OpenRouter, Go, and Command Code responses after credentials change. Report credential deletion failures without losing the configured account state.
- Keep subscription renewals anchored to the original billing day and calculate usage costs using each billing cycle's actual length.
- Correct model and CSV token totals when several tools report the same model with different cache accounting rules.
- Preserve future OpenCode usage growth after migrating legacy combined token counters to separate input and reasoning counters.
- Apply the decompression deadline to blocked input and output operations, and terminate unresponsive zstd processes.
- Neutralize spreadsheet formulas in CSV text fields while preserving numeric values and CSV escaping.
- Renew expired Grok sessions through the Grok CLI before asking users to sign in again.

## Documentation

- Add first-launch approval instructions and download checksum verification steps.

## Validation

- `swift test`: 406 tests, 403 passed, 3 skipped, 0 failures.
- Release build passed. Regression tests use temporary databases and simulated credential and network responses.
