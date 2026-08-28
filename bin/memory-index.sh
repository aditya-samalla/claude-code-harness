#!/usr/bin/env bash
# Orders MEMORY.md by memory type, so that when the index is truncated the lines
# it drops are the cheapest ones.
#
# The index is loaded into every session and truncated tail-first past ~200
# lines. Left in append order it therefore drops the NEWEST entries: measured on
# a real 218-memory store, 19 entries fell past the cut and five of them were
# `feedback` memories - rules about how to work, which do nothing at all unless
# they are loaded. The most expensive lines to lose were exactly the ones being
# lost.
#
# The order, cheapest-to-lose last:
#
#   ACTIVE     hand-curated block at the top, passed through untouched
#   feedback   behaviour rules; worthless unless loaded, so never in the tail
#   reference  durable facts. An index line is how the model learns one EXISTS,
#              so these cannot be demoted on the assumption it will go looking.
#   project    lifecycle-bound and the only type with a natural exit. Newest
#              first, so the tail is the oldest - the archive-eligible end.
#
# This does not fix the size. On a corpus that is mostly live work nothing does:
# measured against Jira, only 3 of 56 project memories were provably settled, so
# neither merging nor archiving reclaims the lines. Ordering is the lever that
# actually exists, which makes truncation survivable rather than lossy.
#
# A pure permutation, always: every entry line is preserved byte-identical, and
# the run aborts before writing if the set of entries changed at all.
#
# Usage:  bash memory-index.sh [--store SLUG] [--write]
#   --store SLUG  only this store (default: every store under ~/.claude/projects)
#   --write       reorder in place (default: report whether it is already ordered)
#
# Exit: 0 already ordered (or written) · 1 out of order · 3 could not run
#
# Portability: macOS ships bash 3.2 — no associative arrays, no mapfile.
set -u

PROJECTS="${CLAUDE_MEMORY_PROJECTS_DIR:-$HOME/.claude/projects}"
ONLY_STORE=""
WRITE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --store) ONLY_STORE="${2:-}"; shift 2 ;;
    --write) WRITE=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done

[ -d "$PROJECTS" ] || { echo "FATAL: no projects dir at $PROJECTS" >&2; exit 3; }

# Section markers. memory-lint.sh reads these to tell which section a line is
# in, so the two must agree; keep the leading text stable.
# The ACTIVE marker is only ever READ, never written: that block is hand-curated
# and this script passes it through, so a store without one does not get one.
M_ACTIVE_PREFIX='<!-- ACTIVE WORK'
M_FEEDBACK='<!-- FEEDBACK — how to work; these only function when loaded, so never in the tail -->'
M_REFERENCE='<!-- REFERENCE — durable facts; the index line is how the model learns they exist -->'
M_PROJECT='<!-- PROJECT — lifecycle-bound, newest first; the oldest tail is archive-eligible -->'

TMP="${TMPDIR:-/tmp}/memory-index.$$"
mkdir -p "$TMP" || exit 3
trap 'rm -rf "$TMP"' EXIT

RC=0
STORES=0

