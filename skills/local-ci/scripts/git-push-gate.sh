#!/bin/bash
# PreToolUse(Bash) hook for Claude Code: gate `git push` on a fresh, non-failing
# local-ci run.
#
# Contract: local-ci.sh writes <git-dir>/local-ci-status as
#   sha=<HEAD-at-run> result=<PASS|FAIL|WARN|NONE> ts=<epoch>
#
# Gate rules (applied per push invocation in the command):
#   - marker missing (no local-ci run recorded)        -> allow (fail-open;
#     don't trap a push behind a CI run that was never kicked off)
#   - result=NONE (local-ci found nothing to run)     -> allow
#   - result=WARN                                     -> allow (WARN is not a
#     green gate for "done", but it no longer blocks the push itself;
#     investigate before declaring done)
#   - result=FAIL                                     -> block
#   - result=PASS at HEAD                             -> allow
#   - result=PASS at an ancestor of HEAD, run < 4h ago -> allow (covers the
#     run-ci-then-commit-then-push flow)
#   - PASS stale or not an ancestor of HEAD             -> block
#
# Command parsing uses a shell tokenizer (python3 shlex), not a regex, so
# quoted `-C` paths, paths with spaces, per-invocation `-C`/`-c` options,
# compound commands with several pushes, and string literals that merely
# mention "git push" are all handled correctly. A preceding `cd <dir> &&`
# (or `cd <dir>;`) is also tracked and used as the base directory for a
# later bare `git push` (no explicit `-C`) - each `cd` updates the effective
# directory for everything after it, matching real shell semantics; an
# explicit `-C <relative>` on the git invocation itself also composes onto
# a preceding `cd`, not just the tool call's original cwd. `cd`/`git`/`rtk`
# are matched wherever the token appears (not restricted to command
# position), so a wrapper before the real command (`time git push`,
# `env FOO=bar git push`, a newline- or `;`-separated `git push` with no
# `&&`/`||` before it) is still recognised - the accepted cost is a bare
# `cd`/`git` appearing as a plain argument to an unrelated command (e.g.
# `echo cd bar`) being misread as a real statement, a rare edge case.
# Every resolved `cd` target is checked against the real filesystem before
# being trusted: an unresolved `$VAR`, a typo, or a `cd` that would
# actually fail at runtime all fail this check - a real failed `cd` leaves
# the shell's directory unchanged, so tracking keeps whatever directory was
# already known rather than discarding it or trusting the bad value.
#
# Fail-open by design (documented, keep the list short): jq or python3
# missing, or the command contains no real git push invocation.
#
# Bypass after investigating: prefix the push command with SKIP_CI_GATE=1
# (recognised as an env assignment before the git invocation).
#
# Register in ~/.claude/settings.json under hooks.PreToolUse (matcher "Bash"):
#   { "type": "command", "command": "<path-to>/git-push-gate.sh" }

set -u

MAX_ANCESTOR_AGE=14400  # seconds a pre-commit run stays valid (4h)

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0       # fail-open by design
command -v python3 >/dev/null 2>&1 || exit 0  # fail-open by design
GIT=$(command -v git) || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$CMD" ] && exit 0
# Cheap pre-filter before spawning python.
printf '%s' "$CMD" | grep -q 'push' || exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="."

