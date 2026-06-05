---
name: pr-review
description: Request and manage pull request reviews using pr-agent (local CLI) with optional Claude second-pass. Use when needing to review a PR, check review comments, address feedback, or iterate on fixes. Triggers on "review pr", "request review", "check review comments", "review this", or "re-review".
---

# PR Review

Primary reviewer: `pr-agent` (Qodo Merge), installed locally via pipx.
Optional second-pass for code PRs: `code-review:code-review` skill (Claude-based).

## Environment

The Bash tool doesn't source `~/.zshrc`. Run pr-agent inside a subshell `(...)` so credential overrides don't leak into the parent shell:

```sh
(source ~/.zshrc; \
  export OPENAI__KEY="$OPENAI_API_KEY"; \
  export CONFIG__MODEL="<provider/model>"; \
  export CONFIG__FALLBACK_MODELS='["<provider/fallback-model>"]'; \
  export GITHUB__USER_TOKEN="$GITHUB_TOKEN"; \
  pr-agent --pr_url <pr-url> <command>)
```

- `OPENAI__KEY`, `OPENAI__API_BASE`, `ANTHROPIC__KEY` etc. are dynaconf env vars — override pr-agent config without touching `.secrets.toml`.
- `CONFIG__MODEL` — override the default model (`gpt-*` by default); prefix with the litellm provider (`openai/`, `anthropic/`, etc.) for non-OpenAI endpoints.
- `CONFIG__FALLBACK_MODELS` — replace the default fallback to prevent accidental expensive model usage when the primary model fails.
- `CONFIG__CUSTOM_MODEL_MAX_TOKENS` — required for models not in pr-agent's built-in token limit table (any non-standard model name).
- Project-level config lives in `.pr_agent.toml` (if present).

## Commands

All commands write to the PR under the user's GitHub identity. Confirm before running `review`, `improve`, or `describe` (which rewrites the PR title and body) on a PR the user didn't author.

> Every `pr-agent` invocation below assumes the env prefix from the [Environment](#environment) section is already prepended.

```sh
# Review — posts a top-level review comment (correctness, security, completeness)
pr-agent --pr_url <pr-url> review

# Improve — posts inline code suggestions
pr-agent --pr_url <pr-url> improve

# Describe — rewrites the PR title and description
pr-agent --pr_url <pr-url> describe

# Ask — ask a specific question about the PR
pr-agent --pr_url <pr-url> ask "<question>"
```

## Workflow

1. **Identify the PR**: `gh pr view <number>` to confirm scope, then grab the URL.
2. **Request pr-agent review** (use the subshell form from [Environment](#environment)):
   ```sh
   (source ~/.zshrc; \
     export OPENAI__KEY="$OPENAI_API_KEY"; \
     export CONFIG__MODEL="<provider/model>"; \
     export CONFIG__FALLBACK_MODELS='["<provider/fallback-model>"]'; \
     export GITHUB__USER_TOKEN="$GITHUB_TOKEN"; \
     pr-agent --pr_url <pr-url> review)
   ```
   For inline suggestions, also run `improve`.
3. **Optional Claude second-pass** (code PRs): invoke `code-review:code-review`. Useful for a second-model perspective — pr-agent uses GPT by default, Claude catches different patterns.
4. **Read the posted feedback**:
   ```sh
   gh pr view <number> --json reviews
   gh api repos/OWNER/REPO/pulls/<number>/comments
   ```
5. **Address feedback** — fix code, commit, push.
6. **Reply to each thread** explaining what was fixed:
   ```sh
   gh api repos/OWNER/REPO/pulls/<PR_NUMBER>/comments/<COMMENT_ID>/replies \
     -X POST -f body="Fixed in <commit-sha>"
   ```
7. **Re-review** — repeat from step 2. Aim for **at least 3 rounds** when the reviewer is providing legitimate feedback. Stop only when two consecutive rounds produce no new actionable comments.

### Round count guidance

- **< 3 rounds**: only acceptable when the very first review finds nothing actionable (clean pass). If any round surfaces real findings, keep going.
- **3 rounds**: default target. Covers the common pattern of a fix introducing a new edge case the reviewer catches on re-pass.
- **4+ rounds**: expected for security issues, logic bugs, or when an earlier skip was later reversed (as happened with the `reviewThreads` finding on this PR).

### Deciding What to Address

- **Address immediately**: Security issues, bugs, missing error handling, secret leaks
- **Create issue for later**: Style preferences, nice-to-have refactors, doc suggestions
- **Skip with explanation**: Comments that don't apply to the project's context — reply on the thread so the rationale is on record. Be prepared for the reviewer to re-flag if the skip was wrong.

## Checking Review Status

```sh
# List open PRs
gh pr list

# View PR details + diff
gh pr view <number>
gh pr diff <number>

# Check existing reviews
gh pr view <number> --json reviews --jq '.reviews[] | {author: .author.login, state, submittedAt}'

# Check inline review comments
gh api repos/OWNER/REPO/pulls/<number>/comments \
  --jq '.[] | {id, path, line, user: .user.login, body}'
```

## Notes

- pr-agent is a **local CLI only** — there is no GitHub Action workflow firing on push.
- If `pr-agent` is missing on PATH, install via `pipx install pr-agent` (the skill assumes it's already installed).
- Project-specific guidance for pr-agent (when relevant) lives in the project's `.claude/CLAUDE.md` or `.agent/pr-agent.md`.
