# migrate-jetson-to-ssd

A safe, interactive migration assistant for NVIDIA Jetson Orin Nano / NX devices. Move your running system between **SD card**, **USB SSD**, and **M.2 NVMe SSD** without needing an external PC or SDK Manager.

Originally based on the video tutorial: https://youtu.be/497u-CcYvE8

**Key improvements in v2.0:**
- **Bilingual UI**: Choose **English** or **Español** at startup
- Single interactive assistant (`migrate.sh`) instead of multiple manual steps
- Automatic disk detection with type inference (SD / USB / NVMe)
- Exhaustive safety checks prevent accidental overwrites
- Supports any combination: SD → NVMe, USB → NVMe, NVMe → USB, etc.
- Optional root partition expansion when migrating to larger drives
- `--dry-run` mode to preview operations before executing them

**Notes (Updated Jan 30, 2025)** I've only tried this with drives that have the same sector size. There have been a couple reports of people experiencing issues. The common factor seems to be that they are using 32GB SD cards. I will be testing this, but be advised that the NVIDIA recommended minimum size for the Orin Nano is a SD card of 64GB.

The Jetson Orin Nano has two M.2 Key M slots, one is for a 80mm card (2280), one is for a 30mm card (2230). The other M.2 slot is for a wireless NIC. The 2280 slot is typically `/dev/nvme0n1`.

## Requirements
- NVIDIA Jetson Developer Kit with SSD capabilities (tested on JetPack 6)
- A running system on any bootable media (SD, USB, or M.2)
- Root privileges
- Destination drive must have equal or larger capacity than source
- Destination drive must not be mounted during migration
- Unformatted / clean destination drives work best

## Quick Start

Run the assistant interactively. You will be prompted to choose **English** or **Español** at startup:

```bash
cd migrate-jetson-to-ssd
chmod +x migrate.sh
sudo ./migrate.sh
```

Preview what would happen without making changes:

```bash
sudo ./migrate.sh --dry-run
```

The assistant will:
1. Ask for your language (**English / Español**)
2. Detect all connected drives and identify your current boot disk
3. Let you pick **Source** and **Destination** from a safe menu
4. Run pre-flight safety checks (size, mount status, etc.)
5. Clone partition structure and filesystems
6. Copy all partition data (raw partitions via `dd`, filesystems via `rsync`)
7. Optionally expand the root partition if destination is larger
8. Update `extlinux.conf` and `/etc/fstab` to boot from the new drive
9. Show a summary with next steps (reboot + UEFI boot order)

## Project Structure

```
.
├── migrate.sh              # Main interactive assistant (use this!)
├── lib/
│   ├── common.sh           # Colors, logging, UI helpers
│   ├── disk_utils.sh       # Drive detection, size/type queries
│   ├── safety.sh           # Pre-flight validations
│   ├── partition_ops.sh    # GPT clone, filesystem creation, UUIDs
│   ├── copy_ops.sh         # Data copy (rsync / dd)
│   ├── boot_config.sh      # extlinux.conf & fstab updates
│   └── expand_ops.sh       # Root partition expansion
├── legacy/                 # Original standalone scripts (preserved)
│   ├── make_partitions.sh
│   ├── copy_partitions.sh
│   ├── configure_ssd_boot.sh
│   └── ...
└── README.md
```

## Safety Features

- **Boot disk protection**: Your currently running system disk is automatically excluded from the destination list.
- **Mount check**: The assistant refuses to overwrite a drive that has mounted partitions.
- **Capacity guard**: Destination must be equal or larger than source.
- **Destructive confirmation**: If the destination already has partitions, you must type `DESTRUCT` to continue.
- **Dry-run mode**: `--dry-run` prints every command without executing anything.
- **Automatic cleanup**: Interrupting the script (`Ctrl+C`) safely unmounts any temporary mount points.
- **Full logging**: Every operation is logged to `/var/log/jetson-migrate-YYYYMMDD-HHMMSS.log`.

## Legacy Scripts

The original standalone scripts have been moved to `legacy/` and remain available for advanced users or automation pipelines. The new `migrate.sh` replaces them with a unified, safer workflow.

## Troubleshooting

**"Destination has mounted partitions"**
- Unmount the destination drive first:
  ```bash
  sudo umount /dev/nvme0n1p*
  ```

**"No root partition found"**
- Ensure your source drive has a standard Jetson partition layout with an `APP` partition.

**Boot order after migration**
- Reboot and press `ESC` repeatedly to enter the UEFI menu.
- Go to **Boot Manager** or **Boot Maintenance Manager**.
- Move your new SSD (SD / USB / NVMe) to the top of the boot order.
- Save and exit.

## License

This project is licensed under the MIT License.
