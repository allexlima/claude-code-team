#!/usr/bin/env bash
# Run each teammate as an interactive `claude` session in its own tab/pane.
#   team.sh spawn [--tmux] [--tabs] [--worktree] [--no-caveman] <team> <role> <prompt-file> [model]
#   team.sh close <team>  -> force-closes every recorded pane/tab; exit 1 (rows kept for a retry) if one could not be closed
#   team.sh init <team>   -> creates .team/ (idempotent) + a run dir; prints the run dir path
#   team.sh gate-init     -> sets up the no-mistakes gate for this repo (needs an "origin" remote)
#   team.sh clean <team>  -> removes the team's worktrees that have no uncommitted changes (branches kept)
#   team.sh park <team> <role>  -> fold an idle teammate's pane into a tab (keeps it running)
#   team.sh show <team> <role>  -> bring a parked teammate back into its own pane
#   team.sh list <team>         -> each teammate: working / parked / closed
#   team.sh models              -> models available here, best tier first
#   team.sh role <name>         -> print a role spec path (project override, then shared library); exit 3 if none
#   team.sh roles               -> list roles available here: "<name>  project|user  <path>"
#   team.sh facts-lint [--pre-append <file>]  -> freshness of .team/facts.md facts (FRESH/CHECK/GONE/NOANCHOR + DUP); --pre-append scans <file> for secrets
#   team.sh mem-sync            -> optional Ruflo index: sync this project's facts + all role Lessons into the memory DB
#                                  (incremental; prints "N facts (S stale), M lessons -> <db> (+added/changed -removed)";
#                                  skips, exit 0, if ruflo is absent or not persisting; exit 2 on a secret/PII hit, nothing written)
#   team.sh mem-recall [--all-projects] [--limit N] "<query>"  -> semantic search; prints <kind>TAB<score>TAB<text>
#                                  (kind fact|lesson:<role>, or fact:<project-id> with --all-projects; default limit 5)
#   team.sh doccheck            -> doc drift guard: retired phrases, subcommands documented, SKILL flags present in HELP
#   team.sh --help              -> prints this header. Any other unknown subcommand exits 2 (it never falls through to spawn).
# --worktree: the teammate works in its own git worktree .team/worktrees/<team>-<role>
# on a new branch team/<team>-<role> (from the current HEAD), like a separate person.
# Each new worktree is pre-accepted in ~/.claude.json so the workspace-trust prompt
# does not appear in every pane (a worktree is its own git top-level, so it cannot inherit it).
# Every pane/tab is titled <team>-<role> (Claude's own terminal-title updates are disabled so it sticks).
# Every teammate gets teammate-rules.md appended to its system prompt (parallelise with
# subagents, verify what they return), plus the caveman output style unless --no-caveman.
# Backend: a cmux tab in the lead's workspace when running inside cmux, else a tmux pane
# (splits the lead's window inside tmux, otherwise a detached session "team-<team>").
# cmux default: split the lead's tab — teammates fill a two-column grid to the right of the lead.
# --tabs (cmux): one tab per teammate instead. --tmux forces tmux.
# Memory DB: ${TEAM_MEMORY_DB:-~/.claude/team/memory.db} (passed to every ruflo call as --path).
# Teammates start in auto permission mode (override with TEAM_PERMISSION_MODE). Spawned tabs/panes are recorded in /tmp/team-<team>.tabs for close.
set -euo pipefail
# Dispatch: anything not listed is refused here, because an unknown word would
# otherwise fall through to the spawn path below and open a real pane.
subs="init gate-init clean close models role roles facts-lint mem-sync mem-recall doccheck park show list spawn"
_usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
case ${1:-} in
  -h|--help|help) _usage; exit 0 ;;
  '') _usage >&2; exit 2 ;;
esac
case " $subs " in
  *" $1 "*) ;;
  *) echo "team.sh: unknown subcommand '$1' (see: team.sh --help)" >&2; exit 2 ;;
esac
sub=$1; shift
# Secret/PII pattern (grep -Ei). One definition: facts-lint --pre-append and mem-sync both
# refuse on a hit, and both scan through _secret_lines (stdin -> "n:line" per hit).
# Git remotes (git@host:org/repo, ssh://git@host/...) are not emails: _secret_lines turns
# the "git@" user into "git " first, so every other address still hits, whatever follows it.
secret='(dapi|dose)[0-9a-f]{32}|gh[pousr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{22,}|sk-(ant|proj|svcacct)-[0-9A-Za-z_-]{16,}|sk-[0-9A-Za-z]{16}|AKIA[0-9A-Z]{16}|(xox[abposr]|xapp)-[0-9A-Za-z-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[0-9A-Za-z_-]{8,}\.eyJ[0-9A-Za-z_-]{8,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
_secret_lines() { sed -E 's/(^|[^A-Za-z0-9._%+-])git@/\1git /g' | grep -nEi -- "$secret"; }