# Emit one line per real `git ... push` invocation: "BYPASS" when the
# invocation carries SKIP_CI_GATE=1, else that invocation's -C dir ("." if none).
PUSH_DIRS=$(CLAUDE_HOOK_CMD="$CMD" CLAUDE_HOOK_CWD="$CWD" python3 - <<'PYEOF'
import os, re, shlex, sys

cmd = os.environ.get("CLAUDE_HOOK_CMD", "")
cwd = os.environ.get("CLAUDE_HOOK_CWD", ".")
try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    toks = list(lex)
except ValueError:
    # Unparseable (unbalanced quotes, heredocs). Gate the cwd only when a
    # push invocation is plausibly present in command position.
    if re.search(r'(^|[\s;|&])(rtk\s+(proxy\s+)?)?git\s+(-[cC]\s*\S+\s+)*push(\s|$)', cmd):
        print(".")
    sys.exit(0)

ENV_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')

def is_word_char(ch):
    return ch.isalnum() or ch in "_./~$"

def compose(base, val):
    # Compose a (possibly relative) directory value onto the currently
    # tracked dir, the same way a real shell resolves any relative path
    # against whatever the cwd actually is at that point - used for both
    # `cd <relative>` and an explicit `git -C <relative>` that follows one.
    if val.startswith("/"):
        return os.path.normpath(val)
    b = base if base is not None else cwd
    result = (b.rstrip("/") + "/" + val) if b not in ("", ".") else val
    return os.path.normpath(result)

def resolve_cd(base, arg):
    # ~ and $VAR expansion (shlex does neither).
    if arg.startswith("~"):
        arg = os.path.expanduser(arg)
    arg = os.path.expandvars(arg)
    candidate = compose(base, arg)
    # Reality check: an unresolved $VAR (left as a literal "$VAR" segment),
    # a typo, or a cd that would actually fail at runtime all converge on
    # "this path doesn't verifiably exist right now". A real failed `cd`
    # leaves the shell's directory unchanged, so on failure keep whatever
    # was already tracked (the sentinel below) rather than either trusting
    # the bad value or discarding a previously-good one.
    if not os.path.isdir(candidate):
        return "UNCHANGED"
    return candidate

out = []
i, n = 0, len(toks)
last_cd_dir = None  # most recent `cd <dir>` statement seen so far, left to right
cd_stack = []  # last_cd_dir snapshots, pushed/popped across ( ... ) boundaries
while i < n:
    bypass = False
    while i < n and ENV_RE.match(toks[i]):
        if toks[i] == "SKIP_CI_GATE=1":
            bypass = True
        i += 1
    if i >= n:
        break
    start = i
    tk = toks[i]
    if not tk:  # empty token (e.g. `cd ""` quotes an empty string)
        i += 1
        continue

    # A token made entirely of shell punctuation may bundle a `(`/`)` with
    # an adjacent separator (shlex emits ");" as one token for
    # `... ); git push`, not two). Scan its characters for subshell
    # boundaries: `(` saves the current tracked dir, `)` restores it - a
    # `cd` inside `( ... )` never affects the outer shell's directory.
    if not is_word_char(tk[0]):
        for ch in tk:
            if ch == "(":
                cd_stack.append(last_cd_dir)
            elif ch == ")" and cd_stack:
                last_cd_dir = cd_stack.pop()
        i += 1
        continue

    # "cd"/"git"/"rtk" are matched as token VALUES wherever they appear,
    # not restricted to genuine command position - a wrapper word before
    # the real command (`time git push`, `env FOO=bar git push`, a
    # newline-separated `git status` then `git push` with no operator
    # between them) is common and must still be recognised. The narrow
    # cost is a `cd`/`git`/`push` appearing as a bare, unquoted argument to
    # an unrelated command (e.g. `echo cd bar`) being misread as a real
    # statement - accepted as a rare, low-impact edge case; the tool is
    # documented as a workflow guard, not a security boundary.
    if tk == "cd":
        j = i + 1
        # Skip recognized flags before the directory argument: -L/-P
        # (POSIX logical-vs-physical) and -e/-@ (macOS). An unrecognized
        # flag can't be confidently treated as a directory argument either.
        while j < n and toks[j] in ("-L", "-P", "-e", "-@"):
            j += 1
        arg = None
        if j < n and toks[j] == "--":
            j += 1
            if j < n and toks[j]:
                arg = toks[j]; j += 1
        elif j < n and toks[j] == "-":
            j += 1  # `cd -`: swaps to $OLDPWD, not statically known
        elif j < n and toks[j] and toks[j][0] != "-" and is_word_char(toks[j][0]):
            arg = toks[j]
            j += 1
        # A `cd <dir> || <fallback>` only takes effect if the cd FAILS,
        # which we can't know statically - too risky to trust either way.
        followed_by_or = j < n and toks[j] == "||"
        if arg is not None and not followed_by_or:
            resolved = resolve_cd(last_cd_dir, arg)
            if resolved != "UNCHANGED":
                last_cd_dir = resolved
            # else: a real failed `cd` leaves the directory as it was -
            # last_cd_dir is intentionally left untouched, not reset.
        else:
            # `cd -`, a bare `cd` (goes to $HOME), or a conditional
            # `cd ... ||`: can't resolve the resulting directory with
            # confidence. Fall back to "untracked" (gates the tool call's
            # own .cwd) rather than risk trusting a stale or wrong one.
            last_cd_dir = None
        i = j
        continue

    if tk == "rtk":
        i += 1
        if i < n and toks[i] == "proxy":
            i += 1
        if i >= n or toks[i] != "git":
            i = start + 1
            continue
    if toks[i] != "git":
        i = start + 1
        continue
    i += 1  # past "git"
    cdir = last_cd_dir if last_cd_dir is not None else "."
    while i < n:
        tk2 = toks[i]
        if not tk2:
            i += 1
            continue
        if tk2 == "-C" and i + 1 < n:
            cdir = compose(last_cd_dir, toks[i + 1]); i += 2
        elif tk2.startswith("-C") and len(tk2) > 2:
            cdir = compose(last_cd_dir, tk2[2:]); i += 1
        elif tk2 == "-c" and i + 1 < n:
            i += 2
        elif tk2.startswith("-c") and len(tk2) > 2:
            i += 1
        elif tk2.startswith("--"):
            i += 1
        else:
            break
    if i < n and toks[i] == "push":
        out.append("BYPASS" if bypass else cdir)
        i += 1
print("\n".join(out))
PYEOF
)
[ -z "$PUSH_DIRS" ] && exit 0

