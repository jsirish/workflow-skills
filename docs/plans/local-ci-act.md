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
- **Detection:** `.github/workflows/ci.yml` or `ci.yaml` exists; the resolved path is what gets
  passed to `-W`. With no flag, record a SKIP row `act[<dir>]: ci.yml (pass --with-act to run it
  under act)`, the same shape as `shell[<dir>]: shellcheck (no .shellcheckrc - pass --with-shellcheck
  to force)`.
- **Reusable workflows:** a workflow with a job-level `uses: .../.github/workflows/...` records
  `act[<dir>]: ci.yml (reusable workflow: matrix service containers bind fixed host ports and
  collide under act)` as a SKIP. The `act[<dir>]:` prefix is required so the row satisfies the
  "config recognised but nothing recorded" check. Only `silverstripe/gha-ci` was measured; other
  reusable workflows are skipped on the same rule until one is shown to run.
- **`--with-act`:** run `act <event> -W <resolved ci path>`. Event is `pull_request` if the
  workflow declares it, else `push`.
  - Runner image: pass `-P <label>=catthehacker/ubuntu:act-latest` for every `ubuntu-*` label in
    the workflow's `runs-on`, so none falls back to the actrc mapping. The default actrc maps
    `ubuntu-latest` to `node:16-buster-slim`, which cannot run PHP workflows. WARN on a
    `runs-on` label that can't be mapped, since act skips an unmapped job and the run would
    otherwise record PASS with nothing executed.
  - `--container-architecture linux/amd64` on arm64 hosts.
  - Secrets: collect `secrets.NAME` references from the workflow; pass `-s NAME` for each one set in
    the environment (act reads the value from env, so it never appears in argv). WARN, names only,
    for missing ones. Map `GITHUB_TOKEN` from `gh auth token` when unset.
  - Missing `act` or a stopped Docker daemon is a WARN, not a silent skip.
  - Result is PASS, or WARN (FAIL with `--strict`), recorded as `act[<dir>]: ci.yml`.
- **`--act-only`:** implies `--with-act`. The native drivers are skipped only for a dir whose act
  run actually executed the workflow (PASS, or a failure from the workflow itself). If act WARNed
  for a precondition (missing binary, Docker stopped, unmapped runner), the native drivers still
  run, so the flag can't end a run with nothing executed. Each skipped driver records
  `<PREFIX>[<dir>]: skipped (--act-only)`. act runs from the repo root and covers the whole repo,
  so the subdirectory scans (`frontend/`, `client/`, `backend/`, `app/`) are skipped too when it
  ran.
- **Docker Hub:** act force-pulls every image. A rejected stored login or an IP throttle
  (`too many failed login attempts`) fails the run. With images cached locally, pass `--pull=false`.
  Base images can be pulled from `mirror.gcr.io/library/<image>` and tagged locally.
- **`--dry-run`:** records a `PLAN` row carrying the exact act command, by going through
  `run_check` with the `gate` category. It does not call `gh auth token` or probe Docker. The
  status marker and push gate are unchanged.

## Work

1. Driver in `skills/local-ci/scripts/local-ci.sh`, modeled on `sh_checks` (`--with-shellcheck`):
   SKIP when the flag is absent, WARN when adopted but the binary is missing. `--with-behat` is
   not the model; it does nothing when its binary is missing.
2. Wire the driver into the reconcile check: call `mark_config_seen act "$d"` and add an
   `act) prefix=act` case to the `case "$driver"` block, so a silent act driver is caught.
3. `skills/local-ci/SKILL.md`: table row, flags, act-vs-native note.
4. Tests, alongside the existing `tests/local-ci-*.sh`: `--dry-run` command shape and `PLAN` row,
   secret handling, reusable-workflow SKIP row prefix, `ci.yaml` detection, unmapped `runs-on`
   WARN, missing-act and stopped-Docker WARN, `--strict` escalation, `--act-only` skip rows and
   its fall-through when act only WARNed.
