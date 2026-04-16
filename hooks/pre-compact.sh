#!/usr/bin/env bash
export PATH="/opt/homebrew/bin:$PATH"
# Backs up the session transcript before compaction (auto or manual).
# Runs async so it never delays the compaction itself.
# Keeps the 20 most recent backups and prunes the rest.

INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
TRIGGER=$(echo "$INPUT"    | jq -r '.trigger // "unknown"')

[[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

BACKUP_DIR="${CLAUDE_TRANSCRIPT_DIR:-$HOME/.claude/transcripts}"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp "$TRANSCRIPT" "$BACKUP_DIR/transcript_${TRIGGER}_${TIMESTAMP}.jsonl"

# Keep the 20 most recent; remove the rest
ls -t "$BACKUP_DIR"/transcript_*.jsonl 2>/dev/null \
  | tail -n +21 \
  | xargs rm -f 2>/dev/null || true
