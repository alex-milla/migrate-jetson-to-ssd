#!/bin/bash
#
# partition_ops.sh — GPT clone, filesystem creation, UUID adjustment
#

source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
source "$(dirname "${BASH_SOURCE[0]}")/disk_utils.sh"

clone_partition_table() {
    local source="$1"
    local dest="$2"
    local backup_file="/tmp/jetson-migrate-gpt-backup.bak"

    log_info "$(_t "msg_erasing_partition_table" "$dest")"
    sgdisk --zap-all "$dest" || log_fatal "$(_t "msg_failed_zap" "$dest")"

    log_info "$(_t "msg_backing_up_gpt" "$source")"
    sgdisk --backup="$backup_file" "$source" || log_fatal "$(_t "msg_failed_backup_gpt" "$source")"

    log_info "$(_t "msg_restoring_gpt" "$dest")"
    sgdisk --load-backup="$backup_file" "$dest" || log_fatal "$(_t "msg_failed_restore_gpt" "$dest")"

    log_info "$(_t "msg_randomizing_guids" "$dest")"
    sgdisk --randomize-guids "$dest" || log_fatal "$(_t "msg_failed_randomize_guids")"

    sync

    log_info "$(_t "msg_reloading_partition_table")"
    partprobe "$dest" || blockdev --rereadpt "$dest" || log_fatal "$(_t "msg_failed_reread_partition_table")"
    udevadm settle

    # Backup path is known to caller; do not print to stdout
}

replicate_filesystems() {
    local source="$1"
    local dest="$2"

    log_info "$(_t "msg_creating_filesystems")"
    local part part_num source_part fstype
    for part in $(get_partitions "$dest"); do
        part_num=$(echo "$part" | grep -oE '[0-9]+$')
        source_part=$(build_part_name "$source" "$part_num")

        fstype=$(blkid -o value -s TYPE "$source_part" 2>/dev/null || true)
        log_info "$(_t "msg_partition_info" "$part" "$source_part" "${fstype:-none}")"

        if [[ -z "$fstype" ]]; then
            log_warn "$(_t "msg_no_filesystem_skip" "$source_part")"
            continue
        fi

        case "$fstype" in
            ext[234])
                mkfs.ext4 -F "$part" >/dev/null 2>&1 || log_error "$(_t "msg_failed_create_ext4" "$part")"
                ;;
            vfat|fat32)
                mkfs.vfat -F 32 "$part" >/dev/null 2>&1 || log_error "$(_t "msg_failed_create_fat32" "$part")"
                ;;
            swap)
                mkswap "$part" >/dev/null 2>&1 || log_error "$(_t "msg_failed_create_swap" "$part")"
                ;;
            *)
                log_warn "$(_t "msg_unsupported_fs" "$fstype" "$part")"
                ;;
        esac
    done

    sync
}

adjust_uuids() {
    local dest="$2"
    local source="$1"

    log_info "$(_t "msg_adjusting_uuids" "$dest")"
    local part part_num source_part fstype
    for part in $(get_partitions "$dest"); do
        part_num=$(echo "$part" | grep -oE '[0-9]+$')
        source_part=$(build_part_name "$source" "$part_num")
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)

        case "$fstype" in
            ext[234])
                e2fsck -f "$part" >/dev/null 2>&1 || true
                tune2fs -U random "$part" >/dev/null 2>&1 || log_error "$(_t "msg_failed_randomize_ext_uuid" "$part")"
                sync
                ;;
            swap)
                mkswap -U "$(uuidgen)" "$part" >/dev/null 2>&1 || log_error "$(_t "msg_failed_set_swap_uuid" "$part")"
                sync
                ;;
            vfat|fat32)
                local src_label src_partlabel
                src_label=$(blkid -o value -s LABEL "$source_part" 2>/dev/null || true)
                src_partlabel=$(blkid -o value -s PARTLABEL "$source_part" 2>/dev/null || true)

                [[ -n "$src_label" ]] && fatlabel "$part" "$src_label" >/dev/null 2>&1 || true
                [[ -n "$src_partlabel" ]] && sgdisk --change-name="${part_num}:${src_partlabel}" "$dest" >/dev/null 2>&1 || true

                sync
                partprobe "$dest"
                udevadm settle
                ;;
            *)
                : # nothing to do
                ;;
        esac
    done

    blockdev --rereadpt "$dest" || true
    udevadm settle
    sync
    log_success "$(_t "msg_uuid_adjustment_complete")"
}
