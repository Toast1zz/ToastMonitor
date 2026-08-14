# Security Policy

## Reporting a vulnerability

This app processes AI usage data and stores API credentials (OpenRouter keys, OpenCode Go cookies) in the macOS Keychain. Please report any issue that could expose those credentials or user data.

**Do not open a public issue for security problems.** Use GitHub's private security advisory flow:

- Go to https://github.com/neko1chau/ToastMonitor/security/advisories and click **New draft security advisory**
- Or email the maintainer directly if the advisory form is not available

Please include:

- The affected version (from `--version` or the About panel)
- macOS version
- Steps to reproduce
- A description of the impact
- Sanitized logs only — never paste real tokens, cookies or session content

You should receive a response within a few days. Public disclosure happens after a fix is released.

## What we consider a vulnerability

- Exposure of Keychain-stored credentials (plaintext fallback, logging, argv leakage)
- Unauthorized network requests to unintended hosts (see the remote-feed validation rules)
- SQL injection or integrity issues in the local database
- Path traversal or permission bugs in backup/export code

## Non-security bugs

Open a regular issue using the bug report template.
