# TokenBar

TokenBar is a small native macOS menu-bar app for monitoring Codex and Claude plan usage without opening either usage page.

It shows:

- Codex weekly usage
- Claude five-hour session usage
- Claude weekly usage, including model-specific windows when available
- Reset times and remaining allowance

TokenBar has no Dock icon, launches automatically at login, and refreshes quietly in the background.

## Privacy and request safety

- Credentials never leave your Mac except in authenticated requests to their original provider.
- Tokens are held in memory and are never written by TokenBar.
- Claude usage is cached locally as JSON data.
- Anthropic is contacted at most once every 15 minutes.
- HTTP 429 responses trigger persistent exponential backoff, and `Retry-After` is honored.
- Cached values remain visible during rate limits and temporary network failures.

## Requirements

- macOS 14 or newer
- Apple Command Line Tools
- Codex CLI installed and signed in
- Claude Code installed and signed in

Install the Apple Command Line Tools if needed:

```bash
xcode-select --install
```

## Install

Clone and build TokenBar locally:

```bash
git clone https://github.com/Prajwal-ak-0/token-usage-monitor.git
cd token-usage-monitor
bash scripts/test.sh
bash scripts/package_app.sh
ditto dist/TokenBar.app /Applications/TokenBar.app
open /Applications/TokenBar.app
```

TokenBar will appear in the menu bar and register itself to launch at login.

If Claude is not connected, open TokenBar and select **Connect Claude**. Claude Code owns the browser sign-in and stores its credential in macOS Keychain.

## How it works

### Codex

TokenBar queries the local Codex app server using `account/rateLimits/read` and displays its weekly quota window.

### Claude

TokenBar reads the existing Claude Code OAuth credential from macOS Keychain and requests usage from Anthropic's authenticated Claude usage endpoint. This endpoint is not a documented public API and may change; TokenBar therefore uses conservative polling, persistent caching, and rate-limit backoff.

## Update

Pull the latest source and rebuild:

```bash
git pull
bash scripts/test.sh
bash scripts/package_app.sh
pkill -x TokenBar || true
ditto dist/TokenBar.app /Applications/TokenBar.app
open /Applications/TokenBar.app
```

## Development

Run parser and cache regression tests:

```bash
bash scripts/test.sh
```

Build an ad-hoc signed application:

```bash
bash scripts/package_app.sh
```

The generated application is written to `dist/TokenBar.app`.

## Troubleshooting

- **TokenBar is not visible:** run `open /Applications/TokenBar.app`.
- **Claude is disconnected:** open TokenBar and select **Connect Claude**.
- **Usage looks stale:** cached data is expected between 15-minute refreshes or while a provider is rate-limiting requests.
- **The app moves in the menu bar:** hold Command and drag TokenBar to your preferred position.

## Status

TokenBar is an independent personal project. It is not affiliated with or endorsed by OpenAI or Anthropic.
