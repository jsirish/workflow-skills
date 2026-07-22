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
# explicit `-C <relative>`/`--work-tree <relative>` on the git invocation
# itself also composes onto a preceding `cd`, and chained `-C` flags on the
# same invocation compose onto each other in order (`git -C a -C b` ->
# cwd/a/b), matching how git itself resolves them - not just the tool
# call's original cwd. `--work-tree` is treated the same as `-C` (both
# repoint git's working directory); other long options that take a
# separate value token (`--git-dir`, `--namespace`, `--super-prefix`,
# `--config-env`, `--exec-path`) are recognised and their value skipped
# so they don't desync the flag scan, but they don't affect the resolved
# directory. `cd`/`git`/`rtk` are matched wherever the token appears (not
# restricted to command position), so a wrapper before the real command
# (`time git push`, `env FOO=bar git push`, a newline- or `;`-separated
# `git push` with no `&&`/`||` before it) is still recognised - the
# accepted cost is a bare `cd`/`git` appearing as a plain argument to an
# unrelated command (e.g. `echo cd bar`) being misread as a real
# statement, a rare edge case. `~` and `$VAR` in a `cd` or `-C`/
# `--work-tree` argument are expanded before resolution. Every resolved
# `cd` target is checked against the real filesystem before being trusted,
# EXCEPT when a `mkdir`, `git clone`, or `git worktree add` appeared
# earlier in the same compound command - that not-yet-existing directory
# is then trusted, since it will exist by the time the `cd` actually runs
# (`mkdir foo && cd foo && git push`). Whenever a `cd`'s effect still
# can't be confidently resolved - an unresolved `$VAR`, a typo, an empty
# argument, `cd -`, a bare `cd`, a conditional `cd ... ||`, or "cd"
# matched as a plain argument with nothing directory-shaped following it -
# tracking is left untouched rather than reset: a previously-tracked,
# recently relevant directory is a safer fallback than discarding it for
# the tool call's unrelated raw cwd.
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

# Long git options that take their value as a SEPARATE following token and
# don't affect the resolved directory (unlike -C/--work-tree below) - just
# consumed so the flag-scan loop doesn't mistake the value for a subcommand.
GIT_LONG_OPTS_WITH_VALUE = {"--git-dir", "--namespace", "--super-prefix", "--config-env", "--exec-path"}

def is_word_char(ch):
    return ch.isalnum() or ch in "_./~$"

def compose(base, val):
    # Compose a (possibly relative) directory value onto the currently
    # tracked dir, the same way a real shell resolves any relative path
    # against whatever the cwd actually is at that point - used for both
    # `cd <relative>` and an explicit `git -C <relative>`/`--work-tree
    # <relative>` that follows one. ~ and $VAR expansion (shlex does
    # neither) applies here so it's shared by every caller, not just cd.
    if val.startswith("~"):
        val = os.path.expanduser(val)
    val = os.path.expandvars(val)
    if val.startswith("/"):
        return os.path.normpath(val)
    b = base if base is not None else cwd
    result = (b.rstrip("/") + "/" + val) if b not in ("", ".") else val
    return os.path.normpath(result)

def resolve_cd(base, arg, trust_missing=False):
    candidate = compose(base, arg)
    # Reality check: an unresolved $VAR (left as a literal "$VAR" segment),
    # a typo, or a cd that would actually fail at runtime all converge on
    # "this path doesn't verifiably exist right now". A real failed `cd`
    # leaves the shell's directory unchanged, so on failure keep whatever
    # was already tracked (the sentinel below) rather than either trusting
    # the bad value or discarding a previously-good one. Exception: a
    # `mkdir`/`git clone`/`git worktree add` seen earlier in this same
    # compound command (trust_missing) means the dir plausibly doesn't
    # exist YET but will by the time this cd actually runs.
    if not os.path.isdir(candidate) and not trust_missing:
        return "UNCHANGED"
    return candidate

out = []
i, n = 0, len(toks)
last_cd_dir = None  # most recent `cd <dir>` statement seen so far, left to right
cd_stack = []  # last_cd_dir snapshots, pushed/popped across ( ... ) boundaries
saw_creator = False  # mkdir / git clone / git worktree add seen earlier
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

    if tk == "mkdir":
        saw_creator = True
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
        resolvable = True  # False for cases with no directory to even attempt
        if j < n and toks[j] == "--":
            j += 1
            if j < n:
                arg = toks[j]; j += 1  # may be "" - resolve_cd's isdir check is the arbiter
            else:
                resolvable = False
        elif j < n and toks[j] == "-":
            j += 1
            resolvable = False  # `cd -`: swaps to $OLDPWD, not statically known
        elif j < n and toks[j] and not toks[j].startswith("-"):
            arg = toks[j]  # may be "" - resolve_cd's isdir check is the arbiter
            j += 1
        else:
            resolvable = False  # bare `cd`, or a false match with no valid arg following
        # A `cd <dir> || <fallback>` only takes effect if the cd FAILS,
        # which we can't know statically - too risky to trust either way.
        followed_by_or = j < n and toks[j] == "||"
        if resolvable and arg is not None and not followed_by_or:
            resolved = resolve_cd(last_cd_dir, arg, trust_missing=saw_creator)
            if resolved != "UNCHANGED":
                last_cd_dir = resolved
        # In every other case (`cd -`, a bare `cd`, a conditional `cd ...
        # ||`, an empty/failed cd, or "cd" matched as a plain argument to
        # some other command with nothing directory-shaped following it,
        # e.g. `git commit -m cd`) last_cd_dir is deliberately left
        # UNTOUCHED rather than reset - a previously-tracked, recently
        # relevant directory is a safer fallback than discarding it for
        # the tool call's unrelated raw cwd.
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
    cdir = last_cd_dir  # None means "untracked"; resolved to "." only at output time
    while i < n:
        tk2 = toks[i]
        if not tk2:
            i += 1
            continue
        if tk2 == "-C" and i + 1 < n:
            # Composes onto the RUNNING cdir (this invocation's own prior
            # -C, if any), not always onto last_cd_dir - git itself chains
            # successive -C flags relative to each other, so
            # `git -C a -C b` resolves to <cwd>/a/b, not <cwd>/b.
            cdir = compose(cdir, toks[i + 1]); i += 2
        elif tk2.startswith("-C") and len(tk2) > 2:
            cdir = compose(cdir, tk2[2:]); i += 1
        elif tk2 == "--work-tree" and i + 1 < n:
            # --work-tree is semantically equivalent to -C for our purposes
            # (it repoints git at a different working directory).
            cdir = compose(cdir, toks[i + 1]); i += 2
        elif tk2.startswith("--work-tree="):
            cdir = compose(cdir, tk2[len("--work-tree="):]); i += 1
        elif tk2 in GIT_LONG_OPTS_WITH_VALUE and i + 1 < n:
            i += 2  # consume value; doesn't affect the resolved dir
        elif any(tk2.startswith(o + "=") for o in GIT_LONG_OPTS_WITH_VALUE):
            i += 1
        elif tk2 == "-c" and i + 1 < n:
            i += 2
        elif tk2.startswith("-c") and len(tk2) > 2:
            i += 1
        elif tk2.startswith("--"):
            i += 1
        else:
            break
    if i < n and toks[i] == "push":
        out.append("BYPASS" if bypass else (cdir if cdir is not None else "."))
        i += 1
    elif i < n and toks[i] == "clone":
        saw_creator = True
        i += 1
    elif i < n and toks[i] == "worktree" and i + 1 < n and toks[i + 1] == "add":
        saw_creator = True
        i += 2
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
