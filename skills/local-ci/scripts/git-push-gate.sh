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
# directory for everything after it, matching real shell semantics.
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
PUSH_DIRS=$(CLAUDE_HOOK_CMD="$CMD" python3 - <<'PYEOF'
import os, re, shlex, sys

cmd = os.environ.get("CLAUDE_HOOK_CMD", "")
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

def resolve_cd(base, arg):
    # ~ and $VAR expansion (shlex does neither); relative args compose onto
    # the current tracked dir, matching real `cd` behavior; an absolute arg
    # resets it outright.
    if arg.startswith("~"):
        arg = os.path.expanduser(arg)
    arg = os.path.expandvars(arg)
    if arg.startswith("/") or base is None:
        return arg
    return base.rstrip("/") + "/" + arg

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

    # A token made entirely of shell punctuation may bundle a `(`/`)` with
    # an adjacent separator (shlex emits ");" as one token for
    # `... ); git push`, not two). Scan its characters for subshell
    # boundaries: `(` saves the current tracked dir, `)` restores it - a
    # `cd` inside `( ... )` never affects the outer shell's directory.
    if tk and not (tk[0].isalnum() or tk[0] in "_./~$-"):
        for ch in tk:
            if ch == "(":
                cd_stack.append(last_cd_dir)
            elif ch == ")" and cd_stack:
                last_cd_dir = cd_stack.pop()
        i += 1
        continue

    if tk == "cd":
        # Track `cd <dir>` as a statement, so a later bare `git push` (no
        # -C) resolves against it instead of the tool call's original cwd.
        j = i + 1
        arg = None
        if j < n and toks[j] != "-" and (toks[j][0].isalnum() or toks[j][0] in "_./~$"):
            arg = toks[j]
            j += 1
        elif j < n and toks[j] == "-":
            j += 1  # `cd -`: swaps to $OLDPWD, not statically known - see below
        # A `cd <dir> || <fallback>` only takes effect if the cd FAILS,
        # which we can't know statically - too risky to trust either way.
        followed_by_or = j < n and toks[j] == "||"
        if arg is not None and not followed_by_or:
            last_cd_dir = resolve_cd(last_cd_dir, arg)
        else:
            # `cd -`, a bare `cd` (goes to $HOME), or a conditional `cd ... ||`:
            # can't resolve the resulting directory with confidence. Fall back
            # to "untracked" (gates the tool call's own .cwd) rather than
            # risk trusting a stale or wrong one.
            last_cd_dir = None
        i = j
        continue

    if toks[i] == "rtk":
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
        tk = toks[i]
        if tk == "-C" and i + 1 < n:
            cdir = toks[i + 1]; i += 2
        elif tk.startswith("-C") and len(tk) > 2:
            cdir = tk[2:]; i += 1
        elif tk == "-c" and i + 1 < n:
            i += 2
        elif tk.startswith("-c") and len(tk) > 2:
            i += 1
        elif tk.startswith("--"):
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
