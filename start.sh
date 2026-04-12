#!/bin/bash

# ============================================================
#  Proxmox CT Creator + WordPress Auto Installer  v3.0
#  Flags: --verbose | --fancy | --dry-run
#  Usage: ./wordpress-ct-setup-v3.sh [--verbose] [--fancy] [--dry-run]
# ============================================================

# ─── FLAG PARSING ────────────────────────────────────────────
VERBOSE=false
FANCY=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=true ;;
        --fancy)   FANCY=true ;;
        --dry-run) DRY_RUN=true ;;
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
LOG_FILE="/tmp/wp-install-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE"

# ─── NILAI DEFAULT ───────────────────────────────────────────
DEFAULT_VMID=105
DEFAULT_HOSTNAME="wordpress"
DEFAULT_PASSWORD="12345678"
DEFAULT_DISK=64
DEFAULT_CPU=4
DEFAULT_MEMORY=2048
DEFAULT_SWAP=2048
DEFAULT_DB_NAME="wordpress"
DEFAULT_DB_USER="wpuser"
DEFAULT_DB_PASS='P@ssw0rd123'

# ─── KONFIGURASI PROXMOX ─────────────────────────────────────
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
BRIDGE="vmbr0"

# ─── STEP TRACKING ───────────────────────────────────────────
TOTAL_STEPS=9
CURRENT_STEP=0
INSTALL_START=0

format_time() {
    local s=$1
    if [ "$s" -lt 60 ]; then
        echo "${s}s"
    else
        echo "$((s/60))m $((s%60))s"
    fi
}

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
    fi
}

# ─── OUTPUT HELPERS ──────────────────────────────────────────
log()  {
    stop_spinner
    echo -e "  ${GREEN}[+]${NC} $1"
    echo "[OK]   $(date '+%H:%M:%S') $1" >> "$LOG_FILE"
}
warn() {
    echo -e "  ${YELLOW}[!]${NC} $1"
    echo "[WARN] $(date '+%H:%M:%S') $1" >> "$LOG_FILE"
}
info() {
    echo -e "  ${BLUE}[i]${NC} $1"
    echo "[INFO] $(date '+%H:%M:%S') $1" >> "$LOG_FILE"
}
error() {
    stop_spinner
    echo -e "\n  ${RED}[x]${NC} ${BOLD}$1${NC}"
    echo "[ERR]  $(date '+%H:%M:%S') $1" >> "$LOG_FILE"
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
# Usage: run_step "Label" "bash command string"
run_step() {
    local label="$1"
    local cmd="$2"
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local prefix="${CURRENT_STEP}/${TOTAL_STEPS}"
    local step_start
    step_start=$(date +%s)

    echo "" >> "$LOG_FILE"
    echo "=== [${prefix}] ${label} ===" >> "$LOG_FILE"

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
        eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
        local exit_code="${PIPESTATUS[0]}"
    else
        start_spinner "[${bar}] ${prefix}  ${label}"
        eval "$cmd" >> "$LOG_FILE" 2>&1
        local exit_code=$?
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
    else
        if $FANCY; then
            echo -e "  ${RED}✗${NC} ${DIM}[${bar}]${NC} ${prefix}  ${label}  ${DIM}${elapsed}${NC}"
        else
            echo -e "  ${RED}[FAIL]${NC} ${DIM}[${bar}]${NC} ${prefix}  ${label}  ${DIM}${elapsed}${NC}"
        fi
        handle_error "$label" "$cmd"
    fi
}

# ─── ERROR RECOVERY ──────────────────────────────────────────
handle_error() {
    local label="$1"
    local cmd="$2"

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

        case "$choice" in
            r|R)
                local t_start
                t_start=$(date +%s)
                if $VERBOSE; then
                    eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
                    local ec="${PIPESTATUS[0]}"
                else
                    start_spinner "Retrying: ${label}"
                    eval "$cmd" >> "$LOG_FILE" 2>&1
                    local ec=$?
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
                warn "Step skipped: ${label}"
                return 0
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
    ██╗  ██╗██████╗      ██████╗████████╗██╗██████╗
    ╚██╗██╔╝██╔══██╗    ██╔════╝╚══██╔══╝██║██╔══██╗
     ╚███╔╝ ██████╔╝    ██║        ██║   ██║██████╔╝
     ██╔██╗ ██╔═══╝     ██║        ██║   ██║██╔═══╝
    ██╔╝ ██╗██║         ╚██████╗   ██║   ██║██║
    ╚═╝  ╚═╝╚═╝          ╚═════╝   ╚═╝   ╚═╝╚═╝
BANNER
        echo -e "${NC}"
        echo -e "  ${BOLD}Proxmox Container + WordPress Installer${NC}  ${DIM}v3.0${NC}"
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${CYAN}${BOLD}"
        cat << 'BANNER'
    __  ______     ________________
    \ \/ / __ \   / ____/_  __/  _/ __ \
     \  / /_/ /  / /     / /  / // /_/ /
     / / ____/  / /___  / / _/ // ____/
    /_/_/        \____/ /_/ /___/_/
BANNER
        echo -e "${NC}"
        echo -e "  ${BOLD}Proxmox Container + WordPress Installer${NC}  ${DIM}v3.0${NC}"
        echo -e "  ${DIM}--------------------------------------------------${NC}"
    fi

    echo ""
    local flags=""
    $VERBOSE && flags+=" ${YELLOW}[verbose]${NC}"
    $FANCY   && flags+=" ${CYAN}[fancy]${NC}"
    $DRY_RUN && flags+=" ${BLUE}[dry-run]${NC}"
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
        pveam update >> "$LOG_FILE" 2>&1 || error "Gagal update daftar template"
        pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >> "$LOG_FILE" 2>&1 \
            || error "Gagal mengunduh template"
        log "Template berhasil diunduh"
    fi
}

