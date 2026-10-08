#!/usr/bin/env bash
# Run each teammate as an interactive `claude` session in its own tab/pane.
#   team.sh spawn [--tmux] [--tabs] [--worktree] [--replace] [--no-caveman] <team> <role> <prompt-file> [model]
#   team.sh close <team>  -> force-closes every recorded pane/tab (incl. the monitor); exit 1 (rows kept for a retry) if one could not be closed
#   team.sh init <team>   -> creates .team/ (idempotent) + a run dir; prints the run dir path
#   team.sh gate-init     -> sets up the no-mistakes gate for this repo (needs an "origin" remote)
#   team.sh clean <team>  -> removes the team's worktrees that have no uncommitted changes (branches kept)
#   team.sh park <team> <role>  -> fold an idle teammate's pane into a tab (keeps it running)
#   team.sh show <team> <role>  -> bring a parked teammate back into its own pane
#   team.sh list <team>         -> each teammate: working / parked / closed; MODEL_GONE when its model left the picker
#   team.sh models              -> models available here, best tier first
#   team.sh pick-model <tier>   -> newest claude-* model id for opus|sonnet|haiku; exit 1 = fell back a tier
#                                  (warning on stderr), 2 = bad tier, 3 = nothing matches
#   team.sh role <name>         -> print a role spec path (project override, then shared library); exit 2 bad name, 3 if none
#   team.sh roles               -> list roles available here: "<name>  project|user  <path>  <status>", status one of
#                                  in-sync|local-ahead|global-ahead|diverged|diverged (no base)|project-only|library-only
#   team.sh role-pull <name> [--force]     -> copy the shared library role into .team/roles/ (records .team/roles/.base/);
#                                             fast-forwards when the local copy is unchanged since .base/.
#                                             exit 0 ok/no-op, 2 bad name/option, 3 not in library, 5 conflict (needs --force)
#   team.sh role-promote <name> [--force]  -> copy a project role into the shared library, secret/PII scan first;
#                                             library ahead always refuses (run role-pull).
#                                             exit 0 ok/no-op, 2 bad name/option or PII hit, 3 not in project, 5 conflict (needs --force)
#   team.sh status [--watch] <team>        -> one row per teammate: ROLE | MILESTONE | STEP | LAST_ACTIVITY | FLAGS;
#                                             --watch refreshes every 30s (Ctrl-C stops). exit 3 no registry
#   team.sh monitor <team>                 -> open one small auto-refreshing status pane (layout dash, title
#                                             <team>-monitor; not a teammate, not in the cap; `close` closes it).
#                                             exit 1 already running
#   (role, roles, role-pull, role-promote live in lib/roles.sh; status, monitor in lib/status.sh)
#   team.sh facts-lint [--pre-append <file>]  -> freshness of .team/facts.md facts (FRESH/CHECK/GONE/NOANCHOR + DUP); --pre-append scans <file> for secrets
#   team.sh doccheck            -> doc drift guard: retired phrases, subcommands documented, SKILL flags present in HELP
#   team.sh --help              -> prints this header. Any other unknown subcommand exits 2 (it never falls through to spawn).
# Exit codes: 0 ok; 1 fallback/warning; 2 refused (usage, bad input, secret/PII hit);
# 3 not found (role, model, registry, python3, backend); 4 team cap reached or spawn lock busy;
# 5 role-promote/role-pull direction refused.
# .team/ always means the MAIN checkout's .team/, also when run from inside a linked worktree.
# Needs python3 (models, pick-model, spawn, park/show/list); those subcommands exit 3 without it.
# TEAM_MODELS_FILE: read the model picker from this JSON file instead of managed-settings/settings.json.
# --worktree: the teammate works in its own git worktree .team/worktrees/<team>-<role>
# on branch team/<team>-<role> (created from HEAD, or reused if it survived a `clean`), like a
# separate person. Needs at least one commit. Each new worktree is pre-accepted in ~/.claude.json
# so the workspace-trust prompt does not appear in every pane (a worktree is its own git
# top-level, so it cannot inherit it).
# spawn checks before opening anything: the prompt file is readable (made absolute), the role is
# kebab-case (no leading, trailing or double hyphen) and not the reserved name `monitor`, and the model is listed. Under a lock it then
# drops registry rows whose pane is gone, refuses a live teammate with the same title unless
# --replace (which closes the old one first), and refuses a 9th teammate (exit 4). The monitor
# pane (layout dash) does not count toward the 8.
# Every pane/tab is titled <team>-<role> (Claude's own terminal-title updates are disabled so it sticks).
# Every teammate gets teammate-rules.md appended to its system prompt (parallelise with
# subagents, verify what they return), plus the caveman output style unless --no-caveman.
# Every teammate runs with CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4, and with
# CLAUDE_CODE_SUBAGENT_MODEL=<newest sonnet> when `pick-model sonnet` finds one exactly (omitted on fallback).
# Backend: a cmux tab in the lead's workspace when running inside cmux, else a tmux pane
# (splits the lead's window inside tmux, otherwise a detached session "team-<team>").
# cmux default: split the lead's tab — teammates fill a two-column grid to the right of the lead.
# --tabs (cmux): one tab per teammate instead. --tmux forces tmux.
# Permission mode: a haiku-tier model (by resolved tier, so any id that behaves as haiku) always
# gets --permission-mode dontAsk plus a per-teammate allowlist: Read/Glob/Grep, SendMessage,
# read-only git (status/log/diff/show/ls-files/rev-parse/blame), ls/wc, `team.sh facts-lint`, and Edit on exactly its
# <run>/reports/<role>.md, <run>/tasks.md and <run>/status/<role>.txt (<run> = parent of the
# prompt file's prompts/ dir, which a haiku-tier prompt must live in). Haiku tier is refused with
# --worktree. Every other tier uses TEAM_PERMISSION_MODE (default auto); it never applies to haiku tier.
# Spawned tabs/panes are recorded in /tmp/team-<team>.tabs, one row each:
# "<backend> <ref> <layout:pane|tab|dash> <title> <model|-> <subagent-model|-> <run-dir|->".
set -euo pipefail
# Dispatch: anything not listed is refused here, because an unknown word would
# otherwise fall through to the spawn path below and open a real pane.
subs="init gate-init clean close models pick-model role roles role-pull role-promote status monitor facts-lint doccheck park show list spawn"
here=$(cd "$(dirname "$0")" && pwd)
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
# Secret/PII pattern (grep -Ei). facts-lint --pre-append refuses on a hit, scanning
# through _secret_lines (stdin -> "n:line" per hit).
# Git remotes (git@host:org/repo, ssh://git@host/...) are not emails: _secret_lines turns
# the "git@" user into "git " first, so every other address still hits, whatever follows it.
secret='(dapi|dose)[0-9a-f]{32}|gh[pousr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{22,}|sk-(ant|proj|svcacct)-[0-9A-Za-z_-]{16,}|sk-[0-9A-Za-z]{16}|AKIA[0-9A-Z]{16}|(xox[abposr]|xapp)-[0-9A-Za-z-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[0-9A-Za-z_-]{8,}\.eyJ[0-9A-Za-z_-]{8,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
_secret_lines() { sed -E 's/(^|[^A-Za-z0-9._%+-])git@/\1git /g' | grep -nEi -- "$secret"; }

