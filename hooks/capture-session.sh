#!/usr/bin/env bash
set -euo pipefail

# Stop / SessionEnd hook: captures the full Claude Code session transcript,
# applies secret redaction, gzip compresses, and commits to the
# refs/heads/claude-sessions branch using git plumbing (no worktree disruption).
#
# Usage:
#   capture-session.sh          — commit locally (Stop hook)
#   capture-session.sh --push   — commit + push to origin (SessionEnd hook)

PUSH=false
for arg in "$@"; do
    [[ "$arg" == "--push" ]] && PUSH=true
done

# Read hook JSON from stdin
INPUT=$(cat)

# Extract transcript_path and session_id
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || echo "")
SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || echo "")

# Fast exit if no transcript or session
[[ -z "$TRANSCRIPT_PATH" || -z "$SESSION_ID" || ! -f "$TRANSCRIPT_PATH" ]] && exit 0

# Resolve git dir
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0

# Early exit if transcript hasn't changed since last commit
MTIME_FILE="$GIT_DIR/session-trail-last-${SESSION_ID}"
CURRENT_MTIME=$(stat -c '%Y' "$TRANSCRIPT_PATH" 2>/dev/null || stat -f '%m' "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
if [[ -f "$MTIME_FILE" ]]; then
    LAST_MTIME=$(cat "$MTIME_FILE")
    if [[ "$CURRENT_MTIME" == "$LAST_MTIME" ]]; then
        # Transcript unchanged — still push on SessionEnd if branch exists
        if [[ "$PUSH" == "true" ]] && git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
            if git remote get-url origin >/dev/null 2>&1; then
                git push origin refs/heads/claude-sessions 2>/dev/null || true
            fi
        fi
        exit 0
    fi
fi

# Delegate processing and git plumbing to Python
HOOK_INPUT="$INPUT" DO_PUSH="$PUSH" python3 <<'PYTHON'
import gzip
import json
import os
import re
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------------------
# Secret redaction (self-contained copy from prompt-trail)
# ---------------------------------------------------------------------------

SECRET_PATTERNS = [
    # Anthropic API keys
    (re.compile(r"sk-ant-api\d{2}-[A-Za-z0-9_-]{86}-[A-Za-z0-9_-]{6}AA"), "[REDACTED_ANTHROPIC_KEY]"),
    # OpenAI API keys
    (re.compile(r"sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}"), "[REDACTED_OPENAI_KEY]"),
    (re.compile(r"sk-proj-[A-Za-z0-9_-]{40,}"), "[REDACTED_OPENAI_KEY]"),
    # AWS access keys
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED_AWS_KEY]"),
    # AWS secret keys (40 char base64-ish after common prefixes)
    (re.compile(r"(?<=[:= '\"])[A-Za-z0-9/+=]{40}(?=[ '\"\n])"), "[REDACTED_AWS_SECRET]"),
    # GitHub tokens
    (re.compile(r"gh[pousr]_[A-Za-z0-9_]{36,}"), "[REDACTED_GITHUB_TOKEN]"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{22}_[A-Za-z0-9_]{59}"), "[REDACTED_GITHUB_TOKEN]"),
    # Generic long hex/base64 strings that look like secrets (64+ chars)
    (re.compile(r"(?<![A-Za-z0-9/])[A-Za-z0-9/+=_-]{64,}(?![A-Za-z0-9/])"), "[REDACTED_LONG_SECRET]"),
    # Bearer tokens
    (re.compile(r"Bearer\s+[A-Za-z0-9._~+/=-]{20,}"), "Bearer [REDACTED_TOKEN]"),
    # Generic "secret/key/token/password = value" patterns
    (re.compile(r"(?i)(api[_-]?key|secret[_-]?key|auth[_-]?token|password|access[_-]?token|private[_-]?key)\s*[=:]\s*['\"]?[^\s'\"]{8,}"), r"\1=[REDACTED]"),
]


def redact_secrets(text):
    """Replace likely secrets/credentials with redaction markers."""
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


# ---------------------------------------------------------------------------
# Transcript processing
# ---------------------------------------------------------------------------

def process_transcript(path):
    """Read raw JSONL transcript, apply secret redaction line-by-line, gzip compress."""
    lines = []
    with open(path, "r", errors="replace") as f:
        for line in f:
            stripped = line.rstrip("\n")
            if stripped:
                lines.append(redact_secrets(stripped))
    content = "\n".join(lines) + "\n"
    return gzip.compress(content.encode("utf-8"), compresslevel=6)


def build_metadata(path, session_id):
    """Extract session metadata for .meta.json by scanning transcript records."""
    meta = {
        "session_id": session_id,
        "slug": "",
        "started": "",
        "last_updated": "",
        "models": [],
        "client_version": "",
        "git_branch": "",
        "user_turns": 0,
        "assistant_turns": 0,
        "commits": [],
        "tools_used": {},
        "compressed_size": 0,
    }
    models_set = set()
    commits_set = set()
    first_ts = ""
    last_ts = ""

    with open(path, "r", errors="replace") as f:
        for line in f:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                record = json.loads(stripped)
            except json.JSONDecodeError:
                continue

            rec_type = record.get("type", "")
            ts = record.get("timestamp", "")
            if ts:
                if not first_ts:
                    first_ts = ts
                last_ts = ts

            if rec_type == "user":
                meta["user_turns"] += 1
                if not meta["slug"]:
                    meta["slug"] = record.get("slug", "")
                if not meta["client_version"]:
                    meta["client_version"] = record.get("version", "")
                if not meta["git_branch"]:
                    meta["git_branch"] = record.get("gitBranch", "")

            elif rec_type == "assistant":
                meta["assistant_turns"] += 1
                msg = record.get("message", {})
                model = msg.get("model", "")
                if model and model not in models_set:
                    meta["models"].append(model)
                    models_set.add(model)
                content = msg.get("content", [])
                if isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get("type") == "tool_use":
                            tool_name = part.get("name", "")
                            if tool_name:
                                meta["tools_used"][tool_name] = meta["tools_used"].get(tool_name, 0) + 1
                            # Detect git commits
                            if tool_name == "Bash":
                                cmd = part.get("input", {}).get("command", "")
                                if "git commit" in cmd:
                                    # We'll try to get the hash from toolUseResult later
                                    pass

            elif rec_type == "toolUseResult":
                # Try to extract commit hashes from tool responses
                result_text = record.get("result", "")
                if isinstance(result_text, list):
                    result_text = " ".join(
                        p.get("text", "") for p in result_text if isinstance(p, dict)
                    )
                if isinstance(result_text, str) and "git commit" not in result_text:
                    match = re.search(r"\[[\w/.-]+ ([a-f0-9]{7,})\]", result_text)
                    if match:
                        commits_set.add(match.group(1))

    meta["started"] = first_ts
    meta["last_updated"] = last_ts
    meta["commits"] = sorted(commits_set)
    return meta


# ---------------------------------------------------------------------------
# Git plumbing: commit to claude-sessions branch without touching worktree
# ---------------------------------------------------------------------------

def git(*args, input_data=None):
    """Run a git command, return (returncode, stdout, stderr)."""
    result = subprocess.run(
        ["git"] + list(args),
        capture_output=True,
        input=input_data,
        timeout=30,
    )
    return result.returncode, result.stdout, result.stderr


def commit_to_sessions_branch(session_id, gzipped_bytes, meta_json):
    """Commit session files to refs/heads/claude-sessions using git plumbing."""
    rc, git_dir_bytes, _ = git("rev-parse", "--git-dir")
    if rc != 0:
        return False
    git_dir = git_dir_bytes.decode().strip()
    tmp_index = os.path.join(git_dir, "claude-sessions-index")

    # Use a temporary index so we don't touch the main index
    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = tmp_index

    max_retries = 3
    for attempt in range(max_retries):
        try:
            # Clean up stale tmp index
            if os.path.exists(tmp_index):
                os.remove(tmp_index)

            # Get current branch tip (if it exists)
            rc, parent_bytes, _ = git("rev-parse", "--verify", "refs/heads/claude-sessions")
            parent = parent_bytes.decode().strip() if rc == 0 else None

            # Read existing tree into temp index
            if parent:
                subprocess.run(
                    ["git", "read-tree", parent],
                    env=env, capture_output=True, timeout=10,
                )

            # Add gzipped transcript as blob
            rc, blob_hash, _ = git("hash-object", "-w", "--stdin",
                                   input_data=gzipped_bytes)
            if rc != 0:
                return False
            blob_sha = blob_hash.decode().strip()

            # Add to temp index
            subprocess.run(
                ["git", "update-index", "--add", "--cacheinfo",
                 f"100644,{blob_sha},sessions/{session_id}.jsonl.gz"],
                env=env, capture_output=True, timeout=10,
            )

            # Add metadata sidecar as blob
            meta_bytes = json.dumps(meta_json, indent=2).encode("utf-8")
            rc, meta_blob_hash, _ = git("hash-object", "-w", "--stdin",
                                        input_data=meta_bytes)
            if rc != 0:
                return False
            meta_blob_sha = meta_blob_hash.decode().strip()

            subprocess.run(
                ["git", "update-index", "--add", "--cacheinfo",
                 f"100644,{meta_blob_sha},sessions/{session_id}.meta.json"],
                env=env, capture_output=True, timeout=10,
            )

            # Write tree from temp index
            result = subprocess.run(
                ["git", "write-tree"],
                env=env, capture_output=True, timeout=10,
            )
            if result.returncode != 0:
                return False
            tree_sha = result.stdout.decode().strip()

            # Create commit
            commit_args = ["git", "commit-tree", tree_sha, "-m",
                          f"Update session {session_id}"]
            if parent:
                commit_args.extend(["-p", parent])
            result = subprocess.run(
                commit_args,
                capture_output=True, timeout=10,
            )
            if result.returncode != 0:
                return False
            commit_sha = result.stdout.decode().strip()

            # Update ref with CAS (compare-and-swap)
            update_args = ["git", "update-ref", "refs/heads/claude-sessions", commit_sha]
            if parent:
                update_args.append(parent)
            result = subprocess.run(
                update_args,
                capture_output=True, timeout=10,
            )
            if result.returncode != 0:
                # CAS failed — race condition, retry with fresh parent
                continue

            return True

        finally:
            # Always clean up temp index
            if os.path.exists(tmp_index):
                try:
                    os.remove(tmp_index)
                except OSError:
                    pass

    return False


def ensure_fetch_refspec():
    """Add fetch refspec for claude-sessions if not already configured."""
    fetch_ref = "+refs/heads/claude-sessions:refs/heads/claude-sessions"
    rc, out, _ = git("config", "--local", "--get-all", "remote.origin.fetch")
    if rc == 0 and fetch_ref.encode() in out:
        return
    git("config", "--add", "--local", "remote.origin.fetch", fetch_ref)


def push_sessions_branch():
    """Push claude-sessions branch to origin (best-effort)."""
    # Check if origin exists
    rc, _, _ = git("remote", "get-url", "origin")
    if rc != 0:
        return

    # Try push, fetch + retry on non-fast-forward
    rc, _, stderr = git("push", "origin", "refs/heads/claude-sessions")
    if rc != 0 and b"non-fast-forward" in stderr:
        git("fetch", "origin", "refs/heads/claude-sessions:refs/heads/claude-sessions")
        rc, _, _ = git("push", "origin", "refs/heads/claude-sessions")

    # After a successful push, ensure the fetch refspec is configured so
    # `git pull` also fetches the claude-sessions branch
    if rc == 0:
        ensure_fetch_refspec()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    try:
        hook_data = json.loads(os.environ.get("HOOK_INPUT", "{}"))
    except json.JSONDecodeError:
        return

    transcript_path = hook_data.get("transcript_path", "")
    session_id = hook_data.get("session_id", "")
    do_push = os.environ.get("DO_PUSH", "false") == "true"

    if not transcript_path or not session_id or not os.path.isfile(transcript_path):
        return

    # Process transcript: redact secrets, gzip compress
    gzipped = process_transcript(transcript_path)

    # Build metadata
    meta = build_metadata(transcript_path, session_id)
    meta["compressed_size"] = len(gzipped)

    # Commit to claude-sessions branch
    if not commit_to_sessions_branch(session_id, gzipped, meta):
        return

    # Record mtime so we can skip no-op commits next time
    rc, git_dir_bytes, _ = git("rev-parse", "--git-dir")
    if rc == 0:
        git_dir = git_dir_bytes.decode().strip()
        try:
            mtime = str(os.path.getmtime(transcript_path))
            # Use stat -f '%m' format to match bash side
            import platform
            if platform.system() == "Darwin":
                result = subprocess.run(
                    ["stat", "-f", "%m", transcript_path],
                    capture_output=True, text=True, timeout=5,
                )
            else:
                result = subprocess.run(
                    ["stat", "-c", "%Y", transcript_path],
                    capture_output=True, text=True, timeout=5,
                )
            if result.returncode == 0:
                mtime = result.stdout.strip()
            mtime_file = os.path.join(git_dir, f"session-trail-last-{session_id}")
            with open(mtime_file, "w") as f:
                f.write(mtime)
        except Exception:
            pass

    # Push on SessionEnd
    if do_push:
        push_sessions_branch()


if __name__ == "__main__":
    main()
PYTHON
