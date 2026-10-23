#!/usr/bin/env bash
#
# Tests for skills/local-ci/scripts/local-ci-post.sh (--post).
# Uses a fake gh (LOCAL_CI_GH) that logs its calls; no network.
# Plain bash, no test framework dependency - mirrors the other tests/*.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POST="$REPO_ROOT/skills/local-ci/scripts/local-ci-post.sh"
[ -f "$POST" ] || { echo "FAIL: cannot find $POST" >&2; exit 1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake gh: logs argv; `pr list` answers 7; `api .../comments` answers $FAKE_COMMENT_ID (may be empty).
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  "pr list") echo 7 ;;
  "api --paginate") echo "${FAKE_COMMENT_ID:-}" ;;
esac
exit 0
EOF
chmod +x "$TMP/gh"
export LOCAL_CI_GH="$TMP/gh" FAKE_GH_LOG="$TMP/gh.log"

# Repo with a remote that has the branch pushed.
git init -q --bare "$TMP/remote.git"
git init -q "$TMP/work"
cd "$TMP/work" || exit 1
git config user.email t@example.com; git config user.name t
git checkout -q -b feat
echo a > a; git add a; git commit -q -m one
git remote add origin "git@github.com:acme/widgets.git"
git remote set-url --push origin "$TMP/remote.git"
git push -q origin feat 2>/dev/null
# The slug comes from the fetch URL; `branch -r` needs a tracking ref.
git update-ref refs/remotes/origin/feat HEAD
GD="$(git rev-parse --absolute-git-dir)"
SHA="$(git rev-parse HEAD)"

write_marker() { # sha result
  printf 'sha=%s result=%s ts=1\n' "$1" "$2" > "$GD/local-ci-status"
  printf 'PASS  phpunit\nWARN  phpstan\nWARN  phpcs\nFAIL  x\n' > "$GD/local-ci-summary"
}
reset() { : > "$FAKE_GH_LOG"; }

# 1. WARN -> success with counts, status + new comment.
reset; write_marker "$SHA" WARN; unset FAKE_COMMENT_ID
bash "$POST" "$TMP/work" >/dev/null 2>&1
grep -q 'statuses/'"$SHA" "$FAKE_GH_LOG" && grep -q 'state=success' "$FAKE_GH_LOG" \
  && grep -q 'description=WARN: PASS 1 / WARN 2 / FAIL 1' "$FAKE_GH_LOG" \
  && pass "WARN posts success with counts" || fail "WARN status: $(cat "$FAKE_GH_LOG")"
grep -q -- '-X POST repos/acme/widgets/issues/7/comments' "$FAKE_GH_LOG" \
  && pass "no existing comment -> POST" || fail "expected comment POST"

# 2. Existing comment -> PATCH, not a second POST.
reset; export FAKE_COMMENT_ID=999
bash "$POST" "$TMP/work" >/dev/null 2>&1
grep -q -- '-X PATCH repos/acme/widgets/issues/comments/999' "$FAKE_GH_LOG" \
  && ! grep -q -- '-X POST repos/acme/widgets/issues/7/comments' "$FAKE_GH_LOG" \
  && pass "existing comment is edited, not duplicated" || fail "expected PATCH only: $(cat "$FAKE_GH_LOG")"
unset FAKE_COMMENT_ID

# 3. --strict turns WARN into failure.
reset
bash "$POST" --strict "$TMP/work" >/dev/null 2>&1
grep -q 'state=failure' "$FAKE_GH_LOG" && pass "--strict: WARN -> failure" || fail "--strict state"

# 4. FAIL -> failure; PASS -> success.
reset; write_marker "$SHA" FAIL; bash "$POST" "$TMP/work" >/dev/null 2>&1
grep -q 'state=failure' "$FAKE_GH_LOG" && pass "FAIL -> failure" || fail "FAIL state"
reset; write_marker "$SHA" PASS; bash "$POST" "$TMP/work" >/dev/null 2>&1
grep -q 'state=success' "$FAKE_GH_LOG" && pass "PASS -> success" || fail "PASS state"

# 5. Stale marker posts nothing.
reset; write_marker "0000000000000000000000000000000000000000" PASS
bash "$POST" "$TMP/work" >/dev/null 2>&1
[ ! -s "$FAKE_GH_LOG" ] && pass "stale marker posts nothing" || fail "stale marker posted"

# 6. NONE posts nothing.
reset; write_marker "$SHA" NONE; bash "$POST" "$TMP/work" >/dev/null 2>&1
[ ! -s "$FAKE_GH_LOG" ] && pass "NONE posts nothing" || fail "NONE posted"

# 7. Unpushed HEAD posts nothing.
echo b > b; git add b; git commit -q -m two
SHA2="$(git rev-parse HEAD)"
reset; write_marker "$SHA2" PASS; bash "$POST" "$TMP/work" >/dev/null 2>&1
[ ! -s "$FAKE_GH_LOG" ] && pass "unpushed HEAD posts nothing" || fail "unpushed HEAD posted"

# 8. --quiet is silent when there is nothing to post.
OUT="$(bash "$POST" --quiet "$TMP/work" 2>&1)"
[ -z "$OUT" ] && pass "--quiet silent on skip" || fail "--quiet printed: $OUT"

# 9. Always exits 0, even when gh fails.
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
write_marker "$SHA" PASS
bash "$POST" "$TMP/work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "gh failure does not fail the caller" || fail "exit $rc"

[ "$FAILURES" -eq 0 ] || { echo "$FAILURES failure(s)" >&2; exit 1; }
echo "all passed"
