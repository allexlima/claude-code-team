#!/usr/bin/env bash
# lib/status.sh — sub_status, sub_monitor, sub_sync functions for team.sh
# Sourced by team.sh after helpers are defined (set -euo pipefail is already on).
# Functions only; no top-level side effects.
#
# Requires team.sh globals/functions (bound before sourcing):
#   $here              absolute dir of team.sh
#   _root              prints main checkout root (main worktree)
#   _reg <team>        prints /tmp/team-<team>.tabs
#   _reg_add <team> <ref> <layout> <title> <model|-> <submodel|-> <rundir|-> [<sid> <cwd>]
#                      appends a registry row (root + state=live inserted automatically)
#   _pane_of <ref>     prints cmux pane_ref or "gone" (cmux only)
#   _lead_pane         prints "<pane_ref> <surface_ref>" of caller's session
#   _model_tier <m>    prints opus|sonnet|haiku or empty
#   _model_gone <m>    returns 0 if model not in org picker (fallback defined below)
#   _alive <b> <r>     returns 0 if surface/pane exists (fallback defined below)
#   _require_cmux [ws] exits 3 if cmux absent/unhealthy; ws also checks CMUX_*IDs
#   _lock <file>       acquire lock; EXIT trap set for cleanup
#
# Registry row format (team.sh, 11 cols):
#   backend ref layout title model submodel rundir root state session-id cwd
#   col 3 layout ∈ pane|tab|dash  (dash = monitor row, excluded from status table)
#   col 6 CLAUDE_CODE_SUBAGENT_MODEL id or "-" (absent on old rows → "")
#   col 7 absolute run dir or "-" (absent on old rows → "")
#   col 8 project root or "-" (absent on old rows → "")
#   col 9 live|finished (absent on rows before rev5 → live). `finished` = closed on
#         purpose by `team.sh finish`; its surface is gone by design, so it is never DEAD
#   col 10 session id or "-"; col 11 cwd (last, may contain spaces)
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
    local sid="${8:--}" cwd="${9:-}"
    local root; root=$(_root 2>/dev/null || pwd)
    printf 'cmux %s %s %s %s %s %s %s live %s %s\n' \
      "$ref" "$lay" "$title" "$mdl" "$smdl" "$rdir" "$root" "$sid" "$cwd" \
      >> "$(_reg "$team")"
  }
fi

# ---------------------------------------------------------------------------
# _st_state <finished> <backend> <alive> <model_gone> <waiting> <idle> <stalled>
# Pure: prints exactly one state token from the detection facts _st_row gathers.
# Flags are 1 or empty; <alive> is 1 (surface exists), 0 (gone) or empty (unknown,
# e.g. no cmux on PATH). Decision order, first match wins:
#   FINISHED    col 9 is rev5-core's `finished` marker — the only "finished on
#               purpose" signal (surface-health omits closed surfaces, and a report on
#               disk alone is also true mid-flight and in round 2)
#   UNKNOWN     not a cmux row, or liveness unknown: never rendered as alive
#   DEAD        surface gone without the marker
#   MODEL_GONE  model (or subagent model) no longer offered
#   WAITING     newest notification is an AskUserQuestion ("Claude question")
#   STALLED     mid-work milestone, no status/report write for >=10 min
#   IDLE        newest notification is "Completed in …" and no report on disk
#               (routine while waiting on a peer; after 10 silent min it is STALLED)
#   WORKING     everything else (including "report on disk" while still alive)
# ---------------------------------------------------------------------------
_st_state() {
  local fin=$1 backend=$2 alive=$3 gone=$4 waiting=$5 idle=$6 stalled=$7
  if [ -n "$fin" ]; then echo FINISHED
  elif [ "$backend" != cmux ] || [ -z "$alive" ]; then echo UNKNOWN
  elif [ "$alive" != 1 ]; then echo DEAD
  elif [ -n "$gone" ]; then echo MODEL_GONE
  elif [ -n "$waiting" ]; then echo WAITING
  elif [ -n "$stalled" ]; then echo STALLED
  elif [ -n "$idle" ]; then echo IDLE
  else echo WORKING
  fi
}

