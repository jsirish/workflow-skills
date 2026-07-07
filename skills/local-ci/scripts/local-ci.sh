#!/usr/bin/env bash
#
# local-ci.sh — run the executable test/lint layer that LLM review can't.
#
# Detects which check configs a project has and runs the matching checks,
# auto-fixing where a fixer exists (then re-checking), and prints a pass/fail
# summary. Mirrors the canonical silverstripe/gha-ci set (phpunit, phpcs,
# phpstan) plus npm scripts and Python (ruff, pytest).
#
# Usage:
#   local-ci.sh [options] [DIR ...]
#
# Options:
#   --no-fix        Do not run auto-fixers (phpcbf / eslint --fix / ruff --fix);
#                   report only.
#   --no-build      Skip the SilverStripe `sake dev/build` step.
#   --strict-build  Treat a failing `sake dev/build` as FAIL (default: WARN).
#   --fresh-deps    Force a real `composer install` even when vendor/ exists
#                   (mirrors GHA's clean-install behaviour; slower, mutates vendor/).
#   --with-behat    Also run Behat (behat.yml) — opt-in; needs a browser/driver.
#   --dry-run       Detect checks and print what WOULD run; execute nothing.
#   -h, --help      Show this help.
#
# DIR ...   One or more project dirs to scan (default: current dir, plus the
#           common sub-package dirs frontend/ client/ backend/ app/ if present).
#
# Execution context: when a project has .ddev/config.yaml, PHP checks run via
# `ddev exec` and composer via `ddev composer`. JS and Python checks always run
# on the host (DDEV containers rarely carry the node/python toolchain).
# Override host vs ddev is automatic.
#
# Exit code: non-zero if any check FAILed.

set -uo pipefail

# ----- options -----------------------------------------------------------
DO_FIX=1
DO_BUILD=1
STRICT_BUILD=0
FRESH_DEPS=0
WITH_BEHAT=0
DRY=0
DIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --no-fix)       DO_FIX=0 ;;
    --no-build)     DO_BUILD=0 ;;
    --strict-build) STRICT_BUILD=1 ;;
    --fresh-deps)   FRESH_DEPS=1 ;;
    --with-behat)   WITH_BEHAT=1 ;;
    --dry-run)      DRY=1 ;;
    -h|--help)      awk 'NR==1{next} /^#/{print; next} /^$/{next} {exit}' "$0"; exit 0 ;;
    --*)            echo "Unknown option: $1" >&2; exit 2 ;;
    *)              DIRS+=("$1") ;;
  esac
  shift
done

ROOT="$(pwd)"

# ----- result tracking ---------------------------------------------------
# Checks run in subshells (per-dir cd), so results go to a temp file that
# survives the subshell boundary rather than an in-memory array.
RESULTS_FILE="$(mktemp -t local-ci.XXXXXX)"
trap 'rm -f "$RESULTS_FILE"' EXIT

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

# Run a command, record PASS/FAIL under a label. Extra args after label are the
# command. Honours the per-dir PHP runner prefix already baked into the command.
run_check() { # label cmd...
  local label="$1"; shift
  hdr "$label"
  if [ "$DRY" -eq 1 ]; then
    printf '   \033[90m[dry-run] %s\033[0m\n' "$*"
    record PLAN "$label"
    return 0
  fi
  if "$@"; then
    record PASS "$label"
  else
    record FAIL "$label"
  fi
}

# ----- detect candidate dirs --------------------------------------------
if [ "${#DIRS[@]}" -eq 0 ]; then
  DIRS=(".")
  for sub in frontend client backend app; do
    [ -d "$sub" ] && DIRS+=("$sub")
  done
fi

# ----- PHP runner (ddev-aware) ------------------------------------------
# Echoes the command prefix for PHP tools given a project dir.
php_prefix() { # dir
  if [ -f "$1/.ddev/config.yaml" ] || { [ "$1" = "." ] && [ -f ".ddev/config.yaml" ]; }; then
    echo "ddev exec"
  else
    echo ""
  fi
}

