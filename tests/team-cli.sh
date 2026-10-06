#!/usr/bin/env bash
# Tests for team.sh's command surface: subcommand dispatch, facts-lint robustness,
# and close. Self-contained: runs in a mktemp -d dir with a stub `cmux` on PATH, so
# no real pane is ever opened or closed. Prints PASS/FAIL per case; exit 1 on any FAIL.
#   bash tests/team-cli.sh
set -euo pipefail
TEAM_SH="$(cd "$(dirname "$0")/.." && pwd)/team.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }

# Stub cmux: logs every call; like the real one, refuses to close a surface whose
# process is alive (all of ours are) unless --force is given.
mkdir -p "$W/bin"
cat > "$W/bin/cmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/cmux.log"
case "\$1" in
  close-surface) case " \$* " in *" --force "*) echo "OK \$3" ;; *) echo "Error: confirmation_required: Surface has a running process; retry with force=true" >&2; exit 1 ;; esac ;;
esac
SH
chmod +x "$W/bin/cmux"
export PATH="$W/bin:$PATH"

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
printf 'cmux surface:1 pane t-a m\ncmux surface:2 pane t-b m\n' > /tmp/team-tcli$$.tabs
: > "$W/cmux.log"
out=$(bash "$TEAM_SH" close "tcli$$" 2>&1) && rc=0 || rc=$?
forced=$(grep -c -- '--force' "$W/cmux.log" || true)
[ $rc = 0 ] && [ "$forced" = 2 ] && [ ! -e /tmp/team-tcli$$.tabs ] && pass "close: force-closes live panes" || fail "close: force-closes live panes" "rc=$rc forced=$forced out=$out"
# A surface that cannot be closed is reported, and its row is kept for a retry.
cat > "$W/bin/cmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/cmux.log"
[ "\$1" = close-surface ] && { echo "Error: boom" >&2; exit 1; }
SH
printf 'cmux surface:9 pane t-z m\n' > /tmp/team-tcli$$.tabs
out=$(bash "$TEAM_SH" close "tcli$$" 2>&1) && rc=0 || rc=$?
[ $rc != 0 ] && [[ $out == *"could not close"* ]] && [[ $out != *"closed cmux surface:9"* ]] && grep -q 'surface:9' /tmp/team-tcli$$.tabs \
  && pass "close: failure reported, row kept" || fail "close: failure reported, row kept" "rc=$rc out=$out"
rm -f /tmp/team-tcli$$.tabs

[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
[ $fails = 0 ]
