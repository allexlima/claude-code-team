#!/usr/bin/env bash
# Run each teammate as an interactive `claude` session in its own tab/pane.
#   team.sh spawn [--tmux] [--tabs] [--worktree] [--no-caveman] <team> <role> <prompt-file> [model]
#   team.sh close <team>
#   team.sh init <team>   -> creates .team/ (idempotent) + a run dir; prints the run dir path
#   team.sh gate-init     -> sets up the no-mistakes gate for this repo (needs an "origin" remote)
#   team.sh clean <team>  -> removes the team's worktrees that have no uncommitted changes (branches kept)
#   team.sh park <team> <role>  -> fold an idle teammate's pane into a tab (keeps it running)
#   team.sh show <team> <role>  -> bring a parked teammate back into its own pane
#   team.sh list <team>         -> each teammate: working / parked / closed
#   team.sh models              -> models available here, best tier first
# --worktree: the teammate works in its own git worktree .team/worktrees/<team>-<role>
# on a new branch team/<team>-<role> (from the current HEAD), like a separate person.
# Each new worktree is pre-accepted in ~/.claude.json so the workspace-trust prompt
# does not appear in every pane (a worktree is its own git top-level, so it cannot inherit it).
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

# Available models. The option list is org-managed (managed-settings.json) and
# changes without notice, so read it at run time instead of hardcoding names.
# `behavesAs` is the capability tier a model is gated at, which is what decides
# whether it is a sensible fit for a role -- not the vendor name.
if [ "$sub" = models ]; then
  python3 - <<'PY'
import json, os, re
options = None
for path in ("/Library/Application Support/ClaudeCode/managed-settings.json",
             os.path.expanduser("~/.claude/settings.json")):
    try:
        with open(path, encoding="utf-8") as fh:
            picker = json.load(fh).get("modelPicker") or {}
    except Exception:
        continue
    if picker.get("options"):
        options = picker["options"]
        break

rows = []
if options:
    for o in options:
        mid = o.get("model") or ""
        if not mid:
            continue
        hit = re.search(r"opus|sonnet|haiku", o.get("behavesAs") or mid)
        rows.append((o.get("label") or mid, mid, hit.group(0) if hit else "?"))
else:
    # No managed picker: the built-in aliases are all that can be relied on.
    rows = [("Opus", "opus", "opus"), ("Sonnet", "sonnet", "sonnet"), ("Haiku", "haiku", "haiku")]

order = {"opus": 0, "sonnet": 1, "haiku": 2, "?": 3}
rows.sort(key=lambda r: order.get(r[2], 3))
wl = max(len(r[0]) for r in rows)
wm = max(len(r[1]) for r in rows)
for label, mid, tier in rows:
    print(f"{label.ljust(wl)}  {mid.ljust(wm)}  [{tier}]")
PY
  exit 0
fi

# Pane <-> tab lifecycle. A teammate's pane is the user's live audit view, so the
# grid should hold only teammates that are actually working. Parking moves the
# teammate's surface into the lead's pane, where it becomes a background tab: the
# claude process is never touched, so it stays alive, stays in ListAgents, and cmux
# can badge the tab if it needs input. `show` moves it back out into its own pane.
if [ "$sub" = park ] || [ "$sub" = show ] || [ "$sub" = list ]; then
  team=${1:?team}; reg="/tmp/team-$team.tabs"
  [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null || {
    echo "park/show/list need the cmux backend (tmux teammates stay in their panes)"; exit 3; }
  [ -f "$reg" ] || { echo "no teammates recorded for $team"; exit 3; }
  # identify still exits 0 for a surface that is gone, returning a null pane_ref,
  # so treat null/missing as "gone" rather than trusting the exit status.
  _pane_of() {  # pane ref holding surface $1, or "gone"
    cmux identify --surface "$1" 2>/dev/null \
      | python3 -c 'import json,sys; c=json.load(sys.stdin).get("caller") or {}; print(c.get("pane_ref") or "gone")' 2>/dev/null \
      || echo gone
  }
  leadpane=$(cmux identify 2>/dev/null \
    | python3 -c 'import json,sys; c=json.load(sys.stdin).get("caller") or {}; print(c.get("pane_ref") or "")' 2>/dev/null || echo "")
  [ -n "$leadpane" ] || { echo "could not resolve this session's pane — run park/show from the lead's pane"; exit 3; }

  if [ "$sub" = list ]; then
    while read -r b ref lay name; do
      [ -n "$ref" ] || continue
      if [ "$b" != cmux ]; then echo "${name:-?}  $b $ref"; continue; fi
      pp=$(_pane_of "$ref")
      case "$pp" in
        gone) st="closed" ;;
        "$leadpane") st="parked (tab, still running)" ;;
        *) st="working ($pp)" ;;
      esac
      echo "${name:-?}  $st"
    done < "$reg"
    exit 0
  fi

  role=${2:?role}; title="$team-$role"
  ref=$(awk -v t="$title" '$1=="cmux" && $4==t {r=$2} END{print r}' "$reg")
  [ -n "$ref" ] || { echo "no recorded pane for $title (spawned with --tabs, or not spawned)"; exit 3; }

  if [ "$sub" = park ]; then
    [ "$(_pane_of "$ref")" = "$leadpane" ] && { echo "$title already parked"; exit 0; }
    cmux move-surface --surface "$ref" --pane "$leadpane" --focus false >/dev/null
    echo "parked $title (now a tab in your pane; session still running)"
  else
    cur=$(_pane_of "$ref")
    [ "$cur" = gone ] && { echo "$title is gone; respawn it"; exit 3; }
    [ "$cur" != "$leadpane" ] && { echo "$title already showing ($cur)"; exit 0; }
    # Extend the teammate region rather than shrinking the lead: hang it off whoever
    # is already working, and only split the lead when no teammate is visible.
    anchor=""
    for r in $(awk '$1=="cmux"{print $2}' "$reg"); do
      pr=$(_pane_of "$r")
      [ "$pr" != "$leadpane" ] && [ "$pr" != gone ] && anchor="$r"
    done
    if [ -n "$anchor" ]; then ph=$(cmux new-split down --surface "$anchor" --focus false | awk '{print $2}')
    else ph=$(cmux new-split right --surface "$CMUX_SURFACE_ID" --focus false | awk '{print $2}'); fi
    cmux move-surface --surface "$ref" --pane "$(_pane_of "$ph")" --focus false >/dev/null
    cmux close-surface --surface "$ph" >/dev/null 2>&1 || true
    echo "showing $title"
  fi
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
  # A worktree is its own git top-level, so it never inherits the repo's workspace
  # trust and `claude` would raise the trust prompt in every pane. Pre-accept this
  # one path. Best-effort: a failure here only means the prompt comes back.
  TEAM_TRUST_DIR="$dir" python3 - <<'PY' || echo "warn: could not pre-trust $dir; expect a trust prompt" >&2
