#!/usr/bin/env bash
# Fedora 44 tuning for the ASUS ROG Zephyrus G14 (2022) GA402RJ
# (Ryzen 9 6900HS / Radeon 680M + RX 6700S / 14 GiB RAM / Micron 2450 NVMe / LUKS+btrfs)
#
# First:    sudo dnf upgrade --refresh && sudo reboot   (the script checks)
# Usage:    sudo bash optimize.sh            — base set (safe, reversible)
#           sudo bash optimize.sh --asus     — plus asusctl (COPR lukenukem/asus-linux)
#           sudo bash optimize.sh --scx      — plus the scx_lavd scheduler (COPR bieszczaders/kernel-cachyos-addons)
#           sudo bash optimize.sh --lean     — plus no gnome-software, dnf-makecache.timer, file indexer or Typing Booster
#           sudo bash optimize.sh --no-calendar — plus no Calendar, Contacts or evolution-data-server
#           sudo bash optimize.sh --dry-run  — only show what would be done
# Flags can be combined and added later with another run: sudo bash optimize.sh --scx --asus
# A re-run only does what is not applied yet; applied steps are marked "✓".
# Rollback: sudo bash rollback.sh
set -euo pipefail

DRY=0; ASUS=0; SCX=0; LEAN=0; NOCAL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --asus)    ASUS=1 ;;
    --scx)     SCX=1 ;;
    --lean)    LEAN=1 ;;
    --no-calendar) NOCAL=1 ;;
    *) echo "Unknown flag: $a"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run it with sudo"; exit 1; }

# The freeworld driver needs the same Mesa version as updates: no partial upgrade in the middle of tuning
if ! dnf -q check-upgrade >/dev/null 2>&1; then
  echo "There are pending updates. First: sudo dnf upgrade --refresh && sudo reboot"
  [[ $DRY -eq 1 ]] || exit 1
fi

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $DRY -eq 1 ]] || { mkdir -p "$BK"; : > "$BK/created-files.txt"; : > "$BK/disabled-services.txt"; : > "$BK/disabled-repos.txt"; }

# ---------------------------------------------------------------------------
log "1. zram: zstd + size = RAM (about 3:1 compression → roughly 25+ GiB of usable memory)"
put /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF
[[ $CHANGED -eq 1 ]] && REBOOT=1

# ---------------------------------------------------------------------------
log "2. sysctl: kernel/VM for zram, desktop and network (+ Performance mode no longer overrides them)"
put /etc/sysctl.d/90-g14-tuning.conf <<'EOF'
# --- Memory (swap lives only in zram, so swapping to RAM is cheap) ---
vm.swappiness = 180
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.vfs_cache_pressure = 50
# Dirty page limits in bytes: fewer freezes when copying large files
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864
# --- Development (PyCharm / IDEs / node) ---
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
# --- Network: BBR instead of cubic (affects uploads from the laptop) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
EOF
put /etc/modules-load.d/bbr.conf <<'EOF'
tcp_bbr
EOF
if [[ -d /sys/module/tcp_bbr ]]; then ok "tcp_bbr module is loaded"; else run modprobe tcp_bbr; fi
SYSCTL_CHANGED=$CHANGED; CHANGED=0

# GNOME Performance mode = tuned throughput-performance: it sets vm.swappiness=10 and dirty 40%/10%,
# which overrides the settings above. Replace it with our own profile: the same CPU speed-up, no server sysctls.
put /etc/tuned/profiles/g14-performance/tuned.conf <<'EOF'
[main]
summary=G14: EPP performance + ASUS Performance thermal policy, without server sysctls

[cpu]
governor=performance
energy_perf_bias=performance
energy_performance_preference=performance
boost=1

# ASUS throttle_thermal_policy = Performance: higher CPU/dGPU power limits and fan speeds
[acpi]
platform_profile=performance

