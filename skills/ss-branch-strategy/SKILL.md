---
name: ss-branch-strategy
description: Use when planning or executing a Silverstripe CMS major version upgrade across module repos (SS3→SS4→SS5→SS6+) — establishes the branch naming convention, default-branch rules, previous-version preservation, and the fork workflow for upstreaming SS6 support to 3rd-party modules.
---

# Silverstripe Module Branch Strategy

**Goal:** Keep branch naming and default-branch setup consistent across all Silverstripe module repos during a major CMS upgrade cycle, so old versions stay maintainable while new work proceeds on a clearly-named active branch.

This applies whenever a module must support the current stable CMS version and the next major version simultaneously (SS3→SS4, SS4→SS5, SS5→SS6, and onward).

---

## Branch Naming

- **Integer version branches are the default branch:** `3`, `4`, `5`, `6`, `7`.
- The integer matches the **recipe** or **CMS major version** the module targets — **not** the module's own semver. A module on recipe version `3` that targets SS6 uses branch `3`; an elemental block on its own major `6` that targets SS6 uses branch `6`. Follow whichever the repo already versions against.
- **`master` is deprecated as a default branch.** It may remain for history, but it is not the active dev target. If `master` currently holds the latest (e.g. SS6) content, migrate that content to the correct numbered branch and leave `master` in place.
- **Feature branches** branch off the active version branch — e.g. `fix/accordion-migration` or `feature/ss6-upgrade` off `6`.

## Default-Branch Rules

| CMS Version | Default Branch | Status |
|-------------|----------------|--------|
| SS6 | `6` (or recipe version, e.g. `3`, `4`) | Active development |
| SS5 | `5` (or recipe version, e.g. `2`, `3`) | Maintenance — backports only |
| SS4 | `4` (or recipe version, e.g. `1`, `2`) | Frozen / EOL |

## Preserve the Previous Major

- When a new major CMS version ships, create its numbered branch from the current default (e.g. branch `6` from `5`).
- The **previous version branch** stays in the repo for backport fixes (e.g. `5` remains after `6` becomes default).
- **Do not** create long-lived `N.x` branches for versions that are no longer supported. One integer branch per maintained major is enough.

### Example: `dynamic/silverstripe-elemental-accordion`

| Branch | CMS Version | Status |
|--------|-------------|--------|
| `5` | SS5 | Maintenance (backports only) |
| `6` | SS6 | Active development (default) |

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

---

## Forking 3rd-Party Modules for SS6 Support

When an upstream module lacks support for the target CMS version:

1. **Fork** the upstream repo into the `dynamic/` GitHub org, keeping the `silverstripe-` prefix.
2. Create a **`feature/ss6-upgrade`** branch with the dependency bumps.
3. Push and **open a PR upstream**.
4. **Add a VCS repo** entry for the fork to the **root project** `composer.json` (VCS repos are not inherited transitively from recipes — they must live in the root project).
5. Composer's VCS-repo priority makes the fork replace the upstream package. If/when the upstream merges and tags a release, switch back to Packagist and drop the VCS entry.

---

## Applying the Strategy to a Repo

1. **Identify the versioning basis** — does this repo version against the recipe number or its own major? Check existing branch names and `composer.json` constraints.
2. **Create the new numbered branch** from the current default for the new CMS major.
3. **Set it as the default branch** in GitHub settings; keep the previous version branch for backports.
4. **Update CI configs** (GitHub Actions) to target the new default branch.
5. **Update `composer.json`:**
   - Branch aliases — e.g. `"extra": { "branch-alias": { "dev-master": "6.x-dev" } }` (or alias the numbered branch, e.g. `"dev-6": "6.x-dev"`).
   - Recipe constraints use `^6@dev` for SS6 branches to allow dev stability during the upgrade.
6. **Declare fork VCS repos** in the root project `composer.json` for any 3rd-party modules being upgraded via a fork.

---

## Checklist

- [ ] Default branch is an integer matching the recipe/CMS major (not `master`, not the module semver)
- [ ] Previous major's branch retained for backports
- [ ] No stray long-lived `N.x` branches for unsupported versions
- [ ] CI configs point at the new default branch
- [ ] `composer.json` branch-alias and constraints updated (`^6@dev` for dev stability)
- [ ] Fork VCS repos declared in the **root** project `composer.json`, not a recipe
