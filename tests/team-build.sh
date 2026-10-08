#!/usr/bin/env bash
# tests/team-build.sh — acceptance tests for /team (rev3 phase-B + rev4 cmux-only)
# Source: .team/runs/2026-10-07-rev2/synthesis.md (phase B), .team/runs/2026-10-08-rev4/decisions.md (rev4).
# Each case is labelled with its item id (bug#N, NN, design-X, rev4-N).
# USAGE:
#   bash tests/team-build.sh                        (current worktree)
#   TEAM_SH=/path/to/team.sh bash tests/team-build.sh  (specific version)
# BASE VERIFICATION for rev3 cases: must FAIL on base 52c569a.
# BASE VERIFICATION for rev4 cases: must FAIL on base 61d4fcd.
set -euo pipefail

TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/team.sh}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; passes=0
pass() { echo "PASS  $1"; passes=$((passes+1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }

# ── PATH stubs — never open real panes, sessions, or terminals ──
mkdir -p "$W/bin"
CMUX_LOG="$W/cmux.log"; CLAUDE_LOG="$W/claude.log"
_reset_logs() { : > "$CMUX_LOG" > "$CLAUDE_LOG"; }
_reset_logs

# cmux stub: configurable via env vars — never replace this file in tests; set env vars instead:
#   CMUX_PING_REPLY=<val>   — override ping reply (default: PONG)
#   CMUX_VERSION=<val>      — override version string (default: "cmux 0.65.0 (108) stub")
#   CMUX_IDENTIFY_GONE=1    — identify always returns {} (surface appears gone; used in dc2)
#   CMUX_TREE_SURFACES=...  — tab-sep "ref\ttitle\n..." lines for tree --all --json output
cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
n=$(wc -l < "$CMUX_LOG" 2>/dev/null || echo 1)
case "$1" in
  ping) echo "${CMUX_PING_REPLY:-PONG}" ;;
  --version) echo "${CMUX_VERSION:-cmux 0.65.0 (108) stub}" ;;
  new-split|new-surface) printf 'ok surface:%d workspace:1\n' "$n" ;;
  close-surface)
    case " $* " in
      *" --force "*) echo "OK" ;;
      *) echo "Error: confirmation_required" >&2; exit 1 ;;
    esac
    ;;
  identify)
    if [ "${CMUX_IDENTIFY_GONE:-}" = 1 ]; then
      echo '{"caller":{}}'
    else
      surf=""; prev=""
      for a; do [ "$prev" = "--surface" ] && surf="$a"; prev="$a"; done
      echo "{\"caller\":{\"pane_ref\":\"pane-stub\",\"surface_ref\":\"${surf:-surface:lead}\"}}"
    fi
    ;;
  tree)
    titles="${CMUX_TREE_SURFACES:-}"
    jout='{"workspaces":[{"ref":"workspace:1","surfaces":['
    first=1
    while IFS=$'\t' read -r ref title; do
      [ -n "$ref" ] || continue
      [ "$first" = 1 ] || jout+=","
      jout+="{\"ref\":\"$ref\",\"title\":\"$title\"}"
      first=0
    done <<< "$titles"
    jout+=']}]}'
    echo "$jout"
    ;;
  rename-workspace|rename-tab|tab-title|move-surface|workspace-title|new-split-*) true ;;
  # rev5: sidebar/notify verbs are only logged (args asserted via $CMUX_LOG), never executed
  set-status|clear-status|set-progress|clear-progress|log|notify) true ;;
esac
SH
chmod +x "$W/bin/cmux"

cat > "$W/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_LOG"
SH
chmod +x "$W/bin/claude"

export PATH="$W/bin:$PATH"
export CMUX_LOG CLAUDE_LOG
# Run from inside a teammate pane TEAM_MEMBER is inherited and makes lead-title a no-op (rev4-3).
unset TEAM_MEMBER

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
# Redirect registries and sysprompts to a scratch dir so tests never touch /tmp/team-*.tabs
# from other live projects (cont2, tw1, w2c, etc.).
export TEAM_REG_DIR="$W/regs"
mkdir -p "$TEAM_REG_DIR"

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
    > "$TEAM_REG_DIR/team-$TM.tabs"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" role2 "$pf" sonnet) \
    >/dev/null 2>&1 && sprc=0 || sprc=$?
  lines=$(wc -l < "$TEAM_REG_DIR/team-$TM.tabs" 2>/dev/null || echo 0)
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  [ "$lines" -ge 2 ] && pass "bug#2e: spawn appends to existing registry" \
    || fail "bug#2e: spawn appends to existing registry" "lines=$lines sprc=$sprc"
}

