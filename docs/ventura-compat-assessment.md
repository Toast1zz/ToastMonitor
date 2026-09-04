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
- `contentTransition`, `onContinuousHover` and the value-less `numericText()` were verified
  `macOS 13.0+` in the same interface. `numericText(value:)` is 14+, so the two hero counters route
  through `tmNumericTextTransition(value:)`, which keeps the value-driven form on 14+.
- `Text.foregroundStyle` (returning `Text`, used inside `Canvas` `ctx.draw`) is 14+; the four chart
  label call sites use `.foregroundColor` instead, which renders identically.

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
| `numericText(value:)` → `tmNumericTextTransition(value:)` | none — the 14+ branch passes the same value | `#available` helper in `TMDesignSystem.swift` |
| 4 chart labels `foregroundStyle` → `foregroundColor` | none visually | both resolve to the same secondary label color |
| Toolbar: centered `NSToolbarItemGroup` gated on 14+ | none — 14+ keeps the group, the `.tabs` role and the centered identity | `#available(macOS 14.0, *)` in `DashboardToolbarController` |
| `Package.swift` `.v13`, `LSMinimumSystemVersion` 13.0 | expected none, **verified by the visual-regression gate** rather than assumed | see below |

The one claim that cannot be settled by reading the SDK is the deployment target. AppKit gates a
number of behaviors on "linked on or after", and this app's Liquid Glass appearance on macOS 26/27
is exactly the kind of thing that could ride on it — `scripts/build-app.sh` carries a comment about
the recorded SDK field for that reason. Glass adoption follows the recorded SDK, not the minimum OS,
and the visual-regression gate (four dashboard tabs + both popover pages, light and dark) is what
holds that: if lowering the floor changed the rendered appearance on 26/27, that gate fails.

## 5. Verdict

- The compatibility implementation **does not need isolation** — 14+ behavior is preserved on every
  changed path, either identically or behind `#available`.
- If formal isolation is ever wanted, the only sensible mechanism is 3.1 (one environment variable
  in `build-app.sh`); 3.2 and 3.3 are rejected.

## 6. Not addressed here

- **Release artifacts.** `package-release.sh` still ships arm64 + universal zips and
  `sign-update-manifest.sh` still signs them; nothing about Ventura changes that flow.
- **Update channel has no OS floor.** `UpdateChecker` selects artifacts by architecture only
  (`artifacts[architecture.rawValue]`, no OS field in `CodingKeys`), so a future 14+-only release
  would still be offered to a Ventura user. That needs an OS field in the manifest before any
  release raises the floor again.
