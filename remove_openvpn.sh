#!/bin/bash

# Check if OpenVPN is installed
if dpkg -l | grep -q "openvpn"; then
    echo "OpenVPN is installed. Proceeding with removal..."
    
    # Stop and disable the OpenVPN service if it's running
    if systemctl is-active --quiet openvpn-server@server.service; then
        systemctl stop openvpn-server@server.service
        echo "OpenVPN service stopped."
    fi
    systemctl disable openvpn-server@server.service 2>/dev/null
    
    # Remove OpenVPN package and configuration
    apt-get remove --purge -y openvpn
    rm -rf /etc/openvpn
    echo "OpenVPN has been successfully removed from the system."

else
    echo "OpenVPN is not installed on this server."
fi
