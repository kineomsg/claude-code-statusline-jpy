# claude-code-statusline

A statusline for [Claude Code](https://claude.ai/code) that shows model, rate limits, context usage, and daily cost in Japanese Yen.

> **What is the Claude Code statusline?**
> Claude Code has a built-in [`statusLine`](https://docs.anthropic.com/en/docs/claude-code/settings) feature that runs a shell command and displays its output at the bottom of the terminal UI. This repo provides that command — a script that reads Claude Code's internal JSON feed and formats it into a compact status bar.

## Preview

Subscription user (Pro):

```
Sonnet4.6(high) Session:45%(14:30) Week:20%(2d3h) Ctx:▰▰▱▱▱40% Cost:~$14.24(~¥2,306)
```

Subscription user (Max — rate limits not reported by API):

```
Sonnet4.6(high) Session:- Week:- Ctx:▰▰▱▱▱40% Cost:~$14.24(~¥2,306)
```

API key user with spending limit (2nd session of the day):

```
Sonnet4.6(high) Ctx:▰▰▱▱▱40% Cost:▰▰▱▱▱$1.27(¥67 Today:¥200/¥500)
```

API key user, over daily budget:

```
!Opus4.8(high) Ctx:▰▰▰▱▱60% Cost:!!▰▰▰▰▰$3.20(¥200 Today:¥510/¥500)
```

Fable5 user:

```
!!Fable5 Ctx:▰▰▱▱▱40%
```

## Features

| Field | Description |
|---|---|
| `Sonnet4.6(high)` / `!Opus4.8` / `!!Fable5` | Model name and effort level; Opus is prefixed with amber `!`, Fable5 with red `!!` |
| `Session:XX%(HH:MM)` / `Session:-` | 5-hour rate limit usage and reset time; shows `-` on Max when the API doesn't report limits |
| `Week:XX%(XdXh)` / `Week:-` | 7-day rate limit usage and time until reset; shows `-` on Max when the API doesn't report limits |
| `Ctx:▰▰▱▱▱XX%` | Context window usage (5-segment bar) |
| `Cost:▰▱▱▱▱$X.XX(¥XXX Today:¥XXX/¥500)` | Daily total in USD, current session and daily total in JPY with budget bar |

**Cost display behavior:**
- First value (`¥XXX`) is the **current session** cost; `Today:¥XXX/¥500` is the **daily cumulative** total across all sessions
- Daily total resets automatically at midnight
- Exchange rate fetched weekly from ECB (European Central Bank) via [frankfurter.dev](https://www.frankfurter.dev/)
- If the exchange rate hasn't been fetched yet (or the host can't reach frankfurter.dev), the Cost field still shows the plain USD amount (e.g. `Cost:$1.27`) without the JPY conversion/budget bar, until the background refresh completes
- **Subscription plans (Pro/Max)** display a plain `Cost:~$X.XX(~¥X,XXX)` format (no budget bar/warning, where `~` signals a client-side estimate rather than actual billing)
- **API-key and other billed users** show the full colored budget bar, JPY session/daily total conversion, and `!!` warning prefix when the ¥500 daily budget is exceeded

## Platform Support

| Platform | Script | Requirements |
|---|---|---|
| Linux | `statusline.sh` | `jq`, `curl` |
| macOS | `statusline.sh` | `jq`, `curl` (via Homebrew) |
| WSL | `statusline.sh` | `jq`, `curl` |
| Git Bash (Windows) | `statusline.sh` | `jq`, `curl` |
| Native Windows | `statusline.ps1` | PowerShell 5.1+ (no extra installs needed) |

<details>
<summary>Installing dependencies</summary>

**Ubuntu / Debian:** `sudo apt install jq curl`  
**macOS:** `brew install jq curl`  
**Arch Linux:** `sudo pacman -S jq curl`  
**Windows:** PowerShell version needs no extras.

</details>

## Quick Install

### Linux / macOS / WSL

```bash
git clone https://github.com/kineomsg/claude-code-statusline.git
cd claude-code-statusline
bash install.sh
```

Then restart Claude Code. That's it.

### Native Windows (PowerShell)

```powershell
git clone https://github.com/kineomsg/claude-code-statusline.git
cd claude-code-statusline
Copy-Item statusline.ps1 "$env:USERPROFILE\.claude\statusline.ps1"
```

Then follow the manual settings step below.

---

## Manual Setup

### Linux / macOS / WSL

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

Make the script executable:

```bash
chmod +x ~/.claude/statusline.sh
```

### Native Windows (PowerShell)

Add to `%USERPROFILE%\.claude\settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -File ~/.claude/statusline.ps1"
  }
}
```

## Files

```
~/.claude/
├── statusline.sh            # Linux / macOS / WSL
├── statusline.ps1           # Native Windows
├── jpy_rate.cache           # Exchange rate cache (auto-generated)
├── jpy_rate.fail            # Marker after a failed rate fetch: retries back off for 1h (auto-generated)
├── cost_budget.cache        # Daily per-session cost ledger (auto-generated)
├── cost_estimate.cache      # Transcript-based cost estimates, one line per transcript (auto-generated)
└── statusline_gauges.cache  # Gauge fallback cache, one line per session (auto-generated)
```

### Cache file formats

**`jpy_rate.cache`**
```
<UnixTimestamp>:<JPY rate>
e.g. 1751234567:157.23
```

**`cost_budget.cache`** — line 1 is the date, then one line per session so
concurrent sessions can't inflate each other's daily total:
```
<YYYY-MM-DD>
<session_key>|<banked USD>|<latest session USD>
e.g. 2026-06-28
     3f2a…|0.32|0.15
```

## Customization

Set environment variables (in the shell that launches Claude Code):

| Variable | Default | Effect |
|---|---|---|
| `CC_STATUSLINE_BUDGET_JPY` | `500` | Daily budget for the cost bar. `0` hides the bar and shows amounts only. |
| `CC_STATUSLINE_JPY` | `1` | `0` disables the JPY conversion entirely (no network fetch, plain `$` display). |

## Troubleshooting

### Statusline doesn't appear in Cursor (or VS Code integrated terminal)

GUI apps on macOS launch with a minimal PATH that often excludes Homebrew's directories (`/opt/homebrew/bin`, `/usr/local/bin`). If `jq` or `curl` can't be found, the script produces no output and the statusline row disappears entirely.

The script already prepends these paths automatically. If it still doesn't appear, verify the tools are installed:

```bash
which jq curl
```

If any are missing, install them:

```bash
brew install jq curl   # macOS
sudo apt install jq curl  # Ubuntu / Debian
```

### Statusline appears in a normal terminal but not in Cursor

Run the script manually in Cursor's terminal to see any errors:

```bash
echo '{}' | ~/.claude/statusline.sh
```

If you get `command not found` for `jq`, installing the missing tool will fix it.

## Notes

- **Subscription plans (Pro/Max)** display a plain estimate with no budget bar (prefixed with `~`, e.g. `Cost:~$14.24(~¥2,306)`)
- **Claude.ai Max** subscribers see `Session:-` and `Week:-` — the Anthropic API currently does not report rate limit data for Max accounts. This is a [known bug in Claude Code](https://github.com/anthropics/claude-code/issues/63659) affecting all platforms (not Windows-only despite the issue title). The script displays `-` as a placeholder until Anthropic fixes the upstream issue
- **Subscription plan edge case**: If you are on a subscription plan (Pro/Max) but the Cost field still shows the API-key-style colored budget bar instead of the plain `~$X.XX(~¥X,XXX)` estimate, check whether `ANTHROPIC_API_KEY`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, or `CLAUDE_CODE_USE_FOUNDRY` happen to be set in your shell environment (e.g. left over from an unrelated project). The script uses these to distinguish real billed API/cloud usage from a Claude.ai OAuth subscription whenever `rate_limits` is not reported by the API (which is always the case for Max due to the bug above) -- unset them if they are not actually being used for this session.
- **API key** shows the Cost field reflecting actual billed spend from Anthropic
- JPY conversion uses a weekly-cached exchange rate from ECB and will not reflect real-time fluctuations. If the rate hasn't been fetched yet (or is unreachable from your network), the Cost field falls back to a plain USD amount with no JPY conversion/budget bar — it does not disappear entirely
- **Azure AI Foundry, Amazon Bedrock, and Google Vertex AI** show an estimated cost (prefixed with `~`) calculated from token usage in the session transcript and Anthropic's published per-model pricing — this may differ from your actual provider bill, since Claude Code does not report exact billing for these auth paths
- The estimated cost relies on Claude Code passing `transcript_path` in the statusLine hook JSON. If a particular Claude Code version/build omits it, the script falls back to locating the most recently modified transcript under `~/.claude/projects/<cwd with "/" replaced by "-">/` instead

## License

MIT