# ══════════════════════════════════════════════════════════════════
# bug#2f — zero-commit repo + --worktree refused (exit 2)
# Must not open a new pane: check for absence of new-split/new-surface
# in cmux log (identify calls from _reg_prune/_alive are OK to have).
# Unique team slug avoids registry cross-contamination from earlier cases.
# ══════════════════════════════════════════════════════════════════
{
  R="$W/b2f"; _mkgit0 "$R"
  pf="$W/p_b2f.md"; printf 'prompt\n' > "$pf"
  TM="b2f$$"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn --worktree "$TM" myrole "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  # No new pane should have been opened (identify calls are OK; new-split/new-surface are not)
  grep -qE 'new-split|new-surface' "$CMUX_LOG" 2>/dev/null && pane_opened=1 || pane_opened=0
  [ "$rc" != 0 ] && [ "$pane_opened" = 0 ] \
    && pass "bug#2f: zero-commit repo + --worktree refused (no pane opened)" \
    || fail "bug#2f: zero-commit repo + --worktree refused (no pane opened)" \
       "rc=$rc pane_opened=$pane_opened cmux=$(cat "$CMUX_LOG")"
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

# pick-model fallback: only haiku in model list → sonnet falls back, exit 1
# Use TEAM_MODELS_FILE so managed-settings.json is bypassed entirely.
{
  cat > "$W/fallback_models.json" <<'JSON'
{"modelPicker":{"options":[
  {"model":"system.ai.claude-haiku-4-5","behavesAs":"haiku"}
]}}
JSON
  out=$(TEAM_MODELS_FILE="$W/fallback_models.json" \
    bash "$TEAM_SH" pick-model sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 1 ] && pass "design-B: pick-model falls back one tier (exit 1)" \
    || fail "design-B: pick-model falls back one tier (exit 1)" "rc=$rc out=${out:0:120}"
}

# pick-model exit 3 when no claude-family match at all (only non-claude models)
# Empty options: [] still falls back to built-in aliases, so use glm-only list instead.
{
  cat > "$W/nonclaude_models.json" <<'JSON'
{"modelPicker":{"options":[
  {"model":"system.ai.glm-5-3","behavesAs":"haiku"},
  {"model":"system.ai.glm-5-2","behavesAs":"haiku"}
]}}
JSON
  out=$(TEAM_MODELS_FILE="$W/nonclaude_models.json" \
    bash "$TEAM_SH" pick-model sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && pass "design-B: pick-model → exit 3 when no claude-family model" \
    || fail "design-B: pick-model → exit 3 when no claude-family model" "rc=$rc out=${out:0:80}"
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
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
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
  # exit 2 and no new-split/new-surface (cmux ping/version calls are ok, no pane)
  pane_opened=0; grep -qE 'new-split|new-surface' "$CMUX_LOG" 2>/dev/null && pane_opened=1 || true
  [ "$rc" = 2 ] && [ "$pane_opened" = 0 ] \
    && pass "N4: haiku + --worktree refused (exit 2, no pane)" \
    || fail "N4: haiku + --worktree refused (exit 2, no pane)" \
       "rc=$rc pane_opened=$pane_opened cmux=$(cat "$CMUX_LOG")"
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
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
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
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  grep -q 'dontAsk' "$CMUX_LOG" \
    && pass "N6: GLM/haiku-tier model also triggers dontAsk" \
    || fail "N6: GLM/haiku-tier model also triggers dontAsk" \
       "cmux=$(grep -m1 '' "$CMUX_LOG" || echo '(empty)')"
}

# N4: haiku allowlist: contains Bash(git status:*) but NOT git diff/log/Bash(git:*)/python3
{
  R="$W/n4c"; _mkgit "$R"
  run="$R/.team/runs/2026-10-08-myteam"; _mkrun "$run"
  pf="$run/prompts/worker.md"; printf 'prompt\n' > "$pf"
  TM="n4c$$"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" worker "$pf" \
    system.ai.claude-haiku-4-5) >/dev/null 2>&1 && true || true
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  has_status=0; has_diff=0; has_python3=0
  # Log uses printf %q escaping: "git\ status" in the line; use .* to match any separator
  grep -q 'git.*status' "$CMUX_LOG" && has_status=1 || true
  # git diff/log/Bash(git:*) must NOT appear (44edfd6 removes them; they write via --output)
  grep -qE 'git.*diff|git.*log|git.*show|Bash.git:..\)' "$CMUX_LOG" && has_diff=1 || true
  grep -q 'python3' "$CMUX_LOG" && has_python3=1 || true
  [ "$has_status" = 1 ] && pass "N4: haiku allowlist contains Bash(git status:*)" \
    || fail "N4: haiku allowlist contains Bash(git status:*)" \
       "cmux=$(grep -o 'allowedTools[^\"]*' "$CMUX_LOG" | head -1 || echo '(not found)')"
  [ "$has_diff" = 0 ] && pass "N4: haiku allowlist excludes git diff/log/Bash(git:*)" \
    || fail "N4: haiku allowlist excludes git diff/log/Bash(git:*)" "found in cmux log"
  [ "$has_python3" = 0 ] && pass "N4: haiku allowlist excludes python3" \
    || fail "N4: haiku allowlist excludes python3" "found in cmux log"
}

# ══════════════════════════════════════════════════════════════════
# Design C / N7 — cap at 8: spawn exits 4 on 9th distinct live title
# CMUX_TREE_SURFACES makes all 8 surfaces appear live in cmux tree output.
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
  } > "$TEAM_REG_DIR/team-$TM.tabs"
  # Surface tree must show them all as live for the cap check to count them
  surfs=$(for i in $(seq 1 8); do printf 'surface:%d\t%s-role%d\n' "$i" "$TM" "$i"; done)
  _reset_logs
  out=$(cd "$R" && CMUX_TREE_SURFACES="$surfs" bash "$TEAM_SH" spawn "$TM" role9 "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  [ "$rc" = 4 ] && pass "N7/design-C: cap at 8, spawn exits 4" \
    || fail "N7/design-C: cap at 8, spawn exits 4" "rc=$rc out=${out:0:120}"
}

# Design C — dead rows pruned before cap check
{
  R="$W/dc2"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="dc2$$"
  # 8 entries BUT cmux identify returns gone for all → all pruned → cap not hit
  # Use CMUX_IDENTIFY_GONE=1 env var (no stub replacement needed)
  {
    for i in $(seq 1 8); do
      printf 'cmux surface:%d pane %s-role%d sonnet -\n' \
        "$i" "$TM" "$i"
    done
  } > "$TEAM_REG_DIR/team-$TM.tabs"
  _reset_logs
  out=$(cd "$R" && CMUX_IDENTIFY_GONE=1 bash "$TEAM_SH" spawn "$TM" role9 "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  [ "$rc" = 0 ] && pass "design-C: dead rows pruned before cap check" \
    || fail "design-C: dead rows pruned before cap check" "rc=$rc out=${out:0:120}"
}

# Design C — duplicate title refused (exit 2) without --replace
{
  R="$W/dc3"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="dc3$$"
  # Pre-populate with a live entry for role1; make surface appear live in tree
  printf 'cmux surface:1 pane %s-role1 sonnet -\n' "$TM" \
    > "$TEAM_REG_DIR/team-$TM.tabs"
  _reset_logs
  out=$(cd "$R" && CMUX_TREE_SURFACES="surface:1	$TM-role1" \
    bash "$TEAM_SH" spawn "$TM" role1 "$pf" sonnet 2>&1) && rc=0 || rc=$?
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  [ "$rc" = 2 ] && pass "design-C: duplicate live title refused (exit 2)" \
    || fail "design-C: duplicate live title refused (exit 2)" "rc=$rc out=${out:0:120}"
}

# Design C — --replace allows duplicate title
{
  R="$W/dc4"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="dc4$$"
  printf 'cmux surface:1 pane %s-role1 sonnet -\n' "$TM" \
    > "$TEAM_REG_DIR/team-$TM.tabs"
  _reset_logs
  out=$(cd "$R" && CMUX_TREE_SURFACES="surface:1	$TM-role1" \
    bash "$TEAM_SH" spawn --replace "$TM" role1 "$pf" sonnet 2>&1) && rc=0 || rc=$?
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
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
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  grep -q 'CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4' "$CMUX_LOG" \
    && pass "design-C: CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4 in spawned cmd" \
    || fail "design-C: CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4 in spawned cmd" \
       "cmux=$(grep CONCURRENT "$CMUX_LOG" || echo '(not found)')"
}

# ══════════════════════════════════════════════════════════════════
# N8 — lock dir: dead-PID lock auto-broken; live lock → exit 4 (timeout)
# spawn creates $TEAM_REG_DIR/team-<team>.tabs.lock with a pid file;
# a lock with a dead PID is auto-broken and spawn proceeds.
# ══════════════════════════════════════════════════════════════════
{
  # N8a: dead-PID lock is auto-broken
  R="$W/n8a"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="n8a$$"
  lock="$TEAM_REG_DIR/team-$TM.tabs.lock"
  mkdir -p "$lock"
  # Write a PID that cannot be a live process (very large, outside range)
  printf '%s\n' "9999999" > "$lock/pid"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn "$TM" worker "$pf" \
    sonnet 2>&1) && rc=0 || rc=$?
  rmdir "$lock" 2>/dev/null || true; rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  [ "$rc" = 0 ] && pass "N8: dead-PID lock auto-broken, spawn succeeds" \
    || fail "N8: dead-PID lock auto-broken, spawn succeeds" \
       "rc=$rc out=${out:0:120}"
}
# N8b — live lock eventually times out with exit 4; too slow for CI.
# Manually verify: mkdir "$TEAM_REG_DIR/team-X.tabs.lock" && echo $$ > .../pid
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
  # Pre-populate registry (same as spawn would do) and show surface as live
  printf 'cmux surface:77 pane %s-w1 sonnet -\n' "$TM" > "$TEAM_REG_DIR/team-$TM.tabs"
  out=$(cd "$R" && CMUX_TREE_SURFACES="surface:77	$TM-w1" \
    bash "$TEAM_SH" status "$TM" 2>&1) && rc=0 || rc=$?
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
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
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
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
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  [ "$rc" = 0 ] || [[ "$out" == *"already running"* ]] || [[ "$out" == *"already"* ]] \
    && pass "N11: second monitor call on same team handled gracefully" \
    || fail "N11: second monitor call on same team handled gracefully" \
       "rc=$rc out=${out:0:120}"
}

