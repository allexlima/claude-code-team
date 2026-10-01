---
name: team
description: Emulate Claude Code agent teams — one interactive claude session per role in its own cmux/tmux pane (or tab), a shared task file, cross-session messaging for challenge rounds, and a git-ignored .team/ folder with reusable roles, run records, and a verified-facts ledger. Use when the user runs /team or asks for a "team", "debate", or multiple agents that challenge each other's findings.
argument-hint: "<task> [--roles N] [--rounds N] [--model <alias|id>] [--autoroles] [--tabs] [--tmux] [--no-gate] [--no-caveman] [--autoclose] [--inline] [--help]"
---

# /team — agent team emulation

**If the arguments are empty or contain `--help`:** print `~/.claude/skills/team/HELP.md` to the user verbatim (as markdown) and stop — do not start a team.

You are the **lead**. Each teammate is a separate interactive `claude` session in its own pane — in cmux, a split of the lead's tab with teammates stacked on the right (`--tabs`: one cmux tab each instead); outside cmux, a tmux pane (`--tmux` forces tmux) — named and titled `<team>-<role>` (the title stays fixed so the user can manage panes), reachable with SendMessage. Teammates can message each other directly. Defaults: 3 roles, 1 challenge round, teammates inherit the lead's model. `--inline` runs teammates as in-session named subagents instead (no panes; see the end).

## 0. Workspace
Pick a short team slug (e.g. `rev1`) and run `bash ~/.claude/skills/team/team.sh init <team>` from the working directory. It creates/keeps `.team/` at the project root (git root, else cwd), adds `.team/` and `CLAUDE.local.md` to `.gitignore` in a git repo, adds a pointer note to `CLAUDE.local.md` once, and prints this run's dir `<run>` (`.team/runs/<date>-<team>/`). Read `.team/facts.md`. Run `bash ~/.claude/skills/team/team.sh roles` to list the roles available here (project roles override shared roles).

**Run type.** If the task edits code *and* the project is a git repo, this is a **build run**: every teammate works like a separate person — its own git worktree `.team/worktrees/<team>-<role>` on branch `team/<team>-<role>`, its own commits, and (unless `--no-gate`) its own **no-mistakes** gate run that reviews/tests/lints, pushes the branch, and opens a PR. Otherwise (read-only task, or not a git repo) it's a **review run**: no worktrees, no gate; editing roles get exclusive files instead.

## 1. Understand the task first (always)
**Never spawn teammates straight from the task text.** A wrong assumption here gets paid once per teammate, so resolve it before there are N of them.
- **Brainstorm the task with the user.** Invoke `superpowers:brainstorming` and work through intended outcome, who it is for, and what success looks like. The task line is a starting point, not a brief.
- **Re-read the previous input.** What the user said earlier in this conversation — corrections, preferences, and anything they asked for that is still outstanding — plus `.team/facts.md` and the most recent `.team/runs/*/synthesis.md`. State which of it you are carrying forward so a wrong reading gets corrected now.
- **Ask every question that changes the work.** Batch them (AskUserQuestion takes up to 4 at once) and keep asking until nothing material is unresolved: scope and non-goals, which files are in play, what "done" means, how the result gets verified, and anything ambiguous in the task. Prefer asking over assuming.
- **Get the plan approved.** Write back the task as you now understand it, the roles and their lenses, what is out of scope, and how the result will be verified. **Wait for the user's explicit OK before spawning — every run, not just `--autoroles`.**

## 2. Plan the team
- **If the user listed roles in the task, use exactly those.** For a bare name, run `bash ~/.claude/skills/team/team.sh role <name>` — it prints the spec path (project `.team/roles/` first, then the shared library `~/.claude/team/roles/`), or exits 3 when there is none; then treat the name as a new role.
- Otherwise, with `--autoroles`, do a quick, cheap scan (a few commands, no deep reads; never print secrets or data files): CLAUDE.md / README, top-level layout and languages, test and CI setup, `git status` / `git diff --stat` / recent `git log` if it's a repo, and stack markers (`databricks.yml`, notebooks, `pyproject.toml`, `package.json`, Dockerfiles). **Prefer roles from `team.sh roles`** that fit; invent new roles only for uncovered lenses (e.g. diff spanning `src/api` + `src/ui` → `backend` + `frontend`; bundle + notebooks → `dabs-config` + `pipeline-logic`; missing tests → `tests`). Show the roster as a table (role · lens · owns · one-line *why* citing the file/signal, marking each role project / shared / new) and **wait for the user's OK or edits before spawning**.
- Without either, pick N roles (3–5) from the task text.
- Each role: kebab-case name, one lens, and — if the task edits code — an **exclusive set of files**. Never let two roles edit the same file. Research/review/debug: include one adversarial role.
- **Pick a model per role.** Run `bash ~/.claude/skills/team/team.sh models` — the list is org-managed and changes, so read it instead of assuming which models exist. Match the *tier* in brackets to what the role actually demands, and pass the model id as the last argument to `spawn`:
  - `opus` — the adversarial role, and anything needing sustained multi-step judgment: architecture, security, subtle debugging, conflicting evidence.
  - `sonnet` — the default for ordinary roles: implementation, review, tests, docs.
  - `haiku` (and anything that *behaves as* it, e.g. GLM / Kimi) — only mechanical breadth: inventories, grep sweeps, running a test or lint command. **These lose auto permission mode and prompt in their own pane**, so never give one a role that has to run unattended.
  Spend the top tier where being wrong is expensive, not uniformly. If the user passed `--model`, it wins for every role. **Always pass a model** — `spawn` refuses one it does not recognise (a bad model does not fail the spawn: the pane opens on a dead session, which is invisible once that teammate is parked) and warns if you leave it off, and `team.sh list` shows what each teammate is actually running.
