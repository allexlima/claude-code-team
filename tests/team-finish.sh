#!/usr/bin/env bash
# tests/team-finish.sh — finish-on-report lifecycle (rev5 workstream B): finish, spawn --resume,
# registry retention. Source: .team/runs/2026-10-08-rev5/decisions.md (decisions 8-12, 25-30,
# 53-60) + rev5-core's step-3 spec. Hermetic: PATH stubs for cmux/claude, scratch repos, scratch
# TEAM_REG_DIR, scratch HOME. Nothing touches a real pane, session or registry.
# USAGE:  bash tests/team-finish.sh            (current worktree)
#         TEAM_SH=/path/to/team.sh bash tests/team-finish.sh
# Every case names the requirement it covers. Each case uses its own team slug + run dir, so
# fixtures never share state; the summary counts come from the pass/fail calls, not from grep.
set -uo pipefail   # no -e: each case reports PASS/FAIL itself

TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/team.sh}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; passes=0
pass() { echo "PASS  $1"; passes=$((passes+1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }
unset TEAM_MEMBER

mkdir -p "$W/bin"
CMUX_LOG="$W/cmux.log"; : > "$CMUX_LOG"
# cmux stub. Knobs (env): CMUX_TREE_SURFACES "ref<TAB>title" lines; CMUX_GONE_REFS; CMUX_LEADPANE_REFS
# (refs that sit in the lead's pane); CMUX_CLOSE_FAIL=1; CMUX_SPLIT_FAIL=1; CMUX_PROBE_REG=<file>
# (its content is logged at close-surface time, to prove the marker is written BEFORE the close).
cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
n=$(wc -l < "$CMUX_LOG" | tr -d ' ')
surf=""; prev=""
for a; do [ "$prev" = "--surface" ] && surf="$a"; prev="$a"; done
case "$1" in
  ping) echo PONG ;;
  --version) echo "cmux 0.65.0 (108) stub" ;;
  new-split|new-surface)
    [ "${CMUX_SPLIT_FAIL:-}" = 1 ] && { echo "Error: split failed" >&2; exit 1; }
    printf 'OK surface:%d workspace:1\n' "$((900+n))" ;;
  close-surface)
    [ -n "${CMUX_PROBE_REG:-}" ] && echo "AT_CLOSE_ROW: $(cat "$CMUX_PROBE_REG" 2>/dev/null | tr '\n' '|')" >> "$CMUX_LOG"
    [ "${CMUX_CLOSE_FAIL:-}" = 1 ] && { echo "Error: boom" >&2; exit 1; }
    case " $* " in *" --force "*) echo OK ;; *) echo "Error: confirmation_required" >&2; exit 1 ;; esac ;;
  identify)
    if [ -z "$surf" ]; then echo '{"caller":{"pane_ref":"pane-lead","surface_ref":"surface:lead"}}'; exit 0; fi
    case " ${CMUX_ERR_REFS:-} " in *" $surf "*) echo "Error: timeout" >&2; exit 1 ;; esac
    case " ${CMUX_NOTFOUND_REFS:-} " in *" $surf "*) echo "Error: not_found" >&2; exit 1 ;; esac
    case " ${CMUX_GONE_REFS:-} " in
      *" $surf "*) echo '{"caller":{"pane_ref":null}}' ;;
      *) case " ${CMUX_LEADPANE_REFS:-} " in
           *" $surf "*) echo "{\"caller\":{\"pane_ref\":\"pane-lead\",\"surface_ref\":\"$surf\"}}" ;;
           *) echo "{\"caller\":{\"pane_ref\":\"pane-of-$surf\",\"surface_ref\":\"$surf\"}}" ;;
         esac ;;
    esac ;;
  tree)
    jout='{"workspaces":[{"ref":"workspace:1","surfaces":['; first=1
    while IFS=$'\t' read -r ref title; do
      [ -n "$ref" ] || continue
      [ "$first" = 1 ] || jout+=","
      jout+="{\"ref\":\"$ref\",\"title\":\"$title\"}"; first=0
    done <<< "${CMUX_TREE_SURFACES:-}"
    echo "$jout]}]}" ;;
  list-panes) echo '{"panes":[]}' ;;
  list-notifications) echo '[]' ;;
  *) true ;;
