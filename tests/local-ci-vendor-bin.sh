#!/usr/bin/env bash
#
# Regression test for workflow-skills#66 (and the related, unreported nested-
# DDEV defect from the same commit, 0341584 / #64).
#
# Bug 1 (#66): $VENDOR_BIN was referenced *unexpanded* inside a single-quoted
# `bash -c '...'` body for phpunit/phpcs/phpstan/behat. Since VENDOR_BIN is
# `local` and never exported, the nested subshell saw it as empty and ran
# `/phpunit` (filesystem root) instead of `vendor/bin/phpunit`.
#
# Bug 2 (found while fixing #66, not in the original issue): in the *nested*
# DDEV case, VENDOR_BIN resolves to a HOST absolute path
# ($ENCLOSING_ROOT/vendor/bin), but the tool invocations that use it run
# INSIDE the DDEV container via `ddev exec` — where that host path does not
# exist. The fix (see local-ci.sh) splits VENDOR_BIN (host-side, for the
# [ -x ... ] guards) from VENDOR_BIN_RUN (exec-side, /var/www/html/vendor/bin
# when nested) and routes each call site to the right one.
#
# Part A is a static guard directly against the #66 regression class: no
# literal, unexpanded "$VENDOR_BIN/" may survive inside a bash -c body.
# Parts B and C are functional: B drives the plain non-nested case end to
# end with stubbed vendor/bin/* binaries (the case #66 reported broken);
# C drives the nested case with a stubbed `ddev` binary and asserts the
# intercepted command uses the container path, not the host path (the case
# #64 was written for but — per the ddev-exec check below — never actually
# worked until this fix, since sake/phpcbf already used the host path
# unconditionally).
#
# Plain bash, no test framework dependency — first test in this repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_CI="$REPO_ROOT/skills/local-ci/scripts/local-ci.sh"
FILE="$LOCAL_CI"

[ -f "$LOCAL_CI" ] || { echo "FAIL: cannot find local-ci.sh at $LOCAL_CI" >&2; exit 1; }

FAILURES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }
skip() { printf 'SKIP: %s\n' "$1"; }

