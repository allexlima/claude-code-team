#!/usr/bin/env bash
# tests/team-build.sh — Phase B acceptance tests for /team
# Source: .team/runs/2026-10-07-rev2/synthesis.md — Consensus bugs, Designs A–D, P0/P1 items.
# Each case is labelled with its item id (bug#N, NN, design-X).
# USAGE:
#   bash tests/team-build.sh                        (current worktree)
#   TEAM_SH=/path/to/team.sh bash tests/team-build.sh  (specific version)
# BASE VERIFICATION: every case must FAIL on base 52c569a. Run:
#   TEAM_SH=/Users/allex.lima/.claude/skills/team/team.sh bash tests/team-build.sh
set -euo pipefail

TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/team.sh}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }

# ── PATH stubs — never open real panes, sessions, or terminals ──
mkdir -p "$W/bin"
CMUX_LOG="$W/cmux.log"; TMUX_LOG="$W/tmux.log"; CLAUDE_LOG="$W/claude.log"
_reset_logs() { : > "$CMUX_LOG" > "$TMUX_LOG" > "$CLAUDE_LOG"; }
_reset_logs

cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
n=$(wc -l < "$CMUX_LOG" 2>/dev/null || echo 1)
case "$1" in
  new-split|new-surface) printf 'ok surface:%d\n' "$n" ;;
  close-surface) case " $* " in *" --force "*) echo "OK" ;; *) echo "Error: confirmation_required" >&2; exit 1 ;; esac ;;
  identify)
    surf=""
    prev=""
    for a; do [ "$prev" = "--surface" ] && surf="$a"; prev="$a"; done
    echo "{\"caller\":{\"pane_ref\":\"pane-stub\",\"surface_ref\":\"$surf\"}}"
    ;;
  rename-tab|tab-title|move-surface|workspace-title|new-split-*) true ;;
esac
SH
chmod +x "$W/bin/cmux"

cat > "$W/bin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
  new-session|new-window|split-window) echo "0" ;;
  has-session) exit 1 ;;
esac
SH
chmod +x "$W/bin/tmux"

cat > "$W/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_LOG"
SH
chmod +x "$W/bin/claude"

export PATH="$W/bin:$PATH"
export CMUX_LOG TMUX_LOG CLAUDE_LOG

# ── Stub model list via HOME override ──
mkdir -p "$W/home/.claude/team/roles"
cat > "$W/home/.claude/settings.json" <<'JSON'
{"modelPicker":{"options":[
  {"model":"system.ai.claude-opus-5-5","behavesAs":"opus"},
  {"model":"system.ai.claude-opus-4-8","behavesAs":"opus"},
  {"model":"system.ai.claude-sonnet-4-6","behavesAs":"sonnet"},
  {"model":"system.ai.claude-haiku-4-5","behavesAs":"haiku"},
  {"model":"system.ai.glm-5-3","behavesAs":"haiku"}
]}}
JSON
export HOME="$W/home"
export TEAM_ROLES_DIR="$W/home/.claude/team/roles"
# TEAM_MODELS_FILE: once rev3-core implements this override, it is the only file
# read for modelPicker.options, replacing both default paths. Set it now so tests
# work correctly on the implementation without being affected by system
# managed-settings.json (which uses [1m]-suffixed model IDs).
export TEAM_MODELS_FILE="$W/home/.claude/settings.json"
# Pre-trust dir so spawn doesn't fail at python3 ~/.claude.json step
cat > "$W/home/.claude.json" <<'JSON'
{"projects":{}}
JSON
# Force cmux backend (spawn checks CMUX_WORKSPACE_ID + cmux on PATH)
export CMUX_WORKSPACE_ID="ws-test"
export CMUX_SURFACE_ID="surface:lead"

