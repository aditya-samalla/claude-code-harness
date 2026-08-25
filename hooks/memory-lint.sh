#!/usr/bin/env bash
# Checks a memory the moment it is written, instead of months later in an audit.
#
# Every defect the memory audit finds is cheap to fix at write time and
# expensive afterwards. A `name:` that disagrees with its filename silently
# breaks every wiki-link pointing at it. A description carrying volatile state
# ("3 PRs open") is wrong within days and nothing detects it, because the
# contradiction lives on GitHub rather than in the file. A claim about work
# still in flight, with no `verify:` block, can never be checked at all.
#
# Without this hook, memory-fix.sh and the audit skill are a cleanup that gets
# repeated forever: a corpus of 218 memories accumulated 64 name mismatches, 26
# broken links and 88 missing timestamps, and a memory written by the live
# system DURING the session that fixed all of them arrived with no timestamp and
# a 176-character index hook.
#
# Advisory by design. This is a PostToolUse hook, so the write has already
# happened; the findings go back to the model while the context is still hot and
# the fix costs one edit. It never blocks and never edits.
source "$(dirname "$0")/lib.sh"

read_input
command -v jq &>/dev/null || exit 0     # advisory only; never fail a write
TOOL=$(jq_get '.tool_name')

case "$TOOL" in
  Write|Edit|MultiEdit) FILE=$(jq_get '.tool_input.file_path') ;;
  *) exit 0 ;;
esac

[ -n "$FILE" ] || exit 0
case "$FILE" in
  */memory/*.md) ;;
  *) exit 0 ;;
esac
BASE=$(basename "$FILE")
case "$BASE" in
  MEMORY.md|ARCHIVE.md) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0

DIR=$(dirname "$FILE")
INDEX_LINE_MAX="${MEMORY_INDEX_LINE_MAX:-110}"
STEM="${BASE%.md}"
FINDINGS=""
add() { FINDINGS="${FINDINGS}  - $1
"; }

# --- identity -------------------------------------------------------------
NAME=$(sed -n '1,20p' "$FILE" | sed -n 's/^name:[[:space:]]*//p' | head -1 | tr -d '"'"'"'' | sed 's/[[:space:]]*$//')
if [ -z "$NAME" ]; then
  add "no \`name:\` in the frontmatter"
elif [ "$NAME" != "$STEM" ]; then
  add "\`name: $NAME\` does not match the filename \`$STEM\`. Every [[$STEM]] link resolves by filename, so this silently breaks them — set name to the stem."
fi

# --- type -----------------------------------------------------------------
TYPE=$(sed -n 's/^[[:space:]]*type:[[:space:]]*//p' "$FILE" | head -1)
case "$TYPE" in
  user|feedback|project|reference) ;;
  "") add "no \`metadata.type\`. One of: user, feedback, project, reference." ;;
  *)  add "\`metadata.type: $TYPE\` is not one of user, feedback, project, reference." ;;
esac

# --- timestamp ------------------------------------------------------------
grep -q '^[[:space:]]*modified:' "$FILE" \
  || add "no \`metadata.modified\`. Without it, age falls back to file mtime, which any tool touching the file resets."

# --- description ----------------------------------------------------------
# The description becomes the index hook, and the index is the only thing loaded
# into every session. Volatile state in a hook is the drift that no checker can
# catch: the file says merged, the hook still says open, and nothing disagrees
# with itself inside the file.
DESC=$(sed -n 's/^description:[[:space:]]*//p' "$FILE" | head -1 | tr -d '"')
if [ -z "$DESC" ]; then
  add "no \`description:\`. It becomes the index hook, so the memory is unfindable without it."
else
  # No length check here on purpose. The description is the fuller summary and
  # runs long by convention (median 167 chars in a real store); it is the INDEX
  # LINE that gets clipped, and that is checked below.
  if printf '%s' "$DESC" | grep -qiE '\b(still open|now open|pending|awaiting|in progress|not yet (merged|landed|deployed)|[0-9]+ prs? open|unreviewed|blocked on)\b'; then
    add "the description asserts changing state. A hook is a retrieval cue, not a status: say what the memory is ABOUT and keep the state in the body next to a \`verify:\` block."
  fi
fi

# --- unverifiable liveness claims ----------------------------------------
OPEN_RE='\b(pending|draft pr|awaiting|not yet (merged|deployed|landed|shipped)|blocked on|still open|will land)\b'
if grep -qiE "$OPEN_RE" "$FILE" && ! grep -q '^verify:' "$FILE"; then
  add "asserts work still in flight but carries no \`verify:\` block, so nothing can ever check it. Add one, e.g. \`  - gh owner/repo#123 open\` or \`  - jira PROJ-1 In Progress\`."
