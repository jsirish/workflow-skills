#!/usr/bin/env bash
#
# local-ci-post.sh — publish the last local-ci run to GitHub.
#
# Reads the marker (<git-dir>/local-ci-status) and summary
# (<git-dir>/local-ci-summary) that local-ci.sh wrote, then:
#   1. POSTs a commit status, context "local-ci", on the pushed HEAD sha.
#   2. Upserts one PR comment (hidden marker <!-- local-ci -->) with the SUMMARY.
#
# Usage:
#   local-ci-post.sh [--strict] [--quiet] [DIR]
#
#   --strict   WARN posts state=failure (default: success, "WARN" in the description).
#   --quiet    Print nothing when there is nothing to post (hook use).
#   DIR        Repo to post for (default: current dir).
#
# Mapping: PASS -> success, FAIL -> failure, WARN -> success (failure under
# --strict), NONE -> not posted.
#
# Posts only when the marker sha equals HEAD and HEAD exists on a remote branch.
# A stale marker, an unpushed HEAD or a missing `gh` login is reported and
# skipped; this script never fails the caller (always exits 0).
#
# These statuses come from the developer's machine, not an independent runner.
# Do not make "local-ci" a required check on public repos.
#
# Test seam: LOCAL_CI_GH overrides the gh binary.

set -uo pipefail

STRICT=0
QUIET=0
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --quiet)  QUIET=1 ;;
    -h|--help) awk 'NR==1{next} /^#/{print; next} /^$/{next} {exit}' "$0"; exit 0 ;;
    --*)      echo "local-ci-post: unknown option $1" >&2; exit 0 ;;
    *)        DIR="$1" ;;
  esac
  shift
done
[ -n "$DIR" ] || DIR="$(pwd)"

GH="${LOCAL_CI_GH:-gh}"
MARKER_TAG='<!-- local-ci -->'

say()  { [ "$QUIET" -eq 1 ] || echo "local-ci-post: $*" >&2; }
warn() { echo "local-ci-post: $*" >&2; }

command -v "$GH" >/dev/null 2>&1 || { warn "gh not found; nothing posted."; exit 0; }
GITDIR="$(git -C "$DIR" rev-parse --absolute-git-dir 2>/dev/null)" || { say "not a git repo; nothing posted."; exit 0; }
MARKER="$GITDIR/local-ci-status"
SUMMARY="$GITDIR/local-ci-summary"
[ -f "$MARKER" ] || { say "no local-ci run recorded; nothing posted."; exit 0; }

M_SHA="" M_RESULT=""
for kv in $(cat "$MARKER"); do
  case "$kv" in
    sha=*)    M_SHA="${kv#sha=}" ;;
    result=*) M_RESULT="${kv#result=}" ;;
  esac
done

HEAD_SHA="$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" || { say "cannot resolve HEAD; nothing posted."; exit 0; }
if [ "$M_SHA" != "$HEAD_SHA" ]; then
  say "last local-ci run was for ${M_SHA:0:7}, HEAD is ${HEAD_SHA:0:7}; re-run local-ci first. Nothing posted."
  exit 0
fi
if [ "$M_RESULT" = "NONE" ] || [ -z "$M_RESULT" ]; then
  say "last run executed no checks; nothing posted."
  exit 0
fi
if [ -z "$(git -C "$DIR" branch -r --contains "$HEAD_SHA" 2>/dev/null)" ]; then
  say "HEAD ${HEAD_SHA:0:7} is not on any remote branch; push first. Nothing posted."
  exit 0
fi

# owner/repo from the remote that carries HEAD (origin first).
REMOTE_URL="$(git -C "$DIR" remote get-url origin 2>/dev/null)" || { warn "no 'origin' remote; nothing posted."; exit 0; }
SLUG="$(printf '%s' "$REMOTE_URL" | sed -E 's#^[a-z+]+://([^/@]*@)?[^/:]*(:[0-9]+)?/##; s#^[^/@]*@[^/:]*:##; s#\.git$##; s#/$##')"
if ! printf '%s' "$SLUG" | /usr/bin/grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  warn "cannot derive owner/repo from the origin URL; nothing posted."
  exit 0
fi

N_PASS=0 N_WARN=0 N_FAIL=0
if [ -f "$SUMMARY" ]; then
  N_PASS=$(/usr/bin/grep -c '^PASS' "$SUMMARY" 2>/dev/null); N_PASS=${N_PASS:-0}
  N_WARN=$(/usr/bin/grep -c '^WARN' "$SUMMARY" 2>/dev/null); N_WARN=${N_WARN:-0}
  N_FAIL=$(/usr/bin/grep -c '^FAIL' "$SUMMARY" 2>/dev/null); N_FAIL=${N_FAIL:-0}
fi

case "$M_RESULT" in
  PASS) STATE=success ;;
  FAIL) STATE=failure ;;
  WARN) if [ "$STRICT" -eq 1 ]; then STATE=failure; else STATE=success; fi ;;
  *)    say "unknown result '$M_RESULT'; nothing posted."; exit 0 ;;
esac
DESC="$M_RESULT: PASS $N_PASS / WARN $N_WARN / FAIL $N_FAIL"

if ! ERR="$("$GH" api -X POST "repos/$SLUG/statuses/$HEAD_SHA" \
     -f context=local-ci -f state="$STATE" -f description="$DESC" 2>&1 >/dev/null)"; then
  warn "status POST to $SLUG@${HEAD_SHA:0:7} failed: $(printf '%s' "$ERR" | head -1)"
  exit 0
fi
say "status local-ci=$STATE ($DESC) on $SLUG@${HEAD_SHA:0:7}"

# PR comment: only when this branch has an open PR.
BRANCH="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then say "detached HEAD; status only, no PR comment."; exit 0; fi
if ! PR="$("$GH" pr list -R "$SLUG" --head "$BRANCH" --state open --json number -q '.[0].number' 2>/dev/null)"; then
  warn "could not look up the PR for $BRANCH; status only."; exit 0
fi
[ -n "$PR" ] || { say "no open PR for $BRANCH; status only."; exit 0; }

BODY_FILE="$(mktemp -t local-ci-post.XXXXXX)"
trap 'rm -f "$BODY_FILE"' EXIT
{
  echo "$MARKER_TAG"
  echo "### local-ci: $M_RESULT"
  echo
  echo "Commit \`${HEAD_SHA:0:7}\` · $DESC · run on the author's machine, not an independent runner."
  if [ -f "$SUMMARY" ]; then
    echo
    echo '```'
    cat "$SUMMARY"
    echo '```'
  fi
} > "$BODY_FILE"

# Capture first, then pick the id: a failed lookup must not fall through to a duplicate POST.
if ! IDS="$("$GH" api --paginate "repos/$SLUG/issues/$PR/comments" \
        -q ".[] | select(.body | startswith(\"$MARKER_TAG\")) | .id" 2>/dev/null)"; then
  warn "could not list comments on PR #$PR; comment skipped."; exit 0
fi
CID="$(printf '%s\n' "$IDS" | head -1)"
if [ -n "$CID" ]; then
  "$GH" api -X PATCH "repos/$SLUG/issues/comments/$CID" -F body=@"$BODY_FILE" >/dev/null 2>&1 \
    && say "updated PR #$PR comment" || warn "failed to update PR #$PR comment"
else
  "$GH" api -X POST "repos/$SLUG/issues/$PR/comments" -F body=@"$BODY_FILE" >/dev/null 2>&1 \
    && say "commented on PR #$PR" || warn "failed to comment on PR #$PR"
fi
exit 0
