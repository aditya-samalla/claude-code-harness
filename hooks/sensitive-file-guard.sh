#!/usr/bin/env bash
export PATH="/opt/homebrew/bin:$PATH"
# Blocks Read/Edit/Write tool calls targeting .env files and credentials.

INPUT=$(cat)
FILE=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')

if [[ -z "$FILE" ]]; then
  echo '{"decision": "allow"}'; exit 0
fi

BLOCKED=(
  '(^|/)\.env$'
  '(^|/)\.env\.'
  '(^|/)\.envrc$'
  '\.pem$'
  '\.key$'
  '(^|/)id_rsa'
  '(^|/)id_ed25519'
  '\.aws/credentials'
  '(^|/)\.netrc$'
  '(^|/)secrets\.'
)

for P in "${BLOCKED[@]}"; do
  if printf '%s\n' "$FILE" | grep -qE "$P"; then
    echo "{
      \"decision\": \"block\",
      \"reason\": \"Blocked: $FILE is a sensitive credentials file. Read env values from process.env in code — do not open the file directly.\"
    }"
    exit 0
  fi
done

echo '{"decision": "allow"}'
