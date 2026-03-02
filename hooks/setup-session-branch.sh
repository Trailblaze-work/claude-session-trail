#!/usr/bin/env bash
set -euo pipefail

# SessionStart hook: idempotently adds a fetch refspec for refs/heads/claude-sessions
# so team members can pull session data — but only if the branch has been
# successfully pushed to the remote. Adding the refspec before the remote has
# the branch causes `git pull` / `git fetch` to fail with "couldn't find remote
# ref". The refspec is first added by capture-session.sh after a successful push;
# this hook re-adds it if the git config was reset (e.g., after a fresh clone).

if git remote get-url origin >/dev/null 2>&1; then
    FETCH_REF="+refs/heads/claude-sessions:refs/heads/claude-sessions"
    if ! git config --local --get-all remote.origin.fetch 2>/dev/null | grep -qF "$FETCH_REF"; then
        # Only add if the remote-tracking ref exists (implies a prior push or fetch succeeded)
        if git rev-parse --verify refs/remotes/origin/claude-sessions >/dev/null 2>&1; then
            git config --add --local remote.origin.fetch "$FETCH_REF"
        fi
    fi
fi

exit 0