# --- Helpers. lib/*.sh may call these; keep their names and output stable. ---
# The main checkout's root, also from inside a linked worktree or a submodule (the first
# porcelain row is always the main worktree). Outside git, `git` fails, pipefail makes the
# pipeline fail, and it falls back to $PWD.
_root() { git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' || pwd; }
_roles_lib() { echo "${TEAM_ROLES_DIR:-$HOME/.claude/team/roles}"; }
_reg() { echo "/tmp/team-$1.tabs"; }
_need_py() {
  command -v python3 >/dev/null 2>&1 && return 0
  echo "team.sh: python3 is required for '$sub' but was not found on PATH" >&2; exit 3
}

# Models available here. The option list is org-managed (managed-settings.json) and
# changes without notice, so it is read at run time instead of hardcoded. Emits
# "<label>TAB<id>TAB<tier>", best tier first. `behavesAs` is the capability tier a
# model is gated at, which is what decides whether it fits a role.
_team_models() {
  _need_py
  python3 - <<'PY'
import json, os, re
options = None
paths = ([os.environ["TEAM_MODELS_FILE"]] if os.environ.get("TEAM_MODELS_FILE") else
         ["/Library/Application Support/ClaudeCode/managed-settings.json",
          os.path.expanduser("~/.claude/settings.json")])
for path in paths:
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

# Newest claude-* model of a tier (user decision: version beats the org's list order;
# equal versions keep list order). Non-claude models that behave as a tier (GLM, Kimi) are
# only ever used by explicit id. An empty tier falls back down (opus -> sonnet -> haiku):
# warning on stderr, return 1. Return 2 = bad tier, 3 = nothing at or below the tier.
_pick_model() {
  case ${1:-} in opus|sonnet|haiku) ;; *) echo "pick-model: tier must be opus|sonnet|haiku" >&2; return 2 ;; esac
  local rows; rows=$(_team_models) || return 3
  printf '%s\n' "$rows" | python3 -c '
import re, sys
want = sys.argv[1]; chain = ["opus", "sonnet", "haiku"]
rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.count("\t") == 2]
def key(mid):
    base = re.sub(r"\[.*?\]", "", mid).rsplit(".", 1)[-1]
    return tuple(int(x) for x in re.findall(r"\d+", base))
