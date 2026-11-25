## Fixed

- **Claude Login Renewal & Auto-Fetch**: Keep in-flight and scheduled Claude CLI login renewals running after the popover closes instead of resetting retries and immediately showing `Login expired`; bypass the 3-minute passive cooldown when reopening the popover in an error or unsynced state; retry transient Keychain read failures on known accounts and clear stale `/usr/bin/security` timeout locks on explicit refresh; recover on macOS wake (`NSWorkspace.didWakeNotification`); and wait for credential renewal confirmation after `/status` before closing the CLI probe.
