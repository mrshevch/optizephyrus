#!/usr/bin/env bash
# Откат всех запусков optimize.sh:  sudo bash rollback.sh
# Бэкапы обходятся от новых к старым, поэтому в итоге восстанавливается состояние до первого запуска.
# Пакеты (кодеки, RPM Fusion, scx, asusctl) не удаляются — при необходимости вручную.
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

  if [[ -f "$BK/disabled-services.txt" ]]; then
    while read -r s; do
      [[ -n "$s" ]] && systemctl enable "$s.service" || true
    done < "$BK/disabled-services.txt"
  fi

  if [[ -f "$BK/disabled-repos.txt" ]]; then
    while read -r r; do
      [[ -n "$r" ]] && dnf config-manager setopt "$r.enabled=1" || true
    done < "$BK/disabled-repos.txt"
  fi

  if [[ -f "$BK/enabled-scx" ]]; then
    systemctl disable --now scx_loader.service || true   # ядро сразу возвращается к EEVDF
  fi
  if [[ -f "$BK/added-nowatchdog" ]]; then
    grubby --update-kernel=ALL --remove-args="nowatchdog"
  fi
done

systemctl daemon-reload
sysctl --system -q
echo "Откат выполнен. Перезагрузитесь."
