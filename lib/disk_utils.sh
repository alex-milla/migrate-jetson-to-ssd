#!/bin/bash
#
# disk_utils.sh — Disk detection, size queries, type inference, mount checks
#

# Resolve the base block device for the current root filesystem
resolve_root_disk() {
    local root_dev
    root_dev=$(findmnt -n -o SOURCE /) || return 1
    # Strip partition suffix: /dev/mmcblk0p1 -> /dev/mmcblk0, /dev/sda1 -> /dev/sda, /dev/nvme0n1p1 -> /dev/nvme0n1
    if [[ "$root_dev" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$root_dev" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$root_dev" =~ ^(/dev/sd[a-z]+)[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$root_dev"
    fi
}

# List candidate block devices (excludes zram, loop, rom, and the current root disk)
list_candidate_disks() {
    local root_disk
    root_disk=$(resolve_root_disk)
    local name
    lsblk -d -n -o NAME | while read -r name; do
        local dev="/dev/$name"
        # Exclude non-disk types and special devices
        if [[ "$dev" == /dev/zram* ]] || [[ "$dev" == /dev/loop* ]] || [[ "$dev" == /dev/rom* ]]; then
            continue
        fi
        local dtype
        dtype=$(lsblk -d -n -o TYPE "$dev" 2>/dev/null || true)
        [[ "$dtype" != "disk" ]] && continue
        # Exclude current root disk
        if [[ "$dev" == "$root_disk" ]]; then
            continue
        fi
        echo "$dev"
    done
}

# Return size in bytes for a block device
get_disk_size() {
    local dev="$1"
    local name
    name=$(basename "$dev")
    if [[ -r "/sys/class/block/$name/size" ]]; then
        local sectors
        sectors=$(cat "/sys/class/block/$name/size")
        echo $((sectors * 512))
    else
        echo 0
    fi
}

# Convert bytes to human-readable (GiB)
get_human_size() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B --padding=7 "$bytes" 2>/dev/null || echo "${bytes} B"
    else
        local gb
        gb=$(awk "BEGIN {printf \"%.1f\", $bytes/1024/1024/1024}")
        echo "${gb} GiB"
    fi
}

# Infer disk type from device name and sysfs attributes
get_disk_type() {
    local dev="$1"
    local name
    name=$(basename "$dev")

    if [[ "$dev" == *"mmcblk"* ]]; then
        echo "SD/eMMC"
        return
    fi
    if [[ "$dev" == *"nvme"* ]]; then
        echo "NVMe (M.2)"
        return
    fi
    if [[ "$dev" == *"sd"* ]]; then
        # Distinguish USB vs SATA if possible
        local removable="0"
        if [[ -r "/sys/class/block/$name/removable" ]]; then
            removable=$(cat "/sys/class/block/$name/removable" 2>/dev/null || echo 0)
        fi
        local model=""
        if [[ -r "/sys/class/block/$name/device/model" ]]; then
            model=$(cat "/sys/class/block/$name/device/model" 2>/dev/null | tr -d ' ')
        fi
        # Many USB-SATA bridges report via usb subsystem
        if [[ -L "/sys/class/block/$name/device" ]]; then
            local devlink
            devlink=$(readlink -f "/sys/class/block/$name/device" 2>/dev/null || true)
            if [[ "$devlink" == *"usb"* ]]; then
                echo "USB"
                return
            fi
        fi
        if [[ "$removable" == "1" ]]; then
            echo "USB/Removable"
            return
        fi
        echo "SATA/USB"
        return
    fi
    echo "Unknown"
}

# Return model string for a device
get_disk_model() {
    local dev="$1"
    local name
    name=$(basename "$dev")
    local model=""
    if [[ -r "/sys/class/block/$name/device/model" ]]; then
        model=$(cat "/sys/class/block/$name/device/model" 2>/dev/null)
    fi
    if [[ -z "$model" ]]; then
        model=$(lsblk -d -n -o MODEL "$dev" 2>/dev/null || true)
    fi
    echo "$model"
}

# Check if any partition of the given disk is currently mounted
is_mounted() {
    local dev="$1"
    local parts
    parts=$(lsblk -ln -o NAME -p "$dev" | grep -E "${dev}p?[0-9]+$" || true)
    local part
    for part in $parts; do
        if findmnt -n -o SOURCE "$part" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# Check if the device itself is the current root disk
is_root_disk() {
    local dev="$1"
    local root_disk
    root_disk=$(resolve_root_disk)
    [[ "$dev" == "$root_disk" ]]
}

# Return partition device names for a given disk
get_partitions() {
    local dev="$1"
    lsblk -ln -o NAME -p "$dev" | grep -E "${dev}p?[0-9]+$" || true
}

# Count partitions on a device
partition_count() {
    local dev="$1"
    get_partitions "$dev" | wc -l
}

# Build partition device name correctly depending on disk naming scheme
# e.g. /dev/sda + 1 -> /dev/sda1
#      /dev/nvme0n1 + 1 -> /dev/nvme0n1p1
#      /dev/mmcblk0 + 1 -> /dev/mmcblk0p1
build_part_name() {
    local device="$1"
    local num="$2"
    if [[ "$device" == *"mmcblk"* || "$device" == *"nvme"* ]]; then
        echo "${device}p${num}"
    else
        echo "${device}${num}"
    fi
}

# Show a friendly one-line description of a disk
disk_summary() {
    local dev="$1"
    local size model dtype
    size=$(get_disk_size "$dev")
    model=$(get_disk_model "$dev")
    dtype=$(get_disk_type "$dev")
    printf "%s\t%s\t%s\t%s\n" "$dev" "$dtype" "$(get_human_size "$size")" "$model"
}
