# /team — agent team emulation

Runs a small team of Claude sessions on one task. Each role is a separate
interactive `claude` session in its own pane; this session is the **lead**:
it plans the roles, relays findings between teammates for challenge rounds,
and writes the final synthesis.

## Usage
    /team <task> [options]

## Options
    --roles N        Number of teammates, 2–8 (default ~3)
    --rounds N       Challenge rounds after the first reports (default 1)
    --autoroles      Scan the project (README, layout, tests, git diff, stack) and propose
                     roles from it; waits for your OK before spawning
    --model M        Force one model for every teammate (alias or full id); a haiku-tier id
                     puts every role in dontAsk and is refused on build runs.
                     Default: the lead picks a model per role (see Choosing models)
    --tabs           One cmux tab per teammate instead of panes
    --no-gate        Build runs: skip no-mistakes (commits stay local, no push/PR)
    --no-caveman     Teammates write normal prose instead of caveman terse style
    --autoclose      Close the team right after the final synthesis
    --inline         No panes: teammates run as in-session subagents (no cmux required)
    --monitor        Open an auto-refreshing status pane showing each teammate's milestone,
                     current step, and flags. Not counted toward the teammate cap; closed
                     with the team. Ignored under --inline (no registry to read).
    --help           Show this help

## Before spawning
Every run starts with the lead closing any leftover teammates from earlier runs (it
lists them for your approval first), then brainstorming the task with you: it re-reads the
earlier conversation, `.team/facts.md` and the last run's synthesis, asks whatever
questions change the work, then writes back the task, the roles, what is out of scope and
how the result gets verified. Teammates spawn only after you approve that — a wrong
assumption otherwise gets paid once per teammate.

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
and the cheap tier only for mechanical sweeps. `team.sh pick-model <tier>` returns
the best model id for that tier on this machine (newest version within the `claude-*`
family; GLM / Kimi only by explicit full id). If no model of the requested tier is
available it falls back through the chain (opus → sonnet → haiku) and exits 1, so the
lead can see a lower tier was used; exit 3 means no model is available at any tier. Cheap-tier (haiku) teammates — and any model id that resolves to haiku tier (e.g. GLM /
Kimi) — always run unattended in `dontAsk` mode with a per-teammate allowlist:
Read/Glob/Grep, SendMessage, ListAgents, Bash restricted to `git status`/`ls`/`wc`/
`team.sh facts-lint`, and Edit on their own report, tasks.md, and status file.
`TEAM_PERMISSION_MODE` never applies to haiku tier.
Denied tools show up in their report. Haiku tier is refused on build runs. Subagents
launched by teammates default to Sonnet when available, unless the teammate specifies
otherwise. The roster you approve shows each role's model, so you can change any of
them before spawning, and the run record notes what each role ran on. An unrecognised
model is refused up front rather than opening a pane on a dead session. `--model`
forces one model everywhere; a haiku-tier id puts every role in dontAsk and is refused on build runs.

