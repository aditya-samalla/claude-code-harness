#!/usr/bin/env bash
# Tests for secret-scanner.sh
#
# Test fixtures that look like real secrets are composed at runtime from
# `prefix${ZZ}suffix` pairs. The empty shell expansion `${ZZ}` disappears
# at runtime (so the scanner still sees the full token) but breaks the
# literal pattern in source — keeping GitHub push-protection, CI secret
# scanners, and this repo's own secret-scanner from flagging the fixtures.
set -u
HOOK="hooks/secret-scanner.sh"
PASS=0; FAIL=0

# Shell-level splitter: expands to empty, defeats static pattern matches.
# (Don't use `_` — bash overwrites it with the last argument of each command.)
ZZ=''

check_write() {
  local label="$1" expect="$2" content="$3"
  local payload
  payload=$(jq -nc --arg c "$content" '{tool_name:"Write", tool_input:{content:$c, file_path:"/tmp/x"}}')
  local result got
  result=$(printf '%s\n' "$payload" | bash "$HOOK" 2>/dev/null)
  if [[ -z "$result" ]]; then
    got="allow"
  else
    got=$(printf '%s\n' "$result" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  fi
  if [[ "$got" = "$expect" ]]; then
    echo "  OK ($expect): $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL (expected=$expect got=$got): $label"
    FAIL=$((FAIL+1))
  fi
}

check_edit() {
  local label="$1" expect="$2" new_string="$3"
  local payload
  payload=$(jq -nc --arg n "$new_string" '{tool_name:"Edit", tool_input:{new_string:$n, old_string:"placeholder", file_path:"/tmp/x"}}')
  local result got
  result=$(printf '%s\n' "$payload" | bash "$HOOK" 2>/dev/null)
  if [[ -z "$result" ]]; then
    got="allow"
  else
    got=$(printf '%s\n' "$result" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  fi
  if [[ "$got" = "$expect" ]]; then
    echo "  OK ($expect): $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL (expected=$expect got=$got): $label"
    FAIL=$((FAIL+1))
  fi
}

echo "=== Known secret shapes via Write (expect: deny) ==="
check_write "AWS access key"   deny "const KEY = \"AKIA${ZZ}IOSFODNN7EXAMPLE\";"
check_write "AWS session key"  deny "AWS_KEY=ASIA${ZZ}IOSFODNN7EXAMPLE"
check_write "GitHub PAT"       deny "token: ghp${ZZ}_0123456789abcdefghij0123456789abcdef"
check_write "Slack token"      deny "SLACK=xoxb${ZZ}-1234567890-1234567890-abcdefgh"
check_write "Google API key"   deny "KEY=AIza${ZZ}SyA-example-key-abcdefghijklmnopqrstuv"
check_write "Stripe live"      deny "STRIPE=sk_live${ZZ}_abcdefghij0123456789ABCDEF"
check_write "JWT"              deny "Bearer eyJ${ZZ}hbGciOiJIUzI1NiJ9.eyJzdWIiOjEyMzQ1Njc4OTB9.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9FYR5aaa"
check_write "PEM private key"  deny "-----BEGIN${ZZ} RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA...
-----END RSA PRIVATE KEY-----"
check_write "Anthropic key"    deny "ANTHROPIC_API_KEY=sk-ant${ZZ}-abcdefghijklmnopqrstuvwxyz"

echo ""
echo "=== Known secret shapes via Edit (expect: deny) ==="
check_edit  "AWS access key"   deny "const K = \"AKIA${ZZ}IOSFODNN7EXAMPLE\";"
check_edit  "GitHub PAT"       deny "ghp${ZZ}_0123456789abcdefghij0123456789abcdef"

echo ""
echo "=== Legitimate content (expect: allow) ==="
check_write "TODO comment"     allow '// TODO: load secrets from env, not inline'
check_write "env.example"      allow 'AWS_ACCESS_KEY_ID=your-access-key-here'
check_write "normal code"      allow 'export function foo() { return process.env.TOKEN; }'
check_write "short string"     allow 'const x = "AKIA";'
check_write "AKIA not key"     allow 'function akiaHelper() { /* no */ }'
check_write "documentation"    allow 'Set AWS_ACCESS_KEY_ID to your IAM key ID before running.'

echo ""
echo "=== Non-Write/Edit tool (expect: allow) ==="
payload=$(jq -nc --arg c "AKIA${ZZ}IOSFODNN7EXAMPLE" '{tool_name:"Bash", tool_input:{command:$c}}')
result=$(printf '%s\n' "$payload" | bash "$HOOK" 2>/dev/null)
got=$([ -z "$result" ] && echo allow || echo "$result" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
if [[ "$got" = "allow" ]]; then
  echo "  OK (allow): Bash tool ignored"; PASS=$((PASS+1))
else
  echo "  FAIL: Bash tool not ignored"; FAIL=$((FAIL+1))
fi

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
