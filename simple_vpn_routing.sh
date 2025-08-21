#!/bin/bash
"""
Basit VPN Routing - Herşey VPN'e, SSH/Panel Korunur
SSH ve panel dışında TÜM TRAFİK VPN'e gider
"""

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "Root olarak çalıştır!"
   exit 1
fi

log "🚀 Basit VPN Routing kuruluyor..."

# 1. Get current connection info
SSH_CLIENT_IP=$(echo $SSH_CLIENT | cut -d' ' -f1)
CURRENT_IP=$(hostname -I | awk '{print $1}')
MAIN_INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}')

log "🔍 Mevcut bağlantı bilgileri:"
log "   SSH Client IP: $SSH_CLIENT_IP"
log "   Server IP: $CURRENT_IP"
log "   Ana Interface: $MAIN_INTERFACE"

# 2. Setup routing table
if ! grep -q "vpn_table" /etc/iproute2/rt_tables; then
    echo "200 vpn_table" >> /etc/iproute2/rt_tables
fi

# 3. Clear existing rules
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

# 4. Create main VPN routing chain
iptables -t mangle -N VPN_ALL
iptables -t mangle -A OUTPUT -j VPN_ALL

log "🛡️ SSH ve Panel koruması ekleniyor..."

# 5. KORUMA - SSH ve Panel Trafiği (RETURN = VPN'e GİTMEZ)
iptables -t mangle -A VPN_ALL -p tcp --dport 22 -j RETURN                    # SSH
iptables -t mangle -A VPN_ALL -p tcp --sport 22 -j RETURN                    # SSH response
iptables -t mangle -A VPN_ALL -p tcp --dport 3000 -j RETURN                  # Panel
iptables -t mangle -A VPN_ALL -p tcp --sport 3000 -j RETURN                  # Panel response

# SSH client IP'si tamamen korunur
if [[ -n "$SSH_CLIENT_IP" ]]; then
    iptables -t mangle -A VPN_ALL -s $SSH_CLIENT_IP -j RETURN
    iptables -t mangle -A VPN_ALL -d $SSH_CLIENT_IP -j RETURN
fi

# Loopback korunur
iptables -t mangle -A VPN_ALL -o lo -j RETURN

# DNS korunur (opsiyonel - VPN DNS de kullanabilirsin)
iptables -t mangle -A VPN_ALL -p udp --dport 53 -j RETURN

log "🔄 VPN routing ekleniyor..."

# 6. GERİ KALAN HER ŞEY VPN'E - Outbound traffic mark et
iptables -t mangle -A VPN_ALL -j MARK --set-mark 100

# 7. Marked traffic'i VPN table'a yönlendir
ip rule add fwmark 100 table vpn_table priority 100

log "✅ VPN routing kuruldu!"
log ""
log "🎯 Artık şunlar olacak:"
log "   ✅ SSH (port 22) ana IP'den gidecek"
log "   ✅ Panel (port 3000) ana IP'den gidecek"  
log "   ✅ SSH client IP'niz ($SSH_CLIENT_IP) korunacak"
log "   🔄 DİĞER HER ŞEY VPN'den gidecek"
log ""
log "💡 Botlarınızı normal şekilde çalıştırın, otomatik VPN'e gidecek:"
log "   nuclei -t /root/nuclei-templates -u target.com"
log "   wpscan --url http://target.com" 
log "   node /path/to/bot.js"
log "   python3 scanner.py"
log "   curl http://anything.com"
log ""
log "🚨 VPN bağlanınca routing otomatik aktif olacak!"

# 8. Save rules
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

log "🎉 Kurulum tamamlandı! VPN'i başlat ve test et."
