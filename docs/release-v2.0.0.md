## A redesigned menu bar panel

- The Today / 7 Days / 30 Days / All Time switch now sits inside the usage card, because it only changes those numbers. Quota and Balance below always show what you have left right now.
- Each quota bar also shows how much of its period has already passed, as a darker part of the track. If your usage runs past it, you are using the quota faster than time.
- Balances take one short line per account and stay quiet while they are fine. An account gets its own highlighted line only when it will run out within about a week at your recent pace, is empty, or cannot be read.
- The Activity heatmap uses four clearly different shades, so busy and quiet days are easy to tell apart even if you had a few very heavy days.
- When an account cannot refresh, a small question mark appears next to it. Click it to see what went wrong and how to fix it. No more red error text.

## X Subscription

- If you have the new X Subscription, add it under Subscriptions in Settings › Sources and the panel shows its name. Grok's own service still reports some of these plans as SuperGrok.

## Fixed

- After Claude Code updated through Homebrew, macOS could show "Apple cannot verify claude" every time ToastMonitor started. ToastMonitor no longer triggers it; when your Claude login expires, it asks you to run claude in Terminal instead.
