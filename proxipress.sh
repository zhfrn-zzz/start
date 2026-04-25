#!/bin/bash
set -o pipefail

# ============================================================
#  proxipress — Proxmox + WordPress in one shot
#  Version: 4.0
#  Flags: --verbose | --fancy | --dry-run | --quick
#  Usage: ./proxipress.sh [--verbose] [--fancy] [--dry-run] [--quick]
# ============================================================

# ─── FLAG PARSING ────────────────────────────────────────────
VERBOSE=false
FANCY=false
DRY_RUN=false
QUICK=false

for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=true ;;
        --fancy)   FANCY=true ;;
        --dry-run) DRY_RUN=true ;;
        --quick)   QUICK=true ;;
    esac
done

# ─── WARNA ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── LOG FILE ────────────────────────────────────────────────
LOG_FILE="/tmp/proxipress-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# ─── NILAI DEFAULT ───────────────────────────────────────────
DEFAULT_VMID=105
DEFAULT_HOSTNAME="wordpress"
DEFAULT_DISK=64
DEFAULT_CPU=4
DEFAULT_MEMORY=2048
DEFAULT_SWAP=2048
DEFAULT_DB_NAME="wordpress"
DEFAULT_DB_USER="wpuser"

# ─── KONFIGURASI PROXMOX ─────────────────────────────────────
STORAGE_ROOT="local-lvm"    # untuk rootfs CT
STORAGE_TMPL="local"        # untuk template
TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
BRIDGE="vmbr0"

# ─── STEP TRACKING ───────────────────────────────────────────
TOTAL_STEPS=11
CURRENT_STEP=0
INSTALL_START=0
_STEP_SEVERITY="recoverable"

format_time() {
    local s=$1
    if [ "$s" -lt 60 ]; then
        echo "${s}s"
    else
        echo "$((s/60))m $((s%60))s"
    fi
}

# ─── CLEANUP TRAP ─────────────────────────────────────────────
CT_CREATED=false
INSTALL_SUCCESS=false
INTERRUPTED=false

cleanup_on_exit() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    tput cnorm 2>/dev/null || true
    $INSTALL_SUCCESS && return
    if $INTERRUPTED; then
        echo ""
        echo -e "  ${RED}[x]${NC} Interrupted by user."
        if $CT_CREATED; then
            read -rp "  => Hapus CT ${VMID} yang setengah jadi? (y/n): " del_choice
            if [[ "$del_choice" =~ ^[yY]$ ]]; then
                pct stop "$VMID" --force 2>/dev/null
                pct destroy "$VMID" 2>/dev/null && \
                    echo -e "  ${GREEN}[+]${NC} CT ${VMID} dihapus." || \
                    echo -e "  ${YELLOW}[!]${NC} Gagal menghapus CT ${VMID}."
            fi
        fi
    fi
}

trap 'INTERRUPTED=true; cleanup_on_exit; exit 130' INT TERM
trap 'cleanup_on_exit' EXIT

# ─── SPINNER ─────────────────────────────────────────────────
SPINNER_PID=""

if $FANCY; then
    SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
else
    SPINNER_CHARS='|/-\'
fi

