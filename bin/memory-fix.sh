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
# And one separate repair, run on its own with --provenance:
#
#   4. metadata.originSessionId recovered from Claude Code's transcripts.
#      Without an origin nothing can tell a fact that survived months from one a
#      peer session appended minutes ago, and a session can cite a memory as
#      corroboration for the very finding that wrote it. Claude Code stamps the
#      origin when it writes a memory through its own memory path; a memory
#      written by other means carries none. The transcripts still hold the
#      answer, because the write itself was recorded there.
#
# Usage:  bash memory-fix.sh [--store SLUG] [--provenance] [--apply] [--force]
#   --store SLUG  only this store (default: every store under ~/.claude/projects)
#   --provenance  run repair 4 INSTEAD of repairs 1-3 (see below)
#   --apply       write the changes (default is a dry run)
#   --force       allow --apply on a store with uncommitted changes
#
# ---- repair 4, and why it looks the way it does ---------------------------
#
# The evidence is one grep over every transcript, ~7s for the whole corpus. A
# per-memory scan is the obvious implementation and takes minutes, which is slow
# enough that nobody runs it; so the pass is inverted — read every write once,
# and index it by the memory it touched.
#
# TWO write shapes, and the second one is the whole point. The obvious query
# finds `"file_path"` on a Write/Edit/MultiEdit tool call. Measured on this
# corpus — 332 memories, 112 of them carrying no origin — that shape recovers
# exactly ONE of the 112, because a memory Claude Code wrote through its own
# tool is a memory it had already stamped itself. The unstamped ones were
# written by the other shape, a Bash heredoc: `cat > "$M/name.md" <<EOF`. It
# carries no `file_path` key anywhere, so that query cannot see it. Adding it
# takes the recovery from 1 to 91. An instrument that reads one spelling of a
# write is not a census of writes, and here the spelling it missed was 99% of
# the answer.
#
# EARLIEST WRITE WINS, which is bin/session-route.sh's rule for pr-link records
# and is settled there: several sessions write the same memory, and the one that
# created it is the one that got there first. Ties are not handled because
# millisecond timestamps do not tie.
#
# DERIVED, AND SAID SO. Both `originSessionId` and `originSessionId_source:
# transcript` are written. A recovered origin is an inference from a side effect
# a session left behind, not that session's own record of itself, and the two
# have to stay tellable apart. Measured: of the 220 memories already carrying a
# first-party stamp this derivation has an opinion about 66, and reproduces the
# first-party answer on 58 of them (88%). The other 8 are memories whose
# first-party stamp names a session with no write to that path recorded
# anywhere — so on those the transcripts and the stamp disagree about who wrote
# it, and the stamp is the one that wins (see below).
#
# NEVER OVERWRITTEN, NEVER INVENTED. A memory that already has an origin is
# skipped whatever the transcripts say. A memory with no write recorded anywhere
# stays ANON and is counted in the report rather than dropped from it: a run
# that reports only its successes is exactly how the 111-memory blind spot above
# would have stayed invisible behind a confident "recovered 1".
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
PROVENANCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --store) ONLY_STORE="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --force) FORCE=1; shift ;;
    --provenance) PROVENANCE=1; shift ;;
    -h|--help) sed -n '2,90p' "$0"; exit 0 ;;
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
TOTAL_SCAN=0; TOTAL_HAVE=0; TOTAL_GOT=0; TOTAL_ANON=0; TOTAL_INDEX=0; STALE=0

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