# ── Git helpers ──
_git() { git -c user.email=t@t -c user.name=T "$@"; }
_mkgit() {
  local d="$1"; mkdir -p "$d"
  _git -C "$d" init -q
  _git -C "$d" commit -q --allow-empty -m init
}
_mkgit0() {  # zero-commit repo
  local d="$1"; mkdir -p "$d"
  _git -C "$d" init -q
}

# Make a minimal run directory tree (prompts/ sibling to reports/, status/)
_mkrun() {
  local run="$1"; mkdir -p "$run/prompts" "$run/reports" "$run/status"
}

# ══════════════════════════════════════════════════════════════════
# bug#1 — worktree root bug: facts-lint and role from inside a worktree
# Fix: _root() uses `git worktree list --porcelain` instead of
# `git rev-parse --show-toplevel` (which returns the worktree path).
# ══════════════════════════════════════════════════════════════════
{
  R="$W/b1main"; _mkgit "$R"
  mkdir -p "$R/.team/roles"
  printf '# TestRole\n**Lens:** test\n' > "$R/.team/roles/b1role.md"
  printf '# Facts\n\n- fact one — evidence: team.sh:1 @abcdef1 — 2026-01-01, run r1\n' > "$R/.team/facts.md"

  wt="$R/.team/worktrees/b1-worker"
  _git -C "$R" worktree add -q -b "team/b1-worker" "$wt" HEAD

  # facts-lint from worktree must NOT exit 3 (old code: root=worktree, no .team/facts.md)
  out=$(cd "$wt" && bash "$TEAM_SH" facts-lint 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && pass "bug#1: facts-lint works from worktree" \
    || fail "bug#1: facts-lint works from worktree" "rc=$rc out=${out:0:160}"

  # role from worktree must find project copy — path must NOT go through worktrees/
  out=$(cd "$wt" && bash "$TEAM_SH" role b1role 2>&1) && rc=0 || rc=$?
  [[ "$out" == *"$R/.team/roles/b1role.md"* ]] \
    && pass "bug#1: role finds project copy from worktree" \
    || fail "bug#1: role finds project copy from worktree" "rc=$rc out=$out"
}

# ══════════════════════════════════════════════════════════════════
# bug#2a — gitignore newline: init adds entries on their own lines
# ══════════════════════════════════════════════════════════════════
{
  R="$W/b2a"; _mkgit "$R"
  # File with no trailing newline (common when editors omit it)
  printf 'existing-entry' > "$R/.gitignore"
  (cd "$R" && bash "$TEAM_SH" init myteam >/dev/null 2>&1) || true
  content=$(cat "$R/.gitignore")
  # Both entries must appear on separate lines (not "existing-entry.team/")
  both=0
  printf '%s\n' "$content" | grep -qx 'existing-entry' && printf '%s\n' "$content" | grep -q '\.team/' && both=1
  [ "$both" = 1 ] && pass "bug#2a: gitignore entries on separate lines after init" \
    || fail "bug#2a: gitignore entries on separate lines after init" "content=$(printf '%q' "$content")"
}

# ══════════════════════════════════════════════════════════════════
# bug#2d — prompt file check: spawn refuses before touching cmux
# ══════════════════════════════════════════════════════════════════
{
  R="$W/b2d"; _mkgit "$R"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn myteam myrole /nonexistent/no_such_file.md \
    sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" != 0 ] && [ ! -s "$CMUX_LOG" ] \
    && pass "bug#2d: spawn refuses missing prompt file before cmux" \
    || fail "bug#2d: spawn refuses missing prompt file before cmux" \
       "rc=$rc cmuxlog=$(cat "$CMUX_LOG") out=${out:0:120}"
}

# ══════════════════════════════════════════════════════════════════
# bug#2d variant — spawn exit code 2 on unreadable prompt
# ══════════════════════════════════════════════════════════════════
{
  R="$W/b2d2"; _mkgit "$R"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn myteam myrole /nonexistent/no_such.md \
    sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] && pass "bug#2d: spawn exits 2 for unreadable prompt" \
    || fail "bug#2d: spawn exits 2 for unreadable prompt" "rc=$rc"
}