fi

# --- links that were MEANT to resolve ------------------------------------
# A link to a memory that does not exist is legitimate — it marks something
# worth writing. A link whose only problem is separator style is a typo.
# Read loop rather than `for t in $(...)`: word splitting on an unquoted
# expansion is a shell-dependent behaviour, and getting it wrong here fails
# open, silently.
while IFS= read -r t; do
  [ -z "$t" ] && continue
  [ -f "$DIR/$t.md" ] && continue
  alt=$(printf '%s' "$t" | tr '-' '_')
  [ "$alt" != "$t" ] && [ -f "$DIR/$alt.md" ] \
    && add "[[$t]] does not resolve, but [[$alt]] does — underscores, not hyphens."
done <<EOF
$(grep -oh '\[\[[^]]*\]\]' "$FILE" 2>/dev/null | sed 's/\[\[//; s/\]\]//' | grep -v '^:.*:$' | sort -u)
EOF

# --- indexed? -------------------------------------------------------------
if [ -f "$DIR/MEMORY.md" ]; then
  IDX=$(grep -m1 "($BASE)" "$DIR/MEMORY.md")
  if [ -z "$IDX" ]; then
    add "no line in MEMORY.md points at $BASE, so it will never be recalled. Add one, in the section for its type."
  else
    # Nothing clips an index line on the way in - a 109-char line arrives in
    # the session verbatim. The budget exists because the index as a WHOLE has
    # a ~25,000 character limit, and one line per memory means the per-line
    # average is the only lever on it: 220 entries x 110 chars is already
    # 24,200. Compose the hook to fit. Hand-clipping to fit is what left a live
    # index with entries ending "per-policy ms ALREADY" and "superset".
    ILEN=${#IDX}
    [ "$ILEN" -gt "$INDEX_LINE_MAX" ] \
      && add "its index line is $ILEN chars and is clipped around $INDEX_LINE_MAX, so the hook is cut mid-clause. Shorten the hook (or the title), do not let it truncate."

    # An index hook carrying changing state is the drift no checker can catch.
    # The file and the hook never contradict each other from inside the store —
    # the contradiction lives on GitHub. A live index had a hook reading
    # "3 PRs open (#1938 #1608 #29)" pointing at a memory whose own body already
    # said all three had merged, and it sat in the most-read block of the file.
    if printf '%s' "$IDX" | grep -qiE '\b(still open|now open|pending|awaiting|in progress|not yet (merged|landed|deployed)|[0-9]+ prs? open|unreviewed|blocked on)\b'; then
      add "its index line asserts changing state. The hook is the one thing loaded into every session and nothing inside the store can ever contradict it — say what the memory is ABOUT and leave the state in the body."
    fi

    # Placement. The index is ordered by type so that truncation drops the
    # cheapest lines; an entry filed under the wrong marker defeats that
    # silently. The live memory writer appends to the end of the file
    # regardless of type, so this fires exactly when it should.
    SECTION=$(awk -v want="$IDX" '
      /^<!--/ { m = $0 }
      $0 == want { print m; exit }
    ' "$DIR/MEMORY.md")
    case "$SECTION" in
      *"ACTIVE WORK"*|"") ;;                       # hand-curated, or unsorted index
      *FEEDBACK*)  [ "$TYPE" = "feedback" ] || [ "$TYPE" = "user" ] \
                     || add "its index line sits in the FEEDBACK section but the memory is \`type: $TYPE\`. Run: bash bin/memory-index.sh --store <slug> --write" ;;
      *REFERENCE*) [ "$TYPE" = "reference" ] \
                     || add "its index line sits in the REFERENCE section but the memory is \`type: $TYPE\`. Run: bash bin/memory-index.sh --store <slug> --write" ;;
      *PROJECT*)   [ "$TYPE" = "project" ] \
                     || add "its index line sits in the PROJECT section but the memory is \`type: $TYPE\`. Run: bash bin/memory-index.sh --store <slug> --write" ;;
    esac
  fi
fi

[ -n "$FINDINGS" ] || exit 0

printf 'memory-lint on %s:\n%s\nFix these now — each one is a single edit here, and none of them is detectable later.\n' \
  "$BASE" "$FINDINGS" >&2
exit 2
