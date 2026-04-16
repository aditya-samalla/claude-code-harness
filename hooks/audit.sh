#!/usr/bin/env bash
export PATH="/opt/homebrew/bin:$PATH"
# Central audit log. Handles:
#   PostToolUse      — file edits/writes (async)
#   PostToolUseFailure — failed tool calls (async)
#   ConfigChange     — settings file modified mid-session (async)
#   Stop             — session summary (blocking, so cost is captured before exit)

LOG="${CLAUDE_AUDIT_LOG:-$HOME/.claude/logs/audit.log}"
mkdir -p "$(dirname "$LOG")"

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"')
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DIR=$(pwd)

case "$EVENT" in
  Stop)
    TURNS=$(echo "$INPUT" | jq -r '.num_turns // "?"')
    COST=$(echo "$INPUT"  | jq -r '.usage.total_cost_usd // "?"')
    echo "$TS | session_end | turns=$TURNS cost_usd=$COST | $DIR" >> "$LOG"
    ;;
  PostToolUseFailure)
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
    ERR=$(echo "$INPUT"  | jq -r '.error // "unknown error"' | head -c 120)
    echo "$TS | FAILED | $TOOL | $ERR | $DIR" >> "$LOG"
    ;;
  ConfigChange)
    FILE=$(echo "$INPUT" | jq -r '.file_path // "unknown"')
    echo "$TS | config_change | $FILE | $DIR" >> "$LOG"
    ;;
  *)
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
    FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // "unknown"')
    echo "$TS | $TOOL | $FILE | $DIR" >> "$LOG"
    ;;
esac
