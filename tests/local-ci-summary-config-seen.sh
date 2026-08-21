#!/usr/bin/env bash
#
# Regression test for workflow-skills#72.
#
# The SUMMARY's empty-RESULTS_FILE branch printed "No recognised check
# configs found — nothing to run." whenever nothing was recorded — but empty
# only means nothing was RECORDED, not that no config was recognised. A
# project can have a real, recognised check config where the driver still
# recorded nothing (a driver bug, like #71 before it was fixed), and the old
# message read as "this project has no CI surface for me to check", a much
# stronger and more misleading claim than "something went wrong recording
# results".
#
# The fix tracks config recognition (CONFIG_SEEN_FILE, written by
# mark_config_seen()) independently of RESULTS_FILE rows. A first version
# compared the two files only in aggregate (any row anywhere vs. none at
# all) — code-reviewer on PR #81 found that this masks a single dir/driver
# going silent the moment ANY OTHER dir/driver in the same multi-dir scan
# legitimately records something, which is the common case, not the edge
# case. The fix reconciles per (driver, dir) instead: after the main scan
# loop, for every (driver, dir) mark_config_seen recorded, check whether
# RESULTS_FILE has at least one row under that driver's own label prefix
# ("PHP[$d]:"/"JS[$d]:"/"PY[$d]:"/"shell[$d]:"/"custom[$d]:") — if not,
# record a WARN naming exactly that (driver, dir) pair as the gap, rather
# than a single whole-run message that can't say which dir/driver went quiet.
#
# That reconciliation alone would have a second problem, also found in the
# same review round: several drivers have legitimate "recognised, nothing to
# check" paths (a package.json with no lint/build/test script and
# node_modules/ already present; a Python project with no ruff adoption and
# no tests) that used to fall through with zero rows too — not a bug, just
# nothing to do. Flagging those as "this is a local-ci bug, please report
# it" would be a false alarm on entirely normal projects. The real fix is at
# the driver level: js_checks and py_checks now explicitly record a SKIP for
# every one of their own "recognised, nothing to do" exits, so the generic
# per-(driver,dir) reconciliation above only ever fires for a genuinely
# unexplained silence, not a named, ordinary one.
#
# Case 1 drives the reconciliation directly via `.local-ci.json` with an
# empty `checks` array — a config custom_checks() legitimately recognises
# (mark_config_seen fires) but records nothing for (the jq loop iterates
# zero times), without needing to inject a synthetic bug into a driver to
# reach it. Cases 3 and 4 drive the two false-positive fixes directly: a
# Python project and a JS project each in a state that used to trip the old
# whole-run message on an entirely normal project.
#
# Plain bash, no test framework dependency — mirrors the other tests/*.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_CI="$REPO_ROOT/skills/local-ci/scripts/local-ci.sh"

[ -f "$LOCAL_CI" ] || { echo "FAIL: cannot find local-ci.sh at $LOCAL_CI" >&2; exit 1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; }

TMP_DIRS=()
cleanup() { for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
  skip "workflow-skills#72: jq not found on this host — cannot exercise custom_checks()"
  exit 0
fi

# ===== Case 1 (#72): a recognised-but-empty config must not claim "nothing found"

run_case1() {
  local work fixture out
  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-configseen.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture"
  cat > "$fixture/.local-ci.json" <<'EOF'
{"checks": []}
EOF

  out="$(cd "$work" && bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"No recognised check configs found"*)
      fail "Case 1 (#72): still claims no configs were recognised, despite .local-ci.json being present. Output:
$out" ;;
    *) pass "Case 1 (#72): does not falsely claim no configs were recognised" ;;
  esac
  case "$out" in
    *"custom[$fixture]: config recognised but nothing was recorded for this driver"*)
      pass "Case 1 (#72): SUMMARY names the exact (driver, dir) gap" ;;
    *)
      fail "Case 1 (#72): expected a 'custom[...]: config recognised but nothing was recorded' WARN naming this exact dir; not found. Output:
$out" ;;
  esac
}

# ===== Case 2 (no regression): a dir with no config at all keeps the
# original message — the fix must not turn every empty run into a false
# "recognised" claim.

run_case2() {
  local work fixture out
  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-configseen-none.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture"

  out="$(cd "$work" && bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"No recognised check configs found — nothing to run."*)
      pass "Case 2: a genuinely empty dir still gets the original message" ;;
    *)
      fail "Case 2: expected the original 'nothing to run' message for a dir with no config at all. Output:
$out" ;;
  esac
}

# ===== Case 3 (code-reviewer finding on PR #81): a Python project with
# nothing left to check (no ruff adoption, no tests, tools unresolvable)
# must get its own named SKIP rows, not the "please report a bug" WARN.

run_case3() {
  local work fixture out
  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-configseen-py.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture"
  # requirements.txt + one .py file, no tests/, no ruff adoption — a
  # perfectly ordinary small Python project with no test suite yet.
  cat > "$fixture/requirements.txt" <<'EOF'
requests==2.31.0
EOF
  cat > "$fixture/app.py" <<'EOF'
print("hello")
EOF

  out="$(cd "$work" && PATH="/usr/bin:/bin" VIRTUAL_ENV= bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"config recognised but nothing was recorded for this driver"*)
      fail "Case 3: a normal Python project with nothing to check triggered the 'please report a bug' WARN. Output:
$out" ;;
    *) pass "Case 3: no false 'please report a bug' WARN for a normal Python project" ;;
  esac
  case "$out" in
    *"PY[$fixture]: ruff (not adopted, not installed"*|*"PY[$fixture]: ruff (no ruff config"*)
      pass "Case 3: ruff's 'nothing to check' state is named explicitly" ;;
    *)
      fail "Case 3: expected a named ruff SKIP row; not found. Output:
$out" ;;
  esac
  case "$out" in
    *"PY[$fixture]: pytest (not installed, no tests found"*)
      pass "Case 3: pytest's 'nothing to check' state is named explicitly" ;;
    *)
      fail "Case 3: expected a named pytest SKIP row; not found. Output:
$out" ;;
  esac
}

# ===== Case 4 (code-reviewer finding on PR #81): a JS project with
# dependencies already installed and no lint/build/test script must get its
# own named SKIP row, not the "please report a bug" WARN.

run_case4() {
  local work fixture out
  if ! command -v node >/dev/null 2>&1; then
    skip "Case 4: node not found on this host — cannot exercise js_checks()"
    return
  fi
  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-configseen-js.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture/node_modules"
  # Dependency-only package.json: no lint/build/test script, no eslint
  # config, and node_modules/ already present so install is skipped too.
  cat > "$fixture/package.json" <<'EOF'
{"name": "fixture", "version": "1.0.0", "dependencies": {}}
EOF

  out="$(cd "$work" && bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"config recognised but nothing was recorded for this driver"*)
      fail "Case 4: a normal dependency-only package.json triggered the 'please report a bug' WARN. Output:
$out" ;;
    *) pass "Case 4: no false 'please report a bug' WARN for a dependency-only package.json" ;;
  esac
  case "$out" in
    *"JS[$fixture]: nothing to check"*)
      pass "Case 4: JS driver's 'nothing to check' state is named explicitly" ;;
    *)
      fail "Case 4: expected a named JS SKIP row; not found. Output:
$out" ;;
  esac
}

run_case1
run_case2
run_case3
run_case4

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAILURES check(s) failed."
  exit 1
fi
