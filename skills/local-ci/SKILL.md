---
name: local-ci
description: Run the executable test/lint layer locally — PHPUnit, PHPCS, PHPStan, npm lint/build/test, and Python ruff/pytest — auto-fixing where a fixer exists, then reporting pass/fail. Augments LLM code review (/code-review, pr-review-toolkit), which never actually runs tests. USE THIS SKILL when asked to "run ci", "run the tests", "run local ci", "check before opening a PR", "run the checks", "does it pass", or to verify a change before review/merge. Replaces per-project tests.sh scripts. Self-contained — bundles scripts/local-ci.sh.
---

# Local CI

LLM review (`/code-review`, `pr-review-toolkit`) reasons about code but **never executes a test suite**. This skill fills that gap: it detects which check configs a project has and runs the matching checks, the same canonical set `silverstripe/gha-ci` runs in CI — PHPUnit, PHPCS, PHPStan, the npm scripts, and (for Python) ruff + pytest.

It is the executable counterpart to review, not a replacement. Run it, then feed the summary into the review.

## When to use

- After writing a feature, before opening a PR.
- As the test pass alongside `/code-review` or `pr-review-toolkit` — run this first, then review with the results in hand.
- Before `/merge-pr`, to confirm the branch is green locally.

Cadence: `feature-dev` → **`local-ci`** → `/code-review` or `pr-review-toolkit` → `/merge-pr` → `/handoff`.

## What it runs (gating by config presence)

| Check | Fires when present | Command |
|---|---|---|
| dev/build | `vendor/bin/sake` (SilverStripe) | `sake dev/build flush=1` (WARN-only on failure) |
| PHPUnit | `phpunit.xml` / `.dist` | `vendor/bin/phpunit` |
| PHPCS | `phpcs.xml` / `.dist` | `phpcbf` (auto-fix) → `phpcs --standard=…` |
| PHPStan | `phpstan.neon` / `.dist` | `vendor/bin/phpstan analyse` |
| JS lint | `package.json` lint script or eslint config | `eslint --fix` → `npm run lint` |
| JS build | `package.json` build script | `npm run build` |
| JS test | `package.json` test script | `npm test` (npm placeholder script is skipped) |
| Python lint | ruff available + Python project | `ruff check --fix` → `ruff check` |
| Python test | pytest available + tests present | `pytest -q` (no tests → SKIP, not FAIL) |
| Behat | `behat.yml` | **opt-in** via `--with-behat` (needs a browser/driver) |

The legacy `phpmd` / `phploc` / `pdepend` / `phpdox` tools some old `tests.sh` scripts ran are intentionally **not** included — no project CI actually runs them.

## How to run

From the project root:

```bash
bash <path-to-skill>/scripts/local-ci.sh
```

Options:

- `--dry-run` — detect checks and print what *would* run; execute nothing. Use this first on an unfamiliar project to see the plan before anything mutates files or the DB.
- `--no-fix` — report only; do not run phpcbf / eslint --fix / ruff --fix.
- `--no-build` — skip the SilverStripe `sake dev/build` step.
- `--with-behat` — also run Behat (off by default; it needs a browser + chromedriver).
- `DIR …` — one or more dirs to scan. Default: the current dir plus the common
  sub-package dirs `frontend/ client/ backend/ app/` when they exist (handles
  monorepo layouts).

### Execution context

When a project has `.ddev/config.yaml`, **PHP** checks run via `ddev exec` (matches the SilverStripe + DDEV conventions). **JS and Python** checks always run on the host — DDEV web containers rarely carry the node/python toolchain. No flag needed; detection is automatic.

> **Note:** PHP-under-DDEV is supported at **project root**. `ddev exec` always runs from the container's configured working directory (`/var/www/html`), so per-dir `cd` into PHP sub-packages is not propagated into the container. Run from the project root for reliable results.

## Reading the result

The script ends with a `SUMMARY` block listing every check as PASS / FAIL / WARN / SKIP, then an `AUTO-FIX CHANGES` section (`git diff --stat`) showing any files a fixer mutated. Exit code is non-zero if anything FAILed.

When augmenting a review:
1. Run `local-ci.sh` and capture the summary.
2. If auto-fixes changed files, review that diff — those are real edits to your working tree.
3. Carry FAIL/WARN items into the review as concrete findings the LLM pass can then explain or contextualise.

## Notes

- Run `composer install` / dependency install first — if `vendor/` is missing the PHP checks are reported as WARN, not silently skipped.
- The script never commits. Auto-fixes are left in the working tree for you to review and commit.
- A project with no recognised configs reports "nothing to run" rather than erroring.
