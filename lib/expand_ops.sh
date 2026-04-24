#!/bin/bash
#
# expand_ops.sh — Expand the APP (root) partition to fill available space
#

source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"

expand_root_partition() {
    local dest="$1"
    local root_part=""
    local part_num

    log_info "$(_t "msg_searching_app" "$dest")"
    for part in $(lsblk -nr -o NAME -x NAME "$dest" | sed "s|^|/dev/|"); do
        local plabel ptype
        plabel=$(blkid -o value -s PARTLABEL "$part" 2>/dev/null || true)
        ptype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
        if [[ "$plabel" == "APP" && "$ptype" == "ext4" ]]; then
            root_part="$part"
            part_num=$(echo "$part" | grep -oE '[0-9]+$')
            break
        fi
    done

    if [[ -z "$root_part" ]]; then
        log_fatal "$(_t "msg_app_not_found" "$dest")"
    fi

    log_info "$(_t "msg_app_partition" "$root_part")"

    # Unmount if mounted
    local mpoint
    mpoint=$(lsblk -ln -o MOUNTPOINT "$root_part" 2>/dev/null || true)
    if [[ -n "$mpoint" ]]; then
        log_info "$(_t "msg_unmounting_partition" "$root_part" "$mpoint")"
        umount "$root_part" || log_fatal "$(_t "msg_failed_unmount" "$root_part")"
    fi

    local start_sector last_sector current_end
    start_sector=$(sgdisk -i "$part_num" "$dest" | grep "First sector" | awk '{print $3}')
    last_sector=$(sgdisk -p "$dest" | grep "Last usable sector" | awk '{print $4}')
    current_end=$(sgdisk -i "$part_num" "$dest" | grep "Last sector" | awk '{print $3}')

    if [[ -z "$start_sector" || -z "$last_sector" || -z "$current_end" ]]; then
        log_error "$(_t "msg_reading_geometry")"
        return 1
    fi

    log_info "$(_t "msg_geometry_start" "$start_sector" "$current_end" "$last_sector")"

    if [[ "$current_end" -ge "$last_sector" ]]; then
        log_success "$(_t "msg_partition_already_max")"
        return 0
    fi

    local free_mb=$(( (last_sector - current_end) * 512 / 1024 / 1024 ))
    log_info "$(_t "msg_free_space_after" "$free_mb")"

    if ! confirm_yesno "$(_t "msg_resizing_with_sgdisk")"; then
        log_warn "$(_t "msg_expansion_skipped")"
        return 0
    fi

    log_info "$(_t "msg_resizing_with_sgdisk")"
    sgdisk -d "$part_num" -n "${part_num}:${start_sector}:${last_sector}" -c "${part_num}:APP" "$dest" || {
        log_error "$(_t "msg_sgdisk_resize_failed")"
        return 1
    }

    partprobe "$dest"
    blockdev --rereadpt "$dest"
    udevadm settle
    sync

    log_info "$(_t "msg_checking_fs")"
    e2fsck -f "$root_part" || log_warn "$(_t "msg_e2fsck_issues")"

    log_info "$(_t "msg_growing_fs")"
    resize2fs "$root_part" || {
        log_error "$(_t "msg_resize2fs_failed")"
        return 1
    }

    log_success "$(_t "msg_root_expanded")"
    lsblk -o NAME,SIZE "$root_part"
}
