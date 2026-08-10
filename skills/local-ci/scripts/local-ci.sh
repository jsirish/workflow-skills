#!/usr/bin/env bash
#
# local-ci.sh — run the executable test/lint layer that LLM review can't.
#
# Detects which check configs a project has and runs the matching checks,
# auto-fixing where a fixer exists (then re-checking), and prints a pass/fail
# summary. Mirrors the canonical silverstripe/gha-ci set (phpunit, phpcs,
# phpstan) plus npm scripts, Python (ruff, pytest), shell scripts (shellcheck),
# and project-declared custom checks (.local-ci.json).
#
# Usage:
#   local-ci.sh [options] [DIR ...]
#
# Options:
#   --no-fix           Do not run auto-fixers (phpcbf / eslint --fix / ruff --fix);
#                      report only.
#   --no-build         Skip the SilverStripe `sake dev/build` step.
#   --strict           Escalate EVERY check to FAIL on a non-zero exit —
#                      restores hard-gating for the whole run. Implies
#                      --strict-build and --strict-lint.
#   --strict-build     Treat a failing `sake dev/build` as FAIL (default: WARN).
#                      A subset of --strict.
#   --strict-lint      Treat failing phpcs/phpstan/eslint lint as FAIL
#                      (default: WARN). A subset of --strict. Every other
#                      check (phpunit, composer install, JS/Python/shell/
#                      custom checks, dev/build) is ALSO WARN-by-default now
#                      — use --strict-build / --strict / plain --strict for
#                      those, not --strict-lint.
#   --fresh-deps       Force a real `composer install` even when vendor/ exists
#                      (mirrors GHA's clean-install behaviour; slower, mutates vendor/).
#   --with-behat       Also run Behat (behat.yml) — opt-in; needs a browser/driver.
#   --with-shellcheck  Force shellcheck even without a .shellcheckrc or a
#                      shell-only project layout — opt-in.
#   --dry-run          Detect checks and print what WOULD run; execute nothing.
#   -h, --help         Show this help.
#
# DIR ...   One or more project dirs to scan (default: current dir, plus the
#           common sub-package dirs frontend/ client/ backend/ app/ if present).
#
# Execution context: when a project has .ddev/config.yaml, PHP checks run via
# `ddev exec` and composer via `ddev composer`. JS and Python checks always run
# on the host (DDEV containers rarely carry the node/python toolchain).
# Override host vs ddev is automatic.
#
# By default every check reports at most WARN — a no-flag run is advisory and
# exits 0 even with real test/build failures; read the SUMMARY, not just the
# exit code. Pass --strict (or a scoped --strict-* variant) to make a run
# gate: non-zero exit if anything FAILs. A broken local-ci setup (malformed
# .local-ci.json, missing "run" key) is always a hard FAIL, regardless of
# --strict — that's not a finding, it's local-ci itself being unable to run.
#
# Exit code: non-zero if any check FAILed (only possible by default via a
# broken-config error above; otherwise only under --strict/-build/-lint).

set -uo pipefail

# ----- options -----------------------------------------------------------
DO_FIX=1
DO_BUILD=1
STRICT=0
STRICT_BUILD=0
STRICT_LINT=0
FRESH_DEPS=0
WITH_BEHAT=0
WITH_SHELLCHECK=0
DRY=0
DIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --no-fix)           DO_FIX=0 ;;
    --no-build)         DO_BUILD=0 ;;
    --strict)           STRICT=1 ;;
    --strict-build)     STRICT_BUILD=1 ;;
    --strict-lint)      STRICT_LINT=1 ;;
    --fresh-deps)       FRESH_DEPS=1 ;;
    --with-behat)       WITH_BEHAT=1 ;;
    --with-shellcheck)  WITH_SHELLCHECK=1 ;;
    --dry-run)          DRY=1 ;;
    -h|--help)          awk 'NR==1{next} /^#/{print; next} /^$/{next} {exit}' "$0"; exit 0 ;;
    --*)                echo "Unknown option: $1" >&2; exit 2 ;;
    *)                  DIRS+=("$1") ;;
  esac
  shift
done

ROOT="$(pwd)"

# ----- result tracking ---------------------------------------------------
# Checks run in subshells (per-dir cd), so results go to a temp file that
# survives the subshell boundary rather than an in-memory array.
RESULTS_FILE="$(mktemp -t local-ci.XXXXXX)"
# Ledger of shellcheck'd files (absolute paths), so the same file is never
# linted (and reported) twice when DIRS has overlapping entries — e.g. "."
# and "frontend" when frontend/ is both its own DIRS entry and already
# picked up by the root scan (git ls-files '*.sh' matches at any depth).
SH_SEEN_FILE="$(mktemp -t local-ci-sh-seen.XXXXXX)"
trap 'rm -f "$RESULTS_FILE" "$SH_SEEN_FILE"' EXIT

record() { # status label
  printf '%s\t%s\n' "$1" "$2" >> "$RESULTS_FILE"
}

# Central executor — in --dry-run, echo the command and succeed; else run it.
X() {
  if [ "$DRY" -eq 1 ]; then
    printf '   \033[90m[dry-run] %s\033[0m\n' "$*"
    return 0
  fi
  "$@"
}

# Pretty header
hdr() {
  printf '\n\033[1m========================================================================\033[0m\n'
  printf '\033[1m %s\033[0m\n' "$1"
  printf '\033[1m========================================================================\033[0m\n'
}

# Resolve the effective severity for a check <category> given the strict
# flags for this run. Every check is WARN-by-default; --strict escalates
# every category to FAIL in one flag, while --strict-build/--strict-lint
# escalate just their own category (subsets of --strict).
#   gate  -> the checks that hard-FAILed before this issue (phpunit, composer
#            install, JS install/build/test, ruff, pytest, shellcheck, custom)
#   build -> sake dev/build
#   lint  -> phpcs / phpstan / JS lint
effective_sev() { # category
  case "$1" in
    lint)  if [ "$STRICT" -eq 1 ] || [ "$STRICT_LINT" -eq 1 ]; then echo FAIL; else echo WARN; fi ;;
    build) if [ "$STRICT" -eq 1 ] || [ "$STRICT_BUILD" -eq 1 ]; then echo FAIL; else echo WARN; fi ;;
    gate)  if [ "$STRICT" -eq 1 ]; then echo FAIL; else echo WARN; fi ;;
    *)     echo FAIL ;;
  esac
}