if [ "$sub" = init ]; then
  team=${1:?team}
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  d="$root/.team"
  mkdir -p "$d/roles" "$d/runs" "${TEAM_ROLES_DIR:-$HOME/.claude/team/roles}"
  [ -f "$d/README.md" ] || cat > "$d/README.md" <<'MD'
# .team — /team skill workspace (git-ignored)
- `facts.md` — verified facts from past runs (consensus only, with evidence). Read before working; flag stale entries.
- `roles/<role>.md` — reusable teammate role specs (lens, owns, constraints, model).
- `runs/<date>-<team>/` — per run: `tasks.md`, `prompts/`, `reports/`, `synthesis.md`.
Never store secrets, PII, or raw data here — conclusions and pointers only.
MD
  [ -f "$d/facts.md" ] || printf '# Facts

<!-- - <fact> — evidence: <file:line | command> @<short-sha> — <YYYY-MM-DD>, run <run-id>  (@nogit outside a repo) -->
' > "$d/facts.md"
  if git -C "$root" rev-parse 2>/dev/null; then
    for p in .team/ CLAUDE.local.md; do
      git -C "$root" check-ignore -q "$p" 2>/dev/null || echo "$p" >> "$root/.gitignore"
    done
  fi
  mem="$root/CLAUDE.local.md"
  grep -q '<!-- team-skill -->' "$mem" 2>/dev/null || cat >> "$mem" <<'MD'

<!-- team-skill -->
## /team workspace
`.team/` (git-ignored) holds /team skill state: `.team/facts.md` = verified facts from past team runs (read before investigating this project; treat entries as leads to re-check, not ground truth), `.team/roles/` = reusable teammate roles, `.team/runs/` = past run records.
MD
  run="$d/runs/$(date +%Y-%m-%d)-$team"
  mkdir -p "$run/prompts" "$run/reports"
  echo "$run"
  exit 0
fi

if [ "$sub" = gate-init ]; then
  command -v no-mistakes >/dev/null || { echo "no-mistakes not installed; gate skipped"; exit 3; }
  git remote get-url origin >/dev/null 2>&1 || { echo "no origin remote; gate skipped"; exit 3; }
  git remote get-url no-mistakes >/dev/null 2>&1 && { echo "gate already set up"; exit 0; }
  no-mistakes init
  exit 0
fi

if [ "$sub" = clean ]; then
  team=${1:?team}
  root=$(git rev-parse --show-toplevel)
  for wt in "$root"/.team/worktrees/"$team"-*; do
    [ -d "$wt" ] || continue
    if git -C "$root" worktree remove "$wt" 2>/dev/null; then echo "removed $wt"
    else echo "kept $wt (uncommitted changes)"; fi
  done
  exit 0
fi

if [ "$sub" = close ]; then
  team=${1:?team}; reg="/tmp/team-$team.tabs"
  [ -f "$reg" ] || { echo "no tabs recorded for $team"; exit 0; }
  # Teammates are live claude sessions, and cmux refuses to close a surface with a
  # running process unless forced. A pane that is already gone counts as closed;
  # any other failure is reported and its row kept, so a re-run can retry it.
  keep=""
  while IFS= read -r row; do
    read -r backend id _ <<<"$row"
    case $backend in
      cmux) err=$(cmux close-surface --surface "$id" --force 2>&1 >/dev/null) && err= ;;
      tmux) err=$(tmux kill-pane -t "$id" 2>&1) && err= ;;
      *) err= ;;
    esac
    case $err in *not_found*|*"can't find"*) err= ;; esac
    if [ -z "$err" ]; then echo "closed $backend $id"
    else echo "could not close $backend $id: $err" >&2; keep+="$row"$'\n'; fi
  done < "$reg"
  [ -z "$keep" ] && { rm -f "$reg"; exit 0; }
  printf '%s' "$keep" > "$reg"; exit 1
fi

# Models available here. The option list is org-managed (managed-settings.json) and
# changes without notice, so it is read at run time instead of hardcoded. Emits
# "<label>TAB<id>TAB<tier>", best tier first. `behavesAs` is the capability tier a
# model is gated at, which is what decides whether it fits a role.
_team_models() {
  python3 - <<'PY'
import json, os, re
options = None
for path in ("/Library/Application Support/ClaudeCode/managed-settings.json",
             os.path.expanduser("~/.claude/settings.json")):
    try:
        with open(path, encoding="utf-8") as fh:
            picker = json.load(fh).get("modelPicker") or {}
    except Exception:
        continue
    if picker.get("options"):
        options = picker["options"]
        break

rows = []
if options:
    for o in options:
        mid = o.get("model") or ""
        if not mid:
            continue
        hit = re.search(r"opus|sonnet|haiku", o.get("behavesAs") or mid)
        rows.append((o.get("label") or mid, mid, hit.group(0) if hit else "?"))
else:
    # No managed picker: the built-in aliases are all that can be relied on.
    rows = [("Opus", "opus", "opus"), ("Sonnet", "sonnet", "sonnet"), ("Haiku", "haiku", "haiku")]

order = {"opus": 0, "sonnet": 1, "haiku": 2, "?": 3}
rows.sort(key=lambda r: order.get(r[2], 3))
for r in rows:
    print("\t".join(r))
PY
}