start_spinner() {
    local label="$1"
    $VERBOSE && return
    tput civis 2>/dev/null || true
    (
        local i=0
        local len=${#SPINNER_CHARS}
        while true; do
            local char="${SPINNER_CHARS:$i:1}"
            printf "\r  ${YELLOW}%s${NC} %s   " "$char" "$label"
            i=$(( (i+1) % len ))
            sleep 0.12
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID"
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r\033[K"
        tput cnorm 2>/dev/null || true
    fi
}

# ─── LOG REDACTION ───────────────────────────────────────────
log_redact() {
    local text="$1"
    [ -n "$PASSWORD" ] && text="${text//$PASSWORD/***REDACTED***}"
    [ -n "$DB_PASS" ] && text="${text//$DB_PASS/***REDACTED***}"
    printf '%s' "$text"
}

_log_pipe() {
    while IFS= read -r line; do
        log_redact "$line" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
    done
}

# ─── OUTPUT HELPERS ──────────────────────────────────────────
log()  {
    stop_spinner
    echo -e "  ${GREEN}[+]${NC} $1"
    log_redact "[OK]   $(date '+%H:%M:%S') $1" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}
warn() {
    echo -e "  ${YELLOW}[!]${NC} $1"
    log_redact "[WARN] $(date '+%H:%M:%S') $1" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}
info() {
    echo -e "  ${BLUE}[i]${NC} $1"
    log_redact "[INFO] $(date '+%H:%M:%S') $1" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}
error() {
    stop_spinner
    echo -e "\n  ${RED}[x]${NC} ${BOLD}$1${NC}"
    log_redact "[ERR]  $(date '+%H:%M:%S') $1" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    echo -e "  ${DIM}Log: ${LOG_FILE}${NC}"
    exit 1
}

section() {
    local title="$1"
    echo ""
    if $FANCY; then
        echo -e "  ${CYAN}${BOLD}▐ ${title}${NC}"
        echo -e "  ${DIM}$(printf '━%.0s' $(seq 1 50))${NC}"
    else
        echo -e "  ${CYAN}${BOLD}> ${title}${NC}"
        echo -e "  ${DIM}$(printf -- '-%.0s' $(seq 1 50))${NC}"
    fi
}

# ─── RUN STEP ────────────────────────────────────────────────
# Usage: run_step "Label" command [arg1 arg2 ...]
run_step() {
    local label="$1"; shift
    local -a cmd=("$@")
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local prefix="${CURRENT_STEP}/${TOTAL_STEPS}"
    local step_start
    step_start=$(date +%s)

    echo "" >> "$LOG_FILE"
    log_redact "=== [${prefix}] ${label} ===" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"

    # Progress bar
    local filled=$(( CURRENT_STEP * 20 / TOTAL_STEPS ))
    local empty=$(( 20 - filled ))
    local bar=""
    if $FANCY; then
        [ "$filled" -gt 0 ] && bar=$(printf '█%.0s' $(seq 1 $filled))
        [ "$empty" -gt 0 ] && bar+=$(printf '░%.0s' $(seq 1 $empty))
    else
        [ "$filled" -gt 0 ] && bar=$(printf '#%.0s' $(seq 1 $filled))
        [ "$empty" -gt 0 ] && bar+=$(printf '.%.0s' $(seq 1 $empty))
    fi

    if $VERBOSE; then
        echo -e "  ${DIM}[${bar}]${NC} ${CYAN}${prefix}${NC}  ${label}"
        "${cmd[@]}" 2>&1 | tee >(_log_pipe)
        local exit_code="${PIPESTATUS[0]}"
    else
        start_spinner "[${bar}] ${prefix}  ${label}"
        "${cmd[@]}" 2>&1 | _log_pipe
        local exit_code="${PIPESTATUS[0]}"
        stop_spinner
    fi

    local elapsed
    elapsed=$(format_time $(( $(date +%s) - step_start )))

    if [ "$exit_code" -eq 0 ]; then
        if $FANCY; then
            echo -e "  ${GREEN}✓${NC} ${DIM}[${bar}]${NC} ${prefix}  ${label}  ${DIM}${elapsed}${NC}"
        else
            echo -e "  ${GREEN}[OK]${NC} ${DIM}[${bar}]${NC} ${prefix}  ${label}  ${DIM}${elapsed}${NC}"
        fi
        echo "[OK] Step selesai dalam ${elapsed}" >> "$LOG_FILE"
    elif [ "$exit_code" -eq 2 ]; then
        if $FANCY; then
            echo -e "  ${YELLOW}⚠${NC} ${DIM}[${bar}]${NC} ${prefix}  ${label}  ${DIM}${elapsed}${NC}"
        else
            echo -e "  ${YELLOW}[WARN]${NC} ${DIM}[${bar}]${NC} ${prefix}  ${label}  ${DIM}${elapsed}${NC}"
        fi
        echo "[WARN] Step selesai dengan warning dalam ${elapsed}" >> "$LOG_FILE"
    else
        if $FANCY; then
            echo -e "  ${RED}✗${NC} ${DIM}[${bar}]${NC} ${prefix}  ${label}  ${DIM}${elapsed}${NC}"
        else
            echo -e "  ${RED}[FAIL]${NC} ${DIM}[${bar}]${NC} ${prefix}  ${label}  ${DIM}${elapsed}${NC}"
        fi
        handle_error "$label" "${cmd[@]}"
    fi
}

# ─── ERROR RECOVERY ──────────────────────────────────────────
handle_error() {
    local label="$1"; shift
    local -a cmd=("$@")

    echo ""
    if $FANCY; then
        echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${RED}${BOLD}  ✗ Step Failed${NC}  ${label}"
        echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "  ${RED}==================================================${NC}"
        echo -e "  ${RED}${BOLD}  [FAILED]${NC}  ${label}"
        echo -e "  ${RED}==================================================${NC}"
    fi
    echo -e "  ${DIM}Log: ${LOG_FILE}${NC}"
    echo ""

    while true; do
        if [ "$_STEP_SEVERITY" = "critical" ]; then
            echo -e "  ${RED}${BOLD}Step ini critical — skip tidak tersedia.${NC}"
            echo ""
            if $FANCY; then
                echo -e "  ${BOLD}Recovery Options:${NC}"
                echo -e "    ${CYAN}r${NC} │ Retry this step"
                echo -e "    ${CYAN}l${NC} │ Show last 30 log lines"
                echo -e "    ${CYAN}a${NC} │ Abort installation"
            else
                echo -e "  ${BOLD}Recovery Options:${NC}"
                echo -e "    ${CYAN}r${NC} | Retry this step"
                echo -e "    ${CYAN}l${NC} | Show last 30 log lines"
                echo -e "    ${CYAN}a${NC} | Abort installation"
            fi
            echo ""
            read -rp "  => Choice (r/l/a): " choice
        else
            if $FANCY; then
                echo -e "  ${BOLD}Recovery Options:${NC}"
                echo -e "    ${CYAN}r${NC} │ Retry this step"
                echo -e "    ${CYAN}s${NC} │ Skip and continue"
                echo -e "    ${CYAN}l${NC} │ Show last 30 log lines"
                echo -e "    ${CYAN}a${NC} │ Abort installation"
            else
                echo -e "  ${BOLD}Recovery Options:${NC}"
                echo -e "    ${CYAN}r${NC} | Retry this step"
                echo -e "    ${CYAN}s${NC} | Skip and continue"
                echo -e "    ${CYAN}l${NC} | Show last 30 log lines"
                echo -e "    ${CYAN}a${NC} | Abort installation"
            fi
            echo ""
            read -rp "  => Choice (r/s/l/a): " choice
        fi

        case "$choice" in
            r|R)
                local t_start
                t_start=$(date +%s)
                if $VERBOSE; then
                    "${cmd[@]}" 2>&1 | tee >(_log_pipe)
                    local ec="${PIPESTATUS[0]}"
                else
                    start_spinner "Retrying: ${label}"
                    "${cmd[@]}" 2>&1 | _log_pipe
                    local ec="${PIPESTATUS[0]}"
                    stop_spinner
                fi
                local elapsed
                elapsed=$(format_time $(( $(date +%s) - t_start )))
                if [ "$ec" -eq 0 ]; then
                    if $FANCY; then
                        echo -e "  ${GREEN}✓${NC} Retry succeeded  ${DIM}${elapsed}${NC}"
                    else
                        echo -e "  ${GREEN}[OK]${NC} Retry succeeded  ${DIM}${elapsed}${NC}"
                    fi
                    return 0
                else
                    echo -e "  ${RED}[x]${NC} Retry failed."
                fi
                ;;
            s|S)
                if [ "$_STEP_SEVERITY" = "critical" ]; then
                    echo -e "  ${RED}Skip tidak tersedia untuk step critical.${NC}"
                else
                    warn "Step skipped: ${label}"
                    return 0
                fi
                ;;
            l|L)
                echo ""
                echo -e "  ${DIM}─── last 30 lines ───${NC}"
                tail -30 "$LOG_FILE" | sed 's/^/    /'
                echo -e "  ${DIM}─── end ───${NC}"
                echo ""
                ;;
            a|A)
                echo ""
                read -rp "  => Hapus CT ${VMID} yang sudah terbuat? (y/n): " del_choice
                if [[ "$del_choice" =~ ^[yY]$ ]]; then
                    pct stop "$VMID" --force 2>/dev/null
                    if pct destroy "$VMID" 2>/dev/null; then
                        info "CT ${VMID} berhasil dihapus."
                    else
                        warn "Gagal menghapus CT ${VMID}."
                    fi
                fi
                error "Installation aborted by user."
                ;;
            *)
                echo -e "  ${RED}Invalid choice.${NC} Enter r, s, l, or a."
                ;;
        esac
    done
}

