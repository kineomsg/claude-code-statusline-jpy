# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## 2026-07-15

- **Changed**: Session/Week gauge colors now factor in pace, not just raw usage percentage. A projected end-of-window landing percentage is computed from elapsed time within the 5-hour/7-day window (skipped for the first 5% of the window to avoid noise), using its own thresholds (green <110%, amber 110-150%, red 150%+) since steady/on-pace usage naturally projects to ~100% and shouldn't be flagged. The final color is the more severe of the raw-usage color (existing 60%/80% thresholds) and the pace color, so genuinely high raw usage late in the window still warns regardless of pace

## 2026-07-14

- **Fixed**: daily "Today" total inflating massively when two or more sessions ran concurrently — the session-restart heuristic (cost decreased => bank previous run) fired on every alternation between sessions sharing one cost_budget.cache. The cache is now a per-session ledger (line 1 = date, then `<session_key>|<banked>|<latest>` per session) keyed by session_id
- **Fixed** (Windows): JPY rate fetch could never complete — Start-Job children are killed when the parent statusline process exits (~100ms). Background work (rate fetch, cost estimate) now re-invokes statusline.ps1 as a detached process via Start-Process with -FetchJpyRate / -ComputeCostFor worker flags
- **Fixed** (Windows): 0% gauge values were treated as missing (`-not $pct` is true for 0), causing spurious cache fallback; now compared against $null
- **Fixed**: Bedrock model IDs (`us.anthropic.claude-*-YYYYMMDD-v1:0`) fell through to default Sonnet pricing in the cost estimator because region prefix and `-vN:0` suffix were never stripped — Opus-on-Bedrock costs were underestimated ~40%
- **Changed**: cost estimate is now computed only in the background (bash: subshell; Windows: detached worker) — first render of a new transcript skips the cost segment instead of blocking on a potentially huge transcript; the estimator jq pass is now a single streaming `jq -Rn 'reduce inputs…'` (constant memory) and PowerShell uses `[IO.File]::ReadLines` streaming
- **Changed**: gauge fallback cache and cost estimate cache are now multi-line, keyed per session / per transcript, so concurrent sessions no longer cross-contaminate or thrash each other's entries; unchanged-value renders skip the disk write
- **Added**: `CC_STATUSLINE_BUDGET_JPY` (0 = amounts only, no bar) and `CC_STATUSLINE_JPY=0` (disable JPY entirely) env vars
- **Added**: 1h back-off after a failed JPY rate fetch (jpy_rate.fail marker) instead of retrying every 30s while offline; a stale cached rate is now still displayed while a refresh is pending
- **Added**: degraded fallback when jq is missing (model name + `[statusline: jq not found]`) instead of a silent blank statusline
- **Fixed**: install.sh now works from any cwd (`cd "$(dirname "$0")"`), backs up settings.json before editing, and no longer half-installs when settings.json is invalid JSON; uninstall.sh cleans up all cache/lock/.tmp leftovers and also backs up settings.json
- **Changed**: `export LC_NUMERIC=C` guards printf/awk number formatting on comma-decimal locales; temp files are PID-suffixed to avoid concurrent-writer collisions

## 2026-07-13

- **Fixed**: JPY exchange rate fetch failing silently due to frankfurter.app -> frankfurter.dev domain migration (301 redirect not followed)
- **Added**: subscription plans (Pro/Max) now show a plain Cost:~$X.XX(~¥X,XXX) estimate instead of the API-key-style budget bar/warning, since there is no real per-token spend to track on a flat-rate plan
- **Added**: thousands-separator commas on yen amounts (e.g. ¥2,306)
- **Fixed**: estimate tilde (~) prefix was missing in the JPY-rate-not-cached-yet fallback branch, and dollar-sign/tilde ordering was inconsistent ($~ vs ~$) in one branch
- **Fixed**: Max subscribers were being misclassified as API-key billed users for Cost/Session/Week display, since Claude.ai Max omits rate_limits from the API (upstream bug anthropics/claude-code#63659) and the old cost==0 detection heuristic broke once Claude Code started sending non-zero cost.total_cost_usd to all subscribers -- now detected via absence of ANTHROPIC_API_KEY/CLAUDE_CODE_USE_BEDROCK/CLAUDE_CODE_USE_VERTEX/CLAUDE_CODE_USE_FOUNDRY env vars
- **Docs**: removed stale bc dependency references, added uninstall.sh cache cleanup for cost_estimate.cache/lock, documented the subscription env-var detection edge case
