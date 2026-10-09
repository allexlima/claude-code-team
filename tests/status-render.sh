#!/usr/bin/env bash
# tests/status-render.sh — golden-frame + state tests for the rev5 monitor renderer.
# Source: .team/runs/2026-10-08-rev5/decisions.md (decisions 1-7, 41, 43, 48), tasks.md.
# Every case names the requirement it covers (A1..., decision N). All headless: a stub cmux on
# PATH, a scratch TEAM_REG_DIR, synthetic registries and run dirs. Nothing touches real panes.
# USAGE:  bash tests/status-render.sh            (current worktree)
#         TEAM_SH=/path/to/team.sh bash tests/status-render.sh
# Two layers:
#   G*  pure layer: `_st_frame <team> <cols> <color> <ascii>` fed TSV records; byte-exact goldens.
#   E*  end to end: `team.sh status <team>` over a fixture registry; asserts the derived STATE.
# No -e: every case reports PASS/FAIL itself, so a failing command must not abort the run.
set -uo pipefail

TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/team.sh}"
LIB="$(dirname "$TEAM_SH")/lib/status.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; passes=0
pass() { echo "PASS  $1"; passes=$((passes+1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }
unset TEAM_MEMBER NO_COLOR TEAM_FORCE_COLOR TEAM_COLS

# ── stub cmux: identify answers "gone" for refs listed in $CMUX_GONE_REFS; everything else is empty ──
mkdir -p "$W/bin"
CMUX_LOG="$W/cmux.log"; : > "$CMUX_LOG"; export CMUX_LOG
cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
case "$1" in
  ping) echo PONG ;;
  --version) echo "cmux 0.65.0 (108) stub" ;;
  identify)
    surf=""; prev=""
    for a; do [ "$prev" = "--surface" ] && surf="$a"; prev="$a"; done
    case " ${CMUX_ERR_REFS:-} " in *" $surf "*) echo "Error: timeout" >&2; exit 1 ;; esac
    case " ${CMUX_NOTFOUND_REFS:-} " in *" $surf "*) echo "Error: not_found" >&2; exit 1 ;; esac
    case " ${CMUX_GONE_REFS:-} " in
      *" $surf "*) echo '{"caller":{"pane_ref":null}}' ;;
      *) echo "{\"caller\":{\"pane_ref\":\"pane-live\",\"surface_ref\":\"${surf:-surface:lead}\"}}" ;;
    esac ;;
  list-panes) echo '{"panes":[]}' ;;
  list-notifications) echo '[]' ;;
  *) true ;;
esac
SH
chmod +x "$W/bin/cmux"
export PATH="$W/bin:$PATH"
export HOME="$W/home"; mkdir -p "$HOME"
export TEAM_REG_DIR="$W/reg"; mkdir -p "$TEAM_REG_DIR"
export CMUX_WORKSPACE_ID=ws-test CMUX_SURFACE_ID=surface:lead

# Display width of stdin lines, one number per line (east-asian wide = 2, combining = 0).
dwidth() {
  python3 -I -c '
import sys, unicodedata as u
for l in sys.stdin.read().split("\n")[:-1] or []:
    print(sum(0 if u.combining(c) else 2 if u.east_asian_width(c) in "WF" else 1 for c in l))'
}
# Run _st_frame in a clean bash with the library sourced; records on stdin.
# `|| true`: on code without _st_frame the case must FAIL (empty frame), not abort the whole run.
frame() { LC_ALL=en_US.UTF-8 bash -c '. "$1"; shift; _st_frame "$@"' _ "$LIB" "$@" 2>/dev/null || true; }
rec() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }   # role title state milestone step age_min note

# ═══ G1 — A1/decision 1: all-healthy frame is compact, no NEEDS YOU block ═══
healthy=$( { rec core fx-core WORKING drafting "drafting report" 3 ""
             rec docs fx-docs FINISHED reported - 0 ""
             rec status fx-status WORKING investigating "investigating facts" 5 ""; } | frame fx 72 0 0 )
want='fx · 1/3 reported · @@CLOCK@@
██████░░░░░░░░░░░░░░  33%

    ROLE    STATE            STEP                                    AGE
  · core    ◐ drafting       drafting report                          3m
  · status  ◐ investigating  investigating facts                      5m
  · docs    ✓ finished       -                                        0m'
