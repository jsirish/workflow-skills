# workflow-skills

Cross-project agent skills for everyday development workflows — session onboarding, handoffs, pull request review, and merge workflows. Maintained by [Jason Irish](https://github.com/jsirish).

These are the general, project-agnostic skills meant to run on nearly any repo, distinct from the domain-specific [silverstripe-skills](https://github.com/jsirish/silverstripe-skills) collection.

## Install

```bash
npx skills add jsirish/workflow-skills
```

## Skills

| Skill | Description |
|-------|-------------|
| `onboard` | Bootstrap agent context at session start — read project state, check environment, align on goals |
| `handoff` | Update the master HANDOFF.md with distilled knowledge and write a timestamped session log |
| `pr-review` | Request and manage pull request reviews using pr-agent, with optional Claude second-pass |
| `merge-pr` | Safely merge an approved PR, clean up branches, and sync the local repository |
| `ss-branch-strategy` | Branch naming, default-branch rules, and fork workflow for Silverstripe CMS major version upgrades |
| `ddev-legacy-php` | Enable EOL PHP versions (5.6–7.4) in DDEV v1.24+ on Apple Silicon (ARM64) |
| `ddev-sync` | Start DDEV, sync the remote database and assets to local, and run the framework build step |
| `server-sync` | Pull databases and assets from a remote server to the local DDEV environment using sync.sh |
| `server-deploy` | Push local databases and assets to a remote pre-prod or staging server using deploy.sh |
| `dhq-deploy` | Deploy a project to production using the DeployHQ CLI (dhq) |
| `local-ci` | Run the executable test/lint layer locally (PHPUnit, PHPCS, PHPStan, npm, ruff/pytest) with auto-fix, a status marker, and a git-push gate hook |
| `visual-regression-upgrade` | Capture full-page screenshots of two environments and produce a pixel-diff HTML report to verify visual parity |

## Installation

Requires [skills.sh](https://skills.sh) (`npx skills`).

### Install all skills globally (Claude Code)

```bash
npx skills add jsirish/workflow-skills --skill '*' -a claude-code -g
```

### Install specific skills

```bash
npx skills add jsirish/workflow-skills --skill onboard --skill handoff -a claude-code -g
```

### Install for multiple agents

```bash
npx skills add jsirish/workflow-skills --skill '*' -a claude-code -a opencode -g
```

### Update

```bash
npx skills update -g
```

> **`update` only refreshes skills you already have installed** — its arguments are installed
> skill *names*, not a repo. It won't pick up skills added to this repo since your last install.
> After this repo gains new skills, re-run `add` instead to pick them up:
>
> ```bash
> npx skills add jsirish/workflow-skills --skill '*' -a claude-code -g
> ```

### List installed

```bash
npx skills list -g
```

## Usage

Once installed, skills activate automatically based on your request. For example:

- *"onboard me on this project"* → `onboard`
- *"update the handoff"* → `handoff`
- *"review this PR"* → `pr-review`
- *"merge the approved PR"* → `merge-pr`
- *"ddev sync"* or *"sync remote database"* → `ddev-sync`
- *"pull remote database to local"* or *"sync from remote server"* → `server-sync`
- *"deploy to staging"* or *"push local data to pre-prod"* → `server-deploy`
- *"visual regression check"* or *"compare prod and staging visually"* → `visual-regression-upgrade`

## Contributing

1. Clone the repo.
2. Author or edit a skill under `skills/<skill-name>/SKILL.md`.
3. Open a pull request against `main`.
