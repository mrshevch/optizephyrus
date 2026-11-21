#!/usr/bin/env bash
# Gaming tweaks for Fedora 44 on the ASUS ROG Zephyrus G14 (2022) GA402RJ
# (Ryzen 9 6900HS / RX 6700S + Radeon 680M / 14 GiB RAM)
#
# First:    sudo bash optimize.sh   (it sets up the g14-performance profile for Performance mode; this script checks)
# Usage:    sudo bash gaming.sh                    — packages, GameMode, sysctl
#           sudo bash gaming.sh --no-mitigations   — plus mitigations=off (faster syscalls, weaker protection against Spectre-class attacks)
#           sudo bash gaming.sh --dry-run          — only show what would be done
# Best together with optimize.sh --scx: scx_lavd --autopower switches to performance by itself when EPP = performance.
# In Steam: Game → Properties → Launch Options:  gamemoderun %command%
# A re-run only does what is not applied yet; applied steps are marked "✓".
# Rollback: sudo bash rollback.sh   (shared with optimize.sh)
set -euo pipefail

DRY=0; NOMIT=0
for a in "$@"; do
  case "$a" in
    --dry-run)        DRY=1 ;;
    --no-mitigations) NOMIT=1 ;;
    *) echo "Unknown flag: $a"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run it with sudo"; exit 1; }
U="${SUDO_USER:-}"
[[ -n "$U" && "$U" != root ]] || { echo "Run it with sudo from your own user: that user is added to the gamemode group"; exit 1; }

# GameMode hooks switch to Performance; without the g14-performance profile from optimize.sh that mode sets vm.swappiness=10
if ! grep -q '^performance=g14-performance$' /etc/tuned/ppd.conf; then
  echo "First run: sudo bash optimize.sh  (Performance mode without server sysctls)"
  [[ $DRY -eq 1 ]] || exit 1
fi

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $DRY -eq 1 ]] || { mkdir -p "$BK"; : > "$BK/created-files.txt"; }

# ---------------------------------------------------------------------------
log "1. Packages: 32-bit GameMode, MangoHud, gamescope"
# gamemode.i686: otherwise 32-bit games never turn GameMode on; mangohud: FPS/frame times; gamescope: FSR upscaling to 2560×1600
pkgs gamemode gamemode.i686 mangohud mangohud.i686 gamescope

# ---------------------------------------------------------------------------
log "2. GameMode: permissions, renice and automatic power profile switch"
# Without the gamemode group, polkit blocks the governor change and limits.d blocks nice -10: GameMode silently does nothing
if [[ " $(id -nG "$U") " == *" gamemode "* ]]; then
  ok "$U is already in the gamemode group"
else
  run usermod -aG gamemode "$U"
  [[ $DRY -eq 1 ]] || echo "$U" > "$BK/added-gamemode-group"
  REBOOT=1
fi
PPD='busctl --system set-property org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile s'
put /etc/gamemode.ini <<EOF
; Adds to /usr/share/gamemode/gamemode.ini (governor performance, ioprio and screensaver inhibit are already there)
[general]
; nice -10 for game processes (the most limits.d allows the gamemode group)
renice=10

[custom]
; Performance (tuned g14-performance) while a game runs; switches without a password, like the GNOME menu
start=$PPD performance
; shortcut: always back to balanced after a game, even if it was power-saver before; remember the previous profile if that gets in the way
end=$PPD balanced
EOF

# ---------------------------------------------------------------------------
log "3. sysctl: fewer background pauses in memory management (SteamOS values)"
put /etc/sysctl.d/91-g14-gaming.conf <<'EOF'
# Proactive compaction moves pages in the background → TLB shootdowns on every core → micro-stutter
vm.compaction_proactiveness = 0
# A waiting thread gets the page lock sooner → shorter latency spikes
vm.page_lock_unfairness = 1
EOF
if [[ $CHANGED -eq 1 ]] || ! sysctl_live /etc/sysctl.d/91-g14-gaming.conf; then
  run sysctl --system -q
else
  ok "sysctl values are already live"
fi

# ---------------------------------------------------------------------------
if [[ $NOMIT -eq 1 ]]; then
  log "4. Kernel: mitigations=off"
  # Zen 3+ runs SRSO Safe RET, STIBP always-on and TSA (VERW on every kernel exit), which hurt syscall-heavy Wine/Proton
  if karg_on mitigations=off; then
    ok "mitigations=off is already in the kernel arguments"
  else
    run grubby --update-kernel=ALL --args="mitigations=off"
    [[ $DRY -eq 1 ]] || touch "$BK/added-mitigations-off"
    REBOOT=1
  fi
fi

summary
if [[ $REBOOT -eq 1 ]]; then echo "Reboot: the gamemode group and nice limit apply at login, mitigations=off at boot."; fi
echo "In Steam → Game → Properties → Launch Options:  gamemoderun %command%   (with overlay: mangohud gamemoderun %command%)"
echo "Check while a game runs:"
echo "  gamemoded -s                                                    # gamemode is active"
echo "  cat /sys/firmware/acpi/platform_profile                         # performance"
echo "  cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference   # performance"
echo "  sysctl vm.swappiness                                            # 180, not 10"
if [[ $NOMIT -eq 1 ]]; then echo "  cat /sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow   # Vulnerable"; fi