for t in chain[chain.index(want):]:
    mids = [m for _, m, tier in rows if tier == t and ("claude-" in m or m == t)]
    if mids:
        best = max(mids, key=key)
        if t != want:
            print(f"warn: no {want}-tier claude model; falling back to {t} ({best})", file=sys.stderr)
            print(best); sys.exit(1)
        print(best); sys.exit(0)
print(f"pick-model: no claude model at or below tier {want}", file=sys.stderr); sys.exit(3)
' "$1"
}

# Tier of a model id or alias (opus|sonnet|haiku), or nothing when it is not listed.
_model_tier() {
  case ${1:-} in opus|sonnet|haiku) echo "$1"; return 0 ;; ''|-) return 0 ;; esac
  _team_models | awk -F'\t' -v m="$1" '$2==m{print $3; exit}'
}
# 0 when a recorded model id is no longer offered here, so the pane's next call will fail.
_model_gone() {
  case ${1:-} in ''|-|opus|sonnet|haiku) return 1 ;; esac
  ! _team_models | awk -F'\t' -v m="$1" '$2==m{f=1} END{exit !f}'
}

# cmux pane ref holding surface $1, or "gone". identify still exits 0 for a surface that is
# gone, returning a null pane_ref, so treat null/missing as "gone" rather than trusting the exit status.
_pane_of() {
  cmux identify --surface "$1" 2>/dev/null \
    | python3 -c 'import json,sys; c=json.load(sys.stdin).get("caller") or {}; print(c.get("pane_ref") or "gone")' 2>/dev/null \
    || echo gone
}
# "<pane_ref> <surface_ref>" of the calling session (the lead), or empty.
_lead_pane() {
  cmux identify 2>/dev/null \
    | python3 -c 'import json,sys; c=json.load(sys.stdin).get("caller") or {}; print(c.get("pane_ref") or "", c.get("surface_ref") or "")' 2>/dev/null || true
}
# 0 if the recorded pane/surface still exists. Only a definite "gone" answer counts as dead:
# a missing tool, an unreachable cmux, or unparseable output keeps the row (never prune blind).
_alive() {
  local out
  case $1 in
    cmux)
      command -v cmux >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 0
      out=$(cmux identify --surface "$2" 2>&1) || { case $out in *not_found*) return 1 ;; esac; return 0; }
      printf '%s' "$out" | python3 -c '
import json, sys
try: c = json.load(sys.stdin).get("caller")
except Exception: sys.exit(0)
sys.exit(1 if isinstance(c, dict) and not c.get("pane_ref") else 0)' ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || return 0
      out=$(tmux display-message -p -t "$2" '#{pane_id}' 2>&1) && return 0
      case $out in *"can't find"*|*"error connecting"*|*"no server"*) return 1 ;; esac
      return 0 ;;
    *) return 0 ;;
  esac
}
# Drop registry rows whose pane is gone, so a reused slug or a dead teammate never holds a
# cap slot, anchors the grid, or blocks a respawn with the same name.
_reg_prune() {
  [ -f "$1" ] || return 0
  local keep="" row b r
  while IFS= read -r row; do
    read -r b r _ <<<"$row" || true
    [ -n "${r:-}" ] || continue
    if _alive "$b" "$r"; then keep+="$row"$'\n'; fi
  done < "$1"
  printf '%s' "$keep" > "$1.tmp" && mv "$1.tmp" "$1"
}
# Registry lock: anything that reads-then-appends the registry holds it. mkdir is atomic; a
# lock whose holder pid is dead is broken, a live one is waited on for up to 30s, then exit 4.
# Released on exit via an EXIT trap, which replaces any earlier EXIT trap: call once per process.
_lock() {
  local lock="$1.lock" i holder
  for i in $(seq 1 300); do
    if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; trap 'rm -rf "'"$lock"'"' EXIT; return 0; fi
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
    sleep 0.1
  done
  echo "registry lock busy: $lock (another spawn/monitor is running; remove it if not)" >&2; exit 4
}
# Distinct titles of teammate rows (layout pane|tab; the dash monitor is not a teammate).
_mates() { [ -f "$1" ] || return 0; awk '$3=="pane" || $3=="tab" {print $4}' "$1" | sort -u; }

