#!/bin/bash
"""
VPN Rotation System - Ana Kurulum Script
Tüm sistemi otomatik olarak kurar ve yapılandırır
"""

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

title() {
    echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Bu script root olarak çalıştırılmalı!"
        echo "Şu komutu kullanın: sudo bash install.sh"
        exit 1
    fi
}

# Backup current configuration
backup_config() {
    title "Mevcut Konfigürasyon Yedekleniyor"
    
    backup_dir="/root/vpn_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # Backup important files
    [[ -f /etc/iptables/rules.v4 ]] && cp /etc/iptables/rules.v4 "$backup_dir/"
    [[ -f /etc/iproute2/rt_tables ]] && cp /etc/iproute2/rt_tables "$backup_dir/"
    
    log "Yedek oluşturuldu: $backup_dir"
}

# Install required packages
install_packages() {
    title "Gerekli Paketler Kuruluyor"
    
    apt-get update > /dev/null
    apt-get install -y \
        openvpn \
        iptables-persistent \
        iproute2 \
        curl \
        jq \
        python3 \
        python3-pip \
        systemd \
        logrotate > /dev/null
    
    # Install Python packages
    pip3 install requests > /dev/null
    
    log "Tüm paketler başarıyla kuruldu"
}

# Setup directories and permissions
setup_directories() {
    title "Dizinler ve İzinler Ayarlanıyor"
    
    # Create OpenVPN directory
    mkdir -p /etc/openvpn
    
    # Create log directory
    mkdir -p /var/log
    touch /var/log/vpn_rotation.log
    chmod 644 /var/log/vpn_rotation.log
    
    # Copy VPN configs
    local source_dir="/Users/muratkara/vpn/mullvad_config_linux"
    
    if [[ -d "$source_dir" ]]; then
        log "Mullvad konfigürasyonları kopyalanıyor..."
        cp -r "$source_dir"/* /etc/openvpn/
        chmod 600 /etc/openvpn/mullvad_userpass.txt
        chmod +x /etc/openvpn/update-resolv-conf
        log "VPN konfigürasyonları kopyalandı"
    else
        error "VPN konfigürasyon dizini bulunamadı: $source_dir"
        exit 1
    fi
    
    # Copy scripts
    cp /Users/muratkara/vpn/vpn_rotation_manager.py /usr/local/bin/
    
    chmod +x /usr/local/bin/vpn_rotation_manager.py
    
    log "Script'ler /usr/local/bin/ dizinine kopyalandı"
}

# Run routing setup
setup_routing() {
    title "VPN Routing Yapılandırılıyor"
    
    bash /Users/muratkara/vpn/simple_vpn_routing.sh
    
    log "VPN routing yapılandırması tamamlandı"
}

# Verify installation
verify_installation() {
    title "Kurulum Doğrulanıyor"
    
    local errors=0
    
    # Check files
    local required_files=(
        "/usr/local/bin/vpn_rotation_manager.py"
        "/etc/openvpn/mullvad_userpass.txt"
        "/etc/systemd/system/vpn-rotation.service"
        "/usr/local/bin/vpn-status.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [[ -f "$file" ]]; then
            log "✓ $file"
        else
            error "✗ $file eksik!"
            ((errors++))
        fi
    done
    
    # Check services
    if systemctl is-enabled vpn-rotation.service > /dev/null 2>&1; then
        log "✓ vpn-rotation.service enabled"
    else
        error "✗ vpn-rotation.service not enabled"
        ((errors++))
    fi
    
    # Check user
    if id botuser > /dev/null 2>&1; then
        log "✓ botuser oluşturuldu"
    else
        error "✗ botuser oluşturulamadı"
        ((errors++))
    fi
    
    # Check routing tables
    if grep -q "vpn_primary" /etc/iproute2/rt_tables; then
        log "✓ Routing tables konfigürasyonu"
    else
        error "✗ Routing tables problemi"
        ((errors++))
    fi
    
    return $errors
}

# Show final instructions
show_instructions() {
    title "Kurulum Tamamlandı!"
    
    echo -e "${GREEN}VPN Rotation System başarıyla kuruldu!${NC}\n"
    
    echo -e "${BOLD}Sistem Başlatma:${NC}"
    echo "systemctl start vpn-rotation.service"
    echo "systemctl status vpn-rotation.service"
    echo ""
    
    echo -e "${BOLD}Durum Kontrolü:${NC}"
    echo "/usr/local/bin/vpn-status.sh"
    echo ""
    
    echo -e "${BOLD}Bot Çalıştırma Örnekleri:${NC}"
    echo "nuclei -t /root/nuclei-templates -u target.com"
    echo "wpscan --url http://target.com"
    echo "node /path/to/your/bot.js"
    echo "python3 /path/to/scanner.py"
    echo ""
    
    echo -e "${BOLD}Loglar:${NC}"
    echo "tail -f /var/log/vpn_rotation.log"
    echo "journalctl -u vpn-rotation.service -f"
    echo ""
    
    echo -e "${YELLOW}ÖNEMLİ:${NC}"
    echo "• SSH ve panel erişimi (port 22, 3000) mevcut IP'nizde kalacak"
    echo "• Bot trafiği VPN üzerinden gidecek"
    echo "• VPN her 30 dakikada otomatik değişecek"
    echo "• Sistem her 5 dakikada VPN sağlığını kontrol edecek"
    echo ""
    
    warn "Sistemi başlatmak için: systemctl start vpn-rotation.service"
}

# Main installation process
main() {
    title "VPN Rotation System Kurulumu Başlıyor"
    
    log "Kurulum başlatılıyor..."
    
    check_root
    backup_config
    install_packages
    setup_directories
    setup_routing
    
    if verify_installation; then
        show_instructions
        
        echo -e "\n${GREEN}Kurulum başarıyla tamamlandı!${NC}"
        echo -e "${YELLOW}Şimdi 'systemctl start vpn-rotation.service' komutunu çalıştırın.${NC}"
    else
        error "Kurulum sırasında hatalar oluştu!"
        echo "Lütfen hataları düzeltin ve tekrar deneyin."
        exit 1
    fi
}

# Run installation
main "$@"