# ---------------------------------------------------------------------------
# Insert `originSessionId:` + `originSessionId_source:` — same placement rules as
# insert_modified, for the same reason: match the shape the file already uses
# rather than restructuring it.
# ---------------------------------------------------------------------------
# The `_source` key is not decoration. A first-party stamp is the writer's own
# record of itself; this one is inferred from a side effect it left in a
# transcript, and a reader weighing whether a memory independently corroborates
# something needs to be able to tell which kind they are holding.
insert_origin() {  # insert_origin <file> <session-uuid>
  if ! grep -q '^metadata:' "$1"; then
    awk -v sid="$2" '
      NR == 1 && $0 == "---" { infm = 1; print; next }
      infm && $0 == "---" {
        if (!done) { print "originSessionId: " sid; print "originSessionId_source: transcript" }
        infm = 0; print; next
      }
      { print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
    return
  fi
  awk -v sid="$2" '
    /^metadata:[[:space:]]*$/ { inmeta = 1; print; next }
    inmeta && /^[[:space:]]+type:/ {
      print
      print "  originSessionId: " sid
      print "  originSessionId_source: transcript"
      inmeta = 0; done = 1; next
    }
    inmeta && !/^[[:space:]]/ {            # metadata block ended with no type:
      if (!done) { print "  originSessionId: " sid; print "  originSessionId_source: transcript"; done = 1 }
      inmeta = 0
    }
    { print }
    END { }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---------------------------------------------------------------------------
# Build memory-path -> earliest writing session, once, for every store.
# ---------------------------------------------------------------------------
# Two greps rather than one: the first narrows hundreds of megabytes of
# transcript to the lines mentioning a memory path, the second keeps only the
# tool calls. Doing it in that order is what keeps the whole corpus at ~7s.
build_evidence() {
  find "$PROJECTS" -path '*/memory/*.md' -type f 2>/dev/null \
    | awk -F/ '{ print $NF "\t" $0 }' > "$TMP/corpus"

  : > "$TMP/hits"
  find "$PROJECTS" -name '*.jsonl' -type f -print0 2>/dev/null \
    | xargs -0 grep -H '/memory' 2>/dev/null \
    | grep -E '"name":"(Write|Edit|MultiEdit|Bash)"' > "$TMP/hits" 2>/dev/null || true

  # The transcript filename IS the sessionId, so the -H prefix carries the
  # author and the line body carries the timestamp and the target.
  awk -v corpusfile="$TMP/corpus" '
    BEGIN { FS = "\t" }

    FILENAME == corpusfile {
      if ($1 == "MEMORY.md" || $1 == "ARCHIVE.md" || $1 == "MEMORY_ARCHIVE.md") next
      live[$2] = 1; nbase[$1]++; bpath[$1] = $2
      next
    }

    {
      i = index($0, ":{"); if (i == 0) next
      sid = substr($0, 1, i - 1); sub(/.*\//, "", sid); sub(/\.jsonl$/, "", sid)
      rest = substr($0, i + 1)
      ts = ""
      if (match(rest, /"timestamp":"[^"]*"/)) ts = substr(rest, RSTART + 13, RLENGTH - 14)
      if (ts == "") next

      # shape 1 — Write/Edit/MultiEdit record an absolute file_path.
      if (rest ~ /"name":"(Write|Edit|MultiEdit)"/) {
        s = rest
        while (match(s, /"file_path":"[^"]*\/memory\/[^"]*"/)) {
          claim(substr(s, RSTART + 13, RLENGTH - 14), ts, sid)
          s = substr(s, RSTART + RLENGTH)
        }
      }

      # shape 2 — a Bash redirect. There is no file_path key; the target is
      # usually built from a shell variable, so only the basename survives.
      if (rest ~ /"name":"Bash"/) {
        c = rest
        gsub(/\\"/, " ", c); gsub(/"/, " ", c); gsub(/\\n/, " ", c)
        # `->` in prose is not a redirect. Left in, it invents a writer for any
        # memory whose name follows an arrow in another memory body.
        gsub(/-+>/, " ", c); gsub(/=>/, " ", c)
        gsub(/>/, " > ", c)
        n = split(c, tok, /[ \t]+/)
        for (k = 1; k < n; k++) {
          if (tok[k] != ">" && tok[k] != "tee") continue
          j = k + 1
          while (j <= n && (tok[j] == ">" || tok[j] == "-a")) j++
          if (j <= n && tok[j] ~ /\/[^\/]*\.md$/) claim(tok[j], ts, sid)
        }
      }
    }

    function claim(target, ts, sid,   base, path) {
      base = target; sub(/.*\//, "", base)
      if (base == "MEMORY.md" || base == "ARCHIVE.md" || base == "MEMORY_ARCHIVE.md") return
      if (substr(target, 1, 1) == "/") {
        # An absolute path is exact evidence. One that no longer exists is a
        # memory this corpus has since moved or deleted: counted, never remapped
        # onto a same-named file, which would attribute one memory to the writer
        # of another.
        if (!(target in live)) { stale[target] = 1; return }
        path = target
      } else {
        # `$M/name.md` — the variable is unresolvable from here, so fall back to
        # the basename, and only when exactly one memory can be meant. Zero or
        # more than one: dropped, never guessed. Same rule as the wiki-links.
        if (nbase[base] != 1) return
        path = bpath[base]
      }
      if (!(path in first) || ts < first[path]) { first[path] = ts; who[path] = sid }
    }

    END {
      for (p in first) printf "%s\t%s\t%s\n", p, who[p], first[p]
      n = 0; for (t in stale) n++
      printf "#stale\t%d\n", n
    }
  ' "$TMP/corpus" "$TMP/hits" > "$TMP/origins.raw"

  STALE=$(sed -n 's/^#stale	//p' "$TMP/origins.raw")
  grep -v '^#stale	' "$TMP/origins.raw" > "$TMP/origins" || true
}

[ "$PROVENANCE" -eq 1 ] && build_evidence

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

  # --- repair 4: originSessionId, from the transcript evidence ---------------
  if [ "$PROVENANCE" -eq 1 ]; then
    N_SCAN=0; N_HAVE=0; N_GOT=0; N_ANON=0; N_INDEX=0
    : > "$TMP/report"
    for f in "$dir"/*.md; do
      b=$(basename "$f")
      # The index files are appended by every session that ever added a line to
      # them, so "the session that wrote this" is not a question they answer.
      case "$b" in
        MEMORY.md|ARCHIVE.md|MEMORY_ARCHIVE.md) N_INDEX=$((N_INDEX+1)); continue ;;
      esac
      N_SCAN=$((N_SCAN+1))
      if sed -n '1,25p' "$f" | grep -q '^[[:space:]]*originSessionId:'; then
        N_HAVE=$((N_HAVE+1)); continue
      fi
      sid=$(awk -F'\t' -v p="$f" '$1 == p { print $2; exit }' "$TMP/origins")
      if [ -z "$sid" ]; then
        N_ANON=$((N_ANON+1))
        [ "$N_ANON" -le 8 ] && echo "  still ANON  ${b%.md}  (no transcript records writing it)" >> "$TMP/report"
        continue
      fi
      N_GOT=$((N_GOT+1))
      [ "$N_GOT" -le 8 ] && echo "  origin  ${b%.md}  <- ${sid%%-*}" >> "$TMP/report"
      [ "$APPLY" -eq 1 ] && insert_origin "$f" "$sid"
    done

    TOTAL_SCAN=$((TOTAL_SCAN + N_SCAN)); TOTAL_HAVE=$((TOTAL_HAVE + N_HAVE))
    TOTAL_GOT=$((TOTAL_GOT + N_GOT));   TOTAL_ANON=$((TOTAL_ANON + N_ANON))
    TOTAL_INDEX=$((TOTAL_INDEX + N_INDEX)); TOTAL_FIXES=$((TOTAL_FIXES + N_GOT))

    echo "$slug"
    printf '  scanned %s   already stamped %s   origin recovered %s   still ANON %s\n' \
      "$N_SCAN" "$N_HAVE" "$N_GOT" "$N_ANON"
    [ "$N_INDEX" -gt 0 ] && printf '  (%s index files excluded: no single session writes them)\n' "$N_INDEX"
    [ -s "$TMP/report" ] && head -16 "$TMP/report"
    continue
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
if [ "$PROVENANCE" -eq 1 ]; then
  # The denominator prints unconditionally, including on a run that recovers
  # nothing. "origin recovered 91" on its own reads as a finished job; only
  # "91 recovered, 21 still ANON, out of 332 scanned" says how much is still
  # unanswered — and the ANON count is the number that decides whether to
  # trust the store's provenance.
  printf 'scanned %s   already stamped %s   origin recovered %s   still ANON %s\n' \
    "$TOTAL_SCAN" "$TOTAL_HAVE" "$TOTAL_GOT" "$TOTAL_ANON"
  [ "$TOTAL_INDEX" -gt 0 ] && printf '%s index files excluded from the scan.\n' "$TOTAL_INDEX"
  [ "${STALE:-0}" -gt 0 ] && printf '%s memory paths were written in the transcripts but no longer exist here (moved or deleted stores) — evidence dropped, never remapped onto a same-named file.\n' "$STALE"
  if [ "$TOTAL_ANON" -gt 0 ]; then
    printf 'The %s ANON have no write recorded anywhere; nothing here can attribute them.\n' "$TOTAL_ANON"
  fi
  if [ "$TOTAL_GOT" -eq 0 ]; then
    echo "nothing to recover"
    exit 0
  fi
  if [ "$APPLY" -eq 1 ]; then
    echo "stamped $TOTAL_GOT origins, each tagged originSessionId_source: transcript"
  else
    echo "$TOTAL_GOT origins recoverable — rerun with --apply"
  fi
  exit 1
fi
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
