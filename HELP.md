# /team — agent team emulation

Runs a small team of Claude sessions on one task. Each role is a separate
interactive `claude` session in its own pane; this session is the **lead**:
it plans the roles, relays findings between teammates for challenge rounds,
and writes the final synthesis.

## Usage
    /team <task> [options]

## Options
    --roles N        Number of teammates, 2–5 (default 3)
    --rounds N       Challenge rounds after the first reports (default 1)
    --autoroles      Scan the project (README, layout, tests, git diff, stack) and propose
                     roles from it; waits for your OK before spawning
    --model M        Force one model for every teammate (alias or full id).
                     Default: the lead picks a model per role (see Choosing models)
    --tabs           One cmux tab per teammate instead of panes
    --tmux           Force tmux even inside cmux
    --no-gate        Build runs: skip no-mistakes (commits stay local, no push/PR)
    --no-caveman     Teammates write normal prose instead of caveman terse style
    --autoclose      Close the team right after the final synthesis
    --inline         No panes: teammates run as in-session subagents
    --help           Show this help

## Before spawning
Every run starts with the lead brainstorming the task with you: it re-reads the earlier
conversation, `.team/facts.md` and the last run's synthesis, asks whatever questions
change the work, then writes back the task, the roles, what is out of scope and how the
result gets verified. Teammates spawn only after you approve that — a wrong assumption
otherwise gets paid once per teammate.

## Choosing roles
- List them in the task (`Roles: security: …, perf: …, skeptic: …`) — used as-is.
  A bare name loads a saved role: this project's `.team/roles/<name>.md` first,
  else your shared library `~/.claude/team/roles/<name>.md`.
- Or `--autoroles` — derived from the project (reusing saved roles first),
  shown with reasons, you confirm. Approved new roles are saved for reuse.
- Otherwise the lead picks roles from the task text alone.
- Best practice: one distinct lens per role, one adversarial role, separate
  files per role when editing, 2–3 roles.

## Choosing models
The lead lists what this machine actually offers (`team.sh models` — the set is
org-managed, so it is read at run time, not hardcoded) and gives each role the
cheapest tier that still fits it: the top tier for the adversarial role and for
architecture / security / subtle debugging, the middle tier for ordinary work,
and the cheap tier only for mechanical sweeps. Cheap-tier teammates lose auto
permission mode and will prompt in their pane, so they are not used for roles
meant to run unattended. The roster you approve shows each role's model, so you
can change any of them before spawning, and the run record notes what each role ran
on. An unrecognised model is refused up front rather than opening a pane on a dead
session. `--model` forces one model everywhere.

