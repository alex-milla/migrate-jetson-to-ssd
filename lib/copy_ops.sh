#!/bin/bash
#
# copy_ops.sh — Copy partition contents via rsync or dd
#

source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
source "$(dirname "${BASH_SOURCE[0]}")/disk_utils.sh"

copy_partition_data() {
    local source="$1"
    local dest="$2"

    log_info "$(_t "msg_enumerating_partitions")"
    local source_parts dest_parts
    source_parts=$(get_partitions "$source")
    dest_parts=$(get_partitions "$dest")

    if [[ -z "$source_parts" || -z "$dest_parts" ]]; then
        log_fatal "$(_t "msg_failed_enumerate_partitions")"
    fi

    local source_part part_num dest_part src_fstype dest_fstype src_mount src_mpoint dest_mount

    for source_part in $source_parts; do
        part_num=$(echo "$source_part" | grep -oE '[0-9]+$')
        dest_part=$(build_part_name "$dest" "$part_num")

        if [[ ! -b "$dest_part" ]]; then
            log_warn "$(_t "msg_dest_partition_missing" "$dest_part")"
            continue
        fi

        src_fstype=$(blkid -o value -s TYPE "$source_part" 2>/dev/null || true)
        dest_fstype=$(blkid -o value -s TYPE "$dest_part" 2>/dev/null || true)

        # Raw partition copy
        if [[ -z "$src_fstype" ]]; then
            log_info "$(_t "msg_raw_copy" "$source_part" "$dest_part")"
            dd if="$source_part" of="$dest_part" bs=4M status=progress conv=fsync || {
                log_error "$(_t "msg_raw_copy_failed" "$source_part" "$dest_part")"
            }
            sync
            continue
        fi

        if [[ -z "$dest_fstype" ]]; then
            log_warn "$(_t "msg_dest_no_fs_skip" "$dest_part")"
            continue
        fi

        src_mpoint=$(lsblk -ln -o MOUNTPOINT "$source_part" 2>/dev/null || true)
        log_info "$(_t "msg_copying_partition" "$source_part" "$dest_part" "$src_fstype")"

        # Use existing mount if available
        if [[ -n "$src_mpoint" ]]; then
            src_mount="$src_mpoint"
        else
            src_mount="/mnt/source_${part_num}"
            mkdir -p "$src_mount"
            mount -o ro "$source_part" "$src_mount" || {
                log_error "$(_t "msg_failed_mount_source" "$source_part")"
                rmdir "$src_mount" 2>/dev/null || true
                continue
            }
        fi

        dest_mount="/mnt/destination_${part_num}"
        mkdir -p "$dest_mount"
        mount "$dest_part" "$dest_mount" || {
            log_error "$(_t "msg_failed_mount_dest" "$dest_part")"
            umount "$src_mount" 2>/dev/null || true
            rmdir "$src_mount" 2>/dev/null || true
            rmdir "$dest_mount" 2>/dev/null || true
            continue
        }

        # Determine copy strategy
        if [[ "$src_fstype" == "ext4" && "$src_mount" == "/" ]]; then
            log_info "$(_t "msg_root_fs_detected")"
            rsync -aAXh --info=progress2 \
                --exclude="/dev/" \
                --exclude="/proc/" \
                --exclude="/sys/" \
                --exclude="/run/" \
                --exclude="/tmp/" \
                --exclude="/mnt/" \
                --exclude="/media/" \
                --exclude="/var/tmp/" \
                --exclude="/lost+found/" \
                "$src_mount/" "$dest_mount/" || log_error "$(_t "msg_rsync_failed_rootfs")"
        elif [[ "$src_mount" == "/boot"* ]] || [[ "$(blkid -o value -s PARTLABEL "$source_part")" == "esp" ]]; then
            log_info "$(_t "msg_boot_partition_detected")"
            rsync -aAXh --info=progress2 "$src_mount/" "$dest_mount/" || log_error "$(_t "msg_rsync_failed_boot")"
        else
            log_info "$(_t "msg_standard_copy")"
            rsync -aAXh --info=progress2 "$src_mount/" "$dest_mount/" || log_error "$(_t "msg_rsync_failed_partition" "$source_part")"
        fi

        sync

        # Cleanup
        umount "$dest_mount" 2>/dev/null || true
        rmdir "$dest_mount" 2>/dev/null || true
        if [[ -z "$src_mpoint" ]]; then
            umount "$src_mount" 2>/dev/null || true
            rmdir "$src_mount" 2>/dev/null || true
        fi
    done

    sync
    blockdev --flushbufs "$dest"
    udevadm settle
    log_success "$(_t "msg_data_copy_complete")"
}