block() { # message; prints guidance and exits 2
  {
    echo "BLOCKED: git push gated on local-ci. $1"
    echo "Run /local-ci and get a green SUMMARY, then push."
    echo "If investigated and genuinely benign, re-run prefixed with SKIP_CI_GATE=1."
  } >&2
  exit 2
}

gate_dir() { # dir (resolved)
  local dir="$1"
  "$GIT" -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local gitdir marker
  gitdir=$("$GIT" -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  marker="$gitdir/local-ci-status"

  if [ ! -f "$marker" ]; then
    return 0  # fail-open: no local-ci run recorded, don't block on that alone
  fi

  local sha result ts head_sha
  sha=$(sed -nE 's/.*sha=([^ ]+).*/\1/p' "$marker" | head -1)
  result=$(sed -nE 's/.*result=([^ ]+).*/\1/p' "$marker" | head -1)
  ts=$(sed -nE 's/.*ts=([0-9]+).*/\1/p' "$marker" | head -1)
  head_sha=$("$GIT" -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)

  case "$result" in
    NONE) return 0 ;;
    WARN) return 0 ;;  # not a green gate for "done", but no longer blocks the push
    FAIL) block "Last local-ci run FAILED (at ${sha:0:8})." ;;
    PASS) ;;
    *)    block "Unreadable marker ($marker)." ;;
  esac

  [ "$sha" = "$head_sha" ] && return 0
  if "$GIT" -C "$dir" merge-base --is-ancestor "$sha" "$head_sha" 2>/dev/null; then
    local now age
    now=$(date +%s)
    age=$(( now - ${ts:-0} ))
    [ "$age" -le "$MAX_ANCESTOR_AGE" ] && return 0
    block "local-ci PASS is stale (ran $((age / 60)) min ago at ancestor ${sha:0:8})."
  fi
  block "local-ci PASS was for ${sha:0:8}, which is not an ancestor of HEAD."
}

while IFS= read -r d; do
  [ -z "$d" ] && continue
  [ "$d" = "BYPASS" ] && continue
  case "$d" in
    /*) rdir="$d" ;;
    *)  rdir="$CWD/$d" ;;
  esac
  gate_dir "$rdir"   # blocks (exit 2) on failure
done <<EOF
$PUSH_DIRS
EOF

exit 0