if [ "$sub" = models ]; then
  _team_models | awk -F'\t' '
    {l[NR]=$1; m[NR]=$2; t[NR]=$3
     if (length($1)>a) a=length($1); if (length($2)>b) b=length($2)}
    END {for (i=1;i<=NR;i++) {
           s=l[i]; while (length(s)<a) s=s" "
           u=m[i]; while (length(u)<b) u=u" "
           print s"  "u"  ["t[i]"]"}}'
  exit 0
fi

# Resolve a role spec by exact name: this project's .team/roles/ overrides the shared
# user library. Prints the winning path; exit 3 if neither has it (the lead then invents
# the role and saves it). Pure bash, so it adds nothing to the python3 dependency surface.
if [ "$sub" = role ]; then
  name=${1:?role name}
  case $name in *[!a-z0-9-]*|'') echo "role names are kebab-case: $name" >&2; exit 2 ;; esac
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  lib=${TEAM_ROLES_DIR:-$HOME/.claude/team/roles}
  for f in "$root/.team/roles/$name.md" "$lib/$name.md"; do
    [ -f "$f" ] && { echo "$f"; exit 0; }
  done
  echo "no role '$name' in $root/.team/roles or $lib" >&2; exit 3
fi

# List roles available here: project roles (which override) first, then the shared
# library. Columns: "<name>  project|user  <path>". A missing dir is skipped, not an
# error, so a fresh machine with no library lists this project's roles only.
if [ "$sub" = roles ]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  lib=${TEAM_ROLES_DIR:-$HOME/.claude/team/roles}
  for f in "$root"/.team/roles/*.md "$lib"/*.md; do
    [ -f "$f" ] || continue
    case $f in "$root"/*) s=project ;; *) s=user ;; esac
    printf '%s\t%s\t%s\n' "$(basename "$f" .md)" "$s" "$f"
  done | awk -F'\t' '!seen[$1]++ {printf "%s\t%s\t%s\n",$1,$2,$3}'
  exit 0
fi

# Facts ledger health. Default: classify each fact in .team/facts.md by freshness of its
# SHA-anchored evidence (FRESH = cited file unchanged since the SHA; CHECK = changed or
# unanchorable; GONE = cited file deleted; NOANCHOR = legacy/@nogit line) and flag exact
# duplicate facts (DUP). With --pre-append <file>: scan <file> for secret/PII patterns and
# refuse (exit 2) on a hit, before new facts are written. Pure bash + git, no python3.
if [ "$sub" = facts-lint ]; then
  if [ "${1:-}" = --pre-append ]; then
    f=${2:?file to scan}
    if _secret_lines < "$f"; then
      echo "facts-lint: secret/PII pattern above — refusing to append" >&2; exit 2
    fi
    echo "facts-lint: no secret/PII pattern found in $f"; exit 0
  fi
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  facts="$root/.team/facts.md"
  [ -f "$facts" ] || { echo "no $facts" >&2; exit 3; }
  while IFS= read -r line; do
    case $line in
      '- '*) [ "${line#- \~\~}" = "$line" ] || continue ;;  # skip struck-through facts
      *) continue ;;
    esac
    sha=$(printf '%s\n' "$line" | sed -n 's/.*@\([0-9a-f]\{7,40\}\).*/\1/p')
    # || true: evidence with no file:line makes grep exit 1, which pipefail + set -e
    # would turn into a silent abort of the whole lint.
    file=$(printf '%s\n' "$line" | grep -oE '[A-Za-z0-9_./-]+:[0-9]+' | head -1 | cut -d: -f1 || true)
    if printf '%s\n' "$line" | grep -q '@nogit' || [ -z "$sha" ]; then st=NOANCHOR
    elif [ -z "$file" ]; then st=CHECK
    elif [ ! -e "$root/$file" ] && [ ! -e "$file" ]; then st=GONE
    elif git -C "$root" diff --quiet "$sha" -- "$file" 2>/dev/null; then st=FRESH
    else st=CHECK
    fi
    printf '%s\t%s\n' "$st" "$line"
  done < "$facts"
  # exact-duplicate fact text (the part before " — evidence"); || true so an empty
  # ledger (grep finds no facts, exits 1) doesn't trip set -o pipefail.
  { grep -E '^- ' "$facts" | grep -v '^- ~~' | sed 's/ — evidence:.*//' \
    | sort | uniq -d | while IFS= read -r d; do [ -n "$d" ] && printf 'DUP\t%s\n' "$d"; done; } || true
  exit 0