[ "$healthy" = "$want" ] \
  && pass "G1: all-healthy compact frame matches golden (summary, bar, table, no alert block)" \
  || { fail "G1: all-healthy compact frame matches golden"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$healthy") | sed 's/^/        /' | head -12; }
grep -q 'NEEDS YOU' <<<"$healthy" \
  && fail "G1b: no NEEDS YOU block when nothing needs attention (decision 1)" \
  || pass "G1b: no NEEDS YOU block when nothing needs attention (decision 1)"

# ═══ G2 — decision 1: alerts pinned in a NEEDS YOU block above the table ═══
alert=$( { rec core fx-core WORKING drafting "-" 1 ""
           rec a fx-a DEAD spawned - 0 "report safe; resume unavailable"
           rec b fx-b WAITING drafting "which db?" 2 ""; } | frame fx 72 0 0 )
hdr_line=$(grep -n 'ROLE' <<<"$alert" | head -1 | cut -d: -f1 || true)
need_line=$(grep -n 'NEEDS YOU (2)' <<<"$alert" | head -1 | cut -d: -f1 || true)
if [ -n "$need_line" ] && [ -n "$hdr_line" ] && [ "$need_line" -lt "$hdr_line" ] \
   && sed -n "${need_line},${hdr_line}p" <<<"$alert" | grep -q 'waiting' \
   && sed -n "${need_line},${hdr_line}p" <<<"$alert" | grep -q 'dead'; then
  pass "G2: WAITING + DEAD pinned in 'NEEDS YOU (2)' block above the table (decision 1)"
else fail "G2: alerts pinned in NEEDS YOU block above the table" "$(printf '%s' "$alert" | head -12)"; fi

# ═══ G3 — decision 3: 50-col narrow frame drops STEP, keeps ROLE/STATE/AGE, never overflows ═══
narrow=$( { rec core fx-core WORKING drafting "drafting a very long step description here" 3 ""
            rec a fx-a DEAD spawned - 0 "report safe; resume unavailable"; } | frame fx 50 0 0 )
th=$(grep 'ROLE' <<<"$narrow" | tail -1 || true)
if grep -q 'STATE' <<<"$th" && grep -q 'AGE' <<<"$th" && ! grep -q 'STEP' <<<"$th" \
   && [ "$(dwidth <<<"$narrow" | sort -n | tail -1)" -le 50 ]; then
  pass "G3: 50 cols — STEP dropped, ROLE/STATE/AGE kept, no line wider than 50 (decision 3)"
else fail "G3: 50-col narrow frame" "header=[$th] maxw=$(dwidth <<<"$narrow" | sort -n | tail -1)"; fi

# ═══ G4 — decision 4: pure-layer colour switch ═══
c0=$(rec core fx-core WORKING drafting step 1 "" | frame fx 72 0 0)
c1=$(rec core fx-core WORKING drafting step 1 "" | frame fx 72 1 0)
if ! grep -q $'\033' <<<"$c0" && grep -q $'\033\\[' <<<"$c1"; then
  pass "G4: colour flag 0 -> no escapes, 1 -> escapes (decision 4)"
else fail "G4: colour flag 0 -> no escapes, 1 -> escapes"; fi

# ═══ G5 — decision 4: ASCII fallback has no non-ASCII bytes and keeps word+symbol ═══
asc=$( { rec core fx-core WORKING drafting "-" 1 ""; rec docs fx-docs FINISHED reported - 1 ""; } | frame fx 60 0 1 )
if ! LC_ALL=C grep -q $'[\x80-\xff]' <<<"$asc" && grep -q 'finished' <<<"$asc"; then
  pass "G5: ASCII mode emits no non-ASCII bytes and still says 'finished' (decision 4)"
else fail "G5: ASCII mode" "$(printf '%s' "$asc" | head -6)"; fi

# ═══ G6 — decision 5: UTF-8 / wide step strings keep every table row the same display width ═══
utf=$( { rec a fx-a WORKING drafting "investigação de fatos" 1 ""
         rec b fx-b WORKING drafting "日本語のステップ説明" 2 ""
         rec c fx-c WORKING drafting "plain ascii step" 3 ""; } | frame fx 72 0 0 )
widths=$(grep -E '^  · |ROLE' <<<"$utf" | dwidth | sort -u | wc -l | tr -d ' ' || true)
nrows=$(grep -cE '^  · ' <<<"$utf" || true)   # guard: 3 data rows must exist, or the width check is vacuous
{ [ "$widths" = 1 ] && [ "$nrows" = 3 ]; } \
  && pass "G6: accented + CJK steps keep all table rows the same display width (decision 5)" \
  || fail "G6: UTF-8 alignment" "distinct row widths=$widths rows=$nrows; frame:
$utf"


# ═══ G7 — decision 63: narrow widths truncate ROLE before dropping STATE/AGE; no line wider than the terminal ═══
longrole=r_abcdefghijklmnop1   # 18 chars
bad=
for cols in 20 30 40 50 72; do
  f=$( { rec "$longrole" fx-x WAITING drafting "needs a decision" 7 ""
         rec "${longrole}b" fx-y DEAD spawned - 2 ""
         rec "${longrole}c" fx-z WORKING drafting "日本語のステップ説明 investigação" 3 ""; } | frame fx "$cols" 0 0 )
  f=${f/@@CLOCK@@/00:00:00}   # the placeholder is 9 wide, the real clock 8: measure the real width
  mw=$(dwidth <<<"$f" | sort -n | tail -1)
  [ "${mw:-999}" -le "$cols" ] || bad+=" cols=$cols:maxwidth=$mw"
  if [ "$cols" -ge 40 ]; then
    # alert rows keep their state WORD (not just the glyph), every table row keeps its AGE
    grep -E 'r_abc' <<<"$f" | sed -n '1,2p' | grep -qiE 'waiting|dead' || bad+=" cols=$cols:alert-word-lost"
    [ "$(grep -cE '^  . r_abc.* [0-9]+m$' <<<"$f")" -ge 1 ] || bad+=" cols=$cols:age-lost"
  fi
done
[ -z "$bad" ] && pass "G7: widths 20-72 with 18-char roles + CJK: no line wider than the terminal; alert rows keep the state word and table rows their AGE at >=40 cols (decision 63)" \
  || fail "G7: narrow-width priority" "$bad"

# ═══ G8 — decision 64: never glyph alone — every state has a distinct ASCII glyph ═══
asc8=$( { for st in FINISHED WORKING WAITING DEAD MODEL_GONE IDLE STALLED UNKNOWN; do rec "r_$st" "fx-r_$st" "$st" drafting step 3 ""; done; } | frame fx 60 0 1 )
glyphs=$(python3 -I - "$asc8" <<'PYG'
import sys
lines = sys.argv[1].split("\n")
hdr = next((i for i, l in enumerate(lines) if "ROLE" in l), len(lines))
out = {}
for i, l in enumerate(lines):
    t = l.split()
    for st in ("FINISHED","WORKING","WAITING","DEAD","MODEL_GONE","IDLE","STALLED","UNKNOWN"):
        if "r_" + st in t:
            k = t.index("r_" + st)
            out[st] = t[k-1] if i < hdr else t[k+1]   # alert rows: glyph before role; table rows: after
print(" ".join(f"{k}={v}" for k, v in sorted(out.items())))
PYG
)
n_states=$(wc -w <<<"$glyphs" | tr -d ' ')
n_distinct=$(tr ' ' '\n' <<<"$glyphs" | sed 's/.*=//' | sort -u | wc -l | tr -d ' ')
{ [ "$n_states" = 8 ] && [ "$n_distinct" = 8 ]; } \
  && pass "G8: all 8 states have distinct ASCII glyphs (WAITING vs MODEL_GONE no longer collide) (decision 64)" \
  || fail "G8: ASCII glyph collision" "states=$n_states distinct=$n_distinct :: $glyphs"

# ═══ End-to-end fixtures ═══
G="$W/repo"; mkdir -p "$G"; git -C "$G" init -q
RUN="$W/run"; mkdir -p "$RUN/reports" "$RUN/status"
: > "$RUN/tasks.md"
reg_row() {   # backend ref title state(col9|'') -> row; layout pane, no model, rundir=$RUN, root=$G
  local backend=$1 ref=$2 title=$3 state=${4:-}
  if [ -n "$state" ]; then
    printf '%s %s pane %s - - %s %s %s %s %s\n' "$backend" "$ref" "$title" "$RUN" "$G" "$state" "11111111-2222-3333-4444-555555555555" "$G"
  else
    printf '%s %s pane %s - - %s\n' "$backend" "$ref" "$title" "$RUN"     # legacy 7-col row
  fi
}
status_out() { # <team> [env...] -> plain-frame text
  local t=$1; shift
  (cd "$G" && env LC_ALL=en_US.UTF-8 TEAM_COLS=100 "$@" bash "$TEAM_SH" status "$t" 2>&1)
}
row_of() { grep -E "^  (·|-) $1 |^ +. $1 " <<<"$2" | head -1; }

# ═══ E1 — decision 8/41: FINISHED (marker set, surface closed, report on disk) renders finished, never dead ═══
printf 'REPORT\nPARALLELISM: none\n' > "$RUN/reports/fin.md"
{ reg_row cmux surface:101 e1-fin finished; } > "$TEAM_REG_DIR/team-e1.tabs"
out=$(status_out e1 CMUX_GONE_REFS="surface:101")
if grep -q 'finished' <<<"$out" && ! grep -qi 'dead' <<<"$out"; then
  pass "E1: finished teammate (marker, closed surface) renders 'finished' and never 'dead' (decisions 8, 41)"
else fail "E1: finished renders finished, not dead" "$out"; fi

# ═══ E2 — no report + closed surface + no marker renders dead ═══
{ reg_row cmux surface:102 e2-gone live; } > "$TEAM_REG_DIR/team-e2.tabs"
out=$(status_out e2 CMUX_GONE_REFS="surface:102")
if grep -qi 'dead' <<<"$out" && ! grep -q 'finished' <<<"$out"; then
  pass "E2: no marker + closed surface renders 'dead' (and not finished)"
else fail "E2: closed surface without marker renders dead" "$out"; fi

# ═══ E3 — decision 43: backend != cmux renders unknown, never alive/working ═══
{ reg_row tmux %7 e3-old live; } > "$TEAM_REG_DIR/team-e3.tabs"
out=$(status_out e3)
if grep -qi 'unknown' <<<"$out" && ! grep -qiE 'working|drafting|spawned' <<<"$out"; then
  pass "E3: non-cmux backend row renders 'unknown', not alive (decision 43)"
else fail "E3: non-cmux backend renders unknown" "$out"; fi

# ═══ E4 — legacy 7-column row (no marker) with a gone surface is dead, never finished (decision 26 compat) ═══
{ reg_row cmux surface:104 e4-legacy; } > "$TEAM_REG_DIR/team-e4.tabs"
out=$(status_out e4 CMUX_GONE_REFS="surface:104")
if grep -qi 'dead' <<<"$out" && ! grep -q 'finished' <<<"$out"; then
  pass "E4: legacy 7-col row, surface gone -> dead, never finished"
else fail "E4: legacy row gone -> dead" "$out"; fi

# ═══ E5 — decision 4 / 48: colour gate is evaluated on the real stdout, with NO_COLOR and TERM=dumb winning ═══
{ reg_row cmux surface:105 e5-a live; } > "$TEAM_REG_DIR/team-e5.tabs"
forced=$(status_out e5 TEAM_FORCE_COLOR=1 TERM=xterm-256color)
nocol=$(status_out e5 TEAM_FORCE_COLOR=1 TERM=xterm-256color NO_COLOR=1)
dumb=$(status_out e5 TEAM_FORCE_COLOR=1 TERM=dumb)
plain=$(status_out e5 TERM=xterm-256color)
if grep -q $'\033\\[' <<<"$forced" && ! grep -q $'\033' <<<"$nocol" \
   && ! grep -q $'\033' <<<"$dumb" && ! grep -q $'\033' <<<"$plain"; then
  pass "E5: escapes only when forced on a colour TERM; NO_COLOR, TERM=dumb and a non-tty all emit none (decisions 4, 48)"
else fail "E5: colour gate" "forced_esc=$(grep -c $'\033' <<<"$forced") nocolor_esc=$(grep -c $'\033' <<<"$nocol") dumb_esc=$(grep -c $'\033' <<<"$dumb") plain_esc=$(grep -c $'\033' <<<"$plain")"; fi

# ═══ E6 — decision 5: end-to-end UTF-8 step stays column-aligned (fails on the old cut -c1-40 table) ═══
printf 'investigação de fatos\n' > "$RUN/status/acc.txt"
printf '日本語のステップ説明\n' > "$RUN/status/cjk.txt"
{ reg_row cmux surface:106 e6-acc live; reg_row cmux surface:107 e6-cjk live; reg_row cmux surface:108 e6-pla live; } > "$TEAM_REG_DIR/team-e6.tabs"
printf 'plain\n' > "$RUN/status/pla.txt"
out=$(status_out e6)
w=$(grep -E '^  · |ROLE' <<<"$out" | dwidth | sort -u | wc -l | tr -d ' ' || true)
nrows=$(grep -cE '^  · ' <<<"$out" || true)
{ [ "$w" = 1 ] && [ "$nrows" = 3 ] && grep -q 'investigação de fatos' <<<"$out"; } \
  && pass "E6: accented/CJK step strings, all rows same display width end to end (decision 5)" \
  || fail "E6: end-to-end UTF-8 alignment" "distinct widths=$w rows=$nrows
$out"


# ═══ E7 — decision 62: a transient cmux failure is UNKNOWN, never DEAD; sync does not log it at error level ═══
{ reg_row cmux surface:110 e7-a live; reg_row cmux surface:111 e7-b live; } > "$TEAM_REG_DIR/team-e7.tabs"
: > "$CMUX_LOG"
out=$(status_out e7 CMUX_ERR_REFS="surface:110 surface:111")
(cd "$G" && env CMUX_ERR_REFS="surface:110 surface:111" bash "$TEAM_SH" sync e7) >/dev/null 2>&1 || true
if grep -qi 'unknown' <<<"$out" && ! grep -qi 'dead' <<<"$out" && ! grep -q 'NEEDS YOU' <<<"$out" \
   && ! grep -E '^log ' "$CMUX_LOG" | grep -q -- '--level error'; then
  pass "E7: 'Error: timeout' from cmux identify renders unknown, no NEEDS YOU, and sync logs nothing at --level error (decision 62)"
else fail "E7: transient failure" "$out
log: $(grep -E '^log ' "$CMUX_LOG" | head -3)"; fi
: > "$CMUX_LOG"
out=$(status_out e7 CMUX_NOTFOUND_REFS="surface:110 surface:111")
(cd "$G" && env CMUX_NOTFOUND_REFS="surface:110 surface:111" bash "$TEAM_SH" sync e7) >/dev/null 2>&1 || true
{ grep -qi 'dead' <<<"$out" && grep -q 'NEEDS YOU' <<<"$out"; } \
  && pass "E7b: control — a definite not_found still renders dead and pins NEEDS YOU" \
  || fail "E7b: not_found is dead" "$out"

# ═══ E8 — decision 65: the clock survives narrow widths (never a stray '@') ═══
{ reg_row cmux surface:120 e8longteamname-a live; } > "$TEAM_REG_DIR/team-e8longteamname.tabs"
bad=
for cols in 24 30 40 55; do
  hl=$(status_out e8longteamname TEAM_COLS=$cols | head -1)
  grep -q '@' <<<"$hl" && bad+=" cols=$cols:stray-@[$hl]"
  grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}' <<<"$hl" || bad+=" cols=$cols:no-clock[$hl]"
