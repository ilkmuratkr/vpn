# VPN Rotation System 🔄

Zero-downtime VPN rotation system for Linux servers that protects SSH and admin panel access while routing bot traffic through rotating VPN connections.

## 🎯 Features

- ✅ **Zero-downtime VPN switching** - Instant rotation (1-2 seconds)
- ✅ **SSH & Admin panel protection** - Keep your access secure
- ✅ **Multi-bot support** - Nuclei, WPScan, Node.js bots
- ✅ **Auto-rotation** - Every 30 minutes
- ✅ **Health monitoring** - Every 5 minutes
- ✅ **Auto-blacklisting** - Failed VPNs blocked for 24 hours
- ✅ **29 country locations** - Mullvad VPN support

## 🚀 Quick Start

```bash
# Download and run
git clone https://github.com/ilkmuratkr/vpn.git
cd vpn
sudo bash quick_start.sh
```

That's it! Your system is ready.

## 📋 System Architecture

```
┌─────────────────┐    ┌──────────────────┐
│   SSH/Admin     │────│  Main Internet   │
│   (Port 22,     │    │  Connection      │
│    3000)        │    │                  │
└─────────────────┘    └──────────────────┘
                               │
┌─────────────────┐    ┌──────────────────┐
│   Bot Traffic   │────│  VPN Rotation    │
│  (Nuclei, WP,   │    │  System          │
│   Node.js)      │    │  (tun0/tun1)     │
└─────────────────┘    └──────────────────┘
```

## 🤖 Running Bots

```bash
# Nuclei scanning
bot_wrapper.sh nuclei -t /root/nuclei-templates -u target.com

# WPScan
bot_wrapper.sh wpscan --url http://target.com --enumerate ap

# Node.js bots
bot_wrapper.sh node /path/to/your/bot.js

# Custom commands
bot_wrapper.sh custom "python3 /path/to/scanner.py"

# Check status
bot_wrapper.sh status

# Test VPN
bot_wrapper.sh test-vpn
```

## 📊 System Control

```bash
# Service status
systemctl status vpn-rotation.service

# View logs
tail -f /var/log/vpn_rotation.log

# Detailed status
/usr/local/bin/vpn-status.sh

# Check IPs
curl https://ipecho.net/plain                    # Main IP
sudo -u botuser curl https://ipecho.net/plain    # Bot IP (VPN)
```

## 📁 File Structure

- **`vpn_rotation_manager.py`** - Main VPN management system
- **`setup_vpn_routing.sh`** - Network routing configuration
- **`bot_wrapper.sh`** - Bot execution wrapper
- **`install.sh`** - Full automatic installation
- **`quick_start.sh`** - One-command setup and start
- **`KULLANIM_REHBERI.txt`** - Detailed usage guide (Turkish)
- **`mullvad_config_linux/`** - VPN configuration files

## ⚙️ Configuration

### Change rotation interval:
Edit `/usr/local/bin/vpn_rotation_manager.py`:
```python
self.rotation_interval = 30 * 60  # seconds
```

### Change health check interval:
```python
self.health_check_interval = 5 * 60  # seconds
```

## 🔧 Requirements

- Linux server with root access
- Mullvad VPN subscription
- Python 3.6+
- OpenVPN
- iptables

## 🛠️ Manual Installation

```bash
# 1. Clone repository
git clone https://github.com/ilkmuratkr/vpn.git
cd vpn

# 2. Run installation
sudo bash install.sh

# 3. Start service
systemctl start vpn-rotation.service
systemctl enable vpn-rotation.service

# 4. Check status
/usr/local/bin/vpn-status.sh
```

## 🐛 Troubleshooting

**Problem:** "VPN interface not found"
**Solution:** `systemctl start vpn-rotation.service`

**Problem:** "VPN routing not working"
**Solution:** 
- Check with `/usr/local/bin/vpn-status.sh`
- Verify rules: `iptables -t mangle -L VPN_ROUTING -n`

**Problem:** "SSH connection lost"
**Solution:** SSH port (22) is never routed through VPN

## 📝 Log Files

- `/var/log/vpn_rotation.log` - Main VPN rotation logs
- `/var/log/openvpn_tun0.log` - Primary VPN connection logs
- `/var/log/openvpn_tun1.log` - Secondary VPN connection logs
- `journalctl -u vpn-rotation.service` - Systemd service logs

## 🔒 Security

- SSH access remains on your original IP
- Admin panel (port 3000) access protected
- Bot traffic completely routed through VPN
- Automatic rotation between different VPN locations
- Failed VPNs automatically blacklisted

## 📈 Performance

- VPN switching completes in 1-2 seconds
- Existing TCP connections preserved
- Zero-downtime rotation
- Multiple concurrent bot support

## 🌍 Supported VPN Locations

29 countries including: US, DE, GB, FR, NL, SE, JP, AU, CA, and more.

## 📞 Support

Check log files and system status with `vpn-status.sh` if you experience issues.

## 📄 License

This project is for educational and security research purposes.

---

**⚠️ Important:** This system preserves SSH and admin panel access on your original IP while routing bot traffic through rotating VPN connections.