- Save each new approved role to `.team/roles/<role>.md` under five headings — **Lens** · **Typical scope** · **Constraints** · **Preferred tier** (opus/sonnet/haiku, *not* a model id — ids go stale; `team.sh models` already lists two opus ids) · **Lessons** (empty at first; filled in step 5). A role describes *how to work*, never facts about a project — facts go only in `.team/facts.md`. Don't overwrite an existing spec unless the user asks.
- Write `<run>/tasks.md`: one line per role (`- [ ] <team>-<role>: <scope> — owns: <files or "read-only"> — model: <model> — spec: <path from team.sh role, or "new">`), so the run record shows what each role ran on.
- Run ListAgents once and note this session's own name (the "This session is …" line) — that is `<lead>`.
- Show the roster in one short table, including each role's model and why that tier; spawning waits for the step-1 approval in every run. **Build run with gate:** the roster must say that each teammate will push `team/<team>-<role>` and open a PR, and you must **wait for the user's OK** before spawning (it publishes to the remote). Then run `bash ~/.claude/skills/team/team.sh gate-init` once from the repo: it sets up the no-mistakes gate (adds a local `no-mistakes` git remote). Exit code 3 = gate unavailable (not installed or no `origin`) — tell the user and continue as a build run without the gate.

## 3. Spawn (one pane per role)
For each role, write its prompt to `<run>/prompts/<role>.md`, then run from the working directory:
`bash ~/.claude/skills/team/team.sh spawn [--tmux] [--tabs] [--worktree] [--no-caveman] <team> <role> <run>/prompts/<role>.md <model>`
(`--worktree` for every build-run teammate; `--tmux` / `--tabs` / `--no-caveman` only if the user gave them). Teammates start in auto permission mode, with a fixed pane/tab title, with `teammate-rules.md` appended to their system prompt (split independent work across subagents in one message; verify what comes back), and with the caveman terse-output style unless `--no-caveman`. Those two are concatenated into one appended file because `claude` keeps only the last `--append-system-prompt-file`. The script prints where the pane/tab opened; relay that (for a detached tmux session, the user runs `tmux attach -t team-<team>`).

