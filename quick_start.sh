#!/bin/bash
"""
VPN Rotation System - Hızlı Başlatma Script'i
Tek komutla sistemi kurar ve çalıştırır
"""

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════════╗"
echo "║        VPN ROTATION SYSTEM v1.0          ║"
echo "║         Hızlı Kurulum & Başlatma         ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Bu script root olarak çalıştırılmalı!${NC}"
    echo "Kullanım: sudo bash quick_start.sh"
    exit 1
fi

echo -e "${YELLOW}⚠️  DİKKAT: Bu script sisteminizde değişiklikler yapacak!${NC}"
echo -e "${YELLOW}   - VPN konfigürasyonları kurulacak${NC}"
echo -e "${YELLOW}   - Ağ routing kuralları değiştirilecek${NC}"
echo -e "${YELLOW}   - Systemd service'leri eklenerek${NC}"
echo ""

read -p "Devam etmek istiyor musunuz? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Kurulum iptal edildi."
    exit 0
fi

echo ""
echo -e "${GREEN}🚀 Kurulum başlatılıyor...${NC}"
echo ""

# Step 1: Install system
echo -e "${BLUE}📦 Sistem kuruluyor...${NC}"
if bash install.sh > /tmp/install.log 2>&1; then
    echo -e "${GREEN}✅ Kurulum tamamlandı${NC}"
else
    echo -e "${RED}❌ Kurulum hatası!${NC}"
    echo "Hata detayları:"
    tail -20 /tmp/install.log
    exit 1
fi

# Step 2: Start service
echo -e "${BLUE}🔧 Servis başlatılıyor...${NC}"
systemctl start vpn-rotation.service

# Wait for service to initialize
sleep 5

# Step 3: Check status
echo -e "${BLUE}🔍 Sistem durumu kontrol ediliyor...${NC}"

if systemctl is-active --quiet vpn-rotation.service; then
    echo -e "${GREEN}✅ VPN Rotation servisi aktif${NC}"
else
    echo -e "${RED}❌ VPN Rotation servisi başlatılamadı${NC}"
    echo "Servis logları:"
    journalctl -u vpn-rotation.service --no-pager -l | tail -10
    exit 1
fi

# Wait for VPN connection
echo -e "${BLUE}🌐 VPN bağlantısı bekleniyor...${NC}"
for i in {1..30}; do
    if ip link show tun0 > /dev/null 2>&1; then
        echo -e "${GREEN}✅ VPN interface (tun0) hazır${NC}"
        break
    fi
    echo -n "."
    sleep 1
done

if ! ip link show tun0 > /dev/null 2>&1; then
    echo -e "${RED}❌ VPN bağlantısı kurulamadı${NC}"
    echo "VPN logları:"
    tail -10 /var/log/vpn_rotation.log
    exit 1
fi

# Test VPN routing
echo -e "${BLUE}🧪 VPN routing test ediliyor...${NC}"

# Get IPs
normal_ip=$(curl -s --max-time 10 https://ipecho.net/plain || echo "FAILED")
vpn_ip=$(sudo -u botuser curl -s --max-time 10 https://ipecho.net/plain || echo "FAILED")

echo "Ana IP: $normal_ip"
echo "Bot IP (VPN): $vpn_ip"

if [[ "$normal_ip" != "$vpn_ip" && "$vpn_ip" != "FAILED" ]]; then
    echo -e "${GREEN}✅ VPN routing başarılı!${NC}"
else
    echo -e "${YELLOW}⚠️  VPN routing henüz hazır değil, birkaç dakika bekleyin${NC}"
fi

# Final status
echo ""
echo -e "${BOLD}${GREEN}🎉 KURULUM TAMAMLANDI!${NC}"
echo ""
echo -e "${BOLD}📋 Sistem Durumu:${NC}"
/usr/local/bin/vpn-status.sh | head -20

echo ""
echo -e "${BOLD}🤖 Bot Çalıştırma Örnekleri:${NC}"
echo "bot_wrapper.sh nuclei -t /root/nuclei-templates -u target.com"
echo "bot_wrapper.sh wpscan --url http://target.com"
echo "bot_wrapper.sh node /path/to/your/bot.js"
echo ""

echo -e "${BOLD}📊 Yararlı Komutlar:${NC}"
echo "bot_wrapper.sh status           # Sistem durumu"
echo "bot_wrapper.sh test-vpn         # VPN testi"
echo "/usr/local/bin/vpn-status.sh    # Detaylı durum"
echo "tail -f /var/log/vpn_rotation.log  # Canlı loglar"
echo ""

echo -e "${GREEN}✨ Sistem hazır! Botlarınızı güvenle çalıştırabilirsiniz.${NC}"
echo ""
echo -e "${YELLOW}💡 İpucu: SSH ve admin paneli ($normal_ip:3000) erişimi korundu.${NC}"
echo -e "${YELLOW}   Bot trafiği artık VPN ($vpn_ip) üzerinden gidiyor.${NC}"

# Optional: Run a quick test
echo ""
read -p "Hızlı VPN testi yapmak ister misiniz? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${BLUE}🧪 VPN testi çalıştırılıyor...${NC}"
    bot_wrapper.sh test-vpn
fi

echo ""
echo -e "${BOLD}${GREEN}🚀 Başarılı! Sisteminiz hazır.${NC}"