# Under DDEV, use "ddev composer" — it handles container mounts / mutagen sync correctly.
composer_cmd() { # dir
  if [ -n "$(php_prefix "$1")" ]; then
    echo "ddev composer"
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

    # --- composer: validate + install ------------------------------------
    local CC; CC="$(composer_cmd .)"
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
        record FAIL "PHP[$d]: composer validate"
      fi

      if [ "$FRESH_DEPS" -eq 1 ] || [ ! -d vendor ]; then
        hdr "PHP[$d]: composer install"
        if [ "$DRY" -eq 1 ]; then
          printf '   \033[90m[dry-run] %s\033[0m\n' "$CC install --no-interaction --prefer-dist"
          record PLAN "PHP[$d]: composer install"
        elif bash -c "$CC install --no-interaction --prefer-dist"; then
          record PASS "PHP[$d]: composer install"
        else
          record FAIL "PHP[$d]: composer install"
          return 0
        fi
      else
        run_check "PHP[$d]: composer install (dry-run)" bash -c "$CC install --dry-run --no-interaction"
      fi
    fi

    local PRE; PRE="$(php_prefix .)"
    run() { if [ -n "$PRE" ]; then X $PRE "$@"; else X "$@"; fi; }

    # --- dev/build (SilverStripe) ----------------------------------------
    # Runs before phpunit so the ORM is built. Failure is WARN by default
    # (phpunit can sometimes self-bootstrap); use --strict-build for a hard gate.
    if [ "$DO_BUILD" -eq 1 ] && [ -x vendor/bin/sake ]; then
      hdr "PHP[$d]: sake dev/build"
      if [ "$DRY" -eq 1 ]; then
        run vendor/bin/sake dev/build flush=1
        record PLAN "PHP[$d]: dev/build"
      elif run vendor/bin/sake dev/build flush=1; then
        record PASS "PHP[$d]: dev/build"
      elif [ "$STRICT_BUILD" -eq 1 ]; then
        record FAIL "PHP[$d]: dev/build"
      else
        record WARN "PHP[$d]: dev/build (continuing — phpunit may self-bootstrap)"
      fi
    fi

    # PHPUnit
    if first_existing phpunit.xml phpunit.xml.dist >/dev/null && [ -x vendor/bin/phpunit ]; then
      run_check "PHP[$d]: phpunit" bash -c 'if [ -n "'"$PRE"'" ]; then '"$PRE"' vendor/bin/phpunit --colors=always; else vendor/bin/phpunit --colors=always; fi'
    elif first_existing phpunit.xml phpunit.xml.dist >/dev/null; then
      record WARN "PHP[$d]: phpunit (adopted via config but vendor/bin/phpunit missing)"
    fi

    # PHPCS (+ phpcbf auto-fix first)
    local std; std="$(first_existing phpcs.xml phpcs.xml.dist .phpcs.xml .phpcs.xml.dist || true)"
    if [ -n "$std" ] && [ -x vendor/bin/phpcs ]; then
      # resolve sniff paths from convention (string, not array — safe under
      # set -u on macOS bash 3.2; empty means rely on the ruleset's <file> entries)
      local paths=""
      if [ -d app/src ]; then paths="app/src"; [ -d app/tests ] && paths="$paths app/tests"
      elif [ -d src ]; then paths="src"; [ -d tests ] && paths="$paths tests"
      fi
      if [ "$DO_FIX" -eq 1 ] && [ -x vendor/bin/phpcbf ]; then
        hdr "PHP[$d]: phpcbf (auto-fix)"
        # shellcheck disable=SC2086  # intentional word-split of $paths
        run vendor/bin/phpcbf --standard="$std" $paths || true
      fi
      run_check "PHP[$d]: phpcs" bash -c '
        if [ -n "'"$PRE"'" ]; then R="'"$PRE"' "; else R=""; fi
        $R vendor/bin/phpcs -s --report=summary --standard="'"$std"'" --extensions=php,inc --ignore=autoload.php --ignore=vendor/ '"$paths"''
    elif [ -n "$std" ]; then
      record WARN "PHP[$d]: phpcs (adopted via $std but vendor/bin/phpcs missing)"
    fi

    # PHPStan
    if first_existing phpstan.neon phpstan.neon.dist >/dev/null && [ -x vendor/bin/phpstan ]; then
      run_check "PHP[$d]: phpstan" bash -c 'if [ -n "'"$PRE"'" ]; then '"$PRE"' vendor/bin/phpstan analyse --no-progress; else vendor/bin/phpstan analyse --no-progress; fi'
    elif first_existing phpstan.neon phpstan.neon.dist >/dev/null; then
      record WARN "PHP[$d]: phpstan (adopted via config but vendor/bin/phpstan missing)"
    fi

    # Behat (opt-in)
    if [ "$WITH_BEHAT" -eq 1 ] && [ -f behat.yml ] && [ -x vendor/bin/behat ]; then
      run_check "PHP[$d]: behat" bash -c 'if [ -n "'"$PRE"'" ]; then '"$PRE"' vendor/bin/behat --colors --strict; else vendor/bin/behat --colors --strict; fi'
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
      if [ -f package-lock.json ]; then
        run_check "JS[$d]: install" bash -c 'npm ci || npm install'
      else
        run_check "JS[$d]: install" npm install
      fi
      # If install failed, node_modules still absent — skip remaining JS checks.
      [ -d node_modules ] || return 0
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
        run_check "JS[$d]: lint" npm run lint
      elif [ "$HAS_ESLINT_CFG" -eq 1 ] && command -v npx >/dev/null 2>&1; then
        # Flat/legacy eslint config present but no lint script — run eslint directly.
        run_check "JS[$d]: lint (eslint)" bash -c 'npx --no-install eslint . --no-error-on-unmatched-pattern'
      fi
    fi

    # build
    if has_npm_script build; then
      run_check "JS[$d]: build" npm run build
    fi

    # test (skip the npm placeholder)
    if has_npm_script test; then
      if node -e 'const t=(require("./package.json").scripts||{}).test||"";process.exit(/no test specified/.test(t)?0:1)' 2>/dev/null; then
        record SKIP "JS[$d]: test (placeholder script)"
      else
        run_check "JS[$d]: test" npm test
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

    # Resolve a Python interpreter for module-import fallbacks.
    local PY=""
    if command -v python3 >/dev/null 2>&1; then PY="python3";
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

    local RUFF=""
    if command -v ruff >/dev/null 2>&1; then RUFF="ruff";
    elif [ -n "$PY" ] && $PY -c 'import ruff' >/dev/null 2>&1; then RUFF="$PY -m ruff"; fi
    if [ -n "$RUFF" ] && [ "$ruff_adopted" -eq 0 ]; then
      record SKIP "PY[$d]: ruff (no ruff config — project has not adopted ruff)"
    elif [ -n "$RUFF" ]; then
      if [ "$DO_FIX" -eq 1 ]; then
        hdr "PY[$d]: ruff --fix"
        X bash -c "$RUFF check --fix . || true"
      fi
      run_check "PY[$d]: ruff" bash -c "$RUFF check ."
    elif [ "$ruff_adopted" -eq 1 ]; then
      record WARN "PY[$d]: ruff (adopted via config but ruff is not installed)"
    fi

    # pytest — keep preferring a `pytest` already on PATH (it's the one tied to
    # an active venv/project env, with the right plugins/deps) over a separately
    # resolved $PY, which may belong to a different environment entirely. Either
    # way, force cwd onto PYTHONPATH: the bare console script does not add cwd to
    # sys.path (only `python -m pytest` does that natively), so suites that import
    # top-level modules by cwd would otherwise false-FAIL with ModuleNotFoundError.
    local PYTEST=""
    if command -v pytest >/dev/null 2>&1; then PYTEST="PYTHONPATH=\"\$PWD\${PYTHONPATH:+:\$PYTHONPATH}\" pytest";
    elif [ -n "$PY" ] && $PY -c 'import pytest' >/dev/null 2>&1; then PYTEST="$PY -m pytest"; fi
    if [ -n "$PYTEST" ]; then
      # Recursive test detection: test files may live in nested packages
      # rather than at the top level or in a tests/ dir.
      if [ -d tests ] || [ -n "$(find . \( -name '.?*' -o -name node_modules -o -name vendor -o -name 'venv*' -o -name env -o -name build -o -name dist -o -name site-packages \) -prune -o \( -name 'test_*.py' -o -name '*_test.py' \) -type f -print 2>/dev/null | head -1)" ]; then
        run_check "PY[$d]: pytest" bash -c "$PYTEST -q"
      else
        record SKIP "PY[$d]: pytest (no tests found)"
      fi
    fi
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
done

# ----- summary -----------------------------------------------------------
hdr "SUMMARY"
FAILED=0
if [ ! -s "$RESULTS_FILE" ]; then
  echo "No recognised check configs found — nothing to run."
else
  while IFS=$'\t' read -r status label; do
    case "$status" in
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
elif [ "$FAILED" -eq 0 ]; then
  echo "Result: all checks passed."
else
  echo "Result: one or more checks FAILED."
fi
exit "$FAILED"