Each prompt must be self-contained (teammates don't see this conversation) and include: goal, lens (copied from the resolved role file if one exists), files owned / readable, constraints, the roster (all `<team>-<role>` names), and these instructions:
- "You are `<team>-<role>` on a team led by `<lead>`. You may message teammates directly with SendMessage (use ListAgents if a name doesn't resolve)."
- "Use parallel subagents as much as possible: whenever you have 2+ independent sub-tasks (exploring areas, reviewing files, running checks, drafting separate pieces), dispatch them with the Agent tool in a single message so they run concurrently, and keep your own context for coordination and verification. Do sequential work yourself only when steps depend on each other."
- "First read `<abs>/.team/facts.md`, then run `bash ~/.claude/skills/team/team.sh facts-lint` and re-check only the facts it marks CHECK / GONE / NOANCHOR (a FRESH fact's cited file is unchanged since its evidence SHA). Treat entries as leads, not ground truth; report any you find contradicted as STALE."
- Build run only: "You work in your own git worktree `<abs worktree>` on branch `team/<team>-<role>` — edit and commit only there (small, focused commits; never touch other teammates' worktrees or the main checkout). Stay inside your scope so your PR doesn't conflict with teammates'. When your work is committed and verified, gate it: `no-mistakes axi run --intent \"<your goal in one sentence>\"` (never `--yes`). At each approval point: `no-mistakes axi respond --action fix` for actionable findings; ask the user in this pane for judgment calls, protected-path or unvalidated-test refusals — never approve those yourself. If `--wait` elapses, reattach with `no-mistakes axi status`. Include your branch, the gate outcome, and the PR URL in your report." (If the gate is off, replace the gate part with: "leave your commits on the branch; don't push.")
- "When done, write your report to `<abs run>/reports/<role>.md`, tick your line in `<abs run>/tasks.md`, then SendMessage the same report to `<lead>`, then wait for further messages. Format:"
```
FINDINGS: numbered, each with evidence (file:line, command output, or source)
CONFIDENCE: high/medium/low per finding
STALE FACTS: facts.md entries contradicted, with evidence (or "none")
OPEN QUESTIONS: what you couldn't verify
PARALLELISM: how many subagents you dispatched and for what (or why the work was not splittable)
```
After spawning, run ListAgents to confirm every teammate appears (retry briefly; sessions take a few seconds to start). If one doesn't, read its screen (`cmux read-screen --surface <ref> --lines 30` or `tmux capture-pane -p -t <pane-id>`; ids are in `/tmp/team-<team>.tabs`) to see why — e.g. a trust or permission prompt the user must answer in that pane — and tell the user.

**Panes are the user's audit view.** Teammates open in a two-column grid to the right of you, so each stays readable instead of getting 1/N of the screen height. Keep that grid to teammates that are *actually working*:
- When a teammate's report arrives, `bash ~/.claude/skills/team/team.sh park <team> <role>` — its pane folds into a tab in your pane. The session is untouched: still running, still in ListAgents, still messageable, and cmux badges the tab if it needs input.
- Before you send a teammate work again, `... show <team> <role>` first, so the user can watch it while it works.
- `... list <team>` prints each teammate as working / parked / closed — use it to reconcile instead of guessing.
Parking needs the cmux backend and panes; with `--tabs` or tmux there is nothing to fold, and the commands say so.

## 4. Challenge rounds (default 1)
When all reports are in, SendMessage each teammate the *other* teammates' findings, labeled by name: "Try to disprove or refine these using evidence — message the author directly if useful. Then append your AGREE / DISPUTE (with evidence) / REFINE per finding and revised list to your report file, and send it to me." `show` each teammate you are about to message so the user can watch the round, then send all before waiting. Relay faithfully — never present your own claims as a teammate's.

## 5. Synthesize and record
Report: build runs first list each teammate's branch, gate outcome, and PR URL, and flag any teammates whose branches touch the same files (merge-conflict risk). Then **Consensus** (survived challenge, with evidence) · **Disputed** (each side's best evidence) · **Dropped** (refuted, one line each) · **Next steps**. Save the same text to `<run>/synthesis.md`.
Update `.team/facts.md`: append **consensus findings only** as one line each (`- <fact> — evidence: <file:line | command> @<git short SHA> — <YYYY-MM-DD>, run <run dir name>`; use `@nogit` outside a repo), and for each confirmed STALE fact, strike it through with a pointer to the contradicting run (don't delete). Before appending, write your new lines to a scratch file and run `bash ~/.claude/skills/team/team.sh facts-lint --pre-append <file>` — it refuses on a secret/PII hit. Never write secrets, PII, raw data, or unverified claims. Tell the user how many facts were added / marked stale.
Make roles learn: for each role spec used this run, append at most one line under its `**Lessons:**` heading when the challenge round exposed a *method* failure — what the role missed and how to work next time (e.g. "reproduce shell claims in a scratch repo; doc-reading alone missed the bug"). Lessons are about method, never this project's code (that goes to facts.md); cap at ~8 lines and propose a merge when full. Show the user the diff before writing.
**Promote roles (optional).** For each role this run saved to the project, ask once — batched into a single AskUserQuestion — "Add `<role>` to your shared library (`~/.claude/team/roles/`)?" On yes: confirm the spec names no customer, project, or file; run `team.sh facts-lint --pre-append` over it; show the diff; then copy it there. Never overwrite an existing shared role without a second yes, and never git-commit it (the shared library lives outside any repo).
Park each teammate once its work is done (`team.sh park <team> <role>`): the workspace ends clean with the whole team still running and messageable, and the user can watch any of them again with `team.sh show <team> <role>`. Unless `--autoclose` was given, in which case shut the team down right after this step. When the user says the team is done ("shut down the team"), SendMessage each teammate that the team is done, then run `bash ~/.claude/skills/team/team.sh close <team>` (closes every recorded pane/tab; the run record in `.team/` stays). For build runs, also run `bash ~/.claude/skills/team/team.sh clean <team>` — removes worktrees without uncommitted changes (branches and PRs stay); report any it kept.

## Rules
- Don't do teammates' work yourself; wait for their messages. If one stalls, message it; if it died, respawn with the same name.
- A parked teammate is only a tab away, but its prompts are off-screen: if one goes quiet, `team.sh show <team> <role>` so the user can see whatever is waiting in it.
- Every claim in the synthesis and facts.md must trace to a teammate's evidence.
- Teammate permission prompts appear in *their* panes — tell the user to approve there. Never relay approvals between sessions.
- Haiku teammates fall back to manual permission mode (auto mode isn't available on Haiku), so they'll prompt in their panes — warn the user if they pick `--model haiku`.
- Keep your own synthesis to the user in normal prose (caveman style is for teammates only).
- Cost: each teammate is a full session. Prefer fewer, sharper roles; suggest `--model sonnet` for broad sweeps.

## --inline mode
Steps 1–2 (understand the task, get the plan approved) apply unchanged. Skip `team.sh spawn`/`close` (still run `init`); no worktrees or gate — inline teammates share your working tree, so give editing roles exclusive files. Spawn all teammates in one message with the Agent tool (`name: <role>`, `model` if given), same prompts minus the pane/ListAgents lines; their reports return to you automatically (write them to `<run>/reports/` yourself). Challenge rounds use SendMessage `to: <role>`. No panes to clean up.
