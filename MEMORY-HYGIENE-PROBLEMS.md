# Memory system — measured problems, 2026-08-25

Evidence base for the remediation work. Every number here was measured, not
estimated. Main store is `~/.claude/projects/-Users-adityasamalla-repos/memory`
(218 memories); there are 8 stores totalling 289 memories.

## Problems

1. **The index exceeds its load limit and structurally cannot comply.**
   219 lines against a 200-line limit (second limit ~25,000 chars; currently
   23.5KB, under). 218 memories, one line each. Past either limit the tail is
   dropped silently at session start. Shortening hooks only relieves the
   CHARACTER limit — the LINE limit needs fewer entries.

2. **6% of wiki-links are broken** — 35 of 588 do not resolve to a file.

3. **Root cause of most of those: 64 of 218 memories have a hyphenated `name:`
   while the filename uses underscores.** `[[feedback-bash-allowlist-prefix-matching]]`
   never resolves to `feedback_bash_allowlist_prefix_matching.md`.

4. **`verify:` coverage is 6%** — 14 of 218. The other 204 cannot be checked
   mechanically at all.

5. **87 of 218 memories have no `metadata.modified` stamp**, so age falls back
   to file mtime, which moves whenever anything rewrites the file. "How long has
   this claim been wrong" becomes unanswerable.

6. **Index hooks drift from the memories they summarise.** Two confirmed, both
   with the SUMMARY lagging the BODY:
   - index line `3 PRs open (#1938 #1608 #29)` while the linked memory said
     "all MERGED 2026-08-25" — and that hook sits in the ACTIVE-WORK block, the
     most-read line in the file.
   - a memory `description` saying a PR was "still open and unreviewed" while
     line 33 of its own body said "MERGED".

7. **Long-lived memories decay into false claims.** One 56KB memory (94 very
   long lines) is ~63% a per-repo shipping ledger; two entries still read
   "IN PROGRESS: PR open" while the top of the same file records both merged.

8. **Staleness detection has a timing gap.** Unverified open-state claims are
   triaged only after 14 days, but PR-state claims rot in hours — one memory
   asserted PRs open that had merged the same day it was written.

9. **Cross-store fragmentation.** A memory about repo X lives in whichever store
   the session was launched from, so a store-scoped audit misses it.

## Measured NOT to be a problem

**Content duplication is ~zero.** Of 1,328 distinct bolded claims across the
corpus, only 6 appeared in more than one memory, and 5 of those were a single
pair (since deduplicated, −1,126 bytes). The corpus is genuinely non-redundant,
so **compaction cannot reclaim index lines**.

## Heuristics built and WITHDRAWN — do not re-propose without addressing why

- **"Retire settled memories with no lesson-shaped wording."** Flagged a memory
  recording a verified pipeline MISMATCH (a real bug) and one recording that a
  table is absent from the lakehouse so a conversion is blocked. Both are
  durable FACTS containing no lesson words. No wordlist separates a pure status
  record from a durable fact.
- **"Merge memories that are about the same ticket."** Grouped a 21-hour
  production crash-loop with a PR-landing table because both cited INS-581.
  Verbatim-claim overlap was 4 for the one real pair and 0 for all three
  others — content overlap separates them, ticket key does not.

Standing principle: deleting on a heuristic destroys knowledge silently, which
is strictly worse than staleness. The tool reports; a human decides.

## Better rule, derived during the audit

For completed work, **keep the technique and the mechanism facts, drop the
ledger** — a section-level rule, not a file-level one. File-level tests keep
failing because a single memory mixes disposable status with durable fact.

## Fixes already applied

- 4 memories corrected against live GitHub/Jira (INS-449, INS-431, INS-430/423,
  ANEP-5121 blocker cleared); 14 now carry `verify:` blocks; 23 claims verify
  mechanically.
- Index hook `3 PRs open` → `ALL MERGED 08-25`.
- `models-ci-optimization-ins499` description and `INS-552 = IN PROGRESS` line
  corrected — both tickets Done (INS-499 08-24, INS-552 08-25).
- `project_psp4340_...` now records Hongxuan's 2026-08-21 confirmation that the
  payload carries `INSTANCE_ID` and the fault is a deployment issue; the
  unanswered long-term-ownership question is flagged as the only thing left.
- 5 verbatim-duplicated lessons stripped from the INS-430/431 summary.

---

# Review findings and remediation, 2026-08-25

Fable reviewed the enumeration above. Its two sharpest points, both verified:

**Problem 6 is a normalization problem, not a detection one.** State lives in
three places — index hook, frontmatter `description`, body — so any volatile
claim drifts by construction. No mechanical check can fix that. Summaries must
become state-free retrieval cues, with volatile state in exactly one place next
to a `verify:` block. Then the drift class ceases to exist.

**Problem 1 was being measured against the wrong thing.** The limit was never
the harm; the ORDERING was. Truncation is tail-first and the index was in pure
append order, so it dropped the NEWEST entries. Measured live: 19 entries past
the cut, **5 of them `feedback_` memories** — the behaviour-shaping ones, which
are worthless unless loaded. Fixed first.

## Corrections to the numbers above

- **"35 broken wiki-links" was inflated.** 26 were mechanically repairable, 7
  were links to memories not yet written — which the memory format treats as a
  marker for something worth writing, not an error — and 1 was `[[:space:]]`, a
  POSIX character class quoted in a body and matching the wiki-link shape.
- **"87 missing `modified`" is now 88, and only 42 were safely fixable.** The
  other 46 have an mtime of today because tooling touched them, so mtime no
  longer carries information about when the CLAIM last changed.
- **13 memories across 4 stores have no `metadata:` block at all** — old-format
  files predating the convention. Not previously counted.
- **Cross-store fragmentation (#9) is latent, not active.** 5 worktree-slug
  project dirs exist but none has a `memory/` subdir, so nothing has been
  written into one yet.

## Rules learned while fixing

- **Never stamp a date you cannot source.** Backfilling `modified` with today
  fabricates recency and hides a memory from age-gated triage, which is worse
  than no stamp. When the true date is unrecoverable, leave it unstamped.
- **Snapshot mtimes before editing anything.** Otherwise pass 1 bumps 64 files
  and pass 3 records today for all of them — the age signal is destroyed
  corpus-wide in a single run. This nearly happened.
- **A finding queue with mixed meanings gets ignored.** `memory-fix` initially
  counted ambiguous links, missing `name:`, and missing `metadata:` in one
  counter, so 13 malformed memories were reported as "ambiguous links" and then
  masked entirely by a later guard. Same defect Fable flagged in
  `memory-verify`'s overloaded `SKIP`.
- **Repair the frontmatter, never rename the file.** 560 links already resolve
  against filenames; renaming to match `name:` would break the working majority
  to fix the broken few.

## Status

| phase | state |
|---|---|
| 0 · git-init the stores | DONE — 8 stores, 298 files baselined |
| 1 · tier-order the index | DONE — pure permutation, 0 feedback below the cut |
| 2 · `bin/memory-fix.sh` | DONE — 178 repairs on the main store, 45 tests |
| 3 · generate index from frontmatter | pending |
| 4 · liveness triage at age zero | pending |
| 5 · demote settled projects to ARCHIVE.md | pending |
| 6 · write-time lint hook | pending |

Evidence that phases 3 and 6 are both needed: a memory written by the live
system DURING this session arrived with no `modified:` stamp and a 176-char
index line appended blindly to the end of the file — past the truncation cut,
in the section reserved for a different type.