## Run types
    Review run   Read-only task, or not a git repo. Teammates share the working tree;
                 editing roles get exclusive files.
    Build run    Task edits code in a git repo. Each teammate works like a separate
                 person: own worktree (.team/worktrees/<team>-<role>), own branch
                 (team/<team>-<role>), own commits, and its own no-mistakes gate —
                 review → test → docs → lint → push → PR. The lead asks your OK first
                 because this publishes branches/PRs. You answer judgment calls in the
                 teammate's pane. Summary lists every PR and flags overlapping files.
    Needs: no-mistakes (https://github.com/kunchenguid/no-mistakes) and an `origin`
    remote; without them the gate is skipped and commits stay local.

## Every teammate
- Opens in a two-column grid right of the lead, so panes stay readable as the team grows.
- Its pane folds into a tab while it is idle and comes back as a pane when it works again,
  so the grid shows only who is working. The session keeps running either way — nothing is
  killed, and you can watch any teammate again on request. (Panes + cmux only.)
- Pane/tab title is fixed to <team>-<role> (Claude's auto-titling is disabled).
- Starts in auto permission mode (TEAM_PERMISSION_MODE overrides; Haiku → manual).
- Splits its own work across subagents: anything independent (separate files, checks or
  drafts) is dispatched in one message so it runs concurrently, and its report says what
  it parallelised. It still verifies what the subagents hand back before reporting it.
- Writes in caveman style (https://github.com/JuliusBrussee/caveman) to save tokens;
  code, paths and errors unchanged. The lead's summary to you stays normal prose.

## Project memory: .team/
Created at the project root on first run (git-ignored, along with CLAUDE.local.md;
a one-time pointer note is added to CLAUDE.local.md — never to CLAUDE.md):
    .team/facts.md             Consensus findings with evidence + date + run id;
                               every teammate reads it first and flags stale entries
    .team/roles/<role>.md      Roles saved in this project (override shared roles)
    .team/runs/<date>-<team>/  tasks.md · prompts/ · reports/ · synthesis.md
    .team/worktrees/           build-run worktrees (removed on shutdown if clean)
Only conclusions and pointers are stored — never secrets, PII, or raw data.

Shared role library: `~/.claude/team/roles/` (outside any repo; roles land there only
when you agree to promote one — make it a private git repo to sync machines). On a new
machine it starts empty until you sync it, so your saved roles are not lost, just not
there yet.

## Ruflo memory bridge (optional)

When `ruflo` is installed and its memory is persisting, `/team` maintains a
semantic-search index alongside `.team/facts.md`:

- `mem-sync` — rebuilds this project's facts and role Lessons in the memory DB.
  Skips (exit 0) if `ruflo` is absent or not persisting. Exit 2 if a secret/PII
  pattern is found — nothing is stored.
- `mem-recall [--all-projects] [--limit N] "<query>"` — semantic search; prints
  `<kind><TAB><score><TAB><text>` per hit (kind: `fact`, `lesson`, or
  `fact:<project-id>` with `--all-projects`; default limit 5). Struck-through facts
  come back with their `~~markup~~` intact.
- **`TEAM_MEMORY_DB`** — path to the SQLite database
  (default `$HOME/.claude/team/memory.db`). Ruflo's working files (ruvector.db,
  .swarm/, .claude-flow/) land next to this file, not in the project.

Without Ruflo, `/team` behaves exactly as today — `.team/facts.md` stays the
single source of truth.

## Where teammates appear
    In cmux (default)   Your tab splits: you on the left, teammates in a two-column
                        grid on the right; idle ones fold away into tabs
    cmux + --tabs       A new tab per teammate in the current workspace
    Inside tmux         Panes split from your current window
    Neither             Detached tmux session — run: tmux attach -t team-<team>

## Examples
    /team review PR #42 for security, performance and test coverage
    /team why does the streaming job lag? --roles 4 --rounds 2 --model sonnet
    /team research vector search options for our RAG demo --tabs --autoclose
    /team review my current changes --autoroles
    /team add retry logic to the ingestion job and cover it with tests --autoroles
    /team quick sanity review of src/utils.py --roles 2 --inline

## While it runs
- Click into any teammate pane to talk to it directly or redirect it. An idle
  teammate is a tab in your pane rather than a pane of its own — click its tab, or
  ask the lead to put it back on screen.
- Teammate *tool-permission* prompts appear in *their* pane — approve them there.
- A teammate that needs your input or a decision forwards the question to the lead; you
  answer it in the lead pane (with options) and the lead relays it back — so you don't
  have to visit each pane.
- Build-run worktrees are pre-trusted, so they no longer prompt. A folder you have
  never opened with Claude can still show a trust prompt the first time.
- `.team/runs/<date>-<team>/tasks.md` tracks each role's status.
- Say "shut down the team" to close all teammate panes/tabs (the run record stays;
  clean worktrees are removed, branches and PRs stay).

## Output
Consensus (findings that survived challenge, with evidence) · Disputed (each
side's best evidence) · Dropped (refuted) · Next steps.

## Notes
- Teammates start in auto permission mode (set TEAM_PERMISSION_MODE to
  override). Haiku falls back to manual, so it will prompt more.
- Cost: every teammate is a full Claude session with its own context window,
  so cost scales with team size. Prefer 2–3 sharp roles; the lead already fits a model
  to each role, so reach for `--model` only to force one model everywhere.
- Give roles separate files when the task edits code.
- This emulates Claude Code's experimental agent teams for setups where they're
  unavailable (e.g. disabled by managed settings); the lead relays challenge
  rounds instead of a native shared mailbox.
