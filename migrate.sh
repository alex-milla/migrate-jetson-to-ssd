#!/bin/bash
#
# migrate.sh — Jetson Storage Migration Assistant
# Interactive, safe migration between SD / USB / M.2 (NVMe) drives.
#

set -uo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/i18n.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/disk_utils.sh"
source "$SCRIPT_DIR/lib/safety.sh"
source "$SCRIPT_DIR/lib/partition_ops.sh"
source "$SCRIPT_DIR/lib/copy_ops.sh"
source "$SCRIPT_DIR/lib/boot_config.sh"
source "$SCRIPT_DIR/lib/expand_ops.sh"

# Globals
DRY_RUN=0
LOG_FILE="/var/log/jetson-migrate-$(date +%Y%m%d-%H%M%S).log"
SOURCE_DISK=""
DEST_DISK=""
GPT_BACKUP=""

# Traps
cleanup() {
    log_info "$(_t "msg_press_enter_continue")"
    cleanup_mounts
    [[ -n "$GPT_BACKUP" && -f "$GPT_BACKUP" ]] && rm -f "$GPT_BACKUP"
}
trap cleanup EXIT INT TERM

# Show help
show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

$(_t "title_assistant")
$(_t "title_assistant_subtitle")

Options:
  --dry-run    $(_t "text_dryrun_no_execute")
  -h, --help   Show this help message.

Example:
  sudo ./migrate.sh
  sudo ./migrate.sh --dry-run
EOF
    exit 0
}

# Parse CLI args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# ───────────────────────────────────────────────────────────────
# Language selection
# ───────────────────────────────────────────────────────────────
show_header

echo "$(_t "msg_select_language")"
echo ""
echo "  [1] $(_t "lang_en")"
echo "  [2] $(_t "lang_es")"
echo ""

lang_choice=""
while true; do
    read -rp "[1-2]: " lang_choice
    case "$lang_choice" in
        1)
            I18N_LANG="en"
            load_i18n "en"
            break
            ;;
        2)
            I18N_LANG="es"
            load_i18n "es"
            break
            ;;
        *)
            echo "$(_t "msg_invalid_selection")"
            ;;
    esac
done

# Setup logging (tee to console and file)
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# ───────────────────────────────────────────────────────────────
# Phase 0: Disclaimer
# ───────────────────────────────────────────────────────────────
show_header

echo -e "${YELLOW}${BOLD}$(_t "title_disclaimer")${NC}\n"
echo "$(_t "text_disclaimer_data_loss")"
echo "$(_t "text_disclaimer_backup")"
echo "$(_t "text_disclaimer_protected")"
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}$(_t "text_dryrun_enabled")${NC}"
    echo "$(_t "text_dryrun_no_execute")"
    echo ""
fi

if ! confirm_yesno "$(_t "prompt_understand_risks")"; then
    log_info "$(_t "msg_aborted_disclaimer")"
    exit 0
fi

# ───────────────────────────────────────────────────────────────
# Phase 1: Environment & Root Check
# ───────────────────────────────────────────────────────────────
require_root

root_disk=$(resolve_root_disk)
log_info "$(_t "msg_root_disk_detected" "$root_disk")"

# ───────────────────────────────────────────────────────────────
# Phase 2: Select Source Disk
# ───────────────────────────────────────────────────────────────
section_title "$(_t "title_select_source")"

echo "$(_t "text_available_drives")"
echo ""

# Build array of candidate disks
declare -a CANDIDATES=()
while IFS= read -r dev; do
    [[ -n "$dev" ]] && CANDIDATES+=("$dev")
done < <(list_candidate_disks)

# Also include root disk in the list for source selection
if [[ -n "$root_disk" && -b "$root_disk" ]]; then
    CANDIDATES+=("$root_disk")
fi

# Sort & deduplicate
IFS=$'\n' read -d '' -ra CANDIDATES < <(printf '%s\n' "${CANDIDATES[@]}" | sort -u)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    log_fatal "$(_t "msg_no_disks")"
fi

# Print menu
idx=1
for dev in "${CANDIDATES[@]}"; do
    dtype="" dsize="" dmodel="" marker=""
    dtype=$(get_disk_type "$dev")
    dsize=$(get_human_size "$(get_disk_size "$dev")")
    dmodel=$(get_disk_model "$dev")
    marker=""
    if [[ "$dev" == "$root_disk" ]]; then
        marker=" ${RED}$(_t "marker_current_boot")${NC}"
    fi
    printf "  [%d] %-12s %-10s %-12s %s%s\n" "$idx" "$dev" "$dtype" "$dsize" "$dmodel" "$marker"
    ((idx++))
done
echo ""

choice=""
while true; do
    read -rp "$(_t "prompt_select_source" "$((idx-1))")" choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < idx )); then
        SOURCE_DISK="${CANDIDATES[$((choice-1))]}"
        break
    fi
    echo "$(_t "msg_invalid_selection")"
done

log_success "$(_t "msg_source_selected" "$SOURCE_DISK")"

# ───────────────────────────────────────────────────────────────
# Phase 3: Select Destination Disk
# ───────────────────────────────────────────────────────────────
section_title "$(_t "title_select_destination")"

echo "$(_t "text_select_drive_to")"
echo ""

