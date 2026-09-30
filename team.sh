#!/usr/bin/env bash
# Run each teammate as an interactive `claude` session in its own tab/pane.
#   team.sh spawn [--tmux] [--tabs] [--worktree] [--no-caveman] <team> <role> <prompt-file> [model]
#   team.sh close <team>
#   team.sh init <team>   -> creates .team/ (idempotent) + a run dir; prints the run dir path
#   team.sh gate-init     -> sets up the no-mistakes gate for this repo (needs an "origin" remote)
#   team.sh clean <team>  -> removes the team's worktrees that have no uncommitted changes (branches kept)
# --worktree: the teammate works in its own git worktree .team/worktrees/<team>-<role>
# on a new branch team/<team>-<role> (from the current HEAD), like a separate person.
# Every pane/tab is titled <team>-<role> (Claude's own terminal-title updates are disabled so it sticks).
# Teammates get the caveman output style (~/.agents/skills/caveman/SKILL.md) unless --no-caveman.
# Backend: a cmux tab in the lead's workspace when running inside cmux, else a tmux pane
# (splits the lead's window inside tmux, otherwise a detached session "team-<team>").
# cmux default: split the lead's tab — first teammate to the right, the rest stacked below it.
# --tabs (cmux): one tab per teammate instead. --tmux forces tmux.
# Teammates start in auto permission mode (override with TEAM_PERMISSION_MODE). Spawned tabs/panes are recorded in /tmp/team-<team>.tabs for close.
set -euo pipefail
sub=${1:?spawn|close}; shift

if [ "$sub" = init ]; then
  team=${1:?team}
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  d="$root/.team"
  mkdir -p "$d/roles" "$d/runs"
  [ -f "$d/README.md" ] || cat > "$d/README.md" <<'MD'
# .team — /team skill workspace (git-ignored)
- `facts.md` — verified facts from past runs (consensus only, with evidence). Read before working; flag stale entries.
- `roles/<role>.md` — reusable teammate role specs (lens, owns, constraints, model).
- `runs/<date>-<team>/` — per run: `tasks.md`, `prompts/`, `reports/`, `synthesis.md`.
Never store secrets, PII, or raw data here — conclusions and pointers only.
MD
  [ -f "$d/facts.md" ] || printf '# Facts

<!-- - <fact> — evidence: <file:line | command> — <YYYY-MM-DD>, run <run-id> -->
' > "$d/facts.md"
  if git -C "$root" rev-parse 2>/dev/null; then
    for p in .team/ CLAUDE.local.md; do
      git -C "$root" check-ignore -q "$p" 2>/dev/null || echo "$p" >> "$root/.gitignore"
    done
  fi
  mem="$root/CLAUDE.local.md"
  grep -q '<!-- team-skill -->' "$mem" 2>/dev/null || cat >> "$mem" <<'MD'

<!-- team-skill -->
## /team workspace
`.team/` (git-ignored) holds /team skill state: `.team/facts.md` = verified facts from past team runs (read before investigating this project; treat entries as leads to re-check, not ground truth), `.team/roles/` = reusable teammate roles, `.team/runs/` = past run records.
MD
  run="$d/runs/$(date +%Y-%m-%d)-$team"
  mkdir -p "$run/prompts" "$run/reports"
  echo "$run"
  exit 0
fi

if [ "$sub" = gate-init ]; then
  command -v no-mistakes >/dev/null || { echo "no-mistakes not installed; gate skipped"; exit 3; }
  git remote get-url origin >/dev/null 2>&1 || { echo "no origin remote; gate skipped"; exit 3; }
  git remote get-url no-mistakes >/dev/null 2>&1 && { echo "gate already set up"; exit 0; }
  no-mistakes init
  exit 0
fi

if [ "$sub" = clean ]; then
  team=${1:?team}
  root=$(git rev-parse --show-toplevel)
  for wt in "$root"/.team/worktrees/"$team"-*; do
    [ -d "$wt" ] || continue
    if git -C "$root" worktree remove "$wt" 2>/dev/null; then echo "removed $wt"
    else echo "kept $wt (uncommitted changes)"; fi
  done
  exit 0