# ─── BANNER ──────────────────────────────────────────────────
show_banner() {
    clear
    echo ""
    if $FANCY; then
        echo -e "${CYAN}"
        cat << 'BANNER'
    ██████╗ ██████╗  ██████╗ ██╗  ██╗██╗██████╗ ██████╗ ███████╗███████╗███████╗
    ██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝██║██╔══██╗██╔══██╗██╔════╝██╔════╝██╔════╝
    ██████╔╝██████╔╝██║   ██║ ╚███╔╝ ██║██████╔╝██████╔╝█████╗  ███████╗███████╗
    ██╔═══╝ ██╔══██╗██║   ██║ ██╔██╗ ██║██╔═══╝ ██╔══██╗██╔══╝  ╚════██║╚════██║
    ██║     ██║  ██║╚██████╔╝██╔╝ ██╗██║██║     ██║  ██║███████╗███████║███████║
    ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝
BANNER
        echo -e "${NC}"
        echo -e "  ${BOLD}Proxmox + WordPress in one shot${NC}  ${DIM}v4.0${NC}"
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${CYAN}${BOLD}"
        cat << 'BANNER'
                         _                            
     _ __  _ __ _____  _(_)_ __  _ __ ___  ___ ___ 
    | '_ \| '__/ _ \ \/ / | '_ \| '__/ _ \/ __/ __|
    | |_) | | | (_) >  <| | |_) | | |  __/\__ \__ \
    | .__/|_|  \___/_/\_\_| .__/|_|  \___||___/___/
    |_|                   |_|                       