# ══════════════════════════════════════════════════════════════════
# bug#2e — slug reuse: spawn appends to existing registry, not wipes it
# ══════════════════════════════════════════════════════════════════
{
  R="$W/b2e"; _mkgit "$R"
  pf="$R/p.md"; printf 'test prompt\n' > "$pf"
  TM="b2e$$"
  # Pre-populate registry with one existing entry
  printf 'cmux surface:99 pane %s-role1 sonnet -\n' "$TM" \
    > "/tmp/team-$TM.tabs"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" role2 "$pf" sonnet) \
    >/dev/null 2>&1 && sprc=0 || sprc=$?
  lines=$(wc -l < "/tmp/team-$TM.tabs" 2>/dev/null || echo 0)
  rm -f "/tmp/team-$TM.tabs"
  [ "$lines" -ge 2 ] && pass "bug#2e: spawn appends to existing registry" \
    || fail "bug#2e: spawn appends to existing registry" "lines=$lines sprc=$sprc"
}

# ══════════════════════════════════════════════════════════════════
# bug#2f — zero-commit repo + --worktree refused (exit 2)
# ══════════════════════════════════════════════════════════════════
{
  R="$W/b2f"; _mkgit0 "$R"
  pf="$W/p_b2f.md"; printf 'prompt\n' > "$pf"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn --worktree myteam myrole "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" != 0 ] && [ ! -s "$CMUX_LOG" ] \
    && pass "bug#2f: zero-commit repo + --worktree refused before cmux" \
    || fail "bug#2f: zero-commit repo + --worktree refused before cmux" \
       "rc=$rc cmuxlog=$(cat "$CMUX_LOG")"
}

