#!/usr/bin/env bash
# Tests for memory-lint.sh — builds a synthetic memory store in a temp dir.
# Hermetic: no real memory is read.
#
# Half of these assert SILENCE. A write-time hook that fires on healthy memories
# gets ignored, and then it is worse than no hook at all.
set -u
HOOK="hooks/memory-lint.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STORE="$TMP/projects/teststore/memory"
mkdir -p "$STORE"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2" ;; esac; }
check_absent()   { case "$3" in *"$2"*) fail "$1" "unexpected: $2" ;; *) pass "$1" ;; esac; }
check_eq()       { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expect=$2 got=$3"; fi; }

lint() {  # lint <file> [tool]
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "${2:-Write}" "$1" \
    | bash "$HOOK" 2>&1
}
lint_rc() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | bash "$HOOK" >/dev/null 2>&1; echo $?
}

# A healthy memory, plus its index line.
write_mem() {  # write_mem <stem> <description> <body...>
  local stem="$1" desc="$2"; shift 2
  { echo "---"; echo "name: $stem"; echo "description: $desc"
    echo "metadata:"; echo "  type: reference"; echo "  modified: 2026-01-01"
    echo "---"; echo ""; printf '%s\n' "$@"; } > "$STORE/$stem.md"
  grep -q "($stem.md)" "$STORE/MEMORY.md" 2>/dev/null \
    || echo "- [T](
$stem.md) — hook" | tr -d '\n' >> "$STORE/MEMORY.md" && echo "" >> "$STORE/MEMORY.md"
}

echo "=== a healthy memory produces no findings at all ==="
: > "$STORE/MEMORY.md"
write_mem good "what this memory is about, stated as a retrieval cue" "body text"
OUT=$(lint "$STORE/good.md")
check_eq "silent"  ""  "$OUT"
check_eq "exit 0"  "0" "$(lint_rc "$STORE/good.md")"

echo ""
echo "=== files outside a memory store, and the index itself, are ignored ==="
echo "whatever" > "$TMP/notes.md"
check_eq "non-store file ignored" "0" "$(lint_rc "$TMP/notes.md")"
check_eq "MEMORY.md itself ignored" "0" "$(lint_rc "$STORE/MEMORY.md")"
check_eq "a Read is ignored" "" "$(lint "$STORE/good.md" Read)"

echo ""
echo "=== name: must equal the filename, because links resolve by filename ==="
: > "$STORE/MEMORY.md"
write_mem wrongname "a description" "body"
sed -i.bak 's/^name: wrongname/name: wrong-name/' "$STORE/wrongname.md" && rm -f "$STORE/wrongname.md.bak"
OUT=$(lint "$STORE/wrongname.md")
check_contains "flagged"          "does not match the filename" "$OUT"
check_contains "says why it matters" "silently breaks them"     "$OUT"

echo ""
echo "=== frontmatter completeness ==="
: > "$STORE/MEMORY.md"
printf -- '---\nname: bare\n---\nbody\n' > "$STORE/bare.md"
echo "- [T](bare.md) — hook" > "$STORE/MEMORY.md"
OUT=$(lint "$STORE/bare.md")
check_contains "missing description" "no \`description:\`"     "$OUT"
check_contains "missing type"        "no \`metadata.type\`"    "$OUT"
check_contains "missing modified"    "no \`metadata.modified\`" "$OUT"

: > "$STORE/MEMORY.md"
write_mem badtype "a description" "body"
sed -i.bak 's/^  type: reference/  type: notes/' "$STORE/badtype.md" && rm -f "$STORE/badtype.md.bak"
check_contains "invalid type named" "is not one of user, feedback, project, reference" \
               "$(lint "$STORE/badtype.md")"

echo ""
echo "=== a description that carries changing state is a drift vector ==="
: > "$STORE/MEMORY.md"
write_mem statey "INS-1 fix; the PR is still open and unreviewed" "body"
check_contains "flagged" "asserts changing state" "$(lint "$STORE/statey.md")"

: > "$STORE/MEMORY.md"
write_mem cue "why the consumer runs on one core and what that costs" "body"
check_absent "a state-free cue is not flagged" "changing state" "$(lint "$STORE/cue.md")"

echo ""
echo "=== a liveness claim with no verify: block cannot ever be checked ==="
: > "$STORE/MEMORY.md"
write_mem inflight "what the change does" "The PR is not yet merged; deploy is blocked on review."
check_contains "flagged"        "no \`verify:\` block" "$(lint "$STORE/inflight.md")"

: > "$STORE/MEMORY.md"
write_mem withblock "what the change does" "verify:" "  - gh acme/api#1 open" \
                                           "The PR is not yet merged."
check_absent "silent once a block exists" "verify\` block" "$(lint "$STORE/withblock.md")"

: > "$STORE/MEMORY.md"
write_mem durable "a durable measured fact" "The consumer runs on one core. Measured."
check_absent "a durable fact needs no block" "verify" "$(lint "$STORE/durable.md")"

echo ""
echo "=== links: a separator typo is a defect, a missing target is not ==="
: > "$STORE/MEMORY.md"
write_mem reference_tag_chain "the target" "body"
write_mem src "the source" "see [[reference_tag_chain]], [[reference-tag-chain]] and [[project_never_written]]"
OUT=$(lint "$STORE/src.md")
check_contains "hyphen typo flagged"    "[[reference-tag-chain]] does not resolve" "$OUT"
check_contains "names the right target" "[[reference_tag_chain]] does"             "$OUT"
check_absent   "forward reference is fine"  "project_never_written"        "$OUT"

echo ""
echo "=== a memory absent from the index will never be recalled ==="
: > "$STORE/MEMORY.md"
write_mem indexed "a description" "body"
cp "$STORE/indexed.md" "$STORE/orphan.md"
sed -i.bak 's/^name: indexed/name: orphan/' "$STORE/orphan.md" && rm -f "$STORE/orphan.md.bak"
check_contains "orphan flagged" "no line in MEMORY.md points at orphan.md" "$(lint "$STORE/orphan.md")"
check_absent   "indexed one is not" "no line in MEMORY.md"                 "$(lint "$STORE/indexed.md")"

echo ""
echo "=== the index line has a character budget, counted in CHARACTERS ==="
# The whole index is capped around 25,000 chars and holds one line per memory,
# so per-line length is the only lever. Em-dashes make bytes != characters, and
# counting bytes would flag lines that are actually within budget.
: > "$STORE/MEMORY.md"
write_mem budget "a description" "body"
LONG=$(printf 'x%.0s' $(seq 1 130))
echo "- [T](budget.md) — $LONG" > "$STORE/MEMORY.md"
check_contains "over-budget line flagged" "is clipped around 110" "$(lint "$STORE/budget.md")"

: > "$STORE/MEMORY.md"
DASHES=$(printf '\xe2\x80\x94%.0s' $(seq 1 30))   # 30 em-dashes: 30 chars, 90 bytes
echo "- [T](budget.md) — $DASHES" > "$STORE/MEMORY.md"
check_absent "not flagged on byte count" "is clipped around" "$(lint "$STORE/budget.md")"

echo ""
echo "=== the hook never edits and never blocks a write ==="
: > "$STORE/MEMORY.md"
write_mem untouched "a description" "The PR is not yet merged."
SUM_BEFORE=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
lint "$STORE/untouched.md" >/dev/null 2>&1
SUM_AFTER=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
check_eq "store byte-identical" "$SUM_BEFORE" "$SUM_AFTER"
check_eq "exit 2 is advice, not a block" "2" "$(lint_rc "$STORE/untouched.md")"

echo ""
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