# ---------------------------------------------------------------------------
# _st_row <row> <run> <leadpane> <team>: one TAB-separated record per teammate
#   role  title  state  milestone  step  age_min(-1 = none)  note
# Detection only (decision 7): gathers the facts and asks _st_state for the token;
# _st_frame does all layout. Reads module globals: _ST_UUID_MAP, _ST_NOTIF_DATA
# ---------------------------------------------------------------------------
_st_row() {
  local row="$1" run="$2" leadpane="$3" team="$4"

  local backend ref lay title mdl submdl rundir marker
  backend=$(awk '{print $1}' <<<"$row")
  ref=$(awk '{print $2}' <<<"$row")
  lay=$(awk '{print $3}' <<<"$row")
  title=$(awk '{print $4}' <<<"$row")
  mdl=$(awk '{print $5}' <<<"$row")
  submdl=$(awk 'NF>=6{print $6}' <<<"$row")
  rundir=$(awk 'NF>=7{print $7}' <<<"$row")
  marker=$(awk 'NF>=9{print $9}' <<<"$row")

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

  # ------ STEP (last line of status file; _st_frame truncates by display width)
  local step='-'
  if [ -n "$stf" ] && [ -f "$stf" ]; then
    local raw; raw=$(tail -1 "$stf" 2>/dev/null | tr '\t\r' '  ') || true
    step="${raw:--}"
  fi

  # ------ LAST_ACTIVITY (age of newest {report, status} mtime) ------------
  local newest=0 age=-1
  local f t
  for f in "$rpt" "$stf"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    t=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || continue
    [ "$t" -gt "$newest" ] && newest=$t
  done
  if [ "$newest" -gt 0 ]; then
    local now; now=$(date +%s)
    age=$(( (now - newest) / 60 ))
  fi

  # ------ FACTS -----------------------------------------------------------
  local fin= alive= gone= waiting= idle= stalled= parked=
  [ "$marker" = finished ] && fin=1

  # STALLED: derived signals only; fires during mid-work milestones, silent >10m
  case $ms in
    spawned|investigating|drafting)
      [ "$age" -ge 10 ] && stalled=1 ;;
  esac

  # MODEL_GONE (N3): check main model col and subagent model col
  local m
  for m in "$mdl" "$submdl"; do
    [ -z "$m" ] || [ "$m" = "-" ] && continue
    _model_gone "$m" 2>/dev/null && { gone=1; break; }
  done

  # Liveness / parked-in-lead-pane / WAITING / IDLE (cmux only; skipped once finished)
  if [ -z "$fin" ] && [ "$backend" = cmux ] && command -v cmux >/dev/null; then
    # DEAD only on _alive's definite answer (not_found / null pane_ref). _alive keeps
    # the row on any cmux error, so a _pane_of failure after it is an error too: UNKNOWN.
    alive=0
    if _alive cmux "$ref" 2>/dev/null; then
      alive=
      local pp; pp=$(_pane_of "$ref" 2>/dev/null || echo gone)
      if [ "$pp" != gone ]; then
        alive=1
        # In the lead's pane (show's failure path, a hand-dragged tab): a note, not a state
        if [ -n "$leadpane" ] && [ "$pp" = "$leadpane" ]; then
          parked=1
        fi

        # WAITING / IDLE: derive from newest cmux notification for this surface.
        # Skip WAITING for haiku/dontAsk tier (no human approval needed).
        # Probed by rev4-tests (CLI 2.1.294):
        #   AskUserQuestion  → title="Claude question", subtitle=""
        #   Completion/Stop  → title="Claude Code",     subtitle="Completed in <session>"
        #   PermissionRequest → NOT in list-notifications (uses cmux hooks feed).
        #     Permission prompts cannot be detected via notifications; a teammate
        #     blocked on one surfaces only as STALLED after 10 min of silence.
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
              if [ -z "$skip_waiting" ]; then
                printf '%s\n' "$notif_title" | grep -qi 'claude question' && waiting=1
              fi
              # Session completed its last turn but report not yet on disk
              if [ "$ms" != reported ]; then
                printf '%s\n' "$notif_subtitle" | grep -qi '^completed in ' && idle=1
              fi
            fi
          fi
        fi
      fi
    fi
  fi

  local state; state=$(_st_state "$fin" "$backend" "$alive" "$gone" "$waiting" "$idle" "$stalled")

  # Notes: context a token alone cannot carry
  local note=
  if [ -n "$parked" ] && [ "$state" = WORKING ]; then note="in the lead's pane"
  elif [ "$state" = WORKING ] && [ "$ms" = reported ]; then note="report on disk"
  elif [ "$state" = DEAD ] && [ -n "$rpt" ] && [ -f "$rpt" ]; then note="report safe; resume unavailable"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$role" "$title" "$state" "$ms" "$step" "$age" "$note"
}

