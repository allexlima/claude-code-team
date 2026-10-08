#!/usr/bin/env bash
# Hermetic tests for lib/roles.sh.
# Sources roles.sh directly with stub helpers; never opens a real pane.
#   bash tests/roles.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }

# ---------------------------------------------------------------------------
# Stub helpers that lib/roles.sh requires from team.sh
# ---------------------------------------------------------------------------
export TEAM_ROOT="$W/repo"
export TEAM_LIB="$W/lib"

_root()      { echo "$TEAM_ROOT"; }
_roles_lib() { echo "$TEAM_LIB"; }

# Minimal secret pattern + scanner (mirrors team.sh)
secret='(dapi|dose)[0-9a-f]{32}|gh[pousr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{22,}|sk-(ant|proj|svcacct)-[0-9A-Za-z_-]{16,}|AKIA[0-9A-Z]{16}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
_secret_lines() { sed -E 's/(^|[^A-Za-z0-9._%+-])git@/\1git /g' | grep -nEi -- "$secret"; }

# Source the library under test
# shellcheck source=../lib/roles.sh
. "$HERE/lib/roles.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
setup() {
  rm -rf "$W/repo" "$W/lib"
  mkdir -p "$W/repo/.team/roles" "$W/lib"
}

write_role() {  # write_role <dir> <name> <content>
  printf '%s\n' "$3" > "$1/$2.md"
}

# ---------------------------------------------------------------------------
# 1. sub_role — resolution order and stderr note
# ---------------------------------------------------------------------------
setup
write_role "$W/repo/.team/roles" mytestrole "# Project role"
write_role "$W/lib" mytestrole "# Library role"

out=$(sub_role mytestrole 2>/dev/null) && rc=0 || rc=$?
[ $rc = 0 ] && [ "$out" = "$W/repo/.team/roles/mytestrole.md" ] \
  && pass "sub_role: project copy returned when both exist" \
  || fail "sub_role: project copy returned when both exist" "rc=$rc out=$out"

setup
write_role "$W/lib" libonly "# Library only"

stderr=$(sub_role libonly 2>&1 >/dev/null) && true || true
out=$(sub_role libonly 2>/dev/null) && rc=0 || rc=$?
[ $rc = 0 ] && [ "$out" = "$W/lib/libonly.md" ] && [[ "$stderr" == *"resolved from shared library"* ]] \
  && pass "sub_role: library fallback + stderr note (N14)" \
  || fail "sub_role: library fallback + stderr note (N14)" "rc=$rc out=$out stderr=$stderr"

setup
out=$(sub_role gone 2>&1) && rc=0 || rc=$?
[ $rc = 3 ] && pass "sub_role: exit 3 when not found" \
  || fail "sub_role: exit 3 when not found" "rc=$rc"

out=$(sub_role "bad name" 2>&1) && rc=0 || rc=$?
[ $rc = 2 ] && pass "sub_role: exit 2 on non-kebab name" \
  || fail "sub_role: exit 2 on non-kebab name" "rc=$rc"

# ---------------------------------------------------------------------------
# 2. sub_roles — status column
# ---------------------------------------------------------------------------
setup
write_role "$W/repo/.team/roles" both "# same content"
write_role "$W/lib" both "# same content"
write_role "$W/repo/.team/roles" projonly "# project"
write_role "$W/lib" libonly "# library"

out=$(sub_roles)
[[ "$out" == *"both"*"in-sync"* ]]    && pass "sub_roles: in-sync when identical"    || fail "sub_roles: in-sync when identical"
[[ "$out" == *"projonly"*"project-only"* ]] && pass "sub_roles: project-only"         || fail "sub_roles: project-only"
[[ "$out" == *"libonly"*"library-only"* ]]  && pass "sub_roles: library-only"         || fail "sub_roles: library-only"

# local-ahead: base==lib, base!=proj
setup
write_role "$W/lib" myrole "# v1"
sub_role_pull myrole >/dev/null 2>&1
echo "# v1 + local lesson" >> "$W/repo/.team/roles/myrole.md"
out=$(sub_roles)
[[ "$out" == *"myrole"*"local-ahead"* ]] && pass "sub_roles: local-ahead after local edit" \
  || fail "sub_roles: local-ahead" "out=$out"

