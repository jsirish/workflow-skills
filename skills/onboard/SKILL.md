---
name: onboard
description: Bootstrap agent context at the start of a new session. Reads project state, checks environment, and aligns on goals.
---

# Skill: Onboard

**Goal:** Get a new or returning agent fully up to speed on a project before starting any work. This ensures no time is wasted on already-solved problems and that work follows established patterns.

**Persistent handoff:** `<project-root>/.agent/handoff/HANDOFF.md`

---

## Phase 1: Load Project Context

1. Read the persistent project state document: `<project-root>/.agent/handoff/HANDOFF.md`
   - If it doesn't exist, note this — the project has no accumulated handoff state yet.
2. If the user mentions a specific recent task or problem, check the linked session logs under "Recent Session Logs" in `HANDOFF.md`.
3. Scan available Knowledge Items (KIs) for relevant existing analysis.

---

## Phase 2: Check Environment

1. Verify the workspace structure:
   ```bash
   ls <project-root>/
   ```
2. Check for project-specific tooling (Docker, DDEV, npm, composer, etc.):
   ```bash
   # Adapt to the project — check whatever runtime/tooling is relevant
   which docker git gh 2>/dev/null
   ```
3. Verify version control state:
   ```bash
   git remote show origin | grep 'HEAD branch'
   git status --short
   ```
4. Check code intelligence (codegraph). A `codegraph` MCP server indexes every
   symbol/edge/file into local SQLite — querying it (`codegraph_context`, then one
   `codegraph_explore`, always passing `projectPath: <absolute root>`) beats grep for
   "how does X work" / architecture / where-is-X questions later in the session.
   ```bash
   if [ -d .codegraph ]; then
     # Index exists — freshen after the branch switch / pull that started this session.
     codegraph sync || echo "Warning: codegraph sync failed — index may be stale"
   fi
   ```
   - If `.codegraph/` is **absent** and this is a non-trivial **code** project, offer
     to initialize it (a file watcher then keeps it current):
     ```bash
     codegraph init && codegraph index
     ```
   - Don't initialize unconditionally — skip config-only, docs-only, or otherwise
     non-code projects. `.codegraph/` is a local artifact; ensure it's gitignored.

---

## Phase 3: Check Operational State

1. List open PRs for the project:
   ```bash
   gh pr list --state open --limit 10
   ```
2. Check open issues:
   ```bash
   gh issue list --state open --limit 10
   ```
3. If production/deployment is relevant and documented in `HANDOFF.md`, check service health using the methods described there.

---

## Phase 4: Align on Goals

1. Summarize what you've learned from the handoff doc and operational state.
2. Ask the user: **"What's the goal for this session?"**
3. Based on their answer and the project context, create an actionable plan.
4. Present the plan for confirmation before starting work.

---

## Important Reminders

- **Don't skip Phase 1.** Reading `HANDOFF.md` is the most important step — it prevents re-solving known problems.
- **Be concise in your summary.** The user doesn't need you to recite the handoff doc back to them. Highlight only what's relevant to the session.
- **Check for stale branches.** If `HANDOFF.md` mentions branches pending PR or in-progress work, verify their current status before assuming they're still relevant.
- **Adapt to the project.** Not every project has Docker, production servers, or multiple repos. Use what's documented in `HANDOFF.md` to guide which checks are relevant.
