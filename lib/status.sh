#!/usr/bin/env bash
# lib/status.sh — sub_status, sub_monitor, sub_sync functions for team.sh
# Sourced by team.sh after helpers are defined (set -euo pipefail is already on).
# Functions only; no top-level side effects.
#
# Requires team.sh globals/functions (bound before sourcing):
#   $here              absolute dir of team.sh
#   _root              prints main checkout root (main worktree)
#   _reg <team>        prints /tmp/team-<team>.tabs
#   _reg_add <team> <ref> <layout> <title> <model|-> <submodel|-> <rundir|->
#                      appends a registry row (root col appended automatically)
#   _pane_of <ref>     prints cmux pane_ref or "gone" (cmux only)
#   _lead_pane         prints "<pane_ref> <surface_ref>" of caller's session
#   _model_tier <m>    prints opus|sonnet|haiku or empty
#   _model_gone <m>    returns 0 if model not in org picker (fallback defined below)
#   _alive <b> <r>     returns 0 if surface/pane exists (fallback defined below)
#   _require_cmux [ws] exits 3 if cmux absent/unhealthy; ws also checks CMUX_*IDs
#   _lock <file>       acquire lock; EXIT trap set for cleanup
#
# Registry row format (team.sh, 8 cols):
#   backend ref layout title model submodel rundir root
#   col 3 layout ∈ pane|tab|dash  (dash = monitor row, excluded from status table)
#   col 6 CLAUDE_CODE_SUBAGENT_MODEL id or "-" (absent on old rows → "")
#   col 7 absolute run dir or "-" (absent on old rows → "")
#   col 8 project root or "-" (absent on old rows → "")
#
# Module-level state (reset by each _st_table call):
#   _ST_UUID_MAP   "surface:N=UUID\n…" built from cmux list-panes (one python3 call)
#   _ST_NOTIF_DATA "UUID|title|subtitle\n…" from cmux list-notifications --json
#
# FLAGS column note — WAITING covers AskUserQuestion only (title="Claude question").
# Tool-approval permission prompts go to `cmux hooks feed`, NOT list-notifications,
# so a teammate blocked on a permission prompt shows no WAITING flag; STALLED? fires
# after 10 min of filesystem silence. This is a known gap (probed by rev4-tests).

_ST_UUID_MAP=
_ST_NOTIF_DATA=

# Shared palette (decision 16): the sidebar pill and the monitor pane use the same
# four roles. None is "#4C8DFF" — `cmux set-status --help` documents that hex as the
# cmux accent, which the claude shim's own claude_code pill already uses.
_ST_C_ALERT='#FF453A'   # needs you / dead
_ST_C_ACTIVE='#AF52DE'  # working
_ST_C_DONE='#30D158'    # reported / finished
_ST_C_DIM='#8E8E93'     # unknown / neutral
# Sidebar sort priority; higher appears first. The shim's claude_code pill is 0.
_ST_PILL_PRIORITY=50

# ---------------------------------------------------------------------------
# Fallback helpers — activate only when team.sh hasn't defined them
# ---------------------------------------------------------------------------

if ! declare -f _model_gone >/dev/null 2>&1; then
  _model_gone() {
    declare -f _team_models >/dev/null 2>&1 || return 1
    local m="$1"
    _team_models 2>/dev/null | awk -v m="$m" '
      $2==m || $1==m { found=1 }
      END { exit (found ? 1 : 0) }
    '
  }
fi

if ! declare -f _alive >/dev/null 2>&1; then
  _alive() {
    local backend="$1" ref="$2"
    case $backend in
      cmux)
        command -v cmux >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 0
        local out
        out=$(cmux identify --surface "$ref" 2>&1) \
          || { case $out in *not_found*) return 1 ;; esac; return 0; }
        ;;
      *) return 0 ;;  # non-cmux: assume alive (conservative)
    esac
  }
fi

if ! declare -f _require_cmux >/dev/null 2>&1; then
  _require_cmux() {
    command -v cmux >/dev/null 2>&1 \
      || { printf 'team.sh: cmux not found — install from https://cmux.app\n' >&2; return 3; }
    cmux ping >/dev/null 2>&1 \
      || { printf 'team.sh: cmux not responding (cmux ping failed)\n' >&2; return 3; }
    if [ "${1:-}" = ws ]; then
      [ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -n "${CMUX_SURFACE_ID:-}" ] \
        || { printf 'team.sh: must run inside a cmux pane\n' >&2; return 3; }
    fi
  }
