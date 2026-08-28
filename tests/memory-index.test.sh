#!/usr/bin/env bash
# Tests for memory-index.sh — synthetic store in a temp dir, so no real index is
# read or written.
#
# The property that matters most is that reordering is a PURE PERMUTATION. An
# index line is the only way the model learns a memory exists, so losing one in
# a sort is a silent, permanent loss.
set -u
SCRIPT_UT="bin/memory-index.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_MEMORY_PROJECTS_DIR="$TMP/projects"
STORE="$CLAUDE_MEMORY_PROJECTS_DIR/teststore/memory"
mkdir -p "$STORE"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected: $2" ;; esac; }
check_absent()   { case "$3" in *"$2"*) fail "$1" "unexpected: $2" ;; *) pass "$1" ;; esac; }
check_eq()       { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expect=$2 got=$3"; fi; }

run()    { bash "$SCRIPT_UT" --store teststore "$@" 2>&1; }
run_rc() { bash "$SCRIPT_UT" --store teststore "$@" >/dev/null 2>&1; echo $?; }

mem() {  # mem <stem> <type> [modified]
  local stem="$1" type="$2" mod="${3:-2026-01-01}"
  { echo "---"; echo "name: $stem"; echo "description: d"
    echo "metadata:"; echo "  type: $type"; echo "  modified: $mod"
    echo "---"; echo "body"; } > "$STORE/$stem.md"
}
entry() { echo "- [T]($1.md) — hook"; }
# Order of the entries as they appear, by stem.
order() { grep '^- \[' "$STORE/MEMORY.md" | sed 's/.*](//; s/\.md).*//' | tr '\n' ' '; }
reset() { rm -f "$STORE"/*.md; }

echo "=== entries are grouped feedback, reference, project ==="
reset
mem p1 project; mem r1 reference; mem f1 feedback; mem r2 reference
{ entry p1; entry r1; entry f1; entry r2; } > "$STORE/MEMORY.md"
check_eq "reports out of order" "1" "$(run_rc)"
check_contains "and says so"    "OUT OF ORDER" "$(run)"
run --write >/dev/null
check_eq "grouped by type, append order kept inside each" "f1 r1 r2 p1 " "$(order)"

echo ""
echo "=== feedback is never in the tail, because it does nothing unless loaded ==="
reset
mem f1 feedback; mem f2 feedback; mem r1 reference; mem p1 project
{ entry r1; entry p1; entry f1; entry f2; } > "$STORE/MEMORY.md"
run --write >/dev/null
FIRST=$(grep '^- \[' "$STORE/MEMORY.md" | head -2 | sed 's/.*](//; s/\.md).*//' | tr '\n' ' ')
check_eq "both feedback entries come first" "f1 f2 " "$FIRST"

echo ""
echo "=== project is newest-first, so the tail is the oldest ==="
reset
mem old project 2024-01-01; mem mid project 2025-06-01; mem new project 2026-08-01
{ entry old; entry mid; entry new; } > "$STORE/MEMORY.md"
run --write >/dev/null
check_eq "newest to oldest" "new mid old " "$(order)"

echo ""
echo "=== the ACTIVE block is passed through untouched, at the top ==="
reset
mem a1 project; mem a2 reference; mem f1 feedback
{ echo "<!-- ACTIVE WORK — kept at top so index truncation cannot drop it -->"
  entry a1; entry a2; echo ""; entry f1; } > "$STORE/MEMORY.md"
run --write >/dev/null
check_eq "active entries stay put, in their own order" "a1 a2 f1 " "$(order)"
check_contains "marker kept" "ACTIVE WORK" "$(head -1 "$STORE/MEMORY.md")"

echo ""
echo "=== reordering is a pure permutation ==="
reset
i=0; : > "$STORE/MEMORY.md"
while [ "$i" -lt 30 ]; do
  t=reference; [ $((i % 3)) -eq 0 ] && t=project; [ $((i % 5)) -eq 0 ] && t=feedback
  mem "m$i" "$t" "2026-01-$(printf '%02d' $((i % 28 + 1)))"
  entry "m$i" >> "$STORE/MEMORY.md"
  i=$((i+1))
done
BEFORE=$(grep '^- \[' "$STORE/MEMORY.md" | sort | shasum | awk '{print $1}')
run --write >/dev/null
AFTER=$(grep '^- \[' "$STORE/MEMORY.md" | sort | shasum | awk '{print $1}')
check_eq "same set of entry lines, byte for byte" "$BEFORE" "$AFTER"
check_eq "none lost" "30" "$(grep -c '^- \[' "$STORE/MEMORY.md")"

echo ""
echo "=== an older memory with a top-level type: is still sorted by it ==="
# These exist: `type:` at the top level rather than under `metadata:`. A stricter
# pattern filed 13 of them under REFERENCE while memory-lint, reading the same
# field permissively, called every one misfiled.
reset
mem r1 reference
printf -- '---\nname: oldstyle\ndescription: d\ntype: feedback\n---\nbody\n' > "$STORE/oldstyle.md"
{ entry r1; entry oldstyle; } > "$STORE/MEMORY.md"
run --write >/dev/null
check_eq "the top-level type wins its section" "oldstyle r1 " "$(order)"

echo ""
echo "=== an entry whose memory is missing or untyped is kept, above project ==="
reset
mem r1 reference; mem p1 project
{ entry r1; entry p1; entry ghost; } > "$STORE/MEMORY.md"
run --write >/dev/null
check_contains "the orphan entry survives" "ghost" "$(order)"
check_eq "and is not demoted below project" "r1 ghost p1 " "$(order)"

echo ""
echo "=== a second run changes nothing ==="
BEFORE=$(shasum < "$STORE/MEMORY.md" | awk '{print $1}')
check_eq "reports already ordered" "0" "$(run_rc)"
run --write >/dev/null
AFTER=$(shasum < "$STORE/MEMORY.md" | awk '{print $1}')
check_eq "byte-identical" "$BEFORE" "$AFTER"

echo ""
echo "=== check mode never writes ==="
reset
mem p1 project; mem f1 feedback
{ entry p1; entry f1; } > "$STORE/MEMORY.md"
BEFORE=$(shasum < "$STORE/MEMORY.md" | awk '{print $1}')
run >/dev/null 2>&1
check_eq "unchanged after a check run" "$BEFORE" "$(shasum < "$STORE/MEMORY.md" | awk '{print $1}')"

echo ""
echo "=== an unknown store is an error, not a silent success ==="
check_eq "exit 3" "3" "$(bash "$SCRIPT_UT" --store nosuchstore >/dev/null 2>&1; echo $?)"

echo ""
echo ""
echo "=== a line that is not an entry aborts, rather than being dropped ==="
# The permutation check filters both sides with `^- [`, the same predicate the
# reordering uses, so a line failing that predicate is equally absent from both
# and the check passes while the line disappears. Measured on a live store: an
# append with no trailing newline left a shell command fused to the front of an
# entry, and the memory silently left the index.
mem stray_a feedback
mem stray_b feedback
{ echo "- [T](stray_a.md) — hook"
  echo "grep -c . MEMORY.md; tail -2 MEMORY.md- [T](stray_b.md) — hook"; } > "$STORE/MEMORY.md"
BEFORE=$(cat "$STORE/MEMORY.md")
OUT=$(run --write)
check_contains "a stray line is named"        "neither an entry nor a tier marker" "$OUT"
check_contains "the stray's text is shown"    "stray_b.md"                          "$OUT"
check_contains "says why it would be lost"    "discard them silently"               "$OUT"
check_contains "names the likely cause"       "no trailing newline"                 "$OUT"
check_eq       "aborts with 3"                "3" "$(run_rc --write)"
check_eq       "and writes nothing"           "$BEFORE" "$(cat "$STORE/MEMORY.md")"

# A tier marker is a comment, not a stray, and must not trip the guard.
{ echo "<!-- FEEDBACK — how to work -->"
  echo "- [T](stray_a.md) — hook"
  echo "- [T](stray_b.md) — hook"; } > "$STORE/MEMORY.md"
OUT=$(run --write)
check_absent "a tier marker is not a stray" "neither an entry nor a tier marker" "$OUT"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