fi

if [ "$sub" = close ]; then
  team=${1:?team}; reg="/tmp/team-$team.tabs"
  [ -f "$reg" ] || { echo "no tabs recorded for $team"; exit 0; }
  while read -r backend id _; do
    case $backend in
      cmux) cmux close-surface --surface "$id" >/dev/null 2>&1 || true ;;
      tmux) tmux kill-pane -t "$id" 2>/dev/null || true ;;
    esac
    echo "closed $backend $id"
  done < "$reg"
  rm -f "$reg"
  exit 0
fi

backend=auto layout=pane worktree= caveman=1
while :; do case ${1:-} in
  --tmux) backend=tmux; shift ;; --tabs) layout=tab; shift ;; --worktree) worktree=1; shift ;;
  --no-caveman) caveman=; shift ;; *) break ;;
esac; done
team=$1 role=$2 pfile=$3 model=${4:-}
reg="/tmp/team-$team.tabs"

dir=$PWD
if [ -n "$worktree" ]; then
  root=$(git rev-parse --show-toplevel)
  dir="$root/.team/worktrees/$team-$role"
  [ -d "$dir" ] || git -C "$root" worktree add -q -b "team/$team-$role" "$dir" HEAD
  echo "worktree $dir (branch team/$team-$role)"
fi
title="$team-$role"
cavefile="$HOME/.agents/skills/caveman/SKILL.md"
cmd="cd $(printf %q "$dir") && CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 claude -n $(printf %q "$title") --permission-mode $(printf %q "${TEAM_PERMISSION_MODE:-auto}")"
if [ -n "$caveman" ] && [ -f "$cavefile" ]; then cmd+=" --append-system-prompt-file $(printf %q "$cavefile")"; fi
[ -n "$model" ] && cmd+=" --model $(printf %q "$model")"
cmd+=" \"\$(cat $(printf %q "$pfile"))\""

if [ "$backend" = auto ] && [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null; then
  if [ "$layout" = pane ]; then
    last=$(awk '$3=="pane"{r=$2} END{print r}' "$reg" 2>/dev/null || true)
    if [ -n "$last" ]; then out=$(cmux new-split down --surface "$last" --command "$cmd" --focus false)
    else out=$(cmux new-split right --surface "$CMUX_SURFACE_ID" --command "$cmd" --focus false); fi
  else
    out=$(cmux new-surface --type terminal --workspace "$CMUX_WORKSPACE_ID" --command "$cmd" --focus false)
  fi
  ref=$(awk '{print $2}' <<<"$out")   # "OK surface:N ..."
  cmux rename-tab --surface "$ref" "$title" >/dev/null
  echo "cmux $ref $layout" >> "$reg"
  echo "cmux $layout $ref ($team-$role) in current workspace"
elif [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  id=$(tmux split-window -t "$TMUX_PANE" -d -P -F '#{pane_id}' "$cmd")
  tmux select-pane -t "$id" -T "$title"; tmux set -w -t "$id" pane-border-status top
  tmux select-layout -t "$TMUX_PANE" tiled >/dev/null
  echo "tmux $id" >> "$reg"
  echo "tmux pane $id ($team-$role) in current window"
else
  s="team-$team"
  if tmux has-session -t "=$s" 2>/dev/null; then
    id=$(tmux split-window -t "=$s" -d -P -F '#{pane_id}' "$cmd")
  else
    id=$(tmux new-session -d -s "$s" -x 240 -y 60 -P -F '#{pane_id}' "$cmd")
  fi
  tmux select-pane -t "$id" -T "$title"; tmux set -w -t "$id" pane-border-status top
  tmux select-layout -t "=$s" tiled >/dev/null
  echo "tmux $id" >> "$reg"
  echo "tmux pane $id ($team-$role) in session $s — attach: tmux attach -t $s"
fi
