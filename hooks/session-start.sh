#!/usr/bin/env bash
# Injects current git state as context at session start.
# Stdout from SessionStart hooks is added directly to Claude's context window —
# no prompt needed. Claude starts every session already knowing where it is.

# Silently exit if not inside a git repo
git rev-parse --git-dir &>/dev/null 2>&1 || exit 0

BRANCH=$(git branch --show-current 2>/dev/null || echo "detached HEAD")
DIRTY=$(git status --short 2>/dev/null | head -10)
COMMITS=$(git log --oneline -5 2>/dev/null)
STASHES=$(git stash list 2>/dev/null | wc -l | tr -d ' ')

echo "## Git context"
echo "Branch: $BRANCH"

if [[ -n "$DIRTY" ]]; then
  echo "Uncommitted changes:"
  echo "$DIRTY"
else
  echo "Working tree: clean"
fi

echo ""
echo "Recent commits:"
echo "$COMMITS"

if [[ "$STASHES" -gt 0 ]]; then
  echo ""
  echo "Stashes: $STASHES stash(es) present"
fi
