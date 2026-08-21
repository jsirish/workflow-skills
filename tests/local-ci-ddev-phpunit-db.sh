#!/usr/bin/env bash
#
# Regression test for workflow-skills#80.
#
# DDEV's default MySQL user (`db`/`db`, per `ddev describe`) is scoped to the
# project's own `db` database only. SilverStripe's SapphireTest/TempDatabase
# bootstrap creates a fresh, randomly-named `ss_tmpdb_*` database per PHPUnit
# run using whatever SS_DATABASE_USERNAME/PASSWORD the project's .env
# provides — normally that same restricted `db` user, correct for the app's
# runtime access but unable to CREATE DATABASE for an arbitrary new name. So
# every DDEV-routed PHPUnit run failed at DB setup before a single test ran,
# reported as a hard FAIL rather than a config problem local-ci itself could
# route around. The fix overrides SS_DATABASE_USERNAME/PASSWORD to DDEV's
# default root/root superuser, scoped to just the phpunit `ddev exec` call —
# never written to the project's .env, so the app's normal runtime DB access
# is untouched.
#
# Part A drives the DDEV-routed case with a stubbed `ddev` binary that
# echoes back whatever it was invoked with, and asserts the root/root
# override appears in the intercepted phpunit invocation. Part B drives the
# plain non-DDEV case (no .ddev/config.yaml) and asserts the override does
# NOT appear — root/root is a DDEV convention, meaningless (and never
# applied) on bare metal. Part B's stub prints the actual
# SS_DATABASE_USERNAME=<value> pair (not just the bare value, which could
# never disprove the variable was set at all — code-reviewer finding on PR
# #81 round 1); both invocations scrub SS_DATABASE_USERNAME/PASSWORD from
# the inherited environment first, so a developer's own shell exporting
# either (direnv, a debugging session) can't produce a spurious result in
# either direction (round 2 finding on the same PR).
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

TMP_DIRS=()
cleanup() { for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# ===== Part A: DDEV-routed — the root/root override must be present

run_part_a() {
  local work fixture stub_bin out
  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-ddevdb-a.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture/.ddev" "$fixture/vendor/bin"

  cat > "$fixture/composer.json" <<'EOF'
{"name": "test/fixture"}
EOF
  cat > "$fixture/.ddev/config.yaml" <<'EOF'
name: fixture
type: silverstripe
EOF
  cat > "$fixture/phpunit.xml" <<'EOF'
<phpunit></phpunit>
EOF
  # Never actually executed — ddev exec (stubbed below) intercepts the whole
  # command line as a string before it would run. Only needs to exist and be
  # +x so local-ci's host-side [ -x "$VENDOR_BIN/phpunit" ] gate passes.
  cat > "$fixture/vendor/bin/phpunit" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fixture/vendor/bin/phpunit"

  # A single stub answers both `ddev composer ...` (composer validate/
  # install, routed through composer_cmd_for_prefix) and `ddev exec ...`
  # (the phpunit invocation itself) — every call just echoes its argv and
  # exits 0, so composer's steps pass cleanly and the phpunit exec's exact
  # argv is captured in $out for assertion.
  stub_bin="$work/stubbin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/ddev" <<'EOF'
#!/usr/bin/env bash
echo "DDEV_STUB_ARGV: $*"
exit 0
EOF
  chmod +x "$stub_bin/ddev"
  # composer itself is never reached — "ddev composer"/"ddev exec" fully
  # short-circuit through the ddev stub above — but keep a no-op on PATH in
  # case composer_cmd_for_prefix's own detection ever calls it directly.
  cat > "$stub_bin/composer" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_bin/composer"

  out="$(cd "$work" && PATH="$stub_bin:$PATH" env -u SS_DATABASE_USERNAME -u SS_DATABASE_PASSWORD bash "$LOCAL_CI" --no-fix --no-build "$fixture" 2>&1)"

  case "$out" in
    *"DDEV_STUB_ARGV:"*"SS_DATABASE_USERNAME=root SS_DATABASE_PASSWORD=root"*"vendor/bin/phpunit"*)
      pass "Part A (#80): DDEV-routed phpunit invocation carries the root/root DB override" ;;
    *)
      fail "Part A (#80): expected the root/root override in the intercepted ddev exec call; not found. Output:
$out" ;;
  esac
}

# ===== Part B: non-DDEV — the override must NOT appear

run_part_b() {
  local work fixture stub_bin out marker
  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-ddevdb-b.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture/vendor/bin"

  cat > "$fixture/composer.json" <<'EOF'
{"name": "test/fixture"}
EOF
  cat > "$fixture/phpunit.xml" <<'EOF'
<phpunit></phpunit>
EOF
  marker="LOCAL_CI_TEST_PHPUNIT_RAN_$$"
  # Echo the actual key=value pair the process sees, not just the bare
  # value — a bare value can never prove the *variable name* wasn't set,
  # which is what this case needs to disprove. Falls back to "unset" so the
  # assertion below has something concrete to match against either way.
  cat > "$fixture/vendor/bin/phpunit" <<EOF
#!/usr/bin/env bash
echo "$marker" "SS_DATABASE_USERNAME=\${SS_DATABASE_USERNAME:-unset}"
exit 0
EOF
  chmod +x "$fixture/vendor/bin/phpunit"

  stub_bin="$work/stubbin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/composer" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_bin/composer"

  out="$(cd "$work" && PATH="$stub_bin:$PATH" env -u SS_DATABASE_USERNAME -u SS_DATABASE_PASSWORD bash "$LOCAL_CI" --no-fix --no-build "$fixture" 2>&1)"

  case "$out" in
    *"$marker"*) pass "Part B (non-DDEV): phpunit stub executed directly (no ddev routing)" ;;
    *) fail "Part B (non-DDEV): phpunit stub never ran (marker missing). Output:
$out" ;;
  esac
  case "$out" in
    *"SS_DATABASE_USERNAME=unset"*) pass "Part B (non-DDEV): no root/root override applied" ;;
    *)
      fail "Part B (non-DDEV): expected SS_DATABASE_USERNAME=unset (no override on a non-DDEV project); not found — either the override leaked in, or the stub's own env-print never ran. Output:
$out" ;;
  esac
}

run_part_a
run_part_b

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAILURES check(s) failed."
  exit 1
fi