# Libraries: functions only (sub_<name> per subcommand), sourced after the helpers they use,
# so a missing lib only disables its own subcommands.
for _lib in "$here/lib/roles.sh" "$here/lib/status.sh"; do
  # shellcheck source=/dev/null
  if [ -f "$_lib" ]; then . "$_lib"; fi
done
case $sub in
  role|roles|role-pull|role-promote|status|monitor)
    fn="sub_${sub//-/_}"
    declare -F "$fn" >/dev/null || {
      case $sub in status|monitor) l=status ;; *) l=roles ;; esac
      echo "team.sh: '$sub' needs $here/lib/$l.sh, which is missing" >&2; exit 3; }
    "$fn" "$@"; exit $? ;;
esac

if [ "$sub" = init ]; then
  team=${1:?team}
  root=$(_root)
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
    gi="$root/.gitignore"
    for p in .team/ CLAUDE.local.md; do
      git -C "$root" check-ignore -q "$p" 2>/dev/null && continue
      # A last line with no newline would merge with ours ("node_modules.team/").
      if [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ]; then echo >> "$gi"; fi
      echo "$p" >> "$gi"
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
  root=$(_root)
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

if [ "$sub" = models ]; then
  _need_py
  _team_models | awk -F'\t' '
    {l[NR]=$1; m[NR]=$2; t[NR]=$3
     if (length($1)>a) a=length($1); if (length($2)>b) b=length($2)}
    END {for (i=1;i<=NR;i++) {
           s=l[i]; while (length(s)<a) s=s" "
           u=m[i]; while (length(u)<b) u=u" "
           print s"  "u"  ["t[i]"]"}}'
  exit 0
fi

if [ "$sub" = pick-model ]; then
  _need_py
  _pick_model "${1:-}"; exit $?
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
  root=$(_root)
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

# Deterministic doc-drift guard (the user's rule: deterministic checks belong in a hook,
# not prose). Flags retired drift phrases, confirms every subcommand is documented in the
# header, and confirms every --flag in SKILL.md's argument-hint is explained in HELP.md.
# Exit 1 if anything is off. Edit the owner file (see CLAUDE.md), then re-run.
if [ "$sub" = doccheck ]; then
  rc=0
  for pat in 'inherit the lead' 'stacked' '3–5' '2–5' 'as much as possible'; do
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
  team=${1:?team}; reg=$(_reg "$team")
  _need_py
  [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null || {
    echo "park/show/list need the cmux backend (tmux teammates stay in their panes)"; exit 3; }
  [ -f "$reg" ] || { echo "no teammates recorded for $team"; exit 3; }
  _lead=$(_lead_pane)
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
    # Teammates only (layout pane|tab): the dash monitor is not a teammate. MODEL_GONE: the
    # teammate's or its subagents' model left the picker, so its next call fails; respawn it.
    while read -r b ref lay name mdl smdl _; do
      [ -n "${ref:-}" ] || continue
      case ${lay:-} in pane|tab) ;; *) continue ;; esac
      gone=""
      if _model_gone "${mdl:-}" || _model_gone "${smdl:-}"; then gone="  MODEL_GONE"; fi
      if [ "$b" != cmux ]; then echo "${name:-?}  $b $ref  model=${mdl:--}$gone"; continue; fi
      pp=$(_pane_of "$ref")
      case "$pp" in
        gone) st="closed" ;;
        "$leadpane") st="parked (tab, still running)" ;;
        *) st="working ($pp)" ;;
      esac
      echo "${name:-?}  $st  model=${mdl:--}$gone"
    done < "$reg"
    exit 0
  fi

  role=${2:?role}; title="$team-$role"
  ref=$(awk -v t="$title" '$1=="cmux" && ($3=="pane" || $3=="tab") && $4==t {r=$2} END{print r}' "$reg")
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
    for r in $(awk '$1=="cmux" && ($3=="pane" || $3=="tab") {print $2}' "$reg"); do
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