esac
SH
chmod +x "$W/bin/cmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/claude"; chmod +x "$W/bin/claude"
export PATH="$W/bin:$PATH" CMUX_LOG

mkdir -p "$W/home/.claude"
cat > "$W/home/.claude/settings.json" <<'JSON'
{"modelPicker":{"options":[
  {"model":"system.ai.claude-opus-5-5","behavesAs":"opus"},
  {"model":"system.ai.claude-sonnet-4-6","behavesAs":"sonnet"},
  {"model":"system.ai.claude-haiku-4-5","behavesAs":"haiku"}]}}
JSON
echo '{"projects":{}}' > "$W/home/.claude.json"
export HOME="$W/home" TEAM_MODELS_FILE="$W/home/.claude/settings.json" TEAM_ROLES_DIR="$W/home/.claude/team/roles"
export CMUX_WORKSPACE_ID=ws-test CMUX_SURFACE_ID=surface:lead
export TEAM_REG_DIR="$W/reg"; mkdir -p "$TEAM_REG_DIR"

_git() { git -c user.email=t@t -c user.name=T "$@"; }
SID=11111111-2222-3333-4444-555555555555

# fixture <name>: scratch repo $R (physical path), run dir $RUN with tasks.md, team slug $T, registry $REG
fixture() {
  T="f$$$1"; R="$W/$1"; mkdir -p "$R"; _git -C "$R" init -q; _git -C "$R" commit -q --allow-empty -m init
  R=$(cd "$R" && pwd -P)
  RUN="$R/.team/runs/2026-10-08-$T"; mkdir -p "$RUN/prompts" "$RUN/reports" "$RUN/status"
  : > "$RUN/tasks.md"; REG="$TEAM_REG_DIR/team-$T.tabs"; : > "$REG"; : > "$CMUX_LOG"
  TREE= CLOSEFAIL= PROBE=   # per-case knobs read by fin(); reset so one case never leaks into the next
}
# row <ref> <role> [state] [sid] [cwd] [layout]  -> appends an 11-col registry row
row() {
  printf 'cmux %s %s %s-%s - - %s %s %s %s %s\n' "$1" "${6:-pane}" "$T" "$2" "$RUN" "$R" "${3:-live}" "${4:-$SID}" "${5:-$R}" >> "$REG"
}
report() { printf '# Report\nFINDINGS: x\nPARALLELISM: none\n' > "$RUN/reports/$1.md"; }
tick() { printf -- '- [x] %s-%s: done\n' "$T" "$1" >> "$RUN/tasks.md"; }
tm() { (cd "$R" && "$@"); }
fin() { (cd "$R" && env CMUX_TREE_SURFACES="$TREE" CMUX_CLOSE_FAIL="$CLOSEFAIL" CMUX_PROBE_REG="$PROBE" bash "$TEAM_SH" finish "$T" "$1" 2>&1); }
col9() { awk -v t="$T-$1" '$4==t {print $9}' "$REG"; }

# ═══ F1-F5: finish refuses (exit 2) and changes nothing — decisions 12, 29 ═══
fixture f1; row surface:11 w; tick w; before=$(cat "$REG")
out=$(fin w); rc=$?
{ [ $rc = 2 ] && grep -q "finish: refused" <<<"$out" && [ "$(cat "$REG")" = "$before" ] && ! grep -q close-surface "$CMUX_LOG"; } \
  && pass "F1: finish refuses (rc 2, row untouched, no close) when the report is missing (decision 29)" \
  || fail "F1: missing report" "rc=$rc out=$out"

fixture f2; row surface:12 w; tick w; : > "$RUN/reports/w.md"
out=$(fin w); rc=$?
{ [ $rc = 2 ] && grep -q "finish: refused" <<<"$out" && [ "$(col9 w)" = live ]; } && pass "F2: finish refuses an empty report (decision 29)" || fail "F2: empty report" "rc=$rc out=$out"

