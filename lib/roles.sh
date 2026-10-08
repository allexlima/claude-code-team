#!/usr/bin/env bash
# lib/roles.sh — role resolution, listing, pull, and promote subcommands.
# Sourced by team.sh AFTER its helpers; defines functions only, no side effects.
# Requires from team.sh: _root, _roles_lib, _secret_lines, $secret.
#
# sub_role <name>
#   Print path of the role spec (project copy first, shared library fallback).
#   Prints a note to stderr when resolving from the shared library.
#   Exit 0: found. Exit 2: invalid name. Exit 3: not found.
#
# sub_roles
#   List all available roles: <name>  <source>  <path>  <status>
#   Source: project | user.  Status: in-sync | local-ahead | global-ahead |
#   diverged | diverged (no base) | project-only | library-only.
#
# sub_role_pull <name> [--force]
#   Copy role from shared library into .team/roles/ and record a .base/ snapshot.
#   Fast-forwards when local is unchanged since base (base == local).
#   Diverged (both changed): shows diffs, refuses unless --force.
#   Exit 0: pulled / fast-forwarded. Exit 1: already up-to-date.
#   Exit 2: invalid name or bad option. Exit 3: not in shared library.
#   Exit 5: conflict (pass --force to overwrite).
#
# sub_role_promote <name> [--force]
#   Copy project role into shared library after a secret/PII scan.
#   Fast-forwards when library is unchanged since base (base == lib) or when the
#   library copy does not yet exist.
#   global-ahead (lib changed, local unchanged): refuses with exit 5 always —
#   run role-pull first; --force does NOT override this case.
#   Diverged (both changed): shows diffs, refuses unless --force.
#   Exit 0: promoted. Exit 1: already up-to-date. Exit 2: invalid name, bad
#   option, or secret/PII hit. Exit 3: not in project. Exit 5: conflict.

sub_role() {
  local name=${1:?role name}
  case $name in *[!a-z0-9-]*|'') echo "role names are kebab-case: $name" >&2; return 2 ;; esac
  local root; root=$(_root)
  local lib; lib=$(_roles_lib)
  if [ -f "$root/.team/roles/$name.md" ]; then
    echo "$root/.team/roles/$name.md"
    return 0
  fi
  if [ -f "$lib/$name.md" ]; then
    echo "note: '$name' resolved from shared library ($lib/$name.md)" >&2
    echo "$lib/$name.md"
    return 0
  fi
  echo "no role '$name' in $root/.team/roles or $lib" >&2
  return 3
}

