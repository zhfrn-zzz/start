#!/bin/bash

# ============================================================
#  Proxmox CT Creator + WordPress Auto Installer v2.0
#  Mode: Quick Install & Custom Install
# ============================================================

# ─── WARNA ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

# ─── KONFIGURASI PROXMOX (sesuaikan jika berbeda) ────────────
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
BRIDGE="vmbr0"

# ─── HELPER: OUTPUT ──────────────────────────────────────────
log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}─── $1 ───────────────────────────────────────${NC}"; }

# ─── HELPER: INPUT ───────────────────────────────────────────
INPUT_RESULT=""

get_input() {
    # $1 = label prompt
    # $2 = default value (opsional, Enter = pakai default)
    # $3 = nama fungsi validator (opsional)
    # $4 = "yes" untuk hide input (password)
    local prompt="$1"
    local default="$2"
    local validator="$3"
    local hide="$4"

    while true; do
        local display
        if [ -n "$default" ]; then
            if [ "$hide" = "yes" ]; then
                display="  ➜ $prompt [default: ****]: "
            else
                display="  ➜ $prompt [default: $default]: "
            fi
        else
            display="  ➜ $prompt: "
        fi

        if [ "$hide" = "yes" ]; then
            read -s -p "$display" INPUT_RESULT
            echo ""
        else
            read -p "$display" INPUT_RESULT
        fi

        # Gunakan default jika kosong
        INPUT_RESULT="${INPUT_RESULT:-$default}"

        # Cek tidak boleh kosong
        if [ -z "$INPUT_RESULT" ]; then
            echo -e "  ${RED}  Field ini tidak boleh kosong. Coba lagi.${NC}"
            continue
        fi

        # Jalankan validator jika ada
        if [ -n "$validator" ]; then
            if ! $validator "$INPUT_RESULT"; then
                continue
            fi
        fi

        break
    done
}

# ─── VALIDATOR ───────────────────────────────────────────────
validate_vmid() {
    local vmid="$1"
    if ! [[ "$vmid" =~ ^[0-9]+$ ]] || [ "$vmid" -lt 100 ]; then
        echo -e "  ${RED}  VMID harus berupa angka >= 100. Coba lagi.${NC}"
        return 1
    fi
    if pct status "$vmid" &>/dev/null 2>&1; then
        echo -e "  ${RED}  CT $vmid sudah ada! Gunakan VMID lain.${NC}"
        return 1
    fi
    return 0
}

validate_number() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ]; then
        echo -e "  ${RED}  Harus berupa angka positif. Coba lagi.${NC}"
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

# ─── DERIVE GATEWAY OTOMATIS ─────────────────────────────────
derive_gateway() {
    local ip="${1%/*}"
    echo "$(echo "$ip" | cut -d. -f1-3).1"
}

# ─── CEK & DOWNLOAD TEMPLATE ─────────────────────────────────
check_template() {
    local path="/var/lib/vz/template/cache/$TEMPLATE"
    if [ ! -f "$path" ]; then
        warn "Template '$TEMPLATE' tidak ditemukan."
        info "Mengunduh template otomatis dari repositori Proxmox..."
        pveam update || error "Gagal update daftar template"
        pveam download $TEMPLATE_STORAGE $TEMPLATE || error "Gagal mengunduh template"
        log "Template berhasil diunduh"
    else
        log "Template ditemukan"
    fi
}

# ─── RINGKASAN KONFIGURASI ───────────────────────────────────
show_summary() {
    local ip_clean="${IP%/*}"
    local pass_mask
    pass_mask=$(echo "$PASSWORD" | sed 's/./*/g')
    local dbpass_mask
    dbpass_mask=$(echo "$DB_PASS" | sed 's/./*/g')

    echo ""
    echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}${BOLD}│           RINGKASAN KONFIGURASI              │${NC}"
    echo -e "${CYAN}${BOLD}├──────────────────┬───────────────────────────┤${NC}"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "VMID"       "$VMID"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "Hostname"   "$HOSTNAME"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "Password"   "$pass_mask"
    echo -e "${CYAN}│──────────────────│───────────────────────────│${NC}"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "Disk"       "${DISK} GB"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "CPU"        "${CPU} core"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "Memory"     "${MEMORY} MB"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "Swap"       "${SWAP} MB"
    echo -e "${CYAN}│──────────────────│───────────────────────────│${NC}"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "IP Address" "$IP"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "Gateway"    "$GW"
    echo -e "${CYAN}│──────────────────│───────────────────────────│${NC}"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "DB Name"    "$DB_NAME"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "DB User"    "$DB_USER"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "DB Pass"    "$dbpass_mask"
    echo -e "${CYAN}│──────────────────│───────────────────────────│${NC}"
    printf "${CYAN}│${NC}  %-16s ${CYAN}│${NC}  %-25s ${CYAN}│${NC}\n" "URL Akses"  "http://$ip_clean"
    echo -e "${CYAN}${BOLD}└──────────────────┴───────────────────────────┘${NC}"
    echo ""
}

