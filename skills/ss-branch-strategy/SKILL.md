---
name: ss-branch-strategy
description: Establish consistent branch-naming and default-branch conventions across all module repos when executing a major framework or CMS version upgrade. Covers integer branch naming, default-branch promotion, previous-version preservation, and the fork-and-upstream workflow for third-party modules. Use when planning or executing a major version upgrade across a suite of repos.
---

# Major-Version Branch Strategy

**Goal:** Keep branch naming and default-branch setup consistent across all module repos during a major-version upgrade cycle, so old versions stay maintainable while new work proceeds on a clearly-named active branch.

The convention applies regardless of ecosystem (Composer/PHP, npm/Node, pip/Python, etc.). Replace "recipe version" with your ecosystem's concept of a shared dependency version.

---

## Branch Naming

- **Integer version branches are the default branch:** `3`, `4`, `5`, `6`, `7`.
- The branch integer matches the **targeted framework/ecosystem major version** — or the ecosystem's shared package/recipe version if repos version against that rather than their own semver. A module targeting v6 of a framework uses branch `6`; a module versioned against a shared recipe on `3` targeting the same framework major uses branch `3`. Follow whichever the repo already versions against.
- **`master` is deprecated as a default branch.** It may remain for history, but it is not the active dev target. If `master` currently holds the latest content, migrate that content to the correct numbered branch and leave `master` in place.
- **Feature branches** branch off the active version branch — e.g. `fix/accordion-migration` or `feature/v6-upgrade` off `6`.

## Default-Branch Rules

| Target version | Branch name | State |
|---|---|---|
| `v6` | `6` (or ecosystem version, e.g. `3`) | Active development |
| `v5` | `5` (or ecosystem version, e.g. `2`) | Maintenance — backports only |
| `v4` | `4` (or ecosystem version, e.g. `1`) | Frozen / EOL |

## Preserve the Previous Major

- When a new major version ships, create its numbered branch from the current default (e.g. branch `6` from `5`).
- The **previous version branch** stays in the repo for backport fixes (e.g. `5` remains after `6` becomes default).
- **Do not** create long-lived `N.x` branches for versions that are no longer supported. One integer branch per maintained major is enough.

---

## Forking 3rd-Party Modules for New Version Support

When an upstream module lacks support for the target framework/ecosystem version:

1. **Fork** the upstream repo into your org, keeping the original package prefix.
2. Create a **`feature/<target>-upgrade`** branch with the dependency bumps.
3. Push and **open a PR upstream**.
4. **Add a dependency override** to the root project's manifest — e.g. Composer `repositories`, npm `overrides`, or equivalent — to point to the fork. (These overrides are not inherited transitively from shared recipes/configs; they must live in the root project.)
5. The override makes the fork replace the upstream package. If/when the upstream merges and tags a release, switch back to the registry and drop the override entry.

---

## Auto-Merge on Integer Default Branches

Auto-merge (`gh pr merge --auto`, the GitHub "Enable auto-merge" button) is **not** gated on
the branch being named `master`/`main`. It works against any default branch — `6`, `5`, `3` —
provided the repo is configured for it. If auto-merge "doesn't work," the cause is almost
always a missing repo setting, not the branch name. Do **not** switch the default branch to
`master` to make auto-merge work.

Prerequisites (per repo):

1. **Enable "Allow auto-merge"** in repo settings — the most common missing piece:
   `gh api -X PATCH repos/<owner>/<repo> -F allow_auto_merge=true`
2. **Branch protection on the integer default branch** with at least one requirement (a
   required status check or required review). Without a protection rule, `--auto` errors and
   you must use a plain `gh pr merge --squash` instead. The `merge-pr` skill already resolves
   the default branch dynamically, so plain squash-merge works against `6`/`5`/`3` today.

---

## Applying the Strategy to a Repo

1. **Identify the versioning basis** — does this repo version against a shared recipe/manifest number or its own semver? Check existing branch names and the package manifest.
2. **Migrate `master` if it holds active content.** If `master` is the current default and already carries the latest content, create the numbered branch *from* `master` so no history is lost, then leave `master` in place for history. Otherwise, create the new numbered branch from the current default for the new major.
3. **Set it as the default branch** in GitHub settings; keep the previous version branch for backports.
4. **Update CI configs** (GitHub Actions or equivalent) to target the new default branch.
5. **Update the package manifest:**
   - Branch aliases — e.g. Composer `"extra": { "branch-alias": { "dev-6": "6.x-dev" } }` or npm `"version": "6.0.0-dev"`.
   - Dependency constraints use a dev/pre-release specifier for the new major during the upgrade (e.g. `^6@dev` in Composer, `^6.0.0-alpha` in npm semver).
6. **Declare dependency overrides** in the root project manifest for any 3rd-party modules being upgraded via a fork.

---

## Checklist

- [ ] Default branch is an integer matching the ecosystem/recipe major (not `master`, not the module's own semver)
- [ ] Any active content on `master` migrated to a numbered branch; `master` left in place for history
- [ ] Previous major's branch retained for backports
- [ ] No stray long-lived `N.x` branches for unsupported versions
- [ ] CI configs point at the new default branch
- [ ] Package manifest branch-alias and constraints updated for dev stability on the new major
- [ ] Fork dependency overrides declared in the **root** project manifest, not a shared recipe
- [ ] `allow_auto_merge` enabled on the repo (auto-merge is branch-name-agnostic — never switch to `master` for it)

---

## Example: Silverstripe CMS + Dynamic Essentials

The following illustrates the convention for the Dynamic Essentials Silverstripe ecosystem,
where module repos version against the recipe number rather than the CMS version.

### Reference mapping — Essentials product line

Recipe/module repos version against the **recipe** number, not the CMS number:

| Module | SS6 Branch | SS5 Branch | Notes |
|--------|-----------|-----------|-------|
| recipe-silverstripe-essentials-website | `3` (default) | `2` | Recipe version, not CMS |
| silverstripe-essentials-tools | `3` (default) | `2` | |
| silverstripe-elemental-accordion | `6` (default) | `5` | Module's own major |
| silverstripe-elemental-embedded-code | `4` | `master` | |
| silverstripe-elemental-sponsors | `5` (default) | `master` | |
| silverstripe-elemental-templates | `3` (default) | `2` | |

### Example repo: `dynamic/silverstripe-elemental-accordion`

| Branch | CMS Version | Status |
|--------|-------------|--------|
| `5` | SS5 | Maintenance (backports only) |
| `6` | SS6 | Active development (default) |

### Silverstripe fork workflow

1. Fork the upstream repo into the `dynamic/` GitHub org, keeping the `silverstripe-` prefix.
2. Create a `feature/ss6-upgrade` branch with the dependency bumps.
3. Push and open a PR upstream.
4. Add a **VCS repo** entry for the fork to the **root project** `composer.json` (VCS repos are not inherited transitively from recipes — they must live in the root project).
5. Composer's VCS-repo priority makes the fork replace the upstream package. When the upstream merges and tags a release, switch back to Packagist and drop the VCS entry.

For Composer specifically, the manifest steps are:
- Branch aliases — e.g. `"extra": { "branch-alias": { "dev-master": "6.x-dev" } }` (or alias the numbered branch, e.g. `"dev-6": "6.x-dev"`).
- Recipe constraints use `^6@dev` for SS6 branches to allow dev stability during the upgrade.
