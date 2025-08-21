#!/usr/bin/env python3
"""
VPN Rotation Manager - Zero Downtime VPN Switching System
Supports instant VPN switching with policy-based routing
"""

import os
import sys
import time
import json
import subprocess
import threading
import logging
import random
from datetime import datetime, timedelta
from pathlib import Path
import requests
import signal

class VPNRotationManager:
    def __init__(self, config_dir="/etc/openvpn"):
        self.config_dir = Path(config_dir)
        self.vpn_configs = self._load_vpn_configs()
        self.blacklisted_vpns = {}  # VPN -> timestamp when blacklisted
        self.current_primary = None
        self.current_secondary = None
        self.rotation_interval = 30 * 60  # 30 minutes
        self.health_check_interval = 5 * 60  # 5 minutes
        self.blacklist_duration = 24 * 60 * 60  # 24 hours
        self.running = False
        
        # Logging setup
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler('/var/log/vpn_rotation.log'),
                logging.StreamHandler(sys.stdout)
            ]
        )
        self.logger = logging.getLogger(__name__)
        
        # Signal handlers for graceful shutdown
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully"""
        self.logger.info(f"Received signal {signum}, shutting down...")
        self.stop()
        sys.exit(0)
    
    def _load_vpn_configs(self):
        """Load all VPN configuration files"""
        configs = []
        for conf_file in self.config_dir.glob("mullvad_*_all.conf"):
            country_code = conf_file.stem.split('_')[1]
            configs.append({
                'country': country_code,
                'file': conf_file,
                'name': f"mullvad_{country_code}"
            })
        self.logger.info(f"Loaded {len(configs)} VPN configurations")
        return configs
    
    def _run_command(self, command, timeout=30):
        """Execute shell command with timeout"""
        try:
            result = subprocess.run(
                command, 
                shell=True, 
                capture_output=True, 
                text=True, 
                timeout=timeout
            )
            return result.returncode == 0, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            self.logger.error(f"Command timeout: {command}")
            return False, "", "Timeout"
        except Exception as e:
            self.logger.error(f"Command error: {command} - {str(e)}")
            return False, "", str(e)
    
    def _get_available_vpns(self):
        """Get VPNs that are not blacklisted"""
        current_time = time.time()
        available_vpns = []
        
        for vpn in self.vpn_configs:
            vpn_name = vpn['name']
            if vpn_name in self.blacklisted_vpns:
                if current_time - self.blacklisted_vpns[vpn_name] < self.blacklist_duration:
                    continue  # Still blacklisted
                else:
                    # Remove from blacklist
                    del self.blacklisted_vpns[vpn_name]
                    self.logger.info(f"Removed {vpn_name} from blacklist")
            
            available_vpns.append(vpn)
        
        return available_vpns
    
    def _setup_routing_tables(self):
        """Setup custom routing tables for VPN traffic"""
        # Add custom routing tables
        commands = [
            "echo '100 vpn_primary' >> /etc/iproute2/rt_tables",
            "echo '101 vpn_secondary' >> /etc/iproute2/rt_tables",
            
            # Create routing rules for bot processes
            # You'll need to identify your bot processes and route them through VPN
            "iptables -t mangle -N VPN_ROUTING",
            "iptables -t mangle -A OUTPUT -j VPN_ROUTING",
        ]
        
        for cmd in commands:
            success, stdout, stderr = self._run_command(cmd)
            if not success and "File exists" not in stderr:
                self.logger.warning(f"Routing setup warning: {cmd} - {stderr}")
    
    def _connect_vpn(self, vpn_config, interface_name):
        """Connect to a specific VPN"""
        self.logger.info(f"Connecting to {vpn_config['name']} on {interface_name}")
        
        # Stop any existing connection on this interface
        self._disconnect_vpn(interface_name)
        
        # Start OpenVPN connection
        cmd = f"""
        openvpn --config {vpn_config['file']} \
                --dev {interface_name} \
                --daemon \
                --writepid /var/run/openvpn_{interface_name}.pid \
                --log-append /var/log/openvpn_{interface_name}.log \
                --cd {self.config_dir}
        """
        
        success, stdout, stderr = self._run_command(cmd)
        if not success:
            self.logger.error(f"Failed to connect VPN: {stderr}")
            return False
        
        # Wait for connection to establish
        for _ in range(30):  # Wait up to 30 seconds
            if self._check_vpn_interface(interface_name):
                self.logger.info(f"VPN {vpn_config['name']} connected successfully on {interface_name}")
                return True
            time.sleep(1)
        
        self.logger.error(f"VPN {vpn_config['name']} failed to establish connection")
        return False
    
    def _disconnect_vpn(self, interface_name):
        """Disconnect VPN on specific interface"""
        pid_file = f"/var/run/openvpn_{interface_name}.pid"
        if os.path.exists(pid_file):
            with open(pid_file, 'r') as f:
                pid = f.read().strip()
            
            success, _, _ = self._run_command(f"kill {pid}")
            if success:
                self.logger.info(f"Disconnected VPN on {interface_name}")
            
            os.remove(pid_file)
    
    def _check_vpn_interface(self, interface_name):
        """Check if VPN interface is up and has IP"""
        success, stdout, _ = self._run_command(f"ip addr show {interface_name}")
        return success and "inet " in stdout
    
    def _test_vpn_connectivity(self, interface_name):
        """Test if VPN is working by checking external IP"""
        test_urls = [
            "https://httpbin.org/ip",
            "https://api.ipify.org?format=json",
            "https://ipecho.net/plain"
        ]
        
        for url in test_urls:
            try:
                # Route this specific request through the VPN interface
                cmd = f"curl -s --interface {interface_name} --max-time 10 {url}"
                success, stdout, stderr = self._run_command(cmd)
                
                if success and stdout.strip():
                    self.logger.info(f"VPN {interface_name} connectivity test passed")
                    return True
                    
            except Exception as e:
                self.logger.warning(f"Connectivity test failed for {interface_name}: {str(e)}")
                continue
        
        self.logger.error(f"VPN {interface_name} connectivity test failed")
        return False
    
    def _switch_primary_routing(self, new_interface):
        """Switch primary routing to new VPN interface - INSTANT SWITCH"""
        self.logger.info(f"Switching primary routing to {new_interface}")
        
        commands = [
            # Clear old routing rules for bot traffic
            "iptables -t mangle -F VPN_ROUTING",
            
            # Route bot traffic through new primary VPN
            f"iptables -t mangle -A VPN_ROUTING -m owner --uid-owner $(id -u botuser) -j MARK --set-mark 100",
            f"ip rule add fwmark 100 table vpn_primary",
            f"ip route add default dev {new_interface} table vpn_primary",
            
            # Flush route cache for immediate effect
            "ip route flush cache"
        ]
        
        for cmd in commands:
            success, stdout, stderr = self._run_command(cmd)
            if not success:
                self.logger.error(f"Routing switch failed: {cmd} - {stderr}")
                return False
        
        self.logger.info(f"Primary routing switched to {new_interface} successfully")
        return True
    
    def _blacklist_vpn(self, vpn_name):
        """Add VPN to blacklist"""
        self.blacklisted_vpns[vpn_name] = time.time()
        self.logger.warning(f"Blacklisted VPN: {vpn_name} for 24 hours")
    
    def _health_check_worker(self):
        """Background worker for health checks"""
        while self.running:
            try:
                # Check primary VPN
                if self.current_primary and not self._test_vpn_connectivity("tun0"):
                    self.logger.error("Primary VPN failed health check")
                    self._blacklist_vpn(self.current_primary['name'])
                    self._emergency_switch()
                
                # Check secondary VPN 
                if self.current_secondary and not self._test_vpn_connectivity("tun1"):
                    self.logger.error("Secondary VPN failed health check")
                    self._blacklist_vpn(self.current_secondary['name'])
                    self._prepare_new_secondary()
                
                time.sleep(self.health_check_interval)
                
            except Exception as e:
                self.logger.error(f"Health check worker error: {str(e)}")
                time.sleep(60)  # Wait before retrying
    
    def _emergency_switch(self):
        """Emergency switch to secondary VPN"""
        if not self.current_secondary:
            self.logger.critical("No secondary VPN available for emergency switch!")
            return False
        
        self.logger.warning("Performing emergency switch to secondary VPN")
        
        # Instant switch to secondary
        success = self._switch_primary_routing("tun1")
        if success:
            # Promote secondary to primary
            old_primary = self.current_primary
            self.current_primary = self.current_secondary
            self.current_secondary = None
            
            # Disconnect failed VPN
            self._disconnect_vpn("tun0")
            
            # Prepare new secondary
            self._prepare_new_secondary()
            
            return True
        
        return False
    
    def _prepare_new_secondary(self):
        """Prepare a new secondary VPN connection"""
        available_vpns = self._get_available_vpns()
        
        # Filter out current primary
        if self.current_primary:
            available_vpns = [vpn for vpn in available_vpns 
                            if vpn['name'] != self.current_primary['name']]
        
        if not available_vpns:
            self.logger.error("No available VPNs for secondary connection")
            return False
        
        # Select random VPN for secondary
        new_secondary = random.choice(available_vpns)
        
        # Connect to secondary interface
        if self._connect_vpn(new_secondary, "tun1"):
            if self._test_vpn_connectivity("tun1"):
                self.current_secondary = new_secondary
                self.logger.info(f"New secondary VPN ready: {new_secondary['name']}")
                return True
            else:
                self._blacklist_vpn(new_secondary['name'])
                self._disconnect_vpn("tun1")
        
        return False
    
    def _rotation_worker(self):
        """Background worker for VPN rotation"""
        while self.running:
            try:
                # Wait for rotation interval
                time.sleep(self.rotation_interval)
                
                if not self.running:
                    break
                
                self.logger.info("Starting VPN rotation")
                
                # Prepare new VPN for rotation
                available_vpns = self._get_available_vpns()
                
                # Filter out current VPNs
                excluded_names = []
                if self.current_primary:
                    excluded_names.append(self.current_primary['name'])
                if self.current_secondary:
                    excluded_names.append(self.current_secondary['name'])
                
                available_vpns = [vpn for vpn in available_vpns 
                                if vpn['name'] not in excluded_names]
                
                if not available_vpns:
                    self.logger.warning("No available VPNs for rotation")
                    continue
                
                # Select new VPN
                new_vpn = random.choice(available_vpns)
                
                # Connect new VPN on tun2 (temporary)
                if self._connect_vpn(new_vpn, "tun2"):
                    if self._test_vpn_connectivity("tun2"):
                        # INSTANT SWITCH: Change routing to tun2
                        if self._switch_primary_routing("tun2"):
                            # Cleanup old primary
                            if self.current_primary:
                                self._disconnect_vpn("tun0")
                            
                            # Promote tun2 to tun0 and secondary to primary position
                            # This is a bit complex but ensures we always have backup
                            self._disconnect_vpn("tun2")
                            if self._connect_vpn(new_vpn, "tun0"):
                                self._switch_primary_routing("tun0")
                                
                                old_primary = self.current_primary
                                self.current_primary = new_vpn
                                
                                self.logger.info(f"VPN rotation completed: {old_primary['name'] if old_primary else 'None'} -> {new_vpn['name']}")
                            
                        else:
                            self._disconnect_vpn("tun2")
                    else:
                        self._blacklist_vpn(new_vpn['name'])
                        self._disconnect_vpn("tun2")
                
            except Exception as e:
                self.logger.error(f"Rotation worker error: {str(e)}")
                time.sleep(300)  # Wait 5 minutes before retrying
    
    def start(self):
        """Start the VPN rotation system"""
        self.logger.info("Starting VPN Rotation Manager")
        self.running = True
        
        # Setup routing tables
        self._setup_routing_tables()
        
        # Initialize with first two VPNs
        available_vpns = self._get_available_vpns()
        
        if len(available_vpns) < 2:
            self.logger.error("Need at least 2 available VPNs to start")
            return False
        
        # Connect primary VPN
        primary_vpn = random.choice(available_vpns)
        if self._connect_vpn(primary_vpn, "tun0"):
            if self._test_vpn_connectivity("tun0"):
                self.current_primary = primary_vpn
                self._switch_primary_routing("tun0")
                self.logger.info(f"Primary VPN connected: {primary_vpn['name']}")
            else:
                self._blacklist_vpn(primary_vpn['name'])
                self.logger.error("Failed to establish primary VPN")
                return False
        
        # Prepare secondary VPN
        self._prepare_new_secondary()
        
        # Start background workers
        health_thread = threading.Thread(target=self._health_check_worker, daemon=True)
        rotation_thread = threading.Thread(target=self._rotation_worker, daemon=True)
        
        health_thread.start()
        rotation_thread.start()
        
        self.logger.info("VPN Rotation Manager started successfully")
        
        # Keep main thread alive
        try:
            while self.running:
                time.sleep(1)
        except KeyboardInterrupt:
            self.stop()
    
    def stop(self):
        """Stop the VPN rotation system"""
        self.logger.info("Stopping VPN Rotation Manager")
        self.running = False
        
        # Disconnect all VPNs
        for interface in ["tun0", "tun1", "tun2"]:
            self._disconnect_vpn(interface)
        
        # Clean up routing rules
        self._run_command("iptables -t mangle -F VPN_ROUTING")
        self._run_command("iptables -t mangle -X VPN_ROUTING")
        
        self.logger.info("VPN Rotation Manager stopped")

if __name__ == "__main__":
    manager = VPNRotationManager()
    manager.start()