TMP_DIRS=()
cleanup() { for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# ===== Part A: exact-substring guard against unexpanded/misrouted VENDOR_BIN
#
# Matches the literal, fully-expanded invocation text anywhere in the file,
# not a line-count context window — a window is layout-fragile (a harmless
# reflow of a neighboring line shifts its boundary) and can either miss the
# site or swallow an unrelated line (e.g. the WARN text a few lines down
# that legitimately contains the host-side "$VENDOR_BIN/" — that one is
# correct and must never be flagged). For the four `bash -c` sites
# (phpunit/phpcs/phpstan/behat) this also guards a variant of #66's own bug
# class against the *new* variable: VENDOR_BIN_RUN referenced but left
# unquoted inside the single-quoted bash -c body would still expand to
# nothing in the nested subshell, exactly like the original bug — so the
# positive assertion is the full, correctly outer-shell-expanded text, not
# a bare "does VENDOR_BIN_RUN appear nearby" substring check (which a
# reintroduced unquoted reference would silently pass).

site_ok() { # description  ok-literal
  if grep -qF "$2" "$FILE"; then
    pass "Part A ($1): correctly-expanded invocation present"
  else
    fail "Part A ($1): expected exact invocation text not found — either #66's unexpanded-variable bug has recurred, or VENDOR_BIN_RUN is present but not properly outer-shell-quoted. Expected:
$2"
  fi
}

site_bad_absent() { # description  bad-literal  why
  if grep -qF "$2" "$FILE"; then
    fail "Part A ($1): $3. Found:
$2"
  fi
}

PHPUNIT_OK=$(cat <<'EOF'
"'"$VENDOR_BIN_RUN"'/phpunit" --colors=always; else "'"$VENDOR_BIN_RUN"'/phpunit"
EOF
)
PHPUNIT_BAD_HOST=$(cat <<'EOF'
"$VENDOR_BIN/phpunit" --colors=always; else "$VENDOR_BIN/phpunit"
EOF
)
PHPUNIT_BAD_UNQUOTED=$(cat <<'EOF'
"$VENDOR_BIN_RUN/phpunit" --colors=always; else "$VENDOR_BIN_RUN/phpunit"
EOF
)
site_ok "phpunit" "$PHPUNIT_OK"
site_bad_absent "phpunit" "$PHPUNIT_BAD_HOST" "unexpanded host-side \$VENDOR_BIN literal in a bash -c body — the original #66 bug"
site_bad_absent "phpunit" "$PHPUNIT_BAD_UNQUOTED" "VENDOR_BIN_RUN referenced but not outer-shell-expanded — same bug class as #66, against the new variable"

PHPCS_OK=$(cat <<'EOF'
$R "'"$VENDOR_BIN_RUN"'/phpcs" -s --report=summary
EOF
)
PHPCS_BAD_HOST=$(cat <<'EOF'
$R "$VENDOR_BIN/phpcs" -s --report=summary
EOF
)
PHPCS_BAD_UNQUOTED=$(cat <<'EOF'
$R "$VENDOR_BIN_RUN/phpcs" -s --report=summary
EOF
)
site_ok "phpcs" "$PHPCS_OK"
site_bad_absent "phpcs" "$PHPCS_BAD_HOST" "unexpanded host-side \$VENDOR_BIN literal in a bash -c body — the original #66 bug"
site_bad_absent "phpcs" "$PHPCS_BAD_UNQUOTED" "VENDOR_BIN_RUN referenced but not outer-shell-expanded — same bug class as #66, against the new variable"

PHPSTAN_OK=$(cat <<'EOF'
"'"$VENDOR_BIN_RUN"'/phpstan" analyse --no-progress; else "'"$VENDOR_BIN_RUN"'/phpstan"
EOF
)
PHPSTAN_BAD_HOST=$(cat <<'EOF'
"$VENDOR_BIN/phpstan" analyse --no-progress; else "$VENDOR_BIN/phpstan"
EOF
)
PHPSTAN_BAD_UNQUOTED=$(cat <<'EOF'
"$VENDOR_BIN_RUN/phpstan" analyse --no-progress; else "$VENDOR_BIN_RUN/phpstan"
EOF
)
site_ok "phpstan" "$PHPSTAN_OK"
site_bad_absent "phpstan" "$PHPSTAN_BAD_HOST" "unexpanded host-side \$VENDOR_BIN literal in a bash -c body — the original #66 bug"
site_bad_absent "phpstan" "$PHPSTAN_BAD_UNQUOTED" "VENDOR_BIN_RUN referenced but not outer-shell-expanded — same bug class as #66, against the new variable"

BEHAT_OK=$(cat <<'EOF'
"'"$VENDOR_BIN_RUN"'/behat" --colors --strict; else "'"$VENDOR_BIN_RUN"'/behat"
EOF
)
BEHAT_BAD_HOST=$(cat <<'EOF'
"$VENDOR_BIN/behat" --colors --strict; else "$VENDOR_BIN/behat"
EOF
)
BEHAT_BAD_UNQUOTED=$(cat <<'EOF'
"$VENDOR_BIN_RUN/behat" --colors --strict; else "$VENDOR_BIN_RUN/behat"
EOF
)
site_ok "behat" "$BEHAT_OK"
site_bad_absent "behat" "$BEHAT_BAD_HOST" "unexpanded host-side \$VENDOR_BIN literal in a bash -c body — the original #66 bug"
site_bad_absent "behat" "$BEHAT_BAD_UNQUOTED" "VENDOR_BIN_RUN referenced but not outer-shell-expanded — same bug class as #66, against the new variable"

# sake and phpcbf go through run() (always outer-shell double-quoted, never
# nested in a bash -c single-quoted body), so there's no "unquoted" failure
# mode for them — only "wrong variable" (host path instead of exec path).
SAKE_OK='run "$VENDOR_BIN_RUN/sake" dev/build flush=1'
SAKE_BAD='run "$VENDOR_BIN/sake" dev/build flush=1'
site_ok "sake" "$SAKE_OK"
site_bad_absent "sake" "$SAKE_BAD" "host-side \$VENDOR_BIN used for the actual invocation instead of VENDOR_BIN_RUN — breaks the nested-DDEV case (Bug 2)"

PHPCBF_OK='run "$VENDOR_BIN_RUN/phpcbf" --standard="$std" $paths'
PHPCBF_BAD='run "$VENDOR_BIN/phpcbf" --standard="$std" $paths'
site_ok "phpcbf" "$PHPCBF_OK"
site_bad_absent "phpcbf" "$PHPCBF_BAD" "host-side \$VENDOR_BIN used for the actual invocation instead of VENDOR_BIN_RUN — breaks the nested-DDEV case (Bug 2)"

# ===== Part B: functional, non-nested (the case #66 reported) ============
# A plain project (no DDEV, not under vendor/) with stubbed vendor/bin/phpunit
# and vendor/bin/phpcs that each print a unique marker and exit 0. Before the
# fix, the subshell saw $VENDOR_BIN unset and tried to exec "/phpunit" —
# the markers below would never print, and "No such file or directory" would.

run_part_b() {
  local work fixture stub_bin out marker_unit marker_cs
  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-nonnested.XXXXXX")"
  TMP_DIRS+=("$work")
  fixture="$work/proj"
  mkdir -p "$fixture/vendor/bin"

  cat > "$fixture/composer.json" <<'EOF'
{"name": "test/fixture"}
EOF
  cat > "$fixture/phpunit.xml" <<'EOF'
<phpunit></phpunit>
EOF
  cat > "$fixture/.phpcs.xml" <<'EOF'
<ruleset name="fixture"></ruleset>
EOF

  marker_unit="LOCAL_CI_TEST_PHPUNIT_RAN_$$"
  marker_cs="LOCAL_CI_TEST_PHPCS_RAN_$$"
  cat > "$fixture/vendor/bin/phpunit" <<EOF
#!/usr/bin/env bash
echo "$marker_unit"
exit 0
EOF
  cat > "$fixture/vendor/bin/phpcs" <<EOF
#!/usr/bin/env bash
echo "$marker_cs"
exit 0
EOF
  chmod +x "$fixture/vendor/bin/phpunit" "$fixture/vendor/bin/phpcs"

  # No-op composer stub so composer validate/install (dry-run) don't depend
  # on a real composer being installed on whatever machine runs this test.
  stub_bin="$work/stubbin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/composer" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_bin/composer"

  out="$(cd "$work" && PATH="$stub_bin:$PATH" bash "$LOCAL_CI" "$fixture" 2>&1)"

  case "$out" in
    *"$marker_unit"*) pass "Part B (non-nested): phpunit stub executed" ;;
    *) fail "Part B (non-nested): phpunit stub never ran (marker missing). Output:
