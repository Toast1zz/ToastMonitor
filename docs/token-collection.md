# Token Collection

This document explains how ToastMonitor accounts for tokens along two axes: **by tool** (where the data comes from and how it is parsed) and **by source** (local reads vs. remote VPS feed).

## Overview

| Tool | Local data source | Row semantics | Remote feed row semantics |
|---|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | per-event (assistant usage) | same per-event structure |
| Codex | `~/.codex/sessions/.../rollout-*.jsonl` + `state_5.sqlite` | per-event (`token_count` `last_token_usage`) | same per-event structure |
| OpenCode | `~/.local/share/opencode/opencode.db` | session cumulative → local delta | cumulative → `session_totals` delta |
| Hermes | `~/.hermes/state.db` (column introspection) | (session, model) cumulative rows → delta | aggregate rows → baseline delta |
| OpenRouter | cloud API (produces no token rows) | — | — |

Each tool can be switched between local and remote independently in Sources & Settings (setting key `src_<tool>`).

---

## By tool

### Claude Code

- **Local path**: `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`; the scanner lists directories recursively (skipping hidden entries) and keeps only `.jsonl`.
- **Parsing**: only `type == "assistant"` events. Usage accepts two shapes: top-level event `usage`, or `message.usage` (newer SDK).
- **Token fields**: `input_tokens`, `output_tokens`, `cache_read_input_tokens` (cache hits), `cache_creation_input_tokens` (cache writes).
- **Incremental**: file changes are detected via (size, nanosecond mtime, inode); the cursor is a **byte offset** (`readNewJSONLines`) so only appended lines are parsed; a partial trailing line is not consumed. Truncated/replaced files replay from offset 0 (replayed events use the old mtime to keep IDs stable for dedupe).
- **Dedupe**: event ID = upstream `uuid`, or `claude:<file>:<inode>:<mtime>:<absolute byte offset>` when missing. A global unique index on (tool, event_id) is the backstop (`INSERT OR IGNORE`).
- **Remote feed**: tm-export.py exports the same per-event structure from the VPS; the app inserts directly (deduped by feed event_id or content hash).

### Codex

- **Local path**: `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`, plus the `threads` table in `~/.codex/state_5.sqlite` for model/title/cwd metadata.
- **Parsing**: `event_msg` events with `payload.type == "token_count"`, reading `payload.info.last_token_usage` (per-turn delta): `input_tokens`, `output_tokens`, `cached_input_tokens`, `cache_write_input_tokens`.
- **Model association**: prefer the model from `turn_context` events; then a model pre-scanned from the chunk; then the `threads` table's model/provider; finally NULL (unknown cost).
- **Incremental**: same (size, mtime, inode) + byte-offset cursor as Claude; `scan_state` persists parsing context (session id/model) across scans.
- **Dedupe**: event ID = `codex:<file>:<inode>:<mtime>:<offset>` (no upstream uuid).
- **Remote feed**: per-event rows inserted directly.

### OpenCode

- **Local path**: the `session` table of `~/.local/share/opencode/opencode.db` (opened read-only).
- **Row semantics**: one row per session holding **cumulative** values: `tokens_input`, `tokens_output`, `tokens_reasoning`, `tokens_cache_read`, `tokens_cache_write`, `cost` (official actual price).
- **Delta mechanism**: a local `session_totals` table (key `opencode|<id>`). Each scan computes new cumulative − last recorded = this batch's delta; shrinking fields (upstream reset) count as 0. The first time a session is seen, the full cumulative value becomes one backfill row attributed to the real last update time (never to today).
- **Time**: upstream millisecond timestamps normalized to seconds.
- **Model**: the upstream `model` column may be a JSON object (`{"id":...,"providerID":...}`); the parser normalizes it to the plain id; existing data is repaired once at startup via SQL.
- **Remote feed**: same cumulative → `session_totals` delta (shares the same key as local, so switching sources never double-counts).

### Hermes

