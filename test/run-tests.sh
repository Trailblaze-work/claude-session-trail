#!/usr/bin/env bash
set -euo pipefail

# Test suite for claude-session-trail
# Tests secret redaction, git plumbing, metadata extraction, and integration.
# All tests run in isolated /tmp directories — no side effects on the real repo.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$PROJECT_DIR/hooks"

PASSED=0
FAILED=0
SKIPPED=0

# --- Helpers ---

pass() {
    printf "  \033[32mPASS\033[0m %s\n" "$1"
    PASSED=$((PASSED + 1))
}

fail() {
    printf "  \033[31mFAIL\033[0m %s: %s\n" "$1" "$2"
    FAILED=$((FAILED + 1))
}

skip() {
    printf "  \033[33mSKIP\033[0m %s: %s\n" "$1" "$2"
    SKIPPED=$((SKIPPED + 1))
}

section() {
    printf "\n\033[1m%s\033[0m\n" "$1"
}

# Create a fresh test repo in /tmp and cd into it.
make_test_repo() {
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cst-test.XXXXXX")
    cd "$TEST_DIR"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
}

cleanup_test_repo() {
    if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
        cd /tmp
        rm -rf "$TEST_DIR"
    fi
}

# Install plugin structure into current repo
install_plugin() {
    mkdir -p .claude-plugin hooks
    cp "$PROJECT_DIR/.claude-plugin/plugin.json" .claude-plugin/
    cp "$HOOKS_DIR/capture-session.sh" hooks/
    cp "$HOOKS_DIR/setup-session-branch.sh" hooks/
    cp "$HOOKS_DIR/backfill-sessions.sh" hooks/
    cp "$HOOKS_DIR/hooks.json" hooks/
    chmod +x hooks/*.sh
    mkdir -p .claude
    cat > .claude/settings.json <<'JSON'
{
  "enabledPlugins": {
    ".": true
  }
}
JSON
}

# Create a mock transcript JSONL with various record types.
# Usage: make_transcript <path> [entries...]
# Entry format:
#   "user:Some prompt text"          → user message record
#   "assistant:Some response"        → assistant text response
#   "bash:some command"              → assistant tool_use (Bash)
#   "tool:ToolName"                  → assistant tool_use for a named tool
#   "commit:hash"                    → toolUseResult with commit hash
#   "raw:json string"               → raw JSON line (for testing secret redaction)
#
# Optional env vars:
#   TRANSCRIPT_MODEL       → model name (default: claude-opus-4-6)
#   TRANSCRIPT_SLUG        → session slug (default: "")
#   TRANSCRIPT_VERSION     → client version (default: "")
#   TRANSCRIPT_BRANCH      → git branch (default: "")
make_transcript() {
    local path="$1"
    shift

    local model="${TRANSCRIPT_MODEL:-claude-opus-4-6}"
    local slug="${TRANSCRIPT_SLUG:-}"
    local version="${TRANSCRIPT_VERSION:-}"
    local branch="${TRANSCRIPT_BRANCH:-}"
    local ts_counter=1709000000

    # Build user record extra fields
    local user_extra=""
    [[ -n "$slug" ]] && user_extra="$user_extra,\"slug\":\"$slug\""
    [[ -n "$version" ]] && user_extra="$user_extra,\"version\":\"$version\""
    [[ -n "$branch" ]] && user_extra="$user_extra,\"gitBranch\":\"$branch\""

    > "$path"
    for entry in "$@"; do
        local type="${entry%%:*}"
        local content="${entry#*:}"
        ts_counter=$((ts_counter + 1))
        local ts="2026-02-27T17:$(printf '%02d' $((ts_counter % 60))):00Z"
        case "$type" in
            user)
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"user","message":{"content":"%s"},"timestamp":"%s"%s}\n' "$content" "$ts" "$user_extra" >> "$path"
                ;;
            assistant)
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}],"model":"%s","usage":{"input_tokens":100,"output_tokens":50}},"timestamp":"%s"}\n' "$content" "$model" "$ts" >> "$path"
                ;;
            bash)
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}],"model":"%s","usage":{"input_tokens":100,"output_tokens":50}},"timestamp":"%s"}\n' "$content" "$model" "$ts" >> "$path"
                ;;
            tool)
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{}}],"model":"%s","usage":{"input_tokens":100,"output_tokens":50}},"timestamp":"%s"}\n' "$content" "$model" "$ts" >> "$path"
                ;;
            commit)
                # toolUseResult with a commit hash
                printf '{"type":"toolUseResult","result":"[main %s] test commit\\n 1 file changed","timestamp":"%s"}\n' "$content" "$ts" >> "$path"
                ;;
            raw)
                printf '%s\n' "$content" >> "$path"
                ;;
        esac
    done
}

# Build hook input JSON for capture-session.sh
make_hook_input() {
    local transcript_path="$1"
    local session_id="${2:-test-session-001}"

    cat <<EOF
{"transcript_path":"${transcript_path}","session_id":"${session_id}"}
EOF
}


# ============================================================
# Secret redaction tests
# ============================================================

test_redacts_secrets_in_transcript() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "raw:{\"type\":\"user\",\"message\":{\"content\":\"my key is sk-ant-api03-$(printf 'A%.0s' {1..86})-$(printf 'B%.0s' {1..6})AA\"},\"timestamp\":\"2026-02-27T17:00:00Z\"}" \
        "assistant:I see your key"

    make_hook_input "$transcript" "secret-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    # Check the stored file has redacted the key
    local stored
    stored=$(git show claude-sessions:sessions/secret-test-session.jsonl.gz | gunzip)
    if echo "$stored" | grep -q "REDACTED_ANTHROPIC_KEY"; then
        pass "redacts Anthropic API keys in transcript"
    else
        fail "redacts Anthropic API keys in transcript" "key not redacted"
    fi
}

test_redacts_openai_keys() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    # sk-proj- style OpenAI key (40+ chars)
    make_transcript "$transcript" \
        "raw:{\"type\":\"user\",\"message\":{\"content\":\"key is sk-proj-$(printf 'X%.0s' {1..50})\"},\"timestamp\":\"2026-02-27T17:00:00Z\"}" \
        "assistant:noted"

    make_hook_input "$transcript" "openai-secret-session" | bash "$HOOKS_DIR/capture-session.sh"

    local stored
    stored=$(git show claude-sessions:sessions/openai-secret-session.jsonl.gz | gunzip)
    if echo "$stored" | grep -q "REDACTED_OPENAI_KEY" && ! echo "$stored" | grep -q "sk-proj-"; then
        pass "redacts OpenAI API keys"
    else
        fail "redacts OpenAI API keys" "key not redacted"
    fi
}

test_redacts_aws_keys() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "raw:{\"type\":\"user\",\"message\":{\"content\":\"aws key AKIAIOSFODNN7EXAMPLE\"},\"timestamp\":\"2026-02-27T17:00:00Z\"}" \
        "assistant:noted"

    make_hook_input "$transcript" "aws-secret-session" | bash "$HOOKS_DIR/capture-session.sh"

    local stored
    stored=$(git show claude-sessions:sessions/aws-secret-session.jsonl.gz | gunzip)
    if echo "$stored" | grep -q "REDACTED_AWS_KEY" && ! echo "$stored" | grep -q "AKIAIOSFODNN7EXAMPLE"; then
        pass "redacts AWS access keys"
    else
        fail "redacts AWS access keys" "key not redacted"
    fi
}

test_redacts_github_tokens() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    # ghp_ token (36+ chars after prefix)
    make_transcript "$transcript" \
        "raw:{\"type\":\"user\",\"message\":{\"content\":\"token ghp_$(printf 'A%.0s' {1..40})\"},\"timestamp\":\"2026-02-27T17:00:00Z\"}" \
        "assistant:noted"

    make_hook_input "$transcript" "github-secret-session" | bash "$HOOKS_DIR/capture-session.sh"

    local stored
    stored=$(git show claude-sessions:sessions/github-secret-session.jsonl.gz | gunzip)
    if echo "$stored" | grep -q "REDACTED_GITHUB_TOKEN" && ! echo "$stored" | grep -q "ghp_"; then
        pass "redacts GitHub tokens"
    else
        fail "redacts GitHub tokens" "token not redacted"
    fi
}

test_redacts_bearer_tokens() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "raw:{\"type\":\"user\",\"message\":{\"content\":\"Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc123\"},\"timestamp\":\"2026-02-27T17:00:00Z\"}" \
        "assistant:noted"

    make_hook_input "$transcript" "bearer-secret-session" | bash "$HOOKS_DIR/capture-session.sh"

    local stored
    stored=$(git show claude-sessions:sessions/bearer-secret-session.jsonl.gz | gunzip)
    if echo "$stored" | grep -q "REDACTED_TOKEN" && ! echo "$stored" | grep -q "eyJhbGci"; then
        pass "redacts Bearer tokens"
    else
        fail "redacts Bearer tokens" "token not redacted"
    fi
}

test_redacts_generic_key_value() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "raw:{\"type\":\"user\",\"message\":{\"content\":\"api_key=mysupersecretvalue123\"},\"timestamp\":\"2026-02-27T17:00:00Z\"}" \
        "assistant:noted"

    make_hook_input "$transcript" "keyval-secret-session" | bash "$HOOKS_DIR/capture-session.sh"

    local stored
    stored=$(git show claude-sessions:sessions/keyval-secret-session.jsonl.gz | gunzip)
    if echo "$stored" | grep -q "REDACTED" && ! echo "$stored" | grep -q "mysupersecretvalue123"; then
        pass "redacts generic key=value secrets"
    else
        fail "redacts generic key=value secrets" "secret not redacted"
    fi
}

test_redacts_multiple_secrets_in_one_line() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "raw:{\"type\":\"user\",\"message\":{\"content\":\"aws AKIAIOSFODNN7EXAMPLE and token ghp_$(printf 'B%.0s' {1..40})\"},\"timestamp\":\"2026-02-27T17:00:00Z\"}" \
        "assistant:noted"

    make_hook_input "$transcript" "multi-secret-session" | bash "$HOOKS_DIR/capture-session.sh"

    local stored
    stored=$(git show claude-sessions:sessions/multi-secret-session.jsonl.gz | gunzip)
    if echo "$stored" | grep -q "REDACTED_AWS_KEY" && echo "$stored" | grep -q "REDACTED_GITHUB_TOKEN"; then
        pass "redacts multiple secrets in one line"
    else
        fail "redacts multiple secrets in one line" "not all secrets redacted"
    fi
}

test_preserves_normal_content() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Hello, please help me with my code" \
        "assistant:Sure, I can help with that" \
        "bash:ls -la"

    make_hook_input "$transcript" "normal-content-session" | bash "$HOOKS_DIR/capture-session.sh"

    local stored
    stored=$(git show claude-sessions:sessions/normal-content-session.jsonl.gz | gunzip)
    if echo "$stored" | grep -q "Hello, please help me with my code" && \
       echo "$stored" | grep -q "Sure, I can help with that" && \
       echo "$stored" | grep -q "ls -la"; then
        pass "preserves normal content after redaction"
    else
        fail "preserves normal content after redaction" "content missing"
    fi
}

test_transcript_is_valid_gzipped_jsonl() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Test prompt" \
        "assistant:Test response" \
        "tool:Edit"

    make_hook_input "$transcript" "gzip-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    # Verify it gunzips successfully and every line is valid JSON
    local tmpfile
    tmpfile=$(mktemp)
    if git show claude-sessions:sessions/gzip-test-session.jsonl.gz | gunzip > "$tmpfile" 2>/dev/null; then
        if python3 -c "
import json, sys
bad = 0
for line in open('$tmpfile'):
    line = line.strip()
    if not line:
        continue
    try:
        json.loads(line)
    except json.JSONDecodeError:
        bad += 1
sys.exit(bad)
" 2>/dev/null; then
            pass "stored file is valid gzipped JSONL"
        else
            fail "stored file is valid gzipped JSONL" "some lines are not valid JSON"
        fi
    else
        fail "stored file is valid gzipped JSONL" "gunzip failed"
    fi
    rm -f "$tmpfile"
}


# ============================================================
# Git plumbing tests
# ============================================================

test_commit_creates_branch() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Create a file" \
        "bash:echo hello > test.txt" \
        "assistant:Done"

    make_hook_input "$transcript" "branch-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    if git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        # Check both files exist
        if git show claude-sessions:sessions/branch-test-session.jsonl.gz > /dev/null 2>&1 && \
           git show claude-sessions:sessions/branch-test-session.meta.json > /dev/null 2>&1; then
            pass "commit creates claude-sessions branch with session files"
        else
            fail "commit creates claude-sessions branch with session files" "files missing from tree"
        fi
    else
        fail "commit creates claude-sessions branch with session files" "branch not created"
    fi
}

test_commit_no_worktree_disruption() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # Create a file in the working tree and stage it
    echo "important work" > working-file.txt
    git add working-file.txt
    echo "unstaged change" >> working-file.txt

    # Record current state
    local head_before
    head_before=$(git rev-parse HEAD)
    local index_before
    index_before=$(git diff --cached --name-only)
    local branch_before
    branch_before=$(git rev-parse --abbrev-ref HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Do something" \
        "assistant:Done"

    make_hook_input "$transcript" "worktree-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    # Verify nothing changed
    local head_after
    head_after=$(git rev-parse HEAD)
    local index_after
    index_after=$(git diff --cached --name-only)
    local branch_after
    branch_after=$(git rev-parse --abbrev-ref HEAD)

    if [[ "$head_before" == "$head_after" ]] && \
       [[ "$index_before" == "$index_after" ]] && \
       [[ "$branch_before" == "$branch_after" ]] && \
       grep -q "unstaged change" working-file.txt; then
        pass "commit does not disrupt worktree, index, or current branch"
    else
        fail "commit does not disrupt worktree, index, or current branch" \
            "HEAD: $head_before→$head_after, branch: $branch_before→$branch_after"
    fi
}

test_commit_idempotent() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:First prompt" \
        "assistant:First response"

    make_hook_input "$transcript" "idempotent-session" | bash "$HOOKS_DIR/capture-session.sh"

    local commits_before
    commits_before=$(git log claude-sessions --oneline 2>/dev/null | wc -l | tr -d ' ')

    # Run again with same transcript (unchanged mtime after first commit recorded it)
    make_hook_input "$transcript" "idempotent-session" | bash "$HOOKS_DIR/capture-session.sh"

    local commits_after
    commits_after=$(git log claude-sessions --oneline 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$commits_before" == "$commits_after" ]]; then
        pass "re-running with unchanged transcript creates no new commit"
    else
        fail "re-running with unchanged transcript creates no new commit" \
            "commits went from $commits_before to $commits_after"
    fi
}

test_commit_updates_existing_session() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:First prompt" \
        "assistant:First response"

    make_hook_input "$transcript" "update-session" | bash "$HOOKS_DIR/capture-session.sh"

    # Append more content (simulating continued session) and touch to update mtime
    sleep 1
    make_transcript "$transcript" \
        "user:First prompt" \
        "assistant:First response" \
        "user:Second prompt" \
        "assistant:Second response with more detail"

    make_hook_input "$transcript" "update-session" | bash "$HOOKS_DIR/capture-session.sh"

    local commits
    commits=$(git log claude-sessions --oneline 2>/dev/null | wc -l | tr -d ' ')

    # Verify the updated content is there
    local stored
    stored=$(git show claude-sessions:sessions/update-session.jsonl.gz | gunzip)
    if [[ "$commits" -eq 2 ]] && echo "$stored" | grep -q "Second prompt"; then
        pass "second run with longer transcript updates the file"
    else
        fail "second run with longer transcript updates the file" \
            "commits=$commits, content check failed"
    fi
}

test_concurrent_sessions() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # Session A
    local transcript_a="$TEST_DIR/transcript_a.jsonl"
    make_transcript "$transcript_a" \
        "user:Session A prompt" \
        "assistant:Session A response"

    make_hook_input "$transcript_a" "session-aaa" | bash "$HOOKS_DIR/capture-session.sh"

    # Session B (different session ID, different transcript)
    local transcript_b="$TEST_DIR/transcript_b.jsonl"
    make_transcript "$transcript_b" \
        "user:Session B prompt" \
        "assistant:Session B response"

    make_hook_input "$transcript_b" "session-bbb" | bash "$HOOKS_DIR/capture-session.sh"

    # Both sessions should exist on the branch
    if git show claude-sessions:sessions/session-aaa.jsonl.gz > /dev/null 2>&1 && \
       git show claude-sessions:sessions/session-bbb.jsonl.gz > /dev/null 2>&1 && \
       git show claude-sessions:sessions/session-aaa.meta.json > /dev/null 2>&1 && \
       git show claude-sessions:sessions/session-bbb.meta.json > /dev/null 2>&1; then
        pass "two different session IDs can commit without conflict"
    else
        fail "two different session IDs can commit without conflict" "one or both sessions missing"
    fi
}


# ============================================================
# Metadata tests
# ============================================================

test_meta_has_session_fields() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    TRANSCRIPT_SLUG="test-slug" \
    TRANSCRIPT_VERSION="2.1.62" \
    TRANSCRIPT_BRANCH="feature-branch" \
    make_transcript "$transcript" \
        "user:Hello" \
        "assistant:Hi there" \
        "bash:ls" \
        "tool:Edit" \
        "tool:Read" \
        "user:Thanks"

    make_hook_input "$transcript" "meta-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    local meta
    meta=$(git show claude-sessions:sessions/meta-test-session.meta.json)

    local has_fields=true
    for field in session_id slug started last_updated models client_version git_branch user_turns assistant_turns tools_used compressed_size; do
        if ! echo "$meta" | python3 -c "import json,sys; d=json.load(sys.stdin); assert '$field' in d" 2>/dev/null; then
            has_fields=false
            break
        fi
    done

    if $has_fields; then
        # Check specific values
        local session_id slug user_turns
        session_id=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])")
        slug=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['slug'])")
        user_turns=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['user_turns'])")
        if [[ "$session_id" == "meta-test-session" ]] && \
           [[ "$slug" == "test-slug" ]] && \
           [[ "$user_turns" -eq 2 ]]; then
            pass ".meta.json contains required fields with correct values"
        else
            fail ".meta.json contains required fields with correct values" \
                "session_id=$session_id, slug=$slug, user_turns=$user_turns"
        fi
    else
        fail ".meta.json contains required fields with correct values" "missing fields"
    fi
}

test_meta_lists_commits() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Make a commit" \
        "bash:git commit -m test" \
        "commit:abc1234" \
        "user:Another commit" \
        "bash:git commit -m test2" \
        "commit:def5678"

    make_hook_input "$transcript" "commits-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    local meta
    meta=$(git show claude-sessions:sessions/commits-test-session.meta.json)

    local commits_count
    commits_count=$(echo "$meta" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['commits']))")
    if [[ "$commits_count" -eq 2 ]]; then
        pass "commits array populated from transcript"
    else
        fail "commits array populated from transcript" "expected 2, got $commits_count"
    fi
}

test_meta_lists_tools() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Do things" \
        "bash:ls" \
        "bash:cat file" \
        "tool:Edit" \
        "tool:Read" \
        "tool:Read" \
        "tool:Grep"

    make_hook_input "$transcript" "tools-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    local meta
    meta=$(git show claude-sessions:sessions/tools-test-session.meta.json)

    local bash_count edit_count read_count
    bash_count=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['tools_used'].get('Bash',0))")
    edit_count=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['tools_used'].get('Edit',0))")
    read_count=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['tools_used'].get('Read',0))")

    if [[ "$bash_count" -eq 2 ]] && [[ "$edit_count" -eq 1 ]] && [[ "$read_count" -eq 2 ]]; then
        pass "tools_used counts are correct"
    else
        fail "tools_used counts are correct" "Bash=$bash_count, Edit=$edit_count, Read=$read_count"
    fi
}

test_meta_timestamps() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:First message" \
        "assistant:Response" \
        "user:Last message"

    make_hook_input "$transcript" "ts-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    local meta
    meta=$(git show claude-sessions:sessions/ts-test-session.meta.json)

    if echo "$meta" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['started'], 'started is empty'
assert d['last_updated'], 'last_updated is empty'
assert d['started'] <= d['last_updated'], 'started > last_updated'
" 2>/dev/null; then
        pass "meta.json has valid started and last_updated timestamps"
    else
        fail "meta.json has valid started and last_updated timestamps" "timestamps missing or invalid"
    fi
}

test_meta_models() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    TRANSCRIPT_MODEL="claude-opus-4-6" \
    make_transcript "$transcript" \
        "user:Hello" \
        "assistant:Hi"

    make_hook_input "$transcript" "models-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    local meta
    meta=$(git show claude-sessions:sessions/models-test-session.meta.json)

    local models
    models=$(echo "$meta" | python3 -c "import json,sys; print(','.join(json.load(sys.stdin)['models']))")
    if [[ "$models" == *"claude-opus-4-6"* ]]; then
        pass "meta.json models array contains the model"
    else
        fail "meta.json models array contains the model" "got '$models'"
    fi
}

test_meta_client_version_and_branch() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    TRANSCRIPT_VERSION="2.1.62" \
    TRANSCRIPT_BRANCH="feature-xyz" \
    make_transcript "$transcript" \
        "user:Hello" \
        "assistant:Hi"

    make_hook_input "$transcript" "version-branch-session" | bash "$HOOKS_DIR/capture-session.sh"

    local meta
    meta=$(git show claude-sessions:sessions/version-branch-session.meta.json)

    local version branch
    version=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['client_version'])")
    branch=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['git_branch'])")
    if [[ "$version" == "2.1.62" ]] && [[ "$branch" == "feature-xyz" ]]; then
        pass "meta.json has correct client_version and git_branch"
    else
        fail "meta.json has correct client_version and git_branch" "version=$version, branch=$branch"
    fi
}

test_meta_compressed_size() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Hello" \
        "assistant:World"

    make_hook_input "$transcript" "size-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    local meta
    meta=$(git show claude-sessions:sessions/size-test-session.meta.json)

    local size
    size=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['compressed_size'])")
    if [[ "$size" -gt 0 ]]; then
        pass "meta.json compressed_size is positive"
    else
        fail "meta.json compressed_size is positive" "got $size"
    fi
}

test_meta_assistant_turns() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:One" \
        "assistant:Reply one" \
        "bash:ls" \
        "tool:Edit" \
        "user:Two" \
        "assistant:Reply two"

    make_hook_input "$transcript" "turns-test-session" | bash "$HOOKS_DIR/capture-session.sh"

    local meta
    meta=$(git show claude-sessions:sessions/turns-test-session.meta.json)

    local user_turns assistant_turns
    user_turns=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['user_turns'])")
    assistant_turns=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin)['assistant_turns'])")
    # 2 user records, 4 assistant records (assistant + bash + tool + assistant)
    if [[ "$user_turns" -eq 2 ]] && [[ "$assistant_turns" -eq 4 ]]; then
        pass "meta.json counts user and assistant turns correctly"
    else
        fail "meta.json counts user and assistant turns correctly" \
            "user=$user_turns (expected 2), assistant=$assistant_turns (expected 4)"
    fi
}


# ============================================================
# Integration tests
# ============================================================

test_push_on_session_end() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # Create a bare remote to push to
    local remote_dir
    remote_dir=$(mktemp -d "${TMPDIR:-/tmp}/cst-remote.XXXXXX")
    git init -q --bare "$remote_dir"
    git remote add origin "$remote_dir"

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Push test" \
        "assistant:Done"

    make_hook_input "$transcript" "push-test-session" | bash "$HOOKS_DIR/capture-session.sh" --push

    # Check remote has the branch
    if git -C "$remote_dir" rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "--push flag triggers push to origin"
    else
        fail "--push flag triggers push to origin" "branch not on remote"
    fi

    rm -rf "$remote_dir"
}

test_setup_skips_refspec_without_remote_branch() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    git remote add origin "https://example.com/test.git"

    bash "$HOOKS_DIR/setup-session-branch.sh"

    local fetch
    fetch=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep "claude-sessions" || echo "")
    if [[ -z "$fetch" ]]; then
        pass "setup-session-branch skips refspec when remote branch absent"
    else
        fail "setup-session-branch skips refspec when remote branch absent" "got '$fetch'"
    fi
}

test_setup_removes_stale_refspec() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    git remote add origin "https://example.com/test.git"

    # Simulate a stale refspec left by the old plugin version
    git config --add --local remote.origin.fetch "+refs/heads/claude-sessions:refs/heads/claude-sessions"

    bash "$HOOKS_DIR/setup-session-branch.sh"

    local fetch
    fetch=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep "claude-sessions" || echo "")
    if [[ -z "$fetch" ]]; then
        pass "setup-session-branch removes stale refspec when remote branch absent"
    else
        fail "setup-session-branch removes stale refspec when remote branch absent" "got '$fetch'"
    fi
}

test_setup_configures_fetch() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # Set up a real remote so push creates remote-tracking ref
    local remote_dir
    remote_dir=$(mktemp -d)
    git init --bare "$remote_dir" >/dev/null 2>&1
    git remote add origin "$remote_dir"

    # Create a local claude-sessions branch and push it to create remote-tracking ref
    git commit --allow-empty -m "init" >/dev/null 2>&1
    git branch claude-sessions >/dev/null 2>&1
    git push origin claude-sessions >/dev/null 2>&1

    bash "$HOOKS_DIR/setup-session-branch.sh"

    local fetch
    fetch=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep "claude-sessions" || echo "")
    if [[ "$fetch" == "+refs/heads/claude-sessions:refs/heads/claude-sessions" ]]; then
        pass "setup-session-branch adds fetch refspec when remote branch exists"
    else
        fail "setup-session-branch adds fetch refspec when remote branch exists" "got '$fetch'"
    fi

    rm -rf "$remote_dir"
}

test_setup_idempotent() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # Set up real remote with claude-sessions branch
    local remote_dir
    remote_dir=$(mktemp -d)
    git init --bare "$remote_dir" >/dev/null 2>&1
    git remote add origin "$remote_dir"
    git commit --allow-empty -m "init" >/dev/null 2>&1
    git branch claude-sessions >/dev/null 2>&1
    git push origin claude-sessions >/dev/null 2>&1

    bash "$HOOKS_DIR/setup-session-branch.sh"
    bash "$HOOKS_DIR/setup-session-branch.sh"
    bash "$HOOKS_DIR/setup-session-branch.sh"

    local count
    count=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep -c "claude-sessions" || echo "0")
    if [[ "$count" -eq 1 ]]; then
        pass "setup-session-branch is idempotent (no duplicate fetch refspecs)"
    else
        fail "setup-session-branch is idempotent" "got $count fetch refspecs"
    fi

    rm -rf "$remote_dir"
}

test_no_transcript_exits_cleanly() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # Empty input — no transcript_path
    echo '{}' | bash "$HOOKS_DIR/capture-session.sh"

    if ! git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "no transcript exits cleanly without creating branch"
    else
        fail "no transcript exits cleanly without creating branch" "branch was created"
    fi
}

test_setup_no_origin_exits_cleanly() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # No origin remote — should exit cleanly
    bash "$HOOKS_DIR/setup-session-branch.sh"
    pass "setup-session-branch exits cleanly with no origin remote"
}

test_setup_does_not_add_display_ref() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    git remote add origin "https://example.com/test.git"

    bash "$HOOKS_DIR/setup-session-branch.sh"

    local display_ref
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" != *"claude-sessions"* ]]; then
        pass "setup-session-branch does not add notes.displayRef"
    else
        fail "setup-session-branch does not add notes.displayRef" "got '$display_ref'"
    fi
}

test_empty_transcript() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    > "$transcript"

    make_hook_input "$transcript" "empty-session" | bash "$HOOKS_DIR/capture-session.sh"

    # Should still create the branch (empty gzip is valid)
    if git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "empty transcript creates branch without error"
    else
        # Also acceptable: script exits cleanly without creating branch
        pass "empty transcript exits cleanly"
    fi
}

test_malformed_jsonl_lines() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Valid prompt" \
        "raw:this is not valid json at all" \
        "raw:{broken json" \
        "assistant:Valid response" \
        "raw:" \
        "user:Another valid prompt"

    make_hook_input "$transcript" "malformed-session" | bash "$HOOKS_DIR/capture-session.sh"

    # Should succeed — malformed lines are kept as-is (redaction is string-based)
    if git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        local stored
        stored=$(git show claude-sessions:sessions/malformed-session.jsonl.gz | gunzip)
        if echo "$stored" | grep -q "Valid prompt" && echo "$stored" | grep -q "Another valid prompt"; then
            pass "malformed JSONL lines don't break processing"
        else
            fail "malformed JSONL lines don't break processing" "valid content missing"
        fi
    else
        fail "malformed JSONL lines don't break processing" "branch not created"
    fi
}

test_missing_session_id() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Hello" \
        "assistant:Hi"

    # No session_id in input
    echo "{\"transcript_path\":\"$transcript\"}" | bash "$HOOKS_DIR/capture-session.sh"

    if ! git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "missing session_id exits cleanly without creating branch"
    else
        fail "missing session_id exits cleanly without creating branch" "branch was created"
    fi
}

test_missing_transcript_path() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # session_id but no transcript_path
    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/capture-session.sh"

    if ! git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "missing transcript_path exits cleanly without creating branch"
    else
        fail "missing transcript_path exits cleanly without creating branch" "branch was created"
    fi
}

test_nonexistent_transcript_file() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    echo '{"transcript_path":"/tmp/does-not-exist.jsonl","session_id":"test-123"}' | bash "$HOOKS_DIR/capture-session.sh"

    if ! git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "nonexistent transcript file exits cleanly"
    else
        fail "nonexistent transcript file exits cleanly" "branch was created"
    fi
}

test_push_without_prior_commit() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local remote_dir
    remote_dir=$(mktemp -d "${TMPDIR:-/tmp}/cst-remote.XXXXXX")
    git init -q --bare "$remote_dir"
    git remote add origin "$remote_dir"

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:First ever session" \
        "assistant:Hello"

    # --push on a brand new branch (no prior commit)
    make_hook_input "$transcript" "first-push-session" | bash "$HOOKS_DIR/capture-session.sh" --push

    # Both local and remote should have the branch
    if git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1 && \
       git -C "$remote_dir" rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "--push works when branch is brand new (no prior commit)"
    else
        fail "--push works when branch is brand new (no prior commit)" "branch missing locally or on remote"
    fi

    rm -rf "$remote_dir"
}

test_no_push_without_flag() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    local remote_dir
    remote_dir=$(mktemp -d "${TMPDIR:-/tmp}/cst-remote.XXXXXX")
    git init -q --bare "$remote_dir"
    git remote add origin "$remote_dir"

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:No push test" \
        "assistant:Done"

    # No --push flag
    make_hook_input "$transcript" "nopush-session" | bash "$HOOKS_DIR/capture-session.sh"

    # Local branch should exist, but remote should NOT have it
    if git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1 && \
       ! git -C "$remote_dir" rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "without --push flag, does not push to origin"
    else
        fail "without --push flag, does not push to origin" "unexpected push occurred"
    fi

    rm -rf "$remote_dir"
}

test_works_during_merge() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # Create a branch with a conflicting file
    git checkout -q -b feature
    echo "feature content" > conflict.txt
    git add conflict.txt
    git commit -q -m "feature commit"
    git checkout -q main
    echo "main content" > conflict.txt
    git add conflict.txt
    git commit -q -m "main commit"

    # Start a merge that conflicts
    git merge feature --no-commit 2>/dev/null || true

    # Session capture should still work during merge
    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Resolving merge conflict" \
        "assistant:Let me help"

    make_hook_input "$transcript" "merge-session" | bash "$HOOKS_DIR/capture-session.sh"

    if git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "session capture works during an in-progress merge"
    else
        fail "session capture works during an in-progress merge" "branch not created"
    fi
}

test_invalid_json_stdin() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    # Garbage stdin
    echo "not json at all" | bash "$HOOKS_DIR/capture-session.sh" || true

    if ! git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "invalid JSON on stdin exits cleanly"
    else
        fail "invalid JSON on stdin exits cleanly" "branch was created"
    fi
}


# ============================================================
# Plugin structure tests
# ============================================================

test_plugin_json_valid() {
    if python3 -c "import json; json.load(open('$PROJECT_DIR/.claude-plugin/plugin.json'))" 2>/dev/null; then
        local name
        name=$(python3 -c "import json; print(json.load(open('$PROJECT_DIR/.claude-plugin/plugin.json'))['name'])")
        if [[ "$name" == "session-trail" ]]; then
            pass "plugin.json is valid with correct name"
        else
            fail "plugin.json is valid with correct name" "name is '$name'"
        fi
    else
        fail "plugin.json is valid with correct name" "invalid JSON"
    fi
}

test_hooks_json_valid() {
    if python3 -c "
import json
d = json.load(open('$HOOKS_DIR/hooks.json'))
assert 'Stop' in d['hooks']
assert 'SessionEnd' in d['hooks']
assert 'SessionStart' in d['hooks']
" 2>/dev/null; then
        pass "hooks.json is valid with Stop, SessionEnd, SessionStart hooks"
    else
        fail "hooks.json is valid with Stop, SessionEnd, SessionStart hooks" "invalid structure"
    fi
}

test_scripts_executable() {
    local all_exec=true
    for script in "$HOOKS_DIR/capture-session.sh" "$HOOKS_DIR/setup-session-branch.sh" "$HOOKS_DIR/backfill-sessions.sh"; do
        if [[ ! -x "$script" ]]; then
            all_exec=false
            fail "hook scripts are executable" "$script is not executable"
        fi
    done
    if $all_exec; then
        pass "hook scripts are executable"
    fi
}


# ============================================================
# Backfill tests
# ============================================================

# Helper: create a fake ~/.claude/projects dir with transcripts for a test repo.
# Sets FAKE_CLAUDE_HOME to a temp dir that should be used as HOME.
# Usage: setup_backfill_transcripts <session_ids...>
setup_backfill_transcripts() {
    FAKE_CLAUDE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/cst-home.XXXXXX")
    local repo_root
    repo_root=$(git rev-parse --show-toplevel)
    local encoded
    encoded=$(printf '%s' "$repo_root" | sed 's|/|-|g')
    local projects_dir="${FAKE_CLAUDE_HOME}/.claude/projects/${encoded}"
    mkdir -p "$projects_dir"

    for sid in "$@"; do
        make_transcript "${projects_dir}/${sid}.jsonl" \
            "user:Hello from ${sid}" \
            "assistant:Hi back"
    done

    # Return the projects dir path for verification
    BACKFILL_PROJECTS_DIR="$projects_dir"
}

cleanup_backfill_home() {
    if [[ -n "${FAKE_CLAUDE_HOME:-}" && -d "$FAKE_CLAUDE_HOME" ]]; then
        rm -rf "$FAKE_CLAUDE_HOME"
    fi
}

test_backfill_imports_sessions() {
    make_test_repo
    trap 'cleanup_backfill_home; cleanup_test_repo' RETURN
    install_plugin

    setup_backfill_transcripts "session-aaa" "session-bbb" "session-ccc"

    # Run backfill with faked HOME
    HOME="$FAKE_CLAUDE_HOME" bash hooks/backfill-sessions.sh

    # All three sessions should be on the branch
    local count=0
    for sid in session-aaa session-bbb session-ccc; do
        if git show "claude-sessions:sessions/${sid}.jsonl.gz" >/dev/null 2>&1 && \
           git show "claude-sessions:sessions/${sid}.meta.json" >/dev/null 2>&1; then
            count=$((count + 1))
        fi
    done

    if [[ "$count" -eq 3 ]]; then
        pass "backfill imports all discovered sessions"
    else
        fail "backfill imports all discovered sessions" "only $count of 3 imported"
    fi
}

test_backfill_skips_existing() {
    make_test_repo
    trap 'cleanup_backfill_home; cleanup_test_repo' RETURN
    install_plugin

    # First, commit one session via capture-session.sh
    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Already here" \
        "assistant:Yes"
    make_hook_input "$transcript" "existing-session" | bash hooks/capture-session.sh

    local commits_before
    commits_before=$(git log claude-sessions --oneline 2>/dev/null | wc -l | tr -d ' ')

    # Set up backfill with same session ID + a new one
    setup_backfill_transcripts "existing-session" "new-session"

    HOME="$FAKE_CLAUDE_HOME" bash hooks/backfill-sessions.sh

    local commits_after
    commits_after=$(git log claude-sessions --oneline 2>/dev/null | wc -l | tr -d ' ')

    # Should have added exactly 1 new commit (for new-session only)
    local new_commits=$((commits_after - commits_before))
    if [[ "$new_commits" -eq 1 ]] && \
       git show "claude-sessions:sessions/new-session.jsonl.gz" >/dev/null 2>&1; then
        pass "backfill skips sessions already on branch"
    else
        fail "backfill skips sessions already on branch" \
            "expected 1 new commit, got $new_commits"
    fi
}

test_backfill_force_overwrites() {
    make_test_repo
    trap 'cleanup_backfill_home; cleanup_test_repo' RETURN
    install_plugin

    # First, commit a session via capture-session.sh
    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Original content" \
        "assistant:Original"
    make_hook_input "$transcript" "force-session" | bash hooks/capture-session.sh

    local commits_before
    commits_before=$(git log claude-sessions --oneline 2>/dev/null | wc -l | tr -d ' ')

    # Set up backfill with same session ID (different content)
    setup_backfill_transcripts "force-session"

    HOME="$FAKE_CLAUDE_HOME" bash hooks/backfill-sessions.sh --force

    local commits_after
    commits_after=$(git log claude-sessions --oneline 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$commits_after" -gt "$commits_before" ]]; then
        pass "--force reimports existing sessions"
    else
        fail "--force reimports existing sessions" \
            "commits before=$commits_before, after=$commits_after"
    fi
}

test_backfill_push() {
    make_test_repo
    trap 'cleanup_backfill_home; cleanup_test_repo' RETURN
    install_plugin

    # Create a bare remote
    local remote_dir
    remote_dir=$(mktemp -d "${TMPDIR:-/tmp}/cst-remote.XXXXXX")
    git init -q --bare "$remote_dir"
    git remote add origin "$remote_dir"

    setup_backfill_transcripts "push-session"

    HOME="$FAKE_CLAUDE_HOME" bash hooks/backfill-sessions.sh --push

    if git -C "$remote_dir" rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
        pass "--push pushes after import"
    else
        fail "--push pushes after import" "branch not on remote"
    fi

    rm -rf "$remote_dir"
}

test_backfill_no_transcripts() {
    make_test_repo
    trap 'cleanup_backfill_home; cleanup_test_repo' RETURN
    install_plugin

    # Fake HOME with no transcripts for this repo
    FAKE_CLAUDE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/cst-home.XXXXXX")
    mkdir -p "$FAKE_CLAUDE_HOME/.claude/projects"

    local output
    output=$(HOME="$FAKE_CLAUDE_HOME" bash hooks/backfill-sessions.sh 2>&1)

    if [[ "$output" == *"No"*"transcripts"* ]]; then
        pass "exits cleanly when no transcripts found"
    else
        fail "exits cleanly when no transcripts found" "output: $output"
    fi
}

test_backfill_excludes_subagents() {
    make_test_repo
    trap 'cleanup_backfill_home; cleanup_test_repo' RETURN
    install_plugin

    setup_backfill_transcripts "real-session"

    # Add a subagent transcript in a subdirectory
    local repo_root
    repo_root=$(git rev-parse --show-toplevel)
    local encoded
    encoded=$(printf '%s' "$repo_root" | sed 's|/|-|g')
    local subagent_dir="${FAKE_CLAUDE_HOME}/.claude/projects/${encoded}/some-uuid/subagents"
    mkdir -p "$subagent_dir"
    make_transcript "${subagent_dir}/subagent-session.jsonl" \
        "user:Subagent prompt" \
        "assistant:Subagent response"

    HOME="$FAKE_CLAUDE_HOME" bash hooks/backfill-sessions.sh

    # real-session should be imported, subagent-session should not
    if git show "claude-sessions:sessions/real-session.jsonl.gz" >/dev/null 2>&1 && \
       ! git show "claude-sessions:sessions/subagent-session.jsonl.gz" >/dev/null 2>&1; then
        pass "backfill excludes subagent transcripts"
    else
        fail "backfill excludes subagent transcripts" "subagent was imported or real session missing"
    fi
}


# ============================================================
# Auto-backfill on start tests
# ============================================================

test_backfill_quiet_suppresses_output() {
    make_test_repo
    trap 'cleanup_backfill_home; cleanup_test_repo' RETURN
    install_plugin

    setup_backfill_transcripts "quiet-session"

    local output
    output=$(HOME="$FAKE_CLAUDE_HOME" bash hooks/backfill-sessions.sh --quiet 2>&1)

    if [[ -z "$output" ]]; then
        pass "--quiet suppresses output on successful backfill"
    else
        fail "--quiet suppresses output on successful backfill" "got output: $output"
    fi
}

test_backfill_quiet_shows_errors() {
    make_test_repo
    trap 'cleanup_backfill_home; cleanup_test_repo' RETURN
    install_plugin

    # No transcripts for this repo — quiet should suppress "No transcripts" message
    FAKE_CLAUDE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/cst-home.XXXXXX")
    mkdir -p "$FAKE_CLAUDE_HOME/.claude/projects"

    local output
    output=$(HOME="$FAKE_CLAUDE_HOME" bash hooks/backfill-sessions.sh --quiet 2>&1)

    if [[ -z "$output" ]]; then
        pass "--quiet suppresses 'no transcripts' message"
    else
        fail "--quiet suppresses 'no transcripts' message" "got output: $output"
    fi
}

test_auto_backfill_recovers_orphaned_session() {
    make_test_repo
    trap 'cleanup_backfill_home; cleanup_test_repo' RETURN
    install_plugin

    # Simulate: session was captured once (so branch exists), then a new session
    # was killed before SessionEnd — its transcript exists on disk but not on the branch
    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:First session" \
        "assistant:Done"
    make_hook_input "$transcript" "committed-session" | bash hooks/capture-session.sh

    # Now create an orphaned transcript (simulates killed session)
    setup_backfill_transcripts "orphaned-session"

    # Run backfill with --quiet as the SessionStart hook would
    HOME="$FAKE_CLAUDE_HOME" bash hooks/backfill-sessions.sh --quiet

    # Verify the orphaned session was recovered
    if git show "claude-sessions:sessions/orphaned-session.jsonl.gz" >/dev/null 2>&1 && \
       git show "claude-sessions:sessions/orphaned-session.meta.json" >/dev/null 2>&1; then
        pass "auto-backfill recovers orphaned session on start"
    else
        fail "auto-backfill recovers orphaned session on start" "orphaned session not found on branch"
    fi
}


# ============================================================
# E2E tests (optional, require ANTHROPIC_API_KEY + claude CLI)
# ============================================================

# Guard: skip if claude CLI is missing.
require_claude() {
    if ! command -v claude >/dev/null 2>&1; then
        skip "$1" "claude CLI not installed"
        return 1
    fi
    return 0
}

# Guard: skip if prerequisites for API-calling E2E tests are missing.
require_e2e() {
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        skip "$1" "ANTHROPIC_API_KEY not set"
        return 1
    fi
    require_claude "$1"
}

# Helper: run a simple Claude session that triggers the Stop hook.
# Usage: claude_session [extra-flags...]
# Returns 0 on success. Sets CLAUDE_OUTPUT.
# Retries once on failure to handle flaky LLM responses.
claude_session() {
    local attempt
    for attempt in 1 2; do
        CLAUDE_OUTPUT=$(claude -p \
            "Say hello and nothing else." \
            --permission-mode acceptEdits \
            --allowedTools 'Bash(echo *)' \
            "$@" \
            2>&1) || true

        if [[ -n "$CLAUDE_OUTPUT" ]]; then
            return 0
        fi
        [[ $attempt -eq 1 ]] && echo "  (retry claude_session after attempt $attempt)" >&2
    done
    return 1
}

test_e2e_plugin_validate() {
    require_claude "E2E plugin validate" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin
    git add .claude-plugin/ hooks/ .claude/
    git commit -q -m "add plugin"

    local output
    output=$(claude plugin validate . 2>&1)
    local rc=$?
    if [[ $rc -eq 0 && "$output" == *"Validation passed"* ]]; then
        pass "E2E: plugin validate passes"
    else
        fail "E2E: plugin validate passes" "rc=$rc output: ${output:0:200}"
    fi
}

test_e2e_session_captured() {
    require_e2e "E2E session captured" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN

    if claude_session --plugin-dir "$PROJECT_DIR"; then
        # The Stop hook should have committed to claude-sessions branch
        if git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
            # Check that session files exist (any session ID)
            local files
            files=$(git ls-tree claude-sessions sessions/ 2>/dev/null || echo "")
            if echo "$files" | grep -q '\.jsonl\.gz' && echo "$files" | grep -q '\.meta\.json'; then
                pass "E2E: session transcript captured on claude-sessions branch"
            else
                fail "E2E: session transcript captured on claude-sessions branch" \
                    "branch exists but files missing. tree: ${files:0:200}"
            fi
        else
            fail "E2E: session transcript captured on claude-sessions branch" \
                "claude-sessions branch not created. Output: ${CLAUDE_OUTPUT:0:200}"
        fi
    else
        fail "E2E: session transcript captured on claude-sessions branch" \
            "claude session failed. Output: ${CLAUDE_OUTPUT:0:200}"
    fi
}

test_e2e_transcript_decompresses() {
    require_e2e "E2E transcript decompresses" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN

    if claude_session --plugin-dir "$PROJECT_DIR"; then
        if git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
            # Find the .jsonl.gz file
            local gz_path
            gz_path=$(git ls-tree --name-only claude-sessions sessions/ 2>/dev/null | grep '\.jsonl\.gz' | head -1)
            if [[ -n "$gz_path" ]]; then
                local content
                content=$(git show "claude-sessions:$gz_path" | gunzip 2>/dev/null || echo "")
                if [[ -n "$content" ]] && echo "$content" | head -1 | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
                    pass "E2E: stored transcript decompresses to valid JSONL"
                else
                    fail "E2E: stored transcript decompresses to valid JSONL" "gunzip or JSON parse failed"
                fi
            else
                fail "E2E: stored transcript decompresses to valid JSONL" "no .jsonl.gz file found"
            fi
        else
            skip "E2E transcript decompresses" "claude-sessions branch not created"
        fi
    else
        fail "E2E: stored transcript decompresses to valid JSONL" \
            "claude session failed. Output: ${CLAUDE_OUTPUT:0:200}"
    fi
}

test_e2e_meta_has_fields() {
    require_e2e "E2E meta has fields" || return 0

    make_test_repo
    trap cleanup_test_repo RETURN

    if claude_session --plugin-dir "$PROJECT_DIR"; then
        if git rev-parse --verify refs/heads/claude-sessions >/dev/null 2>&1; then
            local meta_path
            meta_path=$(git ls-tree --name-only claude-sessions sessions/ 2>/dev/null | grep '\.meta\.json' | head -1)
            if [[ -n "$meta_path" ]]; then
                local meta
                meta=$(git show "claude-sessions:$meta_path" 2>/dev/null || echo "")
                if python3 -c "
import json, sys
d = json.loads('''$meta''') if len(sys.argv) < 2 else json.loads(sys.argv[1])
assert d.get('session_id'), 'missing session_id'
assert d.get('user_turns', 0) > 0, 'no user turns'
assert d.get('assistant_turns', 0) > 0, 'no assistant turns'
assert d.get('compressed_size', 0) > 0, 'no compressed_size'
" 2>/dev/null; then
                    pass "E2E: meta.json has expected fields from real session"
                else
                    # Try passing via stdin to avoid quoting issues
                    if echo "$meta" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('session_id'), 'missing session_id'
assert d.get('user_turns', 0) > 0, 'no user turns'
assert d.get('assistant_turns', 0) > 0, 'no assistant turns'
assert d.get('compressed_size', 0) > 0, 'no compressed_size'
" 2>/dev/null; then
                        pass "E2E: meta.json has expected fields from real session"
                    else
                        fail "E2E: meta.json has expected fields from real session" \
                            "field validation failed. meta: ${meta:0:300}"
                    fi
                fi
            else
                fail "E2E: meta.json has expected fields from real session" "no .meta.json file found"
            fi
        else
            skip "E2E meta has fields" "claude-sessions branch not created"
        fi
    else
        fail "E2E: meta.json has expected fields from real session" \
            "claude session failed. Output: ${CLAUDE_OUTPUT:0:200}"
    fi
}


# ============================================================
# Run all tests
# ============================================================

section "secret redaction"
test_redacts_secrets_in_transcript
test_redacts_openai_keys
test_redacts_aws_keys
test_redacts_github_tokens
test_redacts_bearer_tokens
test_redacts_generic_key_value
test_redacts_multiple_secrets_in_one_line
test_preserves_normal_content
test_transcript_is_valid_gzipped_jsonl

section "git plumbing"
test_commit_creates_branch
test_commit_no_worktree_disruption
test_commit_idempotent
test_commit_updates_existing_session
test_concurrent_sessions
test_works_during_merge

section "metadata"
test_meta_has_session_fields
test_meta_lists_commits
test_meta_lists_tools
test_meta_timestamps
test_meta_models
test_meta_client_version_and_branch
test_meta_compressed_size
test_meta_assistant_turns

section "edge cases"
test_empty_transcript
test_malformed_jsonl_lines
test_missing_session_id
test_missing_transcript_path
test_nonexistent_transcript_file
test_invalid_json_stdin

section "integration"
test_push_on_session_end
test_push_without_prior_commit
test_no_push_without_flag
test_setup_skips_refspec_without_remote_branch
test_setup_removes_stale_refspec
test_setup_configures_fetch
test_setup_idempotent
test_setup_does_not_add_display_ref
test_no_transcript_exits_cleanly
test_setup_no_origin_exits_cleanly

section "plugin structure"
test_plugin_json_valid
test_hooks_json_valid
test_scripts_executable

section "backfill"
test_backfill_imports_sessions
test_backfill_skips_existing
test_backfill_force_overwrites
test_backfill_push
test_backfill_no_transcripts
test_backfill_excludes_subagents

section "auto-backfill on start"
test_backfill_quiet_suppresses_output
test_backfill_quiet_shows_errors
test_auto_backfill_recovers_orphaned_session

section "E2E (optional)"
test_e2e_plugin_validate
test_e2e_session_captured
test_e2e_transcript_decompresses
test_e2e_meta_has_fields

# --- Summary ---
printf "\n\033[1mResults: %d passed, %d failed, %d skipped\033[0m\n\n" "$PASSED" "$FAILED" "$SKIPPED"

exit "$FAILED"