$out" ;;
  esac
  case "$out" in
    *"$marker_cs"*) pass "Part B (non-nested): phpcs stub executed" ;;
    *) fail "Part B (non-nested): phpcs stub never ran (marker missing). Output:
$out" ;;
  esac
  case "$out" in
    *"No such file or directory"*)
      fail "Part B (non-nested): local-ci reported 'No such file or directory' — the exact #66 symptom. Output:
$out"
      ;;
    *) pass "Part B (non-nested): no 'No such file or directory' error" ;;
  esac
}

# ===== Part C: functional, nested under a DDEV project's vendor/ (the case
# #64 was written for) — no real DDEV needed, `ddev` itself is stubbed to log
# its argv. Asserts the intercepted command targets the CONTAINER vendor/bin
# path (/var/www/html/vendor/bin/phpunit), not the HOST path that #64 left
# broken (Bug 2 above).

run_part_c() {
  local work root nested stub_bin ddev_log out_log
  work="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-nested.XXXXXX")"
  TMP_DIRS+=("$work")
  root="$work/enclosing"
  nested="$root/vendor/dynamic/pkg"
  mkdir -p "$root/.ddev" "$root/vendor/bin" "$nested"

  cat > "$root/.ddev/config.yaml" <<'EOF'
name: testproj
type: php
EOF
  cat > "$root/composer.json" <<'EOF'
{"name": "test/enclosing"}
EOF
  cat > "$root/vendor/bin/phpunit" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$root/vendor/bin/phpcs" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$root/vendor/bin/phpunit" "$root/vendor/bin/phpcs"

  if ! command -v git >/dev/null 2>&1; then
    skip "Part C (nested): git not found on PATH — cannot build the nested-checkout fixture"
    return
  fi
  (
    cd "$nested" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    : > .gitkeep
    git add .gitkeep
    git commit -q -m init
  )
  cat > "$nested/composer.json" <<'EOF'
{"name": "dynamic/pkg"}
EOF
  cat > "$nested/phpunit.xml" <<'EOF'