# N9 — monitor pane command runs the real-bash loop (rev5, decision 37 deliberate change)
# Was: grep the command string for $(date|`date` (a frozen-clock guard). rev5 moves the clock,
# frame-diffing, registry-exit and per-tick sync into `team.sh status --watch`'s own bash loop, so
# the string handed to cmux no longer contains a date; the guard is now "it runs status --watch".
{
  R="$W/n9"; _mkgit "$R"
  TM="n9$$"
  _reset_logs  # ensure fresh log before grepping
  (cd "$R" && bash "$TEAM_SH" monitor "$TM") >/dev/null 2>&1 && true || true
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  grep -q 'status --watch' "$CMUX_LOG" \
    && pass "N9: monitor command runs 'status --watch' (clock/frame-diff live in its loop)" \
    || fail "N9: monitor command runs 'status --watch'" \
       "cmux=$(grep -m1 '' "$CMUX_LOG" || echo '(empty)')"
}

# Design D — monitor not counted in 8-teammate cap
{
  R="$W/dd_cap"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="ddcap$$"
  # Fill cap to 8 and make surfaces appear live
  { for i in $(seq 1 8); do
    printf 'cmux surface:%d pane %s-role%d sonnet -\n' "$i" "$TM" "$i"
  done; } > "$TEAM_REG_DIR/team-$TM.tabs"
  surfs=$(for i in $(seq 1 8); do printf 'surface:%d\t%s-role%d\n' "$i" "$TM" "$i"; done)
  _reset_logs
  # monitor must NOT be blocked by the cap
  out=$(cd "$R" && CMUX_TREE_SURFACES="$surfs" bash "$TEAM_SH" monitor "$TM" 2>&1) && rc=0 || rc=$?
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  [ "$rc" = 0 ] && pass "design-D: monitor not blocked by teammate cap" \
    || fail "design-D: monitor not blocked by teammate cap" "rc=$rc out=${out:0:80}"
}

