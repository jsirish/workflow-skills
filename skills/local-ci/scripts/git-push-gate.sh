#!/bin/bash
# PreToolUse(Bash) hook for Claude Code: gate `git push` on a fresh, non-failing
# local-ci run.
#
# Contract: local-ci.sh writes <git-dir>/local-ci-status as
#   sha=<HEAD-at-run> result=<PASS|FAIL|WARN|NONE> ts=<epoch>
#
# Gate rules:
#   - repo has no recognised executable check configs -> allow
#   - result=NONE (local-ci found nothing to run)     -> allow
#   - result=FAIL                                     -> block
#   - result=WARN                                     -> block (WARN is not a
#     green gate; investigate, then bypass if it is genuinely benign)
#   - result=PASS at HEAD                             -> allow
#   - result=PASS at an ancestor of HEAD, run < 4h ago -> allow (covers the
#     run-ci-then-commit-then-push flow)
#   - marker missing or stale                          -> block
#
# Bypass after investigating: prefix the push command with SKIP_CI_GATE=1.
#
# Register in ~/.claude/settings.json under hooks.PreToolUse (matcher "Bash"):
#   { "type": "command", "command": "<path-to>/git-push-gate.sh" }

set -u

MAX_ANCESTOR_AGE=14400  # seconds a pre-commit run stays valid (4h)

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Only act on git push invocations (plain, rtk-proxied, or git -C <path>).
printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])(rtk[[:space:]]+(proxy[[:space:]]+)?)?git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push' || exit 0

# Explicit bypass (use only after investigating a WARN/stale marker).
printf '%s' "$CMD" | grep -q 'SKIP_CI_GATE=1' && exit 0

# Repo dir: honor `git -C <path>`, else the session cwd.
DIR=$(printf '%s' "$CMD" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
[ -z "$DIR" ] && DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$DIR" ] && DIR="."
GIT=$(command -v git) || exit 0
"$GIT" -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

TOP=$("$GIT" -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
GITDIR=$("$GIT" -C "$DIR" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
MARKER="$GITDIR/local-ci-status"

# --- does this repo have executable check configs local-ci would run? -----
has_ci_configs() {
  local f
  for f in phpunit.xml phpunit.xml.dist phpstan.neon phpstan.neon.dist \
           phpcs.xml phpcs.xml.dist .phpcs.xml .phpcs.xml.dist \
           pyproject.toml pytest.ini tox.ini; do
    [ -f "$TOP/$f" ] && return 0
  done
  if [ -f "$TOP/package.json" ] && command -v node >/dev/null 2>&1; then
    node -e '
      const s = (require(process.argv[1] + "/package.json").scripts || {});
      const real = (s.lint || s.build || (s.test && !/no test specified/.test(s.test)));
      process.exit(real ? 0 : 1);
    ' "$TOP" 2>/dev/null && return 0
  fi
  return 1
}

block() { # message lines on stderr, exit 2
  {
    echo "BLOCKED: git push gated on local-ci. $1"
    echo "Run /local-ci and get a green SUMMARY, then push."
    echo "If investigated and genuinely benign, re-run prefixed with SKIP_CI_GATE=1."
  } >&2
  exit 2
}

if [ ! -f "$MARKER" ]; then
  has_ci_configs || exit 0
  block "No local-ci run recorded for this repo (marker missing)."
fi

SHA=$(sed -nE 's/.*sha=([^ ]+).*/\1/p' "$MARKER" | head -1)
RESULT=$(sed -nE 's/.*result=([^ ]+).*/\1/p' "$MARKER" | head -1)
TS=$(sed -nE 's/.*ts=([0-9]+).*/\1/p' "$MARKER" | head -1)
HEAD_SHA=$("$GIT" -C "$DIR" rev-parse HEAD 2>/dev/null || echo unknown)

case "$RESULT" in
  NONE) exit 0 ;;
  FAIL) block "Last local-ci run FAILED (at ${SHA:0:8})." ;;
  WARN) block "Last local-ci run has WARNs (at ${SHA:0:8}); WARN is not a green gate." ;;
  PASS) ;;
  *)    block "Unreadable marker ($MARKER)." ;;
esac

# PASS: fresh enough?
[ "$SHA" = "$HEAD_SHA" ] && exit 0
if "$GIT" -C "$DIR" merge-base --is-ancestor "$SHA" "$HEAD_SHA" 2>/dev/null; then
  NOW=$(date +%s)
  AGE=$(( NOW - ${TS:-0} ))
  [ "$AGE" -le "$MAX_ANCESTOR_AGE" ] && exit 0
  block "local-ci PASS is stale (ran $((AGE / 60)) min ago at ancestor ${SHA:0:8})."
fi
block "local-ci PASS was for ${SHA:0:8}, which is not an ancestor of HEAD."
