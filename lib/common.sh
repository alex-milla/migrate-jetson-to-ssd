#!/bin/bash
#
# common.sh — Shared helpers, colors, logging, and UI utilities
# Sourced by migrate.sh and other library modules.
#

source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"

# Colors (ANSI)
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export BOLD='\033[1m'
export NC='\033[0m' # No Color

# Logging helpers
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC}   $*"; }
log_fatal()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

# Ensure script is run as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_fatal "$(_t "msg_must_be_root" "$0")"
    fi
}

# Simple yes/no confirmation. Returns 0 for yes, 1 for no.
confirm_yesno() {
    local prompt="$1"
    local answer
    while true; do
        read -rp "${prompt} [y/N]: " answer
        case "$answer" in
            [Yy]* ) return 0 ;;
            [Nn]* | "" ) return 1 ;;
            * ) echo "$(_t "msg_answer_yes_no")" ;;
        esac
    done
}

# Destructive-action confirmation: user must type an exact word.
confirm_destructive() {
    local prompt="$1"
    local word="$2"
    local answer
    echo -e "${RED}${BOLD}$(_t "title_disclaimer"):${NC} ${prompt}"
    read -rp "$(_t "msg_type_word_confirm" "$word")" answer
    if [[ "$answer" == "$word" ]]; then
        return 0
    fi
    log_warn "$(_t "msg_confirmation_mismatch")"
    return 1
}

# Pause and wait for Enter
pause() {
    local msg="${1:-$(_t "msg_press_enter_continue")}"
    read -rp "$msg"
}

# Header banner
show_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    printf "║ %-60s ║\n" "$(_t "title_assistant")"
    printf "║ %-60s ║\n" "$(_t "title_assistant_subtitle")"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Show a section title
section_title() {
    echo -e "\n${BOLD}── $* ──${NC}\n"
}

# Spinner / progress placeholder (optional)
spin() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Clean up temp mount points on exit
cleanup_mounts() {
    local mnt
    for mnt in /mnt/source_* /mnt/destination_* /mnt/ssd; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            umount "$mnt" 2>/dev/null || true
        fi
        if [[ -d "$mnt" ]]; then
            rmdir "$mnt" 2>/dev/null || true
        fi
    done
}
