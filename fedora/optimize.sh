#!/usr/bin/env bash
# Оптимизация Fedora 44 под ASUS ROG Zephyrus G14 (2022) GA402RJ
# (Ryzen 9 6900HS / Radeon 680M + RX 6700S / 14 GiB RAM / Micron 2450 NVMe / LUKS+btrfs)
#
# Сначала:  sudo dnf upgrade --refresh && sudo reboot   (скрипт проверит)
# Запуск:   sudo bash optimize.sh            — базовый набор (безопасный, обратимый)
#           sudo bash optimize.sh --asus     — плюс asusctl (COPR lukenukem/asus-linux)
#           sudo bash optimize.sh --scx      — плюс планировщик scx_lavd (COPR bieszczaders/kernel-cachyos-addons)
#           sudo bash optimize.sh --lean     — плюс без gnome-software, dnf-makecache.timer и индексатора файлов
#           sudo bash optimize.sh --no-calendar — плюс без Календаря, Контактов и evolution-data-server
#           sudo bash optimize.sh --dry-run  — только показать, что будет сделано
# Флаги можно комбинировать и добавлять повторным запуском: sudo bash optimize.sh --scx --asus
# Повторный запуск выполняет только то, что ещё не применено; уже применённое помечается «✓».
# Откат:    sudo bash rollback.sh
set -euo pipefail

DRY=0; ASUS=0; SCX=0; LEAN=0; NOCAL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --asus)    ASUS=1 ;;
    --scx)     SCX=1 ;;
    --lean)    LEAN=1 ;;
    --no-calendar) NOCAL=1 ;;
    *) echo "Неизвестный флаг: $a"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Запустите через sudo"; exit 1; }

# freeworld-драйвер требует ту же версию Mesa, что в updates — частичное обновление посреди тюнинга не нужно
if ! dnf -q check-upgrade >/dev/null 2>&1; then
  echo "Есть неустановленные обновления. Сначала: sudo dnf upgrade --refresh && sudo reboot"
  [[ $DRY -eq 1 ]] || exit 1
fi

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $DRY -eq 1 ]] || { mkdir -p "$BK"; : > "$BK/created-files.txt"; : > "$BK/disabled-services.txt"; : > "$BK/disabled-repos.txt"; }

# ---------------------------------------------------------------------------
log "1. zram: zstd + размер = RAM (сжатие ~3:1 → эффективно ~25+ GiB памяти)"
put /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF
[[ $CHANGED -eq 1 ]] && REBOOT=1

# ---------------------------------------------------------------------------
log "2. sysctl: ядро/VM под zram, десктоп и сеть (+ режим «Производительность» их больше не перетирает)"
put /etc/sysctl.d/90-g14-tuning.conf <<'EOF'
# --- Память (swap только в zram: «свопить» в RAM дёшево) ---
vm.swappiness = 180
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.vfs_cache_pressure = 50
# Грязные страницы в байтах: меньше «фризов» при копировании больших файлов
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864
# --- Разработка (PyCharm / IDE / node) ---
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
# --- Сеть: BBR вместо cubic (влияет на отдачу данных с ноутбука) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
EOF
put /etc/modules-load.d/bbr.conf <<'EOF'
tcp_bbr
EOF
if [[ -d /sys/module/tcp_bbr ]]; then ok "модуль tcp_bbr загружен"; else run modprobe tcp_bbr; fi
SYSCTL_CHANGED=$CHANGED; CHANGED=0

# Режим GNOME «Производительность» = tuned throughput-performance: он ставит vm.swappiness=10 и dirty 40%/10%,
# то есть перетирает настройки выше. Заменяем его своим профилем — то же ускорение CPU, без серверных sysctl.
put /etc/tuned/profiles/g14-performance/tuned.conf <<'EOF'
[main]
summary=G14: EPP performance + ASUS Performance thermal policy, without server sysctls

[cpu]
governor=performance
energy_perf_bias=performance
energy_performance_preference=performance
boost=1

# ASUS throttle_thermal_policy = Performance: выше лимиты мощности CPU/dGPU и обороты вентиляторов
[acpi]
platform_profile=performance

