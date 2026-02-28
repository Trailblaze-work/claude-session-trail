# claude-session-trail

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that captures full session transcripts on a dedicated git branch (`claude-sessions`) for replay and analysis.

Part of [Trailblaze](https://trailblaze.work) — tools for AI-assisted development visibility.

## What it does

Every time Claude finishes responding, `session-trail` snapshots the full session transcript — with secrets redacted — and commits it to a `claude-sessions` branch using git plumbing. No working tree disruption, no index conflicts, works during rebases and merges.

When the session ends, it pushes the branch to origin so team members can access session data.

## Install

```bash
claude plugin install github:Trailblaze-work/claude-session-trail
```

Or clone manually and enable:

```bash
git clone https://github.com/Trailblaze-work/claude-session-trail.git
cd claude-session-trail
claude plugin enable .
```

## What gets captured

The full raw JSONL transcript with **only secret redaction** applied:

- User prompts and assistant responses
- Tool invocations with complete inputs and outputs
- Progress events and timing data
- Thinking blocks
- Model, token usage, and conversation threading
- Base64 images (user screenshots)

### What gets redacted

Secrets matching common credential patterns are replaced with `[REDACTED_*]` markers:

- API keys (Anthropic, OpenAI, AWS, GitHub)
- Bearer tokens
- Generic long secrets (64+ character hex/base64 strings)
- Key-value patterns (`api_key=...`, `password=...`, etc.)

## Branch structure

```
refs/heads/claude-sessions
└── sessions/
    ├── <session-id>.jsonl.gz      # redacted + gzip compressed transcript
    └── <session-id>.meta.json     # lightweight metadata sidecar
```

### Metadata sidecar

Each session gets a `.meta.json` for cheap indexing without decompressing transcripts:

```json
{
  "session_id": "003b94b5-...",
  "slug": "starry-hugging-otter",
  "started": "2026-02-27T17:54:24Z",
  "last_updated": "2026-02-27T21:57:00Z",
  "models": ["claude-opus-4-6"],
  "client_version": "2.1.62",
  "git_branch": "main",
  "user_turns": 28,
  "assistant_turns": 32,
  "commits": ["a1b2c3d", "e4f5g6h"],
  "tools_used": {"Bash": 15, "Edit": 8, "Read": 12},
  "compressed_size": 30124
}
```

## Browsing sessions

```bash
# List session commits
git log claude-sessions --oneline

# View session metadata
git show claude-sessions:sessions/<session-id>.meta.json

# Decompress and view transcript
git show claude-sessions:sessions/<session-id>.jsonl.gz | gunzip | head -20

# List all sessions
git ls-tree claude-sessions sessions/
```

## How it works

| Hook event | Action |
|-----------|--------|
| `Stop` (every Claude turn) | Redact secrets → gzip → commit to `claude-sessions` branch |
| `SessionEnd` | Same commit + push to origin |
| `SessionStart` | Configure fetch refspec for `claude-sessions` |

Commits use git plumbing (`hash-object`, `read-tree`, `write-tree`, `commit-tree`, `update-ref`) with a temporary index file — no checkout, no stashing, no worktree disruption.

Git's packfile compression handles deduplication automatically — each commit overwrites the same session file, and git stores only the delta internally.

## Privacy & security

- Secrets are redacted using pattern matching before storage
- Transcripts are stored in a separate branch, not in your main codebase
- The branch can be excluded from CI/CD pipelines
- Push only happens at session end (not per-turn)
- `.gitignore` your branch if you don't want it pushed: add `claude-sessions` to your remote's branch protection

## Typical sizes

| Raw transcript | After redaction + gzip |
|---------------|----------------------|
| 300-700 KB | 5-15 KB |
| 1.6 MB | ~30 KB |
| 60 MB | ~300 KB |

## Uninstall

```bash
claude plugin uninstall session-trail
```

To also remove the session data:

```bash
git branch -D claude-sessions
git push origin --delete claude-sessions
```

## Related

- [claude-prompt-trail](https://github.com/Trailblaze-work/claude-prompt-trail) — captures processed prompt summaries as git notes per commit

## License

MIT

---

<p align="center">
  <a href="https://trailblaze.work">
    <img src="https://raw.githubusercontent.com/Trailblaze-work/trailblaze.work/main/trailblaze-mark.svg" alt="Trailblaze" width="50" />
  </a>
</p>
<h3 align="center">Built by <a href="https://trailblaze.work">Trailblaze</a></h3>
<p align="center">
  We help companies deploy AI across their workforce.<br>
  Strategy, implementation, training, and governance.<br><br>
  <a href="mailto:hello@trailblaze.work"><strong>hello@trailblaze.work</strong></a>
</p>