# Record PASS/<severity> for a check that already ran, given its <category>.
# Used both by run_check (below) and by inline checks that don't shell out
# through it (composer validate/install). The WARN message names the exact
# flag(s) that would escalate this specific category, not just bare --strict
# — re-running with --strict also escalates the other two categories, which
# surprises anyone who only meant to gate on, say, lint.
record_sev() { # label category
  local label="$1" category="$2" hint
  if [ "$(effective_sev "$category")" = WARN ]; then
    case "$category" in
      lint)  hint="--strict-lint or --strict" ;;
      build) hint="--strict-build or --strict" ;;
      *)     hint="--strict" ;;
    esac
    record WARN "$label (not gating; re-run with $hint to gate)"
  else
    record FAIL "$label"
  fi
}

# Run a command, record PASS/<severity> under a label. Extra args after label
# are the command. Honours the per-dir PHP runner prefix already baked into
# the command. <category> (lint/build/gate) resolves to WARN or FAIL via
# effective_sev — every check is WARN-by-default; pass --strict (or the
# matching --strict-* variant) to gate on it. Returns 1 on a non-PASS result
# (regardless of whether it was recorded as WARN or FAIL) so a caller that
# needs to know "did the underlying command actually succeed" — e.g. to
# decide whether skipping dependent checks is warranted — doesn't have to
# infer it from a side effect (a directory existing, a file being written).
run_check() { # label category cmd...
  local label="$1" category="$2"; shift 2
  hdr "$label"
  if [ "$DRY" -eq 1 ]; then
    printf '   \033[90m[dry-run] %s\033[0m\n' "$*"
    record PLAN "$label"
    return 0
  fi
  if "$@"; then
    record PASS "$label"
    return 0
  fi
  record_sev "$label" "$category"
  return 1
}

# ----- detect candidate dirs --------------------------------------------
if [ "${#DIRS[@]}" -eq 0 ]; then
  DIRS=(".")
  for sub in frontend client backend app; do
    [ -d "$sub" ] && DIRS+=("$sub")
  done
fi

# ----- PHP runner (ddev-aware) ------------------------------------------
# If $1 is a live git checkout nested under a vendor/ path whose enclosing
# project has its own .ddev/config.yaml (e.g. a SilverStripe module
# developed in place inside vendor/dynamic/<pkg>, rather than a plain
# composer-installed package), prints "<root>\t<abs>" (the enclosing
# project's root and $1's own absolute path - both already resolved here so
# php_prefix doesn't need a second cd+pwd to get the same $1 resolved
# again). Deliberately narrow - a targeted "find the vendor/ boundary"
# computation, not a generic ancestor walk - so it: (a) never affects the
# default frontend/client/backend/app scan dirs (they aren't under
# vendor/, so this returns nothing for them and they keep their
# pre-existing bare-metal behavior unchanged), and (b) can't cross into an
# unrelated ancestor project's .ddev/config.yaml above the real project
# boundary (there's only ever one candidate root to check: the dir
# immediately enclosing vendor/).
# Known limitation, not fixed: only one level of vendor/ nesting is
# checked. A live checkout nested inside ANOTHER live checkout's own
# vendor/ (module-in-module, itself with no .ddev/config.yaml) resolves
# root to the inner module - not a real composer/ddev boundary - and
# silently falls back to bare metal with no WARN. Rare enough (a module
# developed in place inside another module developed in place) to accept
# rather than generalize into the ancestor walk this function's own
# single-boundary design deliberately avoids (see above).
ddev_root_for() { # dir
  local abs; abs="$(cd "$1" 2>/dev/null && pwd)" || return 0
  [ -z "$abs" ] && return 0
  { [ -d "$abs/.git" ] || [ -f "$abs/.git" ]; } || return 0  # must be its own checkout
  case "$abs" in
    */vendor/*) : ;;
    *) return 0 ;;
  esac
  local root="${abs%/vendor/*}"  # nearest enclosing vendor/, not the leftmost
  { [ -f "$root/composer.json" ] || [ -f "$root/composer.lock" ]; } || return 0  # real composer boundary, not a coincidental vendor/ dir
  [ -f "$root/.ddev/config.yaml" ] || return 0
  # ddev's own project name, not assumed from the dir basename (they can
  # differ) - needed so php_prefix can pin the target project explicitly
  # rather than let `ddev exec` guess it from the invoking shell's cwd.
  local name; name="$(sed -n 's/^name:[[:space:]]*//p' "$root/.ddev/config.yaml" | head -1 | tr -d '"'"'"'\r')"
  [ -n "$name" ] && printf '%s\t%s\t%s\n' "$root" "$abs" "$name"
}

# Echoes the command prefix for PHP tools given a project dir.
#   - dir is a nested vendor/ live checkout under a DIFFERENT project's ddev
#     root (see ddev_root_for above) -> "ddev exec -p <root-project-name> -d
#     /var/www/html/<relpath-from-root>". Both -p and the absolute container
#     path are required, not just convenience: `ddev exec` resolves WHICH
#     project to target by walking up from the INVOKING SHELL's cwd to the
#     nearest .ddev/config.yaml - it does not derive that from -d's value at
#     all. Every caller of this prefix runs from within `dir` itself (a `cd
#     "$d"` already happened), so if `dir` has its own .ddev/config.yaml
#     (exactly the case the PHP-version-mismatch WARN below anticipates),
#     an unpinned `ddev exec -d <relpath>` would silently target THAT
#     project's own separate container instead of the enclosing one -
#     verified directly against a real nested ddev fixture, not assumed:
#     without -p it started the module's own container; with -p it
#     correctly targeted the enclosing project's, even invoked from inside
#     the nested dir. Once -p pins the project, -d must be an absolute path
#     inside the CONTAINER, not host-relative - DDEV's fixed approot mount
#     (independent of any docroot setting), since a relative -d value is
#     resolved against the container's own cwd, not wherever the host
#     shell happens to be.
#   - dir IS a ddev project root         -> "ddev exec"
#   - neither                            -> "" (bare metal / no ddev)
php_prefix() { # dir
  local hit; hit="$(ddev_root_for "$1")"
  if [ -n "$hit" ]; then
    local root abs name
    root="${hit%%$'\t'*}"
    abs="${hit#*$'\t'}"; abs="${abs%%$'\t'*}"
    name="${hit##*$'\t'}"
    echo "ddev exec -p $name -d /var/www/html/${abs#"$root"/}"
    return
  fi
  if [ -f "$1/.ddev/config.yaml" ] || { [ "$1" = "." ] && [ -f ".ddev/config.yaml" ]; }; then
    echo "ddev exec"
  else
    echo ""
  fi
}