# _st_records <reg> <run> <leadpane> <team>: one _st_row record per non-dash teammate
# (deduplicated by title, last row wins). The single record source for the pane and
# the sidebar, so N/M is counted the same way on both surfaces.
_st_records() {
  local reg="$1" run="$2" leadpane="$3" team="$4"

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
# Frame rendering: a pure function of records + width + colour + charset.
# The python3 formatter measures display width (unicodedata.east_asian_width),
# truncates on grapheme-cluster boundaries and paints the shared palette. Its
# header carries the literal @@CLOCK@@ so frames compare equal across ticks.
# ---------------------------------------------------------------------------

read -r -d '' _ST_FRAME_PY <<'PY' || true
import os, sys, unicodedata

# argv: team width color(0|1) ascii(0|1); stdin: TSV records
# role  title  state  milestone  step  age_min(-1 = none)  note
team, width, color, ascii_ = sys.argv[1], int(sys.argv[2]), sys.argv[3] == '1', sys.argv[4] == '1'
sys.stdin.reconfigure(encoding='utf-8', errors='replace')
sys.stdout.reconfigure(encoding='ascii' if ascii_ else 'utf-8', errors='replace')

PAL = {'alert': (0xFF, 0x45, 0x3A), 'active': (0xAF, 0x52, 0xDE),
       'done': (0x30, 0xD1, 0x58), 'dim': (0x8E, 0x8E, 0x93)}
#        token        utf8 ascii  word           role
STATES = {'WAITING':   ('⏸', '!', 'waiting',     'alert'),
          'MODEL_GONE':('⚠', 'M', 'model gone',  'alert'),
          'DEAD':      ('✗', 'x', 'dead',        'alert'),
          'STALLED':   ('⧗', '~', 'stalled?',    'alert'),
          'WORKING':   ('◐', '*', 'working',     'active'),
          'IDLE':      ('◌', '-', 'idle',        'dim'),
          'UNKNOWN':   ('?', '?', 'unknown',     'dim'),
          'FINISHED':  ('✓', '+', 'finished',    'done')}
ORDER = list(STATES)  # alerts first (most urgent first), then working, unknown, finished
HINT = {'WAITING': 'answer it in its pane', 'MODEL_GONE': 'model no longer offered',
        'DEAD': 'pane gone; respawn or check',
        'STALLED': 'no update; maybe a permission prompt'}

def paint(s, role):
    if not color or not s:
        return s
    r, g, b = PAL[role]
    return f'\x1b[38;2;{r};{g};{b}m{s}\x1b[0m'

def cw(ch):
    if unicodedata.combining(ch) or ch in '‍︎️' or unicodedata.category(ch) in ('Mn', 'Me', 'Cf'):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1

def dw(s):
    return sum(cw(c) for c in s)

def clusters(s):
    # A cluster is a base char plus following zero-width chars (combining marks, ZWJ
    # and what it joins, variation selectors) — truncation never splits one.
    out, join = [], False
    for c in s:
        if out and (cw(c) == 0 or join):
            out[-1] += c
        else:
            out.append(c)
        join = c == '‍'
    return out

def fit(s, w):
    """Truncate to display width w (ellipsis included), then pad to exactly w."""
    if w <= 0:
        return ''
    if dw(s) > w:
        ell = '~' if ascii_ else '…'
        acc = ''
        for cl in clusters(s):
            if dw(acc) + dw(cl) > w - 1:
                break
            acc += cl
        s = acc + ell
    return s + ' ' * (w - dw(s))

def age(m):
    m = int(m)
    if m < 0:
        return '-'
    return f'{m}m' if m < 60 else f'{m // 60}h{m % 60:02d}m'

def asciify(s):
    # Non-UTF-8 locale: fold accents (ç -> c), replace anything else with '?' so the
    # width measured is the width printed.
    s = ''.join(c for c in unicodedata.normalize('NFKD', s) if not unicodedata.combining(c))
    return ''.join(c if ord(c) < 128 else '?' for c in s)

recs = []
for line in sys.stdin:
    if ascii_:
        line = asciify(line)
    f = line.rstrip('\n').split('\t')
    if len(f) < 7 or f[2] not in STATES:
        continue
    recs.append(dict(role=f[0], title=f[1], state=f[2], ms=f[3], step=f[4], age=age(f[5]), note=f[6]))

def sym(st):
    u, a, word, role = STATES[st]
    return (a if ascii_ else u), word, role

total = len(recs)
done = sum(1 for r in recs if r['ms'] == 'reported' or r['state'] == 'FINISHED')
sep = ' - ' if ascii_ else ' · '
# The clock (8 cols once bash substitutes @@CLOCK@@) is reserved first; the team
# name gives way, and this line is exempt from clip() so the placeholder stays whole.
head = f'{team}{sep}{done}/{total} reported{sep}'
if dw(head) > width - 8:
    head = fit(head, width - 9).rstrip() + ' '
out = [head + '@@CLOCK@@']
barw = max(5, min(20, width - 8))
filled = (barw * done // total) if total else 0
pct = (100 * done // total) if total else 0
full, empty = ('#', '-') if ascii_ else ('█', '░')
out.append(paint(full * filled, 'done') + paint(empty * (barw - filled), 'dim') + f'  {pct}%')
out.append('')

alerts = [r for r in recs if STATES[r['state']][3] == 'alert']
rest = [r for r in recs if STATES[r['state']][3] != 'alert']
alerts.sort(key=lambda r: ORDER.index(r['state']))
rest.sort(key=lambda r: ORDER.index(r['state']))
rolew = min(18, max([dw(r['role']) for r in recs] + [4]))

if alerts:
    hdr = ('!' if ascii_ else '⚠') + f' NEEDS YOU ({len(alerts)})'
    out.append(paint(hdr, 'alert'))
    agew = max(dw(r['age']) for r in alerts)
    wordw = max(dw(sym(r['state'])[1]) for r in alerts)
    # 4 indent + glyph + space + role + 2 + word + 2 + age: role shrinks before word or age
    arolew = max(3, min(rolew, width - (4 + 2 + 2 + wordw + 2 + agew)))
    for r in alerts:
        s, word, role = sym(r['state'])
        detail = r['note'] or (r['step'] if r['step'] != '-' else '') or HINT[r['state']]
        msg = f'{word}{sep}{detail}'
        msgw = width - (4 + 2 + arolew + 2 + 2 + agew)
        if dw(msg) > msgw:
            msg = word if msgw < dw(word) + dw(sep) + 4 else msg
        line = '    ' + paint(s, 'alert') + ' ' + fit(r['role'], arolew) + '  '
        line += fit(msg, max(msgw, dw(word))) + '  ' + r['age'].rjust(agew)
        out.append(line.rstrip())
    out.append('')

if rest:
    def label(r):
        s, word, _ = sym(r['state'])
        if r['state'] == 'WORKING' and r['ms'] in ('spawned', 'investigating', 'drafting'):
            word = r['ms']
        return s, word
    labels = [label(r) for r in rest]
    statew = max([dw(s + ' ' + w) for s, w in labels] + [5])
    agew = max([dw(r['age']) for r in rest] + [3])
    # role shrinks first (to 3), then the state word, so ROLE + STATE + AGE survive
    trolew = max(3, min(rolew, width - (4 + 2 + statew + 2 + agew)))
    statew = max(3, min(statew, width - (4 + trolew + 2 + 2 + agew)))
    stepw = width - (4 + trolew + 2 + statew + 2 + 2 + agew)
    show_step = width >= 60 and stepw >= 8
    head = '    ' + fit('ROLE', trolew) + '  ' + fit('STATE', statew) + '  '
    head += (fit('STEP', stepw) + '  ' if show_step else '') + 'AGE'.rjust(agew)
    out.append(paint(head.rstrip(), 'dim'))
    for r, (s, word) in zip(rest, labels):
        role = STATES[r['state']][3]
        step = r['step']
        if r['note']:
            step = r['note'] if step == '-' else f"{r['note']}{sep}{step}"
        line = '  ' + ('-' if ascii_ else '·') + ' ' + fit(r['role'], trolew) + '  '
        line += paint(s, role) + ' ' + fit(word, statew - dw(s) - 1) + '  '
        line += (fit(step, stepw) + '  ' if show_step else '') + r['age'].rjust(agew)
        out.append(line.rstrip())

def clip(line):
    # Last guard: no line wider than the pane. Escape sequences cost no width;
    # cut on a cluster boundary and close any open colour.
    vis, res, i = 0, '', 0
    while i < len(line):
        if line[i] == '\x1b':
            j = line.index('m', i) + 1
            res += line[i:j]; i = j; continue
        cl = line[i]; i += 1
        while i < len(line) and line[i] != '\x1b' and cw(line[i]) == 0:
            cl += line[i]; i += 1
        if vis + dw(cl) > width:
            return res + ('\x1b[0m' if color else '')
        res += cl; vis += dw(cl)
    return res

print('\n'.join([out[0]] + [clip(l) for l in out[1:]]))
PY

# _st_cols: terminal width. TEAM_COLS wins (tests), else `tput cols` — never $COLUMNS,
# which is 0 in non-interactive bash. tput prints 80 when stdout is not a tty.
_st_cols() {
  local c=${TEAM_COLS:-}
  case $c in ''|*[!0-9]*) c=$(tput cols 2>/dev/null || true) ;; esac
  case $c in ''|*[!0-9]*) c=80 ;; esac
  [ "$c" -lt 20 ] && c=20
  [ "$c" -gt 400 ] && c=400
  echo "$c"
}

# _st_color_on: 0 when colour applies. Evaluate where stdout is the real output,
# never inside $(...), where [ -t 1 ] is always false.
_st_color_on() {
  [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ] \
    && { [ -t 1 ] || [ "${TEAM_FORCE_COLOR:-}" = 1 ]; }
}

# _st_ascii: 0 when the locale is not UTF-8 (first of LC_ALL, LC_CTYPE, LANG set wins)
_st_ascii() {
  local loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  case $loc in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 1 ;; esac
  return 0
}

# _st_frame <team> <cols> <color 0|1> <ascii 0|1>: records on stdin -> frame on stdout
_st_frame() {
  python3 -I -c "$_ST_FRAME_PY" "$@"
}

# _st_collect <team>: resolve run dir + lead pane, print the team's records.
# Exit 3 when the team has no registry.
_st_collect() {
  local team=$1
  local reg; reg=$(_reg "$team")
  [ -f "$reg" ] || return 3
  local root; root=$(_root)

  # Fallback run dir (for old registry rows without col 7)
  local run
  run=$(ls -dt "$root/.team/runs/"*"-$team" 2>/dev/null | head -1 || true)

  # Lead's pane_ref, for the "in the lead's pane" note. Inside the monitor pane
  # _lead_pane would resolve to the monitor itself, so sub_monitor bakes
  # TEAM_LEAD_PANE into the pane's command.
  local leadpane=
  if command -v cmux >/dev/null && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    if [ -n "${TEAM_LEAD_PANE:-}" ]; then
      leadpane="$TEAM_LEAD_PANE"
    else
      local lp; lp=$(_lead_pane 2>/dev/null || true)
      leadpane="${lp%% *}"
    fi
  fi
  _st_records "$reg" "$run" "$leadpane" "$team"
}

# ---------------------------------------------------------------------------
# sub_status [--watch] <team>
# One frame: summary + progress bar, a NEEDS YOU block only when something needs
# attention, then the table. --watch re-reads the width every tick, repaints only
# when the frame changed, syncs the sidebar from the same records, and exits 0
# once `close` removes the registry.
# Exit: 0 ok, 3 no registry
# ---------------------------------------------------------------------------

sub_status() {
  local watch=
  [ "${1:-}" = --watch ] && { watch=1; shift; }
  local team=${1:?team}
  local reg; reg=$(_reg "$team")
  [ -f "$reg" ] || { printf 'no teammates recorded for %s\n' "$team" >&2; return 3; }

  local color=0 ascii=0
  _st_color_on && color=1
  _st_ascii && ascii=1

  if [ -z "$watch" ]; then
    local frame; frame=$(_st_collect "$team" | _st_frame "$team" "$(_st_cols)" "$color" "$ascii")
    printf '%s\n' "${frame/@@CLOCK@@/$(date '+%H:%M:%S')}"
    return 0
  fi

  local interval=${TEAM_STATUS_INTERVAL:-30}
  case $interval in *[!0-9]*|'') interval=30 ;; esac
  [ "$interval" -lt 1 ] && interval=1
  local prev= recs frame
  while [ -f "$reg" ]; do
    recs=$(_st_collect "$team" || true)
    frame=$(printf '%s\n' "$recs" | _st_frame "$team" "$(_st_cols)" "$color" "$ascii")
    if [ "$frame" != "$prev" ]; then
      clear || true
      printf '%s\n' "${frame/@@CLOCK@@/$(date '+%H:%M:%S')}"
      prev=$frame
    elif [ -t 1 ]; then
      # Unchanged frame: rewrite only the summary line so the clock shows the loop is alive
      local head=${frame%%$'\n'*}
      printf '\033[s\033[H%s\033[K\033[u' "${head/@@CLOCK@@/$(date '+%H:%M:%S')}"
    fi
    _st_sync_apply "$team" "$recs" || true
    sleep "$interval"
  done
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

  # Capture lead's pane_ref NOW (running as the lead), for the monitor pane's
  # command (inside it, _lead_pane would resolve to the monitor itself).
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

  # The pane runs `status --watch`: the loop lives in real bash (sub_status) so it can
  # keep the previous frame and repaint only on change; it reads the width each tick,
  # syncs the sidebar, and exits when `close` removes the registry (no orphan
  # process). TEAM_LEAD_PANE is baked in for the "in the lead's pane" note.
  local team_q; team_q=$(printf '%q' "$team")
  local script_q; script_q=$(printf '%q' "$here/team.sh")
  local cmd="TEAM_LEAD_PANE=$lead_pane_q TEAM_STATUS_INTERVAL=$interval bash $script_q status --watch $team_q"

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
    cmux clear-status "$key" --workspace "$ws" >/dev/null 2>&1 || true
    # Only clear the progress bar if no other team-* key exists in this workspace.
    # clear-progress is workspace-wide; two teams sharing a workspace must not
    # wipe each other's bar.
    local other_key
    other_key=$(cmux list-status --workspace "$ws" 2>/dev/null \
      | grep -oE '^team-[^=]+' | grep -vF "$key" | head -1 || true)
    [ -z "$other_key" ] && cmux clear-progress --workspace "$ws" >/dev/null 2>&1 || true
    cmux log --source team --level info "team $team: closed" \
      --workspace "$ws" >/dev/null 2>&1 || true
    # Remove state file so a reuse of this slug starts fresh
    rm -f "$(dirname "$(_reg "$team")")/team-$team.sync" 2>/dev/null || true
    return 0
  fi

  local recs; recs=$(_st_collect "$team") || return 0
  _st_sync_apply "$team" "$recs"
}

