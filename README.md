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
- [CodexBar](https://github.com/steipete/CodexBar) installed in `/Applications` or `~/Applications` for automatic Claude credential renewal (its menu-bar app can remain closed)

### Build and open TokenBar

```bash
git clone https://github.com/Prajwal-ak-0/tokenbar.git
cd tokenbar
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
| Claude polling | At most one usage probe every 5 minutes; repeated Refresh clicks share cached data |
| Rate limits | Persistent 5–30 minute exponential backoff for reported rate limits; the direct OAuth fallback also honors numeric or HTTP-date `Retry-After`, including longer server delays |
| Offline behavior | The last successful Claude response remains available during rate limits and temporary network failures |
| Local cache | Stored as JSON data in macOS preferences; no access token is included |

## How it works

### Codex

TokenBar queries the local Codex app server through `account/rateLimits/read` and selects its weekly quota window.

### Claude

TokenBar prefers the installed CodexBar CLI adapter with explicit `--provider claude --source cli --format json`. The adapter reads Claude Code's built-in `/usage` screen through a temporary terminal session. Claude Code handles its own saved sign-in and token renewal, so TokenBar does not need a separate Keychain grant or a manually copied access token. This source follows the Claude Code account, rather than importing a potentially different browser account. The CodexBar menu-bar app does not need to run.

The helper runs with Claude safe mode and automatic updates disabled. Only quota windows, reset times, plan and the source measurement timestamp enter TokenBar's cache; account identity and raw diagnostics are discarded. Old, malformed, failed or unexpected-source responses cannot be relabeled as fresh measurements. A failed probe retries automatically after the cooldown without switching to a second network source.

If the adapter is not installed, TokenBar retains its direct OAuth compatibility path. That path silently reads Claude Code's existing Keychain credential and requests Anthropic's usage endpoint; explicit **Authorize Claude access** is available only for this fallback. Installing CodexBar enables the automatic CLI path on the next eligible check. TokenBar never exchanges Claude Code's rotating refresh token itself. These provider interfaces can change; errors remain visible beside the last successful measurement.

### Refresh and recovery

Each provider shows the age of its own measurement. Hover for the exact capture time; cached values keep their original timestamp. Percentages preserve fractional values, and Claude's plan comes from the selected source instead of assuming Max. CLI percentages have the precision reported by Claude Code's usage screen. Reset countdowns are computed locally; a passed reset triggers a fresh measurement when eligible and never invents a zero-percent value.

Automatic checks adapt to interaction: every 5 minutes for an hour after opening the panel, every 15 minutes for the following three hours, and every 30 minutes when idle longer, during idle Low Power Mode, or under serious thermal pressure. Recent panel interaction retains the five-minute cadence in Low Power Mode. Opening the panel checks eligible data immediately. UI countdowns update locally every 15 seconds without provider requests. Persisted cooldowns take priority over resets, manual Refresh, app restarts and adaptive scheduling.

Model-specific limits are available behind a disclosure below Claude's primary rows; the disclosure turns amber when an additional limit reaches 75%. Settings, including **Launch at Login** and **Quit TokenBar**, live in the gear menu. TokenBar allows one running instance per app bundle identifier; separate monitors such as CodexBar have their own polling schedules.

For the direct OAuth compatibility path, a rebuilt app or rotated Claude Keychain item may need a new grant. The preferred CLI path avoids TokenBar reading that foreign item. A genuinely signed-out Claude Code still requires signing in; TokenBar cannot restore a revoked account session without authentication.

## Updating

```bash
cd tokenbar
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
| Claude has no saved sign-in | Select **Connect Claude**; only this action starts browser sign-in |
| Claude Keychain access is unavailable | Install CodexBar to enable automatic CLI checks; its menu-bar app can stay closed |
| Claude session expired | With the CodexBar adapter installed, Claude Code renews its own credential during scheduled usage probes; if actually signed out, connect Claude once |
| Claude returns HTTP 403 | Check account permissions on the Claude usage page; repeated sign-in is not assumed to fix it |
| Claude is rate limited | Wait until the displayed next check; manual Refresh and restarts preserve the cooldown |
| Multiple usage monitors are running | Keep one Claude monitor active to avoid polling the same endpoint from multiple apps |
| Usage looks stale | Check Claude’s capture age, next-check time and any error below the bars; `~` in the menu bar marks stale Claude data |
| TokenBar is in the wrong position | Hold Command and drag it to the preferred menu-bar position |
| The build fails after moving the project | Remove `.build`, then run `bash scripts/package_app.sh` again |

## Development

Run the parser and Claude service regression tests (synthetic credentials, an injected clock, in-memory preferences and stubbed responses; no real Keychain or API calls):

```bash
bash scripts/test.sh
```

Check native popover sizing, including permission errors, long diagnostics and model-limit expansion:

```bash
bash scripts/test_layout.sh
```

The layout checks require a macOS graphical login session. They construct offscreen views with synthetic data and make no provider requests or credential reads.

Build an ad-hoc signed application:

```bash
bash scripts/package_app.sh
```

The generated application is written to `dist/TokenBar.app`.

## Design references

The panel uses native AppKit vibrancy, system typography and SF Symbols. Provider SVG marks come from [CodexBar](https://github.com/steipete/CodexBar), with its MIT notice included in `Resources/ProviderIcons-LICENSE.txt` and the packaged app. Refresh behavior was compared with CodexBar's [refresh-loop documentation](https://github.com/steipete/CodexBar/blob/main/docs/refresh-loop.md); TokenBar retains a five-minute Claude floor even during recent interaction.

## Project status

TokenBar is an independent personal project. It is not affiliated with or endorsed by OpenAI or Anthropic.