# ─── RINGKASAN KONFIGURASI ───────────────────────────────────
show_summary() {
    local ip_clean="${IP%/*}"
    local pass_mask
    pass_mask=$(printf '%s' "$PASSWORD" | sed 's/./*/g')
    local dbpass_mask
    dbpass_mask=$(printf '%s' "$DB_PASS" | sed 's/./*/g')

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
        _row "Password CT"  "$pass_mask"
        echo -e "  ${CYAN}├────────────────────┼──────────────────────────┤${NC}"
        _row "Disk"         "${DISK} GB"
        _row "CPU"          "${CPU} core"
        _row "Memory"       "${MEMORY} MB"
        _row "Swap"         "${SWAP} MB"
        echo -e "  ${CYAN}├────────────────────┼──────────────────────────┤${NC}"
        _row "IP Address"   "$IP"
        _row "Gateway"      "$GW"
        echo -e "  ${CYAN}├────────────────────┼──────────────────────────┤${NC}"
        _row "DB Name"      "$DB_NAME"
        _row "DB User"      "$DB_USER"
        _row "DB Password"  "$dbpass_mask"
        echo -e "  ${CYAN}├────────────────────┼──────────────────────────┤${NC}"
        _row "WordPress URL" "http://${ip_clean}" "$GREEN"
        echo -e "  ${CYAN}└────────────────────┴──────────────────────────┘${NC}"
    else
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        echo -e "  ${CYAN}|${NC} ${BOLD}Parameter${NC}          ${CYAN}|${NC} ${BOLD}Value${NC}                    ${CYAN}|${NC}"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        _row "VMID"         "$VMID"
        _row "Hostname"     "$HOSTNAME"
        _row "Password CT"  "$pass_mask"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        _row "Disk"         "${DISK} GB"
        _row "CPU"          "${CPU} core"
        _row "Memory"       "${MEMORY} MB"
        _row "Swap"         "${SWAP} MB"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        _row "IP Address"   "$IP"
        _row "Gateway"      "$GW"
        echo -e "  ${CYAN}+--------------------+--------------------------+${NC}"
        _row "DB Name"      "$DB_NAME"
        _row "DB User"      "$DB_USER"
        _row "DB Password"  "$dbpass_mask"
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
        "[4/${TOTAL_STEPS}] apt-get update && apt-get upgrade"
        "[5/${TOTAL_STEPS}] Install apache2, mysql-server, php + extensions"
        "[6/${TOTAL_STEPS}] Setup database MySQL: ${DB_NAME} / ${DB_USER}"
        "[7/${TOTAL_STEPS}] Download WordPress + konfigurasi wp-config.php"
        "[8/${TOTAL_STEPS}] Konfigurasi PHP untuk WordPress"
        "[9/${TOTAL_STEPS}] Konfigurasi Apache + aktifkan mod_rewrite"
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

# ─── MODE: QUICK INSTALL ─────────────────────────────────────
quick_install() {
    section "Quick Install"
    echo ""
    info "Disk / CPU / Memory / Swap & DB menggunakan nilai default"
    info "Hanya perlu isi: VMID, Hostname, Password, IP"
    echo ""

    get_input "VMID" "$DEFAULT_VMID" "validate_vmid"
    VMID="$INPUT_RESULT"

    get_input "Hostname" "$DEFAULT_HOSTNAME"
    HOSTNAME="$INPUT_RESULT"

    get_input "Password CT" "$DEFAULT_PASSWORD" "" "yes"
    PASSWORD="$INPUT_RESULT"

    get_input "IP Address (contoh: 192.168.10.5/24)" "" "validate_ip_cidr"
    IP="$INPUT_RESULT"

    GW=$(derive_gateway "$IP")
    info "Gateway otomatis: ${GW}"

    DISK=$DEFAULT_DISK
    CPU=$DEFAULT_CPU
    MEMORY=$DEFAULT_MEMORY
    SWAP=$DEFAULT_SWAP
    DB_NAME=$DEFAULT_DB_NAME
    DB_USER=$DEFAULT_DB_USER
    DB_PASS=$DEFAULT_DB_PASS
}

# ─── MODE: CUSTOM INSTALL ────────────────────────────────────
custom_install() {
    section "Custom Install"
    echo ""

    info "[ Identitas Container ]"
    get_input "VMID" "$DEFAULT_VMID" "validate_vmid"
    VMID="$INPUT_RESULT"

    get_input "Hostname" "$DEFAULT_HOSTNAME"
    HOSTNAME="$INPUT_RESULT"

    get_input "Password CT" "$DEFAULT_PASSWORD" "" "yes"
    PASSWORD="$INPUT_RESULT"

    echo ""
    info "[ Spesifikasi ] Tekan Enter untuk nilai default"

    get_input "Disk (GB)" "$DEFAULT_DISK" "validate_number"
    DISK="$INPUT_RESULT"

    get_input "CPU (core)" "$DEFAULT_CPU" "validate_number"
    CPU="$INPUT_RESULT"

    get_input "Memory (MB)" "$DEFAULT_MEMORY" "validate_number"
    MEMORY="$INPUT_RESULT"

    get_input "Swap (MB)" "$DEFAULT_SWAP" "validate_number"
    SWAP="$INPUT_RESULT"

    echo ""
    info "[ Jaringan ]"

    get_input "IP Address (contoh: 192.168.10.5/24)" "" "validate_ip_cidr"
    IP="$INPUT_RESULT"

    local suggested_gw
    suggested_gw=$(derive_gateway "$IP")
    get_input "Gateway" "$suggested_gw" "validate_ip"
    GW="$INPUT_RESULT"

    echo ""
    info "[ Database WordPress ] Tekan Enter untuk nilai default"

    get_input "DB Name" "$DEFAULT_DB_NAME"
    DB_NAME="$INPUT_RESULT"

    get_input "DB User" "$DEFAULT_DB_USER"
    DB_USER="$INPUT_RESULT"

    get_input "DB Password" "$DEFAULT_DB_PASS" "" "yes"
    DB_PASS="$INPUT_RESULT"
}

# ─── INSTALASI ───────────────────────────────────────────────
run_install() {
    [ "$EUID" -ne 0 ] && error "Script harus dijalankan sebagai root"

    section "Memulai Instalasi"
    INSTALL_START=$(date +%s)
    echo ""

    # Step 1: Template
    run_step "Cek / download template" "check_template"

    # Step 2: Buat CT
    run_step "Membuat CT ${VMID} (${HOSTNAME})" \
        "pct create ${VMID} \
            ${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE} \
            --hostname '${HOSTNAME}' \
            --password '${PASSWORD}' \
            --rootfs ${STORAGE}:${DISK} \
            --cores ${CPU} \
            --memory ${MEMORY} \
            --swap ${SWAP} \
            --net0 name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GW} \
            --unprivileged 1 \
            --features nesting=1 \
            --ostype ubuntu \
            --start 0"

    # Step 3: Start CT
    run_step "Menjalankan CT + tunggu siap" \
        "pct start ${VMID} && sleep 15"

    # Connectivity check
    info "Cek koneksi internet CT..."
    if ! pct exec ${VMID} -- bash -c 'ping -c 2 -W 5 8.8.8.8 &>/dev/null || curl -sf --max-time 10 ifconfig.me &>/dev/null'; then
        error "CT ${VMID} tidak memiliki koneksi internet. Periksa konfigurasi jaringan."
    fi
    log "Koneksi internet CT OK"

    # Step 4: Update & Upgrade
    run_step "apt update && apt upgrade" \
        "pct exec ${VMID} -- bash -c 'apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y'"

    # Step 5: Install LAMP
    run_step "Install LAMP stack (Apache, MySQL, PHP)" \
        "pct exec ${VMID} -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y \
            apache2 mysql-server php php-mysql php-curl php-gd \
            php-mbstring php-xml php-zip libapache2-mod-php'"

    # Step 6: Setup Database
    run_step "Setup database MySQL" \
        "pct exec ${VMID} -- bash -c \"mysql -e \\\"CREATE DATABASE ${DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\\\"\" && \
         pct exec ${VMID} -- bash -c \"mysql -e \\\"CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';\\\"\" && \
         pct exec ${VMID} -- bash -c \"mysql -e \\\"GRANT ALL ON ${DB_NAME}.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;\\\"\""

    # Step 7: WordPress
    run_step "Download & install WordPress" \
        "pct exec ${VMID} -- bash -c '
            cd /tmp && wget -q https://wordpress.org/latest.tar.gz && tar -xzf latest.tar.gz &&
            mv wordpress /var/www/html/ &&
            chown -R www-data:www-data /var/www/html/wordpress &&
            chmod -R 755 /var/www/html/wordpress &&
            cd /var/www/html/wordpress &&
            cp wp-config-sample.php wp-config.php &&
            sed -i \"s|database_name_here|${DB_NAME}|\" wp-config.php &&
            sed -i \"s|username_here|${DB_USER}|\" wp-config.php &&
            sed -i \"s|password_here|${DB_PASS}|\" wp-config.php'"

    # Step 8: PHP Config
    run_step "Konfigurasi PHP untuk WordPress" \
        "pct exec ${VMID} -- bash -c '
            sed -i \"s/upload_max_filesize = .*/upload_max_filesize = 64M/\" /etc/php/*/apache2/php.ini &&
            sed -i \"s/post_max_size = .*/post_max_size = 64M/\" /etc/php/*/apache2/php.ini &&
            sed -i \"s/max_execution_time = .*/max_execution_time = 300/\" /etc/php/*/apache2/php.ini &&
            sed -i \"s/memory_limit = .*/memory_limit = 256M/\" /etc/php/*/apache2/php.ini &&
            systemctl restart apache2'"

    # Step 9: Apache
    run_step "Konfigurasi Apache + mod_rewrite" \
        "pct exec ${VMID} -- bash -c 'cat > /etc/apache2/sites-available/000-default.conf << APACHEEOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/wordpress
    <Directory /var/www/html/wordpress>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \\\${APACHE_LOG_DIR}/error.log
    CustomLog \\\${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHEEOF
        a2enmod rewrite && systemctl restart apache2'"

    # Selesai
    local total_elapsed
    total_elapsed=$(format_time $(( $(date +%s) - INSTALL_START )))
    local ip_clean="${IP%/*}"

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

    # Post-install health check
    local http_code
    http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "http://${ip_clean}" 2>/dev/null || echo "000")
    if [ "$http_code" = "200" ] || [ "$http_code" = "301" ]; then
        log "WordPress merespons (HTTP ${http_code})"
    else
        warn "WordPress belum merespons (HTTP ${http_code}). Cek manual: curl -I http://${ip_clean}"
    fi
    echo ""
}
main() {
    show_banner

    if $FANCY; then
        echo -e "  ${BOLD}Select Installation Mode:${NC}"
        echo ""
        echo -e "    ${GREEN}${BOLD}1${NC}  │  Quick Install    ${DIM}─ minimal input, auto defaults${NC}"
        echo -e "    ${BLUE}${BOLD}2${NC}  │  Custom Install   ${DIM}─ full control over config${NC}"
        echo -e "    ${DIM}0${NC}  │  Exit"
    else
        echo -e "  ${BOLD}Select Installation Mode:${NC}"
        echo ""
        echo -e "    ${GREEN}${BOLD}1${NC}  |  Quick Install    ${DIM}-- minimal input, auto defaults${NC}"
        echo -e "    ${BLUE}${BOLD}2${NC}  |  Custom Install   ${DIM}-- full control over config${NC}"
        echo -e "    ${DIM}0${NC}  |  Exit"
    fi
    echo ""

    while true; do
        read -rp "  => Mode (0/1/2): " choice
        case "$choice" in
            1) quick_install; break ;;
            2) custom_install; break ;;
            0) echo ""; info "Exit."; exit 0 ;;
            *) echo -e "  ${RED}Invalid.${NC} Enter 1, 2, or 0." ;;
        esac
    done

    show_summary
    $DRY_RUN && show_dry_run
    confirm_proceed
    run_install
}

main