# Under DDEV, use "ddev composer" at the project root — it handles container
# mounts / mutagen sync correctly. For a nested subdir (a "ddev exec -p
# <name> -d <path>" prefix rather than the bare "ddev exec"), compose
# against that same scoped, pinned exec instead — "ddev composer" always
# targets the CWD-detected project's own composer.json, not a --dir-scoped
# location within an explicitly pinned one. Takes the already-computed
# prefix rather than re-deriving it, so callers that need both the
# prefix and the composer command only resolve ddev_root_for once per dir.
# Known limitation, not fixed: the nested-subdir "$pp composer" (plain
# `ddev exec -p <name> -d <path> composer`) doesn't have the same explicit
# mutagen-sync-flush behaviour the "ddev composer" wrapper does - there is
# no such wrapper for a directory-scoped call, since "ddev composer" itself
# can't be scoped to a subdirectory. On a Mutagen-backed DDEV project this
# could in principle let a host-side vendor/bin/* check run before the
# container's install output is fully synced. Accepted as an inherent
# property of using ddev exec for directory-scoped work, not something
# local-ci can route around.
composer_cmd_for_prefix() { # prefix
  local pp="$1"
  if [ "$pp" = "ddev exec" ]; then
    echo "ddev composer"
  elif [ -n "$pp" ]; then
    echo "$pp composer"
  elif command -v composer >/dev/null 2>&1; then
    echo "composer"
  else
    echo ""
  fi
}

first_existing() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }

# ===== PHP / SilverStripe ================================================
php_checks() { # dir
  local d="$1"
  ( cd "$d" || return 0
    [ -f composer.json ] || return 0

    # Resolved once per dir (not re-derived independently for composer vs.
    # the PHP tool runner below) - ddev_root_for does real filesystem work,
    # and if it were called twice with a composer install running in
    # between, the two calls could disagree if that install happened to
    # scaffold a stray .ddev/config.yaml into this dir. The flip side of
    # that same choice: this snapshot is taken BEFORE composer install
    # runs, so if install itself is what scaffolds a stray
    # .ddev/config.yaml here, dev/build/phpunit/phpcs/phpstan below still
    # use the pre-install routing for the rest of this run - consistent
    # with the composer step (both use the same pre-install snapshot)
    # rather than each tool independently re-deriving it, which is the
    # tradeoff this "once" design deliberately accepts.
    # Known limitation, not fixed: $PRE ("ddev exec -p <name> -d <path>") is
    # spliced unquoted into run() and every composer/phpcs/phpunit/phpstan
    # bash -c string below, so unquoted-expansion hazards apply to the ddev
    # project name and <relpath> alike - not just a space word-splitting
    # into extra tokens, but any shell glob character (*, ?, [) undergoing
    # pathname expansion against whatever happens to be in the working
    # directory. Accepted rather than reworked into an array threaded
    # through every call site: ddev itself rejects project names containing
    # spaces or glob characters, and composer vendor/<vendor-slug>/<package-slug> paths are
    # never space-containing in practice.
    local PRE; PRE="$(php_prefix .)"
    run() { if [ -n "$PRE" ]; then X $PRE "$@"; else X "$@"; fi; }
    # Single source of truth for "did this dir get routed into a different
    # (enclosing) project's DDEV container" - computed once here rather
    # than each WARN site below independently pattern-matching the literal
    # "ddev exec -p " prefix against PRE/CC, which could silently drift out
    # of sync with php_prefix's actual output format.
    local NESTED=0
    case "$PRE" in "ddev exec -p "*) NESTED=1 ;; esac
    
    # When NESTED=1, capture the enclosing project root to use its vendor/bin
    local ENCLOSING_ROOT=""
    local ENCLOSING_VENDOR_BIN=""
    if [ "$NESTED" -eq 1 ]; then
      local hit; hit="$(ddev_root_for .)"
      if [ -n "$hit" ]; then
        ENCLOSING_ROOT="${hit%%$'\t'*}"
        ENCLOSING_VENDOR_BIN="$ENCLOSING_ROOT/vendor/bin"
      fi
    fi
    
    # Helper to select correct vendor/bin path
    # When routed into an enclosing project's DDEV container (NESTED=1), use the
    # enclosing project's vendor/bin/ rather than the nested checkout's own.
    # The nested checkout may have its own vendor/ from a standalone composer install,
    # but that's disconnected from the DDEV DB and will fail with connection errors.
    # The enclosing project's vendor/bin uses the correct DB configuration.
    #
    # Two variables, not one, because "where the binary lives" and "where the
    # command that invokes it executes" are different filesystems when nested:
    #   - VENDOR_BIN (host-side): used by the [ -x ... ] existence guards and
    #     WARN text below, which run on the host against the enclosing
    #     project's real absolute path.
    #   - VENDOR_BIN_RUN (exec-side): used by the actual tool invocations.
    #     When NESTED, $PRE routes those into the enclosing project's
    #     container via `ddev exec`, where the host path doesn't exist -
    #     DDEV's fixed approot mount is /var/www/html (the same constant
    #     php_prefix above builds its -d value from). Non-nested, both
    #     variables are the same relative "vendor/bin".
    local VENDOR_BIN="vendor/bin"
    local VENDOR_BIN_RUN="vendor/bin"
    if [ "$NESTED" -eq 1 ] && [ -n "$ENCLOSING_VENDOR_BIN" ]; then
      VENDOR_BIN="$ENCLOSING_VENDOR_BIN"
      VENDOR_BIN_RUN="/var/www/html/vendor/bin"
    fi

    # Routed into an enclosing project's ddev container (see ddev_root_for)
    # while this dir also ships its own .ddev/config.yaml: by design the
    # enclosing project wins (real dependency/DB env beats a standalone
    # container for a module developed in place), but that can silently run
    # checks against a different PHP version than the module's own config
    # targets. Surface it as a runtime signal rather than a silent choice.
    if [ "$NESTED" -eq 1 ] && [ -f .ddev/config.yaml ]; then
      record WARN "PHP[$d]: routed into the enclosing project's DDEV container, but this dir has its own .ddev/config.yaml (possible PHP-version mismatch - see SKILL.md)"
    fi

    # --- composer: validate + install ------------------------------------
    local CC; CC="$(composer_cmd_for_prefix "$PRE")"
    if [ -z "$CC" ]; then
      record SKIP "PHP[$d]: composer (no composer binary found)"
      [ -d vendor ] || { record WARN "PHP[$d]: vendor/ missing — install dependencies first"; return 0; }
    else
      # Manifest + lock consistency. --strict surfaces recommendation-level
      # warnings (loose version constraints, a stray `version` field, etc.)
      # on top of real problems (malformed json, out-of-sync lock) — and
      # both share the same non-zero exit code, so a --strict failure alone
      # can't tell them apart. If --strict fails, re-check without it: a
      # plain `composer validate` still exits non-zero for real corruption
      # but exits 0 when the only issue was a --strict-only warning. That
      # lets a genuine error stay a hard FAIL while cosmetic warnings WARN.
      # --no-check-publish avoids spurious noise on private modules missing
      # name/license publish metadata.
      hdr "PHP[$d]: composer validate"
      if [ "$DRY" -eq 1 ]; then
        printf '   \033[90m[dry-run] %s\033[0m\n' "$CC validate --strict --no-check-publish"
        record PLAN "PHP[$d]: composer validate"
      elif bash -c "$CC validate --strict --no-check-publish"; then
        record PASS "PHP[$d]: composer validate"
      elif bash -c "$CC validate --no-check-publish" >/dev/null 2>&1; then
        record WARN "PHP[$d]: composer validate (strict warnings — not gating)"
      else
        record_sev "PHP[$d]: composer validate" gate
      fi

      if [ "$FRESH_DEPS" -eq 1 ] || [ ! -d vendor ]; then
        # A dir routed through "ddev exec -p <name> -d <path>" (nested under
        # a different DDEV project root - see php_prefix above) with no
        # vendor/ yet is about to run its own first composer install. This
        # now happens inside the real DDEV container instead of bare metal,
        # but it still runs the module's own composer.json - if it declares
        # require-dev packages that assume they're the project root (e.g. a
        # SilverStripe test-scaffold recipe with a post-install script), that
        # script can still scaffold files into this dir regardless of ddev
        # vs bare metal. Flag it; local-ci can't prevent a module's own
        # composer.json from doing this.
        if [ "$DRY" -eq 0 ] && [ "$NESTED" -eq 1 ] && [ ! -d vendor ]; then
          record WARN "PHP[$d]: first composer install in a nested DDEV subdir - if this module's require-dev includes a project-scaffolding package (e.g. recipe-testing), its post-install script may still scaffold stray files here regardless of DDEV routing"
        fi
        hdr "PHP[$d]: composer install"
        if [ "$DRY" -eq 1 ]; then
          printf '   \033[90m[dry-run] %s\033[0m\n' "$CC install --no-interaction --prefer-dist"
          record PLAN "PHP[$d]: composer install"
        elif bash -c "$CC install --no-interaction --prefer-dist"; then
          record PASS "PHP[$d]: composer install"
        else
          record_sev "PHP[$d]: composer install" gate
          # Without vendor/, dev/build, phpunit, phpcs, and phpstan can't run
          # for this dir — record that explicitly so a WARN-only run doesn't
          # look clean by omission (they'd otherwise just be absent from the
          # SUMMARY with no indication they were skipped, not merely unused).
          record SKIP "PHP[$d]: dev/build, phpunit, phpcs, phpstan (composer install did not succeed)"
          return 0
        fi
      else
        run_check "PHP[$d]: composer install (dry-run)" gate bash -c "$CC install --dry-run --no-interaction"
      fi
    fi

    # --- dev/build (SilverStripe) ----------------------------------------
    # Runs before phpunit so the ORM is built. Failure is WARN by default
    # (phpunit can sometimes self-bootstrap); use --strict-build for a hard gate.
    if [ "$DO_BUILD" -eq 1 ] && [ -x "$VENDOR_BIN/sake" ]; then
      hdr "PHP[$d]: sake dev/build"
      if [ "$DRY" -eq 1 ]; then
        run "$VENDOR_BIN_RUN/sake" dev/build flush=1
        record PLAN "PHP[$d]: dev/build"
      elif run "$VENDOR_BIN_RUN/sake" dev/build flush=1; then
        record PASS "PHP[$d]: dev/build"
      elif [ "$(effective_sev build)" = FAIL ]; then
        record FAIL "PHP[$d]: dev/build"
      else
        record WARN "PHP[$d]: dev/build (continuing — phpunit may self-bootstrap)"
      fi
    fi

    # PHPUnit
    # The "config present but vendor/bin/X missing" WARN below requires
    # vendor/ to actually exist — under --dry-run against a fresh checkout,
    # composer install is only planned (not run), so vendor/'s absence there
    # reflects the skipped install, not a real missing-binary problem.
    local unit_cfg; unit_cfg="$(first_existing phpunit.xml phpunit.xml.dist || true)"
    if [ -n "$unit_cfg" ] && [ -x "$VENDOR_BIN/phpunit" ]; then
      run_check "PHP[$d]: phpunit" gate bash -c 'if [ -n "'"$PRE"'" ]; then '"$PRE"' "'"$VENDOR_BIN_RUN"'/phpunit" --colors=always; else "'"$VENDOR_BIN_RUN"'/phpunit" --colors=always; fi'
    elif [ -n "$unit_cfg" ] && [ -d vendor ]; then
      record WARN "PHP[$d]: phpunit (adopted via config but $VENDOR_BIN/phpunit missing)"
    fi

    # PHPCS (+ phpcbf auto-fix first)
    local std; std="$(first_existing phpcs.xml phpcs.xml.dist .phpcs.xml .phpcs.xml.dist || true)"
    if [ -n "$std" ] && [ -x "$VENDOR_BIN/phpcs" ]; then
      # resolve sniff paths from convention (string, not array — safe under
      # set -u on macOS bash 3.2; empty means rely on the ruleset's <file> entries)
      local paths=""
      if [ -d app/src ]; then paths="app/src"; [ -d app/tests ] && paths="$paths app/tests"
      elif [ -d src ]; then paths="src"; [ -d tests ] && paths="$paths tests"
      fi
      if [ "$DO_FIX" -eq 1 ] && [ -x "$VENDOR_BIN/phpcbf" ]; then
        hdr "PHP[$d]: phpcbf (auto-fix)"
        # shellcheck disable=SC2086  # intentional word-split of $paths
        run "$VENDOR_BIN_RUN/phpcbf" --standard="$std" $paths || true
      fi
      run_check "PHP[$d]: phpcs" lint bash -c '
        if [ -n "'"$PRE"'" ]; then R="'"$PRE"' "; else R=""; fi
        $R "'"$VENDOR_BIN_RUN"'/phpcs" -s --report=summary --standard="'"$std"'" --extensions=php,inc --ignore=autoload.php --ignore=vendor/ '"$paths"''
    elif [ -n "$std" ] && [ -d vendor ]; then
      record WARN "PHP[$d]: phpcs (adopted via $std but $VENDOR_BIN/phpcs missing)"
    fi

    # PHPStan
    local stan_cfg; stan_cfg="$(first_existing phpstan.neon phpstan.neon.dist || true)"
    if [ -n "$stan_cfg" ] && [ -x "$VENDOR_BIN/phpstan" ]; then
      run_check "PHP[$d]: phpstan" lint bash -c 'if [ -n "'"$PRE"'" ]; then '"$PRE"' "'"$VENDOR_BIN_RUN"'/phpstan" analyse --no-progress; else "'"$VENDOR_BIN_RUN"'/phpstan" analyse --no-progress; fi'
    elif [ -n "$stan_cfg" ] && [ -d vendor ]; then
      record WARN "PHP[$d]: phpstan (adopted via config but $VENDOR_BIN/phpstan missing)"
    fi

    # Behat (opt-in)
    if [ "$WITH_BEHAT" -eq 1 ] && [ -f behat.yml ] && [ -x "$VENDOR_BIN/behat" ]; then
      run_check "PHP[$d]: behat" gate bash -c 'if [ -n "'"$PRE"'" ]; then '"$PRE"' "'"$VENDOR_BIN_RUN"'/behat" --colors --strict; else "'"$VENDOR_BIN_RUN"'/behat" --colors --strict; fi'
    fi
  )
}

