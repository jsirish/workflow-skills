---
name: server-deploy
description: Push local databases and assets to a remote pre-prod or staging server using deploy.sh. Use during major version upgrades or when deploying pre-computed public/assets to a staging environment. See server-sync for the reverse direction.
---

# Server Deploy — Push Local → Remote

Pushes local content state (database and assets) from a DDEV environment up to a remote pre-prod or staging server using `deploy.sh`.

> [!WARNING]
> `deploy.sh` is highly destructive. It will **drop and overwrite** the remote database and assets. Always confirm the destination environment before running.

> [!CAUTION]
> **NEVER run `deploy.sh` when `PREPROD_*` points to the master content source.**
> If pre-prod is the environment where editors work (e.g. production is not yet live), overwriting pre-prod with local data destroys the authoritative content. In this case, `PREPROD_*` should remain empty and `deploy.sh` should not be used at all.

## Prerequisites / Safety

> [!IMPORTANT]
> **`deploy.sh` runs on the HOST** (`bash deploy.sh`). It shells out to `ddev exec` internally (to dump the local DB) and validates that **`ddev` is in PATH**. Running it via `ddev exec ./deploy.sh` fails immediately — there is no `ddev` binary inside the container.

```bash
# Push local → pre-prod: runs on the HOST (it calls ddev exec internally)
bash deploy.sh
```

## Environment Configuration (`.env`)

`deploy.sh` reads `PREPROD_*` vars from the project `.env`:

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

> [!CAUTION]
> **`REMOTE_*` and `PREPROD_*` must point at DIFFERENT hosts.** [`sync.sh`](../server-sync/SKILL.md) reads `REMOTE_*` (pull FROM). `deploy.sh` reads `PREPROD_*` (push TO). If both vars resolve to the same host, you pull from pre-prod *and* deploy to pre-prod — production is never touched. Always verify before migration work:
> ```bash
> grep -E "REMOTE_HOST|PREPROD_HOST" .env    # must be two DIFFERENT hosts
> grep "^PREPROD_" deploy.sh                # deploy.sh must read PREPROD_*
> ```

## Command Flags

| Flag | Description |
|------|-------------|
| `--help` | Shows usage information |
| `--dry-run` | Tests the `rsync` without writing to the remote disk or executing the remote DB import. **Note:** the local DB dump and remote push *are* executed even in dry-run mode — only the remote import/restore is skipped. See the [dry-run caution](#dry-run-caution) below. Always recommend running `--dry-run` first. |
| `--assets` | Bypasses the database phase. Only syncs `public/assets/`. |
| `--db` | Bypasses the asset rsync phase. Only dumps and imports the database. |
| `--exclude=PATTERN` | Exclude specific files or globs from the `rsync` cycle (repeat for multiple patterns). Example: `--exclude=*.log --exclude=_resampled/` |

## Script Internal Logic

1. **DB segment:** Dumps the local `SS_DB` to `/tmp`, gzips it, pushes to the remote `/tmp` via `rsync`, then executes `gunzip | mysql` via SSH on the remote to overwrite the target DB.
2. **Cleanup:** Removes the local staging dump and the remote pushed dump from `/tmp`.
3. **Assets segment:** Executes `rsync --delete` to push local `/assets/` to the target server.

> [!TIP]
> Run heavy local computation (e.g. `GalleryResampleTask`) **before** `deploy.sh --assets` to offload processing burden from the remote VPS.

## Dry-Run Caution

> [!WARNING]
> **`--dry-run` creates — and, if cleanup is gated incorrectly, leaves — DB dumps that are never removed.** `deploy.sh` produces **two** dumps during a push: a local staging dump and a copy pushed to the remote `/tmp`. If cleanup is gated on `!dry-run`, every `--dry-run` silently accumulates both dumps — a data-at-rest exposure on both the local host and the remote server.
>
> **Fix:** Make cleanup unconditional for both dumps — they are always created, so they must always be removed:
> ```bash
> # Always remove the local staging dump
> rm -f ${LOCAL_DUMP_PATH}
>
> # Always remove the remote pushed dump
> ssh ${PREPROD_USER}@${PREPROD_HOST} "rm -f /tmp/${LOCAL_DB_NAME}_deploy_${TIMESTAMP}.sql.gz"
> ```
> The dry-run gate should guard only the remote import/restore step. **Audit your local `deploy.sh`** to confirm both cleanup steps are unconditional.

## DeployHQ / Ploi Caveats

`deploy.sh` moves data; the actual code deploy is usually handled by **DeployHQ** (build + SSH) onto a **Ploi**-managed server. These behaviours are not obvious from the scripts.

> [!CAUTION]
> **DeployHQ deploys from the git remote, not your working copy — check for unpushed commits first.**
> If your deploy branch has local commits you haven't pushed, `dhq deploy` silently ships the older remote revision. Run a preflight before every deploy:
> ```bash
> git log origin/<branch>..<branch> --oneline   # must be empty before dhq deploy
> ```

> [!CAUTION]
> **`composer install` skips packages whose constraint is already satisfied.** On a server with an existing `vendor/`, `composer install` will **not** re-fetch a package just because the locked content changed — leaving stale or mismatched code. For a clean parity deploy, wipe first:
> ```bash
> rm -rf vendor && composer install --no-dev -o
> ```
> Add `rm -rf vendor` to the DeployHQ post-deploy SSH command (or build step) so every deploy starts from a clean vendor tree.

> [!WARNING]
> **DeployHQ deletes files that are removed from git.** When a tracked file is de-tracked, DeployHQ deletes it from the server on the next deploy. Keep server-only files (`.env`, secrets, uploaded assets outside `public/assets/`) in DeployHQ's **config files** / **excluded paths** feature, or recreate them out-of-band — never assume a de-tracked file survives on the server.

> [!WARNING]
> **Ploi requires `127.0.0.1`, not `localhost`, as the database server.** On Ploi-managed servers, `localhost` resolves to a MySQL socket path rather than the TCP interface, causing connection failures. Use the TCP loopback in the server `.env`:
> ```text
> # SilverStripe:
> SS_DATABASE_SERVER="127.0.0.1"
> # Other frameworks: set the equivalent DB_HOST / DATABASE_URL host to 127.0.0.1
> ```

## Terminology

| Term | Meaning | Tool |
|------|---------|------|
| **Code deploy** | Deploys application code (PHP/CSS/JS) via CI/CD | `dhq deploy` (DeployHQ), or your CI pipeline |
| **Content sync** | Pulls DB + assets FROM the authoritative source to local | `sync.sh` (via `ddev exec ./sync.sh`) — see [`server-sync`](../server-sync/SKILL.md) |
| **Content push** | Pushes local DB + assets TO a target environment | `deploy.sh` (via `bash deploy.sh`) |

> "Deploy" alone is ambiguous — always qualify as "code deploy" or "content push."
