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
# _st_row <row> <run> <leadpane> <team>: render one registry row as a table line
# ---------------------------------------------------------------------------
_st_row() {
  local row="$1" run="$2" leadpane="$3" team="$4"

  local backend ref lay title mdl submdl rundir
  backend=$(awk '{print $1}' <<<"$row")
  ref=$(awk '{print $2}' <<<"$row")
  lay=$(awk '{print $3}' <<<"$row")
  title=$(awk '{print $4}' <<<"$row")
  mdl=$(awk '{print $5}' <<<"$row")
  submdl=$(awk 'NF>=6{print $6}' <<<"$row")
  rundir=$(awk 'NF>=7{print $7}' <<<"$row")

  # Fix 2: strip exact team prefix to handle team slugs with hyphens
  local role="${title#"$team"-}"

  # Registry col 7 (rundir) wins over the caller-supplied run fallback
  local effective_run="$run"
  if [ -n "$rundir" ] && [ "$rundir" != "-" ] && [ -d "$rundir" ]; then
    effective_run="$rundir"
  fi

  local rpt= stf=
  if [ -n "$effective_run" ]; then
    rpt="$effective_run/reports/$role.md"
    stf="$effective_run/status/$role.txt"
    # Fix 9: some teammates may use <team>-<role>.txt; accept both
    if [ ! -f "$stf" ] && [ -f "$effective_run/status/$title.txt" ]; then
      stf="$effective_run/status/$title.txt"
    fi
  fi

  # ------ MILESTONE -------------------------------------------------------
  local ms=spawned
  if [ -n "$rpt" ] && [ -f "$rpt" ]; then
    ms=reported
  elif [ -n "$stf" ] && [ -f "$stf" ]; then
    ms=investigating
    grep -qi 'draft' "$stf" 2>/dev/null && ms=drafting
  fi
  # Fix 3: tasks.md tick means "reported" (not "challenged"); use exact match
  if [ "$ms" != reported ] && [ -n "$effective_run" ] && [ -f "$effective_run/tasks.md" ]; then
    grep -qF -- "- [x] $title:" "$effective_run/tasks.md" 2>/dev/null && ms=reported
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

  # MODEL_GONE (N3): check main model col and subagent model col
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
          # Fix 1: match actual CLI 2.1.294 modal text
          printf '%s\n' "$screen" \
            | grep -qiE 'Do you want to proceed|Yes, I trust this folder|Do you want to (make|create)' \
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

# _st_table <reg> <run> <leadpane> <team>: header + one row per non-dash teammate
_st_table() {
  local reg="$1" run="$2" leadpane="$3" team="$4"

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
    _st_row "$row" "$run" "$leadpane" "$team"
  done <<<"$deduped"
}

# ---------------------------------------------------------------------------
# sub_status [--watch] <team>
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
      _st_table "$reg" "$run" "$leadpane" "$team"
      sleep "${TEAM_STATUS_INTERVAL:-30}"
    done
  else
    _st_table "$reg" "$run" "$leadpane" "$team"
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
  # Fix 6: validate interval is a positive integer
  local interval=${TEAM_STATUS_INTERVAL:-30}
  case ${interval:-} in *[!0-9]*|'') interval=30 ;; esac
  local title="$team-monitor"

  # Fix 4: single-instance guard — refuse only when the existing pane is LIVE.
  # If the row exists but the surface is dead (manually closed), prune and proceed.
  if [ -f "$reg" ]; then
    local ex_row
    ex_row=$(awk -v t="$title" '$4==t && $3=="dash"{print $0; exit}' "$reg" 2>/dev/null || true)
    if [ -n "$ex_row" ]; then
      local ex_backend ex_ref
      ex_backend=$(awk '{print $1}' <<<"$ex_row")
      ex_ref=$(awk '{print $2}' <<<"$ex_row")
      if _alive "$ex_backend" "$ex_ref" 2>/dev/null; then
        printf 'monitor: dashboard %q already running for team %q\n' "$title" "$team" >&2
        printf '  Stop it first: team.sh close %q\n' "$team" >&2
        return 1
      else
        # Dead row: prune it and allow a fresh spawn
        local tmp; tmp=$(mktemp)
        awk -v t="$title" '!($4==t && $3=="dash")' "$reg" > "$tmp" && mv "$tmp" "$reg" || true
      fi
    fi
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
    # Fix 5: use new-split down (pane) instead of new-surface (tab); fall back
    # to new-surface if CMUX_SURFACE_ID is not set.
    if [ -n "${CMUX_SURFACE_ID:-}" ]; then
      out=$(cmux new-split down --surface "$CMUX_SURFACE_ID" \
            --command "$cmd" --focus false)
    else
      out=$(cmux new-surface --type terminal --workspace "$CMUX_WORKSPACE_ID" \
            --command "$cmd" --focus false)
    fi
    ref=$(awk '{print $2}' <<<"$out")
    cmux rename-tab --surface "$ref" "$title" >/dev/null
    # Register: backend ref layout title model submodel rundir (all 7 cols)
    printf 'cmux %s dash %s - - -\n' "$ref" "$title" >> "$reg"
    printf 'monitor pane: %s\n' "$title"
  elif [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    local id
    id=$(tmux split-window -t "$TMUX_PANE" -d -P -F '#{pane_id}' "$cmd")
    tmux select-pane -t "$id" -T "$title"
    printf 'tmux %s dash %s - - -\n' "$id" "$title" >> "$reg"
    printf 'monitor pane: %s in tmux\n' "$title"
  else
    # No cmux/tmux backend: print the command for the user to run manually
    printf 'monitor: no cmux or tmux backend — run this to watch the team:\n'
    printf '  %s\n' "$cmd"
    return 0
  fi
}
