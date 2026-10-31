## New

- Estimated usage is labeled. The headline token count still includes the "Cowork & web" estimate, and now says so: "Includes ≈… estimated" in the panel, "≈" in the menu bar and source rows, and "incl. … estimated" on Overview. Analysis says "recorded only".
- If the database is damaged or read-only, ToastMonitor now says so and offers Restore Latest Backup, Start Fresh or Show in Finder. The damaged file is renamed and kept, not deleted.
- Sessions shows how many sessions exist ("Latest 500 of …") and can load more. Titles no longer show attached-file lists, Markdown links or IDs.

## Fixed

- Back Up and Rebuild no longer deletes history whose log is gone. Only sessions whose log is still on this Mac are read again; the preview and confirmation say which is which.
- A log whose last line has no newline no longer stops a whole source from being counted.
- Prices corrected: Sonnet 5.5, Haiku 5.5 and the GPT-5.6 family were priced wrong, and gpt-6-sol and gpt-6-luna had no price. These rows are corrected once.
- Haiku 5.5 prompts over 100K tokens are charged the long-prompt rate. GPT prompts over 272K tokens are charged OpenAI's long-context rate for the whole request; OpenAI doesn't say whether the whole request or only the excess is charged, so this is an estimate.
- Changing the price table no longer recalculates costs already recorded. One-hour Claude cache writes are stored and priced on their own.
- Hermes usage split over several rows on the same route is now added up, and Hermes sessions show real dates instead of 1970.
- Refresh now reaches every source, including Grok and Command Code, from every Refresh entry.
- Opening ToastMonitor a second time brings the running copy forward instead of starting another.
- Plans no longer shows ended subscriptions as active; weekly plans show "/wk". In calendar mode, subscription spend covers only the selected period.
- With "Codex covered by subscription" on, Codex cost is zero everywhere.
- An update error from an older version clears itself.

## Changed

- Secondary text has more contrast in the panel and dashboard, in light and dark.
- Trend charts line dates up with their gridlines and no longer draw false peaks. By Model charts group models past the fifth into "Other".
- Performance reports one model at a time and shows "—" with fewer than 20 samples. Empty values show "—" instead of $0.00.
- DeepSeek Harness uses a darker blue so it is easy to tell apart from Codex.
- The minimum dashboard size is 960×660.
- Exports leave out remote feed addresses, and the save dialog says the file includes session titles and project names.
- The first launch after updating re-reads Claude logs once (about 15 seconds) to store one-hour cache writes.