[video]
panel_power_savings=0
EOF
if grep -q '^performance=throughput-performance$' /etc/tuned/ppd.conf; then
  [[ $DRY -eq 1 ]] || tuned-adm profile_info g14-performance >/dev/null   # tuned sees the profile; otherwise leave ppd.conf alone
  [[ $DRY -eq 1 ]] || cp -a /etc/tuned/ppd.conf "$BK/ppd.conf"
  run sed -i 's/^performance=throughput-performance$/performance=g14-performance/' /etc/tuned/ppd.conf
elif grep -q '^performance=g14-performance$' /etc/tuned/ppd.conf; then
  ok "Performance mode → tuned g14-performance"
else
  echo "!! /etc/tuned/ppd.conf has a non-standard performance= line. Replace it by hand with performance=g14-performance"
fi
if [[ $CHANGED -eq 1 ]]; then run systemctl restart tuned-ppd; fi

# Last: tuned reverts its own sysctls on a profile switch, so our values must be applied on top
if [[ $SYSCTL_CHANGED -eq 1 ]] || ! sysctl_live /etc/sysctl.d/90-g14-tuning.conf; then
  run sysctl --system -q
else
  ok "sysctl values are already live"
fi

# ---------------------------------------------------------------------------
log "3. H.264/HEVC hardware decoding (AV1/VP9 already work) + full ffmpeg"
# Affects RPM apps (Firefox, players); Flatpak apps use their own runtimes
if rpm -q rpmfusion-free-release &>/dev/null; then
  ok "RPM Fusion free is enabled"
else
  run dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
fi
pkgs --allowerasing mesa-va-drivers-freeworld mesa-va-drivers-freeworld.i686 libva-utils
if rpm -q ffmpeg-free &>/dev/null; then
  run dnf -y swap ffmpeg-free ffmpeg --allowerasing
else
  ok "ffmpeg-free is not installed (replaced by ffmpeg)"
fi
# Repos nothing is installed from: NVIDIA (no such GPU), Chrome (installed from Flatpak), PyCharm COPR
CHANGED=0
for r in rpmfusion-nonfree-nvidia-driver google-chrome copr:copr.fedorainfracloud.org:phracek:PyCharm; do
  if repo_on "$r"; then
    [[ $DRY -eq 1 ]] || echo "$r" >> "$BK/disabled-repos.txt"
    run dnf config-manager setopt "$r.enabled=0" || true
  fi
done
[[ $CHANGED -eq 1 ]] || ok "unneeded repos are disabled"

# ---------------------------------------------------------------------------
log "4. dnf: parallel downloads"
if grep -q '^max_parallel_downloads' /etc/dnf/dnf.conf; then
  ok "$(grep '^max_parallel_downloads' /etc/dnf/dnf.conf)"
else
  [[ $DRY -eq 1 ]] || cp -a /etc/dnf/dnf.conf "$BK/dnf.conf"
  run sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf
fi

# ---------------------------------------------------------------------------
log "5. Disable running but unneeded services"
SERVICES=(
  ModemManager                                       # no modem
  abrtd abrt-journal-core abrt-oops abrt-xorg        # crash reporting (CPU/RAM/disk)
  rsyslog                                            # duplicates journald, so logs are written twice
)
for s in "${SERVICES[@]}"; do
  if systemctl is-enabled "$s.service" &>/dev/null; then
    [[ $DRY -eq 1 ]] || echo "$s" >> "$BK/disabled-services.txt"
    run systemctl disable --now "$s.service" || true
  fi
done
[[ $CHANGED -eq 1 ]] || ok "services already disabled: ${SERVICES[*]}"

# ---------------------------------------------------------------------------
log "6. journald: 300 MiB limit"
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
log "7. Btrfs: noatime (fewer metadata writes on a DRAM-less NVMe)"
if grep -qE '\sbtrfs\s.*noatime' /etc/fstab; then
  ok "noatime is already in /etc/fstab"