done
[ -z "$bad" ] && pass "E8: header keeps a real HH:MM:SS clock and never a stray '@' at 24-55 cols, with a long team name (decision 65)" \
  || fail "E8: clock at narrow width" "$bad"


# ═══ C1-C5 — workstream C: sidebar pill + severity-coded log, via `team.sh sync` (decisions 13, 14, 21, 22) ═══
sync_run() { (cd "$G" && env "${@:2}" bash "$TEAM_SH" sync "$1" 2>&1) >/dev/null || true; }
RUNC="$G/.team/runs/2026-10-08-c1"; mkdir -p "$RUNC/reports" "$RUNC/status"
{ printf 'cmux surface:130 pane c1-a - - %s %s live 1111 %s\n' "$RUNC" "$G" "$G"
  printf 'cmux surface:131 pane c1-b - - %s %s live 2222 %s\n' "$RUNC" "$G" "$G"; } > "$TEAM_REG_DIR/team-c1.tabs"
: > "$CMUX_LOG"; sync_run c1
pill=$(grep -E '^set-status ' "$CMUX_LOG" | head -1)
pcol=$(sed -n 's/.*--color \(#[0-9A-Fa-f]\{6\}\).*/\1/p' <<<"$pill")
pprio=$(sed -n 's/.*--priority \([0-9][0-9]*\).*/\1/p' <<<"$pill")
if [ -n "$pcol" ] && [ "$(tr a-f A-F <<<"$pcol")" != "#4C8DFF" ] && [ "${pprio:-0}" -ge 1 ] && grep -q -- '--icon' <<<"$pill"; then
  pass "C1: the team pill passes --icon, a non-accent --color (not #4C8DFF) and --priority >= 1 so it outranks the shim's default-0 pill (decisions 13, 21)"