sub_roles() {
  local root; root=$(_root)
  local lib; lib=$(_roles_lib)
  local base_dir="$root/.team/roles/.base"

  # Collect deduplicated role names: project first (project overrides library).
  local names
  names=$(
    for f in "$root"/.team/roles/*.md "$lib"/*.md; do
      [ -f "$f" ] || continue
      basename "$f" .md
    done | awk '!seen[$1]++'
  )
  [ -n "$names" ] || return 0

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local proj_f="$root/.team/roles/$name.md"
    local lib_f="$lib/$name.md"
    local base_f="$base_dir/$name.md"
    local src status path

    if [ -f "$proj_f" ] && [ -f "$lib_f" ]; then
      src=project; path="$proj_f"
      if cmp -s "$proj_f" "$lib_f"; then
        status="in-sync"
      elif [ -f "$base_f" ]; then
        local beql beqs
        if cmp -s "$base_f" "$lib_f"; then beql=1; else beql=0; fi
        if cmp -s "$base_f" "$proj_f"; then beqs=1; else beqs=0; fi
        if   [ "$beql" = 1 ] && [ "$beqs" = 0 ]; then status="local-ahead"
        elif [ "$beql" = 0 ] && [ "$beqs" = 1 ]; then status="global-ahead"
        else status="diverged"
        fi
      else
        status="diverged (no base)"
      fi
    elif [ -f "$proj_f" ]; then
      src=project; path="$proj_f"; status="project-only"
    else
      src=user; path="$lib_f"; status="library-only"
    fi

    printf '%s\t%s\t%s\t%s\n' "$name" "$src" "$path" "$status"
  done <<< "$names"
}

sub_role_pull() {
  local name=${1:?role name} force=
  shift
  while [ $# -gt 0 ]; do
    case $1 in --force) force=1; shift ;; *) echo "role-pull: unknown option: $1" >&2; return 2 ;; esac
  done
  case $name in *[!a-z0-9-]*|'') echo "role names are kebab-case: $name" >&2; return 2 ;; esac

  local root; root=$(_root)
  local lib; lib=$(_roles_lib)
  local src="$lib/$name.md"
  local dst="$root/.team/roles/$name.md"
  local base="$root/.team/roles/.base/$name.md"

  [ -f "$src" ] || { echo "role '$name' not found in shared library ($lib)" >&2; return 3; }

  if [ ! -f "$dst" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    mkdir -p "$(dirname "$base")"; cp "$src" "$base"
    echo "pulled: $dst"
    return 0
  fi

  if cmp -s "$src" "$dst"; then
    if [ ! -f "$base" ]; then
      mkdir -p "$(dirname "$base")"; cp "$src" "$base"
    fi
    echo "already up-to-date: $dst"
    return 1
  fi

  if [ -f "$base" ]; then
    if cmp -s "$base" "$dst"; then
      # Local unchanged since base — fast-forward safe
      diff "$dst" "$src" || true
      cp "$src" "$dst"; cp "$src" "$base"
      echo "pulled (fast-forward): $dst"
      return 0
    else
      # Both changed since base — diverged
      echo "=== global changed since base ===" >&2
      diff "$base" "$src" >&2 || true
      echo "=== local changed since base ===" >&2
      diff "$base" "$dst" >&2 || true
      if [ -n "$force" ]; then
        cp "$src" "$dst"; cp "$src" "$base"
        echo "pulled (forced): $dst"
        return 0
      fi
      echo "diverged — review above, pass --force to overwrite" >&2
      return 5
    fi
  else
    # No base — 2-way fallback
    diff "$dst" "$src" >&2 || true
    if [ -n "$force" ]; then
      mkdir -p "$(dirname "$base")"
      cp "$src" "$dst"; cp "$src" "$base"
      echo "pulled (forced, no prior base): $dst"
      return 0
    fi
    echo "no base (role never pulled from library) — pass --force to overwrite" >&2
    return 5
  fi
}

sub_role_promote() {
  local name=${1:?role name} force=
  shift
  while [ $# -gt 0 ]; do
    case $1 in --force) force=1; shift ;; *) echo "role-promote: unknown option: $1" >&2; return 2 ;; esac
  done
  case $name in *[!a-z0-9-]*|'') echo "role names are kebab-case: $name" >&2; return 2 ;; esac

  local root; root=$(_root)
  local lib; lib=$(_roles_lib)
  local src="$root/.team/roles/$name.md"
  local lib_f="$lib/$name.md"
  local base="$root/.team/roles/.base/$name.md"

  [ -f "$src" ] || { echo "role '$name' not found in project ($root/.team/roles/)" >&2; return 3; }

  # Secret/PII scan — hard gate; exit 2 on any hit
  if _secret_lines < "$src"; then
    echo "role-promote: secret/PII pattern found in $src — refusing to promote" >&2
    return 2
  fi

  mkdir -p "$lib"

  if [ ! -f "$lib_f" ]; then
    cp "$src" "$lib_f"
    mkdir -p "$(dirname "$base")"; cp "$src" "$base"
    echo "promoted: $lib_f"
    return 0
  fi

  if cmp -s "$lib_f" "$src"; then
    echo "already up-to-date: $lib_f"
    return 1
  fi

  if [ -f "$base" ]; then
    local beql beqs
    if cmp -s "$base" "$lib_f"; then beql=1; else beql=0; fi
    if cmp -s "$base" "$src"; then beqs=1; else beqs=0; fi

    if [ "$beql" = 1 ] && [ "$beqs" = 0 ]; then
      # Library unchanged since base, local changed — fast-forward promote
      diff "$lib_f" "$src" || true
      cp "$src" "$lib_f"; cp "$src" "$base"
      echo "promoted (fast-forward): $lib_f"
      return 0
    elif [ "$beql" = 0 ] && [ "$beqs" = 1 ]; then
      # global-ahead: library changed since base, local unchanged — must pull first
      # --force does NOT override this case (N13)
      echo "global library changed since last pull — run 'team.sh role-pull $name' first" >&2
      return 5
    else
      # Both changed since base — diverged
      echo "=== global changed since base ===" >&2
      diff "$base" "$lib_f" >&2 || true
      echo "=== local changed since base ===" >&2
      diff "$base" "$src" >&2 || true
      if [ -n "$force" ]; then
        cp "$src" "$lib_f"; cp "$src" "$base"
        echo "promoted (forced): $lib_f"
        return 0
      fi
      echo "diverged — review above, pass --force to overwrite" >&2
      return 5
    fi
  else
    # No base — role created locally, never pulled from library
    diff "$lib_f" "$src" >&2 || true
    if [ -n "$force" ]; then
      mkdir -p "$(dirname "$base")"
      cp "$src" "$lib_f"; cp "$src" "$base"
      echo "promoted (forced, no prior base): $lib_f"
      return 0
    fi
    echo "no base (role never pulled from library) — pass --force to overwrite" >&2
    return 5
  fi
}
