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
cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ping) echo PONG ;;
  --version) echo "cmux 0.65.0 (108) stub" ;;
  identify)
    surf=""; prev=""
    for a; do [ "$prev" = "--surface" ] && surf="$a"; prev="$a"; done
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

echo; echo "status-render: $passes passed, $fails failed"
[ "$fails" = 0 ] || exit 1
echo "all passed ($passes cases)"
