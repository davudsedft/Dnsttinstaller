#!/usr/bin/env bash
set -e

if [[ $EUID -ne 0 ]]; then
  echo "❌ Run as root"
  exit 1
fi

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
BIN_NAME="dnstt-server"
BIN_PATH="${WORKDIR}/${BIN_NAME}"
CONFIG_FILE="${WORKDIR}/dnstt.conf"

IPT_SERVICE="dnstt-iptables.service"
DNSTT_SERVICE="dnstt.service"
SSH_SERVICE="ssh-socks.service"

echo "=============================="
echo " DNSTT Manager"
echo "=============================="
echo "1) Install DNSTT"
echo "2) Remove DNSTT"
echo "3) Show DNS Link"
echo
read -rp "Select option [1-3]: " ACTION

############################################
# REMOVE
############################################
remove_dnstt() {

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ DNSTT not installed"
    exit 1
  fi

  source "$CONFIG_FILE"

  echo "[*] Stopping services..."
  systemctl stop dnstt ssh-socks dnstt-iptables 2>/dev/null || true
  systemctl disable dnstt ssh-socks dnstt-iptables 2>/dev/null || true

  echo "[*] Removing systemd services..."
  rm -f /etc/systemd/system/${IPT_SERVICE}
  rm -f /etc/systemd/system/${DNSTT_SERVICE}
  rm -f /etc/systemd/system/${SSH_SERVICE}
  systemctl daemon-reload

  echo "[*] Cleaning iptables rules..."
  iptables -D INPUT -p udp --dport ${DNSTT_PORT} -j ACCEPT 2>/dev/null || true
  iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${DNSTT_PORT} 2>/dev/null || true

  echo "[*] Removing files..."
  rm -f "${WORKDIR}/server.key" "${WORKDIR}/server.pub"
  rm -f "$CONFIG_FILE"

  echo
  echo "✅ DNSTT removed successfully"
}

############################################
# GENERATE DNS LINK
############################################
generate_dns_link() {

  source "$CONFIG_FILE"

  if [[ ! -f "${WORKDIR}/server.pub" ]]; then
    echo "❌ Public key not found"
    exit 1
  fi

  PUBKEY_HEX=$(tr -d '\n' < server.pub)
  FIXED_PORT=6666
  FIXED_DNS="1.1.1.1:53"
  PROTO="udp"

  DNS_RAW="${DOMAIN}&${PUBKEY_HEX}&${FIXED_PORT}&${FIXED_DNS}&${PROTO}"
  DNS_BASE64=$(echo -n "$DNS_RAW" | base64 -w0)
  DNS_LINK="dns://${DNS_BASE64}"

  echo "$DNS_LINK"
}

############################################
# INSTALL
############################################
install_dnstt() {

  if [[ -f "$CONFIG_FILE" ]]; then
    echo "❌ DNSTT already installed"
    exit 1
  fi

  if [[ ! -x "$BIN_PATH" ]]; then
    echo "❌ dnstt-server not found or not executable"
    exit 1
  fi

  read -rp "DNSTT domain (e.g. t.example.com): " DOMAIN
  read -rp "DNSTT UDP port (default 5300): " DNSTT_PORT
  DNSTT_PORT=${DNSTT_PORT:-5300}
  read -rp "SOCKS port (default 8000): " SOCKS_PORT
  SOCKS_PORT=${SOCKS_PORT:-8000}
  
  # Get SSH port from systemd or default to 22
  SSH_PORT=$(ss -tlnp | grep -E 'sshd|ssh' | grep -oE ':[0-9]+' | head -1 | cut -d: -f2)
  
  # Alternative method if ss doesn't work
  if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    SSH_PORT=${SSH_PORT:-22}
  fi
  
  echo "[*] Detected SSH port: $SSH_PORT"

  cd "$WORKDIR"

  if [[ ! -f server.key ]]; then
    echo "[*] Generating DNSTT keys"
    chmod +x "$BIN_PATH"
    "$BIN_PATH" -gen-key -privkey-file server.key -pubkey-file server.pub
  fi

  if [[ ! -f /root/.ssh/id_ed25519 ]]; then
    echo "[*] Generating SSH key"
    mkdir -p /root/.ssh
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
    cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
  fi

  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/id_ed25519
  chmod 600 /root/.ssh/authorized_keys
  chmod 644 /root/.ssh/id_ed25519.pub

  # Save config
  cat > "$CONFIG_FILE" <<EOF
DOMAIN=${DOMAIN}
DNSTT_PORT=${DNSTT_PORT}
SOCKS_PORT=${SOCKS_PORT}
SSH_PORT=${SSH_PORT}
EOF

  # IPTABLES SERVICE
  cat >/etc/systemd/system/${IPT_SERVICE} <<EOF
[Unit]
Description=DNSTT IPTables Rules
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "iptables -I INPUT -p udp --dport ${DNSTT_PORT} -j ACCEPT; iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${DNSTT_PORT}"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  # DNSTT SERVICE
  cat >/etc/systemd/system/${DNSTT_SERVICE} <<EOF
[Unit]
Description=dnstt-server UDP tunnel
After=dnstt-iptables.service
Requires=dnstt-iptables.service

[Service]
User=root
WorkingDirectory=${WORKDIR}
ExecStart=${BIN_PATH} -udp :${DNSTT_PORT} -privkey-file server.key ${DOMAIN} 127.0.0.1:${SOCKS_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  # SSH SOCKS SERVICE - Fixed to use correct SSH port
  cat >/etc/systemd/system/${SSH_SERVICE} <<EOF
[Unit]
Description=Local SSH SOCKS Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /root/.ssh/id_ed25519 -N -D 127.0.0.1:${SOCKS_PORT} 127.0.0.1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dnstt-iptables dnstt ssh-socks
  systemctl start dnstt-iptables dnstt ssh-socks

  echo
  echo "=============================="
  echo "✅ DNSTT Installed Successfully"
  echo "=============================="
  echo
  echo "Domain: $DOMAIN"
  echo "SOCKS: socks5://127.0.0.1:${SOCKS_PORT}"
  echo "SSH Port: ${SSH_PORT}"
  echo
  echo "🔗 DNS LINK:"
  generate_dns_link
}

############################################
# SHOW LINK
############################################
show_dns_link() {

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ DNSTT not installed"
    exit 1
  fi

  echo
  echo "=============================="
  echo "🔗 DNS LINK"
  echo "=============================="
  echo
  generate_dns_link
}

############################################

case "$ACTION" in
  1) install_dnstt ;;
  2) remove_dnstt ;;
  3) show_dns_link ;;
  *) echo "❌ Invalid option"; exit 1 ;;
esac
