## Fixed

- Official Claude and OpenAI prices are updated from the current rate cards. Fable and Mythos 5.2 now have prices, and several GPT-5 family models (including gpt-5.6 / Sol and gpt-5.4-mini) are no longer underpriced. Existing rows are corrected where the logs are still available.
- OpenRouter spend now follows your local calendar day, week and month, instead of mixing in UTC usage windows. All Time uses the account's cumulative total.
- If OpenRouter credits drop, or you replace the API key, today's spend is no longer wiped or padded with the new account's lifetime total.
- Oh My Pi token counts and costs are tracked correctly across streaming updates. Rows that already store a provider cost are labeled as actual, without changing the amounts.
- A damaged or empty text field in the database no longer crashes ToastMonitor.
- Opening the app no longer freezes the menu bar while the database migrates. Refresh still works if you click it before startup finishes, and quitting during startup no longer leaves a half-started session.
