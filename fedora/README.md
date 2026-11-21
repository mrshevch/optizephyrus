# Fedora

Tested on Fedora 44 Workstation (kernel 7.3, GNOME), installed with the default disk layout: LUKS2 with btrfs subvolumes `root` and `home` mounted with `compress=zstd:1`.

| File | Purpose |
|------|---------|
| `optimize.sh` | Applies the changes listed below |
| `rollback.sh` | Reverts them from the backups |

## Usage

```bash
# 1. Update the system first. optimize.sh refuses to run while updates are pending.
sudo dnf upgrade --refresh && sudo reboot

# 2. Preview the plan without changing anything
sudo bash optimize.sh --dry-run --scx

# 3. Apply
sudo bash optimize.sh --scx

# 4. Reboot (needed for zram and the kernel argument)
sudo reboot
```

| Flag | Effect |
|------|--------|
| *(none)* | Base set, sections 1–8 |
| `--scx` | Also installs the `scx_lavd` scheduler (section 9) |
| `--asus` | Also installs `asusctl` (section 10) |
| `--dry-run` | Prints every command and file it would run or write, and changes nothing |

You can combine the flags. You can also add one later by running the script again, for example `sudo bash optimize.sh --scx --asus`. Every run applies the base set again, which is safe because it is idempotent.

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
- **Change:** `SystemMaxUse=300M`, `RuntimeMaxUse=64M`. Then journald is restarted and `journalctl --vacuum-size=300M` runs.
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
- **Service:** enables and starts `scx_loader.service`.
- **Control:** `scxctl switch -m gaming|powersave|auto`. To go back to the stock EEVDF scheduler right away, run `sudo systemctl disable --now scx_loader`.

### 10. `--asus`: asusctl

- **Repo:** COPR `lukenukem/asus-linux`
- **Installs:** `asusctl`. Enables `asusd`.
- **Gives you:** fan curves, keyboard backlight control and panel overdrive.

### Left out on purpose

- **supergfxctl:** without it, the RX 6700S already powers off fully (runtime PM, D3cold) when nothing uses it.
- **Battery charge limit:** GNOME already handles it (*Settings → Power → Preserve Battery Health*).
- **`sp5100_tco` hardware watchdog:** see section 8.

## Backups

Each run (except `--dry-run`) creates `/var/backups/os-tune-YYYYmmdd-HHMMSS/` with:

| Entry | Contents |
|-------|----------|
| `<original path>` | Copy of every file that was overwritten, for example `etc/sysctl.d/...` |
| `created-files.txt` | Every file the run wrote |
| `disabled-services.txt` | Services the run disabled |
| `disabled-repos.txt` | Repos the run disabled |
| `fstab`, `dnf.conf` | Originals before editing |
| `added-nowatchdog`, `enabled-scx` | Markers for kernel-argument and scx changes |

## Rollback

```bash
sudo bash rollback.sh && sudo reboot
```

`rollback.sh` goes through all `/var/backups/os-tune-*` directories from newest to oldest, so you end up with the state from before the first run. It:

- restores overwritten files and deletes files the scripts created;
- restores `/etc/fstab` and `/etc/dnf/dnf.conf`;
- re-enables the services and repos the scripts disabled;
- disables `scx_loader`;
- removes the `nowatchdog` kernel argument.

It does **not**:

- uninstall packages (RPM Fusion, `mesa-va-drivers-freeworld`, `ffmpeg`, `scx-scheds`, `asusctl`) or swap `ffmpeg` back to `ffmpeg-free`;
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
```

`pci-0000:07:00.0` is the Radeon 680M iGPU on the GA402R.
