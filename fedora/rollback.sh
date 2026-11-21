#!/usr/bin/env bash
# Откат всех запусков optimize.sh и gaming.sh:  sudo bash rollback.sh
# Бэкапы обходятся от новых к старым, поэтому в итоге восстанавливается состояние до первого запуска.
# Поставленные скриптами пакеты (кодеки, RPM Fusion, scx, asusctl, gamemode.i686, mangohud, gamescope) не удаляются — при необходимости вручную.
# Удалённые скриптами пакеты (--lean, --no-calendar) ставятся обратно.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Запустите через sudo"; exit 1; }

shopt -s nullglob
BKS=(/var/backups/os-tune-*)   # glob сортирует по имени = по дате
(( ${#BKS[@]} )) || { echo "Бэкапов в /var/backups/os-tune-* нет — откатывать нечего"; exit 1; }

for (( i=${#BKS[@]}-1; i>=0; i-- )); do   # от новых к старым
  BK="${BKS[i]}"
  echo "Откат: $BK"

  # Созданные файлы: восстановить прежнюю версию или удалить
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
      [[ $s == *.* ]] || s+=.service   # старые бэкапы хранят имя службы без суффикса
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
    dnf -y install "${P[@]}" || echo "!! Не удалось поставить обратно: ${P[*]} — нет сети? Повторите: sudo dnf install ${P[*]}"
  fi

  if [[ -f "$BK/masked-user-units.txt" ]]; then
    while read -r u; do
      [[ -n "$u" ]] && systemctl --global unmask "$u" || true
    done < "$BK/masked-user-units.txt"
  fi

  if [[ -f "$BK/enabled-scx" ]]; then
    systemctl disable --now scx_loader.service || true   # ядро сразу возвращается к EEVDF
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
udevadm control --reload   # удалённое правило Wi-Fi перестаёт действовать
sysctl --system -q
systemctl try-restart tuned-ppd   # перечитать восстановленный ppd.conf
echo "Откат выполнен. Перезагрузитесь."
