---
name: dhq-deploy
description: Deploy a project to production using the DeployHQ CLI (dhq). Use when asked to deploy, trigger a deployment, or ship code via DeployHQ.
---

# DeployHQ CLI Deployment

## Prerequisites

- `dhq` CLI installed and authenticated (`dhq auth` / `dhq doctor`)
- Know the **project permalink** — the short slug visible in the DeployHQ URL, e.g. `my-project`. This is NOT the UUID.

## Critical: permalink vs UUID

`dhq deploy` and most commands require the **project permalink** (a short slug), not the UUID. Using a UUID returns a 404 from the DeployHQ API. Always confirm with `dhq projects list` if unsure.

## Find project and server identifiers

```bash
# List all projects — shows permalink in the first column
dhq projects list

# List servers for a project
dhq servers list -p <permalink>
```

## Deploy

### Simplest case (single project, single server, latest commit)

```bash
dhq deploy --wait
```

`--wait` streams the deployment log in real time and exits non-zero on failure.

### Explicit: specific project, server, and revision

```bash
dhq deploy -p <permalink> -s <server-identifier> -r <git-sha> --wait
```

### Preview without deploying

```bash
dhq deploy -p <permalink> --dry-run
```

## Watch an existing deployment

If a deployment was triggered without `--wait`:

```bash
dhq deployments watch <deployment-id> -p <permalink>
```

## Common flags

| Flag | Short | Meaning |
|------|-------|---------|
| `--project` | `-p` | Project permalink |
| `--server` | `-s` | Server or group identifier |
| `--revision` | `-r` | End revision (default: latest) |
| `--branch` | `-b` | Branch to deploy |
| `--wait` | `-w` | Stream log and block until done |
| `--dry-run` | | Preview only, no deployment created |
| `--full` | | Deploy entire branch from first commit |
| `--timeout` | | Seconds before `--wait` gives up (0 = none) |

## Check result and duration

`--wait` exits non-zero on failure and prints final status inline. To inspect duration or retrieve the deployment ID for further commands:

```bash
# Most recent deployments with status and duration
dhq deployments list -p <permalink>

# Full details for a specific deployment
dhq deployments show <deployment-id> -p <permalink>

# Machine-readable (status, duration_seconds, etc.)
dhq deployments show <deployment-id> -p <permalink> --json
```

## Post-deploy

DeployHQ runs any SSH commands configured on the server (e.g. `composer install`, `sake dev/build`, OPcache flush) automatically after the file transfer. No manual post-deploy steps are needed unless something is not in the server's SSH command list.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `404 Not Found` on deploy | You used the project UUID instead of the permalink. Run `dhq projects list` and use the slug. |
| No servers found | Run `dhq servers list -p <permalink>` to confirm identifiers. |
| Deploy queued but not running | Check for a running deployment: `dhq deployments list -p <permalink>`. DeployHQ queues if one is already in progress. |
| Auth failure | Run `dhq doctor` to verify credentials and connectivity. |
