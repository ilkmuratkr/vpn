#!/bin/bash
"""
VPN Routing Setup Script
Bu script bot trafiğini VPN üzerinden yönlendirir, SSH/Admin paneli trafiğini korur
"""

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

log "Setting up VPN routing for bot traffic isolation..."

# 1. Install required packages
log "Installing required packages..."
apt-get update > /dev/null 2>&1
apt-get install -y openvpn iptables-persistent iproute2 curl > /dev/null 2>&1

# 2. Create bot user if doesn't exist
if ! id "botuser" &>/dev/null; then
    log "Creating botuser for traffic isolation..."
    useradd -r -s /bin/false botuser
else
    log "botuser already exists"
fi

# 3. Setup custom routing tables
log "Setting up custom routing tables..."

# Add custom routing tables to rt_tables if not exist
if ! grep -q "vpn_primary" /etc/iproute2/rt_tables; then
    echo "100 vpn_primary" >> /etc/iproute2/rt_tables
fi

if ! grep -q "vpn_secondary" /etc/iproute2/rt_tables; then
    echo "101 vpn_secondary" >> /etc/iproute2/rt_tables
fi

# 4. Configure iptables for traffic marking
log "Configuring iptables rules..."

# Create VPN_ROUTING chain if doesn't exist
if ! iptables -t mangle -L VPN_ROUTING > /dev/null 2>&1; then
    iptables -t mangle -N VPN_ROUTING
fi

# Clear existing rules in VPN_ROUTING chain
iptables -t mangle -F VPN_ROUTING

# Add VPN_ROUTING to OUTPUT chain if not exists
if ! iptables -t mangle -C OUTPUT -j VPN_ROUTING 2>/dev/null; then
    iptables -t mangle -A OUTPUT -j VPN_ROUTING
fi

# 5. Get current SSH connection details to preserve
SSH_CLIENT_IP=$(echo $SSH_CLIENT | cut -d' ' -f1)
CURRENT_IP=$(ip route get 8.8.8.8 | head -1 | cut -d' ' -f7)
MAIN_INTERFACE=$(ip route | grep default | head -1 | cut -d' ' -f5)

log "Detected SSH client IP: $SSH_CLIENT_IP"
log "Current server IP: $CURRENT_IP" 
log "Main interface: $MAIN_INTERFACE"

# 6. Preserve SSH and admin panel access
log "Setting up SSH and admin panel protection..."

# Preserve SSH connections (port 22)
iptables -t mangle -A VPN_ROUTING -p tcp --dport 22 -j RETURN
iptables -t mangle -A VPN_ROUTING -p tcp --sport 22 -j RETURN

# Preserve admin panel (port 3000) 
iptables -t mangle -A VPN_ROUTING -p tcp --dport 3000 -j RETURN
iptables -t mangle -A VPN_ROUTING -p tcp --sport 3000 -j RETURN

# Preserve DNS resolution
iptables -t mangle -A VPN_ROUTING -p udp --dport 53 -j RETURN

# Preserve connections to/from SSH client IP
if [[ -n "$SSH_CLIENT_IP" ]]; then
    iptables -t mangle -A VPN_ROUTING -s $SSH_CLIENT_IP -j RETURN
    iptables -t mangle -A VPN_ROUTING -d $SSH_CLIENT_IP -j RETURN
fi

# 7. Route bot traffic through VPN
log "Setting up bot traffic routing..."

# Mark traffic from botuser for VPN routing
iptables -t mangle -A VPN_ROUTING -m owner --uid-owner $(id -u botuser) -j MARK --set-mark 100

# Mark traffic from specific processes (you may need to adjust these)
# For Nuclei
iptables -t mangle -A VPN_ROUTING -m owner --cmd-owner nuclei -j MARK --set-mark 100

# For WPScan  
iptables -t mangle -A VPN_ROUTING -m owner --cmd-owner wpscan -j MARK --set-mark 100

# For Node.js processes (your custom bots)
iptables -t mangle -A VPN_ROUTING -m owner --cmd-owner node -j MARK --set-mark 100

