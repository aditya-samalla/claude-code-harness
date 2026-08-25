#!/usr/bin/env bash
# Tests for memory-verify.sh — builds a synthetic memory store in a temp dir and
# stubs GitHub, so the suite is hermetic: no real memories are read, no network
# call is made, and CI needs no gh credential.
set -u
SCRIPT="bin/memory-verify.sh"
PASS=0; FAIL=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_MEMORY_PROJECTS_DIR="$TMP/projects"
STORE="$CLAUDE_MEMORY_PROJECTS_DIR/teststore/memory"
mkdir -p "$STORE"

pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }

check_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" "expected to contain: $needle" ;;
  esac
}
check_absent() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) fail "$label" "expected NOT to contain: $needle" ;;
    *) pass "$label" ;;
  esac
}
check_eq() {
  local label="$1" expect="$2" got="$3"
  if [ "$got" = "$expect" ]; then pass "$label"; else fail "$label" "expect=$expect got=$got"; fi
}

# Date N days ago, portable across BSD (macOS) and GNU (CI) date.
days_ago() {
  date -v-"$1"d +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -d "$1 days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null
}

# A stub `gh` that answers only for known refs, so tests assert on our parsing
# and comparison rather than on GitHub.
cat > "$TMP/fakegh" <<'STUB'
#!/usr/bin/env bash
sub="$1"; shift
repo=""; num=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --json|-q) shift 2 ;;
    view) shift ;;
    *) [ -z "$num" ] && num="$1"; shift ;;
  esac
done
case "$sub:$repo#$num" in
  pr:acme/api#4821) echo "MERGED" ;;
  pr:acme/web#900)    echo "OPEN" ;;
  issue:acme/tools#42)    echo "CLOSED" ;;
  pr:acme/tools#42)       exit 1 ;;   # falls through to the issue lookup
  *) exit 1 ;;                            # unknown ref: lookup fails
esac
STUB
chmod +x "$TMP/fakegh"
export MEMORY_VERIFY_GH_CMD="$TMP/fakegh"

mem() {  # mem <filename> <age_days> <body...>
  local name="$1" age="$2"; shift 2
  {
    echo "---"
    echo "name: ${name%.md}"
    echo "description: fixture"
    echo "metadata:"
    echo "  type: project"
    echo "  modified: $(days_ago "$age")"
    echo "---"
    printf '%s\n' "$@"
  } > "$STORE/$name"
}

run() { bash "$SCRIPT" --store teststore "$@" 2>&1; }
run_rc() { bash "$SCRIPT" --store teststore "$@" >/dev/null 2>&1; echo $?; }

