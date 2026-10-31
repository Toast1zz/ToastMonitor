## Fixed

- The quota bar now matches its number in Remaining mode. Thanks to yeyebbc for the fix.
- Claude and Grok logins recover on their own more reliably. When a renewal fails, ToastMonitor tries again every minute until it works, even with the panel closed. After an hour of failures it tries every 10 minutes, and opening the panel tries right away.
- Grok is now found when it was installed with its own installer, so its login can renew too.
- A Claude command-line tool that fails to start no longer keeps a CPU core busy during a login renewal.

## Changed

- Numbers stay plain. The "≈" and "estimated" notes added in 2.5.0 are gone from the menu bar, panel and dashboard, and balance warnings read "3.2d left" instead of "~3.2d left".
- The "Cowork & web" estimate is more accurate. It now also catches use that overlaps with Claude Code on this Mac, so that row and the totals that include it will go up, including for past days.
- Remaining mode shows only what's left. The comparison with how far through the period you are appears only in Used mode. The bars on Plans follow the same setting.
