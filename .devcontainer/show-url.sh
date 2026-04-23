#!/bin/bash
# Show current Codespace public URL for openai-cpa web UI
CODESPACE_NAME="${CODESPACE_NAME:-$(gh codespace list --json name -q '.[0].name' 2>/dev/null)}"
if [[ -z "$CODESPACE_NAME" ]]; then
    echo "ERROR: Cannot determine CODESPACE_NAME"
    exit 1
fi
echo "https://${CODESPACE_NAME}-8000.app.github.dev/"
