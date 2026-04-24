#!/bin/bash

# Script to expand the APP (root) partition on the M.2 SSD to fill available space.
# Run this AFTER copy_partitions_usb_to_m2.sh and BEFORE rebooting.
# Or run it after make_partitions.sh if you want to expand before copying data.

# Function to print usage and exit
usage() {
  echo "Usage: $(basename "$0") [OPTIONS]"
  echo
  echo "Expand the APP (root) partition to use all available space on the M.2 SSD."
  echo
  echo "Options:"
  echo "  -d, --destination <device>  Destination disk (default: /dev/nvme0n1)"
  echo "  -h, --help                 Show this help message and exit"
  echo
  exit 1
}

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

# Parse command-line arguments
DESTINATION="/dev/nvme0n1"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--destination)
      DESTINATION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# Find APP partition
ROOT_PART=""
for PART in $(lsblk -nr -o NAME -x NAME "$DESTINATION" | sed "s|^|/dev/|"); do
  if [[ "$(blkid -o value -s PARTLABEL "$PART" 2>/dev/null)" == "APP" ]] &&
     [[ "$(blkid -o value -s TYPE "$PART" 2>/dev/null)" == "ext4" ]]; then
    ROOT_PART="$PART"
    break
  fi
done

if [[ -z "$ROOT_PART" ]]; then
  echo "Error: No root (APP) partition found on $DESTINATION." >&2
  exit 1
fi

echo "Detected root partition: $ROOT_PART"

# Get partition number
PART_NUM=$(echo "$ROOT_PART" | grep -oE '[0-9]+$')

# Check if partition is mounted and unmount it
MOUNTPOINT=$(lsblk -ln -o MOUNTPOINT "$ROOT_PART")
if [[ -n "$MOUNTPOINT" ]]; then
  echo "Unmounting $ROOT_PART from $MOUNTPOINT..."
  umount "$ROOT_PART" || {
    echo "Error: Failed to unmount $ROOT_PART. Please unmount manually and try again." >&2
    exit 1
  }
fi

# Get current start sector and size info
echo "Analyzing partition layout..."
START_SECTOR=$(sgdisk -i "$PART_NUM" "$DESTINATION" | grep "First sector" | awk '{print $3}')
if [[ -z "$START_SECTOR" ]]; then
  echo "Error: Could not determine start sector of partition $PART_NUM." >&2
  exit 1
fi

echo "Current start sector of APP partition: $START_SECTOR"

# Get last usable sector on disk
LAST_SECTOR=$(sgdisk -p "$DESTINATION" | grep "Last usable sector" | awk '{print $4}')
if [[ -z "$LAST_SECTOR" ]]; then
  echo "Error: Could not determine last usable sector of $DESTINATION." >&2
  exit 1
fi

echo "Last usable sector on disk: $LAST_SECTOR"

# Check if partition can be expanded (i.e., there is free space after it)
CURRENT_END=$(sgdisk -i "$PART_NUM" "$DESTINATION" | grep "Last sector" | awk '{print $3}')
echo "Current end sector of APP partition: $CURRENT_END"

if [[ "$CURRENT_END" -ge "$LAST_SECTOR" ]]; then
  echo "Partition is already at maximum size. Nothing to do."
  exit 0
fi

FREE_SECTORS=$((LAST_SECTOR - CURRENT_END))
FREE_MB=$((FREE_SECTORS * 512 / 1024 / 1024))
echo "Free space after APP partition: ~${FREE_MB} MB"

read -p "Are you sure you want to expand $ROOT_PART to fill all available space? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Operation cancelled."
  exit 1
fi

# Delete and recreate the partition with the same start but new end
echo "Expanding partition $PART_NUM to end of disk..."
sgdisk -d "$PART_NUM" -n "${PART_NUM}:${START_SECTOR}:${LAST_SECTOR}" -c "${PART_NUM}:APP" "$DESTINATION" || {
  echo "Error: Failed to resize partition." >&2
  exit 1
}

echo "Reloading partition table..."
partprobe "$DESTINATION"
blockdev --rereadpt "$DESTINATION"
udevadm settle
sync

echo "Checking filesystem..."
e2fsck -f "$ROOT_PART" || {
  echo "Warning: e2fsck reported errors. Attempting to continue..."
}

echo "Resizing filesystem to fill partition..."
resize2fs "$ROOT_PART" || {
  echo "Error: Failed to resize filesystem." >&2
  exit 1
}

echo "Filesystem expanded successfully."
echo "New size:"
lsblk -o NAME,SIZE "$ROOT_PART"

echo "Done. You can now reboot from the M.2 SSD."
