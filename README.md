# ASUS ROG Zephyrus G14 (2022) Linux tuning

Scripts that tune Linux for the **ASUS ROG Zephyrus G14 (2022)**, model **GA402RJ**.
Each distribution has its own folder. You can preview every change with `--dry-run` and undo it with `rollback.sh`.

## Target hardware

| Component  | Model |
|------------|-------|
| Laptop     | ASUS ROG Zephyrus G14 (2022), GA402RJ, BIOS GA402RJ.319 |
| CPU        | AMD Ryzen 9 6900HS (Zen 3+, 8 cores / 16 threads) |
| iGPU       | AMD Radeon 680M (RDNA 2) |
| dGPU       | AMD Radeon RX 6700S, 8 GB GDDR6 |
| RAM        | 16 GB |
| Storage    | Micron 2450 1 TB NVMe (DRAM-less) |
| Display    | 14" 2560×1600, 120 Hz |
| Wi-Fi / BT | MediaTek MT7922 |

Other GA402R variants (for example GA402RK with an RX 6800S, or a Ryzen 7 6800HS) use the same platform and will probably work, but nobody has tested them.
The 2020/2021 (GA401, Nvidia) and 2023+ G14 models are different hardware and are not supported.

## Distributions

| Folder | Distribution | Status |
|--------|--------------|--------|
| [fedora/](fedora/) | Fedora 44 Workstation (GNOME, kernel 7.3) | Tested |

## Quick start (Fedora)

```bash
sudo dnf upgrade --refresh && sudo reboot   # the script refuses to run with pending updates
cd fedora
sudo bash optimize.sh --dry-run             # show the plan, change nothing
sudo bash optimize.sh                       # apply
sudo bash optimize.sh --lean --no-calendar  # optional: no background updates, file indexer, calendar
sudo bash gaming.sh                         # optional: gaming tweaks (GameMode, packages, sysctl)
sudo reboot
```

Running a script again is safe: it skips steps that are already applied (marked `✓`) and prints only real changes.
[fedora/README.md](fedora/README.md) lists everything the scripts change and how to undo it.

## Disclaimer

The scripts run as root and change system configuration. Read the docs and do a `--dry-run` first.
Each run saves a backup to `/var/backups/`, but you use these scripts at your own risk.
