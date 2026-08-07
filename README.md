<h1 align="center">TokenBar</h1>

<p align="center">
  Codex and Claude usage, always visible in your Mac menu bar.
</p>

<p align="center">
  <img src="docs/images/tokenbar-menu-bar.png" width="220" alt="TokenBar showing Codex and Claude usage in the macOS menu bar">
</p>

<p align="center">
  Native macOS app. No browser tab, account dashboard, or manual tracking.
</p>

## What you get

<table>
  <tr>
    <td width="46%" align="center">
      <img src="docs/images/tokenbar-popover.png" width="380" alt="TokenBar usage panel showing Codex weekly and Claude session and weekly allowances">
    </td>
    <td width="54%">
      <strong>Always available</strong><br>
      See both providers from one compact menu-bar item.<br><br>
      <strong>The limits that matter</strong><br>
      Codex weekly usage plus Claude's five-hour session and weekly allowances.<br><br>
      <strong>Useful reset information</strong><br>
      View remaining allowance and the next reset time at a glance.<br><br>
      <strong>Quiet by design</strong><br>
      TokenBar has no Dock icon and can launch automatically when you sign in.
    </td>
  </tr>
</table>

## Install

### Requirements

- macOS 14 or newer
- [Apple Command Line Tools](#apple-command-line-tools)
- Codex CLI installed and signed in
- Claude Code installed and signed in

### Build and open TokenBar

```bash
git clone https://github.com/Prajwal-ak-0/token-usage-monitor.git
cd token-usage-monitor
bash scripts/test.sh
bash scripts/package_app.sh
ditto dist/TokenBar.app /Applications/TokenBar.app
open /Applications/TokenBar.app
```

TokenBar appears in the menu bar and registers itself to launch at login. If Claude is not connected, open TokenBar and select **Connect Claude**. Claude Code owns the browser sign-in and stores its credential in macOS Keychain.

<details>
  <summary id="apple-command-line-tools">Installing Apple Command Line Tools</summary>

  Run:

  ```bash
  xcode-select --install
  ```

  Complete Apple's installer, then run the TokenBar build commands again.
</details>

## Privacy and request safety

TokenBar is intentionally conservative with credentials and provider requests.

| Protection | Behavior |
| --- | --- |
| Credentials | Read from the providers' existing local sign-in state, held only in memory, and never written by TokenBar |
| Claude polling | At most one Anthropic usage request every 15 minutes |
| Rate limits | HTTP 429 responses trigger persistent exponential backoff and respect `Retry-After` |
| Offline behavior | The last successful Claude response remains available during rate limits and temporary network failures |
| Local cache | Stored as JSON data in macOS preferences; no access token is included |

## How it works

### Codex

TokenBar queries the local Codex app server through `account/rateLimits/read` and selects its weekly quota window.

### Claude

TokenBar reads the existing Claude Code OAuth credential from macOS Keychain and requests usage from Anthropic's authenticated Claude usage endpoint. This endpoint is not a documented public API and may change; TokenBar uses conservative polling, persistent caching, and rate-limit backoff to avoid unnecessary traffic.

## Updating

```bash
cd token-usage-monitor
git pull
bash scripts/test.sh
bash scripts/package_app.sh
pkill -x TokenBar || true
ditto dist/TokenBar.app /Applications/TokenBar.app
open /Applications/TokenBar.app
```

## Troubleshooting

| Problem | What to do |
| --- | --- |
| TokenBar is not visible | Run `open /Applications/TokenBar.app` |
| Claude is disconnected | Open TokenBar and select **Connect Claude** |
| Usage looks stale | Cached data is expected between 15-minute refreshes or while a provider is rate-limiting requests |
| TokenBar is in the wrong position | Hold Command and drag it to the preferred menu-bar position |
| The build fails after moving the project | Remove `.build`, then run `bash scripts/package_app.sh` again |

## Development

Run the parser and cache regression tests:

```bash
bash scripts/test.sh
```

Build an ad-hoc signed application:

```bash
bash scripts/package_app.sh
```

The generated application is written to `dist/TokenBar.app`.

## Project status

TokenBar is an independent personal project. It is not affiliated with or endorsed by OpenAI or Anthropic.
