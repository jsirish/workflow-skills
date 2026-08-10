#!/usr/bin/env bash
#
# Regression test for workflow-skills#70 and #71 — both inside py_checks()'s
# pytest/ruff resolution.
#
# #71: when pytest cannot be resolved (no global binary, no venv, and $PY
# can't import it), the pytest block recorded *nothing* — not FAIL, not WARN,
# not SKIP. On a repo with genuinely failing tests and no other check config,
# that silence made the SUMMARY print "No recognised check configs found" /
# "all checks passed" with exit 0. The fix makes "pytest unresolvable but
# tests exist" its own WARN outcome, distinct from "pytest resolvable but no
# tests" (SKIP).
#
# #70: $PY / pytest / ruff resolution only ever looked at a bare `python3`/
# `python` on PATH or a global `pytest`/`ruff` binary — never a project-local
# .venv, where a uv-managed project keeps its pinned tooling. The fix adds a
# VENV_BIN lookup — this dir's own ./.venv, else ./venv, else (only as a
# fallback, since py_checks runs once per scanned dir and a process-global
# $VIRTUAL_ENV shouldn't silently override every dir's own venv in a
# multi-dir scan) an active $VIRTUAL_ENV — that takes priority over the
# global binary and a stray older/newer globally installed one.
#
# Cases 1 and 3 need genuine ABSENCE of a global pytest/ruff to be meaningful
# — on a dev machine that already lacks both (true for most), that's already
# the case, but this test must not silently pass-by-accident on a machine
# that happens to have them installed. So it builds a curated, EXCLUSIVE PATH
# (a fresh dir of symlinks to only the core utilities local-ci.sh itself
# needs, resolved from the real PATH) rather than prepending stubs to the
# existing PATH — prepending can't hide a real global pytest/ruff sitting
# further down PATH, only shadow-and-still-find it. If a required utility
# can't be resolved on this host, the affected case SKIPs with a named reason
# instead of failing. Every invocation also passes `VIRTUAL_ENV=` to blank
# out whatever the *test runner's own* shell happens to have active — without
# this, a developer running this suite from inside an activated venv would
# get false results in cases 1-4 (an ambient venv resolving pytest/ruff that
# the fixture never provides). Case 5 below is the one case that turns
# $VIRTUAL_ENV back on deliberately, to test that exact fallback path.
#
# Plain bash, no test framework dependency — mirrors local-ci-vendor-bin.sh.

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

ORIGINAL_PATH="$PATH"

# The external utilities local-ci.sh itself needs while scanning a plain
# pyproject.toml(+tests/) fixture with no composer.json, package.json, *.sh
# files, or .local-ci.json — the PHP/JS/shell/custom drivers each bail out
# via a cheap `[ -f ... ]` / file-list-empty check before probing for their
# own tools (composer, node, shellcheck, jq), so those aren't needed here.
# Bash builtins (test, printf, cd, trap, command, echo) need no entry.
REQUIRED_TOOLS="bash git awk basename cksum date dirname find grep head mktemp rm sed tr cat mkdir sort wc"

# Build a directory containing only symlinks to the tools above (resolved
# from the real, unrestricted PATH) plus whatever case-specific stub scripts
# the caller writes into it afterward. Returns 1 (via empty stdout) and lists
# the unresolvable tools on stderr if something required is missing — the
# caller should skip rather than fail in that case.
build_exclusive_bin() { # out_var_name
  local dir missing tool resolved
  dir="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-bin.XXXXXX")"
  TMP_DIRS+=("$dir")
  missing=""
  for tool in $REQUIRED_TOOLS; do
    resolved="$(PATH="$ORIGINAL_PATH" command -v "$tool" 2>/dev/null || true)"
    if [ -n "$resolved" ]; then
      ln -s "$resolved" "$dir/$tool"
    else
      missing="$missing $tool"
    fi
  done
  if [ -n "$missing" ]; then
    printf '%s\n' "MISSING:$missing" >&2
    return 1
  fi
  printf '%s\n' "$dir"
}

# ===== Case 1 (#71): pytest unresolvable, tests present -> WARN, not silent

