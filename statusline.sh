#!/bin/bash
input=$(cat)
now=$(date +%s)

# === Color Palette (Claude Gradient) ===
C_RESET=$'\e[0m'
C_PURPLE=$'\e[38;2;167;139;250m'   # model name
C_GREEN=$'\e[38;2;130;180;100m'    # healthy (<60%)
C_AMBER=$'\e[38;2;229;192;123m'    # warning (>=60%)
C_RED=$'\e[38;2;224;108;117m'      # critical (>=80%) / Opus !!
C_DIM=$'\e[38;2;92;99;112m'        # labels

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 80 ]; then printf "%s" "$C_RED"
    elif [ "$pct" -ge 60 ]; then printf "%s" "$C_AMBER"
    else printf "%s" "$C_GREEN"; fi
}

stat_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# === Single jq call for all JSON fields ===
eval "$(echo "$input" | jq -r '
    "model_id="      + (.model.id // "" | @sh) + "\n" +
    "model_display=" + (.model.display_name // "" | @sh) + "\n" +
    "effort="        + (.effort.level // "" | @sh) + "\n" +
    "h5_pct="        + (if .rate_limits.five_hour.used_percentage != null then (.rate_limits.five_hour.used_percentage | floor | tostring) else "" end | @sh) + "\n" +
    "h5_reset="      + (if .rate_limits.five_hour.resets_at != null then (.rate_limits.five_hour.resets_at | tostring) else "" end | @sh) + "\n" +
    "d7_pct="        + (if .rate_limits.seven_day.used_percentage != null then (.rate_limits.seven_day.used_percentage | floor | tostring) else "" end | @sh) + "\n" +
    "d7_reset="      + (if .rate_limits.seven_day.resets_at != null then (.rate_limits.seven_day.resets_at | tostring) else "" end | @sh) + "\n" +
    "ctx_pct="       + (if .context_window.used_percentage != null then (.context_window.used_percentage | floor | tostring) else "" end | @sh) + "\n" +
    "cost_usd="      + (if .cost.total_cost_usd != null then (.cost.total_cost_usd | tostring) else "" end | @sh)
' 2>/dev/null)"

fmt_reset_hm() {
    [ -z "$1" ] && echo "soon" && return
    local diff=$(( $1 - now ))
    [ $diff -le 0 ] && echo "soon" && return
    date -d "@$1" "+%H:%M" 2>/dev/null || date -r "$1" "+%H:%M" 2>/dev/null || echo "soon"
}

fmt_reset_dh() {
    [ -z "$1" ] && echo "soon" && return
    local diff=$(( $1 - now ))
    [ $diff -le 0 ] && echo "soon" && return
    local d=$(( diff / 86400 ))
    local h=$(( (diff % 86400) / 3600 ))
    local m=$(( (diff % 3600) / 60 ))
    if [ $d -gt 0 ]; then echo "${d}d${h}h"; else echo "${h}h${m}m"; fi
}

# === JPY rate (weekly cache, background refresh) ===
JPY_CACHE="$HOME/.claude/jpy_rate.cache"
JPY_LOCK="$HOME/.claude/jpy_rate.lock"
jpy_rate=""
if [ -f "$JPY_CACHE" ]; then
    cached_ts=$(cut -d: -f1 "$JPY_CACHE" | head -n 1)
    cached_rate=$(cut -d: -f2 "$JPY_CACHE" | head -n 1)
    if [[ "$cached_ts" =~ ^[0-9]+$ ]] && [ $(( now - cached_ts )) -lt 604800 ] && [ -n "$cached_rate" ]; then
        jpy_rate="$cached_rate"
    fi
fi
if [ -z "$jpy_rate" ]; then
    lock_age=$(( now - $(stat_mtime "$JPY_LOCK") ))
    if [ "$lock_age" -gt 30 ]; then
        touch "$JPY_LOCK" 2>/dev/null
        (
            fetched=$(curl -sf --max-time 5 "https://api.frankfurter.app/latest?from=USD&to=JPY" | jq -r '.rates.JPY // empty')
            if [ -n "$fetched" ]; then
                printf '%s:%s' "$now" "$fetched" > "${JPY_CACHE}.tmp" && mv "${JPY_CACHE}.tmp" "$JPY_CACHE"
            fi
            rm -f "$JPY_LOCK"
        ) >/dev/null 2>&1 &
    fi
fi

# === Anthropic OAuth account usage (5-minute cache, background fetch) ===
OAUTH_CACHE="$HOME/.claude/oauth_usage.cache"
OAUTH_LOCK="$HOME/.claude/oauth_usage.lock"
oauth_pct=""
if [ -f "$OAUTH_CACHE" ]; then
    oauth_age=$(( now - $(stat_mtime "$OAUTH_CACHE") ))
    if [ "$oauth_age" -lt 300 ]; then
        oauth_pct=$(cut -f3 "$OAUTH_CACHE" 2>/dev/null)
    fi
fi
if [ -z "$oauth_pct" ]; then
    lock_age=$(( now - $(stat_mtime "$OAUTH_LOCK") ))
    if [ "$lock_age" -gt 60 ]; then
        touch "$OAUTH_LOCK" 2>/dev/null
        (
            token=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
            if [ -n "$token" ]; then
                json=$(curl -sf --max-time 10 "https://api.anthropic.com/api/oauth/usage" \
                    -H "Authorization: Bearer $token" \
                    -H "anthropic-beta: oauth-2025-04-20" \
                    -H "Content-Type: application/json" 2>/dev/null)
                result=$(printf '%s' "$json" | jq -r '
                    if .extra_usage.used_credits then
                        [.extra_usage.used_credits, .extra_usage.monthly_limit, (.extra_usage.utilization * 100 | floor)] | @tsv
                    elif .spend.used.amount_minor then
                        [.spend.used.amount_minor, .spend.limit.amount_minor, (.spend.percent * 100 | floor)] | @tsv
                    else empty end' 2>/dev/null)
                if [ -n "$result" ]; then
                    printf '%s' "$result" > "${OAUTH_CACHE}.tmp" && mv "${OAUTH_CACHE}.tmp" "$OAUTH_CACHE"
                fi
            fi
            rm -f "$OAUTH_LOCK"
        ) >/dev/null 2>&1 &
    fi
fi

# === Build output ===
out=""

# Model prefix with effort level
if [ -n "$model_display" ]; then
    model_short=$(echo "$model_display" | tr -d ' ')
    model_str="${model_short}"
    [ -n "$effort" ] && model_str="${model_str}(${effort})"
    if [[ "$model_id" == *"opus"* ]]; then
        out="${C_RED}!!${model_str}${C_RESET}"
    else
        out="${C_PURPLE}${model_str}${C_RESET}"
    fi
fi

# Session rate limit
if [ -n "$h5_pct" ]; then
    rst=$(fmt_reset_hm "$h5_reset")
    c=$(color_for_pct "$h5_pct")
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Session:${C_RESET}${c}${h5_pct}%${C_DIM}(${rst})${C_RESET}"
fi

# Week rate limit
if [ -n "$d7_pct" ]; then
    rst=$(fmt_reset_dh "$d7_reset")
    c=$(color_for_pct "$d7_pct")
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Week:${C_RESET}${c}${d7_pct}%${C_DIM}(${rst})${C_RESET}"
fi

# Context window
if [ -n "$ctx_pct" ]; then
    filled=$(( ctx_pct / 20 ))
    [ $filled -gt 5 ] && filled=5
    empty=$(( 5 - filled ))
    c=$(color_for_pct "$ctx_pct")
    filled_bar="" empty_bar=""
    for ((i=1; i<=filled; i++)); do filled_bar="${filled_bar}▰"; done
    for ((i=1; i<=empty; i++)); do empty_bar="${empty_bar}▱"; done
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Ctx:${C_RESET}${c}${filled_bar}${C_DIM}${empty_bar}${C_RESET}${c}${ctx_pct}%${C_RESET}"
fi

# Daily cost
if [ -n "$cost_usd" ] && [ -n "$jpy_rate" ]; then
    BUDGET_CACHE="$HOME/.claude/cost_budget.cache"
    cur_date=$(date +%Y-%m-%d)
    cumulative_usd="0"
    last_session_usd="0"

    if [ -f "$BUDGET_CACHE" ]; then
        cached_date=$(cut -d: -f1 "$BUDGET_CACHE")
        if [ "$cached_date" = "$cur_date" ]; then
            cumulative_usd=$(cut -d: -f2 "$BUDGET_CACHE")
            last_session_usd=$(cut -d: -f3 "$BUDGET_CACHE")
        fi
    fi

    if [ "$(echo "$cost_usd < $last_session_usd" | bc)" = "1" ]; then
        cumulative_usd=$(echo "$cumulative_usd + $last_session_usd" | bc)
    fi
    printf '%s:%s:%s' "$cur_date" "$cumulative_usd" "$cost_usd" > "${BUDGET_CACHE}.tmp" && mv "${BUDGET_CACHE}.tmp" "$BUDGET_CACHE"

    total_usd=$(echo "$cumulative_usd + $cost_usd" | bc)
    total_jpy=$(echo "scale=6; $total_usd * $jpy_rate" | bc | awk '{printf "%d", $1 + 0.5}')

    if [ "${total_jpy:-0}" -gt 0 ] 2>/dev/null; then
        budget_jpy=500
        pct=$(( total_jpy * 100 / budget_jpy ))
        [ $pct -gt 100 ] && pct=100
        filled=$(( pct / 20 ))
        empty=$(( 5 - filled ))
        c=$(color_for_pct "$pct")
        filled_bar="" empty_bar=""
        for ((i=1; i<=filled; i++)); do filled_bar="${filled_bar}▰"; done
        for ((i=1; i<=empty; i++)); do empty_bar="${empty_bar}▱"; done
        bar="${filled_bar}${C_DIM}${empty_bar}"
        cost_fmt=$(printf "%.2f" "$total_usd")
        [ -n "$out" ] && out="$out "
        warn=""
        [ $pct -ge 100 ] && warn="!!"
        cost_est=""
        [ -n "$h5_pct" ] && cost_est="~"
        out="${out}${C_DIM}Cost:${C_RESET}${c}${warn}${bar}${cost_est}\$${cost_fmt}${C_RESET}(¥${total_jpy}/¥500)"
    fi
fi

# Account monthly usage (Anthropic OAuth API, shown only when cache is available)
if [ -n "$oauth_pct" ] && [ "$oauth_pct" -gt 0 ] 2>/dev/null; then
    [ "$oauth_pct" -gt 100 ] && oauth_pct=100
    filled=$(( oauth_pct / 20 ))
    [ $filled -gt 5 ] && filled=5
    empty=$(( 5 - filled ))
    c=$(color_for_pct "$oauth_pct")
    filled_bar="" empty_bar=""
    for ((i=1; i<=filled; i++)); do filled_bar="${filled_bar}▰"; done
    for ((i=1; i<=empty; i++)); do empty_bar="${empty_bar}▱"; done
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Acct:${C_RESET}${c}${filled_bar}${C_DIM}${empty_bar}${C_RESET}${c}${oauth_pct}%${C_RESET}"
fi

printf "%s" "$out"
