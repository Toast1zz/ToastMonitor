# Data Semantics

Version: 2026-08-05 · Status: normative (enforced from phase B onward)

## 1. Money semantics (never mix sums)

| Field | Meaning | Source | Summable with |
|---|---|---|---|
| `actualVariableSpend` | actual cash/credit spend explicitly returned upstream | OpenRouter `usage*`, Hermes `actual_cost_usd` | same kind only |
| `estimatedVariableCost` | estimated from the price table | `Pricing.estimate` | same kind only (needs coverage) |
| `subscriptionFixedCost` | user-entered subscription fee | `subscriptions.price` | same kind only (state when amortized per period) |
| `quotaValueConsumed` | plan dollar-priced quota consumed | OCG official `monthlyPct × $60` | not equal to cash spend |
| `accountBalance` | available balance | OpenRouter `/credits` | never summed with other money |
| `purchasedCredits` / `usedCredits` | cumulative purchased/used | OpenRouter `/credits` | cross-reference only, not aggregated |

**Rule**: the UI must not add these values unconditionally. Any sum must declare its basis:

- "Today's total spend" = today's subscription amortization + today's actual OpenRouter spend + direct estimate (each component expandable).
- "Value used" is only valid in a plan context and must never be called "spend".

## 2. Token semantics

- `inputTokens`: total input as defined upstream (may include cache hits).
- `cachedInputTokens`: when a subset of input → non-cached input = input − cached.
- `cacheWriteTokens`: recorded separately, never merged into input.
- `outputTokens`: state whether it includes reasoning; `reasoningTokens` recorded separately when provided upstream.
- `billableInputTokens`: derived from provider billing rules (e.g. OpenAI cached input at the cache price), never a stored guess.

## 3. Data quality

Every aggregate must be able to express:

```
enum MetricQuality { case actual, estimated, partial, unknown }
coverage = covered amount / total amount (shown when estimating)
```

Rules:

- Unknown model/cost → `unknown` + `—`, never display `$0.000`.
- Partial key failure → `partial`, never presented as fully successful.
- Stale data (no sync for N minutes) → explicitly marked `stale`.

## 4. Time

- Stored uniformly as Unix seconds (Int64).
- `created` takes the earliest valid non-zero time; `updated` the latest.
- `0` means unknown and the UI shows `—`, never 1970.
- Hermes without a time column is explicitly unknown; never query columns that do not exist.

## 5. Clearing usage data

- **Clear All Data** removes local usage/history, including `claude_quota_samples`, cached session totals, and quota snapshots. It resets query/estimation cache markers and bumps the data version so displayed usage is recomputed.
- Settings, user preferences, and Keychain credentials are preserved. Hermes remote `hm_d|...` cumulative baselines are also retained as historical high-water marks: a later feed poll imports only usage accumulated since the retained baseline, rather than replaying the cleared historical total as new usage. Clear therefore does not reset remote cumulative counters or their deduplication state.
- Local Claude/Codex rebuild affects only local turns/sessions and does not reset quota samples or remote Hermes baselines.

## 6. Event identity

- Claude rows use `claude:<sessionId>:<message.id>` and keep the greater usage for that id. A row with no message id uses a byte-offset fallback and is not upgraded.
- Codex event ids stay offset-based, so two real turns with the same usage stay distinct. `total_token_usage` is cumulative: only growth is stored, and an unchanged total is skipped. Without a total, `last_token_usage` is the turn.
- DeepSeek Harness log rows use `dsh-log:<session>:<turn>:<step>`. A later message for that step replaces the stored row.
- Schema v7 sets `usage_recount_v7` to `pending`. The next local scan deletes `claude:%`, `codex:%`, and `dsh-log:%` turns only when that source still has files, zeroes those files' cursors, and rebuilds from the logs. Source logs are never deleted. Rows with a NULL event id, cache-mode rows, remote rows, and any other prefix stay. A remote source, or DeepSeek Harness in cache mode, is not wiped. Turns whose source file is already gone cannot be rebuilt.
