#!/usr/bin/env bash
# Repairs the mechanical defects in a memory store that memory-verify.sh reports
# but deliberately will not touch.
#
# memory-verify.sh is read-only by contract, and that contract is worth keeping:
# it judges whether a CLAIM is still true, and a wrong edit there destroys
# knowledge. This script is the opposite kind of tool. It only ever fixes things
# with a single provably-correct answer — a name that must equal its filename, a
# link with exactly one possible target, a missing timestamp recoverable from the
# filesystem. Anything ambiguous is reported and left alone.
#
# Three repairs:
#
#   1. name: := filename stem.  A store accumulated 64 memories whose `name`
#      used hyphens while the file used underscores, which is what broke most of
#      the wiki-links. The frontmatter is rewritten and the FILE IS NEVER
#      RENAMED — the hundreds of links that already resolve point at filenames,
#      so renaming files would break the working majority to fix the broken few.
#
#   2. Wiki-links, on a unique match only.  `[[a-b-c]]` is repaired to `[[a_b_c]]`
#      when exactly one file matches ignoring separators. Zero matches or more
#      than one -> reported, never guessed.
#
#   3. metadata.modified backfilled, tagged with where the date came from so a
#      later substantive edit can upgrade it. File mtime first; when that has
#      been reset to today by tooling it carries no information, so the fallback
#      is the latest date written INSIDE the memory - a memory cannot predate
#      the events it records. Capped at today. If neither exists, it is left
#      unstamped and reported: no date at all beats a fabricated one.
#
# `modified` means "last substantive edit", so this script must never advance it.
# Every mtime is snapshotted BEFORE any file is touched and the backfill uses the
# snapshot — otherwise repair #1 would bump the clock on 64 files and repair #3
# would then record today's date for them, destroying the age signal corpus-wide
# in a single run.
#
# Usage:  bash memory-fix.sh [--store SLUG] [--apply] [--force]
#   --store SLUG  only this store (default: every store under ~/.claude/projects)
#   --apply       write the changes (default is a dry run)
#   --force       allow --apply on a store with uncommitted changes
#
# --apply refuses to run on a dirty git store, so the repair always lands as a
# reviewable, revertable commit of its own. Stores are git repos; if one is not,
# --apply refuses outright rather than editing something with no undo.
#
# Exit: 0 nothing to fix · 1 fixes pending (dry run) or applied · 3 could not run
#
# Portability: macOS ships bash 3.2 — no associative arrays, no mapfile.
set -u

PROJECTS="${CLAUDE_MEMORY_PROJECTS_DIR:-$HOME/.claude/projects}"
ONLY_STORE=""
APPLY=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --store) ONLY_STORE="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done

[ -d "$PROJECTS" ] || { echo "FATAL: no projects dir at $PROJECTS" >&2; exit 3; }

TMP="${TMPDIR:-/tmp}/memory-fix.$$"
mkdir -p "$TMP" || exit 3
trap 'rm -rf "$TMP"' EXIT

TOTAL_FIXES=0
TOTAL_UNRESOLVED=0
TODAY=$(date +%Y-%m-%d)
SOURCE=mtime

