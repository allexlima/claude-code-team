# /team — agent teams for Claude Code, in your terminal panes

A [Claude Code](https://code.claude.com) skill that runs a **team of Claude sessions** on one task — each teammate a full, interactive `claude` session in its own titled [cmux](https://cmux.dev) pane — with a lead that plans roles, runs challenge rounds where teammates try to disprove each other, and synthesizes what survived.

It emulates Claude Code's experimental [agent teams](https://code.claude.com/docs/en/agent-teams) using only standard features (interactive sessions, cross-session messaging, subagents), so it works even where native agent teams are disabled.

```
┌──────────────────────┬───────────────┬───────────────┐
│  you + the lead      │ rev1-security │ rev1-perf     │
│  (plans · relays ·   ├───────────────┼───────────────┤
│   synthesizes)       │ rev1-tests    │ rev1-skeptic  │
└──────────────────────┴───────────────┴───────────────┘
```

## Features

- **One pane per teammate**, titled `<team>-<role>` so you can click in and talk to any of them directly.
- **Questions centralized in the lead** — a teammate that needs your input forwards it to the lead, which asks you (with options) in one place and relays your answer back, so you answer everything in the lead pane instead of hunting across panes.
- **Challenge rounds** — each teammate gets the others' findings and must AGREE / DISPUTE / REFINE with evidence. Output: *Consensus · Disputed · Dropped · Next steps*.
- **Build runs work like a real team** — in a git repo, each teammate gets its own worktree and branch, commits its own work, and gates it through [no-mistakes](https://github.com/kunchenguid/no-mistakes) (review → test → lint → push → PR). One PR per teammate.
- **`--autoroles`** — derives roles from your project (README, layout, tests, git diff, stack) and asks you to confirm.
- **Project memory in `.team/`** (git-ignored) — project role specs (plus a shared role library in `~/.claude/team/roles/`), a full record of every run, and a `facts.md` ledger of verified findings that future teams read first.
- **Token-aware** — teammates use parallel subagents and the [caveman](https://github.com/JuliusBrussee/caveman) terse style for agent-to-agent chatter; your summary stays in normal prose.

## Install

```bash
git clone https://github.com/allexlima/claude-code-team ~/.claude/skills/team
```

That's it — start (or restart) Claude Code and run `/team --help`.

**Try it:** `/team review my current changes --autoroles` — the lead proposes roles from your repo, you approve, and the team runs.

**Update:** `git -C ~/.claude/skills/team pull` · **Uninstall:** `rm -rf ~/.claude/skills/team`

### Requirements

| | |
|---|---|
| Required | [Claude Code](https://code.claude.com), `python3`, and **[cmux](https://cmux.dev)** for panes (or use `--inline` for no panes) |
| Build runs | `git`, an `origin` remote, [no-mistakes](https://github.com/kunchenguid/no-mistakes) (optional — without it, commits just stay local) |
| Optional | [caveman](https://github.com/JuliusBrussee/caveman) installed at `~/.agents/skills/caveman` (skipped if absent) |

## Usage

```
/team <task> [options]
```

```text
/team review PR #42 for security, performance and test coverage
/team why does the streaming job lag? --roles 4 --rounds 2 --model sonnet
/team review my current changes --autoroles
/team add retry logic to the ingestion job and cover it with tests --autoroles
/team research vector search options for our RAG demo --tabs --autoclose
```

Name roles yourself if you like — `Roles: security: auth + tokens, perf: DB queries, skeptic: challenge the others`. Saved roles load by name — first from the project (`.team/roles/`), then from your shared library (`~/.claude/team/roles/`). Run `/team --help` for the full list of options.

When you're done, say **"shut down the team"**.

## How it works

1. **Plan** — the lead picks roles (yours, saved ones, or `--autoroles`), each with one lens and its own scope, including one adversarial role.
2. **Spawn** — `team.sh` opens one pane per role running `claude -n <team>-<role>` in auto permission mode, in a worktree for build runs.
3. **Work** — teammates read `.team/facts.md`, fan out with parallel subagents, write reports to `.team/runs/…/reports/`, and message the lead.
4. **Challenge** — the lead sends each teammate the others' findings; they try to disprove them (and can message each other directly).
5. **Synthesize & record** — consensus findings are added to `facts.md` with evidence; stale facts are struck through, never silently deleted.

```
.team/                       (git-ignored; pointer added to CLAUDE.local.md, never CLAUDE.md)
├── facts.md                 verified findings: fact — evidence — date, run
├── roles/<role>.md          project roles (override ~/.claude/team/roles/)
├── runs/<date>-<team>/      tasks.md · prompts/ · reports/ · status/ · synthesis.md
└── worktrees/               build-run worktrees
```

## Good to know

- **Cost scales with team size** — every teammate is a full Claude session. 2–3 sharp roles beat 5 vague ones.
- **Tool-permission prompts appear in each teammate's own pane** — teammate *questions*, by contrast, are forwarded to the lead, who relays them to you in one place. Haiku-tier models (including behaves-as-haiku ones like GLM/Kimi) run unattended in dontAsk mode with a per-teammate allowlist (Read/Glob/Grep, SendMessage/ListAgents, Bash: git status/ls/wc/facts-lint, Edit on own report+tasks.md+status) on review runs; denied tools show up in their report.
- **First time in a folder**, each pane shows Claude's workspace-trust prompt (folders inside a trusted project are already trusted).
- **Build runs publish** (push + PR per teammate); the lead always asks before spawning them.
- Tested on macOS with cmux.

## License

[MIT](LICENSE)
