#!/usr/bin/env bash
#
# Regression test for workflow-skills#76.
#
# `status` is a read-only special variable in zsh (its $? alias). The
# SUMMARY loop's `read -r status label` fatally errored under zsh — whether
# invoked directly or via a caller that runs `zsh script.sh` instead of
# respecting the bash shebang. The SUMMARY *header* still printed, but the
# PASS/FAIL/WARN rows and the closing "Result:" line never did, and the
# script died with exit 1 (zsh's own reaction to the read-only assignment)
# rather than reaching its real pass/fail logic — a crash for the wrong
# reason on every zsh invocation, not a false "all checks passed." The
# status-marker write further down never ran either, and git-push-gate.sh
# treats a missing marker as "never run" and fails open — that's the actual
# silent-allow risk, not the script's own exit code. The fix renames the
# loop variable to `res`.
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

if ! command -v zsh >/dev/null 2>&1; then
  skip "workflow-skills#76: zsh not found on this host — cannot exercise the zsh invocation path"
  exit 0
fi

# A fixture that should record a real, non-silent finding — a WARN, per
# #71's fix — so the test can tell "SUMMARY rendered and reported it" apart
# from "SUMMARY silently never ran and nothing was printed."
work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-zsh-summary.XXXXXX")"
TMP_DIRS+=("$work")
mkdir -p "$work/tests"
cat > "$work/pyproject.toml" <<'EOF'
[project]
name = "repro"
version = "0.1.0"
EOF
cat > "$work/tests/test_ok.py" <<'EOF'
def test_ok():
    assert True
EOF

# python3 present (so $PY resolves) but unable to import pytest — forces the
# #71 WARN path, independent of whatever's actually installed on this host.
bin="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-zsh-summary-bin.XXXXXX")"
TMP_DIRS+=("$bin")
cat > "$bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$bin/python3"

out="$(cd "$work" && PATH="$bin:$PATH" zsh "$LOCAL_CI" --no-fix --no-build . 2>&1)"
rc=$?

case "$out" in
  *"read-only variable: status"*)
    fail "workflow-skills#76: SUMMARY loop still dies on zsh's read-only \$status. Output:
$out" ;;
  *) pass "workflow-skills#76: no read-only-variable error under zsh" ;;
esac
# Match the actual rendered row text, not a bare "WARN" substring — the
# closing "Result: no FAILs, but findings are WARN..." line is produced
# independently of this loop (a separate grep over $RESULTS_FILE, further
# down the script) and would still contain "WARN" even if the loop body
# itself silently did nothing, which a bare substring match can't tell apart
# from an actually-rendered row.
case "$out" in
  *"! WARN"*)
    pass "workflow-skills#76: SUMMARY actually rendered a WARN row under zsh" ;;
  *)
    fail "workflow-skills#76: expected a rendered '! WARN' row under zsh; none printed. Output:
$out" ;;
esac
# A WARN-only run never sets FAILED, so a correctly-completing SUMMARY loop
# exits 0 here. Before the fix, the crash on the read-only assignment is a
# zsh-fatal error and exits 1 instead — so this also catches the loop dying
# even in a case where the string checks above might otherwise both pass by
# accident (e.g. "WARN" appearing pre-crash in already-flushed output).
if [ "$rc" -eq 0 ]; then
  pass "workflow-skills#76: exits 0 on a WARN-only run under zsh (loop ran to completion)"
else
  fail "workflow-skills#76: exited $rc instead of 0 on a WARN-only run under zsh. Output:
$out"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAILURES check(s) failed."
  exit 1
fi
