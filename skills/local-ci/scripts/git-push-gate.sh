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
# directory (a contrived case - a value-taking long option with its value
# OMITTED, immediately followed by a literal "push" token - lets that
# option's scan consume "push" as its own value and skip gating; this
# mirrors how git itself would consume that same token, so a command
# shaped that way isn't a real push to begin with). `git clone`/`git
# worktree add` options that take a value (`--branch`/`-b`, `--depth`,
# `--origin`/`-o`; `-b`/`-B`/`--orphan`) are recognised the same way so
# their value token isn't mistaken for the destination/path argument.
# `cd`/`git`/`rtk` are matched wherever the token appears (not
# restricted to command position), so a wrapper before the real command
# (`time git push`, `env FOO=bar git push`, a newline- or `;`-separated
# `git push` with no `&&`/`||` before it) is still recognised - the
# accepted cost is a bare `cd`/`git` appearing as a plain argument to an
# unrelated command (e.g. `echo cd bar`) being misread as a real
# statement, a rare edge case. `~` and `$VAR` in a `cd` or `-C`/
# `--work-tree` argument are expanded before resolution. Every resolved
# `cd` target is checked against the real filesystem before being trusted,
# EXCEPT when its exact target (or a path under it) was the destination of
# a `mkdir`, `git clone`, or `git worktree add` seen earlier in the same
# compound command - that specific not-yet-existing directory is then
# trusted, since it will exist by the time the `cd` actually runs
# (`mkdir foo && cd foo && git push`); an unrelated or typoed `cd`
# elsewhere in the same command is not covered by this and still needs to
# already exist. `mkdir -p a/b/c` also registers every intermediate
# ancestor (`a`, `a/b`) as trusted, since -p creates those too; without
# -p, only the leaf is registered, and only when its immediate parent
# already exists (a real `mkdir` without -p fails outright otherwise). A
# `git clone`/`git worktree add` destination is composed against the
# git invocation's own resolved directory (any `-C`/`--work-tree` on that
# same invocation), not just whatever a prior bare `cd` left tracked. A
# `cd` immediately followed by `||` is still resolved normally (if the
# target verifiably exists, the cd will succeed and `|| fallback` never
# runs); a `cd` that is itself the right-hand side of a `||` is left
# untrusted regardless of whether ITS target exists, since whether it
# runs at all depends on an earlier, unrelated statement's success -
# that "right after `||`" marker persists through any non-`&&`/`;` token
# in between (a redirect, an unrelated word) rather than being cleared by
# the first thing that isn't itself a `cd`. Whenever a `cd`'s effect still can't
# be confidently resolved - an unresolved `$VAR` (only the hook process's
# own environment is consulted; a bare `NAME=value` statement assigned
# earlier in the same not-yet-executed command is invisible to this static
# analysis), a typo, an empty argument, `cd -`, a bare `cd`, a conditional
# `cd ... ||` on either side, or "cd" matched as a plain argument with
# nothing directory-shaped following it - tracking is left untouched
# rather than reset: a previously-tracked, recently relevant directory is
# a safer fallback than discarding it for the tool call's unrelated raw
# cwd (this also means a `cd` that fails at runtime and a `cd` that
# statically can't be resolved are both treated as "no-op", matching real
# shell behaviour for the former and erring safe for the latter).
#
# Known limitation, not fixed: a `cd` argument built from command
# substitution (`cd $(git rev-parse --show-toplevel)/sub`) is not
# resolved - shlex's punctuation-aware tokenizer splits `$(`...`)` into
# separate `$`, `(`, ..., `)` tokens. The lone `$` is consumed as (and
# fails to resolve as) the cd's own argument, and the stray `(`/`)` are
# then misread by the subshell-boundary scan above as a real `( ... )`
# subshell, which can pop a stale `last_cd_dir` back onto the stack. A
# quoted `)` inside an otherwise plain string (`echo ")" && git push`) can
# desync the same scan the same way. Both are rare enough in a push
# command's own `cd` target to document rather than give `(`/`)` their
# own quote- and substitution-aware tokenizer-level carve-out.
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