fixture f3; row surface:13 w; tick w; printf '# Report\nFINDINGS: half written\n' > "$RUN/reports/w.md"
out=$(fin w); rc=$?
{ [ $rc = 2 ] && [ "$(col9 w)" = live ] && grep -q 'PARALLELISM' <<<"$out"; } \
  && pass "F3: finish refuses a report without PARALLELISM: — fails closed on a truncated write (decision 29)" \
  || fail "F3: no PARALLELISM" "rc=$rc out=$out"

fixture f3b; row surface:14 w; tick w; printf '# Report\n**PARALLELISM:** none\n' > "$RUN/reports/w.md"; TREE="surface:14	$T-w"; out=$(fin w); rc=$?
{ [ $rc = 0 ] && [ "$(col9 w)" = finished ]; } \
  && pass "F3b: a markdown-bold '**PARALLELISM:**' header satisfies the guard" \
  || fail "F3b: bold header" "rc=$rc out=$out"

fixture f4; row surface:15 w; report w   # no tasks.md checkbox
out=$(fin w); rc=$?
{ [ $rc = 2 ] && [ "$(col9 w)" = live ] && grep -q 'tasks.md' <<<"$out"; } \
  && pass "F4: finish refuses without the '- [x] <title>:' tasks.md line — second independent artifact (decision 29)" \
  || fail "F4: no checkbox" "rc=$rc out=$out"

# ═══ F6: dirty / unreadable worktree refuses (decision 30) ═══
fixture f6; WT="$R/.team/worktrees/$T-w"; _git -C "$R" worktree add -q -b "team/$T-w" "$WT" HEAD
WT=$(cd "$WT" && pwd -P); row surface:16 w live "$SID" "$WT"; report w; tick w
echo dirty > "$WT/uncommitted.txt"
out=$(fin w); rc=$?
{ [ $rc = 2 ] && [ "$(col9 w)" = live ] && ! grep -q close-surface "$CMUX_LOG" && grep -qi 'uncommitted' <<<"$out"; } \
  && pass "F6: finish refuses a --worktree teammate with uncommitted changes; nothing closed (decision 30)" \
  || fail "F6: dirty worktree" "rc=$rc out=$out"
rm "$WT/uncommitted.txt"; TREE="surface:16	$T-w"; out=$(fin w); rc=$?
{ [ $rc = 0 ] && [ "$(col9 w)" = finished ]; } \
  && pass "F6b: once the worktree is clean, finish proceeds" || fail "F6b: clean worktree proceeds" "rc=$rc out=$out"

fixture f6d; WT="$R/.team/worktrees/$T-w"; _git -C "$R" worktree add -q -b "team/$T-w" "$WT" HEAD
WT=$(cd "$WT" && pwd -P); row surface:18 w live "$SID" "$WT"; report w; tick w
echo scratch > "$WT/scratch-notes.txt"   # untracked only: no tracked change
out=$(fin w); rc=$?
{ [ $rc = 2 ] && [ "$(col9 w)" = live ]; } \
  && pass "F6d: an UNTRACKED file in the worktree counts as dirty — finish refuses (decision 71)" \
  || fail "F6d: untracked counts as dirty" "rc=$rc out=$out"
grep -q 'scratch-notes.txt' <<<"$out" \
  && pass "F6e: the refusal NAMES the offending path so the lead can tell scratch from real work (decision 71)" \
  || fail "F6e: refusal names the path" "out=$out"

fixture f6c; WT="$R/.team/worktrees/$T-w"; mkdir -p "$WT"   # under the worktrees dir but NOT a git worktree: git status fails
row surface:17 w live "$SID" "$WT"; report w; tick w
out=$(fin w); rc=$?
{ [ $rc = 2 ] && grep -q "finish: refused" <<<"$out" && [ "$(col9 w)" = live ]; } \
  && pass "F6c: git status failing in the worktree fails closed (rc 2, row untouched)" || fail "F6c: git status failure" "rc=$rc out=$out"