# global-ahead: base==proj, base!=lib
setup
write_role "$W/lib" myrole "# v1"
sub_role_pull myrole >/dev/null 2>&1
echo "# v2" > "$W/lib/myrole.md"   # library updated
out=$(sub_roles)
[[ "$out" == *"myrole"*"global-ahead"* ]] && pass "sub_roles: global-ahead after library update" \
  || fail "sub_roles: global-ahead" "out=$out"

# diverged: both changed
setup
write_role "$W/lib" myrole "# v1"
sub_role_pull myrole >/dev/null 2>&1
echo "# v2-lib" > "$W/lib/myrole.md"
echo "# v2-local" > "$W/repo/.team/roles/myrole.md"
out=$(sub_roles)
[[ "$out" == *"myrole"*"diverged"* ]] && pass "sub_roles: diverged when both changed" \
  || fail "sub_roles: diverged" "out=$out"

# diverged (no base)
setup
write_role "$W/repo/.team/roles" myrole "# project"
write_role "$W/lib" myrole "# different library"
out=$(sub_roles)
[[ "$out" == *"myrole"*"diverged (no base)"* ]] && pass "sub_roles: diverged (no base) when no .base/ exists" \
  || fail "sub_roles: diverged (no base)" "out=$out"

# ---------------------------------------------------------------------------
# 3. sub_role_pull
# ---------------------------------------------------------------------------

