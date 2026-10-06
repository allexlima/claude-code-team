#!/usr/bin/env bash
# Tests for team.sh mem-sync / mem-recall (the optional Ruflo memory bridge).
# Self-contained: every case runs in a mktemp -d dir, with TEAM_MEMORY_DB and
# TEAM_ROLES_DIR pointed into it, so the user's real memory DB and role library
# are never read or written. Cases that need a working ruflo are skipped (not
# failed) when it is absent. Prints PASS/FAIL/SKIP per case; exit 1 on any FAIL.
#   bash tests/memory-bridge.sh
set -euo pipefail
TEAM_SH="$(cd "$(dirname "$0")/.." && pwd)/team.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export TEAM_MEMORY_DB="$W/db/memory.db" TEAM_ROLES_DIR="$W/lib"
mkdir -p "$W/lib"
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }
skip() { echo "SKIP  $1${2:+ — $2}"; }

# PATH with every ruflo-providing dir removed (the "not installed" case).
nopath=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
  [ -n "$d" ] && [ ! -x "$d/ruflo" ] && printf '%s:' "$d"; done)
nopath=${nopath%:}

# A git repo with an origin, a facts ledger, and one project role with a lesson.
mkrepo() {  # <dir> <origin-url> <fact-line>...
  local d=$1 url=$2; shift 2
  mkdir -p "$d/.team/roles"
  git -C "$d" init -q
  git -C "$d" remote add origin "$url"
  { printf '# Facts\n\n<!-- - <fact> — evidence: … -->\n'; for f in "$@"; do printf -- '- %s\n' "$f"; done; } > "$d/.team/facts.md"
}
count_ns() {  # entries in namespaces matching prefix $1 (real ruflo, temp DB)
  (cd "$W" && ruflo memory list --path "$TEAM_MEMORY_DB" --limit 100000 --format json 2>/dev/null) | python3 -c '
import json, re, sys
t = sys.stdin.read()
for m in re.finditer(r"[\[{]", t):
    try: v = json.JSONDecoder().raw_decode(t[m.start():])[0]; break
    except ValueError: pass
else: v = []
print(sum(1 for e in v if e.get("namespace", "").startswith(sys.argv[1])))' "$1"
}

