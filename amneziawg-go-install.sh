#!/bin/bash

# Secure AmneziaWG server installer
# Using amneziawg-go compiled from source & support OpenVZ/venet0.

# Color Definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

function isRoot() {
	if [ "$EUID" -ne 0 ]; then
		echo "This script must be run as root."
		exit 1
	fi
}

function checkVirt() {
	TUN_DEV="/dev/net/tun"
	if [ ! -c "$TUN_DEV" ]; then
		echo -e "${RED}TUN device ($TUN_DEV) is not available!${NC}"
		echo "Please enable the TUN/TAP feature on your VPS/Server control panel."
		exit 1
	fi
}

function checkOS() {
	if [ -f /etc/os-release ]; then
		source /etc/os-release
		if [ "$ID" != "debian" ]; then
			echo -e "${RED}This modified script is tailored specifically for Debian 12 (Bookworm).${NC}"
			exit 1
		fi
		if [ "$VERSION_ID" -lt 12 ]; then
			echo -e "${RED}Your Debian version ($VERSION_ID) is not supported. Please use Debian 12 or newer.${NC}"
			exit 1
		fi
	else
		echo -e "${RED}Could not detect operating system.${NC}"
		exit 1
	fi
}

function initialCheck() {
	isRoot
	checkVirt
	checkOS
}

function detect_mtu() {
	echo -e "\n${BOLD}${YELLOW}[ Auto-Detecting Optimal MTU ]${NC}"
	local target="1.1.1.1"
	local low=1200
	local high=1500
	local best=0

	echo -e " ${CYAN}• Running binary search ICMP ping test to $target...${NC}"

	# Check lowest bound connection
	if ! ping -c 1 -W 2 -M do -s $low $target >/dev/null 2>&1; then
		echo -e " ${ORANGE}⚠ Ping with low payload ($low bytes) failed or ICMP blocked. Falling back to default MTU 1360.${NC}"
		OPTIMAL_MTU=1360
		return
	fi

	while [ $low -le $high ]; do
		local mid=$(( (low + high) / 2 ))
		if ping -c 1 -W 2 -M do -s $mid $target >/dev/null 2>&1; then
			best=$mid
			low=$(( mid + 1 ))
		else
			high=$(( mid - 1 ))
		fi
	done

	if [ $best -gt 0 ]; then
		local mtu_fisik=$(( best + 28 ))
		# AmneziaWG/WireGuard overhead: 60 bytes (IPv4 header + WG/AWG header)
		OPTIMAL_MTU=$(( mtu_fisik - 60 ))
		echo -e " ${GREEN}✓ Max ICMP Payload: ${best} bytes | Physical MTU: ${mtu_fisik} | Optimal AWG MTU: ${OPTIMAL_MTU}${NC}"
	else
		OPTIMAL_MTU=1360
		echo -e " ${ORANGE}⚠ Could not calculate MTU. Falling back to default MTU 1360.${NC}"
	fi
}

