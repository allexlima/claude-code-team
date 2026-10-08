#!/usr/bin/env bash
# lib/status.sh — sub_status and sub_monitor functions for team.sh
# Sourced by team.sh after helpers are defined (set -euo pipefail is already on).
# Functions only; no top-level side effects.
#
# Requires team.sh globals/functions (bound before sourcing):
#   $here              absolute dir of team.sh
#   _root              prints main checkout root (main worktree)
#   _team_models       emits label<TAB>id<TAB>tier TSV
#   _reg <team>        prints /tmp/team-<team>.tabs
#   _pane_of <ref>     prints cmux pane_ref or "gone" (cmux only)
#   _lead_pane         prints "<pane_ref> <surface_ref>" of caller's session
#   _model_tier <m>    prints opus|sonnet|haiku or empty
#   _model_gone <m>    returns 0 if model not in org picker (fallback defined below)
#   _alive <b> <r>     returns 0 if surface/pane exists (fallback defined below)
#
# Registry row format (team.sh):
#   backend ref layout title model submodel rundir
#   col 3 layout ∈ pane|tab|dash  (dash = monitor row, excluded from status table)
#   col 6 CLAUDE_CODE_SUBAGENT_MODEL id or "-" (absent on old rows → "")
#   col 7 absolute run dir or "-" (absent on old rows → "")

# ---------------------------------------------------------------------------
# Fallbacks for helpers that team.sh may not yet define
# ---------------------------------------------------------------------------

# _model_gone <model>: returns 0 if model is gone from the org picker.
# Safe under pipefail: _team_models failure → treat as "not gone" (can't verify).
if ! declare -f _model_gone >/dev/null 2>&1; then
  _model_gone() {
    local m="$1"
    case "$m" in ''|-|opus|sonnet|haiku) return 1 ;; esac
    local ids
    ids=$(_team_models 2>/dev/null | awk -F'\t' '{print $2}') || return 1
    printf '%s\n' "$ids" | grep -qxF "$m" || return 0
    return 1
  }
fi

# _alive <backend> <ref>: returns 0 if surface/pane still exists.
if ! declare -f _alive >/dev/null 2>&1; then
  _alive() {
    local b="$1" r="$2"
    case "$b" in
      cmux) command -v cmux >/dev/null \
              && [ "$(_pane_of "$r" 2>/dev/null || echo gone)" != gone ] ;;
      tmux) tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$r" ;;
      *)    return 0 ;;
    esac
  }
fi

