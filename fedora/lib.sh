# shellcheck shell=bash disable=SC2034  # the scripts that source this file read these variables
# Shared helpers for optimize.sh and gaming.sh (loaded with source; DRY must be set before it).
# Each step first checks whether it is already applied: applied steps print "✓", changes print "+" or "~".

BK="/var/backups/os-tune-$(date +%Y%m%d-%H%M%S)"
CHANGES=0   # number of changes made (with --dry-run: that would be made)
CHANGED=0   # whether the current section changed something; reset by log()
REBOOT=0    # whether a reboot is needed

log()  { CHANGED=0; printf '\n\e[1;34m==> %s\e[0m\n' "$*"; }
ok()   { printf '  \e[32m✓ %s\e[0m\n' "$*"; }
run()  { echo "+ $*"; CHANGES=$((CHANGES+1)); CHANGED=1; [[ $DRY -eq 1 ]] || "$@"; }

put()  { # put <file> ; content from stdin. Leaves a file with the same content alone, prints a diff for a changed one
  local f="$1" new; new="$(cat)"
  if [[ -f "$f" && "$(cat "$f")" == "$new" ]]; then ok "$f — unchanged"; return; fi
  CHANGES=$((CHANGES+1)); CHANGED=1
  if [[ -e "$f" ]]; then
    echo "~ update $f"; diff -u "$f" <(printf '%s\n' "$new") | tail -n +3 | sed 's/^/    /' || true
  else
    echo "+ write $f"; printf '%s\n' "$new" | sed 's/^/    /'
  fi
  if [[ $DRY -eq 1 ]]; then return; fi
  [[ -e "$f" ]] && { mkdir -p "$BK$(dirname "$f")"; cp -a "$f" "$BK$f"; }
  echo "$f" >> "$BK/created-files.txt"
  mkdir -p "$(dirname "$f")"; printf '%s\n' "$new" > "$f"
}

pkgs() { # pkgs [--dnf-options] <package>... — dnf install only the missing ones
  local a o=() p=() m=()
  for a in "$@"; do
    if [[ $a == -* ]]; then o+=("$a"); else p+=("$a"); rpm -q "$a" &>/dev/null || m+=("$a"); fi
  done
  if [[ ${#m[@]} -eq 0 ]]; then ok "already installed: ${p[*]}"; else run dnf -y install "${o[@]}" "${m[@]}"; fi
}

unpkgs() { # unpkgs [dnf options] <package>... — dnf remove only the installed ones; names go to removed-packages.txt so rollback reinstalls them
  local p o=() names=() m=()
  for p in "$@"; do
    if [[ $p == -* ]]; then o+=("$p"); continue; fi
    names+=("$p"); if rpm -q "$p" &>/dev/null; then m+=("$p"); fi
  done
  if [[ ${#m[@]} -eq 0 ]]; then ok "already removed: ${names[*]}"; return; fi
  [[ $DRY -eq 1 ]] || printf '%s\n' "${m[@]}" >> "$BK/removed-packages.txt"
  run dnf -y remove "${o[@]}" "${m[@]}"
}

mask_user() { # mask_user <unit>... — systemctl --global mask only the units not masked yet; names go to masked-user-units.txt
  local u m=()
  for u in "$@"; do [[ "$(systemctl --global is-enabled "$u" 2>/dev/null)" == masked ]] || m+=("$u"); done
  if [[ ${#m[@]} -eq 0 ]]; then ok "already masked: $*"; return; fi
  [[ $DRY -eq 1 ]] || printf '%s\n' "${m[@]}" >> "$BK/masked-user-units.txt"
  run systemctl --global mask "${m[@]}"
}

# No "| grep -q": with pipefail, grep exiting early kills the writer with SIGPIPE and gives a false "no"
repo_on() { [[ -n "$(dnf -q repolist --enabled "$1" 2>/dev/null)" ]]; }
karg_on() { [[ " $(grubby --info=DEFAULT | sed -n 's/^args="\(.*\)"$/\1/p') " == *" $1 "* ]]; }

sysctl_live() { # every "key = value" in the file is already live in the kernel
  local k v
  while IFS='=' read -r k v; do
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    [[ -z "$k" || $k == \#* ]] && continue
    [[ "$(sysctl -n "$k" 2>/dev/null)" == "$v" ]] || return 1
  done < "$1"
}

summary() { # no changes → delete the empty backup and exit; dry-run → print the total and exit
  if [[ $CHANGES -eq 0 ]]; then
    [[ $DRY -eq 1 ]] || rm -rf "$BK"
    log "Everything is already applied, nothing to change"; exit 0
  fi
  if [[ $DRY -eq 1 ]]; then log "Dry-run: $CHANGES change(s) to apply. Nothing was changed."; exit 0; fi
  log "Done: $CHANGES change(s). Backup and list of changes: $BK"
}