else fail "C1: pill differentiation" "pill=[$pill]"; fi
badlog=$(grep -E '^log ' "$CMUX_LOG" | grep -vE -- '--level (info|progress|success|warning|error)( |$)' || true)
{ grep -qE '^log ' "$CMUX_LOG" && [ -z "$badlog" ]; } \
  && pass "C2: every cmux log call carries an explicit --level (decision 22)" \
  || fail "C2: log levels" "unleveled: $badlog"
: > "$CMUX_LOG"; printf 'x\nPARALLELISM: none\n' > "$RUNC/reports/b.md"; sync_run c1
grep -qE -- '^log .*--level success .*c1-b: reported' "$CMUX_LOG" \
  && pass "C3: a report arriving logs '<title>: reported' at --level success (decision 14)" \
  || fail "C3: report -> success" "$(grep -E '^log ' "$CMUX_LOG")"
: > "$CMUX_LOG"; sync_run c1 CMUX_NOTFOUND_REFS="surface:130"
grep -qE -- '^log .*--level error .*c1-a: dead' "$CMUX_LOG" \
  && pass "C4: a definitely-gone teammate logs '<title>: dead' at --level error (decision 14)" \
  || fail "C4: dead -> error" "$(grep -E '^log ' "$CMUX_LOG")"
