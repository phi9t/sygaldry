#!/usr/bin/env bash
# tools/agentic/git_ops.sh — Git helper dispatched by the git_op Temporal activity.
#
# Usage: git_ops.sh <op> [options]
#
# Operations:
#   branch          Create a new branch from base-branch (default: main)
#   commit          Stage all changes and create a commit
#   push            Push the branch to origin
#   create-pr       Create a GitHub pull request via gh CLI
#   reset           Hard-reset the branch to HEAD (discard working-tree changes)
#   delete-branch   Delete a local branch (and attempt remote deletion)
#
# Options:
#   --repo-dir      <path>    Repository root (default: $PWD)
#   --branch        <name>    Target branch name
#   --base-branch   <name>    Base branch (default: main)
#   --commit-message <msg>   Commit message (used by: commit)
#   --pr-title      <title>   PR title (used by: create-pr)
#   --pr-body       <body>    PR body (used by: create-pr)

set -eu -o pipefail
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [git_ops:${BASH_LINENO[0]}] $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# ── Defaults ──────────────────────────────────────────────────────────────────

OP=""
REPO_DIR="${PWD}"
BRANCH=""
BASE_BRANCH="main"
COMMIT_MESSAGE=""
PR_TITLE=""
PR_BODY=""

# ── Argument parsing ──────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    die "usage: git_ops.sh <op> [options]"
fi
OP="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)       REPO_DIR="$2";       shift 2 ;;
        --branch)         BRANCH="$2";         shift 2 ;;
        --base-branch)    BASE_BRANCH="$2";    shift 2 ;;
        --commit-message) COMMIT_MESSAGE="$2"; shift 2 ;;
        --pr-title)       PR_TITLE="$2";       shift 2 ;;
        --pr-body)        PR_BODY="$2";        shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

# ── Move into repo ────────────────────────────────────────────────────────────

if [[ -n "${REPO_DIR}" ]]; then
    cd "${REPO_DIR}" || die "cannot cd to repo-dir: ${REPO_DIR}"
fi

# Verify we are inside a git repo.
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository: ${REPO_DIR}"

# ── Operations ────────────────────────────────────────────────────────────────

case "${OP}" in

    branch)
        [[ -n "${BRANCH}" ]] || die "branch: --branch is required"
        log "creating branch '${BRANCH}' from '${BASE_BRANCH}'"
        git fetch origin "${BASE_BRANCH}" 2>/dev/null || true
        git checkout -B "${BRANCH}" "origin/${BASE_BRANCH}" 2>/dev/null \
            || git checkout -B "${BRANCH}" "${BASE_BRANCH}"
        echo "::set-output name=branch::${BRANCH}"
        log "branch '${BRANCH}' created"
        ;;

    commit)
        [[ -n "${BRANCH}" ]] || BRANCH="$(git rev-parse --abbrev-ref HEAD)"
        [[ -n "${COMMIT_MESSAGE}" ]] || die "commit: --commit-message is required"
        log "staging and committing on branch '${BRANCH}'"
        # Ensure we are on the right branch
        current="$(git rev-parse --abbrev-ref HEAD)"
        if [[ "${current}" != "${BRANCH}" ]]; then
            git checkout "${BRANCH}" || die "commit: cannot checkout branch '${BRANCH}'"
        fi
        git add -A
        if git diff --cached --quiet; then
            log "nothing to commit on branch '${BRANCH}' — implementer made no changes"
            echo "::set-output name=committed::false"
            exit 1
        else
            git commit -m "${COMMIT_MESSAGE}"
            echo "::set-output name=committed::true"
            log "committed on branch '${BRANCH}'"
        fi
        ;;

    push)
        [[ -n "${BRANCH}" ]] || BRANCH="$(git rev-parse --abbrev-ref HEAD)"
        log "pushing branch '${BRANCH}' to origin"
        git push -u origin "${BRANCH}"
        echo "::set-output name=branch::${BRANCH}"
        log "push complete"
        ;;

    create-pr)
        [[ -n "${BRANCH}" ]] || BRANCH="$(git rev-parse --abbrev-ref HEAD)"
        [[ -n "${PR_TITLE}" ]] || die "create-pr: --pr-title is required"
        command -v gh >/dev/null 2>&1 || die "create-pr: gh CLI not found; install GitHub CLI"
        log "creating PR from '${BRANCH}' → '${BASE_BRANCH}'"
        body_flag=()
        if [[ -n "${PR_BODY}" ]]; then
            body_flag=(--body "${PR_BODY}")
        fi
        pr_url="$(gh pr create \
            --title "${PR_TITLE}" \
            --base "${BASE_BRANCH}" \
            --head "${BRANCH}" \
            "${body_flag[@]+"${body_flag[@]}"}")"
        echo "::set-output name=pr_url::${pr_url}"
        log "PR created: ${pr_url}"
        ;;

    reset)
        [[ -n "${BRANCH}" ]] || BRANCH="$(git rev-parse --abbrev-ref HEAD)"
        log "hard-resetting branch '${BRANCH}' to HEAD (discarding working-tree changes)"
        current="$(git rev-parse --abbrev-ref HEAD)"
        if [[ "${current}" != "${BRANCH}" ]]; then
            git checkout "${BRANCH}" || die "reset: cannot checkout branch '${BRANCH}'"
        fi
        # Save a patch artifact before discarding, for post-mortem debugging.
        PATCH_FILE="/tmp/sail-${BRANCH//\//-}-failed.patch"
        git diff HEAD > "${PATCH_FILE}" 2>/dev/null || true
        echo "::set-output name=patch_file::${PATCH_FILE}"
        log "patch artifact saved to ${PATCH_FILE}"
        git reset --hard HEAD
        git clean -fd
        log "reset complete"
        ;;

    delete-branch)
        [[ -n "${BRANCH}" ]] || die "delete-branch: --branch is required"
        log "deleting local branch '${BRANCH}'"
        git branch -D "${BRANCH}" 2>/dev/null || true
        log "attempting remote branch deletion"
        git push origin --delete "${BRANCH}" 2>/dev/null || true
        log "delete-branch complete"
        ;;

    *)
        die "unknown op '${OP}' (must be: branch, commit, push, create-pr, reset, delete-branch)"
        ;;
esac
