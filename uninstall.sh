#!/bin/bash
set -e

DEST="$HOME/.claude"
SETTINGS="$DEST/settings.json"

echo "Uninstalling claude-code-statusline..."

# Remove script files
for f in statusline.sh statusline.ps1; do
    if [ -f "$DEST/$f" ]; then
        rm "$DEST/$f"
        echo "  Removed $DEST/$f"
    fi
done

# Remove cache/lock files (including interrupted-write .tmp leftovers and per-path locks)
for f in jpy_rate.cache jpy_rate.lock jpy_rate.fail cost_budget.cache \
         cost_session_state.cache \
         statusline_gauges.cache cost_estimate.cache cost_estimate.lock; do
    if [ -e "$DEST/$f" ]; then
        rm -f "$DEST/$f"
        echo "  Removed $DEST/$f"
    fi
    rm -f "$DEST/$f".tmp*
done
rm -f "$DEST"/cost_estimate.*.lock

# Remove statusLine entry from settings.json
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    cp "$SETTINGS" "${SETTINGS}.bak"
    tmp=$(mktemp)
    if jq 'del(.statusLine)' "$SETTINGS" > "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$SETTINGS"
        echo "  Removed statusLine from $SETTINGS (backup: ${SETTINGS}.bak)"
    else
        rm -f "$tmp"
        echo "  Could not update $SETTINGS (invalid JSON?). Backup kept at ${SETTINGS}.bak."
    fi
elif [ -f "$SETTINGS" ]; then
    echo ""
    echo "  jq not found. Please remove the statusLine entry from $SETTINGS manually."
fi

echo ""
echo "Done. Restart Claude Code to apply."
