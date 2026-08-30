# Ventura Compatibility: Isolation Assessment

Version: 2026-08-30

## 1. Question

Can the macOS Ventura (13.0+) downward-compatibility implementation be isolated from the
primary target systems (macOS 14+) with **zero impact on those targets**? Candidate mechanisms:
build-script branching, a separate git branch, runtime OS detection with API fallback, and others.

## 2. Context

- The repo previously declared macOS 14.0 everywhere (`Package.swift` `.v14`,
  `LSMinimumSystemVersion` 14.0, README/CONTRIBUTING claims).
- Compatibility work replaced every macOS 14+-only API usage with 13.0+ equivalents:
  - 10 two-parameter `.onChange(of:initial:_:)` call sites → single-parameter `.onChange(of:perform:)`
    (verified against the macOS 13.3 CLT SDK SwiftUI swiftinterface: only the single-parameter form
    exists there, line 2966; `initial:` defaults to `false`, so behavior is identical).
  - 2 `.snappy(duration: 0.25)` animations → `#available(macOS 14.0, *)` guard: macOS 14+ keeps
    `.snappy(duration: 0.25)` exactly as before; only macOS 13 falls back to
    `.easeOut(duration: 0.35)` (`snappy` does not exist in the 13.3 interface).
  - Deployment target lowered: `Package.swift` `.v13`, `LSMinimumSystemVersion` 13.0.
- `contentTransition`, `onContinuousHover`, `numericText` were verified `macOS 13.0+` in the same
  interface and left untouched.

## 3. Candidate isolation paths

### 3.1 Build-script branching — feasible, 1 line, zero impact

- `scripts/build-app.sh` writes `LSMinimumSystemVersion` into a heredoc Info.plist. It could read
  `"${TM_DEPLOY_MIN:-13.0}"` instead of the hard-coded value.
- The SwiftPM manifest is plain Swift and `#if` conditional compilation is syntactically valid
  (`swiftc -parse` passes), so manifest branching is *possible* — but **unnecessary**: a lower
  minimum OS is a subset declaration. It does not change how macOS 14+ renders or behaves, and
  keeping `.v13` unconditional avoids a fork between CI's direct `swift build` and the script.
- Default output is unchanged, so this path is purely a future option, not a requirement.

### 3.2 Separate git branch — technically zero impact, hard cost

- The repo currently has a single `main` branch (no release/ventura branches).
- `UpdateChecker`'s manifest `Payload` selects artifacts **by architecture only**
  (`artifacts[architecture.rawValue]`; `CodingKeys` have no OS field), so a Ventura branch would
  publish into the same `appcast.json` and feed 13.0 artifacts to 14+ users unless the update
  channel itself is forked.
- Cost: permanent dual maintenance (cherry-picks in both directions) plus appcast conflict
  governance. **Not recommended.**

### 3.3 Runtime OS detection + API fallback — not feasible

- There is **nothing left to fall back on**: `grep` confirms zero remaining `onChange(of:initial:)`
  or `.snappy` usage in `Sources/`. Both were already replaced with 13.0+ equivalents.
- `if #available(macOS 14.0, *)` wrappers around either would be dead code.
- Any forced runtime branch would *add* divergence risk on the 14+ path, the opposite of isolation.

## 4. Impact of the applied changes on macOS 14+ targets

| Change | Impact on 14+ | Basis |
|---|---|---|
| 10 onChange two-param → single-param | none | `initial:` defaults `false`; same trigger semantics (13.3 SDK interface line 2966) |
| 2 `.snappy(0.25)` → `#available` guard | none — macOS 14+ keeps the original `.snappy(0.25)`; the easeOut fallback runs only on macOS 13 | snappy exists only in the 14+ SDK; 13.3 interface has no `snappy` |
| `Package.swift` `.v13` | none | lower minos is a subset; minos decides loadability, not runtime behavior |
| `LSMinimumSystemVersion` 13.0 | none | same subset argument; no extra work triggered on 14+ |
| Comments, README, CONTRIBUTING | none | documentation only |

No 14+ behavioral code path was modified. The compatibility implementation is transparent to the
target systems.

## 5. Verdict

- The compatibility implementation **does not need isolation** — it is already zero-impact.
- If formal isolation is ever wanted, the only sensible mechanism is 3.1 (one environment variable
  in `build-app.sh`); 3.2 and 3.3 are rejected.
- Releasing for Ventura needs no special machinery: the existing tag + `build-app.sh` pipeline
  produces an artifact that is natively 13.0+.
