# CLAUDE.md — contributor guardrails for the /team skill

This repo is one skill (`SKILL.md`), one orchestration script (`team.sh`), and
user docs (`HELP.md`, `README.md`). Its recurring failure mode is **doc drift** —
the same fact stated three different ways across those files. The rule below keeps
one owner per fact; everything else points to it or quotes it verbatim.

## Single source of truth

Every behaviour fact has exactly **one owner file**. Other files link to it or
quote it word-for-word — they never restate it in their own words.

| Topic | Owner | Everyone else |
|---|---|---|
| Flags, defaults, ranges (model default, team size, layout) | `HELP.md` (what `--help` prints) | `SKILL.md` keeps only what the lead must act on; `README.md` links to `--help` instead of keeping its own flag table |
| Lead procedure (steps, gates, order) | `SKILL.md` | `HELP.md` / `README.md` describe outcomes only |
| Script interface (subcommands, args, exit codes) | `team.sh` header (the comment block above `set -euo pipefail`) | `SKILL.md` shows only the invocations it needs |
| Role resolution order | `team.sh role` (code) + `SKILL.md` S2 (one sentence) | `HELP.md` and `README.md` are word-for-word summaries |
| Role content format (the five headings) | `SKILL.md` (the save-role step) | — |
| Project facts | `.team/facts.md` only | roles never hold facts; the shared library never holds project content |
| Monitor interaction (row keys, click, PROGRESS/ETA) | `HELP.md` (the monitor paragraph) | `lib/status.sh` holds the behaviour; the teammate-side `· NN%` rule is owned by `teammate-rules.md`. The percentage is self-reported — never describe it as measured. |
| Live vs. finished teammate state | `SKILL.md` step 4 (one sentence) | `HELP.md` says the same thing in the same words. Hook-based state covers *live* teammates only; a finished one has no surface, so its state is read from disk + registry. Do not "fix" this back to hooks. |
| Role vs. knowledge | role spec = *how to work* (lens, constraints, tier, lessons); `.team/facts.md` = *what is true here* | neither stores the other |

## When you change a default, flag, or behaviour

1. Edit the **owner** file above.
2. Grep the repo for the old wording and update or delete the copies.
3. Run `bash team.sh doccheck` — it flags retired drift phrases
   (`inherit the lead`, `stacked`, `3–5`, `--tmux`, `tmux pane`, `tmux session`,
   `tmux attach` and `team.sh park`), confirms every subcommand is documented in the `team.sh` header,
   and confirms every `--flag` in `SKILL.md`'s argument-hint is explained in `HELP.md`.
   Fix what it reports.

Deterministic checks belong in a hook, not prose. `.githooks/pre-commit` runs
`doccheck`; enable it with `git config core.hooksPath .githooks`. Where a global
`core.hooksPath` is already set (e.g. a Databricks secret-scanning hook —
`git config --get core.hooksPath`), don't override it: run `bash team.sh doccheck`
in CI or as a manual pre-push check so you keep the global hook.

## The full gate set

`doccheck` is the doc guard only. Before merging a branch, run all five suites
from the main checkout with `TEAM_MEMBER` unset (an inherited value makes
`rev4-3` fail for the wrong reason):

```
bash -n team.sh lib/*.sh
bash team.sh doccheck
bash tests/roles.sh
bash tests/team-build.sh      # spawn/registry/close/reap
bash tests/team-cli.sh        # secret regex, facts-lint
bash tests/status-render.sh   # monitor frames, widths, colour gate
bash tests/team-finish.sh     # finish guards, --resume, round baselines
bash team.sh facts-lint       # CHECK rows are expected when cited files changed
```

Add a new suite to this list in the same commit that adds the file, or the next
run's gates silently skip it.