echo "=== A claim that matches reality is VERIFIED, not reported by default ==="
rm -f "$STORE"/*.md
mem ok.md 40 "verify:" "  - gh acme/api#4821 merged" "" "The idle-timeout fix landed."
OUT=$(run)
check_absent  "quiet when everything checks out" "ok.md" "$OUT"
check_contains "counted as verified"             "0 stale" "$OUT"
check_eq       "exit 0 when nothing needs attention" "0" "$(run_rc)"
OUT=$(run --all)
check_contains "--all surfaces it"    "VERIFIED" "$OUT"
check_contains "--all names the file" "ok.md"    "$OUT"

echo ""
echo "=== A claim contradicted by GitHub is STALE ==="
rm -f "$STORE"/*.md
mem stale.md 40 "verify:" "  - gh acme/api#4821 open" "" "Still a held draft, do not land yet."
OUT=$(run)
check_contains "flagged STALE"        "STALE"          "$OUT"
check_contains "names the file"       "stale.md"       "$OUT"
check_contains "shows expected"       "expected=open"  "$OUT"
check_contains "shows reality"        "actual=MERGED"  "$OUT"
check_eq       "exit 1 on stale"      "1" "$(run_rc)"

echo ""
echo "=== Falls back to the issue API when the number is not a PR ==="
rm -f "$STORE"/*.md
mem issue.md 40 "verify:" "  - gh acme/tools#42 open"
OUT=$(run)
check_contains "issue resolved and compared" "actual=CLOSED" "$OUT"

echo ""
echo "=== Unverifiable claims are SKIPped, never silently passed ==="
rm -f "$STORE"/*.md
mem jira.md    40 "verify:" "  - jira PROJ-123 Done"
mem bare.md    40 "verify:" "  - gh services#4821 merged"
mem unknown.md 40 "verify:" "  - notion abc123 done"
mem broken.md  40 "verify:" "  - gh acme/api#4821"
mem gone.md    40 "verify:" "  - gh acme/nope#1 merged"
OUT=$(run)
check_contains "jira gets its own finding"   "NEEDS_MCP"                  "$OUT"
check_contains "and says why"                "only through the Jira MCP"  "$OUT"
check_absent   "jira is not lumped into SKIP" "SKIP     teststore    jira.md" "$OUT"
check_contains "unqualified ref refused"     "ref-not-repo-qualified"     "$OUT"
check_contains "unknown kind refused"        "unknown verify kind"        "$OUT"
check_contains "malformed claim refused"     "malformed verify claim"     "$OUT"
check_contains "failed lookup refused"       "lookup-failed"              "$OUT"
check_eq       "exit 2 when only skips"      "2" "$(run_rc)"

echo ""
echo "=== An unverifiable open-state claim is triaged at ANY age ==="
# Not age-gated on purpose: a claim about something still open, with no verify
# block to check it against, is a defect the moment it is written. The corpus
# this was built for held a memory asserting three PRs were open when all three
# had merged that same day.
rm -f "$STORE"/*.md
mem old.md    40 "PENDING: merge, deploy, then live-verify. Refs services #4821."
mem fresh.md   0 "PENDING: merge, deploy, then live-verify."
OUT=$(run)
check_contains "old one triaged"          "TRIAGE"    "$OUT"
check_contains "names it"                 "old.md"    "$OUT"
check_contains "reports age"              "40d old"   "$OUT"
check_contains "a same-day one too"       "fresh.md"  "$OUT"
check_contains "reported as 0d, not hidden" "0d old"  "$OUT"
check_eq       "exit 2 on triage"         "2" "$(run_rc)"

echo ""
echo "=== but a durable fact with no liveness claim is still left alone ==="
rm -f "$STORE"/*.md
mem durable.md 0 "The consumer runs on one core; measured, not configured."
OUT=$(run)
check_absent "no finding for a fresh durable fact" "durable.md" "$OUT"
check_eq     "exit 0"                              "0" "$(run_rc)"

echo ""
echo "=== Self-contradiction inside one file is called out ==="
rm -f "$STORE"/*.md
mem both.md 40 "PENDING: awaiting review." "" "Update: merged and verified in prod."
OUT=$(run)
check_contains "contradiction noted" "self-contradictory" "$OUT"

echo ""
echo "=== Reference list is trimmed of noise and capped ==="
rm -f "$STORE"/*.md
mem noisy.md 40 "PENDING." "Hashes are SHA-256 and stamps are ISO-8601. See #1441 #1458."
mem many.md  40 "PENDING." "#1001 #1002 #1003 #1004 #1005 #1006 #1007 #1008 #1009 #1010"
OUT=$(run)
check_absent   "standards tokens dropped" "SHA-256"       "$OUT"
check_absent   "iso token dropped"        "ISO-8601"      "$OUT"
check_contains "real refs kept"           "#1441"         "$OUT"
check_contains "long lists capped"        "and 2 more"    "$OUT"

echo ""
echo "=== The index is checked for claims, but is not itself a memory ==="
# It is a list of links, so it gets no verify-block resolution and is never
# counted as a memory — but its one-liners are prose that can go stale, and
# they are the part loaded into context every session.
rm -f "$STORE"/*.md
{
  echo "verify:"
  echo "  - gh acme/api#4821 open"
  echo "- [Thing](thing.md) — a stable note about the loader"
} > "$STORE/MEMORY.md"
OUT=$(run)
check_absent "verify block in the index is not resolved" "STALE" "$OUT"
check_eq     "nothing to report"                          "0" "$(run_rc)"

rm -f "$STORE"/*.md
printf -- "- [Gone](gone.md) — PENDING, awaiting review\n" > "$STORE/MEMORY.md"
OUT=$(run)
check_contains "claim about a missing target still flagged" "MEMORY.md:1" "$OUT"

echo ""
echo "=== Counters survive multiple claims in one file (subshell regression) ==="
rm -f "$STORE"/*.md
mem multi.md 40 "verify:" \
  "  - gh acme/api#4821 open" \
  "  - gh acme/web#900 merged" \
  "  - gh acme/api#4821 merged"
OUT=$(run)
check_contains "both mismatches counted" "2 stale" "$OUT"
check_contains "match counted too"       "1 verified" "$OUT"

echo ""
echo "=== --json is machine-readable ==="
rm -f "$STORE"/*.md
mem j.md 40 "verify:" "  - gh acme/api#4821 open"
OUT=$(run --json)
if printf '%s\n' "$OUT" | jq -e . >/dev/null 2>&1; then pass "emits valid JSON"; else fail "emits valid JSON" "$OUT"; fi
check_eq "json status field" "STALE" "$(printf '%s\n' "$OUT" | jq -r '.status' | head -1)"
check_eq "json file field"   "j.md"  "$(printf '%s\n' "$OUT" | jq -r '.file'   | head -1)"
check_eq "json store field"  "teststore" "$(printf '%s\n' "$OUT" | jq -r '.store' | head -1)"

echo ""
echo "=== Memories are never modified ==="
rm -f "$STORE"/*.md
mem immutable.md 40 "verify:" "  - gh acme/api#4821 open"
BEFORE=$(shasum -a 256 "$STORE/immutable.md" | awk '{print $1}')
run >/dev/null 2>&1
AFTER=$(shasum -a 256 "$STORE/immutable.md" | awk '{print $1}')
check_eq "file untouched after a run" "$BEFORE" "$AFTER"

echo ""
echo "=== A clean store prints nothing at all, not a bare header ==="
rm -f "$STORE"/*.md
mem quiet.md 40 "Nothing in flight here; this just records how the loader works."
OUT=$(run)
check_absent "no store header when there is nothing to say" "teststore" "$OUT"
check_contains "still reports totals" "0 stale, 0 triage" "$OUT"

echo ""
echo "=== State words are matched on word boundaries ==="
rm -f "$STORE"/*.md
mem unres.md 40 "PENDING review. The root cause is still unresolved."
OUT=$(run)
check_contains "still triaged"                    "unres.md"           "$OUT"
check_absent   "'unresolved' is not closed state" "self-contradictory" "$OUT"
rm -f "$STORE"/*.md
mem withheld.md 40 "Payment was withheld last quarter."
OUT=$(run)
check_absent "'withheld' does not mean 'held'" "withheld.md" "$OUT"

echo ""
echo "=== Prose that merely reuses state words is not an open claim ==="
# All three are real sentences from the memories this was first run against.
rm -f "$STORE"/*.md
mem heldout.md  40 "Fitted on two tenants; predicts 702s vs actual 741s (5% held-out error)."
mem bearing.md  40 "The claim will recur on future additions and is load-bearing in review."
mem disposn.md  40 "Every candidate gets a disposition: included / held / skipped-with-reason."
OUT=$(run)
check_absent "'held-out' is a statistic"        "heldout.md" "$OUT"
check_absent "'in review' as prose, not status" "bearing.md" "$OUT"
check_absent "'held' as a disposition label"    "disposn.md" "$OUT"

echo ""
echo "=== but the terms that earn their place still fire ==="
rm -f "$STORE"/*.md
mem p1.md 40 "PENDING: merge and release."
mem p2.md 40 "Notebook committed but NOT pushed — awaiting a go for push/PR."
mem p3.md 40 "Shipped behind draft PR 1493; do not land yet."
OUT=$(run)
check_contains "pending fires"  "p1.md" "$OUT"
check_contains "awaiting fires" "p2.md" "$OUT"
check_contains "draft pr fires" "p3.md" "$OUT"

echo ""
echo "=== A stale claim in the index itself is caught ==="
# The index is skipped as a memory, which used to mean a stale hook was never
# examined — despite being the part loaded into context every session.
rm -f "$STORE"/*.md
mem thing.md 40 "This one is fine and says nothing about being in flight."
printf -- "- [Thing](thing.md) — awaiting the new dump before regenerating\n" > "$STORE/MEMORY.md"
OUT=$(run)
check_contains "index line flagged"        "MEMORY.md:1" "$OUT"
check_contains "names the linked memory"   "thing.md"    "$OUT"
check_contains "ages by the linked memory" "40d old"     "$OUT"

echo ""
echo "=== ...but a fresh index line is not nagged about ==="
rm -f "$STORE"/*.md
mem recent.md 2 "Body says nothing in flight."
printf -- "- [Recent](recent.md) — awaiting review\n" > "$STORE/MEMORY.md"
OUT=$(run)
check_absent "young linked memory left alone" "MEMORY.md" "$OUT"

echo ""
echo "=== A clean index stays silent ==="
rm -f "$STORE"/*.md
mem calm.md 40 "Nothing in flight."
printf -- "- [Calm](calm.md) — how the loader resolves paths\n" > "$STORE/MEMORY.md"
OUT=$(run)
check_absent "no index noise when clean" "MEMORY.md" "$OUT"
check_eq     "exit 0"                    "0" "$(run_rc)"

echo ""
echo "=== A store that does not exist is an error, not a clean bill of health ==="
OUT=$(bash "$SCRIPT" --store no-such-store 2>&1)
RC=$(bash "$SCRIPT" --store no-such-store >/dev/null 2>&1; echo $?)
check_contains "says the store is missing" "no store named" "$OUT"
check_eq       "exit 3, not 0"             "3" "$RC"

echo ""

# ---------------------------------------------------------------------------
# Index load limits. The index is the only file pulled into context every
# session, so passing either limit truncates its tail silently.
# ---------------------------------------------------------------------------
mem_about() {  # mem_about <filename> <age_days> <ticket-key> <body...>
  local name="$1" age="$2" key="$3"; shift 3
  {
    echo "---"
    echo "name: ${name%.md}"
    echo "description: $key fixture"
    echo "metadata:"
    echo "  type: project"
    echo "  modified: $(days_ago "$age")"
    echo "---"
    printf '%s\n' "$@"
  } > "$STORE/$name"
}

rm -f "$STORE"/*.md
mem a.md 1 "plain body"

echo ""
echo "=== An index inside both limits is not flagged ==="
echo "- [a](a.md) — hook" > "$STORE/MEMORY.md"
OUT=$(run)
check_absent "no OVERSIZE for a small index" "OVERSIZE" "$OUT"

echo ""
echo "=== An index past the LINE limit is OVERSIZE ==="
i=0; : > "$STORE/MEMORY.md"
while [ "$i" -lt 205 ]; do echo "- [a](a.md) — hook" >> "$STORE/MEMORY.md"; i=$((i+1)); done
export MEMORY_INDEX_MAX_LINES=200
OUT=$(run)
check_contains "flagged"                 "OVERSIZE"        "$OUT"
check_contains "names the line count"    "205/200 lines"   "$OUT"
check_contains "counts the entries"      "205 entries"     "$OUT"
check_contains "says shortening hooks cannot fix it" "shortening hooks cannot fix" "$OUT"
RC=$(run_rc)
check_eq "oversize alone still exits 2 (needs attention)" "2" "$RC"
unset MEMORY_INDEX_MAX_LINES

echo ""
echo "=== An index past the CHAR limit is OVERSIZE even when the line count is fine ==="
: > "$STORE/MEMORY.md"
LONG=$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0)
i=0
while [ "$i" -lt 10 ]; do echo "- [a](a.md) — $LONG" >> "$STORE/MEMORY.md"; i=$((i+1)); done
export MEMORY_INDEX_MAX_CHARS=100
OUT=$(run)
check_contains "flagged on chars"     "OVERSIZE" "$OUT"
check_contains "names the char limit" "/100 chars" "$OUT"
unset MEMORY_INDEX_MAX_CHARS
OUT=$(run)
check_absent "and is silent again at the default char limit" "OVERSIZE" "$OUT"

# ---------------------------------------------------------------------------
# Curation pass. Overlap only — there is deliberately no retirement heuristic.
# ---------------------------------------------------------------------------
echo ""
echo "=== --curate groups memories that make the SAME CLAIMS ==="
rm -f "$STORE"/*.md
mem_about one.md   40 "PROJ-77" "**the consumer runs on a single core, measured**" \
                                "**the tier is discovered by OOM retry, not configured**"
mem_about two.md   40 "PROJ-77" "restating it: **the consumer runs on a single core, measured**" \
                                "and **the tier is discovered by OOM retry, not configured**"
OUT=$(run --curate)
check_contains "an overlapping pair is a merge candidate" "merge? these two share 2" "$OUT"
check_contains "the first file is named"                  "one.md"                   "$OUT"
check_contains "the second file is named"                 "two.md"                   "$OUT"

echo ""
echo "=== sharing a ticket key but no claims is NOT a merge candidate ==="
# The heuristic this replaced keyed on ticket number. Measured on a real store
# that produced four groups, of which three shared zero content: one memory
# records a fix and another records a lesson learned beside it, and they are
# correctly separate files.
rm -f "$STORE"/*.md
mem_about fix.md    40 "PROJ-77" "**the null check was missing on the boot path**"
mem_about lesson.md 40 "PROJ-77" "**always read cardinalities before theorising**"
OUT=$(run --curate)
check_absent "same ticket alone does not group" "CANDIDATE" "$OUT"

echo ""
echo "=== a single shared claim is below the threshold ==="
rm -f "$STORE"/*.md
mem_about a.md 40 "PROJ-1" "**one identical sentence shared between the pair**"
mem_about b.md 40 "PROJ-2" "**one identical sentence shared between the pair**"
OUT=$(run --curate)
check_absent "one overlap is not enough" "CANDIDATE" "$OUT"

echo ""
echo "=== short bolded labels do not manufacture overlap ==="
rm -f "$STORE"/*.md
mem_about x.md 40 "PROJ-3" "**Note**" "**Why:**" "distinct body one"
mem_about y.md 40 "PROJ-4" "**Note**" "**Why:**" "distinct body two"
OUT=$(run --curate)
check_absent "labels are excluded by the length floor" "CANDIDATE" "$OUT"

echo ""

echo "=== Candidates are advisory: only with --curate, and never a deletion ==="
OUT=$(run)
check_absent "no CANDIDATE without the flag" "CANDIDATE" "$OUT"
OUT=$(run --curate)
check_absent "never proposes retirement"     "retire?"   "$OUT"

echo ""
echo "=== --curate still modifies nothing ==="
SUM_BEFORE=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
run --curate >/dev/null 2>&1
SUM_AFTER=$(cat "$STORE"/*.md | shasum | awk '{print $1}')
check_eq "memories are byte-identical after a curate run" "$SUM_BEFORE" "$SUM_AFTER"

echo "--- Results: $PASS passed, $FAIL failed"
exit "$FAIL"
