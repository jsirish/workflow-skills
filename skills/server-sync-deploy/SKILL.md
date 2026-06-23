---
name: server-sync-deploy
description: Documentation for managing local-to-remote and remote-to-local environment synchronizations utilizing deploy.sh and sync.sh bash scripts. Use when syncing databases, transferring public assets, or pushing tested deployments to staging/production servers.
---

# Server Sync & Deploy Workflow

A unified guide on pulling and pushing environmental data (Database & Assets) between DDEV local instances and remote (Preprod/Production) servers using `sync.sh` and `deploy.sh`.

## Overview

In DDEV architectures, rather than executing builds or variant generations on a live VPS—which risks server timeouts on heavy asset matrices—we rely on localized `rsync` techniques. 

> **Note on "production":** `sync.sh` pulls from the *authoritative content source* — typically production, but may be a pre-prod server during pre-launch phases. The `.env` `REMOTE_*` vars always point to whichever environment holds the master content.

*   **`sync.sh`**: Pulls the remote state Downward (`Remote -> Local`). Useful for onboarding onto a project or grabbing fresh production data to test locally.
*   **`deploy.sh`**: Pushes the local state Upward (`Local -> Remote`). Essential during major version upgrades or when deploying pre-computed `public/assets`.

> [!WARNING]
> Both scripts are highly destructive. `sync.sh` will drop and overwrite the local DDEV database/assets. `deploy.sh` will drop and overwrite the remote database/assets. **Always confirm destinations before running.**

## Prerequisites / Safety

Both scripts need authenticated SSH to reach the remote, so run `ddev auth ssh` first.

> [!IMPORTANT]
> **The two scripts run in opposite contexts — this trips people up.**
> - **`sync.sh` runs INSIDE the container** (`ddev exec ./sync.sh`). It connects `mysql`/`mysqldump` to the ddev `db` service host and imports into the container DB, so it must run where that hostname resolves. It validates `ssh rsync mysqldump mysql gzip gunzip` — note **no `ddev`**.
> - **`deploy.sh` runs on the HOST** (`bash deploy.sh`). It shells out to `ddev exec` *itself* (to dump the local DB) and validates that **`ddev` is in PATH**. Running it via `ddev exec ./deploy.sh` fails immediately — there is no `ddev` binary inside the container.

```bash
# Authorize SSH Agent First
ddev auth ssh

# Pull prod → local: runs INSIDE the container
ddev exec ./sync.sh

# Push local → pre-prod: runs on the HOST (it calls ddev exec internally)
bash deploy.sh
```

## Environment Configuration (`.env`)

The target remote environment relies on specific credentials set inside the project's `.env` file. Notice the prefix disparity: `sync.sh` pulls from `REMOTE_`, while `deploy.sh` pushes to `PREPROD_`.

**For `sync.sh` (Pulling):**
```text
REMOTE_USER="username"
REMOTE_HOST="target-host.com"
REMOTE_ASSETS_PATH="/var/www/html/public/assets"
REMOTE_DB_NAME="db_name"
REMOTE_DB_USER="db_user"
REMOTE_DB_PASSWORD="db_password"
REMOTE_DB_HOST="localhost"
```

**For `deploy.sh` (Pushing):**
```text
PREPROD_USER="username"
PREPROD_HOST="target-host.com"
PREPROD_ASSETS_PATH="/var/www/html/public/assets"
PREPROD_DB_NAME="db_name"
PREPROD_DB_USER="db_user"
PREPROD_DB_PASSWORD="db_password"
PREPROD_DB_HOST="localhost"
```

*Local execution relies on the application's database environment variables (`SS_DATABASE_NAME`, `SS_DATABASE_SERVER` for SilverStripe; adapt to your framework's equivalents).*

## Command Flags & Features

Both scripts accept identical command-line flags to isolate deployments or test executions without causing data loss.

| Flag | Description |
|-----------|-------------|
| `--help`  | Shows usage information |
| `--dry-run` | Tests the `rsync` without making changes to the disk or executing MySQL dumps. Always recommend running this first. |
| `--assets`| Bypasses the database dump phase. Only syncs `public/assets/`. |
| `--db`    | Bypasses the asset rsync phase. Only drops and imports the database. |
| `--exclude=PATTERN` | Pass this flag (multiple times if needed) to ignore specific files or globs from the `rsync` cycle. Example: `--exclude=*.log --exclude=_resampled/` |

### Script Internal Logic

#### `sync.sh` (Pulling)
1. **DB Segment:** Performs a `mysqldump` dynamically via SSH on the remote, zips to `/tmp`, pulls via `rsync`, then pipes via `pv` through `gunzip` and drops/imports local DB.
2. **Assets Segment:** Executes `rsync --delete` to map remote `/assets/` directory downwards, purging orphaned local files. 

#### `deploy.sh` (Pushing)
1. **DB Segment:** Dumps local SS_DB to `/tmp`, zips it, pushes to remote `/tmp` via `rsync`, executes remote `gunzip | mysql` via SSH to overwrite the target DB.
2. **Assets Segment:** Executes `rsync --delete` to push local `/assets/` to target. Crucial for syncing locally-resampled thumbnail and variant image structures.

> [!TIP]
> Ensure a local deployment task involving heavy computation (e.g. `GalleryResampleTask`) is run locally *before* utilizing `deploy.sh --assets` to offload processing burden successfully from the remote VPS.

## DeployHQ / Ploi caveats

`sync.sh` / `deploy.sh` move data; the actual code deploy is usually handled by **DeployHQ** (build + SSH) onto a **Ploi**-managed server. Six behaviours of that stack each caused a production-style failure and aren't obvious from the scripts above.

