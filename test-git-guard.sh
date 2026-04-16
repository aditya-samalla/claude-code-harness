#!/usr/bin/env bash
# Tests for git-guard.sh — feeds JSON via stdin, checks output
HOOK="hooks/git-guard.sh"
PASS=0; FAIL=0

check() {
  local label="$1" expect="$2" cmd="$3"
  RESULT=$(printf '{"tool_input":{"command":"%s"}}' "$cmd" | bash "$HOOK" 2>/dev/null)
  if [ -z "$RESULT" ]; then GOT="allow"; else GOT=$(echo "$RESULT" | jq -r '.decision'); fi

  if [ "$GOT" = "$expect" ]; then
    echo "  OK ($expect): $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL (expected=$expect got=$GOT): $label"
    FAIL=$((FAIL+1))
  fi
}

echo "=== Force-push variants (expect: block) ==="
check "git push --force"              block "git push --force"
check "git push -f origin main"       block "git push -f origin main"
check "git push origin main --force"  block "git push origin main --force"
check "git push --force-with-lease"   block "git push --force-with-lease"
check "git push origin main -f"       block "git push origin main -f"
check "chain: add && push --force"    block "git add file.txt && git push --force origin main"

echo ""
echo "=== Indiscriminate staging (expect: block) ==="
check "git add ."        block "git add ."
check "git add -A"       block "git add -A"
check "git add --all"    block "git add --all"
check "git add -A chain" block "git add -A && git commit -m test"

echo ""
echo "=== Sensitive file staging (expect: block) ==="
check "git add .env"           block "git add .env"
check "git add src/.env.local" block "git add src/.env.local"
check "git add secrets.yaml"   block "git add secrets.yaml"
check "git add id_rsa"         block "git add id_rsa"
check "git add server.pem"     block "git add server.pem"
check "git add tls.key"        block "git add tls.key"

echo ""
echo "=== Legitimate commands (expect: allow) ==="
check "git push origin main"         allow "git push origin main"
check "git push"                     allow "git push"
check "git add src/index.ts"         allow "git add src/index.ts"
check "git add package.json"         allow "git add package.json README.md"

echo ""
echo "=== Commit messages with scary text (expect: allow) ==="
check "commit msg mentions --force"  allow "git commit -m 'block git push --force variants'"
check "commit msg mentions .env"     allow "git commit -m 'prevent staging .env files'"
check "commit msg mentions git add ." allow "git commit -m 'block git add . and git add -A'"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
exit $FAIL