# `git clone`/`git worktree add` options that take a value as a SEPARATE
# following token, so the destination/path scanner below must skip both the
# flag and its value, not just the flag - not exhaustive (both commands have
# many more options), but covers the ones plausible in an agent-run compound
# command: renaming the branch, shallow depth, remote name, or the new
# branch a worktree is created on.
CLONE_OPTS_WITH_VALUE = {"--branch", "-b", "--depth", "--origin", "-o"}
WORKTREE_ADD_OPTS_WITH_VALUE = {"-b", "-B", "--orphan"}

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
    b = base if base is not None else cwd
    # os.path.join already discards `b` when `val` is absolute, and handles
    # the base-is-""/"." cases the same way a manual concat would - no need
    # to special-case either by hand.
    return os.path.normpath(os.path.join(b, val))

def resolve_cd(base, arg, created_dirs):
    candidate = compose(base, arg)
    # Reality check: an unresolved $VAR (left as a literal "$VAR" segment),
    # a typo, or a cd that would actually fail at runtime all converge on
    # "this path doesn't verifiably exist right now". A real failed `cd`
    # leaves the shell's directory unchanged, so on failure keep whatever
    # was already tracked (the sentinel below) rather than either trusting
    # the bad value or discarding a previously-good one. Exception: this
    # exact candidate (or a path under it) was the target of a `mkdir`,
    # `git clone`, or `git worktree add` seen earlier in the same compound
    # command - trust_missing by exact/prefix match, not a blanket "some
    # creator command appeared somewhere earlier" flag, so an unrelated or
    # typoed `cd` elsewhere in the same command still isn't trusted.
    if os.path.isdir(candidate):
        return candidate
    trusted = any(candidate == d or candidate.startswith(d + os.sep) for d in created_dirs)
    if not trusted:
        return "UNCHANGED"
    return candidate

def register_created(base, val):
    # Registers the composed target AND every intermediate ancestor between
    # it and `base` (or cwd) - `mkdir -p a/b/c` also creates `a` and `a/b`,
    # so a later `cd a/b` should be trusted too, not just `cd a/b/c`. Bounded
    # to the anchor subtree (base/cwd): an absolute target unrelated to the
    # anchor (`mkdir /tmp/scratch` while anchor is elsewhere) must not walk
    # up into shared ancestors like `/tmp` itself and trust everything under it.
    target = compose(base, val)
    anchor = os.path.normpath(base if base is not None else cwd)
    created_dirs.add(target)
    p = os.path.dirname(target)
    guard = 0
    while p not in ("", "/") and p != anchor and p.startswith(anchor + os.sep) and guard < 64:
        created_dirs.add(p)
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
        guard += 1

