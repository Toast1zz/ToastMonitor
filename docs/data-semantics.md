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
