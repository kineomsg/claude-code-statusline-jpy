# claude-code-statusline

A statusline for [Claude Code](https://claude.ai/code) that shows model, rate limits, context usage, and daily cost in Japanese Yen.

> **What is the Claude Code statusline?**
> Claude Code has a built-in [`statusLine`](https://docs.anthropic.com/en/docs/claude-code/settings) feature that runs a shell command and displays its output at the bottom of the terminal UI. This repo provides that command — a script that reads Claude Code's internal JSON feed and formats it into a compact status bar.

## Preview

```
Sonnet4.6(high) Session:45%(14:30) Week:20%(2d3h) Ctx:▰▰▱▱▱40% Cost:▰▱▱▱▱~$0.15(¥230/¥500)
```

Over budget (Opus, subscription):

```
!!Opus4.8(high) Session:72%(15:05) Week:55%(1d3h) Ctx:▰▰▰▱▱60% Cost:!!▰▰▰▰▰~$3.20(¥480/¥500) Acct:▰▰▱▱▱35%
```

## Features

| Field | Description |
|---|---|
| `Sonnet4.6(high)` / `!!Opus4.8` | Model name and effort level; Opus is prefixed with `!!` |
| `Session:XX%(HH:MM)` | 5-hour rate limit usage and reset time (wall clock) |
| `Week:XX%(XdXh)` | 7-day rate limit usage and time until reset |
| `Ctx:▰▰▱▱▱XX%` | Context window usage (5-segment bar) |
| `Cost:▰▱▱▱▱~$X.XX(¥XXX/¥500)` | Daily cost in USD + JPY with budget bar (`~` on subscription plans) |
| `Acct:▰▱▱▱▱XX%` | Account monthly usage via Anthropic OAuth API (subscription only) |

**Cost display behavior:**
- Accumulates cost across sessions within the same day
- Resets automatically at midnight each day
- Exchange rate fetched weekly from ECB (European Central Bank) via [frankfurter.app](https://www.frankfurter.app/)
- If the exchange rate hasn't been fetched yet, the Cost field is not shown until the background refresh completes
- **Shown on subscription plans (Pro/Max)** with a `~` prefix indicating it's an API-equivalent estimate, not actual billing
- **Shown on API key / Azure AI Foundry** without the `~` prefix (reflects actual cost)
- Shows `!!` prefix when the ¥500 daily budget is exceeded

## Platform Support

| Platform | Script | Requirements |
|---|---|---|
| Linux | `statusline.sh` | `jq`, `bc`, `curl` |
| macOS | `statusline.sh` | `jq`, `bc`, `curl` (via Homebrew) |
| WSL | `statusline.sh` | `jq`, `bc`, `curl` |
| Git Bash (Windows) | `statusline.sh` | `jq`, `curl`, `bc` |
| Native Windows | `statusline.ps1` | PowerShell 5.1+ (no extra installs needed) |

<details>
<summary>Installing dependencies</summary>

**Ubuntu / Debian:** `sudo apt install jq bc curl`  
**macOS:** `brew install jq bc curl`  
**Arch Linux:** `sudo pacman -S jq bc curl`  
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
├── statusline.sh          # Linux / macOS / WSL
├── statusline.ps1         # Native Windows
├── jpy_rate.cache         # Exchange rate cache (auto-generated)
├── oauth_usage.cache      # Account usage cache (auto-generated, subscription only)
└── cost_budget.cache      # Daily cost cache (auto-generated)
```

### Cache file formats

**`jpy_rate.cache`**
```
<UnixTimestamp>:<JPY rate>
e.g. 1751234567:157.23
```

**`cost_budget.cache`**
```
<YYYY-MM-DD>:<cumulative USD>:<last session USD>
e.g. 2026-06-28:0.32:0.15
```

## Customization

To change the daily budget (default: ¥500):

`statusline.sh`:
```bash
budget_jpy=500  # change this value
```

`statusline.ps1`:
```powershell
$budgetJpy = 500  # change this value
```

## Troubleshooting

### Statusline doesn't appear in Cursor (or VS Code integrated terminal)

GUI apps on macOS launch with a minimal PATH that often excludes Homebrew's directories (`/opt/homebrew/bin`, `/usr/local/bin`). If `jq`, `bc`, or `curl` can't be found, the script produces no output and the statusline row disappears entirely.

The script already prepends these paths automatically. If it still doesn't appear, verify the tools are installed:

```bash
which jq bc curl
```

If any are missing, install them:

```bash
brew install jq bc curl   # macOS
sudo apt install jq bc curl  # Ubuntu / Debian
```

### Statusline appears in a normal terminal but not in Cursor

Run the script manually in Cursor's terminal to see any errors:

```bash
echo '{}' | ~/.claude/statusline.sh
```

If you get `command not found` for `jq` or `bc`, installing the missing tool will fix it.

## Notes

- **Subscription plans (Pro/Max)** show cost with a `~` prefix — this is an API-equivalent estimate, not your actual billing amount
- **API key and Azure AI Foundry** show cost without `~` — this reflects actual token spend
- JPY conversion uses a weekly-cached exchange rate from ECB and will not reflect real-time fluctuations. If the rate hasn't been fetched yet, the Cost field is simply not shown
- When using Azure AI Foundry, costs are estimated based on Anthropic's public pricing and may differ from your actual Azure bill
- The `Acct:` field requires an active Claude.ai OAuth session (`~/.claude/.credentials.json`) and is not available to API key users

## License

MIT