# ══════════════════════════════════════════════════════════════════
# bug#8 — --help exact match: "contains --help" was too broad
# Fix: SKILL.md:9 should match the exact string "--help" not "contains --help".
# Verify team.sh itself: `spawn something --help foo` must not print help.
# (team.sh already dispatches --help before spawn; this tests SKILL guidance only.)
# We test that 'team.sh --help' exits 0 and that unknown subcommands with
# "--help" in their name exit 2, not 0.
# ══════════════════════════════════════════════════════════════════
{
  out=$(bash "$TEAM_SH" --help 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [[ "$out" == *"team.sh spawn"* ]] \
    && pass "bug#8: --help exits 0 with usage" \
    || fail "bug#8: --help exits 0 with usage" "rc=$rc"

  # A subcommand that merely contains "--help" should not be mistaken for --help
  out2=$(bash "$TEAM_SH" spawn --help 2>&1) && rc2=0 || rc2=$?
  [ "$rc2" != 0 ] && pass "bug#8: spawn --help exits non-0 (not treated as global --help)" \
    || fail "bug#8: spawn --help exits non-0" "rc=$rc2 out=${out2:0:80}"
}

# ══════════════════════════════════════════════════════════════════
# Design B — pick-model subcommand (model-routing report)
# `team.sh pick-model <tier>`: exits 0 exact match, 1 fallback, 2 bad tier, 3 no match
# ══════════════════════════════════════════════════════════════════

# pick-model sonnet → system.ai.claude-sonnet-4-6
{
  out=$(bash "$TEAM_SH" pick-model sonnet 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [ "$out" = "system.ai.claude-sonnet-4-6" ] \
    && pass "design-B: pick-model sonnet → correct id" \
    || fail "design-B: pick-model sonnet → correct id" "rc=$rc out=$out"
}

# pick-model haiku → system.ai.claude-haiku-4-5 (GLM/Kimi not returned by pick-model)
{
  out=$(bash "$TEAM_SH" pick-model haiku 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [ "$out" = "system.ai.claude-haiku-4-5" ] \
    && pass "design-B: pick-model haiku → claude-family only" \
    || fail "design-B: pick-model haiku → claude-family only" "rc=$rc out=$out"
}

# pick-model opus → newest opus (5.5, not 4-8) — design B: newest version wins
{
  out=$(bash "$TEAM_SH" pick-model opus 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [ "$out" = "system.ai.claude-opus-5-5" ] \
    && pass "design-B: pick-model opus → newest version (5.5 not 4-8)" \
    || fail "design-B: pick-model opus → newest version (5.5 not 4-8)" "rc=$rc out=$out"
}

# pick-model badtier → exit 2
{
  out=$(bash "$TEAM_SH" pick-model badtier 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] && pass "design-B: pick-model badtier → exit 2" \
    || fail "design-B: pick-model badtier → exit 2" "rc=$rc"
}

# pick-model fallback: create a stub with only haiku, ask for sonnet → exit 1 + stderr
{
  mkdir -p "$W/fallback_home/.claude"
  cat > "$W/fallback_home/.claude/settings.json" <<'JSON'
{"modelPicker":{"options":[
  {"model":"system.ai.claude-haiku-4-5","behavesAs":"haiku"}
]}}
JSON
  out=$(HOME="$W/fallback_home" TEAM_ROLES_DIR="$W/fallback_home/.claude/team/roles" \
    bash "$TEAM_SH" pick-model sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 1 ] && pass "design-B: pick-model falls back one tier (exit 1)" \
    || fail "design-B: pick-model falls back one tier (exit 1)" "rc=$rc out=${out:0:120}"
}

# pick-model exit 3 when nothing matches (empty model list)
{
  mkdir -p "$W/empty_home/.claude"
  cat > "$W/empty_home/.claude/settings.json" <<'JSON'
{"modelPicker":{"options":[]}}
JSON
  out=$(HOME="$W/empty_home" TEAM_ROLES_DIR="$W/empty_home/.claude/team/roles" \
    bash "$TEAM_SH" pick-model sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && pass "design-B: pick-model → exit 3 when no models" \
    || fail "design-B: pick-model → exit 3 when no models" "rc=$rc"
}

# ══════════════════════════════════════════════════════════════════
# N1/N2 — CLAUDE_CODE_SUBAGENT_MODEL set in-process, exported in cmd
# When pick-model sonnet exits 0, spawn must export CLAUDE_CODE_SUBAGENT_MODEL
# to the newest sonnet in the cmd string (not via a subshell expansion that
# would expand empty when run from a worktree).
# ══════════════════════════════════════════════════════════════════
{
  R="$W/n12"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="n12$$"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" worker "$pf" sonnet) \
    >/dev/null 2>&1 && true || true
  rm -f "/tmp/team-$TM.tabs"
  # CLAUDE_CODE_SUBAGENT_MODEL=<newest-sonnet> must appear in cmd (stub: system.ai.claude-sonnet-4-6)
  grep -q 'CLAUDE_CODE_SUBAGENT_MODEL=system.ai.claude-sonnet-4-6' "$CMUX_LOG" \
    && pass "N1/N2: CLAUDE_CODE_SUBAGENT_MODEL set in spawned cmd" \
    || fail "N1/N2: CLAUDE_CODE_SUBAGENT_MODEL set in spawned cmd" \
       "cmux=$(grep SUBAGENT_MODEL "$CMUX_LOG" || echo '(not found)')"
}

# ══════════════════════════════════════════════════════════════════
# N4 — haiku tier + --worktree refused (exit 2)
# spawn must refuse haiku-tier model + --worktree combination:
# haiku teammates can't commit/gate in a worktree build run.
# ══════════════════════════════════════════════════════════════════
{
  R="$W/n4"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="n4$$"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn --worktree "$TM" worker "$pf" \
    system.ai.claude-haiku-4-5 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$CMUX_LOG" ] \
    && pass "N4: haiku + --worktree refused (exit 2, no pane)" \
    || fail "N4: haiku + --worktree refused (exit 2, no pane)" \
       "rc=$rc cmux=$(cat "$CMUX_LOG")"
}

# ══════════════════════════════════════════════════════════════════
# N4 — reserved role name 'monitor' refused at spawn (exit 2)
# ══════════════════════════════════════════════════════════════════
{
  R="$W/n4b"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="n4b$$"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn "$TM" monitor "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$CMUX_LOG" ] \
    && pass "N10: role name monitor reserved, spawn exits 2" \
    || fail "N10: role name monitor reserved, spawn exits 2" \
       "rc=$rc cmux=$(cat "$CMUX_LOG")"
}

# ══════════════════════════════════════════════════════════════════
# N5/N6 — haiku tier → --permission-mode dontAsk in spawned cmd
# Haiku-tier model must trigger dontAsk + allowedTools in the cmd.
# ══════════════════════════════════════════════════════════════════
{
  R="$W/n56"; _mkgit "$R"
  run="$R/.team/runs/2026-10-08-myteam"; _mkrun "$run"
  pf="$run/prompts/n5worker.md"; printf 'prompt\n' > "$pf"
  TM="n56$$"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" n5worker "$pf" \
    system.ai.claude-haiku-4-5) >/dev/null 2>&1 && true || true
  rm -f "/tmp/team-$TM.tabs"
  grep -q 'dontAsk' "$CMUX_LOG" \
    && pass "N5: haiku spawn uses dontAsk in cmd" \
    || fail "N5: haiku spawn uses dontAsk in cmd" \
       "cmux=$(grep -m1 '' "$CMUX_LOG" || echo '(empty)')"
}

# N5 variant: --model <haiku-id> also triggers dontAsk
{
  R="$W/n56b"; _mkgit "$R"
  run="$R/.team/runs/2026-10-08-myteam"; _mkrun "$run"
  pf="$run/prompts/n5b.md"; printf 'prompt\n' > "$pf"
  TM="n56b$$"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" n5b "$pf" \
    system.ai.glm-5-3) >/dev/null 2>&1 && true || true
  rm -f "/tmp/team-$TM.tabs"
  grep -q 'dontAsk' "$CMUX_LOG" \
    && pass "N6: GLM/haiku-tier model also triggers dontAsk" \
    || fail "N6: GLM/haiku-tier model also triggers dontAsk" \
       "cmux=$(grep -m1 '' "$CMUX_LOG" || echo '(empty)')"
}

# N4: haiku allowlist includes report/tasks/status paths
{
  R="$W/n4c"; _mkgit "$R"
  run="$R/.team/runs/2026-10-08-myteam"; _mkrun "$run"
  pf="$run/prompts/worker.md"; printf 'prompt\n' > "$pf"
  TM="n4c$$"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" worker "$pf" \
    system.ai.claude-haiku-4-5) >/dev/null 2>&1 && true || true
  rm -f "/tmp/team-$TM.tabs"
  grep -q 'allowedTools' "$CMUX_LOG" \
    && pass "N4: haiku spawn cmd includes --allowedTools" \
    || fail "N4: haiku spawn cmd includes --allowedTools" \
       "cmux=$(grep -m1 '' "$CMUX_LOG" || echo '(empty)')"
}

# ══════════════════════════════════════════════════════════════════
# Design C / N7 — cap at 8: spawn exits 4 on 9th distinct live title
# ══════════════════════════════════════════════════════════════════
{
  R="$W/dc"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="dc$$"
  # Pre-populate registry with 8 live pane entries
  {
    for i in $(seq 1 8); do
      printf 'cmux surface:%d pane %s-role%d sonnet -\n' \
        "$i" "$TM" "$i"
    done
  } > "/tmp/team-$TM.tabs"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn "$TM" role9 "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  rm -f "/tmp/team-$TM.tabs"
  [ "$rc" = 4 ] && pass "N7/design-C: cap at 8, spawn exits 4" \
    || fail "N7/design-C: cap at 8, spawn exits 4" "rc=$rc out=${out:0:120}"
}

# Design C — dead rows pruned before cap check
{
  R="$W/dc2"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="dc2$$"
  # 8 entries BUT cmux identify returns gone for all → all pruned → cap not hit
  # Override cmux stub to return gone for identify
  cat > "$W/bin/cmux" <<'SH2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
n=$(wc -l < "$CMUX_LOG" 2>/dev/null || echo 1)
case "$1" in
  new-split|new-surface) printf 'ok surface:%d\n' "$n" ;;
  close-surface) case " $* " in *" --force "*) echo "OK" ;; *) echo "Error: confirmation_required" >&2; exit 1 ;; esac ;;
  identify) echo '{"caller":{}}' ;;  # no pane_ref → surface appears gone
  rename-tab|tab-title|move-surface|workspace-title) true ;;
