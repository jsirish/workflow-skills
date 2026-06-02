---
name: merge-pr
description: Use when the user asks to merge an approved Pull Request (for example, to merge a reviewed PR or run a previous `/merge_pr` workflow); safely merges the PR, cleans up associated branches, and synchronizes the local repository.
---

# Skill: Merge PR

**Goal:** Safely merge an approved Pull Request, clean up associated branches, and synchronize the local repository.

---

## Phase 1: Pre-Merge Verification

1.  **Check PR Status:**
    ```bash
    gh pr view <pr-number> --json state,reviewDecision,statusCheckRollup,mergeable,mergeStateStatus,headRefName,baseRefName
    ```
2.  **Verify Conditions:**
    -   PR state is `OPEN`.
    -   Review decision is `APPROVED` (or confirmed by user).
    -   All CI/GitHub Action checks are passing (`statusCheckRollup`).
    -   PR is mergeable (`mergeable: "MERGEABLE"` and `mergeStateStatus: "CLEAN"`).
    -   Confirm explicit user approval to merge.

---

## Phase 2: Squash and Merge

1.  **Perform Squash Merge:**
    ```bash
    gh pr merge <pr-number> --squash --delete-branch --subject "<commit-subject>" --body "<commit-body>"
    ```
    -   **Commit Message:** Synthesize a clean, descriptive subject using conventional commits (e.g., `feat: PR title`). If the PR description contains important details, include them in the commit body.
    -   `--delete-branch` handles the remote branch cleanup on the source repository.

---

## Phase 3: Local Cleanup and Sync

First, detect whether you are inside a linked git worktree:
```bash
if [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  echo "linked worktree"
else
  echo "primary checkout"
fi
```

### If running in a worktree (Claude Code default)

`git checkout` and `git branch -D` both fail in a worktree: the default branch is checked
out in the primary worktree (two worktrees cannot share a branch), and the feature branch
is the current worktree itself. Skip both steps. Sync the primary worktree directly:

```bash
# Resolve primary worktree root — first entry in worktree list is always primary
PRIMARY=$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')
git -C "$PRIMARY" fetch origin
git -C "$PRIMARY" checkout <default-branch>
git -C "$PRIMARY" pull origin <default-branch> --ff-only
```

The feature branch worktree is cleaned up automatically by Claude Code when the session
ends — no manual deletion needed.

### If running in the primary checkout

1.  **Switch to Default Branch:**
    ```bash
    git remote show origin | grep 'HEAD branch'
    git checkout <default-branch>
    ```
2.  **Pull Latest Changes:**
    ```bash
    git fetch origin
    git pull origin <default-branch>
    ```
3.  **Sync Fork (if applicable):**
    If working on a fork, sync with upstream:
    ```bash
    git remote | grep upstream && git fetch upstream && git merge upstream/<default-branch> && git push origin <default-branch>
    ```
4.  **Delete Local Branch:**
    ```bash
    git branch -D <feature-branch>
    ```

---

## Phase 4: Handoff & Documentation

1.  **Invoke Handoff:**
    Run the `/handoff` workflow to update `HANDOFF.md` and generate a session log. This ensures the project's state reflects the new merge.
2.  **Verify PR Closure:**
    Confirm that the PR is closed on GitHub and any linked issues are also addressed.

---

## Important Reminders

- **`gh pr merge` is worktree-safe.** It uses the GitHub API and does not require being in the primary checkout. The Phase 3 split above is only about the local sync steps.
- **Branch Deletion:** `gh pr merge --delete-branch` attempts to delete the PR's head/source branch after the merge when permissions allow. For PRs from forks, automatic deletion may fail or require manual deletion on the fork.
- **Merge Conflicts:** If the PR has conflicts, resolve them before attempting to merge.
- **Verification:** Always verify that the merge was successful and that the primary worktree is on a clean, updated default branch.