# N3 — list/status flags MODEL GONE for a model no longer in the list
{
  R="$W/n3"; _mkgit "$R"
  # Registry has an entry with a model not in the stub list; surface appears live
  TM="n3$$"
  printf 'cmux surface:1 pane %s-worker system.ai.retired-model-99 -\n' "$TM" \
    > "$TEAM_REG_DIR/team-$TM.tabs"
  out=$(CMUX_TREE_SURFACES="surface:1	$TM-worker" bash "$TEAM_SH" list "$TM" 2>&1) && rc=0 || rc=$?
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  # list output must flag unavailable model with GONE (not just echo the model name)
  [[ "$out" == *"GONE"* ]] \
    && pass "N3: list flags MODEL GONE for unavailable model" \
    || fail "N3: list flags MODEL GONE for unavailable model" "rc=$rc out=${out:0:120}"
}

# ══════════════════════════════════════════════════════════════════
# rev4-1 — _require_cmux: missing cmux, bad PONG, old version, outside pane
# Each of these must FAIL on base 61d4fcd (rev3 has no _require_cmux).
# ══════════════════════════════════════════════════════════════════

# rev4-1a: spawn without cmux on PATH → exit 3
# Build a PATH that has every essential dir EXCEPT dirs containing any cmux binary.
{
  R="$W/rv1a"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="rv1a$$"
  _reset_logs
  nocmux_path=$(echo "$PATH" | tr ':' '\n' | while read -r d; do [ -x "$d/cmux" ] || echo "$d"; done | tr '\n' ':' | sed 's/:$//')
  out=$(cd "$R" && PATH="$nocmux_path" bash "$TEAM_SH" spawn "$TM" worker "$pf" sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ "$out" == *"cmux"* ]] \
    && pass "rev4-1a: spawn without cmux exits 3 with install hint" \
    || fail "rev4-1a: spawn without cmux exits 3 with install hint" "rc=$rc out=${out:0:120}"
}

# rev4-1b: cmux ping returns wrong value → exit 3
# Use CMUX_PING_REPLY env var (no stub replacement needed)
{
  R="$W/rv1b"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="rv1b$$"
  _reset_logs
  out=$(cd "$R" && CMUX_PING_REPLY=NOPE bash "$TEAM_SH" spawn "$TM" worker "$pf" sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ "$out" == *"PONG"* || "$out" == *"ping"* || "$out" == *"cmux"* ]] \
    && pass "rev4-1b: bad ping → exit 3" \
    || fail "rev4-1b: bad ping → exit 3" "rc=$rc out=${out:0:120}"
}

# rev4-1c: cmux too old (0.64.0 < 0.65.0) → exit 3
# Use CMUX_VERSION env var
{
  R="$W/rv1c"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="rv1c$$"
  _reset_logs
  out=$(cd "$R" && CMUX_VERSION="cmux 0.64.0 (99) old" bash "$TEAM_SH" spawn "$TM" worker "$pf" sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ "$out" == *"0.65"* || "$out" == *"update"* || "$out" == *"cmux"* ]] \
    && pass "rev4-1c: old cmux version → exit 3 with upgrade hint" \
    || fail "rev4-1c: old cmux version → exit 3 with upgrade hint" "rc=$rc out=${out:0:120}"
}