fi

# Optional Ruflo memory bridge: a semantically searchable index over .team/facts.md and
# role Lessons. facts.md stays the source of truth; every sync brings the index in line with it.
# Without a working ruflo both subcommands say so and exit 0, so /team runs unchanged.
if [ "$sub" = mem-sync ] || [ "$sub" = mem-recall ]; then
  db=${TEAM_MEMORY_DB:-$HOME/.claude/team/memory.db}
  case $db in /*) ;; *) db="$PWD/$db" ;; esac
  _say() { if [ "$sub" = mem-sync ]; then echo "$sub: $*"; else echo "$sub: $*" >&2; fi; }
  command -v ruflo >/dev/null || { _say "ruflo not installed — skipping"; exit 0; }
  mkdir -p "$(dirname "$db")"
  # ruflo drops ruvector.db/.swarm/.claude-flow into its cwd even with --path, so every
  # call runs next to the DB instead of in the user's project.
  _rf() { (cd "$(dirname "$db")" && ruflo memory "$@" --path "$db" 2>/dev/null); }
  # stdout carries banner lines ("[INFO] …", "Transformers.js loaded …") before the JSON:
  # print the first value that parses.
  _json() { python3 -c '
import json, re, sys
t = sys.stdin.read()
for m in re.finditer(r"[\[{]", t):
    try: print(json.dumps(json.JSONDecoder().raw_decode(t[m.start():])[0])); break
    except ValueError: pass'; }
  # Project identity, namespaces and (for sync) the records to store, as TSV:
  #   meta  <project-id>  <facts-ns>  <lessons-ns,...>
  #   <kind> <ns> <key> <tags> <source> <value>      (kind: fact|lesson)
  # The root is the main checkout (git common dir), so a worktree shares its repo's
  # .team/ and id; the id prefers the origin URL, so clones on other machines match too.
  plan=$(TEAM_ROLES_LIB="${TEAM_ROLES_DIR:-$HOME/.claude/team/roles}" python3 - <<'PY'
import hashlib, os, re, subprocess
def git(*a):
    try: return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout.strip()
    except Exception: return ""
h = lambda s, n=12: hashlib.sha1(s.encode()).hexdigest()[:n]
common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
if common:
    root = os.path.dirname(common) if os.path.basename(common) == ".git" else git("rev-parse", "--show-toplevel") or os.getcwd()
else:
    root = os.getcwd()
root = os.path.realpath(root)
url = git("remote", "get-url", "origin") if common else ""
if url:
    pid = url
    scheme = re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", pid)
    pid = pid[scheme.end():] if scheme else pid
    pid = re.sub(r"^[^@/]*@", "", pid)
    if scheme: pid = re.sub(r"^([^/:]+):\d+/", r"\1/", pid)   # drop :port
    else: pid = re.sub(r"^([^/:]+):", r"\1/", pid)               # scp-style host:org/repo
    pid = re.sub(r"\.git$", "", pid.rstrip("/")).rstrip("/").lower()   # forges fold case
else:
    pid = f"{os.path.basename(root)}-{h(root, 8)}"
fns = f"team-facts-{h(pid)}"
dirs = []
for d in (os.path.join(root, ".team", "roles"), os.environ["TEAM_ROLES_LIB"]):
    d = os.path.realpath(os.path.expanduser(d))
    if d not in dirs: dirs.append(d)
lns = {d: f"team-lessons-{h(d)}" for d in dirs}
print("\t".join(["meta", pid, fns, ",".join(lns.values())]))
one = lambda v: v.replace("\t", " ").strip()
facts = os.path.join(root, ".team", "facts.md")
if os.path.isfile(facts):
    for n, line in enumerate(open(facts, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line.startswith("- ") or not line[2:].replace("~~", "").strip(): continue
        st = "stale" if line.startswith("- ~~") else "current"
        text = one(line[2:].replace("~~", ""))
        print("\t".join(["fact", fns, hashlib.sha1(line.replace("~~", "").encode()).hexdigest(),
                         f"status:{st},project:{pid}", f"{facts}:{n}", f"~~{text}~~" if st == "stale" else text]))
for d, ns in lns.items():
    if not os.path.isdir(d): continue
    for f in sorted(os.listdir(d)):
        if not f.endswith(".md"): continue
        role, path, inside = f[:-3], os.path.join(d, f), False
        for n, line in enumerate(open(path, encoding="utf-8"), 1):
            line = line.rstrip("\n")
            if line.startswith("**Lessons:**"):
                inside, line = True, line[len("**Lessons:**"):]
            elif inside and (line.startswith("**") or line.startswith("#")):
                inside = False
            text = re.sub(r"^\s*[-*]\s+", "", line).strip()
            if inside and text:
                print("\t".join(["lesson", ns, hashlib.sha1(f"{role}\t{text}".encode()).hexdigest(),
                                 f"role:{role}", f"{path}:{n}", one(text)]))
PY
)
  IFS=$'\t' read -r _ pid fns lnslist <<<"$(printf '%s\n' "$plan" | head -1)"

  if [ "$sub" = mem-sync ]; then
    recs=$(printf '%s\n' "$plan" | awk -F'\t' '$1!="meta"')
    hits=$(printf '%s\n' "$recs" | cut -f6 | _secret_lines | cut -d: -f1 || true)
    if [ -n "$hits" ]; then
      for n in $hits; do printf '%s\n' "$recs" | sed -n "${n}p" | cut -f5 | sed 's/^/  secret\/PII pattern at /' >&2; done
      echo "mem-sync: secret/PII pattern found — refusing, nothing written" >&2; exit 2
    fi
  fi

  # Installed-but-broken ruflo (e.g. sql.js fallback) reports store success and keeps
  # nothing, so prove a round trip before trusting it.
  # Own namespace per call, hard-purged after (delete is a soft delete that leaves a row):
  # concurrent runs never clobber each other's probe.
  tok="team-probe-$$-$RANDOM$RANDOM"
  _rf store -k probe -n "$tok" "--value=$tok" >/dev/null || true
  got=$(_rf retrieve -k probe -n "$tok" --format json | _json \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("content",""))
except Exception: pass' || true)
  _rf purge -n "$tok" -f >/dev/null || true
  [ "$got" = "$tok" ] || { _say "ruflo memory not persisting — skipping"; exit 0; }

  if [ "$sub" = mem-sync ]; then
    work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
    printf '%s\n' "$recs" > "$work/recs"
    added=0 removed=0
    for ns in $fns ${lnslist//,/ }; do
      _rf list -n "$ns" --limit 1000000 --format json | _json > "$work/have" || true
      # Diff by (key, length): the key fixes the text, and a stale fact is stored as
      # ~~text~~, so the length fixes the status too. With nothing to remove, store only
      # new/changed keys; with something removed, rebuild the namespace, because ruflo's
      # per-key delete is a soft delete that leaves a tombstone row behind.
      NS=$ns python3 - "$work/recs" "$work/have" > "$work/todo" <<'PY' || { echo "mem-sync: could not list $ns — left as is; re-run" >&2; exit 1; }
import json, os, sys
ns = os.environ["NS"]
have = json.load(open(sys.argv[2]))
if not isinstance(have, list): sys.exit(1)
have = {e["key"]: e.get("size") for e in have if e.get("namespace", ns) == ns}
want = {}
for line in open(sys.argv[1], encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    if len(f) == 6 and f[1] == ns: want[f[2]] = f
size = lambda v: len(v.encode("utf-16-le")) // 2   # ruflo reports JS string length
gone = set(have) - set(want)
print(len(gone))
for k, f in want.items():   # leading 1/0: new or changed vs. only re-stored by a rebuild
    changed = have.get(k) != size(f[5])
    if gone or changed: print("\t".join(["1" if changed else "0", *f]))
PY
      n=$(head -1 "$work/todo")
      if [ "$n" -gt 0 ]; then
        _rf purge -n "$ns" -f >/dev/null || { echo "mem-sync: purge of $ns failed — re-run" >&2; exit 1; }
        removed=$((removed+n))
      fi
      while IFS=$'\t' read -r changed kind ns_ key tags _src val; do
        [ -n "$kind" ] || continue
        # --value=… form: a value starting with "-" is otherwise parsed as a flag and dropped.
        out=$(_rf store -k "$key" -n "$ns_" "--value=$val" "--tags=$tags" --provenance agent_output || true)
        case $out in *'[OK]'*) ;; *) echo "mem-sync: store failed for ${_src}" >&2; exit 1 ;; esac
        added=$((added+changed))
      done < <(tail -n +2 "$work/todo")
    done
    nf=$(awk -F'\t' '$1=="fact"' "$work/recs" | wc -l | tr -d ' ')
    nst=$(awk -F'\t' '$1=="fact" && $4 ~ /^status:stale/' "$work/recs" | wc -l | tr -d ' ')
    nl=$(awk -F'\t' '$1=="lesson"' "$work/recs" | wc -l | tr -d ' ')
    echo "mem-sync: $nf facts ($nst stale), $nl lessons -> $db (+$added -$removed)"
    exit 0
  fi

  all= limit=5
  while [ $# -gt 0 ]; do case $1 in
    --all-projects) all=1; shift ;;
    --limit) limit=${2:?--limit N}; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac; done
  case $limit in ''|*[!0-9]*) echo "mem-recall: --limit needs a number" >&2; exit 2 ;; esac
  q=${1:?usage: team.sh mem-recall [--all-projects] [--limit N] "<query>"}
  # One search over every namespace, then scope here: ruflo has no namespace-prefix filter.
  hits=$({ _rf search "--query=$q" --limit 10000 --format json | _json | FNS=$fns ALL=$all LIMIT=$limit python3 -c '
import json, os, sys
try: rs = json.load(sys.stdin).get("results", [])
except Exception: rs = []
def ok(ns):
    return ns == os.environ["FNS"] or ns.startswith("team-lessons-") or (os.environ["ALL"] and ns.startswith("team-facts-"))
rs = sorted((r for r in rs if ok(r.get("namespace", ""))), key=lambda r: -r.get("score", 0))
for r in rs[:int(os.environ["LIMIT"])]:
    print("%s\t%s\t%.3f" % (r["namespace"], r["key"], r.get("score", 0)))'; } || true)
  # search previews are truncated, so fetch each hit for its full text (and project tag).
  while IFS=$'\t' read -r ns key score; do
    [ -n "$ns" ] || continue
    _rf retrieve -k "$key" -n "$ns" --format json | _json | NS=$ns ALL=$all SCORE=$score python3 -c '
import json, os, sys
try: e = json.load(sys.stdin)
except Exception: sys.exit(0)
ns = os.environ["NS"]
kind = "lesson" if ns.startswith("team-lessons-") else "fact"
tag = lambda p: next((t[len(p):] for t in e.get("tags", []) if t.startswith(p)), "?")
if kind == "lesson": kind += ":" + tag("role:")
elif os.environ["ALL"]: kind += ":" + tag("project:")
print("%s\t%s\t%s" % (kind, os.environ["SCORE"], e.get("content", "")))' || true
  done <<<"$hits"
  exit 0
fi

# Deterministic doc-drift guard (the user's rule: deterministic checks belong in a hook,
# not prose). Flags retired drift phrases, confirms every subcommand is documented in the
# header, and confirms every --flag in SKILL.md's argument-hint is explained in HELP.md.
# Exit 1 if anything is off. Edit the owner file (see CLAUDE.md), then re-run.
if [ "$sub" = doccheck ]; then
  here=$(cd "$(dirname "$0")" && pwd); rc=0
  for pat in 'inherit the lead' 'stacked' '3–5'; do
    grep -rnF -- "$pat" "$here/SKILL.md" "$here/HELP.md" "$here/README.md" 2>/dev/null && rc=1
  done
  hdr=$(sed '/^set -euo pipefail/q' "$here/team.sh")
  for s in $subs; do
    printf '%s\n' "$hdr" | grep -qw -- "$s" || { echo "doccheck: subcommand '$s' not documented in the header" >&2; rc=1; }
  done
  for fl in $(sed -n '4p' "$here/SKILL.md" | grep -oE '\-\-[a-z-]+'); do
    grep -qF -- "$fl" "$here/HELP.md" || { echo "doccheck: $fl is in SKILL.md but not HELP.md" >&2; rc=1; }
  done
  [ "$rc" = 0 ] && echo "doccheck: ok"
  exit "$rc"
fi

# Pane <-> tab lifecycle. A teammate's pane is the user's live audit view, so the
# grid should hold only teammates that are actually working. Parking moves the
# teammate's surface into the lead's pane, where it becomes a background tab: the
# claude process is never touched, so it stays alive, stays in ListAgents, and cmux
# can badge the tab if it needs input. `show` moves it back out into its own pane.
if [ "$sub" = park ] || [ "$sub" = show ] || [ "$sub" = list ]; then
  team=${1:?team}; reg="/tmp/team-$team.tabs"
  [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null || {
    echo "park/show/list need the cmux backend (tmux teammates stay in their panes)"; exit 3; }
  [ -f "$reg" ] || { echo "no teammates recorded for $team"; exit 3; }
  # identify still exits 0 for a surface that is gone, returning a null pane_ref,
  # so treat null/missing as "gone" rather than trusting the exit status.
  _pane_of() {  # pane ref holding surface $1, or "gone"
    cmux identify --surface "$1" 2>/dev/null \
      | python3 -c 'import json,sys; c=json.load(sys.stdin).get("caller") or {}; print(c.get("pane_ref") or "gone")' 2>/dev/null \
      || echo gone
  }
  _lead=$(cmux identify 2>/dev/null \
    | python3 -c 'import json,sys; c=json.load(sys.stdin).get("caller") or {}; print(c.get("pane_ref") or "", c.get("surface_ref") or "")' 2>/dev/null || echo "")
  leadpane=${_lead%% *}; leadsurface=${_lead##* }
  # Both park and show end up moving cmux's focus onto the teammate: a surface
  # moved into a pane becomes that pane's front tab even with --focus false, and a
  # freshly split pane takes focus too. Either way the user gets yanked off the
  # lead. Naming the lead's own surface beats focus-pane, which would restore
  # whatever tab that pane last remembered -- possibly another parked teammate.
  _focus_lead() {
    [ -n "$leadsurface" ] || return 0
    cmux move-surface --surface "$leadsurface" --pane "$leadpane" --focus true >/dev/null 2>&1 || true
  }
  [ -n "$leadpane" ] || { echo "could not resolve this session's pane — run park/show from the lead's pane"; exit 3; }

  if [ "$sub" = list ]; then
    while read -r b ref lay name mdl; do
      [ -n "$ref" ] || continue
      if [ "$b" != cmux ]; then echo "${name:-?}  $b $ref  model=${mdl:--}"; continue; fi
      pp=$(_pane_of "$ref")
      case "$pp" in
        gone) st="closed" ;;
        "$leadpane") st="parked (tab, still running)" ;;
        *) st="working ($pp)" ;;
      esac
      echo "${name:-?}  $st  model=${mdl:--}"
    done < "$reg"
    exit 0
  fi

  role=${2:?role}; title="$team-$role"
  ref=$(awk -v t="$title" '$1=="cmux" && $4==t {r=$2} END{print r}' "$reg")
  [ -n "$ref" ] || { echo "no recorded pane for $title (spawned with --tabs, or not spawned)"; exit 3; }

  if [ "$sub" = park ]; then
    [ "$(_pane_of "$ref")" = "$leadpane" ] && { echo "$title already parked"; exit 0; }
    cmux move-surface --surface "$ref" --pane "$leadpane" --focus false >/dev/null
    _focus_lead
    echo "parked $title (now a tab in your pane; session still running)"
  else
    cur=$(_pane_of "$ref")
    [ "$cur" = gone ] && { echo "$title is gone; respawn it"; exit 3; }
    [ "$cur" != "$leadpane" ] && { echo "$title already showing ($cur)"; exit 0; }
    # Extend the teammate region rather than shrinking the lead: hang it off whoever
    # is already working, and only split the lead when no teammate is visible.
    anchor=""
    for r in $(awk '$1=="cmux"{print $2}' "$reg"); do
      pr=$(_pane_of "$r")
      [ "$pr" != "$leadpane" ] && [ "$pr" != gone ] && anchor="$r"
    done
    if [ -n "$anchor" ]; then ph=$(cmux new-split down --surface "$anchor" --focus false | awk '{print $2}')
    else ph=$(cmux new-split right --surface "$CMUX_SURFACE_ID" --focus false | awk '{print $2}'); fi
    cmux move-surface --surface "$ref" --pane "$(_pane_of "$ph")" --focus false >/dev/null
    cmux close-surface --surface "$ph" >/dev/null 2>&1 || true
    _focus_lead
    echo "showing $title"
  fi
  exit 0
fi

backend=auto layout=pane worktree= caveman=1
while :; do case ${1:-} in
  --tmux) backend=tmux; shift ;; --tabs) layout=tab; shift ;; --worktree) worktree=1; shift ;;
  --no-caveman) caveman=; shift ;; *) break ;;
esac; done
spawn_usage="usage: team.sh spawn [--tmux] [--tabs] [--worktree] [--no-caveman] <team> <role> <prompt-file> [model]"
team=${1:?$spawn_usage} role=${2:?$spawn_usage} pfile=${3:?$spawn_usage} model=${4:-}

# A wrong model does not fail the spawn: claude exits 0, the pane opens, and the
# session is dead on arrival -- easy to miss entirely once the teammate is parked
# into a tab. So reject an unknown model here, before any worktree or pane exists.
if [ -n "$model" ]; then
  model_ok=
  case "$model" in opus|sonnet|haiku) model_ok=1 ;; esac
  if [ -z "$model_ok" ] && _team_models | awk -F'\t' -v m="$model" '$2==m{f=1} END{exit !f}'; then model_ok=1; fi
  if [ -z "$model_ok" ]; then
    echo "unknown model: $model" >&2
    echo "available (alias opus|sonnet|haiku also accepted):" >&2
    _team_models | awk -F'\t' '{print "  "$2"  ["$3"]"}' >&2
    exit 3
  fi
else
  echo "warn: no model picked for $team-$role — it inherits the lead's model." >&2
  echo "      Fit one per role instead: team.sh models" >&2
fi
reg="/tmp/team-$team.tabs"

dir=$PWD
if [ -n "$worktree" ]; then
  root=$(git rev-parse --show-toplevel)
  dir="$root/.team/worktrees/$team-$role"
  [ -d "$dir" ] || git -C "$root" worktree add -q -b "team/$team-$role" "$dir" HEAD
  echo "worktree $dir (branch team/$team-$role)"
  # A worktree is its own git top-level, so it never inherits the repo's workspace
  # trust and `claude` would raise the trust prompt in every pane. Pre-accept this
  # one path. Best-effort: a failure here only means the prompt comes back.
  TEAM_TRUST_DIR="$dir" python3 - <<'PY' || echo "warn: could not pre-trust $dir; expect a trust prompt" >&2
import json, os, sys
p = os.path.expanduser("~/.claude.json")
d = os.path.abspath(os.environ["TEAM_TRUST_DIR"])
with open(p, encoding="utf-8") as f:
    cfg = json.load(f)
projects = cfg.setdefault("projects", {})
if projects.setdefault(d, {}).get("hasTrustDialogAccepted") is True:
    sys.exit(0)
projects[d]["hasTrustDialogAccepted"] = True
tmp = f"{p}.team-{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(json.dumps(cfg, indent=2, ensure_ascii=False))
os.replace(tmp, p)
PY
fi
title="$team-$role"
cavefile="$HOME/.agents/skills/caveman/SKILL.md"
rulesfile="$(cd "$(dirname "$0")" && pwd)/teammate-rules.md"
# claude keeps only the LAST --append-system-prompt-file, so these are concatenated
# rather than passed as two flags: the always-on teammate rules (parallelise with
# subagents, verify what they return) plus the caveman style unless --no-caveman.
sysprompt="/tmp/team-$team-$role.sysprompt.md"
: > "$sysprompt"
if [ -f "$rulesfile" ]; then cat "$rulesfile" >> "$sysprompt"; fi
if [ -n "$caveman" ] && [ -f "$cavefile" ]; then printf '\n\n' >> "$sysprompt"; cat "$cavefile" >> "$sysprompt"; fi
cmd="cd $(printf %q "$dir") && CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 claude -n $(printf %q "$title") --permission-mode $(printf %q "${TEAM_PERMISSION_MODE:-auto}")"
if [ -s "$sysprompt" ]; then cmd+=" --append-system-prompt-file $(printf %q "$sysprompt")"; fi
[ -n "$model" ] && cmd+=" --model $(printf %q "$model")"
cmd+=" \"\$(cat $(printf %q "$pfile"))\""

if [ "$backend" = auto ] && [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null; then
  if [ "$layout" = pane ]; then
    # Two-column grid in the region right of the lead: #1 opens it, #2 sits beside
    # #1, and every later teammate splits down from the one two slots back. A 1-wide
    # stack gave each teammate 1/N of the screen height, which got unreadable fast.
    n=$(awk '$3=="pane"{c++} END{print c+0}' "$reg" 2>/dev/null || echo 0)
    if [ "$n" -eq 0 ]; then
      out=$(cmux new-split right --surface "$CMUX_SURFACE_ID" --command "$cmd" --focus false)
    elif [ "$n" -eq 1 ]; then
      out=$(cmux new-split right --surface "$(awk '$3=="pane"{print $2; exit}' "$reg")" --command "$cmd" --focus false)
    else
      out=$(cmux new-split down --surface "$(awk '$3=="pane"{print $2}' "$reg" | sed -n "$((n-1))p")" --command "$cmd" --focus false)
    fi
  else
    out=$(cmux new-surface --type terminal --workspace "$CMUX_WORKSPACE_ID" --command "$cmd" --focus false)
  fi
  ref=$(awk '{print $2}' <<<"$out")   # "OK surface:N ..."
  cmux rename-tab --surface "$ref" "$title" >/dev/null
  echo "cmux $ref $layout $title ${model:--}" >> "$reg"
  echo "cmux $layout $ref ($team-$role) in current workspace"
elif [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  id=$(tmux split-window -t "$TMUX_PANE" -d -P -F '#{pane_id}' "$cmd")
  tmux select-pane -t "$id" -T "$title"; tmux set -w -t "$id" pane-border-status top
  tmux select-layout -t "$TMUX_PANE" tiled >/dev/null
  echo "tmux $id pane $title ${model:--}" >> "$reg"
  echo "tmux pane $id ($team-$role) in current window"
else
  s="team-$team"
  if tmux has-session -t "=$s" 2>/dev/null; then
    id=$(tmux split-window -t "=$s" -d -P -F '#{pane_id}' "$cmd")
  else
    id=$(tmux new-session -d -s "$s" -x 240 -y 60 -P -F '#{pane_id}' "$cmd")
  fi
  tmux select-pane -t "$id" -T "$title"; tmux set -w -t "$id" pane-border-status top
  tmux select-layout -t "=$s" tiled >/dev/null
  echo "tmux $id pane $title ${model:--}" >> "$reg"
  echo "tmux pane $id ($team-$role) in session $s — attach: tmux attach -t $s"
fi