# ---------------------------------------------------------------------------
# Rewrite the first top-level `name:` inside the frontmatter block only.
# Restricted to the frontmatter so a `name:` appearing in a fenced YAML example
# further down the body is never touched.
# ---------------------------------------------------------------------------
rewrite_name() {  # rewrite_name <file> <new-stem>
  awk -v want="$2" '
    NR == 1 && $0 == "---" { infm = 1; print; next }
    infm && $0 == "---"    { infm = 0; print; next }
    infm && !done && /^name:[[:space:]]/ { print "name: " want; done = 1; next }
    { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---------------------------------------------------------------------------
# Insert `modified:` into the metadata block, after `type:` when present so the
# key order stays consistent with hand-written memories.
# ---------------------------------------------------------------------------
# Older memories keep `type:` at the top level of the frontmatter with no
# `metadata:` block at all. Restructuring them would be a bigger, riskier change
# than the one repair being made, so the stamp simply matches whichever style
# the file already uses. Both readers are indentation-permissive.
insert_modified() {  # insert_modified <file> <YYYY-MM-DD> <source>
  if ! grep -q '^metadata:' "$1"; then
    awk -v stamp="$2" -v src="$3" '
      NR == 1 && $0 == "---" { infm = 1; print; next }
      infm && $0 == "---" {
        if (!done) { print "modified: " stamp; print "modified_source: " src }
        infm = 0; print; next
      }
      { print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
    return
  fi
  awk -v stamp="$2" -v src="$3" '
    /^metadata:[[:space:]]*$/ { inmeta = 1; print; next }
    inmeta && /^[[:space:]]+type:/ {
      print
      print "  modified: " stamp
      print "  modified_source: " src
      inmeta = 0; done = 1; next
    }
    inmeta && !/^[[:space:]]/ {            # metadata block ended with no type:
      if (!done) { print "  modified: " stamp; print "  modified_source: " src; done = 1 }
      inmeta = 0
    }
    { print }
    END { }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

for dir in "$PROJECTS"/*/memory; do
  [ -d "$dir" ] || continue
  slug=$(basename "$(dirname "$dir")")
  [ -n "$ONLY_STORE" ] && [ "$slug" != "$ONLY_STORE" ] && continue

  ls "$dir"/*.md >/dev/null 2>&1 || continue

  # --- safety: --apply needs a clean git store so the change is revertable ----
  if [ "$APPLY" -eq 1 ]; then
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      echo "REFUSING $slug: not a git repo, so there would be no undo." >&2
      echo "  run: git -C '$dir' init && cd '$dir' && git add -- *.md && git commit -m baseline" >&2
      exit 3
    fi
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] && [ "$FORCE" -eq 0 ]; then
      echo "REFUSING $slug: uncommitted changes present; commit them first (or --force)." >&2
      exit 3
    fi
  fi

  # --- pass 0: snapshot mtimes BEFORE anything is edited ---------------------
  : > "$TMP/mtimes"
  for f in "$dir"/*.md; do
    printf '%s\t%s\n' "$(basename "$f")" "$(date -r "$f" +%Y-%m-%d 2>/dev/null || echo '')" >> "$TMP/mtimes"
  done

  N_NAME=0; N_LINK=0; N_STAMP=0; N_AMBIG=0; N_FWD=0; N_NODATE=0; N_BAD=0
  : > "$TMP/report"; : > "$TMP/fwd"

  # --- pass 1: name: := stem ------------------------------------------------
  for f in "$dir"/*.md; do
    b=$(basename "$f"); [ "$b" = "MEMORY.md" ] && continue
    [ "$b" = "ARCHIVE.md" ] && continue
    stem="${b%.md}"
    cur=$(sed -n '1,20p' "$f" | sed -n 's/^name:[[:space:]]*//p' | head -1 | tr -d '"'"'"'' | sed 's/[[:space:]]*$//')
    [ -z "$cur" ] && { echo "  MALFORMED  $b  (no name: in frontmatter)" >> "$TMP/report"; N_BAD=$((N_BAD+1)); continue; }
    [ "$cur" = "$stem" ] && continue
    N_NAME=$((N_NAME+1))
    [ "$N_NAME" -le 3 ] && echo "  name  $stem  <- was '$cur'" >> "$TMP/report"
    [ "$APPLY" -eq 1 ] && rewrite_name "$f" "$stem"
  done

  # --- pass 2: wiki-links, unique match only --------------------------------
  ls "$dir" | sed 's/\.md$//' > "$TMP/stems"
  # separator-insensitive key -> stem, for unique-match resolution
  awk '{ k = $0; gsub(/-/, "_", k); print k "\t" $0 }' "$TMP/stems" | sort > "$TMP/keyed"

  # `[[:space:]]` and friends are POSIX character classes appearing in regexes
  # quoted inside memory bodies, not links. They match the wiki-link shape
  # exactly, so they must be excluded here or the tool invents defects.
  grep -oh '\[\[[^]]*\]\]' "$dir"/*.md 2>/dev/null \
    | sed 's/\[\[//; s/\]\]//' \
    | grep -v '^:.*:$' \
    | sort -u > "$TMP/links"

  : > "$TMP/subs"
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    [ -f "$dir/$t.md" ] && continue                       # already resolves
    # Resolve ignoring separator style, and tolerating a stray `.md` suffix.
    key=$(printf '%s' "$t" | sed 's/\.md$//' | tr '-' '_')
    hits=$(awk -F'\t' -v k="$key" '$1 == k { print $2 }' "$TMP/keyed")
    n=$(printf '%s\n' "$hits" | grep -c . || true)
    if [ "$n" -eq 1 ]; then
      printf '%s\t%s\n' "$t" "$hits" >> "$TMP/subs"
      N_LINK=$((N_LINK+1))
    elif [ "$n" -eq 0 ]; then
      # No such memory. This is legitimate: the memory format treats a link to
      # a not-yet-written memory as a marker for something worth writing. Report
      # it as a prompt, never as a defect, and never guess a target.
      N_FWD=$((N_FWD+1))
      echo "  forward ref  [[$t]]  (no such memory yet)" >> "$TMP/fwd"
    else
      N_AMBIG=$((N_AMBIG+1))
      echo "  AMBIGUOUS link  [[$t]]  ($n candidates)" >> "$TMP/report"
    fi
  done < "$TMP/links"

  # Collapse every repair into a single sed program and make one pass per file.
  # Pairwise (link x file) greps are O(26 x 220) process spawns on a real store,
  # which is slow enough to blow a command timeout part-way through a write.
  if [ "$APPLY" -eq 1 ] && [ -s "$TMP/subs" ]; then
    awk -F'\t' '{ gsub(/[.[\]*\/\\^$]/, "\\\\&", $1); print "s/\\[\\[" $1 "\\]\\]/[[" $2 "]]/g" }' \
      "$TMP/subs" > "$TMP/sedprog"
    for f in "$dir"/*.md; do
      sed -f "$TMP/sedprog" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
  fi

  # --- pass 3: backfill modified from the pass-0 snapshot -------------------
  for f in "$dir"/*.md; do
    b=$(basename "$f"); [ "$b" = "MEMORY.md" ] && continue
    [ "$b" = "ARCHIVE.md" ] && continue
    grep -q '^[[:space:]]*modified:' "$f" && continue
    stamp=$(awk -F'\t' -v n="$b" '$1 == n { print $2 }' "$TMP/mtimes")
    [ -z "$stamp" ] && continue
    # An mtime of today carries no information about when the CLAIM last
    # changed: any tool that rewrites the file resets it, and a memory actually
    # written today would already carry a stamp, since the format requires one.
    # Stamping it would fabricate recency and hide the memory from age-gated
    # triage — the one failure mode worse than having no stamp at all.
    if [ "$stamp" = "$TODAY" ]; then
      # Fall back to the memory's own content. A memory cannot predate the
      # events it records, so the latest date written inside it is a real lower
      # bound on when it was last meaningfully edited - unlike an mtime that
      # any tool reset. Capped at today, so a memory describing planned work
      # cannot stamp itself into the future.
      stamp=$(grep -ohE '20[0-9]{2}-[01][0-9]-[0-3][0-9]' "$f" 2>/dev/null \
                | sort -u | awk -v t="$TODAY" '$0 <= t' | tail -1)
      if [ -z "$stamp" ]; then
        N_NODATE=$((N_NODATE+1))
        echo "  no usable date  $b  (mtime reset, and no date in the body)" >> "$TMP/fwd"
        continue
      fi
      SOURCE=content
    else
      SOURCE=mtime
    fi
    N_STAMP=$((N_STAMP+1))
    [ "$APPLY" -eq 1 ] && insert_modified "$f" "$stamp" "$SOURCE"
  done

  fixes=$((N_NAME + N_LINK + N_STAMP))
  TOTAL_FIXES=$((TOTAL_FIXES + fixes))
  TOTAL_UNRESOLVED=$((TOTAL_UNRESOLVED + N_AMBIG + N_BAD))

  if [ "$fixes" -gt 0 ] || [ "$N_AMBIG" -gt 0 ] || [ "$N_FWD" -gt 0 ] || [ "$N_NODATE" -gt 0 ] || [ "$N_BAD" -gt 0 ]; then
    echo "$slug"
    printf '  name:=stem %s   links repaired %s   modified backfilled %s   ambiguous %s   forward refs %s\n' \
      "$N_NAME" "$N_LINK" "$N_STAMP" "$N_AMBIG" "$N_FWD"
    [ "$N_BAD" -gt 0 ]    && printf '  %s memories have malformed frontmatter\n' "$N_BAD"
    [ "$N_NODATE" -gt 0 ] && printf '  %s memories have no usable date (mtime is today)\n' "$N_NODATE"
    [ -s "$TMP/report" ] && head -12 "$TMP/report"
    [ -s "$TMP/fwd" ] && head -12 "$TMP/fwd"
  fi
done

echo ""
if [ "$TOTAL_FIXES" -eq 0 ] && [ "$TOTAL_UNRESOLVED" -eq 0 ]; then
  echo "clean: nothing to fix"
  exit 0
fi
if [ "$APPLY" -eq 1 ]; then
  echo "applied $TOTAL_FIXES fixes; $TOTAL_UNRESOLVED left for a human"
else
  echo "$TOTAL_FIXES fixes pending, $TOTAL_UNRESOLVED unresolved — rerun with --apply"
fi
exit 1