for dir in "$PROJECTS"/*/memory; do
  [ -d "$dir" ] || continue
  slug=$(basename "$(dirname "$dir")")
  [ -n "$ONLY_STORE" ] && [ "$slug" != "$ONLY_STORE" ] && continue
  idx="$dir/MEMORY.md"
  [ -f "$idx" ] || continue
  STORES=$((STORES+1))

  # The ACTIVE block is the leading comment plus the entries directly under it,
  # up to the first blank line. It is hand-curated and passed through as-is.
  : > "$TMP/active"
  first=$(head -1 "$idx")
  case "$first" in
    "$M_ACTIVE_PREFIX"*)
      # `exit` still runs END in awk, so guard it with a flag or this prints twice.
      end=$(awk 'NR>1 && !/^- \[/ { print NR-1; f=1; exit } END { if (!f) print NR }' "$idx")
      head -n "$end" "$idx" > "$TMP/active"
      ;;
    *) end=0 ;;
  esac

  awk -v s="$end" 'NR>s && /^- \[/' "$idx" > "$TMP/rest"

  : > "$TMP/feedback"; : > "$TMP/reference"; : > "$TMP/project"; : > "$TMP/unknown"
  while IFS= read -r line; do
    f=$(printf '%s\n' "$line" | sed -n 's/.*](\([^)]*\)).*/\1/p')
    t=""
    # Permissive on indentation on purpose: older memories carry `type:` at the
    # top level rather than nested under `metadata:`. A stricter pattern saw no
    # type on 13 of them, filed them all under REFERENCE, and memory-lint - which
    # reads the same field permissively - then reported every one as misfiled.
    # Two tools must not disagree about what a memory IS.
    [ -n "$f" ] && [ -f "$dir/$f" ] && t=$(sed -n 's/^[[:space:]]*type:[[:space:]]*\([a-z]*\)[[:space:]]*$/\1/p' "$dir/$f" | head -1)
    case "$t" in
      feedback|user) printf '%s\n' "$line" >> "$TMP/feedback" ;;
      reference)     printf '%s\n' "$line" >> "$TMP/reference" ;;
      project)
        # Sort key is the memory's own timestamp, falling back to file mtime.
        m=$(sed -n 's/^  modified: *\([0-9-]*\).*/\1/p' "$dir/$f" | head -1)
        [ -n "$m" ] || m=$(date -r "$dir/$f" +%Y-%m-%d 2>/dev/null || echo 0000-00-00)
        printf '%s\t%s\n' "$m" "$line" >> "$TMP/project" ;;
      # No resolvable type: keep it, and keep it above project so a memory that
      # is merely malformed is not silently demoted to the truncated tail.
      *)             printf '%s\n' "$line" >> "$TMP/unknown" ;;
    esac
  done < "$TMP/rest"

  {
    if [ -s "$TMP/active" ]; then cat "$TMP/active"; echo ""; fi
    if [ -s "$TMP/feedback" ]; then echo "$M_FEEDBACK"; cat "$TMP/feedback"; echo ""; fi
    if [ -s "$TMP/reference" ] || [ -s "$TMP/unknown" ]; then
      echo "$M_REFERENCE"
      [ -s "$TMP/reference" ] && cat "$TMP/reference"
      [ -s "$TMP/unknown" ]   && cat "$TMP/unknown"
      echo ""
    fi
    if [ -s "$TMP/project" ]; then echo "$M_PROJECT"; sort -r "$TMP/project" | cut -f2-; fi
  } > "$TMP/new"

  # Abort before writing anything if this is not a pure permutation.
  grep '^- \[' "$idx"     | sort > "$TMP/a"
  grep '^- \[' "$TMP/new" | sort > "$TMP/b"
  if ! cmp -s "$TMP/a" "$TMP/b"; then
    echo "ABORT $slug: reordering would not be a pure permutation" >&2
    diff "$TMP/a" "$TMP/b" | head -5 >&2
    exit 3
  fi

  # The check above cannot see its own blind spot: it filters both sides with
  # `^- [`, the same predicate the reordering uses. A line that fails that
  # predicate is equally absent from BOTH sides, so the comparison passes while
  # the line is dropped. Measured on a live store: an index entry acquired a
  # leaked shell-command prefix from an append with no trailing newline
  # ("grep -c . MEMORY.md; tail -2 MEMORY.md- [AgentTool unblocked...").
  # It stopped being an entry, the permutation check saw nothing wrong, and the
  # memory silently left the index -- which is the only way the model learns it
  # exists. A checker whose population is defined by the predicate under test
  # cannot catch a failure of that predicate, so this counts EVERY line.
  awk 'NF && $0 !~ /^- \[/ && $0 !~ /^<!--/ { print }' "$idx" > "$TMP/strays"
  if [ -s "$TMP/strays" ]; then
    echo "ABORT $slug: $(wc -l < "$TMP/strays" | tr -d ' ') line(s) in the index are neither an entry nor a tier marker." >&2
    echo "  Reordering would discard them silently. Repair them first:" >&2
    cut -c1-100 "$TMP/strays" | sed 's/^/    /' >&2
    echo "  A stray is usually an append with no trailing newline colliding with the next line." >&2
    exit 3
  fi

  n=$(wc -l < "$TMP/a" | tr -d ' ')
  if cmp -s "$idx" "$TMP/new"; then
    [ -n "$ONLY_STORE" ] && echo "$slug: already ordered ($n entries)"
    continue
  fi

  if [ "$WRITE" -eq 1 ]; then
    cp "$TMP/new" "$idx"
    echo "$slug: reordered ($n entries: feedback $(wc -l < "$TMP/feedback" | tr -d ' '), reference $(wc -l < "$TMP/reference" | tr -d ' '), project $(wc -l < "$TMP/project" | tr -d ' '))"
  else
    echo "$slug: OUT OF ORDER ($n entries) — rerun with --write"
    RC=1
  fi
done

if [ "$STORES" -eq 0 ]; then
  echo "FATAL: no store to check${ONLY_STORE:+ named '$ONLY_STORE'}" >&2
  exit 3
fi
exit "$RC"