# ===== JavaScript / front-end (host only) ================================
has_npm_script() { # script-name  (run inside dir)
  [ -f package.json ] || return 1
  node -e 'const s=(require("./package.json").scripts||{});process.exit(s["'"$1"'"]?0:1)' 2>/dev/null
}

js_checks() { # dir
  local d="$1"
  ( cd "$d" || return 0
    [ -f package.json ] || return 0
    command -v node >/dev/null 2>&1 || { record WARN "JS[$d]: node not found on host"; return 0; }

    # use .nvmrc if nvm is available
    if [ -f .nvmrc ] && [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
      # shellcheck disable=SC1090
      . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" && nvm use >/dev/null 2>&1 || true
    fi

    if [ ! -d node_modules ]; then
      # Skip remaining JS checks only on a genuine install failure (run_check
      # returns 1) — not on `[ -d node_modules ]` afterward, which false-
      # positives when package.json declares no dependencies at all: install
      # then legitimately succeeds without ever creating node_modules/.
      # Record the skip explicitly (see the matching composer-install
      # comment above) so a WARN-only run doesn't look clean by omission.
      if [ -f package-lock.json ]; then
        run_check "JS[$d]: install" gate bash -c 'npm ci || npm install' || {
          record SKIP "JS[$d]: lint, build, test (install did not succeed)"
          return 0
        }
      else
        run_check "JS[$d]: install" gate npm install || {
          record SKIP "JS[$d]: lint, build, test (install did not succeed)"
          return 0
        }
      fi
    fi

    # eslint auto-fix then lint
    local HAS_LINT_SCRIPT; has_npm_script lint && HAS_LINT_SCRIPT=1 || HAS_LINT_SCRIPT=0
    local HAS_ESLINT_CFG; first_existing .eslintrc .eslintrc.js .eslintrc.json .eslintrc.cjs eslint.config.js eslint.config.mjs >/dev/null && HAS_ESLINT_CFG=1 || HAS_ESLINT_CFG=0
    if [ "$HAS_LINT_SCRIPT" -eq 1 ] || [ "$HAS_ESLINT_CFG" -eq 1 ]; then
      if [ "$DO_FIX" -eq 1 ] && command -v npx >/dev/null 2>&1; then
        hdr "JS[$d]: eslint --fix"
        X bash -c 'npx --no-install eslint . --fix --no-error-on-unmatched-pattern 2>/dev/null || true'
      fi
      if [ "$HAS_LINT_SCRIPT" -eq 1 ]; then
        run_check "JS[$d]: lint" lint npm run lint
      elif [ "$HAS_ESLINT_CFG" -eq 1 ] && command -v npx >/dev/null 2>&1; then
        # Flat/legacy eslint config present but no lint script — run eslint directly.
        run_check "JS[$d]: lint (eslint)" lint bash -c 'npx --no-install eslint . --no-error-on-unmatched-pattern'
      fi
    fi

    # build
    if has_npm_script build; then
      run_check "JS[$d]: build" gate npm run build
    fi

    # test (skip the npm placeholder)
    if has_npm_script test; then
      if node -e 'const t=(require("./package.json").scripts||{}).test||"";process.exit(/no test specified/.test(t)?0:1)' 2>/dev/null; then
        record SKIP "JS[$d]: test (placeholder script)"
      else
        run_check "JS[$d]: test" gate npm test
      fi
    fi
  )
}

# ===== Python (host only) ================================================
py_checks() { # dir
  local d="$1"
  ( cd "$d" || return 0
    first_existing pyproject.toml requirements.txt pytest.ini tox.ini setup.cfg ruff.toml .ruff.toml >/dev/null || return 0
    local has_py; has_py=0
    # Recursive source detection (not just top-level): a package layout like
    # src/pkg/mod.py must still set has_py. Skips dot-dirs and dep dirs.
    [ -n "$(find . \( -name '.?*' -o -name node_modules -o -name vendor -o -name 'venv*' -o -name env -o -name build -o -name dist -o -name site-packages \) -prune -o -name '*.py' -type f -print 2>/dev/null | head -1)" ] && has_py=1
    [ -d tests ] && has_py=1
    [ "$has_py" -eq 1 ] || { first_existing pyproject.toml requirements.txt >/dev/null || return 0; }

    # Resolve a project-local venv first: a uv/venv-managed project's
    # pytest/ruff typically live only in .venv/bin — invisible to `command -v`
    # and to a bare system $PY's import path. This dir's own on-disk venv
    # (./.venv, then ./venv) wins over an activated $VIRTUAL_ENV: py_checks
    # runs once per scanned DIR (a monorepo scan can cover several, each with
    # its own venv), and $VIRTUAL_ENV is a single process-global value that
    # would otherwise silently override every dir's own venv with whichever
    # one the invoking shell happened to have active. $VIRTUAL_ENV is still
    # used as a fallback for a dir with no on-disk venv of its own.
    #
    # VENV_BIN may end up an absolute path (from $VIRTUAL_ENV) or relative
    # (the ./.venv / ./venv literals) and either could contain shell
    # metacharacters (e.g. a space) if the enclosing project path has one.
    # It gets embedded both directly as a command word ($PY -c ...) and
    # inside bash -c "..." strings below, so it's kept in two forms: VENV_BIN
    # itself for the plain [ -x ... ] existence checks (already safely
    # double-quoted there), and VENV_BIN_Q — shell-quoted via `printf %q` —
    # for every context where it gets re-embedded into a string that a shell
    # (this one or a nested bash -c) will re-parse. %q's escaping survives
    # both: a plain unquoted word (backslash-escapes are honored by this
    # shell's own word-splitting) and re-embedding inside a double-quoted
    # string later handed to a nested `bash -c` (the backslash escapes pass
    # through literally and are then honored by that nested shell in turn).
    local VENV_BIN="" VENV_BIN_Q=""
    if [ -x ./.venv/bin/python3 ]; then
      VENV_BIN="./.venv/bin"
    elif [ -x ./venv/bin/python3 ]; then
      VENV_BIN="./venv/bin"
    elif [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV:-}/bin/python3" ]; then
      VENV_BIN="$VIRTUAL_ENV/bin"
    fi
    [ -n "$VENV_BIN" ] && VENV_BIN_Q="$(printf '%q' "$VENV_BIN")"

    # Resolve a Python interpreter for module-import fallbacks. Uses the
    # shell-quoted VENV_BIN_Q (see above) since $PY is later invoked as a
    # bare, unquoted command word ($PY -c ...).
    local PY=""
    if [ -n "$VENV_BIN" ]; then PY="$VENV_BIN_Q/python3";
    elif command -v python3 >/dev/null 2>&1; then PY="python3";
    elif command -v python >/dev/null 2>&1; then PY="python"; fi

    # ruff — gated on adoption, like phpcs/phpstan, not mere availability.
    # A global ruff install otherwise fires on every Python repo local-ci
    # touches, producing false FAILs (and sweeping --fix rewrites) on
    # projects that never opted in. Adoption evidence: a [tool.ruff]
    # section in pyproject.toml, a ruff.toml/.ruff.toml file, or a
    # ruff pre-commit hook (projects that lint via pre-commit alone,
    # relying on ruff's defaults, carry no other ruff config file).
    local ruff_adopted=0
    if first_existing ruff.toml .ruff.toml >/dev/null; then
      ruff_adopted=1
    elif [ -f pyproject.toml ] && grep -q '^\[tool\.ruff' pyproject.toml; then
      ruff_adopted=1
    elif [ -f .pre-commit-config.yaml ] && grep -qE 'ruff-pre-commit|/ruff$' .pre-commit-config.yaml; then
      ruff_adopted=1
    fi

    # Prefer the venv's own ruff over a global one: a stray older/newer
    # global install can silently disagree with the project's pinned version
    # on default rule selection for the same config file.
    local RUFF=""
    if [ -n "$VENV_BIN" ] && [ -x "$VENV_BIN/ruff" ]; then RUFF="$VENV_BIN_Q/ruff";
    elif command -v ruff >/dev/null 2>&1; then RUFF="ruff";
    elif [ -n "$PY" ] && $PY -c 'import ruff' >/dev/null 2>&1; then RUFF="$PY -m ruff"; fi
    if [ -n "$RUFF" ] && [ "$ruff_adopted" -eq 0 ]; then
      record SKIP "PY[$d]: ruff (no ruff config — project has not adopted ruff)"
    elif [ -n "$RUFF" ]; then
      if [ "$DO_FIX" -eq 1 ]; then
        hdr "PY[$d]: ruff --fix"
        X bash -c "$RUFF check --fix . || true"
      fi
      run_check "PY[$d]: ruff" gate bash -c "$RUFF check ."
    elif [ "$ruff_adopted" -eq 1 ]; then
      record WARN "PY[$d]: ruff (adopted via config but ruff is not installed)"
    fi

    # pytest — prefer the venv's own binary (see VENV_BIN above), then a
    # `pytest` already on PATH, then a separately resolved $PY's `-m pytest`.
    # Either console-script form still needs cwd forced onto PYTHONPATH: it
    # does not add cwd to sys.path on its own (only `python -m pytest` does
    # that natively), so suites that import top-level modules by cwd would
    # otherwise false-FAIL with ModuleNotFoundError.
    local PYTEST=""
    if [ -n "$VENV_BIN" ] && [ -x "$VENV_BIN/pytest" ]; then PYTEST="PYTHONPATH=\"\$PWD\${PYTHONPATH:+:\$PYTHONPATH}\" $VENV_BIN_Q/pytest";
    elif command -v pytest >/dev/null 2>&1; then PYTEST="PYTHONPATH=\"\$PWD\${PYTHONPATH:+:\$PYTHONPATH}\" pytest";
    elif [ -n "$PY" ] && $PY -c 'import pytest' >/dev/null 2>&1; then PYTEST="$PY -m pytest"; fi

    # Recursive test detection: test files may live in nested packages
    # rather than at the top level or in a tests/ dir. Computed independently
    # of PYTEST resolution so "pytest missing" and "no tests" stay
    # distinguishable outcomes instead of collapsing into one silent no-op.
    local has_tests=0
    [ -d tests ] && has_tests=1
    [ -n "$(find . \( -name '.?*' -o -name node_modules -o -name vendor -o -name 'venv*' -o -name env -o -name build -o -name dist -o -name site-packages \) -prune -o \( -name 'test_*.py' -o -name '*_test.py' \) -type f -print 2>/dev/null | head -1)" ] && has_tests=1

    if [ -n "$PYTEST" ] && [ "$has_tests" -eq 1 ]; then
      run_check "PY[$d]: pytest" gate bash -c "$PYTEST -q"
    elif [ -n "$PYTEST" ]; then
      record SKIP "PY[$d]: pytest (no tests found)"
    elif [ "$has_tests" -eq 1 ]; then
      record WARN "PY[$d]: pytest (tests present but pytest is not installed/importable)"
    fi
  )
}

# ===== Shell (host only) ==================================================
sh_checks() { # dir
  local d="$1"
  ( cd "$d" || return 0

    # Collect shell sources: tracked *.sh files plus any not-yet-`git add`ed
    # ones that aren't gitignored (so a brand-new script still gets linted
    # before its first commit). core.quotePath=false keeps filenames with
    # special/non-ASCII characters literal instead of C-quoted (which would
    # otherwise not match any real path on disk). Fall back to find when the
    # dir isn't a git repo. A leading wildcard like '*.sh' in a git pathspec
    # matches at any depth below cwd, not just cwd itself, so this picks up
    # e.g. both hooks/*.sh and tests/*.sh from the root in one call.
    local files
    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
      files="$(git -c core.quotePath=false ls-files '*.sh' 2>/dev/null
               git -c core.quotePath=false ls-files --others --exclude-standard '*.sh' 2>/dev/null)"
    else
      files="$(find . \( -name '.?*' -o -name node_modules -o -name vendor -o -name 'venv*' -o -name env -o -name build -o -name dist \) -prune -o -name '*.sh' -type f -print 2>/dev/null)"
    fi
    [ -n "$files" ] || return 0

    # Adoption evidence: an explicit .shellcheckrc, or --with-shellcheck.
    # Deliberately config-only (mirrors ruff_adopted above) — no "shell-only
    # project" auto-adopt: shellcheck's default sensitivity flags real-world
    # scripts almost universally, so auto-adopting from language alone would
    # hard-FAIL (and, via the push gate, block pushes on) a project's very
    # first run with no config-driven escape hatch.
    local sc_adopted=0
    if [ -f .shellcheckrc ]; then
      sc_adopted=1
    elif [ "$WITH_SHELLCHECK" -eq 1 ]; then
      sc_adopted=1
    fi

    if [ "$sc_adopted" -eq 0 ]; then
      record SKIP "shell[$d]: shellcheck (no .shellcheckrc — pass --with-shellcheck to force)"
      return 0
    fi

    if ! command -v shellcheck >/dev/null 2>&1; then
      record WARN "shell[$d]: shellcheck (adopted via .shellcheckrc but shellcheck is not installed)"
      return 0
    fi

    # Build the file array, deduping against SH_SEEN_FILE (by absolute path)
    # so overlapping DIRS entries (e.g. "." and "frontend", when frontend/ is
    # both its own entry and already swept up by the root's recursive scan)
    # never shellcheck — or report — the same file twice in one run.
    local sh_files=() rp
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rp="$(cd "$(dirname "$f")" 2>/dev/null && pwd)/$(basename "$f")" || continue
      grep -qxF "$rp" "$SH_SEEN_FILE" 2>/dev/null && continue
      echo "$rp" >> "$SH_SEEN_FILE"
      sh_files+=("$f")
    done <<SHFILES
$files
SHFILES

    if [ "${#sh_files[@]}" -eq 0 ]; then
      record SKIP "shell[$d]: shellcheck (all files already checked via another dir)"
      return 0
    fi

    # Dialect is autodetected per-file from its shebang; a project needing a
    # forced dialect sets `shell=sh` (or bash/dash/ksh) in its .shellcheckrc.
    # `--` guards a file whose name happens to start with `-`.
    run_check "shell[$d]: shellcheck" gate shellcheck -- "${sh_files[@]}"
  )
}

