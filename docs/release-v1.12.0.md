# ToastMonitor v1.12.0

## Redesigned popover

- Sections now sit on tonal cards: Sources, Quota, Balance and Activity. Hover a card's title to reveal an eye button that hides it; the eye icon in the footer brings hidden cards back, and Settings > Show on Home toggles each one.
- Subscription quotas and prepaid balances are separate cards. Quota covers Claude, OpenCode Go, Codex and Command Code; Balance covers OpenRouter and DeepSeek.
- Every quota window gets its own usage bar that fills as the quota is used, with the used percentage and its reset countdown. Claude shows its 5-hour and weekly windows (plus weekly Opus where the plan has one).
- Sources that were never set up collapse into a single "Not connected" line with a Set up shortcut instead of taking a full row each.
- Heatmap and trend chart share one Activity card with a toggle. The heatmap covers the last 24 weeks with month labels on real month boundaries, and the trend line gains an area fill.
- Spent and Value appear as compact chips under the token total.
- One typeface throughout, with tabular digits for numbers.
- Amounts use currency symbols ($, ¥). DeepSeek shows its balance on one line and omits empty wallets.
- The panel edge no longer shows a bright outline in dark mode.

## Settings

- The popover settings page uses the same card layout. Home sections and per-account visibility are multi-select chips instead of a column of switches, and the page scrolls only when it is taller than the screen.

## Claude usage outside this Mac

- Claude's quota row can show an estimate of weekly quota consumed outside this Mac, such as Cowork, claude.ai chat, or Claude Code on another machine. These leave no local transcript, so their tokens cannot be counted.
- The estimate compares each quota sample with Claude Code activity recorded locally over the same interval. It appears only after the current week has at least 6 hours of samples, and is a lower bound: quota is sampled only while the popover or dashboard is open.

## Fixes

- OpenRouter: a rejected key now reads "Key rejected" with a prompt to replace it, and the server's reason appears on hover, instead of a bare "Error".
- A source that is failing (expired cookie, locked Keychain) keeps its row visible rather than being grouped with sources that were never connected.
- Restoring an account row in Settings takes effect on the home page immediately.

## Notes

- Includes Apple Silicon and universal macOS builds. Packages are code-signed but are not notarized.