idx=1
declare -a DEST_CANDIDATES=()
for dev in "${CANDIDATES[@]}"; do
    [[ "$dev" == "$root_disk" ]] && continue
    [[ "$dev" == "$SOURCE_DISK" ]] && continue
    DEST_CANDIDATES+=("$dev")
    dtype=$(get_disk_type "$dev")
    dsize=$(get_human_size "$(get_disk_size "$dev")")
    dmodel=$(get_disk_model "$dev")
    printf "  [%d] %-12s %-10s %-12s %s\n" "$idx" "$dev" "$dtype" "$dsize" "$dmodel"
    ((idx++))
done
echo ""

if [[ ${#DEST_CANDIDATES[@]} -eq 0 ]]; then
    log_fatal "$(_t "msg_no_destinations")"
fi

while true; do
    read -rp "$(_t "prompt_select_destination" "$((idx-1))")" choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < idx )); then
        DEST_DISK="${DEST_CANDIDATES[$((choice-1))]}"
        break
    fi
    echo "$(_t "msg_invalid_selection")"
done

log_success "$(_t "msg_destination_selected" "$DEST_DISK")"

# ───────────────────────────────────────────────────────────────
# Phase 4: Safety Validation
# ───────────────────────────────────────────────────────────────
section_title "$(_t "title_safety_checks")"

if ! validate_migration "$SOURCE_DISK" "$DEST_DISK"; then
    log_fatal "$(_t "msg_checks_failed" "1")"
fi

require_destructive_confirmation "$DEST_DISK"

# ───────────────────────────────────────────────────────────────
# Phase 5: Migration Summary
# ───────────────────────────────────────────────────────────────
section_title "$(_t "title_migration_plan")"

echo ""
printf "  %-20s %s\n" "$(_t "label_source")" "$SOURCE_DISK ($(get_human_size $(get_disk_size "$SOURCE_DISK")))"
printf "  %-20s %s\n" "$(_t "label_destination")" "$DEST_DISK ($(get_human_size $(get_disk_size "$DEST_DISK")))"
printf "  %-20s %s\n" "$(_t "label_log_file")" "$LOG_FILE"
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}$(_t "text_this_is_dryrun")${NC}\n"
else
    echo -e "${RED}${BOLD}$(_t "text_will_destroy_data" "$DEST_DISK")${NC}\n"
fi

if ! confirm_yesno "$(_t "prompt_proceed_migration")"; then
    log_info "$(_t "msg_aborted_before_migration")"
    exit 0
fi

# ───────────────────────────────────────────────────────────────
# Phase 6: Execute Migration Steps
# ───────────────────────────────────────────────────────────────

# Step 1 — Partition structure & filesystems
section_title "$(_t "title_step1")"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "$(_t "msg_dryrun_clone_gpt" "$SOURCE_DISK" "$DEST_DISK")"
    log_info "$(_t "msg_dryrun_create_fs" "$DEST_DISK")"
    log_info "$(_t "msg_dryrun_randomize_uuids")"
else
    GPT_BACKUP="/tmp/jetson-migrate-gpt-backup.bak"
    clone_partition_table "$SOURCE_DISK" "$DEST_DISK"
    replicate_filesystems "$SOURCE_DISK" "$DEST_DISK"
    adjust_uuids "$SOURCE_DISK" "$DEST_DISK"
    log_success "$(_t "msg_partition_structure_cloned")"
fi

# Step 2 — Copy data
section_title "$(_t "title_step2")"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "$(_t "msg_dryrun_copy_data" "$SOURCE_DISK" "$DEST_DISK")"
else
    copy_partition_data "$SOURCE_DISK" "$DEST_DISK"
fi

# Step 3 — Expand root if applicable
src_bytes=$(get_disk_size "$SOURCE_DISK")
dst_bytes=$(get_disk_size "$DEST_DISK")

if [[ $dst_bytes -gt $src_bytes ]]; then
    section_title "$(_t "title_step3")"
    log_info "$(_t "msg_dest_larger")"
    if confirm_yesno "$(_t "prompt_expand_root")"; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "$(_t "msg_dryrun_expand" "$DEST_DISK")"
        else
            if ! expand_root_partition "$DEST_DISK"; then
                log_warn "$(_t "msg_expansion_skipped")"
            fi
        fi
    else
        log_info "$(_t "msg_expansion_skipped")"
    fi
fi

# Step 4 — Configure boot
section_title "$(_t "title_step4")"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "$(_t "msg_dryrun_configure_boot" "$DEST_DISK")"
else
    configure_boot "$DEST_DISK"
fi

# ───────────────────────────────────────────────────────────────
# Phase 7: Final Report
# ───────────────────────────────────────────────────────────────
section_title "$(_t "title_migration_complete")"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${CYAN}$(_t "msg_dryrun_finished")${NC}"
    echo "$(_t "msg_dryrun_review_log")"
else
    log_success "$(_t "msg_migration_success" "$SOURCE_DISK" "$DEST_DISK")"
    echo ""
    echo -e "${YELLOW}$(_t "label_next_steps")${NC}"
    echo "  $(_t "step_reboot")"
    echo "  $(_t "step_enter_uefi")"
    echo "  $(_t "step_change_boot_order" "$DEST_DISK")"
    echo "  $(_t "step_save_exit")"
    echo ""
fi

echo "$(_t "msg_log_saved" "$LOG_FILE")"
