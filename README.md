# Claude Code Harness

Machine-level security, audit, and context hooks for Claude Code.
Install once per developer machine — works across all projects without touching repo files.

## Install

```bash
git clone https://github.com/aditya-samalla/claude-code-harness.git
cd claude-code-harness
bash install.sh
```

Then open Claude Code and run `/hooks` to confirm everything is registered.

## What it does

### Security (blocking)

| Hook | Event | Behaviour |
|---|---|---|
| `env-guard` | PreToolUse → Bash | Blocks commands that would print or transmit env variable values |
| `sensitive-file-guard` | PreToolUse → Read/Edit/Write | Blocks access to `.env`, `*.pem`, `*.key`, credential files |

These return a JSON `deny` decision — Claude sees the reason and cannot proceed.

### Audit (async, non-blocking)

| Hook | Event | Behaviour |
|---|---|---|
| `audit` | PostToolUse → Edit/Write | Logs every file Claude touches |
| `audit` | PostToolUseFailure | Logs failed tool calls with error summary |
| `audit` | ConfigChange | Logs any settings file modified mid-session |
| `audit` | Stop | Logs session turn count and cost on exit |

All entries go to `~/.claude/logs/audit.log`. Format: `timestamp | event | detail | cwd`.

### Context & continuity

| Hook | Event | Behaviour |
|---|---|---|
| `session-start` | SessionStart | Injects git branch, status, and last 5 commits into context automatically |
| `pre-compact` | PreCompact | Backs up the full session transcript before compaction. Keeps last 20. |
| `notify` | Notification | Desktop alert when Claude needs input (async) |

### Settings

| Setting | Value | Effect |
|---|---|---|
| `checkpointingEnabled` | `true` | Automatic git checkpoint before large changes — easy rollback |
| `includeCoAuthoredBy` | `true` | Adds `Co-authored-by: Claude` to commits. Set `false` to disable. |

## File layout after install

```
~/.claude/
  settings.json          ← global config (installed from this repo)
  hooks/
    env-guard.sh
    sensitive-file-guard.sh
    audit.sh
    notify.sh
    session-start.sh
    pre-compact.sh
  logs/
    audit.log            ← append-only audit trail
  transcripts/
    transcript_auto_20260415_143022.jsonl   ← pre-compaction backups
    ...
```

## Per-project additions (not in this harness)

Each repo manages its own:
- `CLAUDE.md` — PR format, reviewer names, workflow rules
- `.claude/settings.json` — project-specific deny rules, auto-formatter, test runner
- Slack notifications — via MCP connector, instructed through CLAUDE.md
