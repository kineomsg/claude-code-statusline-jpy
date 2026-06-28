#!/bin/bash
input=$(cat)
now=$(date +%s)

# === Color Palette (Claude Gradient) ===
C_RESET=$'\e[0m'
C_PURPLE=$'\e[38;2;167;139;250m'   # model name
C_GREEN=$'\e[38;2;130;180;100m'    # healthy (<60%)
C_AMBER=$'\e[38;2;229;192;123m'    # warning (>=60%)
C_RED=$'\e[38;2;224;108;117m'      # critical (>=80%) / Opus !!
C_DIM=$'\e[38;2;92;99;112m'        # labels (Session: Week: Ctx: Cost:)

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 80 ]; then printf "%s" "$C_RED"
    elif [ "$pct" -ge 60 ]; then printf "%s" "$C_AMBER"
    else printf "%s" "$C_GREEN"; fi
}

# Model info
model_id=$(echo "$input" | jq -r '.model.id // empty')
model_display=$(echo "$input" | jq -r '.model.display_name // empty')

# Rate limits
h5_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | cut -d. -f1)
h5_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
d7_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | cut -d. -f1)
d7_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

fmt_reset_hm() {
    [ -z "$1" ] && echo "soon" && return
    local diff=$(( $1 - now ))
    [ $diff -le 0 ] && echo "soon" && return
    local h=$(( diff / 3600 ))
    local m=$(( (diff % 3600) / 60 ))
    echo "${h}h${m}m"
}

fmt_reset_dh() {
    [ -z "$1" ] && echo "soon" && return
    local diff=$(( $1 - now ))
    [ $diff -le 0 ] && echo "soon" && return
    local d=$(( diff / 86400 ))
    local h=$(( (diff % 86400) / 3600 ))
    local m=$(( (diff % 3600) / 60 ))
    if [ $d -gt 0 ]; then
        echo "${d}d${h}h"
    else
        echo "${h}h${m}m"
    fi
}

ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty' | cut -d. -f1)

# JPY rate cache (weekly refresh via ECB/frankfurter.app)
JPY_CACHE="$HOME/.claude/jpy_rate.cache"
jpy_rate=""
if [ -f "$JPY_CACHE" ]; then
    cached_ts=$(cut -d: -f1 "$JPY_CACHE")
    cached_rate=$(cut -d: -f2 "$JPY_CACHE")
    if [ $(( now - cached_ts )) -lt 604800 ] && [ -n "$cached_rate" ]; then
        jpy_rate="$cached_rate"
    fi
fi
if [ -z "$jpy_rate" ]; then
    fetched=$(curl -sf --max-time 3 "https://api.frankfurter.app/latest?from=USD&to=JPY" | jq -r '.rates.JPY // empty')
    if [ -n "$fetched" ]; then
        jpy_rate="$fetched"
        echo "${now}:${fetched}" > "$JPY_CACHE"
    fi
fi

# Model prefix
out=""
if [ -n "$model_display" ]; then
    model_short=$(echo "$model_display" | tr -d ' ')
    if [[ "$model_id" == *"opus"* ]]; then
        out="${C_RED}!!${model_short}${C_RESET}"
    else
        out="${C_PURPLE}${model_short}${C_RESET}"
    fi
fi

if [ -n "$h5_pct" ]; then
    rst=$(fmt_reset_hm "$h5_reset")
    c=$(color_for_pct "$h5_pct")
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Session:${C_RESET}${c}${h5_pct}%${C_DIM}(${rst})${C_RESET}"
fi
if [ -n "$d7_pct" ]; then
    rst=$(fmt_reset_dh "$d7_reset")
    c=$(color_for_pct "$d7_pct")
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Week:${C_RESET}${c}${d7_pct}%${C_DIM}(${rst})${C_RESET}"
fi
if [ -n "$ctx_pct" ]; then
    filled=$(( ctx_pct / 20 ))
    [ $filled -gt 5 ] && filled=5
    empty=$(( 5 - filled ))
    c=$(color_for_pct "$ctx_pct")
    filled_bar="" empty_bar=""
    for i in $(seq 1 $filled 2>/dev/null); do filled_bar="${filled_bar}▰"; done
    for i in $(seq 1 $empty 2>/dev/null); do empty_bar="${empty_bar}▱"; done
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Ctx:${C_RESET}${c}${filled_bar}${C_DIM}${empty_bar}${C_RESET}${c}${ctx_pct}%${C_RESET}"
fi

cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
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

    # Detect new session (cost reset below last known value)
    if [ "$(echo "$cost_usd < $last_session_usd" | bc)" = "1" ]; then
        cumulative_usd=$(echo "$cumulative_usd + $last_session_usd" | bc)
    fi
    echo "${cur_date}:${cumulative_usd}:${cost_usd}" > "$BUDGET_CACHE"

    total_usd=$(echo "$cumulative_usd + $cost_usd" | bc)
    total_jpy=$(echo "scale=6; $total_usd * $jpy_rate" | bc | awk '{printf "%d", $1}')

    if [ "${total_jpy:-0}" -gt 0 ] 2>/dev/null; then
        budget_jpy=500
        pct=$(( total_jpy * 100 / budget_jpy ))
        [ $pct -gt 100 ] && pct=100
        filled=$(( pct / 20 ))
        empty=$(( 5 - filled ))
        c=$(color_for_pct "$pct")
        filled_bar="" empty_bar=""
        for i in $(seq 1 $filled 2>/dev/null); do filled_bar="${filled_bar}▰"; done
        for i in $(seq 1 $empty 2>/dev/null); do empty_bar="${empty_bar}▱"; done
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

printf "%s" "$out"