esac
SH2
  {
    for i in $(seq 1 8); do
      printf 'cmux surface:%d pane %s-role%d sonnet -\n' \
        "$i" "$TM" "$i"
    done
  } > "/tmp/team-$TM.tabs"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn "$TM" role9 "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  rm -f "/tmp/team-$TM.tabs"
  # Restore live stub
  cat > "$W/bin/cmux" <<'SH3'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
n=$(wc -l < "$CMUX_LOG" 2>/dev/null || echo 1)
case "$1" in
  new-split|new-surface) printf 'ok surface:%d\n' "$n" ;;
  close-surface) case " $* " in *" --force "*) echo "OK" ;; *) echo "Error: confirmation_required" >&2; exit 1 ;; esac ;;
  identify)
    surf=""
    prev=""
    for a; do [ "$prev" = "--surface" ] && surf="$a"; prev="$a"; done
    echo "{\"caller\":{\"pane_ref\":\"pane-stub\",\"surface_ref\":\"$surf\"}}"
    ;;
  rename-tab|tab-title|move-surface|workspace-title|new-split-*) true ;;
esac
SH3
  [ "$rc" = 0 ] && pass "design-C: dead rows pruned before cap check" \
    || fail "design-C: dead rows pruned before cap check" "rc=$rc out=${out:0:120}"
}