else
  [[ $DRY -eq 1 ]] || cp -a /etc/fstab "$BK/fstab"
  run sed -i -E '/\sbtrfs\s/ s/(subvol=[a-z]+,compress=zstd:1)/\1,noatime/' /etc/fstab
  if [[ $DRY -eq 0 ]]; then
    if findmnt --verify --tab-file /etc/fstab >/dev/null; then
      systemctl daemon-reload
      mount -o remount,noatime /
      mount -o remount,noatime /home
    else
      echo "!! findmnt --verify failed, restoring fstab"; cp -a "$BK/fstab" /etc/fstab
    fi
  fi
fi

# ---------------------------------------------------------------------------
log "8. Kernel: nowatchdog — drop the lockup detector timers on all 16 threads"
# The sp5100_tco hardware watchdog stays: it is idle during normal work and protects against hangs during reboot
if karg_on nowatchdog; then
  ok "nowatchdog is already in the kernel arguments"
else
  run grubby --update-kernel=ALL --args="nowatchdog"
  [[ $DRY -eq 1 ]] || touch "$BK/added-nowatchdog"
  REBOOT=1
fi

# ---------------------------------------------------------------------------
if [[ $SCX -eq 1 ]]; then
  log "9. sched_ext: scx_lavd scheduler (interactivity + autopower on battery)"
  COPR_ID="copr:copr.fedorainfracloud.org:bieszczaders:kernel-cachyos-addons"
  if repo_on "$COPR_ID"; then ok "COPR kernel-cachyos-addons is enabled"; else run dnf -y copr enable bieszczaders/kernel-cachyos-addons; fi
  # Take only the schedulers from this COPR, so nothing else gets replaced
  if grep -qs '^includepkgs=scx-scheds,scx-tools$' /etc/dnf/repos.override.d/*.repo; then
    ok "COPR is limited to scx-scheds, scx-tools"
  else
    run dnf config-manager setopt "$COPR_ID.includepkgs=scx-scheds,scx-tools"
  fi
  pkgs scx-scheds scx-tools
  CHANGED=0
  put /etc/scx_loader.toml <<'EOF'
# scx_loader: which sched_ext scheduler to start at boot.
# Stop it and go back to the stock EEVDF:  sudo systemctl disable --now scx_loader
# Switch mode on the fly:                  scxctl switch -m gaming|powersave|auto
default_sched = "scx_lavd"
default_mode = "Auto"

[scheds.scx_lavd]
auto_mode = ["--autopower"]        # switches between performance/powersave by the power profile
gaming_mode = ["--performance"]
lowlatency_mode = ["--performance"]
powersave_mode = ["--powersave"]
server_mode = []
EOF
  if ! systemctl is-enabled -q scx_loader.service || ! systemctl is-active -q scx_loader.service; then
    run systemctl enable --now scx_loader.service
    [[ $DRY -eq 1 ]] || touch "$BK/enabled-scx"
  elif [[ $CHANGED -eq 1 ]]; then
    run systemctl restart scx_loader.service   # pick up the new config
  else
    ok "scx_loader is running: $(cat /sys/kernel/sched_ext/root/ops 2>/dev/null || echo '?')"
  fi
fi

# ---------------------------------------------------------------------------
if [[ $ASUS -eq 1 ]]; then
  log "10. asusctl: fan curves, keyboard backlight, panel overdrive"
  # The charge limit is left alone: GNOME manages it (Preserve Battery Health)
  if repo_on copr:copr.fedorainfracloud.org:lukenukem:asus-linux; then ok "COPR asus-linux is enabled"; else run dnf -y copr enable lukenukem/asus-linux; fi
  pkgs asusctl
  if systemctl is-enabled -q asusd && systemctl is-active -q asusd; then ok "asusd is running"; else run systemctl enable --now asusd; fi
  # supergfxctl is NOT installed on purpose: the dGPU already goes to D3cold correctly
fi

# ---------------------------------------------------------------------------
log "11. Wi-Fi: power save on battery, off on AC"
# If the connection profile has powersave=disable, NM applies it on every connect (including after sleep),
# so the helper is called both by udev (power source changed) and by the NM dispatcher (connected)
WPS=/usr/local/libexec/g14-wifi-powersave
WPS_NM=/etc/NetworkManager/dispatcher.d/90-g14-wifi-powersave
put "$WPS" < "$(dirname "${BASH_SOURCE[0]}")/g14-wifi-powersave"
put /etc/udev/rules.d/90-g14-wifi-powersave.rules <<EOF
# Charger plugged in or out: switch Wi-Fi power save
SUBSYSTEM=="power_supply", KERNEL=="AC0", ACTION=="change", RUN+="$WPS"
EOF
put "$WPS_NM" <<EOF
#!/bin/sh
# On every connect NM applies powersave from the connection profile: set it back to "on when on battery"
[ "\$2" = up ] && exec $WPS
exit 0
EOF
for f in "$WPS" "$WPS_NM"; do [[ -x "$f" ]] || run chmod 755 "$f"; done   # NM only runs executable files owned by root
if [[ $CHANGED -eq 1 ]]; then
  run udevadm control --reload
  run "$WPS"   # apply now, without waiting for a power source change
else
  ok "Wi-Fi power save follows the power source"
fi

# ---------------------------------------------------------------------------
if [[ $LEAN -eq 1 ]]; then
  log "12. --lean: no background updates, no file indexer, no Typing Booster"
  # gnome-software holds about 245 MB for the whole session (+ dnf5daemon-server about 126 MB) and downloads updates by itself.
  # Its autostart cannot be turned off without breaking the app window: the session and the menu start the same user service
  unpkgs gnome-software gnome-software-fedora-langpacks
  # Typing Booster: a predictive-text input method in Python (about 105 MB RSS), starts even with plain keyboard layouts.
  # --no-autoremove: its dependencies include the Noto Emoji and Symbola fonts, which other apps fall back to
  unpkgs --no-autoremove ibus-typing-booster
  if systemctl is-enabled -q dnf-makecache.timer; then
    [[ $DRY -eq 1 ]] || echo dnf-makecache.timer >> "$BK/disabled-services.txt"
    run systemctl disable --now dnf-makecache.timer
  else
    ok "dnf-makecache.timer is disabled"
  fi
  mask_user localsearch-3.service   # file indexer; without it Nautilus searches by file name
  if [[ $CHANGED -eq 1 ]]; then REBOOT=1; fi   # running instances live until you log out
fi

# ---------------------------------------------------------------------------
if [[ $NOCAL -eq 1 ]]; then
  log "13. --no-calendar: no calendar and contacts"
  unpkgs gnome-calendar gnome-contacts
  # Calendar and contacts data servers (evolution-data-server); GNOME Online Accounts is left alone
  mask_user evolution-alarm-notify.service evolution-source-registry.service \
            evolution-calendar-factory.service evolution-addressbook-factory.service
  if [[ $CHANGED -eq 1 ]]; then REBOOT=1; fi
fi

# ---------------------------------------------------------------------------
summary
if [[ $REBOOT -eq 1 ]]; then echo "Reboot: zram, kernel arguments and GNOME services take effect at boot and login."; fi
echo "Checks (zram and nowatchdog after a reboot):"
echo "  zramctl                                  # ALGORITHM zstd"
echo "  vainfo --display drm --device /dev/dri/by-path/pci-0000:07:00.0-render | grep -E 'H264|HEVC'"
echo "  sysctl net.ipv4.tcp_congestion_control   # bbr"
echo "  grep ^performance= /etc/tuned/ppd.conf   # performance=g14-performance"
echo "  cat /proc/sys/kernel/watchdog            # 0"
if [[ $SCX -eq 1 ]]; then echo "  cat /sys/kernel/sched_ext/root/ops       # lavd"; fi
echo "  iw dev wlp5s0 get power_save             # on on battery, off on AC"
if [[ $LEAN -eq 1 ]]; then
  echo "  rpm -q gnome-software ibus-typing-booster   # not installed"
  echo "  systemctl --global is-enabled localsearch-3.service   # masked"
fi
