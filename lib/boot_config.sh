#!/bin/bash
#
# boot_config.sh — Update extlinux.conf and fstab for the destination disk
#

source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"

configure_boot() {
    local dest="$1"
    local partitions efi_part root_part

    log_info "$(_t "msg_locating_partitions" "$dest")"
    partitions=$(lsblk -nr -o NAME -x NAME "$dest" | sed "s|^|/dev/|")

    efi_part=""
    root_part=""
    for part in $partitions; do
        local plabel ptype
        plabel=$(blkid -o value -s PARTLABEL "$part" 2>/dev/null || true)
        ptype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)

        if [[ "$plabel" == "esp" && "$ptype" == "vfat" ]]; then
            efi_part="$part"
        fi
        if [[ "$plabel" == "APP" && "$ptype" == "ext4" ]]; then
            root_part="$part"
        fi
    done

    if [[ -z "$root_part" ]]; then
        log_fatal "$(_t "msg_no_root_partition" "$dest")"
    fi
    if [[ -z "$efi_part" ]]; then
        log_fatal "$(_t "msg_no_efi_partition" "$dest")"
    fi

    log_success "Root: $root_part | EFI: $efi_part"

    # Prevent modifying current root
    local current_root
    current_root=$(findmnt -n -o SOURCE /)
    if [[ "$current_root" == "$root_part" ]]; then
        log_fatal "$(_t "msg_attempting_modify_root")"
    fi

    local mount_point="/mnt/ssd"
    mkdir -p "$mount_point"
    mount "$root_part" "$mount_point" || log_fatal "$(_t "msg_failed_mount_root" "$root_part")"

    local efi_uuid root_uuid
    efi_uuid=$(blkid -o value -s UUID "$efi_part") || {
        umount "$mount_point" 2>/dev/null || true
        log_fatal "$(_t "msg_failed_read_efi_uuid")"
    }
    root_uuid=$(blkid -o value -s UUID "$root_part") || {
        umount "$mount_point" 2>/dev/null || true
        log_fatal "$(_t "msg_failed_read_root_uuid")"
    }

    log_info "$(_t "msg_efi_uuid" "$efi_uuid")"
    log_info "$(_t "msg_root_uuid" "$root_uuid")"

    # Update extlinux.conf
    local extlinux_conf="$mount_point/boot/extlinux/extlinux.conf"
    if [[ ! -f "$extlinux_conf" ]]; then
        umount "$mount_point" 2>/dev/null || true
        log_fatal "$(_t "msg_extlinux_not_found" "$extlinux_conf")"
    fi

    cp -p "$extlinux_conf" "${extlinux_conf}.bak" || true
    sed "s|root=[^ ]*|root=UUID=${root_uuid}|" "$extlinux_conf" > "${extlinux_conf}.tmp" && mv "${extlinux_conf}.tmp" "$extlinux_conf" || {
        umount "$mount_point" 2>/dev/null || true
        log_fatal "$(_t "msg_failed_update_extlinux")"
    }
    log_success "$(_t "msg_updated_extlinux" "$root_uuid")"

    # Update fstab
    local fstab="$mount_point/etc/fstab"
    if [[ ! -f "$fstab" ]]; then
        umount "$mount_point" 2>/dev/null || true
        log_fatal "$(_t "msg_fstab_not_found" "$fstab")"
    fi

    cp -p "$fstab" "${fstab}.bak" || true
    sed "/\\/boot\\/efi / s|UUID=[^ ]*|UUID=${efi_uuid}|" "$fstab" > "${fstab}.tmp" && mv "${fstab}.tmp" "$fstab" || {
        umount "$mount_point" 2>/dev/null || true
        log_fatal "$(_t "msg_failed_update_fstab")"
    }
    log_success "$(_t "msg_updated_fstab" "$efi_uuid")"

    sync
    umount "$mount_point" 2>/dev/null || true
    rmdir "$mount_point" 2>/dev/null || true
}
