## Fixed

- Claude Code usage is now more accurate. Work done by sub-agents is counted, and a reply that was saved more than once is counted once, using its final numbers.
- Codex no longer adds a turn each time it repeats its running total, so Codex token counts stop creeping up.
- DeepSeek Harness no longer counts the same step twice.
- Cheaper models such as mini, nano and flash are priced at their own rates instead of the full model's rate.
- Prices were added for Claude Haiku 5.5, GPT-6.1 Sol and GPT-6 Astra.

## Changed

- The first launch after updating recounts the sessions whose logs are still on your Mac. History from logs that were already deleted stays as it is.
- Codex and Grok limits are off on a fresh install. If you already used ToastMonitor, they stay on. You can change both in Settings → Accounts.
- ToastMonitor checks for new usage less often when nothing is changing, and pauses while your Mac sleeps.
