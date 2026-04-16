#!/usr/bin/env bash
# Blocks bash commands that would print or transmit env variable values.
# Returns a JSON decision — "block" halts the tool call, "allow" lets it proceed.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

BLOCKED=(
  'cat.*\.env'
  'echo.*\$(.*KEY\|.*TOKEN\|.*SECRET\|.*PASSWORD)'
  '\bprintenv\b'
  '^env$'
  'curl.*\$[A-Z_]*TOKEN'
  'curl.*\$[A-Z_]*KEY'
)

for P in "${BLOCKED[@]}"; do
  if echo "$CMD" | grep -qiE "$P"; then
    echo '{
      "decision": "block",
      "reason": "Blocked: command may expose sensitive env values. Reference variables by name in code only — do not print or transmit their values."
    }'
    exit 0
  fi
done

echo '{"decision": "allow"}'
