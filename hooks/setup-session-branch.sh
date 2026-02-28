#!/usr/bin/env bash
set -euo pipefail

# SessionStart hook: idempotently adds a fetch refspec for refs/heads/claude-sessions
# so team members can pull session data. Does NOT add to notes.displayRef.

if git remote get-url origin >/dev/null 2>&1; then
    FETCH_REF="+refs/heads/claude-sessions:refs/heads/claude-sessions"
    if ! git config --local --get-all remote.origin.fetch 2>/dev/null | grep -qF "$FETCH_REF"; then
        git config --add --local remote.origin.fetch "$FETCH_REF"
    fi
fi

exit 0