run_case1() {
  local bin work fixture out
  if ! bin="$(build_exclusive_bin 2>/tmp/local-ci-test-case1-missing.$$)"; then
    skip "Case 1 (#71): cannot build exclusive PATH — missing:$(cat /tmp/local-ci-test-case1-missing.$$ | sed 's/^MISSING://')"
    rm -f "/tmp/local-ci-test-case1-missing.$$"
    return
  fi
  rm -f "/tmp/local-ci-test-case1-missing.$$"

  # python3 stub: exists (so $PY resolves) but every `-c 'import X'` fails,
  # matching a system Python with neither pytest nor ruff installed. No
  # `pytest`/`ruff` binary is placed in $bin at all.
  cat > "$bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$bin/python3"

  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-case1.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture/tests"
  cat > "$fixture/pyproject.toml" <<'EOF'
[project]
name = "repro"
version = "0.1.0"
EOF
  cat > "$fixture/tests/test_thing.py" <<'EOF'
def test_that_would_fail():
    assert 1 == 2
EOF

  out="$(cd "$work" && PATH="$bin" VIRTUAL_ENV= bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"WARN"*"pytest"*"not installed"*|*"WARN"*"pytest"*"not"*"importable"*)
      pass "Case 1 (#71): WARN row recorded naming pytest" ;;
    *)
      fail "Case 1 (#71): expected a WARN row naming pytest as unresolvable. Output:
$out" ;;
  esac
  case "$out" in
    *"No recognised check configs found"*)
      fail "Case 1 (#71): summary still claims nothing was recognised — the silent-vanish bug. Output:
$out" ;;
    *) pass "Case 1 (#71): summary does not claim nothing was recognised" ;;
  esac
  case "$out" in
    *"Result: all checks passed."*)
      fail "Case 1 (#71): reported \"all checks passed\" despite an unresolvable pytest over real failing tests. Output:
$out" ;;
    *) pass "Case 1 (#71): did not report \"all checks passed\"" ;;
  esac

  # Not escalated by --strict, matching the sibling "ruff adopted but not
  # installed" WARN a few lines above it in local-ci.sh: both are bare
  # `record WARN` calls describing an environment/tooling gap local-ci
  # itself hit, not a check that ran and found a real problem — --strict's
  # gate/lint/build escalation applies only to the latter (via
  # effective_sev/record_sev). Assert the WARN still shows under --strict
  # too (same static condition, not suppressed) rather than asserting a
  # non-zero exit, which the codebase's own convention doesn't produce here.
  out="$(cd "$work" && PATH="$bin" VIRTUAL_ENV= bash "$LOCAL_CI" --no-fix --strict "$fixture" 2>&1)"
  case "$out" in
    *"WARN"*"pytest"*) pass "Case 1 (#71): WARN row still present under --strict" ;;
    *) fail "Case 1 (#71): WARN row missing under --strict. Output:
$out" ;;
  esac
}

# ===== Case 2 (#70): venv pytest chosen when no global pytest exists

run_case2() {
  local bin work fixture out marker
  if ! bin="$(build_exclusive_bin 2>/tmp/local-ci-test-case2-missing.$$)"; then
    skip "Case 2 (#70): cannot build exclusive PATH — missing:$(cat /tmp/local-ci-test-case2-missing.$$ | sed 's/^MISSING://')"
    rm -f "/tmp/local-ci-test-case2-missing.$$"
    return
  fi
  rm -f "/tmp/local-ci-test-case2-missing.$$"

  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-case2.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture/tests" "$fixture/.venv/bin"
  cat > "$fixture/pyproject.toml" <<'EOF'
[project]
name = "repro"
version = "0.1.0"
EOF
  cat > "$fixture/tests/test_thing.py" <<'EOF'
def test_ok():
    assert 1 == 1
EOF

  marker="LOCAL_CI_TEST_VENV_PYTEST_RAN_$$"
  cat > "$fixture/.venv/bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$fixture/.venv/bin/pytest" <<EOF
#!/usr/bin/env bash
echo "$marker"
exit 0
EOF
  chmod +x "$fixture/.venv/bin/python3" "$fixture/.venv/bin/pytest"

  out="$(cd "$work" && PATH="$bin" VIRTUAL_ENV= bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"$marker"*) pass "Case 2 (#70): .venv/bin/pytest was invoked (no global pytest available)" ;;
    *) fail "Case 2 (#70): .venv/bin/pytest marker never printed. Output:
$out" ;;
  esac
}

# ===== Case 3 (#70): venv ruff preferred over a same-named global ruff

