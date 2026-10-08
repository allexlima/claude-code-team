#!/usr/bin/env bash
# Tests for team.sh's command surface: subcommand dispatch, facts-lint robustness,
# close, and the facts-lint secret/PII scan. Self-contained: runs in a mktemp -d dir with a stub `cmux` on PATH, so
# no real pane is ever opened or closed. Prints PASS/FAIL per case; exit 1 on any FAIL.
#   bash tests/team-cli.sh
set -euo pipefail
TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/team.sh}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }

# Stub cmux: handles ping, --version, tree (configurable via CMUX_TREE_SURFACES file),
# and close-surface. Use CMUX_CLOSE_FAIL=1 to make closes fail; never replace the stub.
mkdir -p "$W/bin"
CMUX_LOG="$W/cmux.log"
CMUX_TREE_FILE="$W/tree_surfaces.tsv"  # tab-sep "ref<TAB>title" per line
# Make CMUX_TREE_FILE available to the stub via env (written by tests before each close call)
export CMUX_LOG CMUX_TREE_FILE
cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
case "$1" in
  ping) echo PONG ;;
  --version) echo "cmux 0.65.0 (108) stub" ;;
  close-surface)
    [ "${CMUX_CLOSE_FAIL:-}" = 1 ] && { echo "Error: boom" >&2; exit 1; }
    case " $* " in *" --force "*) echo "OK" ;; *) echo "Error: confirmation_required: Surface has a running process; retry with force=true" >&2; exit 1 ;; esac ;;
  tree)
    jout='{"workspaces":[{"ref":"workspace:1","surfaces":['
    first=1
    [ -f "${CMUX_TREE_FILE:-}" ] && while IFS=$(printf '\t') read -r ref title; do
      [ -n "$ref" ] || continue
      [ "$first" = 1 ] || jout+=","
      jout+="{\"ref\":\"$ref\",\"title\":\"$title\"}"
      first=0
    done < "$CMUX_TREE_FILE"
    jout+=']}]}'
    echo "$jout" ;;
esac
SH
chmod +x "$W/bin/cmux"
export PATH="$W/bin:$PATH"
# Redirect registries to scratch dir (never touch /tmp/team-*.tabs of live projects)
export TEAM_REG_DIR="$W/reg"
mkdir -p "$W/reg"

# 1. Unknown subcommands never reach the spawn path (which opens a real pane).
for args in "bogus" "bogus a b c" "spwan t r p.md sonnet" "--worktree t r p.md"; do
  : > "$W/cmux.log"
  # shellcheck disable=SC2086
  out=$(cd "$W" && bash "$TEAM_SH" $args 2>&1) && rc=0 || rc=$?
  [ $rc = 2 ] && [[ $out == *"unknown subcommand"* ]] && [ ! -s "$W/cmux.log" ] \
    && pass "dispatch: '$args' refused" || fail "dispatch: '$args' refused" "rc=$rc out=${out:0:120} cmux=$(cat "$W/cmux.log")"