backend=auto layout=pane worktree= caveman=1 replace=
while :; do case ${1:-} in
  --tmux) backend=tmux; shift ;; --tabs) layout=tab; shift ;; --worktree) worktree=1; shift ;;
  --replace) replace=1; shift ;; --no-caveman) caveman=; shift ;; *) break ;;
esac; done
spawn_usage="usage: team.sh spawn [--tmux] [--tabs] [--worktree] [--replace] [--no-caveman] <team> <role> <prompt-file> [model]"
team=${1:?$spawn_usage} role=${2:?$spawn_usage} pfile=${3:?$spawn_usage} model=${4:-}
[ $# -le 4 ] || { echo "$spawn_usage (flags go before <team>; got extra: ${*:5})" >&2; exit 2; }

# Everything below up to the lock is a check: nothing is created and no pane opens until
# all of them pass. `monitor` is reserved for the status pane (title <team>-monitor), and a
# leading/trailing hyphen would make a title that collides with another team's.
case $role in
  ''|-*|*-|*--*|*[!a-z0-9-]*) echo "role names are kebab-case: '$role'" >&2; exit 2 ;;
  monitor) echo "role name 'monitor' is reserved for the status pane (team.sh monitor)" >&2; exit 2 ;;
esac
# The prompt is read with `cat` inside the pane, after `cd` into the teammate's dir, so a
# missing file or a relative path would start the teammate with an empty prompt.
[ -f "$pfile" ] && [ -r "$pfile" ] || { echo "prompt file not readable: $pfile" >&2; exit 2; }
pfile="$(cd "$(dirname "$pfile")" && pwd)/$(basename "$pfile")"
_need_py

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
  echo "      Fit one per role instead: team.sh pick-model <tier>. If the lead runs a haiku-tier" >&2
  echo "      model, this teammate gets no dontAsk allowlist and will stall on permission prompts." >&2
fi
tier=$(_model_tier "$model")
title="$team-$role"
reg=$(_reg "$team")

# The run dir is the parent of the prompt's prompts/ dir; status and the haiku allowlist use it.
rundir=-
pdir=$(dirname "$pfile")
[ "$(basename "$pdir")" = prompts ] && rundir=$(dirname "$pdir")

# Haiku tier (by tier, not name: GLM/Kimi behave as haiku) falls back to prompting under
# `auto` and stalls unattended, so it always runs dontAsk with an explicit allowlist, whatever
# TEAM_PERMISSION_MODE says. The allowlist is read-only except Edit on this teammate's own
# report, tasks.md and status file: `Write(//abs)` is denied under dontAsk, `Edit(//abs)` is
# not. `//` + abs path, unresolved, because the rule matches the path as the teammate writes it.
# No Bash(git:*) (commit/push) or python3. Haiku tier cannot commit, so no build runs.
allow=
if [ "$tier" = haiku ]; then
  [ -z "$worktree" ] || { echo "haiku-tier model ($model) cannot run with --worktree: its allowlist cannot commit; use a sonnet-tier model" >&2; exit 2; }
  [ "$rundir" != - ] || { echo "haiku-tier teammate needs its prompt in <run>/prompts/ so its report path is known: $pfile" >&2; exit 2; }
  allow="Read,Glob,Grep,SendMessage,ListAgents"
  allow+=",Edit(/$rundir/reports/$role.md),Edit(/$rundir/tasks.md),Edit(/$rundir/status/$role.txt)"
  allow+=",Bash(ls:*),Bash(wc:*)"
  # Every spawn prompt asks for facts-lint; a rule matches the command text as typed, so both forms.
  allow+=",Bash(bash ~/.claude/skills/team/team.sh facts-lint:*),Bash(bash $here/team.sh facts-lint:*)"
  for g in status log diff show ls-files rev-parse blame; do allow+=",Bash(git $g:*)"; done
  pmode=dontAsk
  echo "note: $title is haiku-tier ($model): --permission-mode dontAsk + read-only allowlist" >&2
else
  pmode=${TEAM_PERMISSION_MODE:-auto}
fi