[video]
panel_power_savings=0
EOF
if grep -q '^performance=throughput-performance$' /etc/tuned/ppd.conf; then
  [[ $DRY -eq 1 ]] || tuned-adm profile_info g14-performance >/dev/null   # tuned видит профиль — иначе ppd.conf не трогаем
  [[ $DRY -eq 1 ]] || cp -a /etc/tuned/ppd.conf "$BK/ppd.conf"
  run sed -i 's/^performance=throughput-performance$/performance=g14-performance/' /etc/tuned/ppd.conf
elif grep -q '^performance=g14-performance$' /etc/tuned/ppd.conf; then
  ok "режим «Производительность» → tuned g14-performance"
else
  echo "!! В /etc/tuned/ppd.conf нестандартная строка performance= — замените её вручную на performance=g14-performance"
fi
if [[ $CHANGED -eq 1 ]]; then run systemctl restart tuned-ppd; fi

# Последним: tuned при смене профиля откатывает свои sysctl — наши значения должны лечь поверх
if [[ $SYSCTL_CHANGED -eq 1 ]] || ! sysctl_live /etc/sysctl.d/90-g14-tuning.conf; then
  run sysctl --system -q
else
  ok "значения sysctl уже действуют"
fi

# ---------------------------------------------------------------------------
log "3. Аппаратное декодирование H.264/HEVC (AV1/VP9 уже работают) + полный ffmpeg"
# Касается RPM-приложений (Firefox, проигрыватели); Flatpak-приложения используют свои рантаймы
if rpm -q rpmfusion-free-release &>/dev/null; then
  ok "RPM Fusion free подключён"
else
  run dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
fi
pkgs --allowerasing mesa-va-drivers-freeworld mesa-va-drivers-freeworld.i686 libva-utils
if rpm -q ffmpeg-free &>/dev/null; then
  run dnf -y swap ffmpeg-free ffmpeg --allowerasing
else
  ok "ffmpeg-free не установлен (заменён на ffmpeg)"
fi
# Репозитории, из которых ничего не установлено: NVIDIA (её нет), Chrome (он из Flatpak), PyCharm COPR
CHANGED=0
for r in rpmfusion-nonfree-nvidia-driver google-chrome copr:copr.fedorainfracloud.org:phracek:PyCharm; do
  if repo_on "$r"; then
    [[ $DRY -eq 1 ]] || echo "$r" >> "$BK/disabled-repos.txt"
    run dnf config-manager setopt "$r.enabled=0" || true
  fi
done
[[ $CHANGED -eq 1 ]] || ok "лишние репозитории выключены"

# ---------------------------------------------------------------------------
log "4. dnf: параллельные загрузки"
if grep -q '^max_parallel_downloads' /etc/dnf/dnf.conf; then
  ok "$(grep '^max_parallel_downloads' /etc/dnf/dnf.conf)"
else
  [[ $DRY -eq 1 ]] || cp -a /etc/dnf/dnf.conf "$BK/dnf.conf"
  run sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf
fi

# ---------------------------------------------------------------------------
log "5. Отключение работающих, но ненужных служб"
SERVICES=(
  ModemManager                                       # нет модема
  abrtd abrt-journal-core abrt-oops abrt-xorg        # сборщик крашей (CPU/RAM/диск)
  rsyslog                                            # дублирует journald — двойная запись логов
)
for s in "${SERVICES[@]}"; do
  if systemctl is-enabled "$s.service" &>/dev/null; then
    [[ $DRY -eq 1 ]] || echo "$s" >> "$BK/disabled-services.txt"
    run systemctl disable --now "$s.service" || true
  fi
done
[[ $CHANGED -eq 1 ]] || ok "службы уже отключены: ${SERVICES[*]}"

# ---------------------------------------------------------------------------
log "6. journald: лимит 300 MiB"
put /etc/systemd/journald.conf.d/90-size.conf <<'EOF'
[Journal]
SystemMaxUse=300M
RuntimeMaxUse=64M
EOF
if [[ $CHANGED -eq 1 ]]; then
  run systemctl restart systemd-journald
  run journalctl --vacuum-size=300M
fi