run_case3() {
  local bin work fixture out marker_venv marker_global
  if ! bin="$(build_exclusive_bin 2>/tmp/local-ci-test-case3-missing.$$)"; then
    skip "Case 3 (#70): cannot build exclusive PATH — missing:$(cat /tmp/local-ci-test-case3-missing.$$ | sed 's/^MISSING://')"
    rm -f "/tmp/local-ci-test-case3-missing.$$"
    return
  fi
  rm -f "/tmp/local-ci-test-case3-missing.$$"

  marker_global="LOCAL_CI_TEST_GLOBAL_RUFF_RAN_$$"
  cat > "$bin/ruff" <<EOF
#!/usr/bin/env bash
echo "$marker_global"
exit 0
EOF
  chmod +x "$bin/ruff"
  cat > "$bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$bin/python3"

  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-case3.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture/.venv/bin"
  cat > "$fixture/pyproject.toml" <<'EOF'
[project]
name = "repro"
version = "0.1.0"

[tool.ruff]
line-length = 100
EOF

  marker_venv="LOCAL_CI_TEST_VENV_RUFF_RAN_$$"
  cat > "$fixture/.venv/bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$fixture/.venv/bin/ruff" <<EOF
#!/usr/bin/env bash
echo "$marker_venv"
exit 0
EOF
  chmod +x "$fixture/.venv/bin/python3" "$fixture/.venv/bin/ruff"

  out="$(cd "$work" && PATH="$bin" VIRTUAL_ENV= bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"$marker_venv"*) pass "Case 3 (#70): .venv/bin/ruff was invoked" ;;
    *) fail "Case 3 (#70): .venv/bin/ruff marker never printed. Output:
$out" ;;
  esac
  case "$out" in
    *"$marker_global"*) fail "Case 3 (#70): the global ruff stub also ran — venv ruff was not preferred. Output:
$out" ;;
    *) pass "Case 3 (#70): the global ruff stub did not run" ;;
  esac
}

# ===== Case 4 (no regression): pytest resolvable, no tests -> SKIP, as before

run_case4() {
  local bin work fixture out marker
  if ! bin="$(build_exclusive_bin 2>/tmp/local-ci-test-case4-missing.$$)"; then
    skip "Case 4: cannot build exclusive PATH — missing:$(cat /tmp/local-ci-test-case4-missing.$$ | sed 's/^MISSING://')"
    rm -f "/tmp/local-ci-test-case4-missing.$$"
    return
  fi
  rm -f "/tmp/local-ci-test-case4-missing.$$"

  marker="LOCAL_CI_TEST_PYTEST_SHOULD_NOT_RUN_$$"
  cat > "$bin/pytest" <<EOF
#!/usr/bin/env bash
echo "$marker"
exit 0
EOF
  chmod +x "$bin/pytest"
  cat > "$bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$bin/python3"

  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-case4.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture"
  cat > "$fixture/pyproject.toml" <<'EOF'
[project]
name = "repro"
version = "0.1.0"
EOF

  out="$(cd "$work" && PATH="$bin" VIRTUAL_ENV= bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"SKIP"*"pytest"*"no tests found"*) pass "Case 4: SKIP (no tests found) still recorded" ;;
    *) fail "Case 4: expected SKIP row for pytest (no tests found). Output:
$out" ;;
  esac
  case "$out" in
    *"$marker"*) fail "Case 4: pytest was actually invoked despite no tests existing. Output:
$out" ;;
    *) pass "Case 4: pytest binary was not invoked" ;;
  esac
}

# ===== Case 5 (#70): $VIRTUAL_ENV used as a fallback when this dir has no
# on-disk venv of its own — but does NOT override a dir that does have one
# (the precedence bug flagged in review: a process-global $VIRTUAL_ENV must
# not silently win over a dir's own ./.venv in a multi-dir scan).