- **Local path**: `~/.hermes/state.db` (SQLite, column introspection — the schema varies between versions, so the parser adapts to whichever columns exist).
- **Row semantics**: cumulative rows keyed by (session, model).
- **Delta mechanism**: baseline key `hm_d|<session>|<model>|<provider>|<base_url>` stores the last cumulative value; delta = current − last (negatives clamped to 0 to survive counter resets). Output-only messages are kept (input=0 still recorded). Timestamps are normalized between ms/s.
- **Cost**: Hermes traffic bills through the OpenCode Go / OpenRouter / Codex plans, so tokens are recorded but **cost is always 0** (`cost_quality = 'unknown'`).
- **Remote feed**: `session_model_usage` aggregate rows, baseline delta keyed by (session, model, provider, base_url) — one shared key so route changes never double-count.

### OMP (Oh My Pi)

- **Local path**: `~/.omp/agent/sessions/**/*.jsonl` (top-level sessions `<cwd>/<session>.jsonl`, subagent sessions `<session>/<agent>.jsonl`).
- **Parsing**: `message` events (`role == "assistant"`) carry `message.usage`: `input`, `output`, `cacheRead`, `cacheWrite`, `cost` (per-request cost breakdown). The structure resembles Claude Code's JSONL, so the same incremental machinery (size/mtime/inode + byte-offset cursor) is reused.
- **Semantics**: `input` excludes cache hits; `cacheRead` is the hit portion (from the opencode-go upstream, reported at 8-token block granularity — same origin as Hermes, real token values). `cost` is provider-computed; OMP bills within the opencode-go plan, marked `estimated`.
- **Dedupe**: event ID = `omp:<file>:<message id>` (the file name contains the session UUID, globally unique; message ids are stable, so replays dedupe).
- **Remote feed**: none (OMP runs locally only).

### OpenRouter

- Produces no token rows. While the UI is visible, `/api/v1/key` + `/api/v1/credits` are snapshotted every 60s (spend/balance in USD; polling stops in background). Only feeds "actual spend", never token stats.

---

## By source

### Local (default)

Reads the local files/SQLite directly, pure polling (1s while visible, fully stopped in background):

1. List files → stat (size, nanosecond mtime, inode) against `scan_state` → read only on change
2. Byte-offset cursor parses only new lines (append case); truncated/replaced files replay from 0
3. Parsed turns/sessions commit **in the same SQLite transaction as the cursor/baseline** — any failure rolls everything back and the cursor does not advance
4. Steady-state idle scans cost ~20ms

### Remote VPS feed (optional, per-tool switch)

- The VPS exporter is deployed by the user and produces `usage.json`; the app only requests addresses explicitly configured in Sources & Settings (HTTPS, or private local network allowed by rules), with no personal IPs or default remote hosts baked in.
- The app polls incrementally every 15s while visible (stopped in background); the cursor is a **per-tool watermark** (`remote_watermark_<tool>` = `ts:eventID`; same-second events ordered by eventID).
- Row semantics differ per tool (see table above): claude/codex insert per-event rows; opencode/hermes run deltas over cumulative rows — delta baselines are idempotent, so watermarks cannot corrupt them.
- Rows from unknown tools are rejected; watermark, turns and baselines commit in one transaction — nothing advances on failure.
- **Switching sources**: `src_<tool> = local/remote` takes effect immediately. OpenCode's delta key is shared local/remote, so switching never double-counts; Hermes uses different baseline keys (local `session_totals`, remote `hm_d|...`), so the first remote row after a switch backfills the full value — a known edge case that can record one extra historical entry after a source switch.

---

## Master semantics & dedupe guarantees

- **Total tokens = input + output + cacheRead (cache hits)**; the only exception is Codex, whose input already includes cache, so it is not added again. `cacheWrite` (cache writes) is recorded but never counted in totals.
- **Dedupe chain**: upstream event ID (uuid / content hash) → derived ID (file + inode + mtime + byte offset) → global unique index (tool, event_id) with `INSERT OR IGNORE`. Re-scanning or replaying the same event never double-counts.
- **Cost** (separate from tokens): `actual` = tool-provided actual price (OpenCode's cost field); `estimated` = priced from the built-in model table; Hermes = unknown (0). "API value" re-prices every row (including Hermes) at the official per-model list price.