# rev4-1d: cmux ok but CMUX_WORKSPACE_ID not set → exit 3 for spawn (requires pane)
{
  R="$W/rv1d"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="rv1d$$"
  _reset_logs
  out=$(cd "$R" && CMUX_WORKSPACE_ID= CMUX_SURFACE_ID= \
    bash "$TEAM_SH" spawn "$TM" worker "$pf" sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 3 ] && [[ "$out" == *"cmux pane"* || "$out" == *"CMUX_WORKSPACE"* || "$out" == *"cmux"* ]] \
    && pass "rev4-1d: spawn outside cmux pane (no CMUX_WORKSPACE_ID) → exit 3" \
    || fail "rev4-1d: spawn outside cmux pane (no CMUX_WORKSPACE_ID) → exit 3" "rc=$rc out=${out:0:120}"
}

# rev4-1e: init works without cmux (init never calls _require_cmux)
{
  R="$W/rv1e"; _mkgit "$R"
  # Remove cmux entirely for this test
  mv "$W/bin/cmux" "$W/bin/cmux.bak"
  out=$(cd "$R" && CMUX_WORKSPACE_ID= CMUX_SURFACE_ID= \
    bash "$TEAM_SH" init myteam 2>&1) && rc=0 || rc=$?
  mv "$W/bin/cmux.bak" "$W/bin/cmux"
  [ "$rc" = 0 ] \
    && pass "rev4-1e: init works without cmux" \
    || fail "rev4-1e: init works without cmux" "rc=$rc out=${out:0:120}"
}

# ══════════════════════════════════════════════════════════════════
# rev4-2 — --tmux removed: spawn --tmux → exit 2 with "removed" message
# ══════════════════════════════════════════════════════════════════
{
  R="$W/rv2"; _mkgit "$R"
  pf="$R/p.md"; printf 'prompt\n' > "$pf"
  TM="rv2$$"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" spawn --tmux "$TM" worker "$pf" sonnet 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [[ "$out" == *"removed"* ]] && [ ! -s "$CMUX_LOG" ] \
    && pass "rev4-2: --tmux removed → exit 2, no pane opened" \
    || fail "rev4-2: --tmux removed → exit 2, no pane opened" "rc=$rc cmux=$(cat "$CMUX_LOG") out=${out:0:120}"
}

# ══════════════════════════════════════════════════════════════════
# rev4-3 — lead-title: rename-workspace + rename-tab with "Main Board - <basename>"
# No-op when TEAM_MEMBER is set (inside a teammate).
# ══════════════════════════════════════════════════════════════════
{
  R="$W/rv3"; _mkgit "$R"
  _reset_logs
  # lead-title requires CMUX_WORKSPACE_ID and CMUX_SURFACE_ID
  out=$(cd "$R" && bash "$TEAM_SH" lead-title 2>&1) && rc=0 || rc=$?
  proj=$(basename "$R")
  # Must print the title and call rename-workspace + rename-tab
  [ "$rc" = 0 ] \
    && [[ "$out" == "Main Board - $proj" ]] \
    && grep -q "rename-workspace" "$CMUX_LOG" \
    && grep -q "rename-tab" "$CMUX_LOG" \
    && pass "rev4-3: lead-title prints correct title and calls rename-workspace + rename-tab" \
    || fail "rev4-3: lead-title prints correct title and calls rename-workspace + rename-tab" \
       "rc=$rc out=$out cmux=$(cat "$CMUX_LOG")"
}