# ═══ F7-F9: success path and ordering — decision 29 (marker BEFORE close, retryable) ═══
fixture f7; row surface:21 w; report w; tick w
TREE="surface:21	$T-w"; PROBE="$REG"; out=$(fin w); rc=$?
c=$(awk -v t="$T-w" '$4==t' "$REG")
{ [ $rc = 0 ] && [ "$(awk '{print $9,$10,$11}' <<<"$c")" = "finished $SID $R" ] && grep -q 'close-surface --surface surface:21 --force' "$CMUX_LOG"; } \
  && pass "F7: finish marks the row finished (session id + cwd kept) and closes that one pane with --force (decision 8)" \
  || fail "F7: success path" "rc=$rc row=$c out=$out"
at=$(grep AT_CLOSE_ROW "$CMUX_LOG" | head -1)
grep -q ' finished ' <<<"$at" \
  && pass "F8: the finished marker is already on disk when close-surface runs (decision 29: marker before close)" \
  || fail "F8: marker-before-close" "at-close registry: $at"

fixture f9; row surface:22 w; report w; tick w
TREE="surface:22	$T-w"; CLOSEFAIL=1; out=$(fin w); rc=$?
{ [ $rc = 1 ] && [ "$(col9 w)" = finished ]; } \
  && pass "F9: a failing close leaves a finished row and exits 1 (retryable, decision 29)" \
  || fail "F9: failing close" "rc=$rc col9=$(col9 w) out=$out"
CLOSEFAIL=; TREE="surface:22	$T-w"; out=$(fin w); rc=$?
{ [ $rc = 0 ] && grep -q 'already finished; retrying the close' <<<"$out"; } \
  && pass "F9b: re-running finish says 'already finished; retrying the close' and succeeds" \
  || fail "F9b: retry" "rc=$rc out=$out"

# ═══ F10: round-2 baseline (decision 29: round 2 appends to the same report) ═══
fixture f10; report w; tick w; printf 'prompt\n' > "$RUN/prompts/w.md"
tm env CMUX_TREE_SURFACES= bash "$TEAM_SH" spawn "$T" w "$RUN/prompts/w.md" sonnet >/dev/null 2>&1
rnd="$TEAM_REG_DIR/team-$T-w.round"
{ [ -f "$rnd" ] && grep -Eq '^[0-9]+ [0-9]+$' "$rnd" && [ "$(cut -d' ' -f2 "$rnd")" = 1 ]; } \
  && pass "F10a: spawn records '<bytes> <PARALLELISM: line count>' of the existing report in the .round sidecar (decision 66)" \
  || fail "F10a: .round sidecar" "$(cat "$rnd" 2>&1)"
ref=$(awk '{print $2}' "$REG" | head -1)
TREE="$ref	$T-w"; out=$(fin w); rc=$?
{ [ $rc = 2 ] && grep -q 'did not grow' <<<"$out" && [ "$(col9 w)" = live ]; } \
  && pass "F10b: round 2 — finish refuses a report that did not grow since spawn" || fail "F10b: unchanged report" "rc=$rc out=$out"
printf 'round 2 notes, still working\n' >> "$RUN/reports/w.md"
out=$(fin w); rc=$?
{ [ $rc = 2 ] && grep -q 'PARALLELISM' <<<"$out" && [ "$(col9 w)" = live ]; } \
  && pass "F10c: round 2 — an append WITHOUT a new PARALLELISM: is refused (the old header does not count)" || fail "F10c: append w/o PARALLELISM" "rc=$rc out=$out"
# F10c2 (decision 66): round-2 text inserted ABOVE the old trailer grows the file but adds no trailer
cp "$RUN/reports/w.md" "$W/f10.saved"
python3 - "$RUN/reports/w.md" <<'PYI'
import sys; p=sys.argv[1]; t=open(p).read(); i=t.index("PARALLELISM:"); open(p,"w").write(t[:i]+"round 2 block inserted above the old trailer\n"+t[i:])
PYI
out=$(fin w); rc=$?
{ [ $rc = 2 ] && [ "$(col9 w)" = live ]; } \
  && pass "F10c2: a round-2 block inserted ABOVE the old PARALLELISM: line is refused — the trailer COUNT must rise (decision 66)" \
  || fail "F10c2: insert-above bypass" "rc=$rc out=$out"