fi

if ! declare -f _reg_add >/dev/null 2>&1; then
  _reg_add() {
    local team="$1" ref="$2" lay="$3" title="$4" mdl="${5:--}" smdl="${6:--}" rdir="${7:--}"
    local root; root=$(_root 2>/dev/null || pwd)
    printf 'cmux %s %s %s %s %s %s %s\n' \
      "$ref" "$lay" "$title" "$mdl" "$smdl" "$rdir" "$root" \
      >> "$(_reg "$team")"
  }
fi

# ---------------------------------------------------------------------------
# _st_row <row> <run> <leadpane> <team>: render one registry row as a table line
# Reads module globals: _ST_UUID_MAP, _ST_NOTIF_DATA
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

  # Strip exact team prefix to handle team slugs with hyphens
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
    # Some teammates may use <team>-<role>.txt; accept both
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
  if [ "$ms" != reported ] && [ -n "$effective_run" ] && [ -f "$effective_run/tasks.md" ]; then
    grep -qF -- "- [x] $title:" "$effective_run/tasks.md" 2>/dev/null && ms=reported
  fi

  # ------ STEP (last line of status file, max 40 chars) -------------------
  local step='-'
  if [ -n "$stf" ] && [ -f "$stf" ]; then
    local raw; raw=$(tail -1 "$stf" 2>/dev/null | cut -c1-40) || true
    step="${raw:--}"
  fi

  # ------ LAST_ACTIVITY (age of newest {report, status} mtime) ------------
  local newest=0 la='-' age=0
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

  # DEAD / PARKED / WAITING (cmux only)
  if [ "$backend" = cmux ] && command -v cmux >/dev/null; then
    if ! _alive cmux "$ref" 2>/dev/null; then
      flags="${flags}DEAD "
    else
      local pp; pp=$(_pane_of "$ref" 2>/dev/null || echo gone)
      if [ "$pp" = gone ]; then
        flags="${flags}DEAD "
      else
        # PARKED: pane_ref matches lead (only when lead context available)
        if [ -n "$leadpane" ] && [ "$pp" = "$leadpane" ]; then
          flags="${flags}PARKED "
        fi

        # WAITING / DONE: derive from newest cmux notification for this surface.
        # Skip WAITING for haiku/dontAsk tier (no human approval needed).
        # Probed by rev4-tests (CLI 2.1.294):
        #   AskUserQuestion  → title="Claude question", subtitle=""
        #   Completion/Stop  → title="Claude Code",     subtitle="Completed in <session>"
        #   PermissionRequest → NOT in list-notifications (uses cmux hooks feed).
        #     Permission prompts cannot be detected via notifications; tool-approval
        #     prompts are handled only through the process exit path (DEAD flag).
        local skip_waiting=
        case "${mdl:-}" in *haiku*|*glm*|*kimi*) skip_waiting=1 ;; esac
        if [ -z "$skip_waiting" ] && declare -f _model_tier >/dev/null 2>&1; then
          local tier; tier=$(_model_tier "${mdl:-}" 2>/dev/null || true)
          [ "$tier" = haiku ] && skip_waiting=1
        fi
        if [ -n "$_ST_UUID_MAP" ] && [ -n "$_ST_NOTIF_DATA" ]; then
          local uuid
          uuid=$(awk -F'=' -v r="$ref" '$1==r {print $2; exit}' <<<"$_ST_UUID_MAP" 2>/dev/null || true)
          if [ -n "$uuid" ]; then
            local notif_line notif_title notif_subtitle
            notif_line=$(awk -F'|' -v u="$uuid" '$1==u {print; exit}' \
                         <<<"$_ST_NOTIF_DATA" 2>/dev/null || true)
            if [ -n "$notif_line" ]; then
              notif_title=$(awk -F'|' '{print $2}' <<<"$notif_line")
              notif_subtitle=$(awk -F'|' '{print $3}' <<<"$notif_line")
              # WAITING (AskUserQuestion only; permission prompts not in notifications)
              if [ -z "$skip_waiting" ]; then
                printf '%s\n' "$notif_title" | grep -qi 'claude question' \
                  && flags="${flags}WAITING "
              fi
              # DONE: session completed its last turn but report not yet on disk
              if [ "$ms" != reported ]; then
                printf '%s\n' "$notif_subtitle" | grep -qi '^completed in ' \
                  && flags="${flags}DONE "
              fi
            fi
          fi
        fi
      fi
    fi
  fi

  printf '%-18s %-14s %-42s %-14s %s\n' \
    "$role" "$ms" "$step" "$la" "${flags:----}"
}