# ---------------------------------------------------------------------------
# _st_row <row> <run> <leadpane>: render one registry row as a table line
# ---------------------------------------------------------------------------
_st_row() {
  local row="$1" run="$2" leadpane="$3"

  local backend ref lay title mdl submdl rundir
  backend=$(awk '{print $1}' <<<"$row")
  ref=$(awk '{print $2}' <<<"$row")
  lay=$(awk '{print $3}' <<<"$row")
  title=$(awk '{print $4}' <<<"$row")
  mdl=$(awk '{print $5}' <<<"$row")
  submdl=$(awk 'NF>=6{print $6}' <<<"$row")
  rundir=$(awk 'NF>=7{print $7}' <<<"$row")

  local role="${title#*-}"

  # Registry col 7 (rundir) wins over the caller-supplied run fallback
  local effective_run="$run"
  if [ -n "$rundir" ] && [ "$rundir" != "-" ] && [ -d "$rundir" ]; then
    effective_run="$rundir"
  fi

  local rpt= stf=
  if [ -n "$effective_run" ]; then
    rpt="$effective_run/reports/$role.md"
    stf="$effective_run/status/$role.txt"
  fi

  # ------ MILESTONE -------------------------------------------------------
  local ms=spawned
  if [ -n "$rpt" ] && [ -f "$rpt" ]; then
    ms=reported
  elif [ -n "$stf" ] && [ -f "$stf" ]; then
    ms=investigating
    grep -qi 'draft' "$stf" 2>/dev/null && ms=drafting
  fi
  if [ -n "$effective_run" ] && [ -f "$effective_run/tasks.md" ]; then
    grep -q "\[x\].*$role" "$effective_run/tasks.md" 2>/dev/null && ms=challenged
  fi

  # ------ STEP (last line of status file, max 40 chars) -------------------
  local step='—'
  if [ -n "$stf" ] && [ -f "$stf" ]; then
    local raw; raw=$(tail -1 "$stf" 2>/dev/null | cut -c1-40) || true
    step="${raw:-—}"
  fi

  # ------ LAST_ACTIVITY (age of newest {report, status} mtime) ------------
  local newest=0 la='—' age=0
  local f t
  for f in "$rpt" "$stf"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    t=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || continue
    [ "$t" -gt "$newest" ] && newest=$t
  done
  if [ "$newest" -gt 0 ]; then
    local now; now=$(date +%s)
    age=$(( (now - newest) / 60 ))
    la="${age}m ago"
  fi

  # ------ FLAGS -----------------------------------------------------------
  local flags=''

  # STALLED?: derived signals only; fires during mid-work milestones, silent >10m
  case $ms in
    spawned|investigating|drafting)
      [ "$newest" -gt 0 ] && [ "$age" -ge 10 ] && flags="${flags}STALLED? " ;;
  esac

  # MODEL GONE (N3): check main model col and subagent model col
  local m
  for m in "$mdl" "$submdl"; do
    [ -z "$m" ] || [ "$m" = "-" ] && continue
    _model_gone "$m" 2>/dev/null && { flags="${flags}MODEL_GONE "; break; }
  done

  # DEAD / PARKED / PROMPT
  if [ "$backend" = cmux ] && command -v cmux >/dev/null; then
    if ! _alive cmux "$ref" 2>/dev/null; then
      flags="${flags}DEAD "
    elif [ -n "$leadpane" ]; then
      local pp; pp=$(_pane_of "$ref" 2>/dev/null || echo gone)
      if [ "$pp" = gone ]; then
        flags="${flags}DEAD "
      elif [ "$pp" = "$leadpane" ]; then
        flags="${flags}PARKED "
        # Skip PROMPT for parked surfaces: background-tab cmux read-screen
        # is unverified; skip to avoid false positives.
      else
        # PROMPT: skip haiku-tier (dontAsk mode, no human approval needed)
        local skip_prompt=
        case "${mdl:-}" in *haiku*|*glm*|*kimi*) skip_prompt=1 ;; esac
        if [ -z "$skip_prompt" ] && declare -f _model_tier >/dev/null 2>&1; then
          local tier; tier=$(_model_tier "${mdl:-}" 2>/dev/null || true)
          [ "$tier" = haiku ] && skip_prompt=1
        fi
        if [ -z "$skip_prompt" ]; then
          local screen
          screen=$(cmux read-screen --surface "$ref" --lines 10 2>/dev/null || true)
          printf '%s\n' "$screen" \
            | grep -qiE 'Allow tool:|Trust this folder' \
            && flags="${flags}PROMPT "
        fi
      fi
    fi
  elif [ "$backend" = tmux ]; then
    _alive tmux "$ref" 2>/dev/null || flags="${flags}DEAD "
  fi

  printf '%-18s %-14s %-42s %-14s %s\n' \
    "$role" "$ms" "$step" "$la" "${flags:----}"
}

