#!/bin/bash
input=$(cat)

# Extract JSON fields
MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
SESSION_ID=$(echo "$input" | jq -r '.session_id')
SESSION_NAME=$(echo "$input" | jq -r '.session_name // empty')

# Context usage
CONTEXT_USED=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Git caching to avoid slowdowns
CACHE_FILE="/tmp/statusline-git-cache-$SESSION_ID"
CACHE_MAX_AGE=5  # seconds

cache_is_stale() {
    [ ! -f "$CACHE_FILE" ] || \
    [ $(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0))) -gt $CACHE_MAX_AGE ]
}

if cache_is_stale; then
    if git rev-parse --git-dir > /dev/null 2>&1; then
        BRANCH=$(git branch --show-current 2>/dev/null)
        STAGED=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
        MODIFIED=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
        UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
        echo "$BRANCH|$STAGED|$MODIFIED|$UNTRACKED" > "$CACHE_FILE"
    else
        echo "|||" > "$CACHE_FILE"
    fi
fi

IFS='|' read -r BRANCH STAGED MODIFIED UNTRACKED < "$CACHE_FILE"

# Build status line in Starship-like bracketed format
OUTPUT=""

# Session name or model
if [ -n "$SESSION_NAME" ]; then
    OUTPUT="[$SESSION_NAME]"
else
    OUTPUT="[$MODEL]"
fi

# Directory
OUTPUT="$OUTPUT [${DIR##*/}]"

# Git branch and status
if [ -n "$BRANCH" ]; then
    GIT_STATUS=""
    [ "$STAGED" != "0" ] && GIT_STATUS="${GIT_STATUS}+${STAGED}"
    [ "$MODIFIED" != "0" ] && GIT_STATUS="${GIT_STATUS}~${MODIFIED}"
    [ "$UNTRACKED" != "0" ] && GIT_STATUS="${GIT_STATUS}?${UNTRACKED}"

    if [ -n "$GIT_STATUS" ]; then
        OUTPUT="$OUTPUT [$BRANCH][$GIT_STATUS]"
    else
        OUTPUT="$OUTPUT [$BRANCH]"
    fi
fi

# Context usage if available
if [ -n "$CONTEXT_USED" ]; then
    USED_INT=$(printf "%.0f" "$CONTEXT_USED")
    OUTPUT="$OUTPUT [ctx:${USED_INT}%]"
fi

echo "$OUTPUT"