: > "$CMUX_LOG"; (cd "$G" && bash "$TEAM_SH" sync --clear c1) >/dev/null 2>&1 || true
{ grep -q '^clear-progress' "$CMUX_LOG" && grep -qE -- '^log .*--level info .*closed' "$CMUX_LOG"; } \
  && pass "C5: sync --clear clears the progress bar and logs 'closed' at --level info (decision 14)" \
  || fail "C5: clear" "$(cat "$CMUX_LOG")"

# ---------------------------------------------------------------------------
# P*  per-teammate self-reported progress, ETA, row keys and click mapping
# ---------------------------------------------------------------------------

# pct is field 8, elapsed-minutes field 9. 70% after 14m -> ~6m remaining.
P_RECS=$'core\tp-core\tWORKING\tdrafting\tdrafting report\t4\t\t70\t14\ntests\tp-tests\tWORKING\tinvestigating\trunning gates\t1\t\t40\t20'
# Same records with no percentage reported at all.
P_NOPCT=$'core\tp-core\tWORKING\tdrafting\tdrafting report\t4\t\t-1\t-1\ntests\tp-tests\tWORKING\tinvestigating\trunning gates\t1\t\t-1\t-1'

f=$(printf '%s\n' "$P_RECS" | frame p 100 0 0 0)
{ grep -q 'PROGRESS' <<<"$f" && grep -qE '70%' <<<"$f" && grep -qE '40%' <<<"$f"; }   && pass "P1: a reported '· NN%' renders a PROGRESS column with a per-row bar"   || fail "P1: progress column" "$f"