done
out=$(bash "$TEAM_SH" --help 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && [[ $out == *"team.sh spawn"* ]] && pass "dispatch: --help prints usage" || fail "dispatch: --help prints usage" "rc=$rc"
out=$(bash "$TEAM_SH" 2>&1) && rc=0 || rc=$?
[ $rc = 2 ] && [[ $out == *"team.sh spawn"* ]] && pass "dispatch: no subcommand prints usage" || fail "dispatch: no subcommand prints usage" "rc=$rc"
out=$(cd "$W" && bash "$TEAM_SH" spawn onlyteam 2>&1) && rc=0 || rc=$?
[ $rc != 0 ] && [[ $out != *"unbound variable"* ]] && pass "dispatch: spawn with too few args explains" || fail "dispatch: spawn with too few args explains" "rc=$rc out=${out:0:120}"

# 2. facts-lint checks every fact, including ones whose evidence has no file:line.
R="$W/repo"; mkdir -p "$R/.team"; git -C "$R" init -q
printf '# Facts\n\n- first fact — evidence: live probe @nogit — 2026-10-06, run r\n- second fact — evidence: a.sh:3 @nogit — 2026-10-06, run r\n- third fact — evidence: command output — 2026-10-06, run r\n' > "$R/.team/facts.md"
out=$(cd "$R" && bash "$TEAM_SH" facts-lint 2>&1) && rc=0 || rc=$?
n=$(printf '%s\n' "$out" | grep -c $'^NOANCHOR\t' || true)
[ $rc = 0 ] && [ "$n" = 3 ] && pass "facts-lint: no-file:line facts don't abort" || fail "facts-lint: no-file:line facts don't abort" "rc=$rc out=$out"

# 3. close really closes live panes, and says so only when it did.
# TEAM_REG_DIR redirects to $W/reg; CMUX_TREE_FILE makes surfaces appear live.
TCLI="tcli$$"
printf 'cmux surface:1 pane t-a m\ncmux surface:2 pane t-b m\n' > "$TEAM_REG_DIR/team-$TCLI.tabs"
printf 'surface:1\tt-a\nsurface:2\tt-b\n' > "$CMUX_TREE_FILE"
: > "$CMUX_LOG"
out=$(bash "$TEAM_SH" close "$TCLI" 2>&1) && rc=0 || rc=$?
forced=$(grep -c -- '--force' "$CMUX_LOG" || true)
[ $rc = 0 ] && [ "$forced" = 2 ] && [ ! -e "$TEAM_REG_DIR/team-$TCLI.tabs" ] \
  && pass "close: force-closes live panes" \
  || fail "close: force-closes live panes" "rc=$rc forced=$forced out=$out"
# A surface that cannot be closed is reported, and its row is kept for a retry.
printf 'cmux surface:9 pane t-z m\n' > "$TEAM_REG_DIR/team-$TCLI.tabs"
printf 'surface:9\tt-z\n' > "$CMUX_TREE_FILE"
: > "$CMUX_LOG"
out=$(CMUX_CLOSE_FAIL=1 bash "$TEAM_SH" close "$TCLI" 2>&1) && rc=0 || rc=$?
[ $rc != 0 ] && [[ $out == *"could not close"* ]] && [[ $out != *"closed cmux surface:9"* ]] \
  && grep -q 'surface:9' "$TEAM_REG_DIR/team-$TCLI.tabs" \
  && pass "close: failure reported, row kept" \
  || fail "close: failure reported, row kept" "rc=$rc out=$out"
rm -f "$TEAM_REG_DIR/team-$TCLI.tabs" "$CMUX_TREE_FILE"

# 4. facts-lint --pre-append refuses secrets/PII and lets git remotes through. Every
# token is assembled at run time so this file never holds a literal secret.
h32=$(printf 'a%.0s' {1..32}); a36=$(printf 'A%.0s' {1..36})
for t in "dap""i$h32" "dos""e$h32" "gh""p_$a36" "gh""o_$a36" "gh""u_$a36" "gh""s_$a36" "gh""r_$a36" \
         "github""_pat_$a36" "sk-""ant-api03-$a36" "sk-""proj-$a36" "sk-""svcacct-$a36" "sk-""$a36" "AKI""A$(printf 'B%.0s' {1..16})" \
         "xo""xb-1234567890-abcdefghij" "xo""xp-1234567890-abcdefghij" "xa""pp-1-A012345-abcdef0123" \
         "-----BEGIN RSA PRIV""ATE KEY-----" "-----BEGIN PRIV""ATE KEY-----" \
         "ey""JhbGciOiJIUzI1NiJ9.ey""JzdWIiOiIxMjM0NTY3ODkwIn0" \
         "mail alice""@example.com today" "mail alice""@example.com." "alice""@example.com" \
         "contact: alice""@example.com: ping" "see alice""@example.com/profile" "ssh://deploy""@example.com:22/x"; do
  printf -- '- fact %s — evidence: x:1\n' "$t" > "$W/scan.md"
  bash "$TEAM_SH" facts-lint --pre-append "$W/scan.md" >/dev/null 2>&1 && rc=0 || rc=$?
  [ $rc = 2 ] && pass "secret refused: ${t:0:12}…" || fail "secret refused: ${t:0:12}…" "rc=$rc"
done
for t in "origin git@github.com:acme/widgets.git" "ssh://git@github.com/acme/widgets" \
         "ssh://git@github.com:22/acme/widgets.git" "git@gitlab.example.com:a/b" "evidence team.sh:45 @327cfc2"; do
  printf -- '- fact %s — evidence: x:1\n' "$t" > "$W/scan.md"
  bash "$TEAM_SH" facts-lint --pre-append "$W/scan.md" >/dev/null 2>&1 && rc=0 || rc=$?
  [ $rc = 0 ] && pass "not a secret: $t" || fail "not a secret: $t" "rc=$rc"
done

[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
[ $fails = 0 ]
