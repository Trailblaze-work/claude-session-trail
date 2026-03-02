---
name: backfill
description: Import existing local Claude session transcripts to the claude-sessions git branch
allowed-tools: Bash, AskUserQuestion
user-invocable: true
---

Run the backfill script to import existing session transcripts for this repository:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/backfill-sessions.sh"
```

Report the results to the user.

If any new sessions were imported (i.e. not all were "already present"), ask the user whether they want to push the claude-sessions branch to origin. If they say yes, run:

```bash
git push origin claude-sessions
```
