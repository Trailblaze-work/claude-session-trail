---
name: backfill
description: Import existing local Claude session transcripts to the claude-sessions git branch
allowed-tools: Bash
user-invocable: true
---

Run the backfill script to import existing session transcripts for this repository:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/backfill-sessions.sh"
```

Report the results to the user.