# F10c3 (decision 73): quoting a peer's trailer (blockquote) is not this teammate's own trailer
cp "$W/f10.saved" "$RUN/reports/w.md"; printf 'peer said:\n> PARALLELISM: 4 subagents\n' >> "$RUN/reports/w.md"
out=$(fin w); rc=$?
{ [ $rc = 2 ] && [ "$(col9 w)" = live ]; } \
  && pass "F10c3: a quoted '> PARALLELISM:' line from a peer's report does not satisfy the guard (decision 73)" \
  || fail "F10c3: blockquoted trailer counted" "rc=$rc col9=$(col9 w) out=$out"
cp "$W/f10.saved" "$RUN/reports/w.md"
printf 'PARALLELISM: 2 subagents\n' >> "$RUN/reports/w.md"
TREE="$ref	$T-w"; out=$(fin w); rc=$?
{ [ $rc = 0 ] && [ "$(col9 w)" = finished ] && ! grep -q 'already finished' <<<"$out"; } \
  && pass "F10d: round 2 — an append WITH a new PARALLELISM: is accepted" || fail "F10d: append with PARALLELISM" "rc=$rc out=$out"
{ [ "$(col9 w)" = finished ] && [ ! -f "$rnd" ]; } && pass "F10e: finish removes the .round sidecar once it succeeds" || fail "F10e: sidecar removed"

# ═══ F11: spawn --resume (decisions 9, 32, 33, 53-58) ═══
fixture f11; row surface:31 w finished "$SID" "$R"; printf 'next round: do X\n' > "$RUN/prompts/w.md"
out=$(tm bash "$TEAM_SH" spawn --resume "$T" w "$RUN/prompts/w.md" sonnet 2>&1); rc=$?
cmdline=$(grep -E 'new-split|new-surface' "$CMUX_LOG" | head -1)
if [ $rc = 0 ] && grep -q -- "claude --resume $SID" <<<"$cmdline" && grep -q -- '--permission-mode' <<<"$cmdline" \
   && ! grep -q -- '--session-id' <<<"$cmdline" && ! grep -q -- '--append-system-prompt-file' <<<"$cmdline" \
   && grep -q "cd $R" <<<"$cmdline"; then
  pass "F11: --resume runs 'claude --resume <sid>' in the recorded cwd, re-passes --permission-mode, no --session-id / system prompt (decisions 32, 33, 35)"
else fail "F11: resume command" "rc=$rc cmd=$cmdline out=$out"; fi
{ [ "$(awk -v t="$T-w" '$4==t' "$REG" | wc -l | tr -d ' ')" = 1 ] && [ "$(col9 w)" = live ]; } \
  && pass "F11b: the resumed session replaces the finished row (one live row, same title)" || fail "F11b: row replaced" "$(cat "$REG")"

fixture f11c; out=$(tm bash "$TEAM_SH" spawn --resume "$T" ghost "$RUN/prompts/w.md" sonnet 2>&1); rc=$?
printf 'p\n' > "$RUN/prompts/w.md"; out=$(tm bash "$TEAM_SH" spawn --resume "$T" ghost "$RUN/prompts/w.md" sonnet 2>&1); rc=$?
[ $rc = 3 ] && pass "F11c: --resume with no recorded row/session exits 3" || fail "F11c: resume w/o row" "rc=$rc out=$out"

fixture f11d; row surface:32 w finished "$SID" "$W/does-not-exist"; printf 'p\n' > "$RUN/prompts/w.md"
out=$(tm bash "$TEAM_SH" spawn --resume "$T" w "$RUN/prompts/w.md" sonnet 2>&1); rc=$?
{ [ $rc = 3 ] && [ "$(col9 w)" = finished ]; } \
  && pass "F11d: --resume when the recorded cwd is gone exits 3 and keeps the row (fall back to a fresh spawn)" \
  || fail "F11d: resume with cwd gone" "rc=$rc out=$out"

# ═══ F12: duplicate-title guard vs finished rows (decision 27) ═══
fixture f12; row surface:41 w finished; printf 'p\n' > "$RUN/prompts/w.md"
out=$(tm bash "$TEAM_SH" spawn "$T" w "$RUN/prompts/w.md" sonnet 2>&1); rc=$?
{ [ $rc = 0 ] && ! grep -q 'already live' <<<"$out"; } \
  && pass "F12: a fresh spawn over a FINISHED row of the same title is not blocked by the duplicate guard (decision 27)" \
  || fail "F12: dup guard vs finished" "rc=$rc out=$out"
