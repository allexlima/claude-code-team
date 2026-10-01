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
| Script interface (subcommands, args, exit codes) | `team.sh` header (lines 1–27) | `SKILL.md` shows only the invocations it needs |
| Role resolution order | `team.sh role` (code) + `SKILL.md` S2 (one sentence) | `HELP.md` and `README.md` are word-for-word summaries |
| Role content format (the five headings) | `SKILL.md` (the save-role step) | — |
| Project facts | `.team/facts.md` only | roles never hold facts; the shared library never holds project content |
| Role vs. knowledge | role spec = *how to work* (lens, constraints, tier, lessons); `.team/facts.md` = *what is true here* | neither stores the other |

## When you change a default, flag, or behaviour

1. Edit the **owner** file above.
2. Grep the repo for the old wording and update or delete the copies.
3. Run `bash team.sh doccheck` — it flags retired drift phrases
   (`inherit the lead`, `stacked`, `3–5`), confirms every subcommand is
   documented in the `team.sh` header, and confirms every `--flag` in
   `SKILL.md`'s argument-hint is explained in `HELP.md`. Fix what it reports.

Deterministic checks belong in a hook, not prose. `.githooks/pre-commit` runs
`doccheck`; enable it with `git config core.hooksPath .githooks`. Where a global
`core.hooksPath` is already set (e.g. a Databricks secret-scanning hook —
`git config --get core.hooksPath`), don't override it: run `bash team.sh doccheck`
in CI or as a manual pre-push check so you keep the global hook.
