#!/bin/bash
input=$(cat)
now=$(date +%s)

# === Color Palette (Claude Gradient) ===
C_RESET=$'\e[0m'
C_PURPLE=$'\e[38;2;167;139;250m'   # model name
C_GREEN=$'\e[38;2;130;180;100m'    # healthy (<60%)
C_AMBER=$'\e[38;2;229;192;123m'    # warning (>=60%) / Opus !
C_RED=$'\e[38;2;224;108;117m'      # critical (>=80%) / Fable !!
C_DIM=$'\e[38;2;92;99;112m'        # labels

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 80 ]; then printf "%s" "$C_RED"
    elif [ "$pct" -ge 60 ]; then printf "%s" "$C_AMBER"
    else printf "%s" "$C_GREEN"; fi
}

stat_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

compute_cost_estimate() {
    jq -R 'fromjson? // empty' "$1" 2>/dev/null | jq -s '
        {
          "claude-opus-4-8": {in:5.00, out:25.00, cwrite:6.25, cread:0.50},
          "claude-opus-4-7": {in:5.00, out:25.00, cwrite:6.25, cread:0.50},
          "claude-opus-4-6": {in:5.00, out:25.00, cwrite:6.25, cread:0.50},
          "claude-opus-4-5": {in:5.00, out:25.00, cwrite:6.25, cread:0.50},
          "claude-opus-4-1": {in:5.00, out:25.00, cwrite:6.25, cread:0.50},
          "claude-opus-4-0": {in:5.00, out:25.00, cwrite:6.25, cread:0.50},
          "claude-sonnet-5": {in:3.00, out:15.00, cwrite:3.75, cread:0.30},
          "claude-sonnet-4-6": {in:3.00, out:15.00, cwrite:3.75, cread:0.30},
          "claude-sonnet-4-5": {in:3.00, out:15.00, cwrite:3.75, cread:0.30},
          "claude-sonnet-4-0": {in:3.00, out:15.00, cwrite:3.75, cread:0.30},
          "claude-haiku-4-5": {in:1.00, out:5.00, cwrite:1.25, cread:0.10},
          "claude-fable-5": {in:10.00, out:50.00, cwrite:12.50, cread:1.00},
          "claude-mythos-5": {in:10.00, out:50.00, cwrite:12.50, cread:1.00}
        } as $p |
        def norm_model:
            sub("^anthropic\\."; "") | sub("@.*$"; "") | sub("-[0-9]{8}$"; "");
        ( [ .[]? | select(.type == "assistant") | .message // {} | select(.usage) |
            { model: ((.model // "claude-sonnet-5") | norm_model), u: .usage } ] ) as $msgs |
        (reduce $msgs[] as $m (0;
            . + (($p[$m.model] // $p["claude-sonnet-5"]) as $r |
                (($m.u.input_tokens // 0) * $r.in +
                 ($m.u.output_tokens // 0) * $r.out +
                 ($m.u.cache_creation_input_tokens // 0) * $r.cwrite +
                 ($m.u.cache_read_input_tokens // 0) * $r.cread) / 1000000)
        ))
    ' 2>/dev/null
}

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
    "cost_usd="      + (if .cost.total_cost_usd != null then (.cost.total_cost_usd | tostring) else "" end | @sh) + "\n" +
    "cwd="           + (.cwd // "" | @sh) + "\n" +
    "transcript_path=" + (.transcript_path // "" | @sh) + "\n" +
    "has_rl="        + (if .rate_limits != null then "1" else "" end | @sh)
' 2>/dev/null)"

# === Gauge fallback cache (Claude Code omits context_window/rate_limits briefly after a mid-session model switch) ===
GAUGE_CACHE="$HOME/.claude/statusline_gauges.cache"
GAUGE_TTL=20
if [ -f "$GAUGE_CACHE" ]; then
    IFS='|' read -r g_cwd g_ctx g_h5 g_h5r g_d7 g_d7r g_ts < "$GAUGE_CACHE"
    if [ "$g_cwd" = "$cwd" ] && [ -n "$cwd" ] && [[ "$g_ts" =~ ^[0-9]+$ ]] && [ $(( now - g_ts )) -lt $GAUGE_TTL ]; then
        [ -z "$ctx_pct" ] && [ -n "$g_ctx" ] && ctx_pct="$g_ctx"
        [ -z "$h5_pct" ] && [ -n "$g_h5" ] && h5_pct="$g_h5" && h5_reset="$g_h5r"
        [ -z "$d7_pct" ] && [ -n "$g_d7" ] && d7_pct="$g_d7" && d7_reset="$g_d7r"
    fi
fi
if [ -n "$cwd" ] && { [ -n "$ctx_pct" ] || [ -n "$h5_pct" ] || [ -n "$d7_pct" ]; }; then
    echo "${cwd}|${ctx_pct}|${h5_pct}|${h5_reset:-0}|${d7_pct}|${d7_reset:-0}|${now}" > "$GAUGE_CACHE"
fi

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

# === Build output ===
out=""

# Model prefix with effort level
if [ -n "$model_display" ]; then
    model_short=$(echo "$model_display" | tr -d ' ')
    model_str="${model_short}"
    [ -n "$effort" ] && model_str="${model_str}(${effort})"
    if [[ "$model_id" == *"opus"* ]]; then
        out="${C_AMBER}!${model_str}${C_RESET}"
    elif [[ "$model_id" == *"fable"* ]]; then
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
elif [ -z "$has_rl" ] && [ -n "$model_display" ] && awk -v cost="${cost_usd:-0}" 'BEGIN {exit !(cost == 0)}' 2>/dev/null; then
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Session:-${C_RESET}"
fi

# Week rate limit
if [ -n "$d7_pct" ]; then
    rst=$(fmt_reset_dh "$d7_reset")
    c=$(color_for_pct "$d7_pct")
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Week:${C_RESET}${c}${d7_pct}%${C_DIM}(${rst})${C_RESET}"
elif [ -z "$has_rl" ] && [ -n "$model_display" ] && awk -v cost="${cost_usd:-0}" 'BEGIN {exit !(cost == 0)}' 2>/dev/null; then
    [ -n "$out" ] && out="$out "
    out="${out}${C_DIM}Week:-${C_RESET}"
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

# transcript_path fallback: some Claude Code versions/auth paths omit transcript_path
# from the statusLine hook JSON. Locate the most recently modified transcript in the
# project-specific directory (derived from cwd, same convention Claude Code itself uses)
# as a best-effort substitute.
if [ -z "$transcript_path" ] && [ -n "$cwd" ]; then
    proj_dir="$HOME/.claude/projects/$(printf '%s' "$cwd" | tr '/' '-')"
    if [ -d "$proj_dir" ]; then
        transcript_path=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -n 1)
    fi
fi

# === Fallback cost estimate (Claude Code omits cost.total_cost_usd for Azure/Bedrock/Vertex-routed sessions) ===
cost_is_estimate=""
if [ -z "$cost_usd" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    EST_CACHE="$HOME/.claude/cost_estimate.cache"
    EST_LOCK="$HOME/.claude/cost_estimate.lock"
    t_mtime=$(stat_mtime "$transcript_path")
    cached_path="" cached_mtime="" cached_val=""
    if [ -f "$EST_CACHE" ]; then
        cached_path=$(cut -d'|' -f1 "$EST_CACHE")
        cached_mtime=$(cut -d'|' -f2 "$EST_CACHE")
        cached_val=$(cut -d'|' -f3 "$EST_CACHE")
    fi
    est_val=""
    if [ "$cached_path" = "$transcript_path" ] && [ "$cached_mtime" = "$t_mtime" ] && [ -n "$cached_val" ]; then
        est_val="$cached_val"
    else
        [ "$cached_path" = "$transcript_path" ] && [ -n "$cached_val" ] && est_val="$cached_val"
        lock_age=$(( now - $(stat_mtime "$EST_LOCK") ))
        if [ "$lock_age" -gt 30 ]; then
            touch "$EST_LOCK" 2>/dev/null
            (
                computed=$(compute_cost_estimate "$transcript_path")
                if [ -n "$computed" ]; then
                    printf '%s|%s|%s' "$transcript_path" "$t_mtime" "$computed" > "${EST_CACHE}.tmp" && mv "${EST_CACHE}.tmp" "$EST_CACHE"
                fi
                rm -f "$EST_LOCK"
            ) >/dev/null 2>&1 &
        fi
        if [ -z "$est_val" ]; then
            est_val=$(compute_cost_estimate "$transcript_path")
        fi
    fi
    [ -z "$est_val" ] && est_val="0"
    cost_usd="$est_val"
    cost_is_estimate=1
fi

# Daily cost
# NOTE: jpy_rate is best-effort (fetched over the network); the $ cost must still
# display even when the JPY conversion is unavailable (offline, blocked host, etc.)
if [ -n "$cost_usd" ]; then
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

    if awk -v cur="$cost_usd" -v last="$last_session_usd" 'BEGIN {exit !(cur < last)}' 2>/dev/null; then
        cumulative_usd=$(awk -v cum="$cumulative_usd" -v last="$last_session_usd" 'BEGIN {print cum + last}')
    fi
    printf '%s:%s:%s' "$cur_date" "$cumulative_usd" "$cost_usd" > "${BUDGET_CACHE}.tmp" && mv "${BUDGET_CACHE}.tmp" "$BUDGET_CACHE"

    total_usd=$(awk -v cum="$cumulative_usd" -v cur="$cost_usd" 'BEGIN {print cum + cur}')
    cost_fmt=$(printf "%.2f" "$total_usd")
    est_prefix=""; [ -n "$cost_is_estimate" ] && est_prefix="~"

    if [ -n "$jpy_rate" ]; then
        total_jpy=$(awk -v tot="$total_usd" -v rate="$jpy_rate" 'BEGIN {printf "%d", tot * rate + 0.5}')
        session_jpy=$(awk -v cur="$cost_usd" -v rate="$jpy_rate" 'BEGIN {printf "%d", cur * rate + 0.5}')

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
            [ -n "$out" ] && out="$out "
            warn=""
            [ $pct -ge 100 ] && warn="!!"
            out="${out}${C_DIM}Cost:${C_RESET}${c}${warn}${bar}${C_RESET}${c}\$${est_prefix}${cost_fmt}${C_RESET}${C_DIM}(${C_RESET}${c}¥${session_jpy}${C_RESET} ${C_DIM}Today:${C_RESET}${c}¥${total_jpy}${C_DIM}/¥500)${C_RESET}"
        fi
    elif awk -v tot="$total_usd" 'BEGIN {exit !(tot > 0)}' 2>/dev/null; then
        # JPY rate not yet cached (offline / blocked) — show plain $ amount, no bar/budget
        [ -n "$out" ] && out="$out "
        out="${out}${C_DIM}Cost:${C_RESET}${C_GREEN}\$${est_prefix}${cost_fmt}${C_RESET}"
    fi
fi

printf "%s" "$out"
