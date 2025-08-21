#!/bin/bash
"""
Bot Wrapper Script - VPN Üzerinden Bot Çalıştırma
Bu script mevcut botlarınızı VPN trafiği üzerinden çalıştırır
"""

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Function to show usage
show_usage() {
    echo "Bot Wrapper - VPN üzerinden bot çalıştırma"
    echo ""
    echo "Kullanım:"
    echo "  $0 nuclei [nuclei_options]"
    echo "  $0 wpscan [wpscan_options]"
    echo "  $0 node [js_file] [node_options]"
    echo "  $0 custom [command]"
    echo "  $0 status"
    echo "  $0 test-vpn"
    echo ""
    echo "Örnekler:"
    echo "  $0 nuclei -t /root/nuclei-templates -u target.com"
    echo "  $0 wpscan --url http://target.com --enumerate ap"
    echo "  $0 node /path/to/your/bot.js"
    echo "  $0 custom 'python3 /path/to/scanner.py'"
    echo ""
}

# Function to check VPN connection
check_vpn() {
    log "VPN bağlantısı test ediliyor..."
    
    # Check if tun0 interface exists
    if ! ip link show tun0 > /dev/null 2>&1; then
        error "VPN interface (tun0) bulunamadı!"
        error "Önce VPN rotation service'ini başlatın: systemctl start vpn-rotation.service"
        exit 1
    fi
    
    # Test external IP through VPN
    VPN_IP=$(curl -s --interface tun0 --max-time 10 https://ipecho.net/plain || echo "FAILED")
    MAIN_IP=$(curl -s --max-time 10 https://ipecho.net/plain || echo "FAILED")
    
    if [[ "$VPN_IP" == "FAILED" ]]; then
        error "VPN üzerinden internet erişimi yok!"
        exit 1
    fi
    
    if [[ "$VPN_IP" != "$MAIN_IP" ]]; then
        log "VPN çalışıyor! VPN IP: $VPN_IP, Ana IP: $MAIN_IP"
        return 0
    else
        warn "VPN IP ana IP ile aynı. Routing problemi olabilir."
        return 1
    fi
}

# Function to run command as botuser through VPN
run_with_vpn() {
    local cmd="$1"
    
    info "Komut VPN üzerinden çalıştırılıyor: $cmd"
    
    # Set environment for VPN routing
    export FORCE_VPN=1
    
    # Run command as botuser to ensure VPN routing
    if [[ $EUID -eq 0 ]]; then
        # Running as root, switch to botuser
        sudo -u botuser -E bash -c "
            export PATH=/usr/local/bin:/usr/bin:/bin
            export FORCE_VPN=1
            cd $(pwd)
            $cmd
        "
    else
        # Already running as non-root, check if we're botuser
        current_user=$(whoami)
        if [[ "$current_user" != "botuser" ]]; then
            warn "Şu anda $current_user olarak çalışıyorsunuz. VPN routing için botuser kullanılması önerilir."
            warn "Root olarak şu komutu çalıştırın: sudo $0 $*"
        fi
        
        # Run directly
        bash -c "$cmd"
    fi
}

# Function to show current status
show_status() {
    echo "=== Bot Wrapper & VPN Status ==="
    
    # VPN service status
    echo -e "\n${BLUE}VPN Rotation Service:${NC}"
    if systemctl is-active --quiet vpn-rotation.service; then
        echo -e "${GREEN}✓ Active${NC}"
    else
        echo -e "${RED}✗ Inactive${NC}"
    fi
    
    # VPN interfaces
    echo -e "\n${BLUE}VPN Interfaces:${NC}"
    if ip link show tun0 > /dev/null 2>&1; then
        tun0_ip=$(ip addr show tun0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
        echo -e "${GREEN}✓ tun0: $tun0_ip${NC}"
    else
        echo -e "${RED}✗ tun0: Not connected${NC}"
    fi
    
    if ip link show tun1 > /dev/null 2>&1; then
        tun1_ip=$(ip addr show tun1 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
        echo -e "${GREEN}✓ tun1: $tun1_ip${NC}"
    else
        echo -e "${YELLOW}- tun1: Not connected (secondary)${NC}"
    fi
    
    # External IPs
    echo -e "\n${BLUE}External IPs:${NC}"
    main_ip=$(curl -s --max-time 5 https://ipecho.net/plain || echo "Failed")
    echo "Ana IP: $main_ip"
    
    if ip link show tun0 > /dev/null 2>&1; then
        vpn_ip=$(curl -s --interface tun0 --max-time 5 https://ipecho.net/plain || echo "Failed")
        echo "VPN IP: $vpn_ip"
        
        if [[ "$main_ip" != "$vpn_ip" && "$vpn_ip" != "Failed" ]]; then
            echo -e "${GREEN}✓ VPN routing çalışıyor${NC}"
        else
            echo -e "${RED}✗ VPN routing problemi${NC}"
        fi
    fi
    
    # Recent logs
    echo -e "\n${BLUE}Son VPN Rotation Logları:${NC}"
    tail -5 /var/log/vpn_rotation.log 2>/dev/null || echo "Log dosyası bulunamadı"
    
    # Active bot processes
    echo -e "\n${BLUE}Aktif Bot Süreçleri:${NC}"
    ps aux | grep -E "(nuclei|wpscan|node)" | grep -v grep | head -10 || echo "Aktif bot süreci yok"
}

# Function to test VPN routing
test_vpn_routing() {
    log "VPN routing test ediliyor..."
    
    # Test 1: Check interfaces
    if ! ip link show tun0 > /dev/null 2>&1; then
        error "tun0 interface yok!"
        return 1
    fi
    
    # Test 2: Check routing rules
    if ! ip rule list | grep -q "fwmark 0x64"; then
        error "VPN routing kuralları eksik!"
        return 1
    fi
    
    # Test 3: Test external IP through VPN
    info "Normal bağlantı IP'si test ediliyor..."
    normal_ip=$(curl -s --max-time 10 https://httpbin.org/ip | jq -r .origin || echo "FAILED")
    
    info "VPN üzerinden IP test ediliyor..."
    vpn_ip=$(sudo -u botuser curl -s --max-time 10 https://httpbin.org/ip | jq -r .origin || echo "FAILED")
    
    echo "Normal IP: $normal_ip"
    echo "VPN IP: $vpn_ip"
    
    if [[ "$normal_ip" != "$vpn_ip" && "$vpn_ip" != "FAILED" ]]; then
        log "✓ VPN routing başarılı! Botlar farklı IP kullanıyor."
        return 0
    else
        error "✗ VPN routing çalışmıyor!"
        return 1
    fi
}

# Main script logic
case "${1:-}" in
    "nuclei")
        check_vpn
        shift
        run_with_vpn "nuclei $*"
        ;;
    "wpscan")
        check_vpn
        shift
        run_with_vpn "wpscan $*"
        ;;
    "node")
        check_vpn
        shift
        run_with_vpn "node $*"
        ;;
    "custom")
        check_vpn
        shift
        run_with_vpn "$*"
        ;;
    "status")
        show_status
        ;;
    "test-vpn")
        test_vpn_routing
        ;;
    "help"|"-h"|"--help")
        show_usage
        ;;
    *)
        error "Geçersiz komut: ${1:-}"
        echo ""
        show_usage
        exit 1
        ;;
esac
