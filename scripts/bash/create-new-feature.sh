#!/usr/bin/env bash

set -e

JSON_MODE=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        --help|-h) echo "Usage: $0 [--json] <feature_description>"; exit 0 ;;
        *) ARGS+=("$arg") ;;
    esac
done

FEATURE_DESCRIPTION="${ARGS[*]}"
if [ -z "$FEATURE_DESCRIPTION" ]; then
    echo "Usage: $0 [--json] <feature_description>" >&2
    exit 1
fi

# Function to find the repository root by searching for existing project markers
find_repo_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.git" ] || [ -d "$dir/.specify" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# Check if we're in a worktree structure
is_worktree_structure() {
    local current_dir="$1"
    local parent_dir="$(dirname "$current_dir")"
    local grandparent_dir="$(dirname "$parent_dir")"

    # Check if we're in workspace/source/ or workspace/worktree/[branch]/
    if [[ "$(basename "$parent_dir")" == "workspace" && "$(basename "$current_dir")" == "source" ]]; then
        echo "source"
        return 0
    elif [[ "$(basename "$grandparent_dir")" == "workspace" && "$(basename "$parent_dir")" == "worktree" ]]; then
        echo "worktree"
        return 0
    fi
    return 1
}

# Migrate existing repo to worktree structure
migrate_to_worktree() {
    local repo_root="$1"
    local workspace_dir="$(dirname "$repo_root")/workspace"
    local source_dir="$workspace_dir/source"
    local worktree_dir="$workspace_dir/worktree"

    echo "Migrating to worktree structure..."

    # Create workspace structure
    mkdir -p "$workspace_dir"
    mkdir -p "$worktree_dir"

    # Move current repo to source
    mv "$repo_root" "$source_dir"

    echo "Migration complete. Repository moved to $source_dir"
    echo "$source_dir"
}

# Resolve repository root and handle worktree structure
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if git rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_ROOT=$(git rev-parse --show-toplevel)
    HAS_GIT=true
else
    REPO_ROOT="$(find_repo_root "$SCRIPT_DIR")"
    if [ -z "$REPO_ROOT" ]; then
        echo "Error: Could not determine repository root. Please run this script from within the repository." >&2
        exit 1
    fi
    HAS_GIT=false
fi

# Determine current context and handle migration
WORKTREE_TYPE=$(is_worktree_structure "$REPO_ROOT")
if [ $? -eq 0 ]; then
    # Already in worktree structure
    if [ "$WORKTREE_TYPE" == "source" ]; then
        SOURCE_DIR="$REPO_ROOT"
        WORKSPACE_DIR="$(dirname "$REPO_ROOT")"
    else
        # We're in a feature worktree, find the source
        WORKSPACE_DIR="$(dirname "$(dirname "$REPO_ROOT")")"
        SOURCE_DIR="$WORKSPACE_DIR/source"
    fi
else
    # Need to migrate
    if [ "$HAS_GIT" = false ]; then
        echo "Error: Git worktrees require a git repository. Please initialize git first." >&2
        exit 1
    fi
    SOURCE_DIR=$(migrate_to_worktree "$REPO_ROOT")
    WORKSPACE_DIR="$(dirname "$SOURCE_DIR")"
fi

cd "$SOURCE_DIR"

SPECS_DIR="$SOURCE_DIR/specs"
mkdir -p "$SPECS_DIR"

HIGHEST=0
if [ -d "$SPECS_DIR" ]; then
    for dir in "$SPECS_DIR"/*; do
        [ -d "$dir" ] || continue
        dirname=$(basename "$dir")
        number=$(echo "$dirname" | grep -o '^[0-9]\+' || echo "0")
        number=$((10#$number))
        if [ "$number" -gt "$HIGHEST" ]; then HIGHEST=$number; fi
    done
fi

NEXT=$((HIGHEST + 1))
FEATURE_NUM=$(printf "%03d" "$NEXT")

BRANCH_NAME=$(echo "$FEATURE_DESCRIPTION" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//' | sed 's/-$//')
WORDS=$(echo "$BRANCH_NAME" | tr '-' '\n' | grep -v '^$' | head -3 | tr '\n' '-' | sed 's/-$//')
BRANCH_NAME="${FEATURE_NUM}-${WORDS}"

WORKTREE_PATH="$WORKSPACE_DIR/worktree/$BRANCH_NAME"

if [ "$HAS_GIT" = true ]; then
    # Create worktree for the new feature branch
    git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH"

    # Switch to the new worktree
    cd "$WORKTREE_PATH"
else
    >&2 echo "[specify] Warning: Git repository not detected; skipped worktree creation for $BRANCH_NAME"
    mkdir -p "$WORKTREE_PATH"
    cd "$WORKTREE_PATH"
fi

FEATURE_DIR="$WORKTREE_PATH/specs/$BRANCH_NAME"
mkdir -p "$FEATURE_DIR"

TEMPLATE="$SOURCE_DIR/.specify/templates/spec-template.md"
SPEC_FILE="$FEATURE_DIR/spec.md"
if [ -f "$TEMPLATE" ]; then cp "$TEMPLATE" "$SPEC_FILE"; else touch "$SPEC_FILE"; fi

# Set the SPECIFY_FEATURE environment variable for the current session
export SPECIFY_FEATURE="$BRANCH_NAME"

if $JSON_MODE; then
    printf '{"BRANCH_NAME":"%s","SPEC_FILE":"%s","FEATURE_NUM":"%s","WORKTREE_PATH":"%s"}\n' "$BRANCH_NAME" "$SPEC_FILE" "$FEATURE_NUM" "$WORKTREE_PATH"
else
    echo "BRANCH_NAME: $BRANCH_NAME"
    echo "WORKTREE_PATH: $WORKTREE_PATH"
    echo "SPEC_FILE: $SPEC_FILE"
    echo "FEATURE_NUM: $FEATURE_NUM"
    echo "SPECIFY_FEATURE environment variable set to: $BRANCH_NAME"
fi
