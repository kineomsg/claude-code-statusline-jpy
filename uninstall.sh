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

# Remove cache files
for f in jpy_rate.cache jpy_rate.lock cost_budget.cache statusline_gauges.cache cost_estimate.cache cost_estimate.lock; do
    if [ -f "$DEST/$f" ]; then
        rm "$DEST/$f"
        echo "  Removed $DEST/$f"
    fi
done

# Remove statusLine entry from settings.json
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
    tmp=$(mktemp)
    jq 'del(.statusLine)' "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "  Removed statusLine from $SETTINGS"
elif [ -f "$SETTINGS" ]; then
    echo ""
    echo "  jq not found. Please remove the statusLine entry from $SETTINGS manually."
fi

echo ""
echo "Done. Restart Claude Code to apply."
