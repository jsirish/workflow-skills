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
# mark_config_seen()) independently of RESULTS_FILE rows, and picks the
# SUMMARY message from it.
#
# This test drives the case directly rather than re-simulating a since-fixed
# driver bug: a `.local-ci.json` with an empty `checks` array is a config
# custom_checks() legitimately recognises (mark_config_seen fires) but
# legitimately records nothing for (the jq loop iterates zero times) — the
# exact "recognised, nothing recorded" shape #72 describes, without needing
# to inject a synthetic bug into a driver to reach it.
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
    *"recognised, but nothing was recorded"*)
      pass "Case 1 (#72): SUMMARY names the actual gap (recognised, nothing recorded)" ;;
    *)
      fail "Case 1 (#72): expected the 'recognised, but nothing was recorded' message; not found. Output:
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

run_case1
run_case2

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAILURES check(s) failed."
  exit 1
fi