# Subagents launched without a model default to haiku and can overflow its context, so
# point them at the newest sonnet -- resolved here, in-process, and only on an exact match:
# after a fallback the "sonnet" would be a haiku id, the very thing this guards against.
if submodel=$(_pick_model sonnet 2>/dev/null) && [ -n "$submodel" ]; then :; else
  submodel=-
  echo "warn: no sonnet-tier model; CLAUDE_CODE_SUBAGENT_MODEL not set for $title" >&2
fi

if [ -n "$worktree" ]; then
  root=$(_root)
  git -C "$root" rev-parse -q --verify HEAD >/dev/null 2>&1 || {
    echo "--worktree needs a git repo with at least one commit (none at $root)" >&2; exit 2; }
fi

# Prune + duplicate check + cap + register must not interleave with a parallel spawn of the
# same team, or two spawns both see 7 teammates.
_lock "$reg"

_reg_prune "$reg"
# A live teammate with this title would be a second session SendMessage cannot tell apart.
live=$(awk -v t="$title" '$4==t {print $1" "$2}' "$reg" 2>/dev/null || true)
if [ -n "$live" ]; then
  [ -n "$replace" ] || { echo "$title is already live ($(echo $live)); pass --replace to close it and respawn" >&2; exit 2; }
  while read -r b r; do
    case $b in
      cmux) cmux close-surface --surface "$r" --force >/dev/null 2>&1 || true ;;
      tmux) tmux kill-pane -t "$r" 2>/dev/null || true ;;
    esac
    echo "replaced: closed $b $r ($title)"
  done <<<"$live"
  awk -v t="$title" '$4!=t' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
fi
n_mates=$(_mates "$reg" | grep -c . || true)
[ "$n_mates" -lt 8 ] || { echo "team $team already has $n_mates live teammates (cap 8); close or replace one first" >&2; exit 4; }

dir=$PWD
if [ -n "$worktree" ]; then
  dir="$root/.team/worktrees/$team-$role"
  if [ ! -d "$dir" ]; then
    # `clean` keeps the branch, so a respawn reuses it instead of failing on `-b`.
    if git -C "$root" show-ref -q --verify "refs/heads/team/$team-$role"; then
      git -C "$root" worktree add -q "$dir" "team/$team-$role"
    else
      git -C "$root" worktree add -q -b "team/$team-$role" "$dir" HEAD
    fi
  fi
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
cavefile="$HOME/.agents/skills/caveman/SKILL.md"
rulesfile="$here/teammate-rules.md"
# claude keeps only the LAST --append-system-prompt-file, so these are concatenated
# rather than passed as two flags: the always-on teammate rules (parallelise with
# subagents, verify what they return) plus the caveman style unless --no-caveman.
sysprompt="/tmp/team-$team-$role.sysprompt.md"
: > "$sysprompt"
if [ -f "$rulesfile" ]; then cat "$rulesfile" >> "$sysprompt"; fi
if [ -n "$caveman" ] && [ -f "$cavefile" ]; then printf '\n\n' >> "$sysprompt"; cat "$cavefile" >> "$sysprompt"; fi
envs="CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4"
[ "$submodel" != - ] && envs+=" CLAUDE_CODE_SUBAGENT_MODEL=$(printf %q "$submodel")"
cmd="cd $(printf %q "$dir") && $envs claude -n $(printf %q "$title") --permission-mode $(printf %q "$pmode")"
# One comma-joined value: the flag is variadic and would otherwise swallow the prompt.
[ -n "$allow" ] && cmd+=" --allowedTools $(printf %q "$allow")"
if [ -s "$sysprompt" ]; then cmd+=" --append-system-prompt-file $(printf %q "$sysprompt")"; fi
[ -n "$model" ] && cmd+=" --model $(printf %q "$model")"
cmd+=" \"\$(cat $(printf %q "$pfile"))\""
row_tail="$title ${model:--} $submodel $rundir"

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
  echo "cmux $ref $layout $row_tail" >> "$reg"
  echo "cmux $layout $ref ($team-$role) in current workspace"
elif [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  id=$(tmux split-window -t "$TMUX_PANE" -d -P -F '#{pane_id}' "$cmd")
  tmux select-pane -t "$id" -T "$title"; tmux set -w -t "$id" pane-border-status top
  tmux select-layout -t "$TMUX_PANE" tiled >/dev/null
  echo "tmux $id pane $row_tail" >> "$reg"
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
  echo "tmux $id pane $row_tail" >> "$reg"
  echo "tmux pane $id ($team-$role) in session $s — attach: tmux attach -t $s"
fi
