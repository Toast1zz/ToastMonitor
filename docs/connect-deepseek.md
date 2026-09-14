# DeepSeek balance and account spend

## Connect

Open **Dashboard > Plans & Balance > DeepSeek > Connect DeepSeek**.

- **Browser** (recommended, including Google accounts): choose Chrome or Safari, click **Open DeepSeek in Browser**, and sign in normally. Leave the signed-in Platform tab selected, return to ToastMonitor, and click **Connect from Browser**. Only that active DeepSeek tab's `userToken` is read, then validated and saved in Keychain. macOS may ask permission for ToastMonitor to automate the selected browser.
- Chrome requires **View > Developer > Allow JavaScript from Apple Events**; Safari requires **Develop > Allow JavaScript from Apple Events**. ToastMonitor reports a specific permission error instead of silently failing. It does not enable these browser permissions automatically.
- **In-App** is retained for compatible email sign-ins. Google authentication and secondary login windows switch to the real-browser route; Google OAuth is not run inside a WebView. A fresh Platform page is opened in the browser, not a partial OAuth URL/state from the embedded window.
- **Platform Session** accepts a Platform `userToken` locally when the embedded login page is unavailable. This is a website login credential, not an API key. Never share it in chat, screenshots, diagnostic logs, or bug reports.
- **API Key** queries the official public balance endpoint only. Period spend requires a Platform connection.

Only one credential/account is active at a time. Switching between Platform and API Key replaces the connection and clears the previous account's displayed data. Browser import runs only when explicitly clicked; it never reads browser profiles, other tabs, Google cookies, or password fields. ToastMonitor never combines an API-key balance with an unrelated website session.

## Popover

- **DeepSeek** in Quota displays the latest account balance. CNY and USD remain separate; paid and granted balances are detailed in Plans & Balance.
- **Spent** includes the official account's billed consumption, including other devices and all API-key/model series returned by the Platform. CNY spend is converted to USD using the editable **USD conversion** rate in Plans & Balance > DeepSeek (default: 1 USD = 7 CNY, a manual accounting rate, not a live market quote), then added to the dollar total. The rate is saved and changes apply immediately. Unsupported currencies remain explicit rather than being silently dropped. While account billing is available for the selected period, local actual costs explicitly attributed to the `deepseek` provider are replaced by account billing. Other providers are not inferred from model names. Balance stays in its original currency. Balance and spend display two decimal places; calculations retain their original precision until final display.
- Today, 7 Days and 30 Days follow the selected control. Calendar mode follows the configured week start and calendar month. The Platform uses billing-day buckets at the current fixed UTC offset, shown in the detail view/tooltip. On a DST transition this is not a variable-offset hourly ledger.
- **All Time** displays **Full history unavailable**. There is no verified complete-history contract for this internal endpoint; the app does not relabel a limited window as all-time spend.

The current day's amount is the latest billed usage returned by DeepSeek, not a promise of real-time settlement. No consumption is inferred from wallet changes, so recharges are not mistaken for negative spending. The app does not convert or add different currencies.

## Refresh and disconnect

Visible windows poll every 60 seconds; background polling uses five minutes. The refresh button also refreshes DeepSeek. Failures back off, keep the last successful snapshot with a stale indication, and never become zero spend. Changing periods clears the old period immediately. Expired sessions require reconnecting.

Use **Disconnect** in Plans & Balance to clear the saved credential and account display. The Popover settings toggle restores a hidden DeepSeek balance row.

## Integration boundary

This is an **experimental** integration with private DeepSeek Platform endpoints, which can change without notice:

```text
GET https://platform.deepseek.com/api/v0/users/get_user_summary
GET https://platform.deepseek.com/api/v0/usage/by_api_key/cost?start=...&end=...&tz=...
GET https://api.deepseek.com/user/balance  (API-key balance only)
```

Platform requests use the Platform session's Bearer token and `x-client-platform: web`. API keys are sent only to the public balance endpoint. Credential-bearing requests reject redirects, do not use a persistent cookie store, and cap response bodies at 5 MB. Unsupported/malformed responses or explicit pagination are treated as unavailable, not as complete zero-valued reports.

Endpoint and response-shape references checked on September 14, 2026:

- [DeepSeek public balance documentation](https://api-docs.deepseek.com/api/get-user-balance)
- [CodexBar's DeepSeek integration notes](https://github.com/steipete/CodexBar/blob/main/docs/deepseek.md)
- [Platform cost response structure](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/DeepSeek/DeepSeekUsageCostParser.swift)

Unit tests use synthetic payloads; a successful build is not proof of a live authenticated DeepSeek response. Final account verification requires a user sign-in and comparison with the Platform's usage page for the same date range and timezone.
