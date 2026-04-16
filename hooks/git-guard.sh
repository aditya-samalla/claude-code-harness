#!/usr/bin/env bash
export PATH="/opt/homebrew/bin:$PATH"
# Blocks dangerous git operations that bypass other guards:
#   1. git push with any --force / -f / --force-with-lease variant
#   2. git add . / -A / --all  (indiscriminate staging may include secrets)
#   3. git add targeting sensitive file patterns (.env, .pem, .key, …)
#
# All regexes are anchored to line-start or chain operators (&&, ;, ||)
# so that text inside commit messages / heredocs does not false-positive.

INPUT=$(cat)
CMD=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // ""')

ANCHOR='(^|&&|;|\|\|)\s*'

# --- Force-push guard ---------------------------------------------------
# Single regex: git push + force flag on the same line, anchored.
if printf '%s\n' "$CMD" | grep -qE "${ANCHOR}git\s+push\s.*(-f\b|--force\b|--force-with-lease\b)"; then
  echo '{
    "decision": "block",
    "reason": "Blocked: force-push is not allowed. Use regular git push, or ask the user to run this manually."
  }'
  exit 0
fi

# --- Indiscriminate staging guard ----------------------------------------
if printf '%s\n' "$CMD" | grep -qE "${ANCHOR}git\s+add\s+(-A|--all|\.)(\s|;|&|$)"; then
  echo '{
    "decision": "block",
    "reason": "Blocked: broad git add (., -A, --all) may stage sensitive files. Stage files by name instead."
  }'
  exit 0
fi

# --- Sensitive file staging guard ----------------------------------------
SENSITIVE=(
  '\.env(\s|$)'
  '\.env\.'
  '\.envrc(\s|$)'
  '\.pem(\s|$)'
  '\.key(\s|$)'
  'id_rsa'
  'id_ed25519'
  '\.aws/credentials'
  '\.netrc(\s|$)'
  'secrets\.'
)

for P in "${SENSITIVE[@]}"; do
  if printf '%s\n' "$CMD" | grep -qE "${ANCHOR}git\s+add\s.*${P}"; then
    echo "{
      \"decision\": \"block\",
      \"reason\": \"Blocked: git add targets a sensitive file. Do not stage credentials or secret files.\"
    }"
    exit 0
  fi
done

exit 0
