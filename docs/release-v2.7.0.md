## Added

- **Popover Tool / Model Switcher**: Added a persistent `By Tool` / `By Model` toggle next to `Spent` / `Value` in the menu-bar popover, keeping the share bar full-width and aggregating per-model totals in the lightweight snapshot.

## Improved

- **Unified Cross-Source Model Names**: Normalized trailing reasoning-effort, tier, and context-window suffixes (such as `-medium`, `-tiered-high`, `-900k`, `(Medium)`) in `ModelName.display(_:)` so identical models across different tools merge under one canonical name.
- **AI Company Brand Colors & Calm Quota Bars**: Colored models across Popover and Dashboard (`Overview`, `Analysis`, `Performance`) using their AI maker's official brand colors (Claude orange, Gemini blue, OpenAI green, DeepSeek blue, Qwen violet, etc.) with stepped tonal shades for multiple models from the same maker, and removed red/orange color shifts on high-usage quota bars and percentages.