# _st_table <reg> <run> <leadpane> <team>: header + one row per non-dash teammate
_st_table() {
  local reg="$1" run="$2" leadpane="$3" team="$4"

  printf '%-18s %-14s %-42s %-14s %s\n' ROLE MILESTONE STEP LAST_ACTIVITY FLAGS

  # Build surface ref → UUID map (single python3 call).
  # list-panes --json has surface_refs[] + surface_ids[] in parallel arrays.
  _ST_UUID_MAP=
  if command -v cmux >/dev/null && command -v python3 >/dev/null \
      && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    _ST_UUID_MAP=$(python3 -c "
import json, subprocess, os, sys
ws = os.environ.get('CMUX_WORKSPACE_ID', '')
if not ws:
    sys.exit(0)
try:
    r = subprocess.run(['cmux', 'list-panes', '--workspace', ws, '--json'],
                      capture_output=True, text=True, timeout=5)
    data = json.loads(r.stdout)
    for pane in data.get('panes', []):
        for ref, uid in zip(pane.get('surface_refs', []),
                            pane.get('surface_ids', [])):
            print(ref + '=' + uid)
except Exception:
    pass
" 2>/dev/null || true)
  fi

  # Build team UUID set from registry refs (used to filter notification data).
  local _st_team_uuids=""
  if [ -n "$_ST_UUID_MAP" ]; then
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      local _lay _ref _uid
      _lay=$(awk '{print $3}' <<<"$row")
      [ "$_lay" = dash ] && continue
      _ref=$(awk '{print $2}' <<<"$row")
      _uid=$(awk -F'=' -v r="$_ref" '$1==r {print $2; exit}' <<<"$_ST_UUID_MAP" 2>/dev/null || true)
      [ -n "$_uid" ] && _st_team_uuids="$_st_team_uuids $_uid"
    done < "$reg"
    _st_team_uuids="${_st_team_uuids# }"
  fi

  # Fetch notifications for WAITING state detection.
  # Privacy: filter to team surface UUIDs only; never emit body.
  # Stale-state: keep NEWEST notification per surface (by created_at), regardless
  # of read state, so a stale "waiting" cleared by a newer "Completed" won't fire.
  _ST_NOTIF_DATA=
  if command -v cmux >/dev/null && command -v python3 >/dev/null; then
    _ST_NOTIF_DATA=$(export _ST_TEAM_UUIDS="$_st_team_uuids"; python3 -c "
import json, subprocess, sys, os
team_uuids = set(os.environ.get('_ST_TEAM_UUIDS', '').split())
try:
    r = subprocess.run(['cmux', 'list-notifications', '--json'],
                      capture_output=True, text=True, timeout=5)
    newest = {}  # surface_id -> newest notification dict
    for n in json.loads(r.stdout):
        sid = n.get('surface_id', '')
        if not sid:
            continue
        if team_uuids and sid not in team_uuids:
            continue  # filter to team surfaces only
        ts = n.get('created_at', '')
        if sid not in newest or ts > newest[sid].get('created_at', ''):
            newest[sid] = n
    for sid, n in newest.items():
        # Replace | in title/subtitle to keep pipe-split safe; never emit body
        title = n.get('title', '').replace('|', ' ')
        subtitle = n.get('subtitle', '').replace('|', ' ')
        print(sid + '|' + title + '|' + subtitle)
except Exception:
    pass
" 2>/dev/null || true)
  fi

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

  # Resolve lead's pane_ref for PARKED detection.
  # When running inside the monitor loop, sub_monitor pre-sets TEAM_LEAD_PANE so
  # _lead_pane (which identifies the calling pane) returns the monitor's own pane
  # rather than the lead's pane — making PARKED detection wrong.
  local leadpane=
  if command -v cmux >/dev/null && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    if [ -n "${TEAM_LEAD_PANE:-}" ]; then
      leadpane="$TEAM_LEAD_PANE"
    else
      local lp; lp=$(_lead_pane 2>/dev/null || true)
      leadpane="${lp%% *}"
    fi
  fi

  if [ -n "$watch" ]; then
    # \$(date ...) is in the loop body — evaluated each iteration, not frozen.
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
# Requires cmux with workspace context (_require_cmux ws).
# Exit: 0 ok, 1 already-running, 3 cmux unavailable
# ---------------------------------------------------------------------------

sub_monitor() {
  local team=${1:?team}

  # cmux with workspace context is a hard requirement (decision 1)
  _require_cmux ws

  local reg; reg=$(_reg "$team")
  local interval=${TEAM_STATUS_INTERVAL:-30}
  case ${interval:-} in *[!0-9]*|'') interval=30 ;; esac
  local title="$team-monitor"

  # Capture lead's pane_ref NOW (running as the lead).
  # Baked into the status loop so PARKED detection is correct inside the
  # monitor pane (where _lead_pane would otherwise resolve to the monitor itself).
  local lead_pane=
  local lp; lp=$(_lead_pane 2>/dev/null || true)
  lead_pane="${lp%% *}"
  local lead_pane_q; lead_pane_q=$(printf '%q' "$lead_pane")

  # Acquire registry lock: makes single-instance check + append atomic vs spawn.
  # _lock sets an EXIT trap for cleanup; do NOT set another EXIT trap after this.
  _lock "$reg"

  # Single-instance guard: refuse if a live dash row with this title exists.
  # Dead rows (pane manually closed) are pruned so a fresh monitor can open.
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
        # Dead row: prune in-place
        local prunetmp="$reg.pruning-$$"
        awk -v t="$title" '!($4==t && $3=="dash")' "$reg" > "$prunetmp" \
          && mv "$prunetmp" "$reg" || rm -f "$prunetmp"
      fi
    fi
  fi

  # Build the loop command string.
  # \$(date ...) leaves a literal $(date ...) so the executing shell evaluates
  # it each loop iteration. while [ -f <reg> ] exits when close removes the
  # registry (no orphan process). TEAM_LEAD_PANE is baked in for correct
  # PARKED detection inside the monitor pane.
  local reg_q; reg_q=$(printf '%q' "$reg")
  local team_q; team_q=$(printf '%q' "$team")
  local script_q; script_q=$(printf '%q' "$here/team.sh")
  # shellcheck disable=SC2016  # intentional: \$() must not expand at assignment
  local cmd="while [ -f $reg_q ]; do clear; printf 'team %s -- %s\\n' $team_q \"\$(date '+%H:%M:%S')\"; TEAM_LEAD_PANE=$lead_pane_q bash $script_q status $team_q; bash $script_q sync $team_q 2>/dev/null || true; sleep $interval; done"

  local out ref
  out=$(cmux new-split down --surface "$CMUX_SURFACE_ID" \
        --command "$cmd" --focus false)
  ref=$(awk '{print $2}' <<<"$out")
  cmux rename-tab --surface "$ref" "$title" >/dev/null
  _reg_add "$team" "$ref" dash "$title" - - -
  printf 'monitor pane: %s\n' "$title"
}

# ---------------------------------------------------------------------------
# sub_sync [--clear] <team>
# Update the lead workspace sidebar: status pill (team-<team>) + progress bar.
# --clear: remove the pill and progress bar (called when the team closes).
# Exit: always 0 (cmux errors warn only; use return, never exit).
# ---------------------------------------------------------------------------

sub_sync() {
  local clear=
  case "${1:-}" in --clear) clear=1; shift ;; esac
  local team=${1:?team}

  command -v cmux >/dev/null 2>&1 || return 0
  [ -n "${CMUX_WORKSPACE_ID:-}" ] || return 0

  local ws="$CMUX_WORKSPACE_ID"
  local key="team-$team"  # per-team key prevents two teams clobbering each other

  if [ -n "$clear" ]; then
    cmux clear-status "$key" --workspace "$ws" 2>/dev/null || true
    # Only clear the progress bar if no other team-* key exists in this workspace.
    # clear-progress is workspace-wide; two teams sharing a workspace must not
    # wipe each other's bar.
    local other_key
    other_key=$(cmux list-status --workspace "$ws" 2>/dev/null \
      | grep -oE '^team-[^=]+' | grep -vF "$key" | head -1 || true)
    [ -z "$other_key" ] && cmux clear-progress --workspace "$ws" 2>/dev/null || true
    cmux log --source team --level info "team $team: closed" \
      --workspace "$ws" 2>/dev/null || true
    # Remove state file so a reuse of this slug starts fresh
    rm -f "$(dirname "$(_reg "$team")")/team-$team.sync" 2>/dev/null || true
    return 0
  fi

  local reg; reg=$(_reg "$team")
  [ -f "$reg" ] || return 0

  # Count total teammates and how many have reported (non-dash rows only).
  local total=0 reported=0
  local root; root=$(_root)
  local fallback_run; fallback_run=$(ls -dt "$root/.team/runs/"*"-$team" 2>/dev/null | head -1 || true)

  while IFS= read -r row; do
    [ -z "$row" ] && continue
    local lay; lay=$(awk '{print $3}' <<<"$row")
    [ "$lay" = dash ] && continue
    total=$((total + 1))
    local title rundir
    title=$(awk '{print $4}' <<<"$row")
    rundir=$(awk 'NF>=7{print $7}' <<<"$row")
    [ "${rundir:-}" = - ] && rundir=
    local run="${rundir:-$fallback_run}"
    local role="${title#"$team"-}"
    if [ -n "$run" ] && [ -f "$run/reports/$role.md" ]; then
      reported=$((reported + 1))
    elif [ -n "$run" ] && [ -f "$run/tasks.md" ] \
        && grep -qF -- "- [x] $title:" "$run/tasks.md" 2>/dev/null; then
      reported=$((reported + 1))
    fi
  done < "$reg"

  # Phase label
  local phase
  if [ "$total" -eq 0 ]; then
    phase="spawning"
  elif [ "$reported" -ge "$total" ]; then
    phase="done"
  elif [ "$reported" -gt 0 ]; then
    phase="working"
  else
    phase="spawning"
  fi

  # Progress fraction 0.0-1.0
  local frac="0.0"
  if [ "$total" -gt 0 ] && command -v python3 >/dev/null 2>&1; then
    frac=$(python3 -c "print(f'{$reported/$total:.2f}')" 2>/dev/null) || frac="0.0"
  fi

  # Compute pill text; colour and log level follow the phase
  local pill="$phase · $reported/$total reported"
  local pill_color=$_ST_C_ACTIVE level=progress
  [ "$phase" = done ] && { pill_color=$_ST_C_DONE; level=success; }

  # Update sidebar (never fatal; use per-team key and explicit workspace)
  cmux set-status "$key" "$pill" --icon sparkle --color "$pill_color" \
    --priority "$_ST_PILL_PRIORITY" --workspace "$ws" 2>/dev/null || true
  cmux set-progress "$frac" --label "$team" --workspace "$ws" 2>/dev/null || true

  # Transition logging: log when pill or per-teammate state changes.
  # State file: first line = last pill, subsequent lines = reported titles.
  # Derived from _reg's directory so TEAM_REG_DIR overrides work in tests.
  local state_file; state_file="$(dirname "$(_reg "$team")")/team-$team.sync"
  local prev_pill="" prev_reported_titles=""
  if [ -f "$state_file" ]; then
    prev_pill=$(head -1 "$state_file" 2>/dev/null || true)
    prev_reported_titles=$(tail -n +2 "$state_file" 2>/dev/null || true)
  fi

  # Log overall phase/count change
  if [ "$pill" != "$prev_pill" ]; then
    cmux log --source team --level "$level" "$team: $pill" --workspace "$ws" 2>/dev/null || true
  fi

  # Build current reported titles list; log each new completion
  local cur_reported_titles=""
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    local _lay _title _rundir
    _lay=$(awk '{print $3}' <<<"$row")
    [ "$_lay" = dash ] && continue
    _title=$(awk '{print $4}' <<<"$row")
    _rundir=$(awk 'NF>=7{print $7}' <<<"$row")
    [ "${_rundir:-}" = - ] && _rundir=
    local _run="${_rundir:-$fallback_run}"
    local _role="${_title#"$team"-}"
    if [ -n "$_run" ] && [ -f "$_run/reports/$_role.md" ]; then
      cur_reported_titles="${cur_reported_titles}${_title}"$'\n'
      if ! printf '%s\n' "$prev_reported_titles" | grep -qxF "$_title" 2>/dev/null; then
        cmux log --source team --level success "$_title: reported" --workspace "$ws" 2>/dev/null || true
      fi
    fi
  done < "$reg"

  # Write current state (never fatal)
  { printf '%s\n' "$pill"; printf '%s' "$cur_reported_titles"; } > "$state_file" 2>/dev/null || true
}

# sub_sync_clear <team> — shorthand for close path in team.sh
sub_sync_clear() { sub_sync --clear "${1:?team}"; }