function installQuestions() {
	clear

	# Sleek Minimalist Header
	echo -e "${CYAN}=====================================================${NC}"
	echo -e "   ${BOLD}${GREEN}AmneziaWG Installer${NC} ${CYAN}(amneziawg-go)${NC} - ${BOLD}Debian 12${NC}"
	echo -e "${CYAN}=====================================================${NC}"
	echo -e "${ORANGE}Answer the following questions to set up your server.${NC}\n"

	# 1. Detect Main Interface
	SERVER_NIC=$(ip route show default | grep -oP 'dev \K\S+' | head -n1)
	if [[ "$SERVER_NIC" == "link" ]] || [[ -z "$SERVER_NIC" ]]; then
		if ip link show venet0 &>/dev/null; then
			SERVER_NIC="venet0"
		fi
	fi
	
	# 2. Detect Public IP
	SERVER_PUB_IP=$(ip -4 addr show "$SERVER_NIC" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n1)
	if [[ -z "$SERVER_PUB_IP" ]]; then
		SERVER_PUB_IP=$(curl -s4 --connect-timeout 5 https://ifconfig.me || curl -s4 --connect-timeout 5 https://api.ipify.org)
	fi

	# Network Settings Prompts
	echo -e "${BOLD}${YELLOW}[ Network Configuration ]${NC}"
	read -rp "$(echo -e "${CYAN}•${NC} Server Public IPv4   : ")" -e -i "$SERVER_PUB_IP" SERVER_PUB_IP
	read -rp "$(echo -e "${CYAN}•${NC} Network Interface    : ")" -e -i "$SERVER_NIC" SERVER_NIC
	read -rp "$(echo -e "${CYAN}•${NC} AmneziaWG Interface  : ")" -e -i "awg0" SERVER_WG_NIC
	read -rp "$(echo -e "${CYAN}•${NC} AmneziaWG Server IP  : ")" -e -i "10.66.66.1" SERVER_WG_IPV4

	# Run MTU Auto-Detection
	detect_mtu

	# Port Selection
	echo -e "\n${BOLD}${YELLOW}[ Port Selection ]${NC}"
	echo -e "  ${GREEN}1)${NC} Default Port  ${CYAN}(51820)${NC}"
	echo -e "  ${GREEN}2)${NC} Random Port   ${CYAN}(1024-65535)${NC}"
	echo -e "  ${GREEN}3)${NC} Custom Port   ${CYAN}(Manual Input)${NC}"
	read -rp "$(echo -e "${CYAN}Select option [1-3]: ${NC}")" -e -i "1" PORT_CHOICE

	case "$PORT_CHOICE" in
		1)
			SERVER_PORT="51820"
			;;
		2)
			RANDOM_PORT=$(shuf -i 1024-65535 -n 1)
			while ss -ludn | grep -q ":$RANDOM_PORT "; do
				RANDOM_PORT=$(shuf -i 1024-65535 -n 1)
			done
			SERVER_PORT="$RANDOM_PORT"
			echo -e "  ${GREEN}✓${NC} Selected Random Port: ${BOLD}${GREEN}${SERVER_PORT}${NC}"
			;;
		3)
			read -rp "$(echo -e "  ${CYAN}• Enter Port [1024-65535]: ${NC}")" -e SERVER_PORT
			;;
		*)
			SERVER_PORT="51820"
			;;
	esac

	# DNS Options
	echo -e "\n${BOLD}${YELLOW}[ Client DNS Resolver ]${NC}"
	echo -e "  ${GREEN}1)${NC} Cloudflare ${CYAN}(1.1.1.1)${NC}"
	echo -e "  ${GREEN}2)${NC} Google     ${CYAN}(8.8.8.8)${NC}"
	echo -e "  ${GREEN}3)${NC} Quad9      ${CYAN}(9.9.9.9)${NC}"
	echo -e "  ${GREEN}4)${NC} AdGuard    ${CYAN}(94.140.14.14)${NC}"
	echo -e "  ${GREEN}5)${NC} OpenDNS    ${CYAN}(208.67.222.222)${NC}"
	echo -e "  ${GREEN}6)${NC} NextDNS    ${CYAN}(45.90.28.0)${NC}"
	echo -e "  ${GREEN}7)${NC} Custom IPv4 DNS"
	read -rp "$(echo -e "${CYAN}Select option [1-7]: ${NC}")" -e -i "1" DNS_CHOICE

	case "$DNS_CHOICE" in
		1) CLIENT_DNS="1.1.1.1, 1.0.0.1" ;;
		2) CLIENT_DNS="8.8.8.8, 8.8.4.4" ;;
		3) CLIENT_DNS="9.9.9.9, 149.112.112.112" ;;
		4) CLIENT_DNS="94.140.14.14, 94.140.15.15" ;;
		5) CLIENT_DNS="208.67.222.222, 208.67.220.220" ;;
		6) CLIENT_DNS="45.90.28.0, 45.90.30.0" ;;
		7) 
			read -rp "$(echo -e "  ${CYAN}• Primary DNS: ${NC}")" CUSTOM_DNS1
			read -rp "$(echo -e "  ${CYAN}• Secondary DNS: ${NC}")" CUSTOM_DNS2
			CLIENT_DNS="${CUSTOM_DNS1}, ${CUSTOM_DNS2}"
			;;
		*) CLIENT_DNS="1.1.1.1, 1.0.0.1" ;;
	esac

	# Client Isolation
	echo -e "\n${BOLD}${YELLOW}[ Client Isolation Settings ]${NC}"
	echo -e "  ${GREEN}1)${NC} Enabled  - Keeps clients separated for security ${GREEN}(Default)${NC}"
	echo -e "  ${GREEN}2)${NC} Disabled - Allows clients to communicate (SMB/Samba)"
	read -rp "$(echo -e "${CYAN}Select option [1-2]: ${NC}")" -e -i "1" CLIENT_ISOLATION
	until [[ "$CLIENT_ISOLATION" =~ ^[1-2]$ ]]; do
		echo -e "  ${RED}Invalid option!${NC}"
		read -rp "$(echo -e "${CYAN}Select option [1-2]: ${NC}")" -e -i "1" CLIENT_ISOLATION
	done

	case "$CLIENT_ISOLATION" in
		1)
			ISOLATION_POSTUP="; iptables -I FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_WG_NIC} -j DROP"
			ISOLATION_POSTDOWN="; iptables -D FORWARD -i ${SERVER_WG_NIC} -o ${SERVER_WG_NIC} -j DROP"
			;;
		2)
			ISOLATION_POSTUP=""
			ISOLATION_POSTDOWN=""
			;;
	esac

	# AmneziaWG Obfuscation Parameters Prompts
	echo -e "\n${BOLD}${YELLOW}[ AmneziaWG Obfuscation Configuration ]${NC}"
    read -rp "$(echo -e "${CYAN}Use default parameters? (Y/n) : ${NC}")" -e -i "Y" USE_DEFAULT

    if [[ "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
        JC=4
        JMIN=40
        JMAX=70
        S1=15
        S2=25
        H1=$(shuf -i 100000000-2000000000 -n 1)
        H2=$(shuf -i 100000000-2000000000 -n 1)
        H3=$(shuf -i 100000000-2000000000 -n 1)
        H4=$(shuf -i 100000000-2000000000 -n 1)
    else
      echo -e "\n${BOLD}${YELLOW}--- [1/3] Junk Packets Configuration ---${NC}"
      echo -e "Dummy packets sent before actual WireGuard connection starts."
      read -rp "$(echo -e "${CYAN}• Junk Packet Count [JC]         : ${NC}")" -e -i "4" JC
      
      echo -e "\nRandom size range (in bytes) for each dummy packet sent."
      while true; do
          read -rp "$(echo -e "${CYAN}• Junk Packet Min Size [JMIN]    : ${NC}")" -e -i "40" JMIN
          read -rp "$(echo -e "${CYAN}• Junk Packet Max Size [JMAX]    : ${NC}")" -e -i "70" JMAX

          if [[ "$JMIN" -le "$JMAX" ]]; then
              break
          fi
          echo -e "\n${RED}[!] Error: JMIN ($JMIN) cannot be greater than JMAX ($JMAX). Try again.${NC}"
      done

      echo -e "\n${BOLD}${YELLOW}--- [2/3] Packet Payload Junk Size ---${NC}"
      echo -e "Amount of random junk bytes appended to the Initiation packet."
      read -rp "$(echo -e "${CYAN}• Init Packet Junk Size [S1]     : ${NC}")" -e -i "15" S1
      echo -e "\nAmount of random junk bytes appended to the Response packet."
      read -rp "$(echo -e "${CYAN}• Response Packet Junk Size [S2] : ${NC}")" -e -i "25" S2
      
      echo -e "\n${BOLD}${YELLOW}--- [3/3] Custom Headers (Magic Numbers) ---${NC}"
      echo -e "Unique 4-byte values replacing standard WireGuard headers to prevent detection."
      read -rp "$(echo -e "${CYAN}• Init Packet Header [H1]        : ${NC}")" -e -i "$(shuf -i 100000000-2000000000 -n 1)" H1
      read -rp "$(echo -e "${CYAN}• Response Packet Header [H2]    : ${NC}")" -e -i "$(shuf -i 100000000-2000000000 -n 1)" H2
      read -rp "$(echo -e "${CYAN}• Cookie Packet Header [H3]      : ${NC}")" -e -i "$(shuf -i 100000000-2000000000 -n 1)" H3
      read -rp "$(echo -e "${CYAN}• Transport Packet Header [H4]   : ${NC}")" -e -i "$(shuf -i 100000000-2000000000 -n 1)" H4
  fi

	echo -e "\n${CYAN}-----------------------------------------------------${NC}"
	echo -e " ${BOLD}${GREEN}✔ Configuration ready to apply!${NC}"
	echo -e "${CYAN}-----------------------------------------------------${NC}\n"
	read -n1 -r -p "Press any key to continue installation..."
}

function installWireGuard() {
	installQuestions

	echo -e "\n${GREEN}[1/5] Updating repositories and installing dependencies...${NC}"
	apt-get update
	apt-get install -y git build-essential iptables iptables-persistent qrencode curl resolvconf wireguard-tools

	echo -e "\n${GREEN}[2/5] Installing Go official release & building AmneziaWG...${NC}"
	apt-get remove -y golang-go 2>/dev/null || true

	LATEST_GO=$(curl -s "https://go.dev/dl/?mode=json" | grep -o 'go[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n 1)

	if [ -z "$LATEST_GO" ]; then
		LATEST_GO="go1.23.2"
	fi

	curl -LO "https://go.dev/dl/${LATEST_GO}.linux-amd64.tar.gz"
	rm -rf /usr/local/go
	tar -C /usr/local -xzf "${LATEST_GO}.linux-amd64.tar.gz"
	rm "${LATEST_GO}.linux-amd64.tar.gz"

	export PATH=$PATH:/usr/local/go/bin

	WORKDIR=$(mktemp -d)
	cd "$WORKDIR"

	git clone https://github.com/amnezia-vpn/amneziawg-go.git
	cd amneziawg-go
	make
	cp amneziawg-go /usr/local/bin/
	cd "$WORKDIR"

	git clone https://github.com/amnezia-vpn/amneziawg-tools.git
	cd amneziawg-tools/src
	make
	make install
	cd "$WORKDIR"
	rm -rf "$WORKDIR"

	echo -e "\n${GREEN}[3/5] Creating configuration directory & generating keys...${NC}"
	mkdir -p /etc/amnezia/amneziawg
	chmod 700 /etc/amnezia/amneziawg

	SERVER_PRIV_KEY=$(awg genkey)
	SERVER_PUB_KEY=$(awg pubkey <<< "$SERVER_PRIV_KEY")

	if [[ -z "$SERVER_PRIV_KEY" ]] || [[ -z "$SERVER_PUB_KEY" ]]; then
		echo -e "${RED}Error: Failed to generate AmneziaWG keys.${NC}"
		exit 1
	fi
	
	# Intercept DNAT
	PRIMARY_DNS=$(echo "$CLIENT_DNS" | cut -d',' -f1 | tr -d ' ')

	echo -e "\n${GREEN}[4/5] Writing configuration to /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf...${NC}"

	cat <<EOF > /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf
[Interface]
Address = ${SERVER_WG_IPV4}/24
PrivateKey = ${SERVER_PRIV_KEY}
ListenPort = ${SERVER_PORT}
MTU = ${OPTIMAL_MTU}

Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

PostUp = iptables -A INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT; iptables -A FORWARD -i ${SERVER_WG_NIC} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${SERVER_NIC} -j MASQUERADE; iptables -t nat -A PREROUTING -i ${SERVER_WG_NIC} -p udp --dport 53 -j DNAT --to-destination ${PRIMARY_DNS}:53; iptables -t nat -A PREROUTING -i ${SERVER_WG_NIC} -p tcp --dport 53 -j DNAT --to-destination ${PRIMARY_DNS}:53${ISOLATION_POSTUP}
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT; iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${SERVER_NIC} -j MASQUERADE; iptables -t nat -D PREROUTING -i ${SERVER_WG_NIC} -p udp --dport 53 -j DNAT --to-destination ${PRIMARY_DNS}:53; iptables -t nat -D PREROUTING -i ${SERVER_WG_NIC} -p tcp --dport 53 -j DNAT --to-destination ${PRIMARY_DNS}:53${ISOLATION_POSTDOWN}
# Default DNS Settings for Clients: ${CLIENT_DNS}
# Optimal Detected MTU: ${OPTIMAL_MTU}
EOF

	chmod 600 /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf

# Safely enable IP Forwarding & Localnet Routing for Local DNS Intercept
	cat <<EOF > /etc/sysctl.d/99-amneziawg.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.default.route_localnet=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF

	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
	sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1
	sysctl -w net.ipv4.conf.default.route_localnet=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
	
	sysctl -p /etc/sysctl.d/99-amneziawg.conf >/dev/null 2>&1
	
	if command -v netfilter-persistent &>/dev/null; then
		netfilter-persistent save >/dev/null 2>&1
	fi

	echo -e "\n${GREEN}[5/5] Enabling and starting AmneziaWG service...${NC}"
	systemctl enable awg-quick@${SERVER_WG_NIC}
	systemctl restart awg-quick@${SERVER_WG_NIC}

# Add cronjob to reset disconnected peer
	cat <<'EOF' > /usr/local/bin/reset-disconnected-peer.sh
#!/bin/bash
INTERFACE="awg0"
CONFIG_FILE="/etc/amnezia/amneziawg/awg0.conf"
TIMEOUT=180
NOW=$(date +%s)

awg show $INTERFACE dump | tail -n +2 | while read -r line; do
    PUBLIC_KEY=$(echo "$line" | awk '{print $1}')
    LATEST_HANDSHAKE=$(echo "$line" | awk '{print $5}')
    
    if [ "$LATEST_HANDSHAKE" -ne 0 ]; then
        DIFF=$((NOW - LATEST_HANDSHAKE))
        
        if [ $DIFF -gt $TIMEOUT ]; then
            awg set $INTERFACE peer "$PUBLIC_KEY" remove
            awg syncconf $INTERFACE <(awg-quick strip $INTERFACE)
        fi
    fi
done
EOF
	chmod +x /usr/local/bin/reset-disconnected-peer.sh
	
	echo "* * * * * root /usr/local/bin/reset-disconnected-peer.sh >/dev/null 2>&1" > /etc/cron.d/awg-peer-reset
	chmod 644 /etc/cron.d/awg-peer-reset
	systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
	
	echo -e "\n${GREEN}AmneziaWG (amneziawg-go) installed successfully!${NC}"

	newClient
}

function newClient() {
	echo -e "\n${GREEN}--- Add New AmneziaWG Client ---${NC}"
    echo ""
	read -rp "Client name (e.g., android-phone): " CLIENT_NAME
	CLIENT_NAME=$(echo "$CLIENT_NAME" | sed 's/[^a-zA-Z0-9_-]//g')

	if [ -z "$CLIENT_NAME" ]; then
		CLIENT_NAME="client1"
	fi

	# Fetch server parameter fallback
	if [ -z "$SERVER_PUB_KEY" ]; then
		SERVER_PRIV_KEY=$(grep PrivateKey /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
		SERVER_PUB_KEY=$(awg pubkey <<< "$SERVER_PRIV_KEY")
	fi

	if [ -z "$SERVER_WG_IPV4" ]; then
		SERVER_WG_IPV4=$(grep Address /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}' | cut -d'/' -f1)
	fi
	if [ -z "$SERVER_PORT" ]; then
		SERVER_PORT=$(grep ListenPort /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
	fi
	if [ -z "$SERVER_PUB_IP" ]; then
		SERVER_PUB_IP=$(curl -s4 --connect-timeout 5 https://ifconfig.me || curl -s4 --connect-timeout 5 https://api.ipify.org)
	fi

	CLIENT_DNS="${SERVER_WG_IPV4}"

	# Fetch MTU value from server configuration
	if [ -z "$OPTIMAL_MTU" ]; then
		OPTIMAL_MTU=$(grep "^MTU =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
		if [ -z "$OPTIMAL_MTU" ]; then
			OPTIMAL_MTU=1360
		fi
	fi

	# Fetch AmneziaWG obfuscation parameters from server conf
	JC=$(grep "^Jc =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
	JMIN=$(grep "^Jmin =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
	JMAX=$(grep "^Jmax =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
	S1=$(grep "^S1 =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
	S2=$(grep "^S2 =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
	H1=$(grep "^H1 =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
	H2=$(grep "^H2 =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
	H3=$(grep "^H3 =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')
	H4=$(grep "^H4 =" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}')

	# Generate Client Keys
	CLIENT_PRIV_KEY=$(awg genkey)
	CLIENT_PUB_KEY=$(awg pubkey <<< "$CLIENT_PRIV_KEY")
	CLIENT_PRE_KEY=$(awg genpsk)

	if [[ -z "$CLIENT_PRIV_KEY" ]] || [[ -z "$CLIENT_PUB_KEY" ]]; then
		echo -e "${RED}Error: Failed to generate AmneziaWG keys.${NC}"
		exit 1
	fi

	# Cari IP client berikutnya
	OCTET=2
	while grep -q "10.66.66.${OCTET}" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf; do
		((OCTET++))
	done
	CLIENT_WG_IPV4="10.66.66.${OCTET}"

	# Tambahkan Peer ke server config
	cat <<EOF >> /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf

[Peer]
# Client: ${CLIENT_NAME}
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32
EOF

	# Reload live interface
	awg syncconf ${SERVER_WG_NIC} <(awg-quick strip ${SERVER_WG_NIC})

	# Generate Client Config File
	CLIENT_FILE="/root/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
	cat <<EOF > "$CLIENT_FILE"
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS}
MTU = ${OPTIMAL_MTU}

Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_KEY}
Endpoint = ${SERVER_PUB_IP}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

	chmod 600 "$CLIENT_FILE"

	echo -e "\n${GREEN}Client '${CLIENT_NAME}' created successfully!${NC}"
	echo -e "\nProfile file saved to: ${GREEN}${CLIENT_FILE}${NC}\n"
	
	# Render QR Code
	qrencode -t ansiutf8 < "$CLIENT_FILE"
    echo ""
}

function revokeClient() {
	echo -e "\n${GREEN}--- Remove AmneziaWG Client ---${NC}"
	echo ""

	CLIENT_LIST=($(grep '^# Client:' /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf | awk '{print $3}'))
	NUMBER_OF_CLIENTS=${#CLIENT_LIST[@]}

	if [ "$NUMBER_OF_CLIENTS" -eq 0 ]; then
		echo "No client configurations found."
		exit 0
	fi

	for ((i=0; i<NUMBER_OF_CLIENTS; i++)); do
		echo "  $((i+1))) ${CLIENT_LIST[$i]}"
	done
	echo ""

	read -rp "Select client number to revoke [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
	until [[ "$CLIENT_NUMBER" =~ ^[0-9]+$ ]] && [ "$CLIENT_NUMBER" -ge 1 ] && [ "$CLIENT_NUMBER" -le "$NUMBER_OF_CLIENTS" ]; do
		echo "$CLIENT_NUMBER: invalid selection"
		read -rp "Select client number to revoke [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
	done

	REMOVE_CLIENT_NAME="${CLIENT_LIST[$((CLIENT_NUMBER-1))]}"

	sed -i "/^\[Peer\]$/{N;/# Client: ${REMOVE_CLIENT_NAME}\$/!b; :a; N; /AllowedIPs/!ba; d}" /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf

	awg syncconf ${SERVER_WG_NIC} <(awg-quick strip ${SERVER_WG_NIC})

	rm -f /root/${SERVER_WG_NIC}-client-${REMOVE_CLIENT_NAME}.conf

	echo -e "\n${GREEN}Client '${REMOVE_CLIENT_NAME}' removed successfully!${NC}"
    echo ""
}

function uninstallWireGuard() {
	echo -e "\n${RED}Uninstalling AmneziaWG and resetting system settings...${NC}"

	if [ -z "$SERVER_WG_NIC" ]; then
		SERVER_WG_NIC="awg0"
	fi

	CONF_FILE="/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf"
	if [ -f "$CONF_FILE" ]; then
		SERVER_PORT=$(grep -i '^ListenPort' "$CONF_FILE" | awk '{print $3}')
	fi

	systemctl stop awg-quick@${SERVER_WG_NIC} 2>/dev/null
	systemctl disable awg-quick@${SERVER_WG_NIC} 2>/dev/null

	echo -e "${GREEN}[1/4] Resetting iptables rules...${NC}"
	
	if [ -n "$SERVER_PORT" ]; then
		while iptables -C INPUT -p udp --dport "$SERVER_PORT" -j ACCEPT 2>/dev/null; do
			iptables -D INPUT -p udp --dport "$SERVER_PORT" -j ACCEPT
		done
	fi

	while iptables -C INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null; do
		iptables -D INPUT -p udp --dport 51820 -j ACCEPT
	done

	while iptables -C FORWARD -i "${SERVER_WG_NIC}" -j ACCEPT 2>/dev/null; do
		iptables -D FORWARD -i "${SERVER_WG_NIC}" -j ACCEPT
	done
	while iptables -C FORWARD -i "${SERVER_WG_NIC}" -o "${SERVER_WG_NIC}" -j DROP 2>/dev/null; do
		iptables -D FORWARD -i "${SERVER_WG_NIC}" -o "${SERVER_WG_NIC}" -j DROP
	done
	if [ -n "$SERVER_NIC" ]; then
		while iptables -t nat -C POSTROUTING -o "${SERVER_NIC}" -j MASQUERADE 2>/dev/null; do
			iptables -t nat -D POSTROUTING -o "${SERVER_NIC}" -j MASQUERADE
		done
	fi

	if command -v netfilter-persistent &>/dev/null; then
		netfilter-persistent save >/dev/null 2>&1
	fi

	echo -e "${GREEN}[2/4] Resetting sysctl configuration...${NC}"
	if [ -f /etc/sysctl.d/99-amneziawg.conf ]; then
		rm -f /etc/sysctl.d/99-amneziawg.conf
	fi

	sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1
	sysctl --system >/dev/null 2>&1

	echo -e "${GREEN}[3/4] Removing AmneziaWG binaries...${NC}"
	rm -f /usr/local/bin/amneziawg-go /usr/bin/awg /usr/bin/awg-quick

	echo -e "${GREEN}[4/4] Cleaning configuration files...${NC}"
	rm -rf /etc/amnezia/amneziawg
	rm -f /root/${SERVER_WG_NIC}-client-*.conf
	rm -f /usr/local/bin/reset-disconnected-peer.sh
	rm -f /etc/cron.d/awg-peer-reset
	systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null

	echo -e "\n${GREEN}AmneziaWG has been uninstalled!${NC}"
    echo ""
}

# Main Execution Flow
initialCheck

if [ -f "/etc/amnezia/amneziawg/awg0.conf" ]; then
	SERVER_WG_NIC="awg0"
	echo -e "\n${GREEN}AmneziaWG is already installed on this system.${NC}"
    echo ""
	echo "1) Add New Client"
	echo "2) Revoke Existing Client"
	echo "3) Uninstall AmneziaWG"
	echo "4) Exit"
    echo ""
	read -rp "Select option [1-4]: " MENU_OPTION
	case "$MENU_OPTION" in
		1) newClient ;;
		2) revokeClient ;;
		3) uninstallWireGuard ;;
		*) exit 0 ;;
	esac
else
	installWireGuard
fi