## Run types
    Review run   Read-only task, or not a git repo. Teammates share the working tree;
                 editing roles get exclusive files.
    Build run    Task edits code in a git repo. Each teammate works like a separate
                 person: own worktree (.team/worktrees/<team>-<role>), own branch
                 (team/<team>-<role>), own commits, and its own no-mistakes gate —
                 review → test → docs → lint → push → PR. The lead asks your OK first
                 because this publishes branches/PRs. Judgment calls are forwarded
                 to the lead via NEEDS INPUT; you answer them in the lead pane.
                 Summary lists every PR and flags overlapping files.
    Needs: no-mistakes (https://github.com/kunchenguid/no-mistakes) and an `origin`
    remote; without them the gate is skipped and commits stay local.

## Every teammate
- Opens in a two-column grid right of the lead, so panes stay readable as the team grows.
- Its pane folds into a tab while it is idle and comes back as a pane when it works again,
  so the grid shows only who is working. The session keeps running either way — nothing is
  killed, and you can watch any teammate again on request. (Panes + cmux only.)
- Pane/tab title is fixed to <team>-<role> (Claude's auto-titling is disabled).
- Starts in auto permission mode (TEAM_PERMISSION_MODE overrides for non-haiku tiers; haiku tier always → dontAsk + per-teammate allowlist, regardless of TEAM_PERMISSION_MODE).
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
    .team/runs/<date>-<team>/  tasks.md · prompts/ · reports/ · status/ · synthesis.md
    .team/worktrees/           build-run worktrees (removed on shutdown if clean)
Only conclusions and pointers are stored — never secrets, PII, or raw data.

Shared role library: `~/.claude/team/roles/` (outside any repo; make it a private git
repo to sync machines). `team.sh role-pull <name>` brings a shared role into this
project; `team.sh role-promote <name>` publishes a project role to the shared library
(shows a diff and scans for secrets/PII before copying). `team.sh roles` lists all
available roles with a status column:
    in-sync          Project and library copies are identical
    local-ahead      Project copy has changes not in the library (promote candidate)
    global-ahead     Library is newer — run role-pull before promoting
    diverged         Both differ from the saved base — show both diffs before deciding
    diverged (no base)  Both differ but no saved base for comparison
    project-only     Role exists in the project but not in the library (promote to add it)
    library-only     Role exists in the library but not in this project (pull to add it)
On a new machine the shared library starts empty until you sync it.

## Where teammates appear
    In cmux (default)   Your tab splits: you on the left, teammates in a two-column
                        grid on the right; idle ones fold away into tabs.
                        cmux is required for pane modes. Install: https://cmux.dev
    cmux + --tabs       A new tab per teammate in the current workspace
    --inline            No panes: teammates run as subagents inside your session.
                        Works without cmux.

## Progress (cmux sidebar)
The lead workspace shows a live status pill and progress bar: phase (spawning /
working / challenge / synthesizing) and "N/M reported". Events are logged to the
cmux event stream so you can scroll back. A badge and ring light up when any
teammate reports or sends a question — the notification comes from `cmux notify`
inside that teammate. `--monitor` adds a detailed status pane (see below).

## Cleanup: team.sh reap [--yes]
At the start of every run the lead lists any leftover teammates from earlier runs
of this project and asks you to confirm before closing them. You can also run
`team.sh reap` at any time to see the list, or `team.sh reap --yes` to close them
without prompting. Only teammates whose registry row records this project's root are
touched; live teams in other projects are never affected.

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
  (Haiku-tier teammates run in dontAsk mode and don't prompt; denied tools appear in
  their report.)
- A teammate that needs your input or a decision forwards the question to the lead via
  NEEDS INPUT with options and a recommendation; you answer it in the lead pane (with the
  recommended option presented first) and the lead relays it back — so you don't have
  to visit each pane. The lead always uses AskUserQuestion for your input.
- Build-run worktrees are pre-trusted, so they no longer prompt. A folder you have
  never opened with Claude can still show a trust prompt the first time.
- `.team/runs/<date>-<team>/tasks.md` tracks each role's status.
- Run `team.sh status <team>` to see each teammate's milestone
  (spawned → investigating → drafting → reported),
  current step, time since last activity, and flags:
    STALLED?     No update in a while — check its pane or message it
    MODEL_GONE   Its model is no longer available — respawn with a different model
    DEAD         Session exited — respawn it
    PARKED       Folded into a tab; session is still running
  With `--monitor`, this view opens automatically in a status pane and refreshes
  every 30 s (override with `TEAM_STATUS_INTERVAL`).
  Under `--inline` there is no registry; track teammates by their returned reports and tasks.md.
- Say "shut down the team" to close all teammate panes/tabs (the run record stays;
  clean worktrees are removed, branches and PRs stay).

## Output
Consensus (findings that survived challenge, with evidence) · Disputed (each
side's best evidence) · Dropped (refuted) · Next steps.

## Notes
- Non-haiku teammates start in auto permission mode (set TEAM_PERMISSION_MODE to override).
  Haiku-tier teammates always run unattended in dontAsk mode with a per-teammate allowlist
  (Read/Glob/Grep, SendMessage/ListAgents, Bash: git status/ls/wc/facts-lint, Edit on own
  report+tasks.md+status); TEAM_PERMISSION_MODE has no effect on haiku tier; they are
  refused on build runs.
- The hard cap is 8 teammates (spawn refuses beyond it).
- Cost: every teammate is a full Claude session with its own context window,
  so cost scales with team size. Prefer 2–3 sharp roles; the lead already fits a model
  to each role, so reach for `--model` only to force one model everywhere.
- Give roles separate files when the task edits code.
- This emulates Claude Code's experimental agent teams for setups where they're
  unavailable (e.g. disabled by managed settings); the lead relays challenge
  rounds instead of a native shared mailbox.