<phpunit></phpunit>
EOF
  cat > "$nested/.phpcs.xml" <<'EOF'
<ruleset name="fixture"></ruleset>
EOF

  stub_bin="$work/stubbin"
  mkdir -p "$stub_bin"
  ddev_log="$work/ddev-calls.log"
  : > "$ddev_log"
  cat > "$stub_bin/ddev" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$ddev_log"
exit 0
EOF
  chmod +x "$stub_bin/ddev"
  cat > "$stub_bin/composer" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_bin/composer"

  out_log="$work/out.log"
  (cd "$work" && PATH="$stub_bin:$PATH" bash "$LOCAL_CI" "$nested" >"$out_log" 2>&1)

  if [ ! -s "$ddev_log" ]; then
    fail "Part C (nested): the ddev stub was never invoked — nested DDEV routing didn't trigger. local-ci output:
$(cat "$out_log")"
    return
  fi

  if grep -qF '/var/www/html/vendor/bin/phpunit' "$ddev_log"; then
    pass "Part C (nested): ddev exec invoked with the container vendor/bin path"
  else
    fail "Part C (nested): ddev exec was never called with /var/www/html/vendor/bin/phpunit. Calls seen:
$(cat "$ddev_log")"
  fi

  if grep -qF "$root/vendor/bin/phpunit" "$ddev_log"; then
    fail "Part C (nested): ddev exec was called with the HOST vendor/bin path ($root/vendor/bin/phpunit) instead of the container path — this is Bug 2. Calls seen:
$(cat "$ddev_log")"
  else
    pass "Part C (nested): no host-path leaked into the container exec"
  fi

  if grep -qF '/var/www/html/vendor/bin/phpcs' "$ddev_log"; then
    pass "Part C (nested): phpcs also invoked with the container vendor/bin path"
  else
    fail "Part C (nested): ddev exec was never called with /var/www/html/vendor/bin/phpcs. Calls seen:
$(cat "$ddev_log")"
  fi

  if grep -qF "$root/vendor/bin/phpcs" "$ddev_log"; then
    fail "Part C (nested): ddev exec was called with the HOST phpcs path ($root/vendor/bin/phpcs) instead of the container path — this is Bug 2. Calls seen:
$(cat "$ddev_log")"
  else
    pass "Part C (nested): no host-path leaked into the container phpcs exec"
  fi

  if grep -qF "No such file or directory" "$out_log"; then
    fail "Part C (nested): local-ci reported 'No such file or directory'. Output:
$(cat "$out_log")"
  fi
}

run_part_b
run_part_c

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAILURES check(s) failed."
  exit 1
fi