run_case5() {
  local bin work fixture venv_dir out marker
  if ! bin="$(build_exclusive_bin 2>/tmp/local-ci-test-case5-missing.$$)"; then
    skip "Case 5 (#70): cannot build exclusive PATH — missing:$(cat /tmp/local-ci-test-case5-missing.$$ | sed 's/^MISSING://')"
    rm -f "/tmp/local-ci-test-case5-missing.$$"
    return
  fi
  rm -f "/tmp/local-ci-test-case5-missing.$$"
  cat > "$bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$bin/python3"

  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-case5.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture/tests"
  cat > "$fixture/pyproject.toml" <<'EOF'
[project]
name = "repro"
version = "0.1.0"
EOF
  cat > "$fixture/tests/test_ok.py" <<'EOF'
def test_ok():
    assert 1 == 1
EOF

  venv_dir="$work/activated-venv"
  mkdir -p "$venv_dir/bin"
  marker="LOCAL_CI_TEST_ACTIVATED_VENV_PYTEST_RAN_$$"
  cat > "$venv_dir/bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$venv_dir/bin/pytest" <<EOF
#!/usr/bin/env bash
echo "$marker"
exit 0
EOF
  chmod +x "$venv_dir/bin/python3" "$venv_dir/bin/pytest"

  # No .venv/venv on disk in the fixture itself — VIRTUAL_ENV is the only
  # tool source available, so it must be used, not silently ignored.
  out="$(cd "$work" && PATH="$bin" VIRTUAL_ENV="$venv_dir" bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"$marker"*) pass "Case 5 (#70): \$VIRTUAL_ENV used as fallback when the dir has no venv of its own" ;;
    *) fail "Case 5 (#70): \$VIRTUAL_ENV/bin/pytest marker never printed. Output:
$out" ;;
  esac
}

# ===== Case 6 (review finding, code-reviewer on PR#73): a venv path
# containing a space (as $VIRTUAL_ENV commonly is — it's an absolute path
# derived from wherever the enclosing project/container happens to live) must
# not break word-splitting when embedded into the pytest/ruff command strings.

run_case6() {
  local bin work fixture venv_dir out marker_pytest marker_ruff
  if ! bin="$(build_exclusive_bin 2>/tmp/local-ci-test-case6-missing.$$)"; then
    skip "Case 6: cannot build exclusive PATH — missing:$(cat /tmp/local-ci-test-case6-missing.$$ | sed 's/^MISSING://')"
    rm -f "/tmp/local-ci-test-case6-missing.$$"
    return
  fi
  rm -f "/tmp/local-ci-test-case6-missing.$$"
  cat > "$bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$bin/python3"

  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-case6.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture/tests"
  cat > "$fixture/pyproject.toml" <<'EOF'
[project]
name = "repro"
version = "0.1.0"

[tool.ruff]
line-length = 100
EOF
  cat > "$fixture/tests/test_ok.py" <<'EOF'
def test_ok():
    assert 1 == 1
EOF

  venv_dir="$work/an env with spaces"
  mkdir -p "$venv_dir/bin"
  marker_pytest="LOCAL_CI_TEST_SPACE_PATH_PYTEST_RAN_$$"
  marker_ruff="LOCAL_CI_TEST_SPACE_PATH_RUFF_RAN_$$"
  cat > "$venv_dir/bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$venv_dir/bin/pytest" <<EOF
#!/usr/bin/env bash
echo "$marker_pytest"
exit 0
EOF
  cat > "$venv_dir/bin/ruff" <<EOF
#!/usr/bin/env bash
echo "$marker_ruff"
exit 0
EOF
  chmod +x "$venv_dir/bin/python3" "$venv_dir/bin/pytest" "$venv_dir/bin/ruff"

  out="$(cd "$work" && PATH="$bin" VIRTUAL_ENV="$venv_dir" bash "$LOCAL_CI" --no-fix "$fixture" 2>&1)"

  case "$out" in
    *"No such file or directory"*)
      fail "Case 6: local-ci reported 'No such file or directory' — a space in the venv path broke word-splitting. Output:
$out" ;;
    *) pass "Case 6: no 'No such file or directory' error from the space-containing venv path" ;;
  esac
  case "$out" in
    *"$marker_pytest"*) pass "Case 6: pytest ran correctly from a venv path containing a space" ;;
    *) fail "Case 6: pytest marker never printed. Output:
$out" ;;
  esac
  case "$out" in
    *"$marker_ruff"*) pass "Case 6: ruff ran correctly from a venv path containing a space" ;;
    *) fail "Case 6: ruff marker never printed. Output:
$out" ;;
  esac
}

run_case1
run_case2
run_case3
run_case4
run_case5
run_case6

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAILURES check(s) failed."
  exit 1
fi
