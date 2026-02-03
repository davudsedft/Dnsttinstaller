#!/usr/bin/env bash
set -e

if [[ $EUID -ne 0 ]]; then
  echo "❌ Run as root"
  exit 1
fi

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
BIN_NAME="dnstt-server"
BIN_PATH="${WORKDIR}/${BIN_NAME}"

IPT_SERVICE="dnstt-iptables.service"
DNSTT_SERVICE="dnstt.service"
SSH_SERVICE="ssh-socks.service"

echo "=============================="
echo " DNSTT Manager"
echo "=============================="
echo "1) Install DNSTT"
echo "2) Remove DNSTT"
echo
read -rp "Select option [1-2]: " ACTION

############################################
# REMOVE
############################################
remove_dnstt() {
  echo "[*] Stopping services..."
  systemctl stop dnstt ssh-socks dnstt-iptables 2>/dev/null || true
  systemctl disable dnstt ssh-socks dnstt-iptables 2>/dev/null || true

  echo "[*] Removing systemd services..."
  rm -f /etc/systemd/system/${IPT_SERVICE}
  rm -f /etc/systemd/system/${DNSTT_SERVICE}
  rm -f /etc/systemd/system/${SSH_SERVICE}

  systemctl daemon-reload

  echo "[*] Cleaning iptables rules..."
  iptables -D INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
  iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT 2>/dev/null || true

  echo "[*] Removing DNSTT files..."
  rm -f "${WORKDIR}/server.key" "${WORKDIR}/server.pub"

  echo
  echo "✅ DNSTT removed successfully"
}

############################################
# INSTALL
############################################
install_dnstt() {
  echo "[*] Working directory: $WORKDIR"

  # بررسی باینری
  if [[ ! -x "$BIN_PATH" ]]; then
    echo "❌ dnstt-server not found or not executable in:"
    echo "   $WORKDIR"
    exit 1
  fi

  # ورودی‌ها
  read -rp "DNSTT domain (e.g. t.example.com): " DOMAIN
  read -rp "DNSTT UDP port (default 5300): " DNSTT_PORT
  DNSTT_PORT=${DNSTT_PORT:-5300}
  read -rp "SOCKS port (default 8000): " SOCKS_PORT
  SOCKS_PORT=${SOCKS_PORT:-8000}

  cd "$WORKDIR"

  # ساخت کلیدهای dnstt
  if [[ ! -f server.key ]]; then
    echo "[*] Generating DNSTT keys"
    chmod +x "$BIN_PATH"
    "$BIN_PATH" -gen-key -privkey-file server.key -pubkey-file server.pub
  fi

  # ساخت SSH key (localhost)
  if [[ ! -f /root/.ssh/id_ed25519 ]]; then
    echo "[*] Generating SSH key"
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
    cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
  fi

  # ---------------- iptables service ----------------
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

  # ---------------- dnstt service ----------------
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

  # ---------------- ssh socks service ----------------
  cat >/etc/systemd/system/${SSH_SERVICE} <<EOF
[Unit]
Description=Local SSH SOCKS Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/ssh -i /root/.ssh/id_ed25519 -N -D 127.0.0.1:${SOCKS_PORT} 127.0.0.1
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

  # فعال‌سازی سرویس‌ها
  systemctl daemon-reload
  systemctl enable dnstt-iptables dnstt ssh-socks
  systemctl start dnstt-iptables dnstt ssh-socks

  # ---------------- خروجی لینک DNS ----------------
  PUBKEY_HEX=$(cat server.pub | tr -d '\n')
  FIXED_PORT=6666
  FIXED_DNS="8.8.8.8:53"
  PROTO="udp"
  DNS_RAW="${DOMAIN}&${PUBKEY_HEX}&${FIXED_PORT}&${FIXED_DNS}&${PROTO}"
  DNS_BASE64=$(echo -n "$DNS_RAW" | base64 -w0)
  DNS_LINK="dns://${DNS_BASE64}"

  echo
  echo "=============================="
  echo "✅ DNSTT INSTALLED"
  echo "=============================="
  echo
  echo "Working directory: $WORKDIR"
  echo "DNSTT domain: $DOMAIN"
  echo "Public key: $PUBKEY_HEX"
  echo "SOCKS proxy: socks5://127.0.0.1:${SOCKS_PORT}"
  echo "DNS link: $DNS_LINK"
}

############################################

case "$ACTION" in
  1) install_dnstt ;;
  2) remove_dnstt ;;
  *) echo "❌ Invalid option"; exit 1 ;;
esac
