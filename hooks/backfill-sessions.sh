#!/usr/bin/env bash
set -euo pipefail

# Backfill existing local Claude Code session transcripts to the
# claude-sessions branch. Discovers transcripts for the current repo
# in ~/.claude/projects/<encoded-repo-path>/, deduplicates against
# sessions already on the branch, and commits the missing ones.
#
# Usage:
#   backfill-sessions.sh              — import missing sessions
#   backfill-sessions.sh --push       — import + push to origin
#   backfill-sessions.sh --force      — overwrite existing sessions

PUSH=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --push)  PUSH=true ;;
        --force) FORCE=true ;;
    esac
done

# Resolve git dir — exit if not in a git repo
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || { echo "Not a git repo." >&2; exit 1; }

# Determine repo root and encode it the same way Claude Code does
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Cannot determine repo root." >&2; exit 1; }
ENCODED_PATH=$(printf '%s' "$REPO_ROOT" | sed 's|/|-|g')

# Find the local transcript directory
CLAUDE_PROJECTS="${HOME}/.claude/projects"
TRANSCRIPT_DIR="${CLAUDE_PROJECTS}/${ENCODED_PATH}"

if [[ ! -d "$TRANSCRIPT_DIR" ]]; then
    echo "No local transcripts found at $TRANSCRIPT_DIR"
    exit 0
fi

# Collect .jsonl files, excluding subagent transcripts
TRANSCRIPTS=()
while IFS= read -r -d '' f; do
    TRANSCRIPTS+=("$f")
done < <(find "$TRANSCRIPT_DIR" -maxdepth 1 -name '*.jsonl' -print0 2>/dev/null)

