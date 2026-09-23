# ToastMonitor v1.11.0

## New

- Connect an official DeepSeek account to display its balance in the popover.
- Read account-wide billed usage from DeepSeek Platform, including consumption from other devices, for the selected daily, weekly, or monthly period.
- Sign in through Chrome or Safari, including Google login, and explicitly import the active DeepSeek Platform tab's session. Credentials are validated and stored in macOS Keychain.
- Include DeepSeek billed usage in Spent. Convert CNY costs to USD with an editable accounting rate in Plans & Balance > DeepSeek. The default is 1 USD = 7 CNY; this is a manual accounting rate, not a live market quote.
- Display DeepSeek balances and billed costs with two decimal places while retaining calculation precision.

## Reliability

- Accept scientific-notation amounts returned by the billing API.
- Preserve the last successful result on temporary failures, report expired sessions, and prevent stale requests from replacing a newer account or period.
- Replace local actual costs attributed to the direct DeepSeek provider when account billing is available, avoiding duplicate inclusion of those local costs.

## Notes

- DeepSeek Platform integration is experimental and depends on its authenticated website API. Session expiry requires reconnection. Full-history billing is not available.
- An official DeepSeek API key supports balance queries only; period billing requires a Platform session.
- Browser import may require macOS Automation permission and the browser's Allow JavaScript from Apple Events setting. Import is explicit and limited to the active DeepSeek Platform tab.
- Includes Apple Silicon and universal macOS builds. Packages are code-signed but are not notarized.