# ---------------------------------------------------------------------------
log "7. Btrfs: noatime (меньше записей метаданных на DRAM-less NVMe)"
if grep -qE '\sbtrfs\s.*noatime' /etc/fstab; then
  ok "noatime уже в /etc/fstab"
else
  [[ $DRY -eq 1 ]] || cp -a /etc/fstab "$BK/fstab"
  run sed -i -E '/\sbtrfs\s/ s/(subvol=[a-z]+,compress=zstd:1)/\1,noatime/' /etc/fstab
  if [[ $DRY -eq 0 ]]; then
    if findmnt --verify --tab-file /etc/fstab >/dev/null; then
      systemctl daemon-reload
      mount -o remount,noatime /
      mount -o remount,noatime /home
    else
      echo "!! findmnt --verify не прошёл — возвращаю fstab"; cp -a "$BK/fstab" /etc/fstab
    fi
  fi
fi

# ---------------------------------------------------------------------------
log "8. Ядро: nowatchdog — убрать таймеры детектора зависаний на всех 16 потоках"
# Аппаратный sp5100_tco не трогаем: в работе он выключен, а при перезагрузке страхует от зависания
if karg_on nowatchdog; then
  ok "nowatchdog уже в параметрах ядра"
else
  run grubby --update-kernel=ALL --args="nowatchdog"
  [[ $DRY -eq 1 ]] || touch "$BK/added-nowatchdog"
  REBOOT=1
fi