fixture f12b; row surface:42 w live; printf 'p\n' > "$RUN/prompts/w.md"
CMUX_GONE_REFS= out=$(tm bash "$TEAM_SH" spawn "$T" w "$RUN/prompts/w.md" sonnet 2>&1); rc=$?
{ [ $rc = 2 ] && grep -q 'already live' <<<"$out"; } \
  && pass "F12b: control — a LIVE duplicate is still refused (exit 2, 'already live')" || fail "F12b: live dup refused" "rc=$rc out=$out"

# ═══ F13: a spawn whose split fails keeps the old finished row (decision 60) ═══
fixture f13; row surface:51 w finished; printf 'p\n' > "$RUN/prompts/w.md"; before=$(cat "$REG")
out=$(tm env CMUX_SPLIT_FAIL=1 bash "$TEAM_SH" spawn --resume "$T" w "$RUN/prompts/w.md" sonnet 2>&1); rc=$?
{ [ $rc != 0 ] && grep -q "split failed" <<<"$out" && [ "$(cat "$REG")" = "$before" ]; } \
  && pass "F13: a failed new-split leaves the finished row (and its session id) intact (decision 60)" \
  || fail "F13: failed spawn keeps row" "rc=$rc reg=$(cat "$REG")"

# ═══ F14: cap counts live teammates only (decision 27) ═══
fixture f14; for i in 1 2 3 4 5 6 7 8; do row "surface:6$i" "x$i" finished; done; printf 'p\n' > "$RUN/prompts/w.md"
out=$(tm bash "$TEAM_SH" spawn "$T" w "$RUN/prompts/w.md" sonnet 2>&1); rc=$?
[ $rc = 0 ] && pass "F14: 8 finished rows do not consume the 8-teammate cap (_mates excludes them)" || fail "F14: finished rows vs cap" "rc=$rc out=$out"
fixture f14b; for i in 1 2 3 4 5 6 7 8; do row "surface:7$i" "x$i" live; done; printf 'p\n' > "$RUN/prompts/w.md"
out=$(tm bash "$TEAM_SH" spawn "$T" w "$RUN/prompts/w.md" sonnet 2>&1); rc=$?
[ $rc = 4 ] && pass "F14b: control — 8 live rows still hit the cap (exit 4)" || fail "F14b: cap with 8 live" "rc=$rc out=$out"

# ═══ F15: prune / reap / close vs finished rows (decisions 25, 59) ═══
fixture f15; row surface:81 a finished; row surface:82 b live; printf 'p\n' > "$RUN/prompts/c.md"
out=$(tm env CMUX_GONE_REFS="surface:81 surface:82" bash "$TEAM_SH" spawn "$T" c "$RUN/prompts/c.md" sonnet 2>&1); rc=$?
{ [ -n "$(col9 a)" ] && [ "$(col9 a)" = finished ] && [ -z "$(awk -v t="$T-b" '$4==t' "$REG")" ]; } \
  && pass "F15: spawn's prune drops the dead LIVE row but keeps the finished row and its session id (decision 25)" \
  || fail "F15: prune vs finished" "reg=$(cat "$REG")"

fixture f15b; row surface:83 a finished; : > "$CMUX_LOG"
out=$(tm bash "$TEAM_SH" reap --yes 2>&1); rc=$?
{ [ "$(col9 a)" = finished ] && ! grep -q 'close-surface --surface surface:83' "$CMUX_LOG"; } \
  && pass "F15b: reap never closes or drops a finished row" || fail "F15b: reap vs finished" "rc=$rc reg=$(cat "$REG" 2>&1) out=$out"