BANNER
        echo -e "${NC}"
        echo -e "  ${BOLD}Proxmox + WordPress in one shot${NC}  ${DIM}v4.0${NC}"
        echo -e "  ${DIM}--------------------------------------------------${NC}"
    fi

    echo ""
    local flags=""
    $VERBOSE && flags+=" ${YELLOW}[verbose]${NC}"
    $FANCY   && flags+=" ${CYAN}[fancy]${NC}"
    $DRY_RUN && flags+=" ${BLUE}[dry-run]${NC}"
    $QUICK   && flags+=" ${GREEN}[quick]${NC}"
    [ -n "$flags" ] && echo -e "  ${DIM}Flags:${NC}${flags}" && echo ""

    echo -e "  ${DIM}Log:${NC} ${LOG_FILE}"
    echo ""
}

# ─── INPUT HELPER ────────────────────────────────────────────
INPUT_RESULT=""

get_input() {
    local prompt="$1"
    local default="$2"
    local validator="$3"
    local hide="$4"

    # --quick: auto-accept default if available
    if $QUICK && [ -n "$default" ]; then
        INPUT_RESULT="$default"
        return
    fi
    if $QUICK && [ -z "$default" ]; then
        warn "--quick mode tapi field ini wajib diisi"
    fi

    while true; do
        local display
        if [ -n "$default" ]; then
            if [ "$hide" = "yes" ]; then
                display="  => ${prompt} [default: ****]: "
            else
                display="  => ${prompt} [default: ${default}]: "
            fi
        else
            display="  => ${prompt}: "
        fi

        if [ "$hide" = "yes" ]; then
            read -rs -p "$display" INPUT_RESULT
            echo ""
        else
            read -rp "$display" INPUT_RESULT
        fi

        INPUT_RESULT="${INPUT_RESULT:-$default}"

        if [ -z "$INPUT_RESULT" ]; then
            echo -e "  ${RED}  Field ini tidak boleh kosong. Coba lagi.${NC}"
            continue
        fi

        if [ -n "$validator" ] && ! $validator "$INPUT_RESULT"; then
            continue
        fi

        break
    done
}

# ─── PASSWORD GENERATOR ───────────────────────────────────────
gen_password() {
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c16
}

get_password_input() {
    local prompt="$1"
    local generated
    generated=$(gen_password)
    if $QUICK; then
        INPUT_RESULT="$generated"
        return
    fi
    while true; do
        echo -e "  => ${prompt} [generated: ${GREEN}${generated}${NC}, Enter=pakai ini, atau ketik sendiri]"
        read -rs -p "  => " INPUT_RESULT
        echo ""
        INPUT_RESULT="${INPUT_RESULT:-$generated}"
        if [ ${#INPUT_RESULT} -lt 12 ]; then
            echo -e "  ${RED}  Password minimal 12 karakter.${NC}"
            continue
        fi
        break
    done
}

# ─── VALIDATORS ──────────────────────────────────────────────
validate_vmid() {
    local v="$1"
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 101 ]; then
        echo -e "  ${RED}  VMID harus angka >= 101.${NC}"
        return 1
    fi
    if pct status "$v" &>/dev/null 2>&1; then
        echo -e "  ${RED}  CT ${v} sudah ada! Gunakan VMID lain.${NC}"
        return 1
    fi
    return 0
}

validate_number() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ]; then
        echo -e "  ${RED}  Harus berupa angka positif.${NC}"
        return 1
    fi
    return 0
}