{ grep -q 'ETA' <<<"$f" && grep -qE '~6m' <<<"$f" && grep -qE '~30m' <<<"$f"; }   && pass "P2: ETA extrapolates elapsed*(100-pct)/pct and is marked '~' (70%@14m -> ~6m)"   || fail "P2: eta" "$f"

f=$(printf '%s\n' "$P_NOPCT" | frame p 100 0 0 0)
{ ! grep -q 'PROGRESS' <<<"$f" && ! grep -q 'ETA' <<<"$f" && grep -q 'STEP' <<<"$f"; }   && pass "P3: no teammate reporting a % renders no PROGRESS/ETA columns (goldens unchanged)"   || fail "P3: columns absent without pct" "$f"

# A 100% row is complete, so it has no remaining time to extrapolate.
f=$(printf 'd\tp-d\tWORKING\tdrafting\tdone\t1\t\t100\t30\n' | frame p 100 0 0 0)
{ grep -q '100%' <<<"$f" && ! grep -q '~' <<<"$f"; }   && pass "P4: a 100% row shows the full bar and no ETA"   || fail "P4: 100% has no eta" "$f"

# Narrow: the core columns must still win over PROGRESS/ETA (decisions 63-65).
f=$(printf '%s\n' "$P_RECS" | frame p 40 0 0 0)
{ ! grep -q 'PROGRESS' <<<"$f" && grep -q 'ROLE' <<<"$f" && grep -q 'AGE' <<<"$f"   && [ "$(dwidth <<<"$f" | sort -n | tail -1)" -le 40 ]; }   && pass "P5: at 40 cols PROGRESS/ETA drop and ROLE+STATE+AGE survive, no overflow"   || fail "P5: narrow drops progress" "$f"