# Design C — duplicate title refused (exit 2) without --replace
{
  R="$W/dc3"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="dc3$$"
  # Pre-populate with a live entry for role1
  printf 'cmux surface:1 pane %s-role1 sonnet -\n' "$TM" \
    > "/tmp/team-$TM.tabs"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn "$TM" role1 "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  rm -f "/tmp/team-$TM.tabs"
  [ "$rc" = 2 ] && pass "design-C: duplicate live title refused (exit 2)" \
    || fail "design-C: duplicate live title refused (exit 2)" "rc=$rc out=${out:0:120}"
}

# Design C — --replace allows duplicate title
{
  R="$W/dc4"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="dc4$$"
  printf 'cmux surface:1 pane %s-role1 sonnet -\n' "$TM" \
    > "/tmp/team-$TM.tabs"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn --replace "$TM" role1 "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  rm -f "/tmp/team-$TM.tabs"
  [ "$rc" = 0 ] && pass "design-C: --replace allows duplicate title" \
    || fail "design-C: --replace allows duplicate title" "rc=$rc out=${out:0:120}"
}

# Design C — CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4 in spawned cmd
{
  R="$W/dc5"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="dc5$$"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" worker "$pf" \
    sonnet) >/dev/null 2>&1 && true || true
  rm -f "/tmp/team-$TM.tabs"
  grep -q 'CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4' "$CMUX_LOG" \
    && pass "design-C: CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4 in spawned cmd" \
    || fail "design-C: CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4 in spawned cmd" \
       "cmux=$(grep CONCURRENT "$CMUX_LOG" || echo '(not found)')"
}