# ===== Custom project-declared checks =====================================
# Escape hatch for projects whose real CI isn't shaped like any of the
# language drivers above (e.g. a pure-shell repo running its own test
# harness plus jq-based manifest validation). Reads a project-committed
# .local-ci.json and runs each declared command as its own PASS/FAIL check.
# Runs regardless of --no-fix, same as phpunit/npm test/pytest above — only
# the auto-fixer sub-steps (phpcbf/eslint --fix/ruff --fix) are gated by it.
#
# Trust model: identical to the npm/composer scripts already run above —
# this executes commands the project itself authored and committed.
#
# Schema:
#   { "checks": [ { "label": "hook tests", "run": "sh tests/run.sh" }, ... ] }
custom_checks() { # dir
  local d="$1"
  ( cd "$d" || return 0
    [ -f .local-ci.json ] || return 0

    if ! command -v jq >/dev/null 2>&1; then
      record WARN "custom[$d]: .local-ci.json present but jq is not installed to parse it"
      return 0
    fi

    if ! jq -e '.checks | type == "array"' .local-ci.json >/dev/null 2>&1; then
      record FAIL "custom[$d]: .local-ci.json (malformed — expected {\"checks\":[{\"label\":...,\"run\":...}]})"
      return 0
    fi

    # Single-pass extraction (one jq spawn regardless of check count). @tsv
    # escapes embedded tab/newline/CR/backslash within each field, so a
    # label containing a literal newline can't split a row across two lines
    # downstream — RESULTS_FILE and the git-push-gate status marker are both
    # parsed as one record per line.
    local label cmd
    while IFS=$'\t' read -r label cmd; do
      if [ -z "$cmd" ]; then
        record FAIL "custom[$d]: ${label:-unnamed check} (malformed — missing \"run\")"
        continue
      fi
      run_check "custom[$d]: ${label:-unnamed check}" gate bash -c "$cmd"
    done < <(jq -r '.checks[] | [(.label // ""), (.run // "")] | @tsv' .local-ci.json)
  )
}