# fresh pull (no local copy)
setup
write_role "$W/lib" myrole "# library v1"
out=$(sub_role_pull myrole 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && [ -f "$W/repo/.team/roles/myrole.md" ] && [ -f "$W/repo/.team/roles/.base/myrole.md" ] \
  && pass "sub_role_pull: fresh pull writes dst and .base/" \
  || fail "sub_role_pull: fresh pull" "rc=$rc out=$out"

# already up-to-date
out=$(sub_role_pull myrole 2>&1) && rc=0 || rc=$?
[ $rc = 1 ] && [[ "$out" == *"already up-to-date"* ]] \
  && pass "sub_role_pull: exit 1 when already up-to-date" \
  || fail "sub_role_pull: exit 1 already up-to-date" "rc=$rc out=$out"

# fast-forward: local unchanged, library updated
setup
write_role "$W/lib" myrole "# v1"
sub_role_pull myrole >/dev/null 2>&1
echo "# v2" > "$W/lib/myrole.md"
out=$(sub_role_pull myrole 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && grep -q 'v2' "$W/repo/.team/roles/myrole.md" \
  && pass "sub_role_pull: fast-forward when local unchanged" \
  || fail "sub_role_pull: fast-forward" "rc=$rc out=$out"

# diverged — refuses without --force
setup
write_role "$W/lib" myrole "# v1"
sub_role_pull myrole >/dev/null 2>&1
echo "# v2-lib" > "$W/lib/myrole.md"
echo "# v2-local" > "$W/repo/.team/roles/myrole.md"
out=$(sub_role_pull myrole 2>&1) && rc=0 || rc=$?
[ $rc = 5 ] && [[ "$out" == *"diverged"* ]] \
  && pass "sub_role_pull: exit 5 on diverged without --force" \
  || fail "sub_role_pull: exit 5 diverged" "rc=$rc out=$out"

# diverged — --force succeeds
out=$(sub_role_pull myrole --force 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && grep -q 'v2-lib' "$W/repo/.team/roles/myrole.md" \
  && pass "sub_role_pull: --force overwrites diverged local" \
  || fail "sub_role_pull: --force" "rc=$rc out=$out"

# no base, differs — refuses without --force
setup
write_role "$W/lib" myrole "# library"
write_role "$W/repo/.team/roles" myrole "# different local"
out=$(sub_role_pull myrole 2>&1) && rc=0 || rc=$?
[ $rc = 5 ] \
  && pass "sub_role_pull: exit 5 when no base and differs" \
  || fail "sub_role_pull: exit 5 no base" "rc=$rc out=$out"

# exit 3 when not in library
setup
out=$(sub_role_pull notexist 2>&1) && rc=0 || rc=$?
[ $rc = 3 ] && pass "sub_role_pull: exit 3 when not in library" \
  || fail "sub_role_pull: exit 3" "rc=$rc"

# ---------------------------------------------------------------------------
# 4. sub_role_promote
# ---------------------------------------------------------------------------

# fresh promote (library copy absent)
setup
write_role "$W/repo/.team/roles" myrole "# my role"
out=$(sub_role_promote myrole 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && [ -f "$W/lib/myrole.md" ] && [ -f "$W/repo/.team/roles/.base/myrole.md" ] \
  && pass "sub_role_promote: fresh promote writes lib and .base/" \
  || fail "sub_role_promote: fresh promote" "rc=$rc out=$out"

# already up-to-date
out=$(sub_role_promote myrole 2>&1) && rc=0 || rc=$?
[ $rc = 1 ] && [[ "$out" == *"already up-to-date"* ]] \
  && pass "sub_role_promote: exit 1 when already up-to-date" \
  || fail "sub_role_promote: exit 1" "rc=$rc"

# fast-forward: library unchanged since base, local has new content
setup
write_role "$W/repo/.team/roles" myrole "# v1"
sub_role_promote myrole >/dev/null 2>&1
echo "# v1 + lesson" >> "$W/repo/.team/roles/myrole.md"
out=$(sub_role_promote myrole 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && grep -q 'lesson' "$W/lib/myrole.md" \
  && pass "sub_role_promote: fast-forward when library unchanged" \
  || fail "sub_role_promote: fast-forward" "rc=$rc out=$out"

# global-ahead: library changed, local unchanged — refuses even with --force (N13)
setup
write_role "$W/repo/.team/roles" myrole "# v1"
sub_role_promote myrole >/dev/null 2>&1
echo "# v2-lib" > "$W/lib/myrole.md"   # library updated externally
out=$(sub_role_promote myrole 2>&1) && rc=0 || rc=$?
[ $rc = 5 ] && [[ "$out" == *"role-pull"* ]] \
  && pass "sub_role_promote: global-ahead exits 5 directing to role-pull" \
  || fail "sub_role_promote: global-ahead" "rc=$rc out=$out"
out=$(sub_role_promote myrole --force 2>&1) && rc=0 || rc=$?
[ $rc = 5 ] \
  && pass "sub_role_promote: global-ahead refuses --force (N13)" \
  || fail "sub_role_promote: global-ahead refuses --force (N13)" "rc=$rc"

# diverged — refuses without --force
setup
write_role "$W/repo/.team/roles" myrole "# v1"
sub_role_promote myrole >/dev/null 2>&1
echo "# v2-lib" > "$W/lib/myrole.md"
echo "# v2-local" > "$W/repo/.team/roles/myrole.md"
out=$(sub_role_promote myrole 2>&1) && rc=0 || rc=$?
[ $rc = 5 ] && [[ "$out" == *"diverged"* ]] \
  && pass "sub_role_promote: exit 5 on diverged without --force" \
  || fail "sub_role_promote: exit 5 diverged" "rc=$rc out=$out"

# diverged — --force succeeds
out=$(sub_role_promote myrole --force 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && grep -q 'v2-local' "$W/lib/myrole.md" \
  && pass "sub_role_promote: --force overwrites diverged library" \
  || fail "sub_role_promote: --force" "rc=$rc out=$out"

# no base, differs — refuses without --force
setup
write_role "$W/repo/.team/roles" myrole "# local"
write_role "$W/lib" myrole "# different library"
out=$(sub_role_promote myrole 2>&1) && rc=0 || rc=$?
[ $rc = 5 ] \
  && pass "sub_role_promote: exit 5 when no base and differs" \
  || fail "sub_role_promote: exit 5 no base" "rc=$rc"

# exit 3 when not in project
setup
out=$(sub_role_promote notexist 2>&1) && rc=0 || rc=$?
[ $rc = 3 ] && pass "sub_role_promote: exit 3 when not in project" \
  || fail "sub_role_promote: exit 3" "rc=$rc"

# secret/PII guard — exit 2
setup
printf '# role\ncontact=user@example.com\n' > "$W/repo/.team/roles/badpii.md"
out=$(sub_role_promote badpii 2>&1) && rc=0 || rc=$?
[ $rc = 2 ] && [ ! -f "$W/lib/badpii.md" ] \
  && pass "sub_role_promote: exit 2 on PII, no file written" \
  || fail "sub_role_promote: PII guard" "rc=$rc out=$out"

# mkdir -p: library dir does not pre-exist
setup
rm -rf "$W/lib"
write_role "$W/repo/.team/roles" myrole "# ok"
out=$(sub_role_promote myrole 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && [ -f "$W/lib/myrole.md" ] \
  && pass "sub_role_promote: mkdir -p creates library dir" \
  || fail "sub_role_promote: mkdir -p" "rc=$rc"

# ---------------------------------------------------------------------------
echo
[ $fails = 0 ] && echo "All tests passed." || echo "$fails test(s) FAILED."
exit $fails
