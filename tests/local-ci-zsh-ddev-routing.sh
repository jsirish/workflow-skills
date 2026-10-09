#!/usr/bin/env bash
#
# Regression test for the `ddev exec` routing failure when local-ci.sh is
# started with `zsh local-ci.sh` instead of `bash local-ci.sh`.
#
# local-ci.sh builds its DDEV prefix as a string ("ddev exec") and splices it
# unquoted into run(): `X $PRE "$@"`. bash splits that into two words; zsh does
# not, so the dev/build and phpcbf steps died with
#   X:5: command not found: ddev exec
# while the composer steps (which use a differently built prefix) still ran.
# The script's shebang is bash and SKILL.md documents `bash <path>/local-ci.sh`,
# but callers that start it with `zsh` (an autobuild loop did) hit the failure
# and reported a red baseline that no diff caused. The script now re-runs itself
# under bash when it finds itself in zsh.
#
# A stub `ddev` on PATH records its argv, so the test asserts what was actually
# routed rather than parsing the summary text. Plain bash, no framework.

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
  if [ -n "${CI:-}" ]; then
    echo "FAIL: zsh not found and CI is set - the zsh regression would go unrun" >&2
    exit 1
  fi
  skip "zsh not found on this host - cannot exercise the zsh invocation path"
  exit 0
fi

base="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test-zsh-ddev.XXXXXX")"
TMP_DIRS+=("$base")
mkdir -p "$base/bin" "$base/proj/.ddev" "$base/proj/vendor/bin" "$base/proj/src"

cat > "$base/bin/ddev" <<'EOF'
#!/bin/sh
echo "DDEV-ARGV: $*" >> "$DDEV_LOG"
exit 0
EOF
chmod +x "$base/bin/ddev"

printf 'name: reprox\ntype: php\n' > "$base/proj/.ddev/config.yaml"
printf '{"name":"x/y","require":{"silverstripe/framework":"^6"}}\n' > "$base/proj/composer.json"
printf '#!/bin/sh\nexit 0\n' > "$base/proj/vendor/bin/sake"
chmod +x "$base/proj/vendor/bin/sake"
printf '<?php\nclass A {}\n' > "$base/proj/src/A.php"
: > "$base/proj/vendor/autoload.php"
git -C "$base/proj" init -q 2>/dev/null

run_with() {
  local shell_bin="$1" log="$base/ddev-$1.log"
  : > "$log"
  OUT="$(cd "$base/proj" && DDEV_LOG="$log" PATH="$base/bin:$PATH" "$shell_bin" "$LOCAL_CI" --no-fix --strict-build 2>&1)"
  LOG="$log"
}

for sh in bash zsh; do
  run_with "$sh"
  if printf '%s' "$OUT" | /usr/bin/grep -q 'command not found: ddev exec'; then
    fail "$sh: 'command not found: ddev exec' - the DDEV prefix was passed to the shell as one word"
  else
    pass "$sh: no 'command not found: ddev exec'"
  fi
  if /usr/bin/grep -q 'DDEV-ARGV: exec vendor/bin/sake dev/build' "$LOG"; then
    pass "$sh: dev/build was routed through 'ddev exec'"
  else
    fail "$sh: dev/build never reached ddev. ddev saw: $(tr '\n' ';' < "$LOG")"
  fi
done

# Run a command with a hard time limit enforced from outside (a re-exec loop
# keeps one PID and ignores an in-process alarm, so the test must kill it).
# Output goes to $BOUNDED_OUT; the return code is 124 on timeout.
run_bounded() {
  local limit="$1"; shift
  BOUNDED_OUT="$base/bounded.out"
  : > "$BOUNDED_OUT"
  "$@" >"$BOUNDED_OUT" 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((limit * 5)) ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
    i=$((i + 1))
  done
  wait "$pid"
}

# The re-exec guard must not loop when bash itself inherits ZSH_VERSION from
# its environment (a parent shell or dotfile can export it).
ZSH_VERSION=5.9 run_bounded 20 bash "$LOCAL_CI" --help
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "bash with an inherited ZSH_VERSION does not re-exec in a loop"
else
  fail "bash with an inherited ZSH_VERSION did not finish cleanly (rc=$rc; 124 means it was still looping after 20s)"
fi

# Sourcing from zsh must not replace the caller's shell with bash.
run_bounded 20 zsh -c "source '$LOCAL_CI' --help; echo AFTER-SOURCE"
out="$(cat "$BOUNDED_OUT")"
if printf '%s' "$out" | /usr/bin/grep -q 'AFTER-SOURCE' && printf '%s' "$out" | /usr/bin/grep -q 'run it with bash'; then
  pass "sourcing from zsh reports the problem and leaves the caller's shell alive"
else
  fail "sourcing from zsh replaced or crashed the caller's shell. Output: $out"
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
fi
echo "$FAILURES check(s) failed."
exit 1