# ══════════════════════════════════════════════════════════════════
# N8 — lock dir: dead-PID lock auto-broken; live lock → exit 4 (timeout)
# spawn creates /tmp/team-<team>.tabs.lock with a pid file;
# a lock with a dead PID is auto-broken and spawn proceeds.
# ══════════════════════════════════════════════════════════════════
{
  # N8a: dead-PID lock is auto-broken
  R="$W/n8a"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="n8a$$"
  lock="/tmp/team-$TM.tabs.lock"
  mkdir -p "$lock"
  # Write a PID that cannot be a live process (very large, outside range)
  printf '%s\n' "9999999" > "$lock/pid"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn "$TM" worker "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  rmdir "$lock" 2>/dev/null || true; rm -f "/tmp/team-$TM.tabs"
  [ "$rc" = 0 ] && pass "N8: dead-PID lock auto-broken, spawn succeeds" \
    || fail "N8: dead-PID lock auto-broken, spawn succeeds" \
       "rc=$rc out=${out:0:120}"
}
# N8b — live lock eventually times out with exit 4; too slow for CI.
# Manually verify: mkdir /tmp/team-X.tabs.lock && echo $$ > /tmp/team-X.tabs.lock/pid
# then: TEAM_SH=... bash tests/team-build.sh  (will wait ~30s for timeout, exit 4)

# ══════════════════════════════════════════════════════════════════
# Design A / N13 / N14 — role-pull, role-promote, roles status column
# Unit tests for lib/roles.sh are in tests/roles.sh (owned by rev3-tests,
# transferred from rev3-roles-impl). Run: bash tests/roles.sh
# The tests below cover only dispatch-level integration.
# ══════════════════════════════════════════════════════════════════

# N14 (dispatch) — `team.sh role <name>` prints stderr note when resolving to library
{
  R="$W/n14"; _mkgit "$R"
  mkdir -p "$R/.team/roles"
  printf '# LibRole\n**Lens:** library\n## Lessons\n' \
    > "$W/home/.claude/team/roles/libdispatchrole.md"
  stderr_out=$(cd "$R" && bash "$TEAM_SH" role libdispatchrole 2>&1 >/dev/null) && rc=0 || rc=$?
  [ -n "$stderr_out" ] && pass "N14: team.sh role prints stderr note for library resolution" \
    || fail "N14: team.sh role prints stderr note for library resolution" "no stderr"
}

# ══════════════════════════════════════════════════════════════════
# Design D — `status <team>` subcommand exists and prints a table
# ══════════════════════════════════════════════════════════════════
{
  R="$W/dd_status"; _mkgit "$R"
  run="$R/.team/runs/2026-10-08-myteam"; _mkrun "$run"
  TM="ddstatus$$"
  pf="$run/prompts/w1.md"; printf 'prompt\n' > "$pf"
  # Spawn one teammate to create a registry row
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" w1 "$pf" \
    sonnet) >/dev/null 2>&1 && true || true
  out=$(bash "$TEAM_SH" status "$TM" 2>&1) && rc=0 || rc=$?
  rm -f "/tmp/team-$TM.tabs"
  # Output must have ROLE header and rc=0
  [ "$rc" = 0 ] && [[ "$out" == *"ROLE"* || "$out" == *"w1"* ]] \
    && pass "design-D: status <team> prints table with ROLE column" \
    || fail "design-D: status <team> prints table with ROLE column" \
       "rc=$rc out=${out:0:120}"
}

# ══════════════════════════════════════════════════════════════════
# Design D — `monitor <team>` spawns a dash pane (layout=dash)
# Monitor pane is excluded from the teammate cap.
# ══════════════════════════════════════════════════════════════════
{
  R="$W/dd_mon"; _mkgit "$R"
  TM="ddmon$$"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" monitor "$TM" 2>&1) && rc=0 || rc=$?
  rm -f "/tmp/team-$TM.tabs"
  # cmux must be called with layout=dash (or --command referencing monitor)
  [ "$rc" = 0 ] && { grep -q 'dash' "$CMUX_LOG" || grep -q 'monitor' "$CMUX_LOG"; } \
    && pass "design-D: monitor opens dash pane" \
    || fail "design-D: monitor opens dash pane" "rc=$rc cmux=$(cat "$CMUX_LOG")"
}