# ─── KONFIRMASI ──────────────────────────────────────────────
confirm_proceed() {
    while true; do
        read -p "  ➜ Lanjutkan instalasi? (y/n): " answer
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)
                warn "Instalasi dibatalkan."
                exit 0
                ;;
            *) echo -e "  ${RED}  Ketik y untuk lanjut atau n untuk batal.${NC}" ;;
        esac
    done
}

# ─── MODE: QUICK INSTALL ─────────────────────────────────────
quick_install() {
    section "Quick Install"
    echo ""
    info "Disk/CPU/Memory/Swap & DB menggunakan nilai default"
    info "Hanya perlu isi: VMID, Hostname, Password CT, dan IP"
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
    info "Gateway otomatis diset ke: $GW"

    # Semua nilai lain pakai default
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

    # ── Identitas CT
    info "[ Identitas Container ]"
    get_input "VMID" "$DEFAULT_VMID" "validate_vmid"
    VMID="$INPUT_RESULT"

    get_input "Hostname" "$DEFAULT_HOSTNAME"
    HOSTNAME="$INPUT_RESULT"

    get_input "Password CT" "$DEFAULT_PASSWORD" "" "yes"
    PASSWORD="$INPUT_RESULT"

    # ── Spesifikasi (skippable)
    echo ""
    info "[ Spesifikasi ] Tekan Enter untuk pakai nilai default"

    get_input "Disk (GB)" "$DEFAULT_DISK" "validate_number"
    DISK="$INPUT_RESULT"

    get_input "CPU (core)" "$DEFAULT_CPU" "validate_number"
    CPU="$INPUT_RESULT"

    get_input "Memory (MB)" "$DEFAULT_MEMORY" "validate_number"
    MEMORY="$INPUT_RESULT"

    get_input "Swap (MB)" "$DEFAULT_SWAP" "validate_number"
    SWAP="$INPUT_RESULT"

    # ── Jaringan
    echo ""
    info "[ Jaringan ]"

    get_input "IP Address (contoh: 192.168.10.5/24)" "" "validate_ip_cidr"
    IP="$INPUT_RESULT"

    local suggested_gw
    suggested_gw=$(derive_gateway "$IP")
    get_input "Gateway" "$suggested_gw" "validate_ip"
    GW="$INPUT_RESULT"

    # ── Database WordPress
    echo ""
    info "[ Database WordPress ] Tekan Enter untuk pakai nilai default"

    get_input "DB Name" "$DEFAULT_DB_NAME"
    DB_NAME="$INPUT_RESULT"

    get_input "DB User" "$DEFAULT_DB_USER"
    DB_USER="$INPUT_RESULT"

    get_input "DB Password" "$DEFAULT_DB_PASS" "" "yes"
    DB_PASS="$INPUT_RESULT"
}

