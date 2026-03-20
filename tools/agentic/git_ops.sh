#!/usr/bin/env bash
# tools/agentic/git_ops.sh — Git helper dispatched by the git_op Temporal activity.
#
# Usage: git_ops.sh <op> [options]
#
# Operations:
#   branch          Create a new branch from base-branch, or sync base-branch for direct landing
#   commit          Stage all changes and create a commit
#   push            Push the branch to origin
#   create-pr       Create a GitHub pull request via gh CLI, or no-op for direct landing
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
WORKTREE_PATH=""

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
        --worktree-path)  WORKTREE_PATH="$2";  shift 2 ;;
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
        if [[ "${BRANCH}" == "${BASE_BRANCH}" ]]; then
            log "syncing base branch '${BASE_BRANCH}' for direct landing"
            git fetch origin "${BASE_BRANCH}" 2>/dev/null || true
            git checkout "${BASE_BRANCH}" 2>/dev/null \
                || git checkout -B "${BASE_BRANCH}" "${BASE_BRANCH}"
            if git rev-parse --verify "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
                git reset --hard "origin/${BASE_BRANCH}"
            fi
            echo "::set-output name=branch::${BASE_BRANCH}"
            log "base branch '${BASE_BRANCH}' ready"
            exit 0
        fi
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
        # Unstage sensitive files that should never enter the repository.
        sensitive_staged="$(git diff --cached --name-only | grep -Ei '(^|/)\.env($|\.|[^/]*$)|credentials|secrets?|tokens?' 2>/dev/null || true)"
        if [[ -n "${sensitive_staged}" ]]; then
            log "WARNING: sensitive file(s) detected in staged changes — removing from stage"
            echo "${sensitive_staged}" | xargs -r git reset HEAD --
        fi
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
        if [[ "${BRANCH}" == "${BASE_BRANCH}" ]]; then
            log "direct landing complete on '${BRANCH}'; skipping PR creation"
            echo "::set-output name=landed_branch::${BRANCH}"
            exit 0
        fi
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

    worktree-add)
        [[ -n "${BRANCH}" ]]        || die "worktree-add: --branch is required"
        [[ -n "${WORKTREE_PATH}" ]] || die "worktree-add: --worktree-path is required"
        log "adding worktree '${WORKTREE_PATH}' on branch '${BRANCH}' from '${BASE_BRANCH}'"
        git fetch origin "${BASE_BRANCH}" 2>/dev/null || true
        mkdir -p "$(dirname "${WORKTREE_PATH}")"
        if git worktree add -b "${BRANCH}" "${WORKTREE_PATH}" "origin/${BASE_BRANCH}" 2>/dev/null; then
            :
        else
            git worktree add -b "${BRANCH}" "${WORKTREE_PATH}" "${BASE_BRANCH}"
        fi
        echo "::set-output name=worktree_path::${WORKTREE_PATH}"
        log "worktree added at ${WORKTREE_PATH}"
        ;;

    worktree-commit)
        [[ -n "${WORKTREE_PATH}" ]] || die "worktree-commit: --worktree-path is required"
        [[ -n "${COMMIT_MESSAGE}" ]] || die "worktree-commit: --commit-message is required"
        log "committing in worktree '${WORKTREE_PATH}'"
        cd "${WORKTREE_PATH}" || die "cannot cd to worktree: ${WORKTREE_PATH}"
        git add -A
        # Unstage sensitive files that should never enter the repository.
        sensitive_staged="$(git diff --cached --name-only | grep -Ei '(^|/)\.env($|\.|[^/]*$)|credentials|secrets?|tokens?' 2>/dev/null || true)"
        if [[ -n "${sensitive_staged}" ]]; then
            log "WARNING: sensitive file(s) detected in staged changes — removing from stage"
            echo "${sensitive_staged}" | xargs -r git reset HEAD --
        fi
        if git diff --cached --quiet; then
            log "nothing to commit in worktree"
            echo "::set-output name=committed::false"
            exit 1
        fi
        git commit -m "${COMMIT_MESSAGE}"
        COMMIT_SHA="$(git rev-parse HEAD)"
        echo "::set-output name=committed::true"
        echo "::set-output name=commit_sha::${COMMIT_SHA}"
        log "committed ${COMMIT_SHA} in worktree"
        ;;

    worktree-remove)
        [[ -n "${WORKTREE_PATH}" ]] || die "worktree-remove: --worktree-path is required"
        [[ -n "${BRANCH}" ]]        || die "worktree-remove: --branch is required"
        log "removing worktree '${WORKTREE_PATH}'"
        git worktree remove --force "${WORKTREE_PATH}" 2>/dev/null || true
        git branch -D "${BRANCH}" 2>/dev/null || true
        log "worktree removed"
        ;;

    worktree-land)
        [[ -n "${WORKTREE_PATH}" ]] || die "worktree-land: --worktree-path is required"
        log "landing worktree commit onto '${BASE_BRANCH}' via temp worktree"
        SHA="$(cd "${WORKTREE_PATH}" && git rev-parse HEAD)"
        # Fetch latest origin so the temp worktree starts from the current remote tip.
        git fetch origin "${BASE_BRANCH}" 2>/dev/null || true
        # Create a clean temporary worktree at origin/BASE_BRANCH (detached HEAD) to
        # avoid disturbing local staged/unstaged changes in the main worktree.
        LAND_WT="$(mktemp -d /tmp/rfc-land-XXXXXX)"
        rmdir "${LAND_WT}"  # worktree add requires the target to not exist
        git worktree add --detach --quiet "${LAND_WT}" "origin/${BASE_BRANCH}"
        # Ensure LAND_WT is cleaned up even if the script exits early.
        trap 'git worktree remove --force "${LAND_WT}" 2>/dev/null || true' EXIT
        cd "${LAND_WT}"
        git cherry-pick "${SHA}" || { cd - > /dev/null; die "cherry-pick failed"; }
        # Push with retry: on conflict, re-fetch, reset to latest origin, re-cherry-pick.
        _push_ok=0
        for _attempt in 1 2 3; do
            if git push origin "HEAD:refs/heads/${BASE_BRANCH}"; then
                _push_ok=1
                break
            fi
            if [[ "${_attempt}" -eq 3 ]]; then
                cd - > /dev/null
                die "push failed after 3 attempts"
            fi
            log "push attempt ${_attempt} failed; re-fetching origin/${BASE_BRANCH} and retrying"
            git fetch origin "${BASE_BRANCH}"
            git reset --hard "origin/${BASE_BRANCH}"
            git cherry-pick "${SHA}" || { cd - > /dev/null; die "cherry-pick failed on retry ${_attempt}"; }
        done
        cd - > /dev/null
        # Sync local branch pointer to match origin.
        git fetch origin "${BASE_BRANCH}:${BASE_BRANCH}" 2>/dev/null || true
        echo "::set-output name=landed::true"
        echo "::set-output name=commit_sha::${SHA}"
        log "landed ${SHA} onto ${BASE_BRANCH}"
        ;;

    *)
        die "unknown op '${OP}' (must be: branch, commit, push, create-pr, reset, delete-branch, worktree-add, worktree-commit, worktree-remove, worktree-land)"
        ;;
esac
