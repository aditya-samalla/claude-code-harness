#!/usr/bin/env bash
# Installs the Claude Code harness to ~/.claude
# Run once per machine: bash install.sh

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Claude Code harness..."

# Directories
mkdir -p ~/.claude/hooks ~/.claude/logs ~/.claude/transcripts
echo "  ✓ directories"

# Hooks
HOOKS=(env-guard.sh sensitive-file-guard.sh audit.sh notify.sh session-start.sh pre-compact.sh)
for f in "${HOOKS[@]}"; do
  cp "$REPO/hooks/$f" ~/.claude/hooks/"$f"
  chmod +x ~/.claude/hooks/"$f"
  echo "  ✓ hooks/$f"
done

# Global settings (backs up any existing file)
if [[ -f ~/.claude/settings.json ]]; then
  cp ~/.claude/settings.json ~/.claude/settings.json.bak
  echo "  (backed up existing settings.json → settings.json.bak)"
fi
cp "$REPO/settings.json" ~/.claude/settings.json
echo "  ✓ settings.json"

# gh check
echo ""
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  echo "  ✓ gh CLI authenticated"
else
  echo "  ✗ gh CLI not set up — run: gh auth login"
fi

echo ""
echo "Done. Open Claude Code and run /hooks to verify."
echo "Audit log:   ~/.claude/logs/audit.log"
echo "Transcripts: ~/.claude/transcripts/"
