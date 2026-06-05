---
name: pr-review
description: Request and manage pull request reviews using pr-agent (local CLI) with optional Claude second-pass. Use when needing to review a PR, check review comments, address feedback, or iterate on fixes. Triggers on "review pr", "request review", "check review comments", "review this", or "re-review".
---

# PR Review

Primary reviewer: `pr-agent` (Qodo Merge), installed locally via pipx.
Optional second-pass for code PRs: `code-review:code-review` skill (Claude-based).

## Environment

pr-agent is configured entirely through **environment variables** — there is no user-global config file for the CLI (see [Notes](#notes)). Put this block in your shell rc (`~/.zshrc`) once, substituting your provider's endpoint, key var, and model:

```sh
export OPENAI__KEY="$YOUR_PROVIDER_KEY"
export OPENAI__API_BASE="<https://your-endpoint/v1>"
export CONFIG__MODEL="<provider/model>"            # e.g. openai/<model-name>
export CONFIG__FALLBACK_MODELS='["<provider/fallback-model>"]'
export CONFIG__CUSTOM_MODEL_MAX_TOKENS=<tokens>    # required if model isn't in pr-agent's built-in list
export GITHUB__USER_TOKEN="$GITHUB_TOKEN"
```

- `SECTION__KEY` double-underscore is dynaconf's env convention (pr-agent sets `envvar_prefix=False`, so no prefix). These vars are read **only** by pr-agent — they don't collide with other tools' `OPENAI_API_KEY`/`OPENAI_API_BASE`.
- `CONFIG__MODEL` overrides the default (`gpt-*`); prefix with the provider (`openai/`, `anthropic/`, …) to route a custom model to your `OPENAI__API_BASE`.
- Setting `OPENAI__API_BASE` pins all openai-provider calls to your endpoint, so a stray real `OPENAI_API_KEY` in the environment can never reach `api.openai.com` via pr-agent — no `unset` needed.

Project-level config lives in `.pr_agent.toml` (if present).

## Commands

All commands write to the PR under the user's GitHub identity. Confirm before running `review`, `improve`, or `describe` (which rewrites the PR title and body) on a PR the user didn't author.

In an interactive terminal the env block is already loaded, so just call `pr-agent`. Non-interactive callers (e.g. an agent's shell tool) that don't load your rc should prepend `source ~/.zshrc;`.

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
2. **Request pr-agent review**:
   ```sh
   source ~/.zshrc; pr-agent --pr_url <pr-url> review
   ```
   For inline suggestions, also run `improve`. (Env vars from [Environment](#environment) must be loaded; the `source` covers non-interactive shells.)
3. **Optional Claude second-pass** (code PRs): invoke `code-review:code-review`. Useful for a second-model perspective — pr-agent uses a different model by default, so Claude catches different patterns.
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
- Install via `pipx install pr-agent`. **Do not edit the bundled `.secrets.toml` inside the pipx venv** — `pipx upgrade`/`reinstall` rebuilds the venv and wipes it. Configure via the env vars above instead (they live outside the venv and survive upgrades).
- **There is no user-global config file for the CLI** (no `~/.pr_agent.toml`). pr-agent loads settings only from package-internal paths and actively blocks dynaconf's include/external-file mechanisms. The "global configuration" in the docs is the org-level `pr-agent-settings` GitHub repo, which applies only to the hosted GitHub App — not the CLI. Environment variables are the only global mechanism.
- Project-specific guidance for pr-agent (when relevant) lives in the project's `.claude/CLAUDE.md` or `.agent/pr-agent.md`.