# ─── PROSES INSTALASI ────────────────────────────────────────
run_install() {
    section "Memulai Proses Instalasi"
    echo ""

    # Root check
    [ "$EUID" -ne 0 ] && error "Script harus dijalankan sebagai root di Proxmox host"

    # Cek / download template
    check_template

    # Buat CT
    log "Membuat CT $VMID ($HOSTNAME)..."
    pct create $VMID \
        $TEMPLATE_STORAGE:vztmpl/$TEMPLATE \
        --hostname "$HOSTNAME" \
        --password "$PASSWORD" \
        --rootfs $STORAGE:$DISK \
        --cores $CPU \
        --memory $MEMORY \
        --swap $SWAP \
        --net0 name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GW \
        --unprivileged 1 \
        --features nesting=1 \
        --ostype ubuntu \
        --start 0 || error "Gagal membuat CT"

    log "Menjalankan CT..."
    pct start $VMID

    log "Menunggu CT siap (15 detik)..."
    sleep 15

    # Update & Upgrade
    section "apt update & upgrade"
    pct exec $VMID -- bash -c "apt-get update -y" \
        || error "apt-get update gagal"
    pct exec $VMID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" \
        || error "apt-get upgrade gagal"
    log "Update & upgrade selesai"

    # Install LAMP
    section "Install LAMP Stack"
    pct exec $VMID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        apache2 \
        mysql-server \
        php \
        php-mysql \
        php-curl \
        php-gd \
        php-mbstring \
        php-xml \
        php-zip \
        libapache2-mod-php" || error "Instalasi LAMP gagal"
    log "Apache, MySQL, PHP berhasil diinstall"

    # Setup Database
    section "Setup Database MySQL"
    pct exec $VMID -- bash -c "mysql -e \"CREATE DATABASE $DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"" \
        || error "Gagal membuat database '$DB_NAME'"
    pct exec $VMID -- bash -c "mysql -e \"CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';\"" \
        || error "Gagal membuat user '$DB_USER'"
    pct exec $VMID -- bash -c "mysql -e \"GRANT ALL ON $DB_NAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;\"" \
        || error "Gagal set privileges"
    log "Database '$DB_NAME' dan user '$DB_USER' berhasil dibuat"

    # Download WordPress
    section "Download & Install WordPress"
    pct exec $VMID -- bash -c "
        cd /tmp && \
        wget -q https://wordpress.org/latest.tar.gz && \
        tar -xzf latest.tar.gz && \
        mv wordpress /var/www/html/ && \
        chown -R www-data:www-data /var/www/html/wordpress && \
        chmod -R 755 /var/www/html/wordpress" || error "Download WordPress gagal"
    log "WordPress berhasil diunduh dan dipasang"

    # wp-config.php
    section "Konfigurasi wp-config.php"
    pct exec $VMID -- bash -c "
        cd /var/www/html/wordpress && \
        cp wp-config-sample.php wp-config.php && \
        sed -i 's|database_name_here|$DB_NAME|' wp-config.php && \
        sed -i 's|username_here|$DB_USER|' wp-config.php && \
        sed -i 's|password_here|$DB_PASS|' wp-config.php" || error "Konfigurasi wp-config gagal"
    log "wp-config.php dikonfigurasi"

    # Apache config
    section "Konfigurasi Apache"
    pct exec $VMID -- bash -c "cat > /etc/apache2/sites-available/000-default.conf << 'APACHEEOF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/wordpress

    <Directory /var/www/html/wordpress>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHEEOF
    a2enmod rewrite && systemctl restart apache2" || error "Konfigurasi Apache gagal"
    log "Apache dikonfigurasi dan direstart"

    # Selesai
    local ip_clean="${IP%/*}"
    echo ""
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}   ✓  INSTALASI SELESAI!                          ${NC}"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}CT ID     :${NC} $VMID"
    echo -e "  ${BOLD}Hostname  :${NC} $HOSTNAME"
    echo -e "  ${BOLD}IP        :${NC} $ip_clean"
    echo ""
    echo -e "  Buka browser dan akses:"
    echo -e "  ${CYAN}${BOLD}http://$ip_clean${NC}"
    echo ""
    echo -e "  Selesaikan wizard WordPress di browser"
    echo -e "  untuk setup nama situs dan akun admin."
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""
}

# ─── MAIN ────────────────────────────────────────────────────
main() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}   Proxmox CT Creator + WordPress Installer v2.0  ${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}[1]${NC} Quick Install   — Setup cepat, minimal pertanyaan"
    echo -e "  ${BOLD}[2]${NC} Custom Install  — Konfigurasi lengkap & fleksibel"
    echo -e "  ${BOLD}[0]${NC} Exit"
    echo ""

    while true; do
        read -p "  ➜ Pilih mode (0/1/2): " choice
        case "$choice" in
            1) quick_install; break ;;
            2) custom_install; break ;;
            0) echo ""; info "Exit."; exit 0 ;;
            *) echo -e "  ${RED}  Pilihan tidak valid. Ketik 1, 2, atau 0.${NC}" ;;
        esac
    done

    show_summary
    confirm_proceed
    run_install
}

main