out = []
i, n = 0, len(toks)
last_cd_dir = None  # most recent `cd <dir>` statement seen so far, left to right
cd_stack = []  # last_cd_dir snapshots, pushed/popped across ( ... ) boundaries
created_dirs = set()  # composed targets of mkdir / git clone / git worktree add seen earlier
prev_was_or = False  # True while processing the token immediately after `||`
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
    # `||` marks the pending "conditional" marker (`prev_was_or`, consumed
    # by the `cd` branch below as `was_or`); `&&`/`;` clear it (a new,
    # unconditional statement has started). Any other token in between -
    # punctuation like a redirect, or an unrelated word like a redirect's
    # target filename or a different command entirely - is left alone and
    # does NOT clear the marker, so it stays pending until either an
    # actual `cd` consumes it or a real `&&`/`;` supersedes it - e.g.
    # `true || >/dev/null cd dir && git push` still has `cd dir`
    # conditional on `true` having failed.
    if not is_word_char(tk[0]):
        if tk == "||":
            prev_was_or = True
        elif tk in ("&&", ";"):
            prev_was_or = False
        for ch in tk:
            if ch == "(":
                cd_stack.append(last_cd_dir)
            elif ch == ")" and cd_stack:
                last_cd_dir = cd_stack.pop()
        i += 1
        continue

    if tk == "mkdir":
        i += 1
        base = last_cd_dir
        # `-p`/`--parents` makes mkdir create every missing intermediate
        # too; without it, mkdir only creates the leaf (and FAILS if an
        # ancestor doesn't already exist) - so only trust intermediate
        # ancestors as "will exist" when -p was actually passed.
        saw_p = False
        while i < n and toks[i] and (is_word_char(toks[i][0]) or toks[i].startswith("-")):
            t = toks[i]
            if t.startswith("-"):
                if t in ("-p", "--parents") or (not t.startswith("--") and "p" in t[1:]):
                    saw_p = True
                i += 1  # flags (-p and unrecognized alike) - best-effort skip
                continue
            if saw_p:
                register_created(base, t)
            else:
                # Without -p, mkdir creates only the leaf, and FAILS
                # entirely if its immediate parent doesn't already exist -
                # so only trust the leaf when that parent is real; a
                # not-yet-existing parent means this mkdir would itself
                # fail in a real shell, so nothing after it is trustworthy.
                target = compose(base, t)
                if os.path.isdir(os.path.dirname(target)):
                    created_dirs.add(target)
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
        # Consumes the pending "right after ||" marker regardless of trust
        # outcome below - it applies to this one statement only.
        was_or, prev_was_or = prev_was_or, False
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
        # A `cd <dir> || <fallback>` only takes effect if the cd FAILS - but
        # if `<dir>` verifiably exists right now, the cd WILL succeed (same
        # real-filesystem trust resolve_cd already applies everywhere else),
        # so `||`'s presence on the right doesn't need special-casing here;
        # resolve_cd's own isdir/created_dirs check is the arbiter. A `cd`
        # that is itself the right-hand side of a preceding `||` is
        # different: whether it runs AT ALL depends on whether the prior,
        # unrelated statement failed, which isn't knowable regardless of
        # whether this cd's own target exists - so that side stays untrusted.
        if resolvable and arg is not None and not was_or:
            resolved = resolve_cd(last_cd_dir, arg, created_dirs)
            if resolved != "UNCHANGED":
                last_cd_dir = resolved
        # In every other case (`cd -`, a bare `cd`, a conditional `cd ...
        # ||` on either side, an empty/failed cd, or "cd" matched as a
        # plain argument to some other command with nothing directory-
        # shaped following it, e.g. `git commit -m cd`) last_cd_dir is
        # deliberately left UNTOUCHED rather than reset - a previously-
        # tracked, recently relevant directory is a safer fallback than
        # discarding it for the tool call's unrelated raw cwd.
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
        # Registers the clone's actual destination dir (explicit arg, or
        # inferred from the URL's basename when omitted) rather than a
        # blanket "a clone happened somewhere" flag. Composed against
        # `cdir` (this invocation's own -C/--work-tree-resolved dir, which
        # already falls back to last_cd_dir when neither was given), not
        # last_cd_dir directly - `git -C /elsewhere clone URL` clones
        # relative to /elsewhere, not wherever a prior bare `cd` left off.
        i += 1
        url = None
        dest = None
        while i < n and toks[i] and (is_word_char(toks[i][0]) or toks[i].startswith("-")):
            t = toks[i]
            if t.startswith("-"):
                i += 1
                if t in CLONE_OPTS_WITH_VALUE and i < n:
                    i += 1  # also consume this option's separate value token
                continue
            if url is None:
                url = t
            elif dest is None:
                dest = t
                i += 1
                break
            i += 1
        if url is not None and dest is None:
            base_name = url.rstrip("/").split("/")[-1]
            if base_name.endswith(".git"):
                base_name = base_name[:-4]
            dest = base_name or None
        if dest:
            register_created(cdir, dest)
    elif i < n and toks[i] == "worktree" and i + 1 < n and toks[i + 1] == "add":
        i += 2
        path = None
        while i < n and toks[i]:
            t = toks[i]
            if t.startswith("-"):
                i += 1
                if t in WORKTREE_ADD_OPTS_WITH_VALUE and i < n:
                    i += 1  # also consume this option's separate value token
                continue
            path = t
            i += 1
            break
        if path:
            register_created(cdir, path)
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