# Alternative: Mark by destination ports (HTTP/HTTPS traffic from bots)
# This is more reliable if you can't use process names
iptables -t mangle -A VPN_ROUTING -p tcp --dport 80 -m owner ! --uid-owner root -j MARK --set-mark 100
iptables -t mangle -A VPN_ROUTING -p tcp --dport 443 -m owner ! --uid-owner root -j MARK --set-mark 100
iptables -t mangle -A VPN_ROUTING -p tcp --dport 8080 -m owner ! --uid-owner root -j MARK --set-mark 100
iptables -t mangle -A VPN_ROUTING -p tcp --dport 8443 -m owner ! --uid-owner root -j MARK --set-mark 100

# 8. Setup routing rules for marked traffic
log "Setting up routing rules for marked traffic..."

# Add rule to send marked traffic to VPN table
if ! ip rule list | grep -q "fwmark 0x64"; then
    ip rule add fwmark 100 table vpn_primary priority 100
fi

# 9. Create startup script
log "Creating VPN routing startup script..."

cat > /usr/local/bin/setup-vpn-routing.sh << 'EOF'
#!/bin/bash
# This script is called by systemd to setup VPN routing

# Wait for network interfaces
sleep 5

# Setup routing rules if VPN interface exists
if ip link show tun0 > /dev/null 2>&1; then
    # Add default route to VPN table
    ip route add default dev tun0 table vpn_primary 2>/dev/null || true
    
    # Flush route cache
    ip route flush cache
    
    echo "VPN routing setup complete"
fi
EOF

chmod +x /usr/local/bin/setup-vpn-routing.sh

# 10. Save iptables rules
log "Saving iptables rules..."
iptables-save > /etc/iptables/rules.v4

# 11. Create systemd service for VPN rotation manager
log "Creating systemd service..."

cat > /etc/systemd/system/vpn-rotation.service << EOF
[Unit]
Description=VPN Rotation Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /Users/muratkara/vpn/vpn_rotation_manager.py
ExecStartPost=/usr/local/bin/setup-vpn-routing.sh
Restart=always
RestartSec=10

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log /var/run /etc/iptables

[Install]
WantedBy=multi-user.target
EOF

# 12. Setup log rotation
log "Setting up log rotation..."

cat > /etc/logrotate.d/vpn-rotation << EOF
/var/log/vpn_rotation.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl reload vpn-rotation.service
    endscript
}
EOF

# 13. Create monitoring script
log "Creating monitoring script..."

cat > /usr/local/bin/vpn-status.sh << 'EOF'
#!/bin/bash
echo "=== VPN Rotation Status ==="
echo "Service Status:"
systemctl status vpn-rotation.service --no-pager -l

echo -e "\nVPN Interfaces:"
ip addr show tun0 2>/dev/null || echo "tun0: Not connected"
ip addr show tun1 2>/dev/null || echo "tun1: Not connected"

echo -e "\nRouting Tables:"
echo "Main table default route:"
ip route show default

echo -e "\nVPN table routes:"
ip route show table vpn_primary 2>/dev/null || echo "VPN table empty"

echo -e "\nFirewall rules (VPN_ROUTING chain):"
iptables -t mangle -L VPN_ROUTING -n --line-numbers

echo -e "\nRecent logs:"
tail -20 /var/log/vpn_rotation.log 2>/dev/null || echo "No logs yet"
EOF

chmod +x /usr/local/bin/vpn-status.sh

# 14. Test current IP
log "Testing current external IP..."
CURRENT_EXTERNAL_IP=$(curl -s --max-time 5 https://ipecho.net/plain || echo "Could not determine")
log "Current external IP: $CURRENT_EXTERNAL_IP"

# Enable and start service
systemctl daemon-reload
systemctl enable vpn-rotation.service

log "VPN routing setup completed!"
log ""
log "Next steps:"
log "1. Copy Mullvad configs to /etc/openvpn/: cp -r /Users/muratkara/vpn/mullvad_config_linux/* /etc/openvpn/"
log "2. Start the service: systemctl start vpn-rotation.service"
log "3. Check status: /usr/local/bin/vpn-status.sh"
log "4. Run your bots as 'botuser': sudo -u botuser your_bot_command"
log ""
log "Important: SSH and panel access will remain on original IP!"
log "Bot traffic will go through rotating VPN connections."
