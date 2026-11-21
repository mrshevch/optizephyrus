#!/usr/bin/env bash
# Оптимизация Fedora 44 под ASUS ROG Zephyrus G14 (2022) GA402RJ
# (Ryzen 9 6900HS / Radeon 680M + RX 6700S / 14 GiB RAM / Micron 2450 NVMe / LUKS+btrfs)
#
# Сначала:  sudo dnf upgrade --refresh && sudo reboot   (скрипт проверит)
# Запуск:   sudo bash optimize.sh            — базовый набор (безопасный, обратимый)
#           sudo bash optimize.sh --asus     — плюс asusctl (COPR lukenukem/asus-linux)
#           sudo bash optimize.sh --scx      — плюс планировщик scx_lavd (COPR bieszczaders/kernel-cachyos-addons)
#           sudo bash optimize.sh --dry-run  — только показать, что будет сделано
# Флаги можно комбинировать и добавлять повторным запуском: sudo bash optimize.sh --scx --asus
# Откат:    sudo bash rollback.sh
set -euo pipefail

DRY=0; ASUS=0; SCX=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --asus)    ASUS=1 ;;
    --scx)     SCX=1 ;;
    *) echo "Неизвестный флаг: $a"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Запустите через sudo"; exit 1; }

# freeworld-драйвер требует ту же версию Mesa, что в updates — частичное обновление посреди тюнинга не нужно
if ! dnf -q check-upgrade >/dev/null 2>&1; then
  echo "Есть неустановленные обновления. Сначала: sudo dnf upgrade --refresh && sudo reboot"
  [[ $DRY -eq 1 ]] || exit 1
fi

BK="/var/backups/os-tune-$(date +%Y%m%d-%H%M%S)"
log()  { printf '\n\e[1;34m==> %s\e[0m\n' "$*"; }
run()  { echo "+ $*"; [[ $DRY -eq 1 ]] || "$@"; }
put()  { # put <файл> ; содержимое из stdin
  local f="$1"; echo "+ write $f"
  if [[ $DRY -eq 1 ]]; then sed 's/^/    /'; return; fi
  [[ -e "$f" ]] && { mkdir -p "$BK$(dirname "$f")"; cp -a "$f" "$BK$f"; }
  echo "$f" >> "$BK/created-files.txt"
  mkdir -p "$(dirname "$f")"; cat > "$f"
}

[[ $DRY -eq 1 ]] || { mkdir -p "$BK"; : > "$BK/created-files.txt"; : > "$BK/disabled-services.txt"; : > "$BK/disabled-repos.txt"; }
echo "Бэкап: $BK"

# ---------------------------------------------------------------------------
log "1. zram: zstd + размер = RAM (сжатие ~3:1 → эффективно ~25+ GiB памяти)"
put /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF

# ---------------------------------------------------------------------------
log "2. sysctl: ядро/VM под zram, десктоп и сеть"
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
run modprobe tcp_bbr
run sysctl --system -q

# ---------------------------------------------------------------------------
log "3. Аппаратное декодирование H.264/HEVC (AV1/VP9 уже работают) + полный ffmpeg"
# Касается RPM-приложений (Firefox, проигрыватели); Flatpak-приложения используют свои рантаймы
if ! rpm -q rpmfusion-free-release &>/dev/null; then
  run dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
fi
run dnf -y install --allowerasing mesa-va-drivers-freeworld mesa-va-drivers-freeworld.i686 libva-utils
rpm -q ffmpeg-free &>/dev/null && run dnf -y swap ffmpeg-free ffmpeg --allowerasing
# Репозитории, из которых ничего не установлено: NVIDIA (её нет), Chrome (он из Flatpak), PyCharm COPR
for r in rpmfusion-nonfree-nvidia-driver google-chrome copr:copr.fedorainfracloud.org:phracek:PyCharm; do
  if dnf -q repolist --enabled "$r" 2>/dev/null | grep -q .; then
    [[ $DRY -eq 1 ]] || echo "$r" >> "$BK/disabled-repos.txt"
    run dnf config-manager setopt "$r.enabled=0" || true
  fi
done

# ---------------------------------------------------------------------------
log "4. dnf: параллельные загрузки"
if [[ $DRY -eq 0 ]]; then cp -a /etc/dnf/dnf.conf "$BK/dnf.conf"; fi
grep -q '^max_parallel_downloads' /etc/dnf/dnf.conf || run sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf

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

# ---------------------------------------------------------------------------
log "6. journald: лимит 300 MiB"
put /etc/systemd/journald.conf.d/90-size.conf <<'EOF'
[Journal]
SystemMaxUse=300M
RuntimeMaxUse=64M
EOF
run systemctl restart systemd-journald
run journalctl --vacuum-size=300M

# ---------------------------------------------------------------------------
log "7. Btrfs: noatime (меньше записей метаданных на DRAM-less NVMe)"
if ! grep -qE '\sbtrfs\s.*noatime' /etc/fstab; then
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
if ! grubby --info=DEFAULT | grep -q 'nowatchdog'; then
  run grubby --update-kernel=ALL --args="nowatchdog"
  [[ $DRY -eq 1 ]] || touch "$BK/added-nowatchdog"
fi

# ---------------------------------------------------------------------------
if [[ $SCX -eq 1 ]]; then
  log "9. sched_ext: планировщик scx_lavd (интерактивность + autopower на батарее)"
  COPR_ID="copr:copr.fedorainfracloud.org:bieszczaders:kernel-cachyos-addons"
  run dnf -y copr enable bieszczaders/kernel-cachyos-addons
  # Из этого COPR берём только планировщики — ничего больше не подменится
  run dnf config-manager setopt "$COPR_ID.includepkgs=scx-scheds,scx-tools"
  run dnf -y install scx-scheds scx-tools
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
  run systemctl enable --now scx_loader.service
  [[ $DRY -eq 1 ]] || touch "$BK/enabled-scx"
fi

# ---------------------------------------------------------------------------
if [[ $ASUS -eq 1 ]]; then
  log "10. asusctl: кривые вентиляторов, подсветка, panel overdrive"
  # Лимит заряда не трогаем — им управляет GNOME («Сохранять здоровье батареи»)
  run dnf -y copr enable lukenukem/asus-linux
  run dnf -y install asusctl
  run systemctl enable --now asusd
  # supergfxctl намеренно НЕ ставлю: dGPU и так корректно уходит в D3cold
fi

log "Готово. Бэкап и список изменений: $BK"
echo "Перезагрузитесь, чтобы применились zram и nowatchdog. После перезагрузки проверьте:"
echo "  zramctl                                  # ALGORITHM zstd"
echo "  vainfo --display drm --device /dev/dri/by-path/pci-0000:07:00.0-render | grep -E 'H264|HEVC'"
echo "  sysctl net.ipv4.tcp_congestion_control   # bbr"
echo "  cat /proc/sys/kernel/watchdog            # 0"
[[ $SCX -eq 1 ]] && echo "  cat /sys/kernel/sched_ext/root/ops       # lavd" || true
