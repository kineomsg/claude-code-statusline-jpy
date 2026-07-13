# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## 2026-07-13

- **Fixed**: JPY exchange rate fetch failing silently due to frankfurter.app -> frankfurter.dev domain migration (301 redirect not followed)
- **Added**: subscription plans (Pro/Max) now show a plain Cost:~$X.XX(~¥X,XXX) estimate instead of the API-key-style budget bar/warning, since there is no real per-token spend to track on a flat-rate plan
- **Added**: thousands-separator commas on yen amounts (e.g. ¥2,306)
- **Fixed**: estimate tilde (~) prefix was missing in the JPY-rate-not-cached-yet fallback branch, and dollar-sign/tilde ordering was inconsistent ($~ vs ~$) in one branch
- **Fixed**: Max subscribers were being misclassified as API-key billed users for Cost/Session/Week display, since Claude.ai Max omits rate_limits from the API (upstream bug anthropics/claude-code#63659) and the old cost==0 detection heuristic broke once Claude Code started sending non-zero cost.total_cost_usd to all subscribers -- now detected via absence of ANTHROPIC_API_KEY/CLAUDE_CODE_USE_BEDROCK/CLAUDE_CODE_USE_VERTEX/CLAUDE_CODE_USE_FOUNDRY env vars
- **Docs**: removed stale bc dependency references, added uninstall.sh cache cleanup for cost_estimate.cache/lock, documented the subscription env-var detection edge case