# ----- run ---------------------------------------------------------------
# Snapshot tree state so AUTO-FIX CHANGES reports only what the fixers mutated
# during this run, not pre-existing staged/unstaged user edits.
tree_state() {
  { git -C "$ROOT" diff HEAD --stat 2>/dev/null || git -C "$ROOT" diff --stat 2>/dev/null; } | cksum
}
PRE_FIX_STATE=""
if [ "$DO_FIX" -eq 1 ] && [ "$DRY" -eq 0 ] && command -v git >/dev/null 2>&1 \
   && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  PRE_FIX_STATE="$(tree_state)"
fi

for d in "${DIRS[@]}"; do
  php_checks "$d"
  js_checks "$d"
  py_checks "$d"
  sh_checks "$d"
  custom_checks "$d"
done

# ----- summary -----------------------------------------------------------
hdr "SUMMARY"
FAILED=0
if [ ! -s "$RESULTS_FILE" ]; then
  echo "No recognised check configs found — nothing to run."
else
  # Not "status": zsh treats that as a read-only special (its $? alias), and
  # `read -r status ...` under zsh (whether invoked directly or via a caller
  # that runs the script with `zsh script.sh` instead of respecting the bash
  # shebang) fatally errors here — SUMMARY never prints and the run silently
  # exits 0 regardless of real results.
  while IFS=$'\t' read -r res label; do
    case "$res" in
      PASS) printf '  \033[32m✔ PASS\033[0m  %s\n' "$label" ;;
      FAIL) printf '  \033[31m✘ FAIL\033[0m  %s\n' "$label" ; FAILED=1 ;;
      WARN) printf '  \033[33m! WARN\033[0m  %s\n' "$label" ;;
      SKIP) printf '  \033[90m- SKIP\033[0m  %s\n' "$label" ;;
      PLAN) printf '  \033[36m▷ PLAN\033[0m  %s\n' "$label" ;;
    esac
  done < "$RESULTS_FILE"