fixture f15c; row surface:84 a finished; row surface:85 b live; echo "5 5" > "$TEAM_REG_DIR/team-$T-a.round"
TREE="surface:85	$T-b" out=$(tm env CMUX_TREE_SURFACES="surface:85	$T-b" bash "$TEAM_SH" close "$T" 2>&1); rc=$?
{ [ ! -e "$REG" ] && [ ! -e "$TEAM_REG_DIR/team-$T-a.round" ] && grep -q 'close-surface --surface surface:85' "$CMUX_LOG" \
  && ! grep -q 'close-surface --surface surface:84' "$CMUX_LOG"; } \
  && pass "F15c: close drops finished rows without a pane, closes live ones, removes the registry and .round sidecars (decision 59)" \
  || fail "F15c: close" "rc=$rc reg=$(ls "$REG" 2>&1) round=$(ls "$TEAM_REG_DIR/team-$T-a.round" 2>&1) out=$out"

# ═══ F16-F17: list words and show (decision 10) ═══
fixture f16; row surface:91 a finished; row surface:92 b live; row surface:93 c live; row surface:94 d live pane
out=$(tm env CMUX_GONE_REFS="surface:93" CMUX_LEADPANE_REFS="surface:94" bash "$TEAM_SH" list "$T" 2>&1); rc=$?
{ grep -q "$T-a  finished" <<<"$out" && grep -q "$T-b  working (pane-of-surface:92)" <<<"$out" \
  && grep -q "$T-c  dead" <<<"$out" && grep -q "$T-d  tab (in your pane, running)" <<<"$out"; } \
  && pass "F16: list words — working (<pane>) / tab (in your pane, running) / finished / dead" \
  || fail "F16: list words" "rc=$rc out=$out"

: > "$CMUX_LOG"
out=$(tm bash "$TEAM_SH" show "$T" b 2>&1); rc=$?
{ [ $rc = 0 ] && grep -q 'move-surface --surface surface:92 --pane pane-of-surface:92 --focus true' "$CMUX_LOG"; } \
  && pass "F17: show logs 'move-surface --surface <ref> --pane <its pane> --focus true' (decision 10)" \
  || fail "F17: show focuses" "rc=$rc out=$out log=$(cat "$CMUX_LOG")"
out=$(tm bash "$TEAM_SH" show "$T" a 2>&1); rc=$?
[ $rc = 3 ] && pass "F17b: show on a finished teammate exits 3 (no pane to surface)" || fail "F17b: show finished" "rc=$rc out=$out"

# ═══ F19: transient cmux failure is never "dead"/"gone" (decisions 62, 70) ═══
fixture f19; row surface:95 a; row surface:96 b
out=$(tm env CMUX_ERR_REFS="surface:95" CMUX_NOTFOUND_REFS="surface:96" bash "$TEAM_SH" list "$T" 2>&1); rc=$?
{ ! grep -q "$T-a  dead" <<<"$out" && grep -q "$T-b  dead" <<<"$out"; } \
  && pass "F19: list — 'Error: timeout' is NOT dead, a definite not_found still is (decisions 62, 70)" \
  || fail "F19: list transient vs not_found" "rc=$rc out=$out"
out=$(tm env CMUX_ERR_REFS="surface:95" bash "$TEAM_SH" show "$T" a 2>&1); rc=$?
! grep -qi 'gone; respawn' <<<"$out" \
  && pass "F19b: show — a transient failure never says 'is gone; respawn it' (decision 70: that sends the lead to kill a busy teammate)" \
  || fail "F19b: show transient" "rc=$rc out=$out"
out=$(tm env CMUX_NOTFOUND_REFS="surface:96" bash "$TEAM_SH" show "$T" b 2>&1); rc=$?
{ [ $rc = 3 ] && grep -qi 'gone' <<<"$out"; } \
  && pass "F19c: control — show on a definite not_found still says gone (exit 3)" || fail "F19c: show not_found" "rc=$rc out=$out"

# ═══ F18: park is gone (decision 10) ═══
out=$(tm bash "$TEAM_SH" park "$T" b 2>&1); rc=$?
[ $rc = 2 ] && pass "F18: 'team.sh park' is an unknown subcommand (exit 2) — removed in rev5 (decision 10)" || fail "F18: park removed" "rc=$rc out=$out"

echo; echo "team-finish: $passes passed, $fails failed"
[ "$fails" = 0 ] || exit 1
echo "all passed ($passes cases)"