# _st_table <reg> <run> <leadpane>: print header + one row per non-dash teammate
_st_table() {
  local reg="$1" run="$2" leadpane="$3"

  printf '%-18s %-14s %-42s %-14s %s\n' ROLE MILESTONE STEP LAST_ACTIVITY FLAGS

  # Deduplicate by title (last row wins, first-appearance order, dash excluded)
  local deduped
  deduped=$(awk '
    $3 == "dash" { next }
    {
      rows[$4] = $0
      if (!seen[$4]++) { order[++n] = $4 }
    }
    END { for (i = 1; i <= n; i++) print rows[order[i]] }
  ' "$reg" 2>/dev/null || true)

  while IFS= read -r row; do
    [ -z "$row" ] && continue
    _st_row "$row" "$run" "$leadpane"
  done <<<"$deduped"
}

# ---------------------------------------------------------------------------
# sub_status <team> [--watch goes before team] — called as: sub_status "$@"
# Actually: team.sh dispatch does: sub_status "$@" where $@ is remaining args
# Usage: status [--watch] <team>
# Exit: 0 ok, 3 no registry
# ---------------------------------------------------------------------------

sub_status() {
  local watch=
  [ "${1:-}" = --watch ] && { watch=1; shift; }
  local team=${1:?team}
  local reg; reg=$(_reg "$team")
  [ -f "$reg" ] || { printf 'no teammates recorded for %s\n' "$team" >&2; return 3; }

  local root; root=$(_root)

  # Resolve fallback run dir (for old registry rows without col 7)
  local run
  run=$(ls -dt "$root/.team/runs/"*"-$team" 2>/dev/null | head -1 || true)

  # Resolve lead's pane_ref for PARKED detection (cmux only, once per call)
  local leadpane=
  if command -v cmux >/dev/null && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    local lp; lp=$(_lead_pane 2>/dev/null || true)
    leadpane="${lp%% *}"
  fi

  if [ -n "$watch" ]; then
    # N9: $(date ...) is in the loop body — evaluated each iteration, not frozen.
    while true; do
      clear
      printf 'team %s — %s\n' "$team" "$(date '+%H:%M:%S')"
      _st_table "$reg" "$run" "$leadpane"
      sleep "${TEAM_STATUS_INTERVAL:-30}"
    done
  else
    _st_table "$reg" "$run" "$leadpane"
  fi
}

# ---------------------------------------------------------------------------
# sub_monitor <team>
# Opens one auto-refreshing status pane with layout=dash (not a teammate).
# Exit: 0 ok (incl. no-backend print), 1 already-running
# ---------------------------------------------------------------------------

sub_monitor() {
  local team=${1:?team}
  local reg; reg=$(_reg "$team")
  local interval=${TEAM_STATUS_INTERVAL:-30}
  local title="$team-monitor"

  # Single-instance guard (N11): refuse if a dash row with this title already exists
  if [ -f "$reg" ] \
      && awk -v t="$title" '$4==t && $3=="dash"{f=1} END{exit !f}' "$reg" 2>/dev/null; then
    printf 'monitor: dashboard %q already registered for team %q\n' "$title" "$team" >&2
    printf '  Reopen: team.sh close %q first.\n' "$team" >&2
    return 1
  fi

  # Build the loop command string.
  # N9: \$(date ...) leaves a literal $(date ...) in cmd; the executing shell
  #     evaluates it each loop iteration (not at assignment time).
  # N11: while [ -f <reg> ] exits automatically when the team is closed
  #      (close removes the registry), leaving no orphan process.
  local reg_q; reg_q=$(printf '%q' "$reg")
  local team_q; team_q=$(printf '%q' "$team")
  local script_q; script_q=$(printf '%q' "$here/team.sh")
  # shellcheck disable=SC2016  # intentional: \$() must not expand at assignment
  local cmd="while [ -f $reg_q ]; do clear; printf 'team %s -- %s\\n' $team_q \"\$(date '+%H:%M:%S')\"; bash $script_q status $team_q; sleep $interval; done"

  if [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null; then
    local out ref
    out=$(cmux new-surface --type terminal --workspace "$CMUX_WORKSPACE_ID" \
          --command "$cmd" --focus false)
    ref=$(awk '{print $2}' <<<"$out")
    cmux rename-tab --surface "$ref" "$title" >/dev/null
    # Register with dash layout; model cols are placeholders (–)
    printf 'cmux %s dash %s - -\n' "$ref" "$title" >> "$reg"
    printf 'monitor pane: %s\n' "$title"
  elif [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    local id
    id=$(tmux split-window -t "$TMUX_PANE" -d -P -F '#{pane_id}' "$cmd")
    tmux select-pane -t "$id" -T "$title"
    printf 'tmux %s dash %s - -\n' "$id" "$title" >> "$reg"
    printf 'monitor pane: %s in tmux\n' "$title"
  else
    # No cmux/tmux backend: print the command for the user to run manually
    printf 'monitor: no cmux or tmux backend — run this to watch the team:\n'
    printf '  %s\n' "$cmd"
    return 0
  fi
}