# An out-of-range percentage must not produce a bar wider than the column.
f=$(printf 'd\tp-d\tWORKING\tdrafting\tgone wild · 999%%\t1\t\t-1\t5\n' | frame p 100 0 0 0)
[ "$(dwidth <<<"$f" | sort -n | tail -1)" -le 100 ]   && pass "P6: a malformed/oversized percentage cannot overflow the pane width"   || fail "P6: pct clamp" "$f"

# keys=1 (interactive monitor only) numbers the rows and prints the hint line.
f=$(printf '%s\n' "$P_RECS" | frame p 100 0 0 1)
{ grep -q '\[1\] ' <<<"$f" && grep -q '\[2\] ' <<<"$f" && grep -q 'focus pane' <<<"$f"; }   && pass "P7: keys=1 numbers each row [N] and shows the keybinding hint"   || fail "P7: row keys" "$f"

f=$(printf '%s\n' "$P_RECS" | frame p 100 0 0 0)
{ ! grep -q '\[1\] ' <<<"$f" && ! grep -q 'focus pane' <<<"$f"; }   && pass "P8: keys=0 (one-shot status) keeps the plain bullet and no hint line"   || fail "P8: no keys when non-interactive" "$f"

# The keymap is the contract between the frame and the input loop: key, role,
# state, and the terminal LINE the row was printed on.
KM="$TEAM_REG_DIR/km.tsv"
printf '%s\n' "$P_RECS" | TEAM_KEYMAP_OUT="$KM" frame p 100 0 0 1 >/dev/null
line1=$(awk -F'\t' '$1=="1"{print $4}' "$KM")
f=$(printf '%s\n' "$P_RECS" | frame p 100 0 0 1)
got=$(sed -n "${line1:-0}p" <<<"$f")
{ [ -n "$line1" ] && grep -q '\[1\] ' <<<"$got"; }   && pass "P9: keymap line numbers address the row the frame actually printed"   || fail "P9: keymap line mapping" "line1=$line1 got=[$got]"

# Alerts come first, so keys are numbered across both blocks without collision.
A_RECS=$'t\tp-t\tWAITING\tinvestigating\tneeds input\t2\t\t-1\t-1\nc\tp-c\tWORKING\tdrafting\twork\t1\t\t70\t14'
printf '%s\n' "$A_RECS" | TEAM_KEYMAP_OUT="$KM" frame p 100 0 0 1 >/dev/null
{ [ "$(awk -F'\t' '$1=="1"{print $2}' "$KM")" = t ]   && [ "$(awk -F'\t' '$1=="2"{print $2}' "$KM")" = c ]   && [ "$(wc -l < "$KM" | tr -d ' ')" = 2 ]; }   && pass "P10: row keys run across NEEDS YOU then the table, one key per teammate"   || fail "P10: key ordering" "$(cat "$KM")"