> [!CAUTION]
> **DeployHQ deploys from the git remote, not your working copy — check for unpushed commits first.**
> If your deploy branch has local commits you haven't pushed, `dhq deploy` silently ships the older
> remote revision. Run a preflight before every deploy:
> ```bash
> git log origin/<branch>..<branch> --oneline   # must be empty before dhq deploy
> ```
> (Field evidence: master had 2 unpushed commits at deploy time on a production project — caught only by this check.)

> [!CAUTION]
> **`composer install` skips packages whose constraint is already satisfied.** On a server with an existing `vendor/`, `composer install` will **not** re-fetch a package just because the locked content changed — leaving stale or mismatched code that passes locally but breaks the deploy. For a clean parity deploy, wipe first:
> ```bash
> rm -rf vendor && composer install --no-dev -o
> ```
> Add `rm -rf vendor` to the DeployHQ post-deploy SSH command (or build step) so every deploy starts from a clean vendor tree.

> [!WARNING]
> **DeployHQ deletes files that are removed from git.** When a tracked file is **de-tracked** (removed from the repo), DeployHQ deletes it from the server on the next deploy. This silently wiped a server's `.env` after it was removed from version control. Keep server-only files (`.env`, secrets, uploaded assets outside `public/assets/`) in DeployHQ's **config files** / **excluded paths** feature, or recreate them out-of-band — never assume a de-tracked file survives on the server.

> [!WARNING]
> **Ploi requires `127.0.0.1`, not `localhost`, as the database server.** On Ploi-managed servers, `localhost` resolves to a MySQL **socket path** rather than the TCP interface, causing connection failures. Use the TCP loopback in the server `.env`:
> ```text
> # SilverStripe:
> SS_DATABASE_SERVER="127.0.0.1"
> # Other frameworks: set the equivalent DB_HOST / DATABASE_URL host to 127.0.0.1
> ```

> [!CAUTION]
> **`REMOTE_*` and `PREPROD_*` must point at DIFFERENT hosts — if both scripts use `REMOTE_*`, they target the same server.** `sync.sh` reads `REMOTE_*` (production — pull FROM). `deploy.sh` reads `PREPROD_*` (pre-prod/staging — push TO). When `.env` only defines `REMOTE_*` and `deploy.sh` was left reading the same vars, `sync.sh` and `deploy.sh` both targeted pre-prod: data pulled *from* pre-prod, deployed *to* pre-prod, and production was never touched. The failure is completely silent. Always verify before any migration work:
> ```bash
> grep -E "REMOTE_HOST|PREPROD_HOST" .env    # must be two DIFFERENT hosts
> grep -E "REMOTE_|PREPROD_" deploy.sh       # deploy.sh must read PREPROD_*
> ```

> [!CAUTION]
> **NEVER run `deploy.sh` when `PREPROD_*` points to the master content source.**
> If pre-prod is the environment where editors work (e.g. production is not yet live),
> overwriting pre-prod with local data destroys the authoritative content. In this case,
> `PREPROD_*` should remain empty and `deploy.sh` should not be used at all.

## Terminology

| Term | Meaning | Script |
|------|---------|--------|
| **Code deploy** | Deploys application code (PHP/CSS/JS) via CI/CD | `dhq deploy` (DeployHQ), or your CI pipeline |
| **Content sync** | Pulls DB + assets FROM the authoritative source to local | `sync.sh` (via `ddev exec ./sync.sh`) |
| **Content push** | Pushes local DB + assets TO a target environment | `deploy.sh` (via `bash deploy.sh`) |

> "Deploy" alone is ambiguous — always qualify as "code deploy" or "content push."

> [!WARNING]
> **`sync.sh --dry-run` creates — and leaves — a full production DB dump in `/tmp` on the remote server.** The `mysqldump` runs before the dry-run gate; the remote cleanup (`ssh ... rm`) was gated behind `!dry-run`. Every `--dry-run` silently accumulates a complete production database dump on the server. This is a data-at-rest exposure. The fix is to make the remote cleanup unconditional — it must run in both modes since the dump is always created:
> ```bash
> # Cleanup — always remove the remote dump (created even in --dry-run)
> ssh ${REMOTE_USER}@${REMOTE_HOST} "rm -f ${REMOTE_DUMP_PATH}"
> ```
> Audit your local `sync.sh` to confirm cleanup is not gated on dry-run mode.

## ddev lifecycle gotchas

Two ddev container-lifecycle behaviours bite the sync/deploy loop after a restart or power cycle.

> [!WARNING]
> **`ddev poweroff` clears the ssh-agent.** After `ddev poweroff` (or a full restart) the
> ddev-ssh-agent container is removed, so the next `sync.sh` — which needs SSH keys to reach prod —
> fails. Re-run `ddev auth ssh` before syncing. `deploy.sh` uses host SSH, so it's unaffected.

> [!WARNING]
> **OrbStack port forwarding goes stale after `ddev mutagen reset` + `ddev restart`.** The
> `.ddev.site` hostname can return `ERR_CONNECTION_RESET` in the browser even though the containers are
> healthy and router → web is 200 internally — OrbStack's host port forwarding is stale. Fully
> re-initialize it with `ddev poweroff && ddev start`. A direct `127.0.0.1:<port>` (from `ddev describe`)
> often still works as a stopgap — the same loopback fallback the
> [visual-regression-upgrade skill](../visual-regression-upgrade/SKILL.md#when-ddevsite-is-unreachable-use-127001port)
> relies on.
