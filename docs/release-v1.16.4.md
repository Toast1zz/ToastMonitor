Corrects Claude model pricing and Codex cached-input costs, prevents duplicate Hermes usage when switching sources, and imports OpenCode cache-only usage. Also preserves actual zero-cost records, validates backups before restoring, saves a pre-restore recovery snapshot, removes legacy credentials from database exports, and prevents managed backups from overwriting each other.

Known issue: the light-mode Analysis visual regression still differs from the reference in the development VM. The threshold and baseline are unchanged; failing screenshots are now retained for review.
