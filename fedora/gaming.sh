#!/usr/bin/env bash
# Игровые оптимизации Fedora 44 для ASUS ROG Zephyrus G14 (2022) GA402RJ
# (Ryzen 9 6900HS / RX 6700S + Radeon 680M / 14 GiB RAM)
#
# Сначала:  sudo bash optimize.sh   (в нём профиль «Производительность» g14-performance — скрипт проверит)
# Запуск:   sudo bash gaming.sh                    — пакеты, GameMode, sysctl
#           sudo bash gaming.sh --no-mitigations   — плюс mitigations=off (быстрее syscall-и, слабее защита от Spectre-подобных атак)
#           sudo bash gaming.sh --dry-run          — только показать, что будет сделано
# Лучше вместе с optimize.sh --scx: scx_lavd --autopower сам уходит в performance, когда EPP = performance.
# В Steam: Свойства игры → Параметры запуска:  gamemoderun %command%
# Повторный запуск выполняет только то, что ещё не применено; уже применённое помечается «✓».
# Откат:    sudo bash rollback.sh   (общий с optimize.sh)
set -euo pipefail

DRY=0; NOMIT=0
for a in "$@"; do
  case "$a" in
    --dry-run)        DRY=1 ;;
    --no-mitigations) NOMIT=1 ;;
    *) echo "Неизвестный флаг: $a"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Запустите через sudo"; exit 1; }
U="${SUDO_USER:-}"
[[ -n "$U" && "$U" != root ]] || { echo "Запустите через sudo из-под своего пользователя: он будет добавлен в группу gamemode"; exit 1; }

# Хуки GameMode включают «Производительность»; без профиля g14-performance из optimize.sh она ставит vm.swappiness=10
if ! grep -q '^performance=g14-performance$' /etc/tuned/ppd.conf; then
  echo "Сначала: sudo bash optimize.sh  (режим «Производительность» без серверных sysctl)"
  [[ $DRY -eq 1 ]] || exit 1
fi

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $DRY -eq 1 ]] || { mkdir -p "$BK"; : > "$BK/created-files.txt"; }

# ---------------------------------------------------------------------------
log "1. Пакеты: 32-битный GameMode, MangoHud, gamescope"
# gamemode.i686 — иначе 32-битные игры не включают GameMode; mangohud — FPS/frametime; gamescope — FSR-апскейл до 2560×1600
pkgs gamemode gamemode.i686 mangohud mangohud.i686 gamescope

# ---------------------------------------------------------------------------
log "2. GameMode: права, renice и автопереключение профиля питания"
# Без группы gamemode polkit запрещает смену governor, а limits.d — nice -10: сейчас GameMode молча ничего не делает
if [[ " $(id -nG "$U") " == *" gamemode "* ]]; then
  ok "$U уже в группе gamemode"
else
  run usermod -aG gamemode "$U"
  [[ $DRY -eq 1 ]] || echo "$U" > "$BK/added-gamemode-group"
  REBOOT=1
fi
PPD='busctl --system set-property org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile s'
put /etc/gamemode.ini <<EOF
; Дополняет /usr/share/gamemode/gamemode.ini (governor performance, ioprio, запрет скринсейвера уже там)
[general]
; nice -10 для процессов игры (максимум, разрешённый группе gamemode в limits.d)
renice=10

[custom]
; На время игры — «Производительность» (tuned g14-performance); переключение без пароля, как в меню GNOME
start=$PPD performance
; shortcut: после игры всегда balanced, даже если до неё был power-saver; запоминать прежний профиль, если это мешает
end=$PPD balanced
EOF

# ---------------------------------------------------------------------------
log "3. sysctl: меньше фоновых пауз подсистемы памяти (значения SteamOS)"
put /etc/sysctl.d/91-g14-gaming.conf <<'EOF'
# Проактивная компакция переносит страницы в фоне → TLB shootdown на всех ядрах → микрофризы
vm.compaction_proactiveness = 0
# Page lock раньше передаётся ожидающему потоку — короче «хвосты» задержек
vm.page_lock_unfairness = 1
EOF
if [[ $CHANGED -eq 1 ]] || ! sysctl_live /etc/sysctl.d/91-g14-gaming.conf; then
  run sysctl --system -q
else
  ok "значения sysctl уже действуют"
fi

# ---------------------------------------------------------------------------
if [[ $NOMIT -eq 1 ]]; then
  log "4. Ядро: mitigations=off"
  # На Zen 3+ включены SRSO Safe RET, STIBP always-on и TSA (VERW на каждом выходе из ядра) — бьют по syscall-тяжёлому Wine/Proton
  if karg_on mitigations=off; then
    ok "mitigations=off уже в параметрах ядра"
  else
    run grubby --update-kernel=ALL --args="mitigations=off"
    [[ $DRY -eq 1 ]] || touch "$BK/added-mitigations-off"
    REBOOT=1
  fi
fi

summary
if [[ $REBOOT -eq 1 ]]; then echo "Перезагрузитесь: группа gamemode и лимит nice применяются при входе, mitigations=off — при загрузке."; fi
echo "В Steam → Свойства игры → Параметры запуска:  gamemoderun %command%   (с оверлеем: mangohud gamemoderun %command%)"
echo "Проверка во время игры:"
echo "  gamemoded -s                                                    # gamemode is active"
echo "  cat /sys/firmware/acpi/platform_profile                         # performance"
echo "  cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference   # performance"
echo "  sysctl vm.swappiness                                            # 180, не 10"
if [[ $NOMIT -eq 1 ]]; then echo "  cat /sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow   # Vulnerable"; fi
