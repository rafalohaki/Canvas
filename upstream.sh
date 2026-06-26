#!/usr/bin/env bash
set -euo pipefail

# Canvas upstream sync script — direct Paper upstream
# Usage:
#   ./upstream.sh update     — fetch latest Paper dev/26.2, update paperCommit
#   ./upstream.sh apply      — apply all patches (applyAllPatches)
#   ./upstream.sh rebuild    — rebuild all patches
#   ./upstream.sh full       — update + apply + rebuild (full sync)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PAPER_REMOTE="https://github.com/PaperMC/Paper.git"
PAPER_BRANCH="dev/26.2"
PROPS_FILE="gradle.properties"

get_current_commit() {
    grep "^paperCommit" "$PROPS_FILE" | cut -d'=' -f2 | tr -d ' '
}

get_latest_commit() {
    git ls-remote "$PAPER_REMOTE" "refs/heads/$PAPER_BRANCH" | awk '{print $1}'
}

update_commit() {
    local new_commit="$1"
    sed -i.bak "s/^paperCommit = .*/paperCommit = $new_commit/" "$PROPS_FILE"
    rm -f "$PROPS_FILE.bak"
    echo "Updated paperCommit to $new_commit"
}

cmd_update() {
    echo "Fetching latest Paper $PAPER_BRANCH..."
    local latest
    latest=$(get_latest_commit)
    local current
    current=$(get_current_commit)

    echo "Current: $current"
    echo "Latest:  $latest"

    if [ "$current" = "$latest" ]; then
        echo "Already up to date."
        return 0
    fi

    update_commit "$latest"
    echo "Paper commit updated. Run './upstream.sh apply' to apply patches."
}

cmd_apply() {
    echo "Applying all patches..."
    ./gradlew applyAllPatches --no-configuration-cache
}

cmd_rebuild() {
    echo "Rebuilding all patches..."
    ./gradlew rebuildPatches --no-configuration-cache
}

cmd_full() {
    cmd_update
    cmd_apply
    echo "Patches applied. Review changes, then run './upstream.sh rebuild' to rebuild patches."
}

case "${1:-help}" in
    update)
        cmd_update
        ;;
    apply)
        cmd_apply
        ;;
    rebuild)
        cmd_rebuild
        ;;
    full)
        cmd_full
        ;;
    *)
        echo "Canvas upstream sync — direct Paper upstream"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  update   — fetch latest Paper dev/26.2, update paperCommit in gradle.properties"
        echo "  apply    — run applyAllPatches (apply Paper + Canvas patches)"
        echo "  rebuild  — rebuild all Canvas patches from applied source"
        echo "  full     — update + apply (full upstream sync)"
        echo ""
        echo "Paper remote: $PAPER_REMOTE"
        echo "Paper branch: $PAPER_BRANCH"
        ;;
esac
