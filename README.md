# AmneziaWG-Go Installer

Automated Bash script to quickly install, configure, and manage an [AmneziaWG-Go](https://github.com/amnezia-vpn/amneziawg-go) VPN server with built-in obfuscation support on Linux containers (OpenVZ/LXC/venet0).

Designed for low-overhead setups with DPI-bypass obfuscation parameters, optimal MTU handling, built-in NAT routing, and automated system-wide DNS management.

---

## Supported OS

* **Debian 12 (Bookworm)** *(Tested and fully supported)*

---

## Installation & Usage

Run the commands below as the **root** user. Follow the interactive prompts to complete the setup.

```bash
curl -O https://raw.githubusercontent.com/xidecvlt1/amneziawg-go-install/main/amneziawg-go-install.sh
chmod +x amneziawg-go-install.sh
./amneziawg-go-install.sh
```
---
## Key Features

* OpenVZ / LXC / KVM Friendly: Uses amneziawg-go userspace implementation and optimal MTU settings (1360) to work seamlessly on virtual environments without requiring native kernel modules or crashing connection throughput.

* DPI-Bypass Obfuscation: Automatically generates and applies AmneziaWG obfuscation parameters (Jc, Jmin, Jmax, S1, S2, H1-H4) to protect VPN traffic against Deep Packet Inspection (DPI) blocks.

* Auto Build & Dependencies: Automatically installs the latest official Go environment to compile both amneziawg-go and amneziawg-tools directly from source.

* Auto NAT Routing: Automatically configures iptables rules and IPv4 forwarding so clients browse securely using the server's public IP.

* Centralized DNS: Sets the upstream DNS choice directly on the server configuration for all connected VPN peers.

* Interactive Management: Re-run the script anytime to add new clients, revoke existing ones, or completely uninstall AmneziaWG.

* QR Code Support: Generates ANSI terminal QR codes instantly for fast mobile device onboarding via the AmneziaWG client app.
