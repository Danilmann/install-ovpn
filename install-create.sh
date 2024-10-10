#!/bin/bash

# Ensure the script is executed with bash
if readlink /proc/$$/exe | grep -q "dash"; then
    echo 'This installer needs to be run with "bash", not "sh".'
    exit
fi

# Check for root privileges
if [[ "$EUID" -ne 0 ]]; then
    echo "This installer needs to be run with superuser privileges."
    exit
fi

# Check for TUN device
if [[ ! -e /dev/net/tun ]] || ! ( exec 7<>/dev/net/tun ) 2>/dev/null; then
    echo "The system does not have the TUN device available. TUN needs to be enabled before running this installer."
    exit
fi

# Function to create the client configuration
new_client () {
    {
        cat /etc/openvpn/server/client-common.txt
        echo "<ca>"
        cat /etc/openvpn/server/ca.crt
        echo "</ca>"
        echo "<cert>"
        sed -ne '/BEGIN CERTIFICATE/,$ p' /etc/openvpn/server/easy-rsa/pki/issued/client.crt
        echo "</cert>"
        echo "<key>"
        cat /etc/openvpn/server/easy-rsa/pki/private/client.key
        echo "</key>"
        echo "<tls-crypt>"
        cat /etc/openvpn/server/tc.key
        echo "</tls-crypt>"
    } > /home/ubuntu/client.ovpn
    chown ubuntu:ubuntu /home/ubuntu/client.ovpn
}

# Install and configure OpenVPN server if not already installed
if [[ ! -e /etc/openvpn/server/server.conf ]]; then
    # Install necessary packages
    apt-get update
    apt-get install -y --no-install-recommends openvpn openssl ca-certificates iptables

    # Set up variables
    protocol="udp"
    port="1194"
    ip=$(curl -s http://checkip.amazonaws.com)

    # Configure OpenVPN server
    mkdir -p /etc/openvpn/server/easy-rsa/
    easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.2.1/EasyRSA-3.2.1.tgz'
    { wget -qO- "$easy_rsa_url" || curl -sL "$easy_rsa_url"; } | tar xz -C /etc/openvpn/server/easy-rsa/ --strip-components 1
    chown -R root:root /etc/openvpn/server/easy-rsa/
    cd /etc/openvpn/server/easy-rsa/
    ./easyrsa --batch init-pki
    ./easyrsa --batch build-ca nopass
    ./easyrsa --batch build-server-full server nopass
    ./easyrsa --batch gen-crl
    cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server
    chmod o+x /etc/openvpn/server/

    # Generate TLS crypt key
    openvpn --genkey secret /etc/openvpn/server/tc.key

    # Generate server configuration file
    cat > /etc/openvpn/server/server.conf <<EOL
port $port
proto $protocol
dev tun
ca ca.crt
cert server.crt
key server.key
dh none
auth SHA512
tls-crypt /etc/openvpn/server/tc.key
cipher AES-256-CBC
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
user nobody
group nogroup
persist-key
persist-tun
crl-verify crl.pem
explicit-exit-notify 1
EOL

    # Enable IP forwarding
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
    sysctl --system

    # Set up iptables rules
    mkdir -p /etc/iptables
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE
    iptables -A INPUT -p $protocol --dport $port -j ACCEPT
    iptables -A FORWARD -s 10.8.0.0/24 -j ACCEPT
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Save iptables rules
    iptables-save > /etc/iptables/rules.v4

    # Enable and start OpenVPN service
    systemctl enable --now openvpn-server@server.service

    # Check if OpenVPN service started correctly
    if ! systemctl is-active --quiet openvpn-server@server.service; then
        echo "OpenVPN service failed to start. Please check the logs with:"
        echo "journalctl -xeu openvpn-server@server.service"
        exit 1
    fi

    # Create client template and generate first client configuration
    cat > /etc/openvpn/server/client-common.txt <<EOL
client
dev tun
proto $protocol
remote $ip $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-CBC
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3
EOL

    # Generate the client certificate and configuration
    cd /etc/openvpn/server/easy-rsa/
    ./easyrsa --batch build-client-full "client" nopass
    new_client

    echo "The client configuration is available at /home/ubuntu/client.ovpn"
else
    echo "OpenVPN is already installed and configured."
fi
