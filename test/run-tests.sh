#!/usr/bin/env bash
set -euo pipefail

# Test suite for claude-session-trail
# Tests secret redaction, git plumbing, metadata extraction, and integration.
# All tests run in isolated /tmp directories — no side effects on the real repo.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$PROJECT_DIR/hooks"

PASSED=0
FAILED=0

# --- Helpers ---

pass() {
    printf "  \033[32mPASS\033[0m %s\n" "$1"
    PASSED=$((PASSED + 1))
}

fail() {
    printf "  \033[31mFAIL\033[0m %s: %s\n" "$1" "$2"
    FAILED=$((FAILED + 1))
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

test_setup_configures_fetch() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    git remote add origin "https://example.com/test.git"

    bash "$HOOKS_DIR/setup-session-branch.sh"

    local fetch
    fetch=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep "claude-sessions" || echo "")
    if [[ "$fetch" == "+refs/heads/claude-sessions:refs/heads/claude-sessions" ]]; then
        pass "setup-session-branch adds fetch refspec for claude-sessions"
    else
        fail "setup-session-branch adds fetch refspec for claude-sessions" "got '$fetch'"
    fi
}

test_setup_idempotent() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_plugin

    git remote add origin "https://example.com/test.git"

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
    for script in "$HOOKS_DIR/capture-session.sh" "$HOOKS_DIR/setup-session-branch.sh"; do
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
# Run all tests
# ============================================================

section "secret redaction"
test_redacts_secrets_in_transcript
test_preserves_normal_content
test_transcript_is_valid_gzipped_jsonl

section "git plumbing"
test_commit_creates_branch
test_commit_no_worktree_disruption
test_commit_idempotent
test_commit_updates_existing_session
test_concurrent_sessions

section "metadata"
test_meta_has_session_fields
test_meta_lists_commits
test_meta_lists_tools

section "integration"
test_push_on_session_end
test_setup_configures_fetch
test_setup_idempotent
test_no_transcript_exits_cleanly
test_setup_no_origin_exits_cleanly

section "plugin structure"
test_plugin_json_valid
test_hooks_json_valid
test_scripts_executable

# --- Summary ---
printf "\n"
printf "  \033[32m%d passed\033[0m" "$PASSED"
if [[ "$FAILED" -gt 0 ]]; then
    printf ", \033[31m%d failed\033[0m" "$FAILED"
fi
printf "\n\n"

exit "$FAILED"
