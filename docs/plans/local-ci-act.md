# local-ci: opt-in `act` driver

Status: planned, not implemented. Tracked in Teamwork task 49204702 (syncs to a GitHub issue).

## Goal

When a repo has `.github/workflows/ci.yml`, let `/local-ci` run that workflow locally with
[nektos/act](https://github.com/nektos/act) as an opt-in fidelity check, next to the native drivers.

## Decision

`act` is opt-in. It does not replace the native drivers, and a `ci.yml` does not suppress them.

- Stale workflows (old PHP/MySQL versions, deprecated actions) fail for reasons unrelated to the change.
- amd64 emulation on Apple Silicon, service containers, and a fresh dependency install take minutes;
  the native checks take seconds.
- The native drivers provide DDEV routing, auto-fix, per-check SUMMARY rows, and WARN/`--strict` semantics.
- Secrets differ per repo and have to be plumbed in.

## What works under act

Measured with act 0.2.89, `catthehacker/ubuntu:act-latest`, `--container-architecture linux/amd64`:

| Workflow | Result |
|---|---|
| Plain node workflow (`daisy-webhooks`: `tsc` + `npm test`) | Passes, about 84s |
| Python workflow with a private dependency (`daisy-gateway`) | Runs; `-s GH_TOKEN` reaches the job and stays out of the log; reports the same failure GitHub does |
| `silverstripe/gha-ci` reusable workflow (SS modules) | Does not run reliably. The Context, matrix and governance jobs pass, but every PHPUnit/lint matrix job fails at "Set up job" with `port is already allocated`: gha-ci binds fixed host ports for its service containers and the matrix legs collide. `--concurrent-jobs 1` does not prevent it. |

## Design

- **Scope:** `ci.yml` / `ci.yaml` only. Never `docker-publish.yml`, `release.yml`, `add-to-project.yml`.
  DAISY image builds stay on Actions.
- **Detection:** `.github/workflows/ci.yml` exists. With no flag, record a SKIP row
  `act[<dir>]: ci.yml present, run with --with-act`.
- **Reusable workflows:** a `ci.yml` with a job-level `uses: .../.github/workflows/...` records
  `SKIP: reusable workflow not supported under act`.
- **`--with-act`:** run `act <event> -W .github/workflows/ci.yml`. Event is `pull_request` if the
  workflow declares it, else `push`.
  - Runner image: pass `-P ubuntu-latest=catthehacker/ubuntu:act-latest`. The default actrc maps
    `ubuntu-latest` to `node:16-buster-slim`, which cannot run PHP workflows; WARN when the user's
    actrc does.
  - `--container-architecture linux/amd64` on arm64 hosts.
  - Secrets: collect `secrets.NAME` references from the workflow; pass `-s NAME` for each one set in
    the environment (act reads the value from env, so it never appears in argv). WARN, names only,
    for missing ones. Map `GITHUB_TOKEN` from `gh auth token` when unset.
  - Missing `act` or a stopped Docker daemon is a WARN, not a silent skip.
  - Result is PASS, or WARN (FAIL with `--strict`), recorded as `act[<dir>]: ci.yml`.
- **`--act-only`:** implies `--with-act`; skips the native drivers for dirs where act ran.
- **Docker Hub:** act force-pulls every image. A rejected stored login or an IP throttle
  (`too many failed login attempts`) fails the run. With images cached locally, pass `--pull=false`.
  Base images can be pulled from `mirror.gcr.io/library/<image>` and tagged locally.
- `--dry-run` prints the exact act command. The status marker and push gate are unchanged.

## Work

1. Driver in `skills/local-ci/scripts/local-ci.sh`, following `--with-behat` / `--with-shellcheck`
   and the `.local-ci.json` recording helpers.
2. `skills/local-ci/SKILL.md`: table row, flags, act-vs-native note.
3. Tests: `--dry-run` command shape, secret handling, reusable-workflow SKIP, missing-act and
   stopped-Docker WARN, `--strict` escalation.