fi

# Show auto-fixer mutations: only when the tree state changed during the run.
# Diff against HEAD so fixer mutations to already-staged files show up too;
# plain `git diff` (index vs worktree) under-reports those. Fall back to the
# plain diff on an unborn HEAD (repo with no commits yet).
if [ "$DO_FIX" -eq 1 ] && [ "$DRY" -eq 0 ] && command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if [ "$(tree_state)" != "$PRE_FIX_STATE" ]; then
    changed="$(git -C "$ROOT" diff HEAD --stat 2>/dev/null)" || changed="$(git -C "$ROOT" diff --stat 2>/dev/null)"
    hdr "AUTO-FIX CHANGES (tree changed during run; git diff HEAD --stat)"
    echo "$changed"
  fi
fi

# ----- status marker (consumed by the git-push gate hook) ----------------
# Records this run so a PreToolUse hook can verify "local-ci ran at this HEAD
# and did not fail" before allowing `git push`. See scripts/git-push-gate.sh.
# Format: one line — sha=<HEAD> result=<PASS|FAIL|WARN|NONE> ts=<epoch>
# Stamps every distinct repo among the scanned DIRS (not $(pwd): an explicit
# DIR arg may point at a different repo than the invocation cwd). A run in
# which nothing actually executed (all SKIP, or nothing found) records NONE
# rather than certifying a PASS.
if [ "$DRY" -eq 0 ] && command -v git >/dev/null 2>&1; then
  MARKER_RESULT=PASS
  if [ "$FAILED" -ne 0 ]; then MARKER_RESULT=FAIL
  elif grep -q '^WARN' "$RESULTS_FILE" 2>/dev/null; then MARKER_RESULT=WARN
  elif ! grep -qE '^(PASS|FAIL|WARN)' "$RESULTS_FILE" 2>/dev/null; then MARKER_RESULT=NONE
  fi
  SEEN_GITDIRS=" "
  for d in "${DIRS[@]}"; do
    MARKER_DIR="$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" || continue
    case "$SEEN_GITDIRS" in *" $MARKER_DIR "*) continue ;; esac
    SEEN_GITDIRS="$SEEN_GITDIRS$MARKER_DIR "
    MARKER_SHA="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo none)"
    printf 'sha=%s result=%s ts=%s\n' \
      "$MARKER_SHA" "$MARKER_RESULT" "$(date +%s)" > "$MARKER_DIR/local-ci-status" 2>/dev/null || true
  done
fi

echo
if [ "$DRY" -eq 1 ]; then
  echo "Result: dry-run — listed planned checks, executed nothing."
elif [ "$FAILED" -ne 0 ]; then
  echo "Result: one or more checks FAILED."
elif grep -q '^WARN' "$RESULTS_FILE" 2>/dev/null; then
  echo "Result: no FAILs, but findings are WARN — read the SUMMARY above (re-run with --strict to gate)."
else
  echo "Result: all checks passed."
fi
exit "$FAILED"
