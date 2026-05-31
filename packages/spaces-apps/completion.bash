# Bash completion for spaces-apps.
#
# Completes:
#   - subcommand names
#   - global flags (--json, --describe, -f, -n)
#   - app names (via `spaces-apps list`) for subcommands that take one
#   - running unit names (via `spaces-apps --json running`) for kill/logs
#   - permission names (via `spaces-apps --json permissions`) for grant/revoke
#
# Installed at $out/share/bash-completion/completions/spaces-apps so
# bash-completion's standard auto-discovery picks it up. Source it
# manually with `source $(spaces-apps-completion-path)` if needed.

_spaces_apps() {
  # Pull current word + position from COMP_* directly so the
  # completion works without bash-completion's framework helpers
  # (`_init_completion`) loaded first.
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local cword=$COMP_CWORD
  local -a words=("${COMP_WORDS[@]}")

  # Find the subcommand — the first non-flag word after `spaces-apps`.
  local subcommand=""
  local subcommand_index=0
  local i
  for ((i = 1; i < cword; i++)); do
    case "${words[i]}" in
    -*) ;;
    *)
      subcommand="${words[i]}"
      subcommand_index=$i
      break
      ;;
    esac
  done

  # Before the subcommand → complete flags + subcommand names.
  if [[ -z $subcommand || $cword -le $subcommand_index ]]; then
    if [[ $cur == -* ]]; then
      mapfile -t COMPREPLY < <(compgen -W "--json --describe -f -n --help -h" -- "$cur")
      return
    fi
    mapfile -t COMPREPLY < <(compgen -W "list info running spawn kill logs audit spawns verify permissions grants grant revoke cleanup" -- "$cur")
    return
  fi

  # Arguments after the subcommand.
  case "$subcommand" in
  info | spawn | grants | grant | revoke)
    # First arg after these subcommands is an app name.
    local args_after=$((cword - subcommand_index))
    if [[ $args_after -eq 1 ]]; then
      local apps
      apps=$(spaces-apps list 2>/dev/null)
      mapfile -t COMPREPLY < <(compgen -W "$apps" -- "$cur")
      return
    fi
    # Second arg for grant/revoke is a permission name.
    # Be context-aware: `revoke` should only suggest
    # currently-granted permissions; `grant` should hide the
    # ones already granted. Falls back to the full catalogue
    # if either query fails — usability over strict accuracy.
    if [[ $args_after -eq 2 && ($subcommand == "grant" || $subcommand == "revoke") ]]; then
      local app="${words[subcommand_index + 1]}"
      local all_perms
      all_perms=$(spaces-apps --json permissions 2>/dev/null |
        grep -oE '"[^"]+"\s*:' | tr -d '":' | tr -d ' ')
      local current_grants=""
      if [[ -n $app ]]; then
        current_grants=$(spaces-apps grants "$app" 2>/dev/null |
          grep -v '^(' | grep -v '^$')
      fi
      local candidates="$all_perms"
      if [[ $subcommand == "revoke" && -n $current_grants ]]; then
        # Only suggest currently-granted permissions.
        candidates="$current_grants"
      elif [[ $subcommand == "grant" && -n $current_grants ]]; then
        # Subtract currently-granted from all.
        local p remaining=""
        while IFS= read -r p; do
          [[ -z $p ]] && continue
          if ! grep -qxF "$p" <<<"$current_grants"; then
            remaining+="$p"$'\n'
          fi
        done <<<"$all_perms"
        candidates="$remaining"
      fi
      mapfile -t COMPREPLY < <(compgen -W "$candidates" -- "$cur")
      return
    fi
    ;;
  kill | logs)
    # First arg is a running unit name.
    local args_after=$((cword - subcommand_index))
    if [[ $args_after -eq 1 ]]; then
      local units
      units=$(spaces-apps --json running 2>/dev/null |
        grep -oE '"unit":"[^"]+"' | cut -d'"' -f4)
      mapfile -t COMPREPLY < <(compgen -W "$units" -- "$cur")
      return
    fi
    ;;
  esac
}

complete -F _spaces_apps spaces-apps
