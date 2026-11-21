#!/usr/bin/env bash
# Reverts all runs of optimize.sh and gaming.sh:  sudo bash rollback.sh
# Backups are processed from newest to oldest, so you end up with the state from before the first run.
# Packages the scripts installed (codecs, RPM Fusion, scx, asusctl, gamemode.i686, mangohud, gamescope) are not removed; remove them by hand if needed.
# Packages the scripts removed (--lean, --no-calendar) are installed again.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run it with sudo"; exit 1; }

shopt -s nullglob
BKS=(/var/backups/os-tune-*)   # the glob sorts by name, which is by date
(( ${#BKS[@]} )) || { echo "No backups in /var/backups/os-tune-*, nothing to roll back"; exit 1; }

for (( i=${#BKS[@]}-1; i>=0; i-- )); do   # newest first
  BK="${BKS[i]}"
  echo "Rolling back: $BK"

  # Files the scripts wrote: restore the previous version or delete
  if [[ -f "$BK/created-files.txt" ]]; then
    while read -r f; do
      [[ -z "$f" ]] && continue
      if [[ -e "$BK$f" ]]; then cp -a "$BK$f" "$f"; else rm -f "$f"; fi
    done < "$BK/created-files.txt"
  fi

  [[ -f "$BK/fstab" ]]    && cp -a "$BK/fstab" /etc/fstab
  [[ -f "$BK/dnf.conf" ]] && cp -a "$BK/dnf.conf" /etc/dnf/dnf.conf
  [[ -f "$BK/ppd.conf" ]] && cp -a "$BK/ppd.conf" /etc/tuned/ppd.conf

  if [[ -f "$BK/disabled-services.txt" ]]; then
    while read -r s; do
      [[ -n "$s" ]] || continue
      [[ $s == *.* ]] || s+=.service   # old backups store service names without the suffix
      systemctl enable "$s" || true
    done < "$BK/disabled-services.txt"
  fi

  if [[ -f "$BK/disabled-repos.txt" ]]; then
    while read -r r; do
      [[ -n "$r" ]] && dnf config-manager setopt "$r.enabled=1" || true
    done < "$BK/disabled-repos.txt"
  fi

  if [[ -s "$BK/removed-packages.txt" ]]; then
    mapfile -t P < "$BK/removed-packages.txt"
    dnf -y install "${P[@]}" || echo "!! Could not reinstall: ${P[*]}. No network? Retry: sudo dnf install ${P[*]}"
  fi

  if [[ -f "$BK/masked-user-units.txt" ]]; then
    while read -r u; do
      [[ -n "$u" ]] && systemctl --global unmask "$u" || true
    done < "$BK/masked-user-units.txt"
  fi

  if [[ -f "$BK/enabled-scx" ]]; then
    systemctl disable --now scx_loader.service || true   # the kernel goes back to EEVDF right away
  fi
  if [[ -f "$BK/added-nowatchdog" ]]; then
    grubby --update-kernel=ALL --remove-args="nowatchdog"
  fi
  if [[ -f "$BK/added-mitigations-off" ]]; then
    grubby --update-kernel=ALL --remove-args="mitigations=off"
  fi
  if [[ -f "$BK/added-gamemode-group" ]]; then
    gpasswd -d "$(cat "$BK/added-gamemode-group")" gamemode || true
  fi
done

systemctl daemon-reload
udevadm control --reload   # the deleted Wi-Fi rule stops working
sysctl --system -q
systemctl try-restart tuned-ppd   # re-read the restored ppd.conf
echo "Rollback done. Reboot now."
