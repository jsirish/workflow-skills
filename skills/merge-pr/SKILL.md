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

- **Branch Deletion:** `gh pr merge --delete-branch` attempts to delete the PR's head/source branch after the merge when permissions allow. For PRs from forks, automatic deletion may fail or require manual deletion on the fork.
- **Merge Conflicts:** If the PR has conflicts, resolve them before attempting to merge.
- **Clean Workspace:** Before switching branches, ensure your local workspace is clean (`git status --short`).
- **Verification:** Always verify that the merge was successful and that you are back on a clean, updated default branch.