# N11 — second monitor call on same team either reuses or exits gracefully (not crash)
{
  R="$W/n11"; _mkgit "$R"
  TM="n11$$"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" monitor "$TM") >/dev/null 2>&1 && true || true
  out=$(cd "$R" && bash "$TEAM_SH" monitor "$TM" 2>&1) && rc=0 || rc=$?
  rm -f "/tmp/team-$TM.tabs"
  [ "$rc" = 0 ] || [[ "$out" == *"already running"* ]] || [[ "$out" == *"already"* ]] \
    && pass "N11: second monitor call on same team handled gracefully" \
    || fail "N11: second monitor call on same team handled gracefully" \
       "rc=$rc out=${out:0:120}"
}

# N9 — monitor pane command has properly quoted date (not frozen by quoting)
{
  R="$W/n9"; _mkgit "$R"
  TM="n9$$"
  _reset_logs  # ensure fresh log before grepping for date
  (cd "$R" && bash "$TEAM_SH" monitor "$TM") >/dev/null 2>&1 && true || true
  rm -f "/tmp/team-$TM.tabs"
  # The date command must not be hard-coded (frozen); grep for $(date or `date`
  grep -Eq '\$\(date|\`date' "$CMUX_LOG" \
    && pass "N9: monitor command uses dynamic date (not frozen literal)" \
    || fail "N9: monitor command uses dynamic date" \
       "cmux=$(grep -m1 '' "$CMUX_LOG" || echo '(empty)')"
}

# Design D — monitor not counted in 8-teammate cap
{
  R="$W/dd_cap"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="ddcap$$"
  # Fill cap to 8
  { for i in $(seq 1 8); do
    printf 'cmux surface:%d pane %s-role%d sonnet -\n' "$i" "$TM" "$i"
  done; } > "/tmp/team-$TM.tabs"
  _reset_logs
  # monitor must NOT be blocked by the cap
  out=$(cd "$R" && bash "$TEAM_SH" monitor "$TM" 2>&1) && rc=0 || rc=$?
  rm -f "/tmp/team-$TM.tabs"
  [ "$rc" = 0 ] && pass "design-D: monitor not blocked by teammate cap" \
    || fail "design-D: monitor not blocked by teammate cap" "rc=$rc out=${out:0:80}"
}

# N3 — list/status flags MODEL GONE for a model no longer in the list
{
  R="$W/n3"; _mkgit "$R"
  # Registry has an entry with a model not in the stub list
  TM="n3$$"
  printf 'cmux surface:1 pane %s-worker system.ai.retired-model-99 -\n' "$TM" \
    > "/tmp/team-$TM.tabs"
  out=$(bash "$TEAM_SH" list "$TM" 2>&1) && rc=0 || rc=$?
  rm -f "/tmp/team-$TM.tabs"
  # list output must flag unavailable model with GONE (not just echo the model name)
  [[ "$out" == *"GONE"* ]] \
    && pass "N3: list flags MODEL GONE for unavailable model" \
    || fail "N3: list flags MODEL GONE for unavailable model" "rc=$rc out=${out:0:120}"
}

# ══════════════════════════════════════════════════════════════════
# doccheck passes after all changes
# ══════════════════════════════════════════════════════════════════
{
  out=$(bash "$TEAM_SH" doccheck 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && pass "doccheck: passes cleanly" \
    || fail "doccheck: passes cleanly" "rc=$rc out=${out:0:200}"
}

# ══════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════
echo ""
[ "$fails" = 0 ] && echo "all passed ($(($(grep -c '^pass\b' "$0" || true))) cases)" \
  || echo "$fails case(s) failed"
[ "$fails" = 0 ]
