#!/bin/bash
#
# safety.sh — Pre-flight validations and risk warnings
#

source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
source "$(dirname "${BASH_SOURCE[0]}")/disk_utils.sh"

# Validate a candidate migration pair. Returns 0 if safe, 1 otherwise.
validate_migration() {
    local source="$1"
    local dest="$2"
    local errors=0

    section_title "$(_t "title_safety_checks")"

    # 1. Existence
    if [[ ! -b "$source" ]]; then
        log_error "$(_t "msg_source_not_exist" "$source")"
        ((errors++))
    fi
    if [[ ! -b "$dest" ]]; then
        log_error "$(_t "msg_dest_not_exist" "$dest")"
        ((errors++))
    fi
    [[ $errors -gt 0 ]] && return 1

    # 2. Same device
    if [[ "$source" == "$dest" ]]; then
        log_error "$(_t "msg_same_device")"
        ((errors++))
    fi

    # 3. Destination is current root
    if is_root_disk "$dest"; then
        log_error "$(_t "msg_dest_is_root" "$dest")"
        ((errors++))
    fi

    # 4. Destination mounted?
    if is_mounted "$dest"; then
        log_error "$(_t "msg_dest_mounted" "$dest")"
        lsblk -o NAME,MOUNTPOINT,SIZE "$dest" | grep -E "${dest}p?[0-9]+"
        ((errors++))
    fi

    # 5. Size check (destination must be >= source)
    local src_bytes dst_bytes
    src_bytes=$(get_disk_size "$source")
    dst_bytes=$(get_disk_size "$dest")

    if [[ $dst_bytes -lt $src_bytes ]]; then
        log_error "$(_t "msg_dest_smaller" "$(get_human_size "$dst_bytes")" "$(get_human_size "$src_bytes")")"
        log_info  "$(_t "msg_dest_must_be_larger")"
        ((errors++))
    else
        log_success "$(_t "msg_capacity_ok" "$(get_human_size "$dst_bytes")" "$(get_human_size "$src_bytes")")"
    fi

    # 6. Warn if destination already has partitions
    local pcount
    pcount=$(partition_count "$dest")
    if [[ $pcount -gt 0 ]]; then
        log_warn "$(_t "msg_dest_has_partitions" "$pcount")"
        warn_existing_partitions "$dest"
    fi

    # 7. Source has partitions?
    local scount
    scount=$(partition_count "$source")
    if [[ $scount -eq 0 ]]; then
        log_error "$(_t "msg_source_no_partitions")"
        ((errors++))
    fi

    # 8. Check for known filesystems on destination (extra safety)
    local part fstype
    for part in $(get_partitions "$dest"); do
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
        if [[ -n "$fstype" ]]; then
            log_warn "$(_t "msg_partition_has_fs" "$part" "$fstype")"
        fi
    done

    if [[ $errors -gt 0 ]]; then
        log_error "$(_t "msg_checks_failed" "$errors")"
        return 1
    fi

    log_success "$(_t "msg_all_checks_passed")"
    return 0
}

# Display existing partition table of a device
warn_existing_partitions() {
    local dev="$1"
    echo -e "\n${YELLOW}$(_t "title_existing_partitions" "$dev")${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL "$dev" 2>/dev/null || true
    echo ""
}

# Extra confirmation when destination has data
require_destructive_confirmation() {
    local dest="$1"
    local pcount
    pcount=$(partition_count "$dest")
    if [[ $pcount -gt 0 ]]; then
        if ! confirm_destructive "$(_t "msg_data_will_be_erased" "$dest")" "DESTRUCT"; then
            log_fatal "$(_t "msg_user_aborted_destructive")"
        fi
    else
        if ! confirm_yesno "$(_t "msg_overwrite_partition_table" "$dest")"; then
            log_fatal "$(_t "msg_user_aborted")"
        fi
    fi
}
