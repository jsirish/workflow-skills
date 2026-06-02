# workflow-skills

Cross-project agent skills for everyday development workflows — session onboarding, handoffs, pull request review, and merge workflows. Maintained by [Jason Irish](https://github.com/jsirish).

These are the general, project-agnostic skills meant to run on nearly any repo, distinct from the domain-specific [silverstripe-skills](https://github.com/jsirish/silverstripe-skills) collection.

## Skills

| Skill | Description |
|-------|-------------|
| `onboard` | Bootstrap agent context at session start — read project state, check environment, align on goals |
| `handoff` | Update the master HANDOFF.md with distilled knowledge and write a timestamped session log |
| `pr-review` | Request and manage pull request reviews using pr-agent, with optional Claude second-pass |
| `merge-pr` | Safely merge an approved PR, clean up branches, and sync the local repository |
| `ddev-legacy-php` | Enable EOL PHP versions (5.6–7.4) in DDEV v1.24+ on Apple Silicon (ARM64) |

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

## Contributing

1. Clone the repo.
2. Author or edit a skill under `skills/<skill-name>/SKILL.md`.
3. Open a pull request against `main`.