validate_ip_cidr() {
    if ! [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo -e "  ${RED}  Format tidak valid. Contoh: 192.168.10.5/24${NC}"
        return 1
    fi
    return 0
}

validate_ip() {
    if ! [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "  ${RED}  Format tidak valid. Contoh: 192.168.10.1${NC}"
        return 1
    fi
    return 0
}

validate_password() {
    if [ ${#1} -lt 12 ]; then
        echo -e "  ${RED}  Password minimal 12 karakter.${NC}"
        return 1
    fi
    return 0
}

derive_gateway() {
    local ip="${1%/*}"
    echo "$(echo "$ip" | cut -d. -f1-3).1"
}

# ─── CEK / DOWNLOAD TEMPLATE ─────────────────────────────────
check_template() {
    local path="/var/lib/vz/template/cache/${TEMPLATE}"
    if [ ! -f "$path" ]; then
        warn "Template '${TEMPLATE}' tidak ditemukan."
        info "Mengunduh otomatis dari repositori Proxmox..."
        pveam update 2>&1 | _log_pipe || error "Gagal update daftar template"
        pveam download "$STORAGE_TMPL" "$TEMPLATE" 2>&1 | _log_pipe \
            || error "Gagal mengunduh template"
        log "Template berhasil diunduh"
    fi
}

# ─── RINGKASAN KONFIGURASI ───────────────────────────────────
show_summary() {
    local ip_clean="${IP%/*}"

    echo ""
    echo -e "  ${YELLOW}${BOLD}! Save password sekarang — tidak akan ditampilkan lagi setelah install.${NC}"

    # Helper: print a row with proper alignment (ANSI-safe)
    _row() {
        local key="$1" val="$2" val_color="${3:-}"
        if $FANCY; then
            printf "  ${CYAN}│${NC} %-18s ${CYAN}│${NC} " "$key"
            if [ -n "$val_color" ]; then
                printf "${val_color}%-24s${NC}" "$val"
            else
                printf "%-24s" "$val"
            fi
            printf " ${CYAN}│${NC}\n"
        else
            printf "  ${CYAN}|${NC} %-18s ${CYAN}|${NC} " "$key"
            if [ -n "$val_color" ]; then
                printf "${val_color}%-24s${NC}" "$val"
            else
                printf "%-24s" "$val"
            fi
            printf " ${CYAN}|${NC}\n"
        fi
    }

    echo ""
    if $FANCY; then
        echo -e "  ${CYAN}┌────────────────────┬──────────────────────────┐${NC}"
        echo -e "  ${CYAN}│${NC} ${BOLD}Parameter${NC}          ${CYAN}│${NC} ${BOLD}Value${NC}                    ${CYAN}│${NC}"
        echo -e "  ${CYAN}├────────────────────┼──────────────────────────┤${NC}"
        _row "VMID"         "$VMID"
        _row "Hostname"     "$HOSTNAME"
        _row "Password CT"  "$PASSWORD" "$YELLOW"
        echo -e "  ${CYAN}├────────────────────┼──────────────────────────┤${NC}"
        _row "Disk"         "${DISK} GB"
        _row "CPU"          "${CPU} core"
        _row "Memory"       "${MEMORY} MB"
        _row "Swap"         "${SWAP} MB"
        _row "Storage Root" "$STORAGE_ROOT"
        _row "Storage Tmpl" "$STORAGE_TMPL"
        echo -e "  ${CYAN}├────────────────────┼──────────────────────────┤${NC}"
        _row "IP Address"   "$IP"
        _row "Gateway"      "$GW"
        _row "Timezone"     "$TIMEZONE"
        echo -e "  ${CYAN}├────────────────────┼──────────────────────────┤${NC}"
        _row "DB Name"      "$DB_NAME"
        _row "DB User"      "$DB_USER"
        _row "DB Password"  "$DB_PASS" "$YELLOW"
        echo -e "  ${CYAN}├────────────────────┼──────────────────────────┤${NC}"
        _row "WordPress URL" "http://${ip_clean}" "$GREEN"
        echo -e "  ${CYAN}└────────────────────┴──────────────────────────┘${NC}"
    else
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        echo -e "  ${CYAN}|${NC} ${BOLD}Parameter${NC}          ${CYAN}|${NC} ${BOLD}Value${NC}                    ${CYAN}|${NC}"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        _row "VMID"         "$VMID"
        _row "Hostname"     "$HOSTNAME"
        _row "Password CT"  "$PASSWORD" "$YELLOW"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        _row "Disk"         "${DISK} GB"
        _row "CPU"          "${CPU} core"
        _row "Memory"       "${MEMORY} MB"
        _row "Swap"         "${SWAP} MB"
        _row "Storage Root" "$STORAGE_ROOT"
        _row "Storage Tmpl" "$STORAGE_TMPL"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        _row "IP Address"   "$IP"
        _row "Gateway"      "$GW"
        _row "Timezone"     "$TIMEZONE"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        _row "DB Name"      "$DB_NAME"
        _row "DB User"      "$DB_USER"
        _row "DB Password"  "$DB_PASS" "$YELLOW"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        _row "WordPress URL" "http://${ip_clean}" "$GREEN"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
    fi
    echo ""
}

# ─── KONFIRMASI ──────────────────────────────────────────────
confirm_proceed() {
    while true; do
        read -rp "  => Lanjutkan instalasi? (y/n): " answer
        case "$answer" in
            y|Y|yes) return 0 ;;
            n|N|no)
                warn "Instalasi dibatalkan."
                exit 0
                ;;
            *) echo -e "  ${RED}  Ketik y atau n.${NC}" ;;
        esac
    done
}

# ─── DRY RUN PREVIEW ─────────────────────────────────────────
show_dry_run() {
    show_summary

    section "Dry Run — Steps yang Akan Dijalankan"
    echo ""
    local steps=(
        "[1/${TOTAL_STEPS}] Cek / download template"
        "[2/${TOTAL_STEPS}] pct create ${VMID} (${HOSTNAME})"
        "[3/${TOTAL_STEPS}] pct start ${VMID} + tunggu siap"
        "[4/${TOTAL_STEPS}] Set timezone CT"
        "[5/${TOTAL_STEPS}] apt-get update && apt-get upgrade"
        "[6/${TOTAL_STEPS}] Install apache2, mysql-server, php + extensions"
        "[7/${TOTAL_STEPS}] Setup database MySQL: ${DB_NAME} / ${DB_USER}"
        "[8/${TOTAL_STEPS}] Download WordPress + konfigurasi wp-config.php"
        "[9/${TOTAL_STEPS}] Konfigurasi PHP untuk WordPress"
        "[10/${TOTAL_STEPS}] Konfigurasi Apache + aktifkan mod_rewrite"
        "[11/${TOTAL_STEPS}] Health check WordPress"
    )
    for step in "${steps[@]}"; do
        echo -e "  ${DIM}o${NC}  ${step}"
    done

    echo ""
    echo -e "  ${BLUE}[i]${NC} Mode dry-run: tidak ada yang dieksekusi."
    echo -e "  ${BLUE}[i]${NC} Jalankan tanpa --dry-run untuk eksekusi nyata."
    echo ""
    exit 0
}

# ─── GATHER INPUT ─────────────────────────────────────────────
gather_input() {
    section "Konfigurasi"
    echo ""

    info "[ Identitas Container ]"
    get_input "VMID" "$DEFAULT_VMID" "validate_vmid"
    VMID="$INPUT_RESULT"

    get_input "Hostname" "$DEFAULT_HOSTNAME"
    HOSTNAME="$INPUT_RESULT"

    get_password_input "Password CT"
    PASSWORD="$INPUT_RESULT"

    echo ""
    info "[ Spesifikasi ]"

    get_input "Disk (GB)" "$DEFAULT_DISK" "validate_number"
    DISK="$INPUT_RESULT"

    get_input "CPU (core)" "$DEFAULT_CPU" "validate_number"
    CPU="$INPUT_RESULT"

    get_input "Memory (MB)" "$DEFAULT_MEMORY" "validate_number"
    MEMORY="$INPUT_RESULT"

    get_input "Swap (MB)" "$DEFAULT_SWAP" "validate_number"
    SWAP="$INPUT_RESULT"

    get_input "Storage CT (rootfs)" "$STORAGE_ROOT"
    STORAGE_ROOT="$INPUT_RESULT"

    get_input "Storage Template" "$STORAGE_TMPL"
    STORAGE_TMPL="$INPUT_RESULT"

    echo ""
    info "[ Jaringan ]"

    get_input "IP Address (contoh: 192.168.10.5/24)" "" "validate_ip_cidr"
    IP="$INPUT_RESULT"

    local suggested_gw
    suggested_gw=$(derive_gateway "$IP")
    get_input "Gateway" "$suggested_gw" "validate_ip"
    GW="$INPUT_RESULT"

    echo ""
    info "[ Database WordPress ]"

    get_input "DB Name" "$DEFAULT_DB_NAME"
    DB_NAME="$INPUT_RESULT"

    get_input "DB User" "$DEFAULT_DB_USER"
    DB_USER="$INPUT_RESULT"

    get_password_input "DB Password"
    DB_PASS="$INPUT_RESULT"

    echo ""
    info "[ Lainnya ]"

    get_input "Timezone CT" "Asia/Jakarta"
    TIMEZONE="$INPUT_RESULT"
}

# ─── INSTALASI ───────────────────────────────────────────────
run_install() {
    [ "$EUID" -ne 0 ] && error "Script harus dijalankan sebagai root"

    local ip_clean="${IP%/*}"
    section "Memulai Instalasi"
    INSTALL_START=$(date +%s)
    echo ""

    # Step 1: Template
    _STEP_SEVERITY="recoverable"
    run_step "Cek / download template" check_template

    # Step 2: Buat CT
    _STEP_SEVERITY="critical"
    run_step "Membuat CT ${VMID} (${HOSTNAME})" \
        pct create "${VMID}" \
            "${STORAGE_TMPL}:vztmpl/${TEMPLATE}" \
            --hostname "${HOSTNAME}" \
            --password "${PASSWORD}" \
            --rootfs "${STORAGE_ROOT}:${DISK}" \
            --cores "${CPU}" \
            --memory "${MEMORY}" \
            --swap "${SWAP}" \
            --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GW}" \
            --unprivileged 1 \
            --features nesting=1 \
            --ostype ubuntu \
            --start 0

    CT_CREATED=true

    # Step 3: Start CT
    _STEP_SEVERITY="critical"
    _wait_ct_ready() {
        pct start "${VMID}" || return 1
        local _t=0
        until pct exec "${VMID}" -- echo ok &>/dev/null; do
            sleep 2
            _t=$((_t+2))
            if [ $_t -ge 60 ]; then
                echo 'Timeout waiting for CT'
                return 1
            fi
        done
    }
    run_step "Menjalankan CT + tunggu siap" _wait_ct_ready

    # Connectivity check (non-step)
    info "Cek koneksi internet CT..."
    pct exec "${VMID}" -- bash -c 'command -v curl >/dev/null || apt-get install -y curl' 2>&1 | _log_pipe
    _check_url() {
        local url="$1"
        local result
        result=$(pct exec "${VMID}" -- curl -sI --max-time 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
        local ec=$?
        if [ "$ec" -eq 6 ]; then
            error "DNS resolution failed untuk ${url} — cek /etc/resolv.conf di CT ${VMID}"
        elif [ "$ec" -eq 28 ]; then
            error "Network timeout ke ${url} — kemungkinan no route atau firewall block"
        elif [ "$ec" -ne 0 ]; then
            error "Curl gagal (exit ${ec}) ke ${url} — cek jaringan CT ${VMID}"
        fi
        case "$result" in
            200|301|302) return 0 ;;
            *) error "Upstream issue di ${url} (HTTP ${result})" ;;
        esac
    }
    _check_url "http://archive.ubuntu.com"
    _check_url "https://wordpress.org"
    log "Koneksi internet CT OK"

    # Step 4: Set timezone
    _STEP_SEVERITY="recoverable"
    run_step "Set timezone CT" pct exec "${VMID}" -- timedatectl set-timezone "$TIMEZONE"

    # Step 5: Update & Upgrade
    _STEP_SEVERITY="recoverable"
    run_step "apt update && apt upgrade" \
        pct exec "${VMID}" -- bash -c 'apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y'

    # Step 6: Install LAMP
    _STEP_SEVERITY="critical"
    run_step "Install LAMP stack (Apache, MySQL, PHP)" \
        pct exec "${VMID}" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y \
            apache2 mysql-server php php-mysql php-curl php-gd \
            php-mbstring php-xml php-zip libapache2-mod-php'

    # Step 7: Setup Database
    _STEP_SEVERITY="critical"
    _setup_db() {
        pct exec "${VMID}" -- bash -c '
            DB_NAME="$1"; DB_USER="$2"; DB_PASS="$3"
            ESCAPED_PASS="${DB_PASS//\\/\\\\}"
            ESCAPED_PASS="${ESCAPED_PASS//'"'"'/\\'"'"'}"
            mysql -e "CREATE DATABASE \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" &&
            mysql -e "CREATE USER '"'"'${DB_USER}'"'"'@'"'"'localhost'"'"' IDENTIFIED BY '"'"'${ESCAPED_PASS}'"'"';" &&
            mysql -e "GRANT ALL ON \`${DB_NAME}\`.* TO '"'"'${DB_USER}'"'"'@'"'"'localhost'"'"'; FLUSH PRIVILEGES;"
        ' -- "${DB_NAME}" "${DB_USER}" "${DB_PASS}"
    }
    run_step "Setup database MySQL" _setup_db

    # Step 8: WordPress
    _STEP_SEVERITY="critical"
    _install_wordpress() {
        pct exec "${VMID}" -- bash -c '
            cd /tmp && wget -q https://wordpress.org/latest.tar.gz && tar -xzf latest.tar.gz &&
            mv wordpress /var/www/html/ &&
            chown -R www-data:www-data /var/www/html/wordpress &&
            find /var/www/html/wordpress -type d -exec chmod 755 {} \; &&
            find /var/www/html/wordpress -type f -exec chmod 644 {} \; &&
            cd /var/www/html/wordpress &&
            cp wp-config-sample.php wp-config.php &&
            if grep -q "put your unique phrase here" wp-config.php; then
                SALTS=$(curl -sf --max-time 10 https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null)
                if [ -z "$SALTS" ]; then
                    SALTS=""
                    for KEY in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
                        VAL=$(openssl rand -base64 64 | tr -d "\n")
                        SALTS="${SALTS}define('"'"'${KEY}'"'"', '"'"'${VAL}'"'"');\n"
                    done
                fi
                sed -i "/put your unique phrase here/d" wp-config.php
                MARKER=$(grep -n "Authentication unique keys" wp-config.php | tail -1 | cut -d: -f1)
                if [ -n "$MARKER" ]; then
                    sed -i "${MARKER}a\\
$(printf "%b" "$SALTS")" wp-config.php
                else
                    printf "%b" "$SALTS" >> wp-config.php
                fi
            fi &&
            php -r "
                \$f = '"'"'wp-config.php'"'"';
                \$c = file_get_contents(\$f);
                \$c = str_replace('"'"'database_name_here'"'"', \$argv[1], \$c);
                \$c = str_replace('"'"'username_here'"'"', \$argv[2], \$c);
                \$c = str_replace('"'"'password_here'"'"', \$argv[3], \$c);
                file_put_contents(\$f, \$c);
            " "$1" "$2" "$3" &&
            chmod 640 /var/www/html/wordpress/wp-config.php &&
            chown root:www-data /var/www/html/wordpress/wp-config.php
        ' -- "${DB_NAME}" "${DB_USER}" "${DB_PASS}"
    }
    run_step "Download & install WordPress" _install_wordpress

    # Step 9: PHP Config
    _STEP_SEVERITY="recoverable"
    run_step "Konfigurasi PHP untuk WordPress" \
        pct exec "${VMID}" -- bash -c '
            sed -i "s/upload_max_filesize = .*/upload_max_filesize = 64M/" /etc/php/*/apache2/php.ini &&
            sed -i "s/post_max_size = .*/post_max_size = 64M/" /etc/php/*/apache2/php.ini &&
            sed -i "s/max_execution_time = .*/max_execution_time = 300/" /etc/php/*/apache2/php.ini &&
            sed -i "s/memory_limit = .*/memory_limit = 256M/" /etc/php/*/apache2/php.ini'

    # Step 10: Apache
    _STEP_SEVERITY="critical"
    _setup_apache() {
        pct exec "${VMID}" -- bash -c 'cat > /etc/apache2/sites-available/000-default.conf << "APACHEEOF"
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/wordpress
    <Directory /var/www/html/wordpress>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHEEOF
a2enmod rewrite && systemctl restart apache2'
    }
    run_step "Konfigurasi Apache + mod_rewrite" _setup_apache

    # Step 11: Health check
    _STEP_SEVERITY="recoverable"
    _health_check() {
        if ! pct exec "${VMID}" -- command -v curl &>/dev/null; then
            echo 'curl not found, installing...'
            pct exec "${VMID}" -- apt-get install -y curl
        fi
        local http_code
        http_code=$(pct exec "${VMID}" -- curl -so /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1 2>/dev/null || echo 000)
        if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
            echo "WordPress responding (HTTP $http_code)"
            return 0
        else
            echo "HTTP $http_code — WordPress belum merespons dengan benar. Cek manual: curl -I http://${ip_clean}"
            return 2
        fi
    }
    run_step "Health check WordPress" _health_check

    # Selesai
    INSTALL_SUCCESS=true
    local total_elapsed
    total_elapsed=$(format_time $(( $(date +%s) - INSTALL_START )))

    echo ""
    if $FANCY; then
        echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${GREEN}${BOLD}  ✓  INSTALLATION COMPLETE${NC}"
        echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "  ${GREEN}==================================================${NC}"
        echo -e "  ${GREEN}${BOLD}  [OK]  INSTALLATION COMPLETE${NC}"
        echo -e "  ${GREEN}==================================================${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}CT ID${NC}         ${VMID}"
    echo -e "  ${BOLD}Hostname${NC}      ${HOSTNAME}"
    echo -e "  ${BOLD}IP Address${NC}    ${ip_clean}"
    echo -e "  ${BOLD}Duration${NC}      ${total_elapsed}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}! Save credential ini — tidak akan ditampilkan lagi.${NC}"
    echo -e "  ${BOLD}Password CT${NC}   ${YELLOW}${PASSWORD}${NC}"
    echo -e "  ${BOLD}DB Name${NC}       ${DB_NAME}"
    echo -e "  ${BOLD}DB User${NC}       ${DB_USER}"
    echo -e "  ${BOLD}DB Password${NC}   ${YELLOW}${DB_PASS}${NC}"
    echo ""
    if $FANCY; then
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "  ${DIM}--------------------------------------------------${NC}"
    fi
    echo -e "  Open your browser:"
    echo ""
    echo -e "    ${CYAN}${BOLD}→  http://${ip_clean}${NC}"
    echo ""
    if $FANCY; then
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "  ${DIM}--------------------------------------------------${NC}"
    fi
    echo -e "  ${DIM}Full log: ${LOG_FILE}${NC}"
    echo ""
}
main() {
    if ! command -v pct &>/dev/null; then
        echo "Error: pct tidak ditemukan. Script harus dijalankan di Proxmox host." >&2
        exit 1
    fi

    show_banner
    gather_input
    show_summary
    $DRY_RUN && show_dry_run
    confirm_proceed
    run_install
}

main