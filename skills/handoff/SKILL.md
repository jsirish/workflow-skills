---
name: handoff
description: Updates the master HANDOFF.md with distilled knowledge and creates a timestamped session log. Run ONLY when explicitly invoked by the user via /handoff.
---

# Skill: Handoff

**Goal:** Update the project's long-term memory (`HANDOFF.md`) with concise, high-value information from the completed session, and generate a detailed session log for historical reference.

**Persistent handoff:** `<project-root>/.agent/handoff/HANDOFF.md`
**Session logs:** `<project-root>/.agent/handoffs/handoff-YYYY-MM-DD-HHMM.md`

---

## Phase 1: Ingest and Analyze

1. Read the **entire current** `.agent/handoff/HANDOFF.md` to understand its structure and existing content.
   - If `.agent/handoff/HANDOFF.md` does not exist, create it using the template in Phase 5.
2. Review the work completed in this session — commands run, files changed, decisions made, issues resolved.
3. Identify what constitutes a **permanent, reusable change** versus session-specific noise.

---

## Phase 2: Synthesize Updates

For each relevant section of `HANDOFF.md`, prepare concise updates. Use this checklist — skip sections that don't apply to the current project:

### Architecture & Services
- [ ] Were any repos, services, or components added, removed, or restructured?
- [ ] Did the container/service topology change?

### Environment & Infrastructure
- [ ] Was anything deployed to production or staging?
- [ ] Did infrastructure config change? (docker-compose, server config, etc.)
- [ ] Were system versions updated? (runtimes, frameworks, databases)

### Tools & Integrations
- [ ] Were tools, APIs, or integrations added, renamed, or removed?
- [ ] Did authentication or token handling change?

### Configuration & Secrets
- [ ] Were config files modified?
- [ ] Were new env vars or API keys added? (Document key name and purpose, **never the value**)

### Skills & Workflows
- [ ] Were agent skills or workflows added, updated, or found broken?

### Resolved Issues
- [ ] Move any newly-resolved issues from "Pending" to "Resolved Issues" with brief root cause + fix summary.
- [ ] **Remove** resolved items from the pending table.

### Pending Items
- [ ] Did your work uncover new problems, necessary refactors, or next steps?
- [ ] Add these as actionable items to "Pending Items".

### Key Files & Resources
- [ ] Were any important new files, scripts, or directories created?

---

## Phase 3: Generate Session Log

Create a detailed timestamped session log at `.agent/handoffs/handoff-YYYY-MM-DD-HHMM.md`. Use current local date/time for the filename. Create `.agent/handoffs/` if it doesn't exist.

The session log MUST contain ALL of the following sections:

```markdown
# Handoff: <Brief Title>
**Date:** <YYYY-MM-DD HH:MM TZ>
**Conversation ID:** <conversation-id if available>

## Objective
What the user is trying to accomplish (the big picture goal).

## Plan
The full technical plan that was agreed upon. Include architecture decisions,
file paths, and any design choices made.

## Progress
### Completed
- List every completed item with specifics (PR numbers, commits, file changes)

### In Progress
- Items that were started but not finished

### Not Started
- Items from the plan that haven't been touched yet

## Key Learnings & Gotchas
Critical discoveries that will save the next agent time. Include:
- Bugs encountered and their root causes
- Non-obvious configuration details
- Workarounds applied
- Things that look like they should work but don't

## Current State
### Repository Status
- Branch status, uncommitted changes, remote sync state

### Production Status
- What's deployed, what's pending, container/service health

### Open PRs & Issues
- Links and status of any open PRs or issues

## Next Steps
Ordered list of exactly what the next agent should do first, second, third.
Be specific — include exact commands, file paths, and expected outcomes.

## Files & Resources
Key file paths, URLs, credentials locations, and documentation references
the next agent will need.
```

---

## Phase 4: Execute and Finalize

1. Update `HANDOFF.md` with all synthesized changes from Phase 2.
2. Update the **`Last Updated`** date at the top of `HANDOFF.md`.
3. Add a link to the new session log under "Recent Session Logs" in `HANDOFF.md`. **Keep only the last 5 entries** — remove the oldest if needed.
4. Do a final read-through to ensure `HANDOFF.md` remains **concise, accurate, and well-organized**.
5. **Notify the user** with paths to both the updated `HANDOFF.md` and the new session log for review.

---

## Phase 5: HANDOFF.md Template

If `HANDOFF.md` does not yet exist, create it with the following structure. Remove sections that don't apply to the project:

```markdown
# <Project Name> Project Handoff

**Last Updated:** <YYYY-MM-DD>

---

## Architecture & Services
High-level overview of project structure, repos, services, and their relationships.

## Environment & Infrastructure
Production/staging status, server info, deployment config.

## Tools & Integrations
Registered tools, API integrations, known issues.

## Authentication & Secrets
Key names and purposes (never values). OAuth status, token locations.

## Skills & Workflows
Agent capabilities, skill paths, workflow references.

## Resolved Issues
| Issue | Resolution | Date |
|-------|-----------|------|

## Pending Items
| Item | Priority | Tracking |
|------|----------|----------|

## Key Files & Resources
| Resource | Path |
|----------|------|

## Recent Session Logs
1. [Title](relative/path/to/session-log.md) — YYYY-MM-DD
```

---

## Important Reminders

- **Keep it tight.** Each entry in `HANDOFF.md` should be 1–2 lines max. This is a reference doc, not a journal.
- **Preserve structure.** Work within the existing sections — do not add new top-level sections unless truly necessary.
- **Don't duplicate.** If something is already documented, update the existing entry rather than adding a new one.
- **Session logs are the detail.** Put verbose context, debugging notes, and architecture diagrams in the timestamped session log, not in `HANDOFF.md`.
- **Start of session habit.** At the *start* of every new session, read `HANDOFF.md` to load project context before beginning work.
- **User-invoked only.** Never run this workflow proactively after completing a task. The user will invoke `/handoff` when they decide the session's work is complete.