if [[ ${#TRANSCRIPTS[@]} -eq 0 ]]; then
    echo "No transcripts found in $TRANSCRIPT_DIR"
    exit 0
fi

echo "Found ${#TRANSCRIPTS[@]} transcript(s) in $TRANSCRIPT_DIR"

# Delegate to Python for dedup + import
DO_PUSH="$PUSH" DO_FORCE="$FORCE" TRANSCRIPTS_JSON=$(printf '%s\n' "${TRANSCRIPTS[@]}" | python3 -c "import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))") \
python3 <<'PYTHON'
import gzip
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Secret redaction (same patterns as capture-session.sh)
# ---------------------------------------------------------------------------

SECRET_PATTERNS = [
    (re.compile(r"sk-ant-api\d{2}-[A-Za-z0-9_-]{86}-[A-Za-z0-9_-]{6}AA"), "[REDACTED_ANTHROPIC_KEY]"),
    (re.compile(r"sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}"), "[REDACTED_OPENAI_KEY]"),
    (re.compile(r"sk-proj-[A-Za-z0-9_-]{40,}"), "[REDACTED_OPENAI_KEY]"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED_AWS_KEY]"),
    (re.compile(r"(?<=[:= '\"])[A-Za-z0-9/+=]{40}(?=[ '\"\n])"), "[REDACTED_AWS_SECRET]"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9_]{36,}"), "[REDACTED_GITHUB_TOKEN]"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{22}_[A-Za-z0-9_]{59}"), "[REDACTED_GITHUB_TOKEN]"),
    (re.compile(r"(?<![A-Za-z0-9/])[A-Za-z0-9/+=_-]{64,}(?![A-Za-z0-9/])"), "[REDACTED_LONG_SECRET]"),
    (re.compile(r"Bearer\s+[A-Za-z0-9._~+/=-]{20,}"), "Bearer [REDACTED_TOKEN]"),
    (re.compile(r"(?i)(api[_-]?key|secret[_-]?key|auth[_-]?token|password|access[_-]?token|private[_-]?key)\s*[=:]\s*['\"]?[^\s'\"]{8,}"), r"\1=[REDACTED]"),
]


def redact_secrets(text):
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


# ---------------------------------------------------------------------------
# Transcript processing (same as capture-session.sh)
# ---------------------------------------------------------------------------

def process_transcript(path):
    lines = []
    with open(path, "r", errors="replace") as f:
        for line in f:
            stripped = line.rstrip("\n")
            if stripped:
                lines.append(redact_secrets(stripped))
    content = "\n".join(lines) + "\n"
    return gzip.compress(content.encode("utf-8"), compresslevel=6)


def build_metadata(path, session_id):
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

            elif rec_type == "toolUseResult":
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
# Git plumbing (same as capture-session.sh)
# ---------------------------------------------------------------------------

def git(*args, input_data=None):
    result = subprocess.run(
        ["git"] + list(args),
        capture_output=True,
        input=input_data,
        timeout=30,
    )
    return result.returncode, result.stdout, result.stderr


def commit_to_sessions_branch(session_id, gzipped_bytes, meta_json):
    rc, git_dir_bytes, _ = git("rev-parse", "--git-dir")
    if rc != 0:
        return False
    git_dir = git_dir_bytes.decode().strip()
    tmp_index = os.path.join(git_dir, "claude-sessions-index")

    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = tmp_index

    max_retries = 3
    for attempt in range(max_retries):
        try:
            if os.path.exists(tmp_index):
                os.remove(tmp_index)

            rc, parent_bytes, _ = git("rev-parse", "--verify", "refs/heads/claude-sessions")
            parent = parent_bytes.decode().strip() if rc == 0 else None

            if parent:
                subprocess.run(
                    ["git", "read-tree", parent],
                    env=env, capture_output=True, timeout=10,
                )

            rc, blob_hash, _ = git("hash-object", "-w", "--stdin",
                                   input_data=gzipped_bytes)
            if rc != 0:
                return False
            blob_sha = blob_hash.decode().strip()

            subprocess.run(
                ["git", "update-index", "--add", "--cacheinfo",
                 f"100644,{blob_sha},sessions/{session_id}.jsonl.gz"],
                env=env, capture_output=True, timeout=10,
            )

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

            result = subprocess.run(
                ["git", "write-tree"],
                env=env, capture_output=True, timeout=10,
            )
            if result.returncode != 0:
                return False
            tree_sha = result.stdout.decode().strip()

            commit_args = ["git", "commit-tree", tree_sha, "-m",
                          f"Backfill session {session_id}"]
            if parent:
                commit_args.extend(["-p", parent])
            result = subprocess.run(
                commit_args,
                capture_output=True, timeout=10,
            )
            if result.returncode != 0:
                return False
            commit_sha = result.stdout.decode().strip()

            update_args = ["git", "update-ref", "refs/heads/claude-sessions", commit_sha]
            if parent:
                update_args.append(parent)
            result = subprocess.run(
                update_args,
                capture_output=True, timeout=10,
            )
            if result.returncode != 0:
                continue

            return True

        finally:
            if os.path.exists(tmp_index):
                try:
                    os.remove(tmp_index)
                except OSError:
                    pass

    return False


def push_sessions_branch():
    rc, _, _ = git("remote", "get-url", "origin")
    if rc != 0:
        return
    rc, _, stderr = git("push", "origin", "refs/heads/claude-sessions")
    if rc != 0 and b"non-fast-forward" in stderr:
        git("fetch", "origin", "refs/heads/claude-sessions:refs/heads/claude-sessions")
        git("push", "origin", "refs/heads/claude-sessions")


# ---------------------------------------------------------------------------
# Main: discover, deduplicate, import
# ---------------------------------------------------------------------------

def get_existing_session_ids():
    """Get set of session IDs already on the claude-sessions branch."""
    rc, _, _ = git("rev-parse", "--verify", "refs/heads/claude-sessions")
    if rc != 0:
        return set()
    rc, tree_output, _ = git("ls-tree", "claude-sessions", "sessions/")
    if rc != 0:
        return set()
    ids = set()
    for line in tree_output.decode().splitlines():
        # format: <mode> <type> <hash>\t<path>
        parts = line.split("\t", 1)
        if len(parts) == 2:
            filename = parts[1].split("/")[-1]
            if filename.endswith(".jsonl.gz"):
                ids.add(filename[:-len(".jsonl.gz")])
    return ids


def main():
    transcripts = json.loads(os.environ.get("TRANSCRIPTS_JSON", "[]"))
    do_push = os.environ.get("DO_PUSH", "false") == "true"
    do_force = os.environ.get("DO_FORCE", "false") == "true"

    if not transcripts:
        return

    existing_ids = get_existing_session_ids()
    imported = 0
    skipped = 0
    failed = 0

    for path in transcripts:
        filename = os.path.basename(path)
        if not filename.endswith(".jsonl"):
            continue
        session_id = filename[:-len(".jsonl")]

        if session_id in existing_ids and not do_force:
            skipped += 1
            continue

        try:
            gzipped = process_transcript(path)
            meta = build_metadata(path, session_id)
            meta["compressed_size"] = len(gzipped)

            if commit_to_sessions_branch(session_id, gzipped, meta):
                imported += 1
                # Update existing_ids so subsequent dedup checks work
                existing_ids.add(session_id)
            else:
                failed += 1
                print(f"  Failed to commit session {session_id}", file=sys.stderr)
        except Exception as e:
            failed += 1
            print(f"  Error processing {session_id}: {e}", file=sys.stderr)

    print(f"Imported {imported} session(s), skipped {skipped} already present", end="")
    if failed:
        print(f", {failed} failed", end="")
    print()

    if do_push and imported > 0:
        push_sessions_branch()
        print("Pushed claude-sessions branch to origin")


if __name__ == "__main__":
    main()
PYTHON