import json, os, sys
p = os.path.expanduser("~/.claude.json")
d = os.path.abspath(os.environ["TEAM_TRUST_DIR"])
with open(p, encoding="utf-8") as f:
    cfg = json.load(f)
projects = cfg.setdefault("projects", {})
if projects.setdefault(d, {}).get("hasTrustDialogAccepted") is True:
    sys.exit(0)
projects[d]["hasTrustDialogAccepted"] = True
tmp = f"{p}.team-{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(json.dumps(cfg, indent=2, ensure_ascii=False))
os.replace(tmp, p)
PY
fi
title="$team-$role"
cavefile="$HOME/.agents/skills/caveman/SKILL.md"
cmd="cd $(printf %q "$dir") && CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 claude -n $(printf %q "$title") --permission-mode $(printf %q "${TEAM_PERMISSION_MODE:-auto}")"
if [ -n "$caveman" ] && [ -f "$cavefile" ]; then cmd+=" --append-system-prompt-file $(printf %q "$cavefile")"; fi
[ -n "$model" ] && cmd+=" --model $(printf %q "$model")"
cmd+=" \"\$(cat $(printf %q "$pfile"))\""

if [ "$backend" = auto ] && [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null; then
  if [ "$layout" = pane ]; then
    # Two-column grid in the region right of the lead: #1 opens it, #2 sits beside
    # #1, and every later teammate splits down from the one two slots back. A 1-wide
    # stack gave each teammate 1/N of the screen height, which got unreadable fast.
    n=$(awk '$3=="pane"{c++} END{print c+0}' "$reg" 2>/dev/null || echo 0)
    if [ "$n" -eq 0 ]; then
      out=$(cmux new-split right --surface "$CMUX_SURFACE_ID" --command "$cmd" --focus false)
    elif [ "$n" -eq 1 ]; then
      out=$(cmux new-split right --surface "$(awk '$3=="pane"{print $2; exit}' "$reg")" --command "$cmd" --focus false)
    else
      out=$(cmux new-split down --surface "$(awk '$3=="pane"{print $2}' "$reg" | sed -n "$((n-1))p")" --command "$cmd" --focus false)
    fi
  else
    out=$(cmux new-surface --type terminal --workspace "$CMUX_WORKSPACE_ID" --command "$cmd" --focus false)
  fi
  ref=$(awk '{print $2}' <<<"$out")   # "OK surface:N ..."
  cmux rename-tab --surface "$ref" "$title" >/dev/null
  echo "cmux $ref $layout $title" >> "$reg"
  echo "cmux $layout $ref ($team-$role) in current workspace"
elif [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  id=$(tmux split-window -t "$TMUX_PANE" -d -P -F '#{pane_id}' "$cmd")
  tmux select-pane -t "$id" -T "$title"; tmux set -w -t "$id" pane-border-status top
  tmux select-layout -t "$TMUX_PANE" tiled >/dev/null
  echo "tmux $id pane $title" >> "$reg"
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
  echo "tmux $id pane $title" >> "$reg"
  echo "tmux pane $id ($team-$role) in session $s — attach: tmux attach -t $s"
fi
