# Fedora

Tested on Fedora 44 Workstation (kernel 7.3, GNOME), installed with the default disk layout: LUKS2 with btrfs subvolumes `root` and `home` mounted with `compress=zstd:1`.

| File | Purpose |
|------|---------|
| `optimize.sh` | Applies the base changes listed below |
| `gaming.sh` | Applies the gaming changes ([section](#what-gamingsh-changes)) |
| `rollback.sh` | Reverts both from the backups |
| `lib.sh` | Shared helpers for `optimize.sh` and `gaming.sh` |
| `g14-wifi-powersave` | Wi-Fi power save helper that `optimize.sh` installs ([section 11](#11-wi-fi-power-save-on-battery)) |
| `test-lib.sh` | Self-test for `lib.sh` and `g14-wifi-powersave`, runs without root: `bash test-lib.sh` |

## Usage

```bash
# 1. Update the system first. optimize.sh refuses to run while updates are pending.
sudo dnf upgrade --refresh && sudo reboot

# 2. Preview the plan without changing anything
sudo bash optimize.sh --dry-run --scx

# 3. Apply
sudo bash optimize.sh --scx

# 4. Gaming tweaks (optional): preview, then apply
sudo bash gaming.sh --dry-run
sudo bash gaming.sh

# 5. Reboot (needed for zram, kernel arguments and the gamemode group)
sudo reboot
```

| Flag | Effect |
|------|--------|
| *(none)* | Base set, sections 1–8 and 11 |
| `--scx` | Also installs the `scx_lavd` scheduler (section 9) |
| `--asus` | Also installs `asusctl` (section 10) |
| `--lean` | Also removes GNOME Software, disables `dnf-makecache.timer` and the file indexer (section 12) |
| `--no-calendar` | Also removes GNOME Calendar and Contacts and masks evolution-data-server (section 13) |
| `--dry-run` | Prints every command and file it would run or write, and changes nothing |

You can combine the flags. You can also add one later by running the script again, for example `sudo bash optimize.sh --scx --asus`.

**Re-runs.** Each step first checks whether it is already applied. In the output:

- `✓` — already applied, nothing is run;
- `+` — a command that runs, or a new file with its full content;
- `~` — an existing file that changes, shown as a diff.

Services restart only when their config changed. `sysctl --system` runs only when a live value differs from the file. A run with nothing to change prints *"Всё уже применено — изменений нет"* and removes its empty backup directory. `gaming.sh` behaves the same way.

**Update check.** The H.264/HEVC driver from RPM Fusion has to match the Mesa version in Fedora `updates`. If `dnf check-upgrade` reports pending updates, the script stops. In `--dry-run` it only prints a warning.

## What `optimize.sh` changes

### 1. zram: size = RAM, zstd

- **File:** `/etc/systemd/zram-generator.conf`
- **Change:** `zram-size = ram`, `compression-algorithm = zstd`.
- **Why:** Fedora limits zram to `min(ram, 8192)` MiB. zstd usually compresses about 3:1, so a zram device as big as RAM gives roughly 25+ GiB of usable memory on a 16 GB machine.
- **Takes effect:** after a reboot.

### 2. sysctl: memory, desktop and network

- **Files:** `/etc/sysctl.d/90-g14-tuning.conf`, `/etc/modules-load.d/bbr.conf` (loads `tcp_bbr` at boot)
- **Takes effect:** immediately (`sysctl --system`).

| Key | Value | Why |
|-----|-------|-----|
| `vm.swappiness` | 180 | Swap lives only in zram (RAM), so swapping out is cheap and preferred to dropping file cache |
| `vm.page-cluster` | 0 | Read one page from zram at a time. Readahead does not help on compressed RAM |
| `vm.watermark_boost_factor` | 0 | Stops bursts of reclaim after memory fragmentation events |
| `vm.watermark_scale_factor` | 125 | kswapd starts reclaiming earlier, so allocations stall less |
| `vm.vfs_cache_pressure` | 50 | Keeps dentry and inode caches longer |
| `vm.dirty_bytes` | 256 MiB | Limits dirty page cache in bytes, not percent, to avoid freezes when copying large files |
| `vm.dirty_background_bytes` | 64 MiB | Starts background writeback earlier |
| `fs.inotify.max_user_watches` | 524288 | File watchers in IDEs and Node.js tools |
| `fs.inotify.max_user_instances` | 1024 | Same reason |
| `net.core.default_qdisc` | `fq` | Required for BBR pacing |
| `net.ipv4.tcp_congestion_control` | `bbr` | Better upload throughput on lossy Wi-Fi than `cubic` |
| `net.ipv4.tcp_mtu_probing` | 1 | Recovers from PMTU black holes |

**GNOME *Performance* mode no longer undoes these values.**

- **Files:** `/etc/tuned/profiles/g14-performance/tuned.conf`. In `/etc/tuned/ppd.conf`, the line `performance=throughput-performance` becomes `performance=g14-performance`. `tuned-ppd` is restarted if either of them changed.
- **Why:** *Performance* maps to tuned's server profile `throughput-performance`. That profile sets `vm.swappiness=10` and dirty limits of 40 %/10 %, which overrides the zram and writeback values above every time you pick *Performance*.
- **The new profile** keeps the parts that make *Performance* faster: governor `performance`, EPP `performance`, boost on, `platform_profile=performance` (ASUS *Performance* thermal policy: higher CPU/dGPU power limits and fan speeds), panel power savings off.
- **Takes effect:** immediately.

### 3. H.264/HEVC hardware decoding and full ffmpeg

- **Installs:** the RPM Fusion *free* release package (if missing), `mesa-va-drivers-freeworld` and its i686 build, and `libva-utils`.
- **Swaps:** `ffmpeg-free` → `ffmpeg` (`--allowerasing`).
- **Why:** Fedora's Mesa has H.264 and HEVC decoding disabled for patent reasons. AV1 and VP9 already work. This affects RPM apps such as Firefox and mpv. Flatpak apps use the codecs of their own runtime.
- **Disables these repos if they are enabled:** `rpmfusion-nonfree-nvidia-driver`, `google-chrome`, `copr:copr.fedorainfracloud.org:phracek:PyCharm`. They only slow down `dnf` metadata refreshes on this machine: the laptop has no Nvidia GPU, and the author installs Chrome and PyCharm from Flathub.

> **Warning:** the repos are disabled without checking whether you installed anything from them. If you use Google Chrome or PyCharm as RPMs, remove them from the `for r in ...` line first. Otherwise they stop getting updates.

### 4. dnf: parallel downloads

- **File:** `/etc/dnf/dnf.conf`
- **Change:** adds `max_parallel_downloads=10` under `[main]` if the option is not set.

### 5. Disable unneeded services

These are disabled and stopped, but only if they are enabled:

| Service | Reason |
|---------|--------|
| `ModemManager` | The laptop has no WWAN modem |
| `abrtd`, `abrt-journal-core`, `abrt-oops`, `abrt-xorg` | Crash reporting. Costs CPU, RAM and disk when apps crash. You will no longer get crash reports |
| `rsyslog` | Duplicates journald, so every log line is written twice |

### 6. journald size limit

- **File:** `/etc/systemd/journald.conf.d/90-size.conf`
- **Change:** `SystemMaxUse=300M`, `RuntimeMaxUse=64M`. If the file changed, journald is restarted and `journalctl --vacuum-size=300M` runs.
- **Note:** logs older than the 300 MB limit are deleted right away. Rollback cannot bring them back.

### 7. btrfs `noatime`

- **File:** `/etc/fstab`
- **Change:** on btrfs lines, `subvol=<name>,compress=zstd:1` becomes `subvol=<name>,compress=zstd:1,noatime`. The script checks the result with `findmnt --verify`. If the check fails, it restores the original fstab. Then it remounts `/` and `/home` live.
- **Why:** reading a file no longer writes access-time metadata. On btrfs every such write is a copy-on-write of metadata, which is extra wear on a DRAM-less NVMe drive.
- **Note:** if your fstab does not use Fedora's default format, the sed leaves it unchanged.

### 8. Kernel argument `nowatchdog`

- **Command:** `grubby --update-kernel=ALL --args="nowatchdog"`
- **Why:** turns off the soft and hard lockup detectors. Their timers run on all 16 threads and wake idle cores. The hardware watchdog `sp5100_tco` is left on: it is idle during normal work and protects against hangs during reboot.
- **Takes effect:** after a reboot.

### 9. `--scx`: sched_ext scheduler `scx_lavd`

- **Repo:** COPR `bieszczaders/kernel-cachyos-addons`, limited with `includepkgs=scx-scheds,scx-tools`. Nothing else, such as a kernel, can come from it.
- **Installs:** `scx-scheds`, `scx-tools`.
- **File:** `/etc/scx_loader.toml`. The default scheduler is `scx_lavd` in `Auto` mode with `--autopower`, so it follows the current power profile on its own.
- **Service:** enables and starts `scx_loader.service`, or restarts it if `/etc/scx_loader.toml` changed.
- **Control:** `scxctl switch -m gaming|powersave|auto`. To go back to the stock EEVDF scheduler right away, run `sudo systemctl disable --now scx_loader`.

### 10. `--asus`: asusctl

- **Repo:** COPR `lukenukem/asus-linux`
- **Installs:** `asusctl`. Enables `asusd`.
- **Gives you:** fan curves, keyboard backlight control and panel overdrive.

### 11. Wi-Fi power save on battery

- **Files:** `/usr/local/libexec/g14-wifi-powersave` (copy of [`g14-wifi-powersave`](g14-wifi-powersave)), `/etc/udev/rules.d/90-g14-wifi-powersave.rules`, `/etc/NetworkManager/dispatcher.d/90-g14-wifi-powersave`.
- **Change:** on battery the helper turns Wi-Fi power save on for every wireless interface. On AC it turns it off, as before. The udev rule runs it when the charger is plugged in or out. The NetworkManager dispatcher runs it after every connection.
- **Why:** the connection profile has `802-11-wireless.powersave=disable`, and NetworkManager applies it on every connect, including after sleep. Without the dispatcher hook, the first lid close on battery would turn power save off again. On battery, charge matters more than Wi-Fi latency.
- **Takes effect:** immediately.
- **Limit:** online games on battery also run with power save on, so ping can spike. Plug in the charger for online games.

### 12. `--lean`: no background updates, no file indexer

For people who update by hand and never search file contents.

| What | Change | Why |
|------|--------|-----|
| GNOME Software | Removes `gnome-software` and `gnome-software-fedora-langpacks` | It runs for the whole session (about 245 MB RSS, plus about 126 MB for the `dnf5daemon-server` it starts) and downloads updates in the background. Its autostart cannot be turned off without breaking the app window: the session and the app menu start the same user service |
| `dnf-makecache.timer` | Disabled | Refreshes dnf metadata in the background. `dnf upgrade --refresh` does it anyway |
| localsearch (file indexer) | `systemctl --global mask localsearch-3.service` | Crawls and indexes your files. Without it, Nautilus searches by file name only |

- **Updates from now on:** `sudo dnf upgrade --refresh` and `flatpak update`.
- **Takes effect:** after you log in again. Processes that are already running keep running until then.

### 13. `--no-calendar`: no calendar and contacts

For people who do not use GNOME Calendar or Contacts on this machine.

- **Removes:** `gnome-calendar`, `gnome-contacts`.
- **Masks** (`systemctl --global mask`): `evolution-alarm-notify`, `evolution-source-registry`, `evolution-calendar-factory`, `evolution-addressbook-factory`. Together with Calendar they use about 260 MB RSS.
- **Result:** the clock menu shows no events. GNOME Online Accounts is left alone.
- **Takes effect:** after you log in again.

### Left out on purpose

- **supergfxctl:** without it, the RX 6700S already powers off fully (runtime PM, D3cold) when nothing uses it.
- **Battery charge limit:** GNOME already handles it (*Settings → Power → Preserve Battery Health*).
- **`sp5100_tco` hardware watchdog:** see section 8.
- **initramfs without amdgpu:** amdgpu is 31 of 145 MB of the unpacked image (21 %). Too little to be worth a different boot path.
- **GRUB timeout:** the menu is already hidden (`menu_auto_hide=1`). The rest of the 4.7 s loader time is reading the kernel and initramfs through UEFI.
- **PCIe ASPM `powersupersave`:** the OS controls ASPM, and the BIOS already enables L1.1 and L1.2 on the Wi-Fi card and the NVMe drive. There is nothing left to gain.
- **Runtime PM for the O2 Micro card reader:** the `sdhci-pci` driver leaves it off on purpose. Forcing it on can make the reader miss an inserted card.
- **Services that never start on this hardware** (`thermald`, `intel_lpmd`, VM guest agents, iSCSI, `livesys`): their start conditions are not met, so disabling them saves nothing.
- **TPM2 unlock for LUKS:** most of the initrd time is typing the passphrase, but TPM2 unlock is a security decision, not a speed tweak.

## What `gaming.sh` changes

Run `optimize.sh` first. GameMode switches to *Performance* while a game runs, and without the `g14-performance` profile from [section 2](#2-sysctl-memory-desktop-and-network) that mode sets `vm.swappiness=10`. `gaming.sh` checks this and stops if the profile is missing. With `--scx`, `scx_lavd --autopower` follows the CPU energy preference, so it switches itself to performance mode when a game starts.

| Flag | Effect |
|------|--------|
| *(none)* | Sections 1–3 |
| `--no-mitigations` | Also adds the `mitigations=off` kernel argument (section 4) |
| `--dry-run` | Prints every command and file, changes nothing |

### 1. Packages

`gamemode.i686`, `mangohud` + `.i686`, `gamescope`. Without the 32-bit GameMode library, 32-bit games never turn GameMode on. MangoHud shows FPS and frame times. gamescope gives FSR upscaling (see [Steam launch options](#steam-launch-options)).

### 2. GameMode

- **Group:** adds you (`$SUDO_USER`) to `gamemode`. Without it, polkit blocks GameMode's governor helper and `limits.d` blocks the nice change, so GameMode silently does nothing.
- **File:** `/etc/gamemode.ini`, on top of the defaults in `/usr/share/gamemode/gamemode.ini`:
  - `renice=10`: the game runs at nice −10, the most the `gamemode` group may use.
  - `start`/`end` hooks: switch the power profile to *Performance* (`g14-performance`) while a game runs, and back to *Balanced* after it. They use the same D-Bus call as GNOME's menu, so no password is needed.
- **Limit:** after a game the profile always goes back to *Balanced*, even if you were on *Power Saver* before.

### 3. sysctl (SteamOS values)

- **File:** `/etc/sysctl.d/91-g14-gaming.conf`

| Key | Value | Why |
|-----|-------|-----|
| `vm.compaction_proactiveness` | 0 | Background compaction moves pages around and causes TLB shootdowns on every core, which shows up as micro-stutter |
| `vm.page_lock_unfairness` | 1 | A waiting thread gets the page lock sooner, which shortens latency spikes |

### 4. `--no-mitigations`: kernel argument `mitigations=off`

- **Why:** on this CPU the kernel runs SRSO *Safe RET*, STIBP *always-on* and the TSA buffer clear on every return from the kernel. Wine/Proton makes many system calls, so it pays for these more than native apps do.
- **Cost:** no protection against Spectre-class attacks from local code (other users, malicious programs). Use it only on a single-user machine.
- **Check:** `cat /sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow` prints `Vulnerable`.

### Steam launch options

*Game → Properties → Launch Options:*

```
gamemoderun %command%                                                   # GameMode
mangohud gamemoderun %command%                                          # plus FPS overlay
gamescope -W 2560 -H 1600 -w 1920 -h 1200 -F fsr -f -- gamemoderun %command%   # render at 1920×1200, FSR upscale
```

`steam.desktop` already has `PrefersNonDefaultGPU=true`, so GNOME starts Steam and its games on the RX 6700S.

### Manual switches

- **120 Hz and VRR.** The panel supports 2560×1600 at 120 Hz with variable refresh rate. Turn both on in *Settings → Displays → Refresh Rate*. At 60 Hz you never see more than 60 FPS.
- **MUX (dGPU only).** The RX 6700S drives the internal panel directly, with no copy through the iGPU. This gives more FPS in CPU-bound games but uses much more battery. Not tested by these scripts.
  ```bash
  echo 0 | sudo tee /sys/class/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/current_value && sudo reboot   # dGPU only
  echo 1 | sudo tee /sys/class/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/current_value && sudo reboot   # back to hybrid
  ```

### Left out on purpose

| What | Why not |
|------|---------|
| Custom kernel (CachyOS etc.) | The Fedora 7.3 kernel already has what games use: sched_ext (`scx_lavd`), NTSYNC (`/dev/ntsync`, loaded at boot, Proton picks it up automatically), a 1000 Hz tick and `amd-pstate-epp`. An `-O3`/x86-64-v3 build adds little, and an out-of-tree kernel complicates Fedora updates and SELinux |
| `preempt=full` | `scx_lavd` preempts right away anyway. The default `lazy` mode only affects the stock EEVDF scheduler |
| `power_dpm_force_performance_level=high`, C-state limits | On a laptop the CPU and GPU share one power and cooling budget. Pinned clocks and awake idle cores take boost headroom away from the cores doing the work |
| amdgpu overdrive / undervolting | Needs calibration on each chip by hand (`amdgpu.ppfeaturemask` + LACT) |
| Wi-Fi power save | Already off on this machine |

## Backups

Each run that changes something (not `--dry-run`) creates `/var/backups/os-tune-YYYYmmdd-HHMMSS/` with:

| Entry | Contents |
|-------|----------|
| `<original path>` | Copy of every file that was overwritten, for example `etc/sysctl.d/...` |
| `created-files.txt` | Every file the run wrote |
| `disabled-services.txt` | Services and timers the run disabled |
| `disabled-repos.txt` | Repos the run disabled |
| `fstab`, `dnf.conf`, `ppd.conf` | Originals before editing |
| `added-nowatchdog`, `added-mitigations-off`, `enabled-scx` | Markers for kernel-argument and scx changes |
| `added-gamemode-group` | The user added to the `gamemode` group |
| `removed-packages.txt` | Packages the run removed (`--lean`, `--no-calendar`) |
| `masked-user-units.txt` | User units the run masked with `systemctl --global mask` |

## Rollback

```bash
sudo bash rollback.sh && sudo reboot
```

`rollback.sh` goes through all `/var/backups/os-tune-*` directories (from both `optimize.sh` and `gaming.sh`) from newest to oldest, so you end up with the state from before the first run. It:

- restores overwritten files and deletes files the scripts created;
- restores `/etc/fstab`, `/etc/dnf/dnf.conf` and `/etc/tuned/ppd.conf`;
- re-enables the services, timers and repos the scripts disabled;
- reinstalls the packages the scripts removed (needs network);
- unmasks the user units the scripts masked;
- reloads udev rules, so the Wi-Fi rule stops working once its file is deleted;
- disables `scx_loader`;
- removes the `nowatchdog` and `mitigations=off` kernel arguments;
- removes the user from the `gamemode` group.

It does **not**:

- uninstall packages the scripts installed (RPM Fusion, `mesa-va-drivers-freeworld`, `ffmpeg`, `scx-scheds`, `asusctl`, `gamemode.i686`, `mangohud`, `gamescope`) or swap `ffmpeg` back to `ffmpeg-free`;
- disable the COPR repos or the `asusd` service;
- restore journal entries that the vacuum deleted;
- delete the backup directories.

## Checking the result after reboot

```bash
zramctl                                  # ALGORITHM zstd, DISKSIZE ≈ RAM
vainfo --display drm --device /dev/dri/by-path/pci-0000:07:00.0-render | grep -E 'H264|HEVC'
sysctl net.ipv4.tcp_congestion_control   # bbr
cat /proc/sys/kernel/watchdog            # 0
findmnt -no OPTIONS /                    # contains noatime
cat /sys/kernel/sched_ext/root/ops       # lavd (with --scx)
grep ^performance= /etc/tuned/ppd.conf   # performance=g14-performance
iw dev wlp5s0 get power_save             # on on battery, off on AC
rpm -q gnome-software                    # not installed (--lean)
systemctl --global is-enabled localsearch-3.service   # masked (--lean)
pgrep -l 'evolution|gnome-calendar'      # nothing (--no-calendar)

# power draw on battery, idle, 60 s average
for i in $(seq 60); do cat /sys/class/power_supply/BAT0/power_now; sleep 1; done | awk '{s+=$1} END {printf "%.2f W\n", s/NR/1e6}'
sysctl vm.compaction_proactiveness       # 0 (gaming.sh)

# while a game runs with gamemoderun:
gamemoded -s                             # gamemode is active
cat /sys/firmware/acpi/platform_profile  # performance
sysctl vm.swappiness                     # still 180, not 10
```

`pci-0000:07:00.0` is the Radeon 680M iGPU on the GA402R.