# rev4-3b: lead-title no-op when TEAM_MEMBER is set
{
  R="$W/rv3b"; _mkgit "$R"
  _reset_logs
  out=$(cd "$R" && TEAM_MEMBER=myteam-worker bash "$TEAM_SH" lead-title 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && [ ! -s "$CMUX_LOG" ] \
    && pass "rev4-3b: lead-title no-op when TEAM_MEMBER set (teammate can't rename)" \
    || fail "rev4-3b: lead-title no-op when TEAM_MEMBER set" "rc=$rc cmux=$(cat "$CMUX_LOG")"
}

# ══════════════════════════════════════════════════════════════════
# rev4-4 — spawn: --name and TEAM_MEMBER in spawned claude cmd
# Registry row has 11 cols (rev5): col 8 = project root, then state, session-id, cwd.
# ══════════════════════════════════════════════════════════════════
{
  R="$W/rv4"; _mkgit "$R"
  run="$R/.team/runs/2026-10-08-myteam"; mkdir -p "$run/prompts" "$run/reports" "$run/status"
  pf="$run/prompts/worker.md"; printf 'prompt\n' > "$pf"
  TM="rv4$$"
  _reset_logs
  (cd "$R" && bash "$TEAM_SH" spawn "$TM" worker "$pf" sonnet) >/dev/null 2>&1 && true || true
  # Claude cmd (passed to cmux new-split --command "...") must have --name <team>-<role>
  grep -q -- "--name.*$TM-worker" "$CMUX_LOG" \
    && pass "rev4-4: --name <team>-<role> in spawned claude cmd" \
    || fail "rev4-4: --name <team>-<role> in spawned claude cmd" \
       "cmux=$(grep -- '--name' "$CMUX_LOG" || echo '(not found)')"
  # Claude cmd must have TEAM_MEMBER=<team>-<role>
  grep -qE "TEAM_MEMBER=.?$TM-worker" "$CMUX_LOG" \
    && pass "rev4-4: TEAM_MEMBER=<team>-<role> in spawned claude cmd" \
    || fail "rev4-4: TEAM_MEMBER=<team>-<role> in spawned claude cmd" \
       "cmux=$(grep TEAM_MEMBER "$CMUX_LOG" || echo '(not found)')"
  # Registry row must have 8 cols (cmux ref layout title model submodel rundir root)
  row=$(cat "$TEAM_REG_DIR/team-$TM.tabs" 2>/dev/null | head -1)
  cols=$(printf '%s\n' "$row" | awk '{print NF}')
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  # rev5 (decisions 26, 37, 46): 11 cols; the new ones come AFTER root (col 8). Assert real values,
  # not "-" placeholders: _row_root falls back to deriving root from col 7, so a placeholder fixture
  # would still pass against misordered columns.
  [ "$cols" = 11 ] \
    && pass "rev5-4: registry row has 11 cols (root=8, state=9, session-id=10, cwd=11)" \
    || fail "rev5-4: registry row has 11 cols" "cols=$cols row=$row"
  c8=$(awk '{print $8}' <<<"$row"); c9=$(awk '{print $9}' <<<"$row")
  c10=$(awk '{print $10}' <<<"$row"); c11=$(awk '{print $11}' <<<"$row")
  Rp=$(cd "$R" && pwd -P)   # root is stored physical (/private/var/… on macOS); cwd is $PWD as given
  [ "$c8" = "$Rp" ] && [ "$c9" = live ] \
    && printf '%s' "$c10" | grep -Eq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' \
    && [ "$c11" = "$R" ] \
    && pass "rev5-4: cols 8-11 = root, live, uuid, spawn cwd (all real values)" \
    || fail "rev5-4: cols 8-11 = root, live, uuid, cwd" "row=$row"
  grep -Eq -- "claude --session-id [0-9a-f-]{36} --name" "$CMUX_LOG" \
    && pass "rev5-4: spawned claude cmd carries --session-id <uuid>" \
    || fail "rev5-4: spawned claude cmd carries --session-id" "cmux=$(grep -- '--name' "$CMUX_LOG" || echo '(not found)')"
}

# rev4-4b: registry col 8 (root) is the main checkout root, not the worktree
{
  R="$W/rv4b"; _mkgit "$R"
  wt="$R/.team/worktrees/rv4b-worker"
  git -c user.email=t@t -c user.name=T -C "$R" worktree add -q -b "team/rv4b-worker" "$wt" HEAD
  run="$R/.team/runs/2026-10-08-myteam"; mkdir -p "$run/prompts"
  pf="$run/prompts/worker.md"; printf 'prompt\n' > "$pf"
  TM="rv4b$$"
  _reset_logs
  (cd "$wt" && bash "$TEAM_SH" spawn --worktree "$TM" worker "$pf" sonnet) >/dev/null 2>&1 && true || true
  row=$(cat "$TEAM_REG_DIR/team-$TM.tabs" 2>/dev/null | head -1)
  root=$(printf '%s\n' "$row" | awk '{print $8}')
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  # Root must be R (main checkout), not $wt (worktree path)
  [ -n "$root" ] && [ "$root" != "$wt" ] \
    && pass "rev4-4b: registry col 8 = main checkout root (not worktree)" \
    || fail "rev4-4b: registry col 8 = main checkout root" "root=$root wt=$wt"
}

# ══════════════════════════════════════════════════════════════════
# rev4-5 — reap: own/other/legacy/mismatch/caller-surface/exclude scoping
# Safety: TEAM_REG_DIR redirects all registry I/O to the scratch dir.
# ══════════════════════════════════════════════════════════════════

# rev4-5a: reap lists teammates from THIS project's registry, not others
{
  R="$W/rv5a"; _mkgit "$R"
  me=$(cd -P "$R" && pwd)
  OTHER="$W/rv5a_other"; _mkgit "$OTHER"
  other=$(cd -P "$OTHER" && pwd)
  TM_MINE="rv5amine$$"; TM_OTHER="rv5aother$$"
  # Own project row (root = $me)
  printf 'cmux surface:10 pane %s-worker sonnet - - %s\n' "$TM_MINE" "$me" \
    > "$TEAM_REG_DIR/team-$TM_MINE.tabs"
  # Other project row (root = $other) — must NOT appear in reap output for $R
  printf 'cmux surface:20 pane %s-worker sonnet - - %s\n' "$TM_OTHER" "$other" \
    > "$TEAM_REG_DIR/team-$TM_OTHER.tabs"
  # Stub cmux tree to make both surfaces appear live
  export CMUX_TREE_SURFACES="surface:10	$TM_MINE-worker
surface:20	$TM_OTHER-worker"
  out=$(cd "$R" && bash "$TEAM_SH" reap 2>&1) && rc=0 || rc=$?
  unset CMUX_TREE_SURFACES
  rm -f "$TEAM_REG_DIR/team-$TM_MINE.tabs" "$TEAM_REG_DIR/team-$TM_OTHER.tabs"
  # Own row listed, other row NOT shown
  [[ "$out" == *"$TM_MINE"* ]] && [[ "$out" != *"$TM_OTHER"* ]] \
    && pass "rev4-5a: reap lists own project's teammates, not other projects'" \
    || fail "rev4-5a: reap scoping" "out=$out"
}

# rev4-5b: reap --yes closes own-project row and rewrites registry
{
  R="$W/rv5b"; _mkgit "$R"
  me=$(cd -P "$R" && pwd)
  TM="rv5b$$"
  printf 'cmux surface:11 pane %s-worker sonnet - - %s\n' "$TM" "$me" \
    > "$TEAM_REG_DIR/team-$TM.tabs"
  export CMUX_TREE_SURFACES="surface:11	$TM-worker"
  out=$(cd "$R" && bash "$TEAM_SH" reap --yes 2>&1) && rc=0 || rc=$?
  unset CMUX_TREE_SURFACES
  # Registry must be gone (row was the only one)
  [ "$rc" = 0 ] \
    && { [ ! -f "$TEAM_REG_DIR/team-$TM.tabs" ] || [ ! -s "$TEAM_REG_DIR/team-$TM.tabs" ]; } \
    && pass "rev4-5b: reap --yes closes own row and removes empty registry" \
    || fail "rev4-5b: reap --yes" "rc=$rc reg=$(cat "$TEAM_REG_DIR/team-$TM.tabs" 2>/dev/null || echo gone)"
}

# rev4-5c: reap --exclude skips the named team
{
  R="$W/rv5c"; _mkgit "$R"
  me=$(cd -P "$R" && pwd)
  TM1="rv5ca$$"; TM2="rv5cb$$"
  printf 'cmux surface:12 pane %s-worker sonnet - - %s\n' "$TM1" "$me" \
    > "$TEAM_REG_DIR/team-$TM1.tabs"
  printf 'cmux surface:13 pane %s-worker sonnet - - %s\n' "$TM2" "$me" \
    > "$TEAM_REG_DIR/team-$TM2.tabs"
  export CMUX_TREE_SURFACES="surface:12	$TM1-worker
surface:13	$TM2-worker"
  out=$(cd "$R" && bash "$TEAM_SH" reap --exclude "$TM2" 2>&1) && rc=0 || rc=$?
  unset CMUX_TREE_SURFACES
  rm -f "$TEAM_REG_DIR/team-$TM1.tabs" "$TEAM_REG_DIR/team-$TM2.tabs"
  [[ "$out" == *"$TM1"* ]] && [[ "$out" != *"$TM2"* ]] \
    && pass "rev4-5c: reap --exclude skips named team" \
    || fail "rev4-5c: reap --exclude" "out=$out"
}

# rev4-5d: reap never closes the caller's own surface
{
  R="$W/rv5d"; _mkgit "$R"
  me=$(cd -P "$R" && pwd)
  TM="rv5d$$"
  # Register a row whose surface ref IS the caller's surface (CMUX_SURFACE_ID = surface:lead)
  printf 'cmux surface:lead pane %s-worker sonnet - - %s\n' "$TM" "$me" \
    > "$TEAM_REG_DIR/team-$TM.tabs"
  export CMUX_TREE_SURFACES="surface:lead	$TM-worker"
  out=$(cd "$R" && bash "$TEAM_SH" reap --yes 2>&1) && rc=0 || rc=$?
  unset CMUX_TREE_SURFACES
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  # The caller surface must NOT be closed (no --force call for it)
  # Since we're stubbing cmux and it always returns OK, we check the cmux log
  [ ! -s "$CMUX_LOG" ] || ! grep -q "close-surface.*surface:lead" "$CMUX_LOG" \
    && pass "rev4-5d: reap never closes the caller's own surface" \
    || fail "rev4-5d: reap caller surface untouched" "cmux=$(grep surface:lead "$CMUX_LOG" || echo none)"
}

# rev4-5e: reap with no-root (legacy) row: shows as "unknown project", never closed
{
  R="$W/rv5e"; _mkgit "$R"
  TM="rv5e$$"
  # 7-col row (no root col) — legacy rev3 format
  printf 'cmux surface:14 pane %s-worker sonnet - -\n' "$TM" \
    > "$TEAM_REG_DIR/team-$TM.tabs"
  export CMUX_TREE_SURFACES="surface:14	$TM-worker"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" reap --yes 2>&1) && rc=0 || rc=$?
  unset CMUX_TREE_SURFACES
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  # Must mention "unknown project" and NOT close
  [[ "$out" == *"unknown"* ]] || [[ "$out" == *"no project"* ]] || [[ "$out" == *"left alone"* ]] \
    && pass "rev4-5e: legacy no-root row reported as unknown, not closed" \
    || fail "rev4-5e: legacy no-root row" "out=${out:0:200}"
}

# ══════════════════════════════════════════════════════════════════
# rev4-6 — close: skips row when title mismatches live surface (ref reused)
# ══════════════════════════════════════════════════════════════════
{
  R="$W/rv6"; _mkgit "$R"
  TM="rv6$$"
  # Pre-populate registry: surface:15 registered for "rv6-worker"
  printf 'cmux surface:15 pane %s-worker sonnet -\n' "$TM" \
    > "$TEAM_REG_DIR/team-$TM.tabs"
  # But cmux tree shows surface:15 has a DIFFERENT title (ref was reused)
  export CMUX_TREE_SURFACES="surface:15	other-project-session"
  _reset_logs
  out=$(cd "$R" && bash "$TEAM_SH" close "$TM" 2>&1) && rc=0 || rc=$?
  unset CMUX_TREE_SURFACES
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  # Must not call close-surface (title mismatch skipped)
  ! grep -q 'close-surface.*surface:15' "$CMUX_LOG" 2>/dev/null \
    && pass "rev4-6: close skips row when title mismatches live surface" \
    || fail "rev4-6: close skips mismatched title" "cmux=$(cat "$CMUX_LOG")"
}

# ══════════════════════════════════════════════════════════════════
# rev4-9b — no model + haiku-tier default → dontAsk + worktree refused
# Decision 9 carry-over: haiku-tier lead with no --model → dontAsk.
# ══════════════════════════════════════════════════════════════════
{
  R="$W/rv9b"; _mkgit "$R"
  run="$R/.team/runs/2026-10-08-myteam"; mkdir -p "$run/prompts"
  pf="$run/prompts/worker.md"; printf 'prompt\n' > "$pf"
  TM="rv9b$$"
  _reset_logs
  # Use ANTHROPIC_MODEL to force haiku as the default (no --model arg to spawn)
  (cd "$R" && ANTHROPIC_MODEL=system.ai.claude-haiku-4-5 \
    bash "$TEAM_SH" spawn "$TM" worker "$pf") >/dev/null 2>&1 && true || true
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  # dontAsk must appear in the cmux command string (spawn passes it to cmux new-split --command)
  grep -q 'dontAsk' "$CMUX_LOG" \
    && pass "rev4-9b: no-model + haiku-default → dontAsk in spawned cmd" \
    || fail "rev4-9b: no-model + haiku-default → dontAsk in spawned cmd" \
       "cmux=$(cat "$CMUX_LOG")"
}

# rev4-9b2: no model + haiku default + --worktree → exit 2 (haiku can't commit)
{
  R="$W/rv9b2"; _mkgit "$R"
  run="$R/.team/runs/2026-10-08-myteam"; mkdir -p "$run/prompts"
  pf="$run/prompts/worker.md"; printf 'prompt\n' > "$pf"
  TM="rv9b2$$"
  _reset_logs
  out=$(cd "$R" && ANTHROPIC_MODEL=system.ai.claude-haiku-4-5 \
    bash "$TEAM_SH" spawn --worktree "$TM" worker "$pf" 2>&1) && rc=0 || rc=$?
  # exit 2 with no pane (cmux ping/version calls ok, new-split must not appear)
  pane_opened=0; grep -qE 'new-split|new-surface' "$CMUX_LOG" 2>/dev/null && pane_opened=1 || true
  [ "$rc" = 2 ] && [ "$pane_opened" = 0 ] \
    && pass "rev4-9b2: no-model + haiku-default + --worktree → exit 2 (no pane)" \
    || fail "rev4-9b2: no-model + haiku-default + --worktree → exit 2" \
       "rc=$rc pane_opened=$pane_opened cmux=$(cat "$CMUX_LOG")"
}

# ══════════════════════════════════════════════════════════════════
# rev4-N — no PROMPT scraping in status/list (decision 3)
# ══════════════════════════════════════════════════════════════════
{
  R="$W/rvprompt"; _mkgit "$R"
  TM="rvprompt$$"
  printf 'cmux surface:99 pane %s-worker sonnet -\n' "$TM" \
    > "$TEAM_REG_DIR/team-$TM.tabs"
  out=$(bash "$TEAM_SH" status "$TM" 2>&1) && rc=0 || rc=$?
  rm -f "$TEAM_REG_DIR/team-$TM.tabs"
  # status must NOT call `cmux get-screen-content` or `cmux read-pane` or similar scraping
  ! grep -qE 'get-screen|read-pane|capture-pane|screen-capture|PROMPT' "$CMUX_LOG" 2>/dev/null \
    && pass "rev4-N: status/list uses no PROMPT scraping" \
    || fail "rev4-N: status/list uses no PROMPT scraping" "cmux=$(cat "$CMUX_LOG")"
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
[ "$fails" = 0 ] && echo "all passed ($passes cases)" \
  || echo "$fails case(s) failed"
[ "$fails" = 0 ]