# _st_sync_apply <team> <records>: pill + progress + transition log from _st_records
# output. Read-only towards teammates (decision 28): it only writes the sidebar and
# its own .sync state file, because the monitor pane and the lead both run it.
_st_sync_apply() {
  local team=$1 recs=$2
  command -v cmux >/dev/null 2>&1 || return 0
  [ -n "${CMUX_WORKSPACE_ID:-}" ] || return 0
  local ws="$CMUX_WORKSPACE_ID" key="team-$team"

  local total=0 reported=0 needs=0 started=
  local role title state ms _step _age _note
  while IFS=$'\t' read -r role title state ms _step _age _note; do
    [ -n "$title" ] || continue
    total=$((total + 1))
    { [ "$ms" = reported ] || [ "$state" = FINISHED ]; } && reported=$((reported + 1))
    [ "$ms" != spawned ] && started=1
    case $state in WAITING|DEAD|MODEL_GONE|STALLED) needs=$((needs + 1)) ;; esac
  done <<<"$recs"

  # Phase, pill colour and log level move together (one palette with the pane)
  local phase pill_color level
  if [ "$total" -gt 0 ] && [ "$reported" -ge "$total" ]; then
    phase=done; pill_color=$_ST_C_DONE; level=success
  elif [ "$needs" -gt 0 ]; then
    phase="needs you"; pill_color=$_ST_C_ALERT; level=warning
  elif [ "$reported" -gt 0 ] || [ -n "$started" ]; then
    phase=working; pill_color=$_ST_C_ACTIVE; level=progress
  else
    phase=spawning; pill_color=$_ST_C_ACTIVE; level=progress
  fi

  # Progress fraction 0.0-1.0
  local frac="0.0"
  if [ "$total" -gt 0 ] && command -v python3 >/dev/null 2>&1; then
    frac=$(python3 -c "print(f'{$reported/$total:.2f}')" 2>/dev/null) || frac="0.0"
  fi

  local pill="$phase · $reported/$total reported"

  # Update sidebar (never fatal; use per-team key and explicit workspace)
  cmux set-status "$key" "$pill" --icon sparkle --color "$pill_color" \
    --priority "$_ST_PILL_PRIORITY" --workspace "$ws" >/dev/null 2>&1 || true
  cmux set-progress "$frac" --label "$team" --workspace "$ws" >/dev/null 2>&1 || true

  # Transition logging. State file: line 1 = last pill, then "title<TAB>state<TAB>ms"
  # per teammate. Derived from _reg's directory so TEAM_REG_DIR overrides work in tests.
  local state_file; state_file="$(dirname "$(_reg "$team")")/team-$team.sync"
  local prev_pill="" prev_rows=""
  if [ -f "$state_file" ]; then
    prev_pill=$(head -1 "$state_file" 2>/dev/null || true)
    prev_rows=$(tail -n +2 "$state_file" 2>/dev/null || true)
  fi

  if [ "$pill" != "$prev_pill" ]; then
    cmux log --source team --level "$level" "$team: $pill" --workspace "$ws" >/dev/null 2>&1 || true
  fi

  local cur_rows="" prev pstate pms msg lvl
  while IFS=$'\t' read -r role title state ms _step _age _note; do
    [ -n "$title" ] || continue
    cur_rows="${cur_rows}${title}"$'\t'"${state}"$'\t'"${ms}"$'\n'
    prev=$(awk -F'\t' -v t="$title" '$1==t {print; exit}' <<<"$prev_rows" 2>/dev/null || true)
    pstate=$(awk -F'\t' '{print $2}' <<<"$prev"); pms=$(awk -F'\t' '{print $3}' <<<"$prev")
    msg= lvl=
    if [ -z "$prev" ] || [ "$state" != "$pstate" ]; then
      case $state in
        WAITING)    msg="waiting (needs input)" lvl=warning ;;
        IDLE)       msg="idle (turn ended without a report)" lvl=info ;;
        STALLED)    msg="stalled?" lvl=warning ;;
        DEAD)       msg=dead lvl=error ;;
        MODEL_GONE) msg="model gone" lvl=error ;;
        FINISHED)   msg=finished lvl=success ;;
      esac
      [ -z "$prev" ] && [ -z "$msg" ] && msg=spawned lvl=progress
    fi
    if [ "$ms" = reported ] && [ "$pms" != reported ] && [ -z "$msg" ]; then
      msg=reported lvl=success
    fi
    [ -n "$msg" ] && { cmux log --source team --level "$lvl" "$title: $msg" \
      --workspace "$ws" >/dev/null 2>&1 || true; }
  done <<<"$recs"

  # Write current state (never fatal)
  { printf '%s\n' "$pill"; printf '%s' "$cur_rows"; } > "$state_file" 2>/dev/null || true
}

# sub_sync_clear <team> — shorthand for close path in team.sh
sub_sync_clear() { sub_sync --clear "${1:?team}"; }