# ---------------------------------------------------------------------------
if [[ $SCX -eq 1 ]]; then
  log "9. sched_ext: планировщик scx_lavd (интерактивность + autopower на батарее)"
  COPR_ID="copr:copr.fedorainfracloud.org:bieszczaders:kernel-cachyos-addons"
  if repo_on "$COPR_ID"; then ok "COPR kernel-cachyos-addons подключён"; else run dnf -y copr enable bieszczaders/kernel-cachyos-addons; fi
  # Из этого COPR берём только планировщики — ничего больше не подменится
  if grep -qs '^includepkgs=scx-scheds,scx-tools$' /etc/dnf/repos.override.d/*.repo; then
    ok "COPR ограничен пакетами scx-scheds, scx-tools"
  else
    run dnf config-manager setopt "$COPR_ID.includepkgs=scx-scheds,scx-tools"
  fi
  pkgs scx-scheds scx-tools
  CHANGED=0
  put /etc/scx_loader.toml <<'EOF'
# scx_loader: какой sched_ext-планировщик запускать при загрузке.
# Остановить и вернуться к штатному EEVDF:  sudo systemctl disable --now scx_loader
# Сменить режим на лету:                     scxctl switch -m gaming|powersave|auto
default_sched = "scx_lavd"
default_mode = "Auto"

[scheds.scx_lavd]
auto_mode = ["--autopower"]        # сам переключается между performance/powersave по профилю питания
gaming_mode = ["--performance"]
lowlatency_mode = ["--performance"]
powersave_mode = ["--powersave"]
server_mode = []
EOF
  if ! systemctl is-enabled -q scx_loader.service || ! systemctl is-active -q scx_loader.service; then
    run systemctl enable --now scx_loader.service
    [[ $DRY -eq 1 ]] || touch "$BK/enabled-scx"
  elif [[ $CHANGED -eq 1 ]]; then
    run systemctl restart scx_loader.service   # подхватить новый конфиг
  else
    ok "scx_loader работает: $(cat /sys/kernel/sched_ext/root/ops 2>/dev/null || echo '?')"
  fi
fi

# ---------------------------------------------------------------------------
if [[ $ASUS -eq 1 ]]; then
  log "10. asusctl: кривые вентиляторов, подсветка, panel overdrive"
  # Лимит заряда не трогаем — им управляет GNOME («Сохранять здоровье батареи»)
  if repo_on copr:copr.fedorainfracloud.org:lukenukem:asus-linux; then ok "COPR asus-linux подключён"; else run dnf -y copr enable lukenukem/asus-linux; fi
  pkgs asusctl
  if systemctl is-enabled -q asusd && systemctl is-active -q asusd; then ok "asusd работает"; else run systemctl enable --now asusd; fi
  # supergfxctl намеренно НЕ ставлю: dGPU и так корректно уходит в D3cold
fi

# ---------------------------------------------------------------------------
log "11. Wi-Fi: энергосбережение на батарее, от сети — выключено"
# В профиле подключения стоит powersave=disable, и NM применяет его при каждом подключении (в том числе после сна),
# поэтому помощник зовут и udev (сменилось питание), и dispatcher NM (подключились)
WPS=/usr/local/libexec/g14-wifi-powersave
WPS_NM=/etc/NetworkManager/dispatcher.d/90-g14-wifi-powersave
put "$WPS" < "$(dirname "${BASH_SOURCE[0]}")/g14-wifi-powersave"
put /etc/udev/rules.d/90-g14-wifi-powersave.rules <<EOF
# Зарядку подключили или отключили — переключить power save Wi-Fi
SUBSYSTEM=="power_supply", KERNEL=="AC0", ACTION=="change", RUN+="$WPS"
EOF
put "$WPS_NM" <<EOF
#!/bin/sh
# NM при каждом подключении применяет powersave из профиля подключения — вернуть «на батарее включено»
[ "\$2" = up ] && exec $WPS
exit 0
EOF
for f in "$WPS" "$WPS_NM"; do [[ -x "$f" ]] || run chmod 755 "$f"; done   # NM запускает только исполняемые root-файлы
if [[ $CHANGED -eq 1 ]]; then
  run udevadm control --reload
  run "$WPS"   # применить сразу, не дожидаясь смены питания
else
  ok "power save Wi-Fi переключается по питанию"
fi

# ---------------------------------------------------------------------------
if [[ $LEAN -eq 1 ]]; then
  log "12. --lean: без фоновых обновлений и индексатора файлов"
  # gnome-software весь сеанс держит ~245 МБ (+ dnf5daemon-server ~126 МБ) и сам качает обновления.
  # Выключить автозапуск, не сломав окно приложения, нельзя: сеанс и меню поднимают одну user-службу
  unpkgs gnome-software gnome-software-fedora-langpacks
  if systemctl is-enabled -q dnf-makecache.timer; then
    [[ $DRY -eq 1 ]] || echo dnf-makecache.timer >> "$BK/disabled-services.txt"
    run systemctl disable --now dnf-makecache.timer
  else
    ok "dnf-makecache.timer выключен"
  fi
  mask_user localsearch-3.service   # индексатор файлов; Nautilus без него ищет по имени
  if [[ $CHANGED -eq 1 ]]; then REBOOT=1; fi   # запущенные экземпляры живут до выхода из сеанса
fi

# ---------------------------------------------------------------------------
if [[ $NOCAL -eq 1 ]]; then
  log "13. --no-calendar: без календаря и контактов"
  unpkgs gnome-calendar gnome-contacts
  # Серверы данных календаря и контактов (evolution-data-server); GNOME Online Accounts не трогаем
  mask_user evolution-alarm-notify.service evolution-source-registry.service \
            evolution-calendar-factory.service evolution-addressbook-factory.service
  if [[ $CHANGED -eq 1 ]]; then REBOOT=1; fi
fi

# ---------------------------------------------------------------------------
summary
if [[ $REBOOT -eq 1 ]]; then echo "Перезагрузитесь: zram, параметры ядра и службы GNOME применяются при загрузке и входе."; fi
echo "Проверка (zram и nowatchdog — после перезагрузки):"
echo "  zramctl                                  # ALGORITHM zstd"
echo "  vainfo --display drm --device /dev/dri/by-path/pci-0000:07:00.0-render | grep -E 'H264|HEVC'"
echo "  sysctl net.ipv4.tcp_congestion_control   # bbr"
echo "  grep ^performance= /etc/tuned/ppd.conf   # performance=g14-performance"
echo "  cat /proc/sys/kernel/watchdog            # 0"
if [[ $SCX -eq 1 ]]; then echo "  cat /sys/kernel/sched_ext/root/ops       # lavd"; fi
echo "  iw dev wlp5s0 get power_save             # on от батареи, off от сети"
if [[ $LEAN -eq 1 ]]; then
  echo "  rpm -q gnome-software                    # не установлен"
  echo "  systemctl --global is-enabled localsearch-3.service   # masked"
fi
