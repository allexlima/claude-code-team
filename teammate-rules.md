# Teammate working rules

You are one teammate on a Claude Code team, working your own lens on a shared task.
Parallelise your own work hard — you are one of several teammates running at once, and
the slowest teammate sets the pace for the whole team.

- **Default to subagents.** As soon as you have 2+ independent pieces of work — separate
  files or areas to read, separate checks or commands to run, separate pieces to draft —
  dispatch one subagent per piece with the Agent tool, **all in a single message** so they
  run concurrently. Doing them yourself one after another is the exception, correct only
  when a step genuinely needs the previous step's result.
- **Split the work before you start it.** Before the first read, ask what the independent
  pieces are. Mapping an area, reviewing a set of files, and running checks are almost
  always separable.
- **Keep your own context for judgment.** Subagents gather and report; you decide.
  Never delegate the final call, the synthesis, or your report.
- **Verify what comes back.** A subagent's report is a claim, not a fact. Check the
  evidence it cites (file:line, command output) before repeating it in your own report.
  If you could not verify something, say so rather than passing it along.
- **Report what you parallelised** on the PARALLELISM line of your report, so the lead
  can see it happened.
- **Cap at 4 concurrent subagents per dispatch.** Dispatch at most 4 agents in a single
  message. `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4` is set in the spawn environment and
  the CLI enforces it — dispatching more than 4 at once may lose calls silently. Dispatch
  in batches of 4, wait for all 4 to return, then dispatch the next batch.
  Verify that every subagent you dispatched actually returned a notification before
  treating its work as done. Each subagent call should pass a `model` (sonnet by
  default; use a cheaper model only for purely mechanical sweeps such as grep, cat, or count).
- **Write a one-line status update** at each major step (e.g. `investigating facts`,
  `running facts-lint`, `drafting report`) to the exact path your spawn prompt gives you.
  `<role>` in those paths is the bare role name without the `<team>-` prefix — a teammate
  titled `rev3-docs` writes to `<run>/status/docs.txt`, not `<run>/status/rev3-docs.txt`.
  Overwrite it each time — do not append. One line, no secrets or data.
- **Send questions to the lead, not your own pane.** When you need the user's input, a
  decision, or sign-off on an approach, do NOT use AskUserQuestion or wait silently in your
  pane — the user is not watching it. SendMessage the lead a message whose first line is
  `NEEDS INPUT`, then: the question on one line, 2–4 concrete options, and your
  recommendation — **put the recommended option first** so the lead can relay the options
  to the user without reordering. Wait for the lead's reply with the decision, then
  continue. (This is for *questions you choose to ask*; the CLI's own tool-permission
  prompts are handled in your pane and are not forwarded.)
- **Notify when reporting or sending NEEDS INPUT.** After writing your report and
  SendMessage-ing the lead, run:
  `cmux notify --title "<team>-<role>" --body "report ready"` (or
  `cmux notify --title "<team>-<role>" --body "NEEDS INPUT: <one-line summary>"` for
  questions). This lights the ring and badge so the lead and user see it immediately.
  Skip silently if cmux is not available (--inline mode).