# _st_click: release on a row focuses it; press, wheel, blank lines and junk do not.
clicks=$(LC_ALL=en_US.UTF-8 bash -c '
  . "$1"; _st_focus_role() { echo "FOCUS:$2"; return 0; }
  for s in "[<0;9;5m" "[<0;9;99m" "[<0;9;5M" "[<64;9;5m" "junk"; do
    _st_click demo "$2" "$s" >/dev/null 2>&1 && echo "acted:$s" || echo "ignored:$s"
  done' _ "$LIB" "$KM" 2>/dev/null || true)
nacted=$(grep -c '^acted:' <<<"$clicks" || true)
{ [ "$nacted" = 1 ] && grep -q 'acted:\[<0;9;5m' <<<"$clicks"; }   && pass "P11: _st_click acts on a release over a row only — press, wheel, blank line and junk ignored"   || fail "P11: click guards" "$clicks"

# The clamp itself lives in the record layer (_st_row), not the formatter: an
# out-of-range "999%" must become 100 and must not be left in the STEP text.
RUNP="$G/.team/runs/2026-10-08-p1"; mkdir -p "$RUNP/reports" "$RUNP/status"
printf 'cmux surface:140 pane p1-w - - %s %s live 9999 %s\n' "$RUNP" "$G" "$G" > "$TEAM_REG_DIR/team-p1.tabs"
printf 'gone wild \xc2\xb7 999%%\n' > "$RUNP/status/w.txt"
rec=$(LC_ALL=en_US.UTF-8 TEAM_REG_DIR="$TEAM_REG_DIR" bash -c '. "$1"; _st_row "$2" "$3" "" p1' _ "$LIB" "cmux surface:140 pane p1-w - - $RUNP $G live 9999 $G" "$RUNP" 2>/dev/null || true)
gotpct=$(cut -f8 <<<"$rec"); gotstep=$(cut -f5 <<<"$rec")
{ [ "${gotpct:-x}" = 100 ] && [ "${gotstep:-x}" = "gone wild" ]; } \
  && pass "P12: record layer clamps '999%' to 100 and strips it from the STEP text" \
  || fail "P12: pct clamp in _st_row" "pct=[$gotpct] step=[$gotstep] rec=[$rec]"

# A percentage the teammate never wrote stays absent (-1), not 0 -- 0% would draw
# an empty bar and claim "no progress", which is a different statement.
printf 'investigating facts\n' > "$RUNP/status/w.txt"
rec=$(LC_ALL=en_US.UTF-8 TEAM_REG_DIR="$TEAM_REG_DIR" bash -c '. "$1"; _st_row "$2" "$3" "" p1' _ "$LIB" "cmux surface:140 pane p1-w - - $RUNP $G live 9999 $G" "$RUNP" 2>/dev/null || true)
[ "$(cut -f8 <<<"$rec")" = "-" ] \
  && pass "P13: a status line with no percentage reports pct '-' (absent), never 0" \
  || fail "P13: absent pct" "rec=[$rec]"

# A teammate pane in the default grid is ~80 cols: PROGRESS and ETA must both fit
# there, and ETA must still appear at 56. Fixed 72/84 gates failed this.
for w in 56 70 80; do
  f=$(printf '%s\n' "$P_RECS" | frame p "$w" 0 0 0)
  { grep -q 'PROGRESS' <<<"$f" && grep -q 'ETA' <<<"$f" \
    && [ "$(dwidth <<<"$f" | sort -n | tail -1)" -le "$w" ]; } \
    || { fail "P14: PROGRESS+ETA at $w cols" "$f"; break; }
  [ "$w" = 80 ] && pass "P14: PROGRESS and ETA both fit at 56/70/80 cols without overflow"
done

echo; echo "status-render: $passes passed, $fails failed"
[ "$fails" = 0 ] || exit 1
echo "all passed ($passes cases)"