# 1. ruflo absent -> skip message, exit 0
out=$(cd "$W" && PATH="$nopath" bash "$TEAM_SH" mem-sync 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && [[ $out == *"ruflo not installed — skipping"* ]] && pass "absent: mem-sync skips" || fail "absent: mem-sync skips" "rc=$rc out=$out"
out=$(cd "$W" && PATH="$nopath" bash "$TEAM_SH" mem-recall "x" 2>&1 >/dev/null) && rc=0 || rc=$?
[ $rc = 0 ] && [[ $out == *"ruflo not installed"* ]] && pass "absent: mem-recall skips on stderr" || fail "absent: mem-recall skips on stderr" "rc=$rc out=$out"

# 2. installed but broken: store claims success, retrieve finds nothing
mkdir -p "$W/stub"
cat > "$W/stub/ruflo" <<'SH'
#!/usr/bin/env bash
case "$2" in store) echo "[OK] Data stored successfully" ;; *) echo "[WARN] Key not found"; exit 1 ;; esac
SH
chmod +x "$W/stub/ruflo"
out=$(cd "$W" && PATH="$W/stub:$nopath" bash "$TEAM_SH" mem-sync 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && [[ $out == *"not persisting — skipping"* ]] && pass "broken: mem-sync skips" || fail "broken: mem-sync skips" "rc=$rc out=$out"
out=$(cd "$W" && PATH="$W/stub:$nopath" bash "$TEAM_SH" mem-recall "x" 2>&1 >/dev/null) && rc=0 || rc=$?
[ $rc = 0 ] && [[ $out == *"not persisting"* ]] && pass "broken: mem-recall skips" || fail "broken: mem-recall skips" "rc=$rc out=$out"

if ! command -v ruflo >/dev/null; then
  skip "live cases" "ruflo not installed"
  [ $fails = 0 ]; exit
fi

A="$W/a" B="$W/b"
mkrepo "$A" "git@github.com:acme/widgets.git" \
  "The deploy script requires python3 to parse JSON output — evidence: deploy.sh:4" \
  "~~The cache layer uses Redis~~ replaced by memcached — evidence: cache.sh:9"
printf '**Lens:** x\n\n**Lessons:**\n- Always probe the external CLI live in a temp dir before relying on it\n' > "$A/.team/roles/impl.md"
mkrepo "$B" "https://github.com/acme/gadgets.git" \
  "Billing invoices are generated nightly by a cron job — evidence: billing.py:12"

# 3. a secret in facts -> exit 2, nothing stored (token built at run time, never literal)
S="$W/s"; mkrepo "$S" "git@github.com:acme/secrets.git" "token dapi$(printf '0%.0s' {1..32}) leaked — evidence: x:1"
out=$(cd "$S" && bash "$TEAM_SH" mem-sync 2>&1) && rc=0 || rc=$?
n=$(count_ns team-)
[ $rc = 2 ] && [ "$n" = 0 ] && pass "secret: refuse, exit 2, nothing stored" || fail "secret: refuse, exit 2, nothing stored" "rc=$rc entries=$n out=$out"

# 4. round trip: sync, then recall a fact by meaning (not by keyword)
out=$(cd "$A" && bash "$TEAM_SH" mem-sync 2>&1) && rc=0 || rc=$?
[ $rc = 0 ] && [[ $out == "mem-sync: 2 facts (1 stale), 1 lessons -> $TEAM_MEMORY_DB" ]] && pass "sync: counts" || fail "sync: counts" "rc=$rc out=$out"
hit=$(cd "$A" && bash "$TEAM_SH" mem-recall "which interpreter is needed for deployment")
[[ $(printf '%s\n' "$hit" | head -1) == fact$'\t'*$'\t'"The deploy script requires python3"* ]] && pass "recall: fact found by meaning" || fail "recall: fact found by meaning" "$hit"
hit=$(cd "$A" && bash "$TEAM_SH" mem-recall "test an outside command before trusting it")
[[ $hit == *lesson$'\t'*"Always probe the external CLI"* ]] && pass "recall: lesson found" || fail "recall: lesson found" "$hit"
[ -z "$(git -C "$A" status --short --untracked-files=all | grep -v '^?? .team/' || true)" ] && pass "no ruflo junk in the project dir" || fail "no ruflo junk in the project dir" "$(git -C "$A" status --short)"

hit=$(cd "$A" && bash "$TEAM_SH" mem-recall -- "--deploy needs python3") && rc=0 || rc=$?
[ $rc = 0 ] && [[ $hit == *"The deploy script"* ]] && pass "recall: query starting with -" || fail "recall: query starting with -" "rc=$rc $hit"

# 5. struck-through fact is stored as stale
ns=$(cd "$W" && ruflo memory list --path "$TEAM_MEMORY_DB" --format json 2>/dev/null | grep -o '"team-facts-[0-9a-f]*"' | head -1 | tr -d '"')
key=$(printf '%s' "- The cache layer uses Redis replaced by memcached — evidence: cache.sh:9" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())')
tags=$(cd "$W" && ruflo memory retrieve --path "$TEAM_MEMORY_DB" -k "$key" -n "$ns" --format json 2>/dev/null || true)
[[ $tags == *'"status:stale"'* && $tags == *'"project:github.com/acme/widgets"'* ]] && pass "struck fact tagged stale" || fail "struck fact tagged stale" "$tags"

# 6. re-sync is idempotent
before=$(count_ns team-)
(cd "$A" && bash "$TEAM_SH" mem-sync >/dev/null)
after=$(count_ns team-)
[ "$before" = 3 ] && [ "$after" = 3 ] && pass "re-sync idempotent" || fail "re-sync idempotent" "before=$before after=$after"

# 7. a removed line disappears after re-sync
sed -i.bak '/cache layer/d' "$A/.team/facts.md"
printf -- '- \n-   \n' >> "$A/.team/facts.md"   # empty bullets are skipped, not a store failure
out=$(cd "$A" && bash "$TEAM_SH" mem-sync)
[[ $out == "mem-sync: 1 facts (0 stale), 1 lessons"* ]] && [ "$(count_ns team-facts-)" = 1 ] && pass "removed line gone" || fail "removed line gone" "$out"

# 8. two projects in one DB: no leak without --all-projects, visible with it
(cd "$B" && bash "$TEAM_SH" mem-sync >/dev/null)
hit=$(cd "$A" && bash "$TEAM_SH" mem-recall "when are invoices created")
[[ $hit != *Billing* ]] && pass "projects isolated by default" || fail "projects isolated by default" "$hit"
hit=$(cd "$A" && bash "$TEAM_SH" mem-recall --all-projects "when are invoices created")
[[ $hit == *"fact:github.com/acme/gadgets"$'\t'*Billing* ]] && pass "--all-projects sees other projects" || fail "--all-projects sees other projects" "$hit"

# 9. a git worktree of a repo gets the same project id (and its .team/ facts)
git -C "$A" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t.t commit -q --allow-empty -m init
git -C "$A" worktree add -q "$W/a-wt" -b wt
hit=$(cd "$W/a-wt" && bash "$TEAM_SH" mem-recall "which interpreter is needed for deployment")
[[ $hit == fact$'\t'*"The deploy script"* ]] && pass "worktree shares project id" || fail "worktree shares project id" "$hit"
out=$(cd "$W/a-wt" && bash "$TEAM_SH" mem-sync)
[[ $out == "mem-sync: 1 facts (0 stale), 1 lessons"* ]] && [ "$(count_ns team-facts-)" = 2 ] && pass "worktree sync reuses namespace" || fail "worktree sync reuses namespace" "$out facts=$(count_ns team-facts-)"

# 10. no origin: id falls back to <basename>-<hash>, distinct per path
mkdir -p "$W/c1/proj" "$W/c2/proj"
for c in c1 c2; do git -C "$W/$c/proj" init -q; mkdir -p "$W/$c/proj/.team"; printf -- '- Fact from %s about the release train schedule\n' "$c" > "$W/$c/proj/.team/facts.md"; (cd "$W/$c/proj" && bash "$TEAM_SH" mem-sync >/dev/null); done
hit=$(cd "$W/c1/proj" && bash "$TEAM_SH" mem-recall --limit 10 "release train schedule")
[[ $hit == *"from c1"* && $hit != *"from c2"* ]] && pass "no-origin repos stay distinct" || fail "no-origin repos stay distinct" "$hit"

# 11. origin URL forms normalize to one id (ssh://user@Host:port/… == git@host:…)
D="$W/d"; mkrepo "$D" "ssh://git@GitHub.com:22/Acme/Widgets.git"
hit=$(cd "$D" && bash "$TEAM_SH" mem-recall "which interpreter is needed for deployment")
[[ $hit == fact$'\t'*"The deploy script"* ]] && pass "origin forms share an id" || fail "origin forms share an id" "$hit"

[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
[ $fails = 0 ]
