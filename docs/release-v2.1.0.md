## New: readable model names

- The dashboard now shows model names the way you would say them: "Opus 5.5", "GPT-5.6 Sol", "DeepSeek V4.1 Flash" instead of ids like `claude-opus-5-5`.
- One model that shows up under several spellings, such as `deepseek-v4-flash` and `deepseek/deepseek-v4-flash`, is now a single row.
- The Analysis CSV export still lists the original ids, one row each.

## Changed

- Quota bars keep showing how much of the period has passed even when your usage runs ahead of it: the part of the bar beyond that point is drawn in a lighter shade.

## Fixed

- When the panel had more cards than fit on screen, a dark band covered the bottom of the last card. The cards now fade out cleanly, and the fade disappears once you scroll to the end.
