#!/usr/bin/env bash
#
# install.sh — Install controlled-system-update auto-mode
# Sets up the script, config, and systemd timer/service
#
# Usage: sudo bash install.sh
# License: MIT
#
set -euo pipefail

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
CONFIG_DIR="/etc/controlled-system-update"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Controlled System Update Installer ==="
echo

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

# 1. Install the script
echo "[1/5] Installing auto-update.sh to ${INSTALL_PREFIX}/bin/"
install -Dm755 "${SCRIPT_DIR}/scripts/auto-update.sh" "${INSTALL_PREFIX}/bin/auto-update.sh"
echo "  -> Installed ${INSTALL_PREFIX}/bin/auto-update.sh"

# 2. Install config
echo "[2/5] Installing config to ${CONFIG_DIR}/"
if [[ -f "${CONFIG_DIR}/auto-update.conf" ]]; then
    echo "  -> Config already exists, backing up..."
    cp "${CONFIG_DIR}/auto-update.conf" "${CONFIG_DIR}/auto-update.conf.bak.$(date +%Y%m%d)"
fi
install -Dm600 "${SCRIPT_DIR}/config/auto-update.conf" "${CONFIG_DIR}/auto-update.conf"
chmod 600 "${CONFIG_DIR}/auto-update.conf"
echo "  -> Installed ${CONFIG_DIR}/auto-update.conf (permissions: 600)"
echo "  -> EDIT THIS FILE to set your Telegram bot token and chat ID!"

# 3. Install systemd units
echo "[3/5] Installing systemd units"
install -Dm644 "${SCRIPT_DIR}/systemd/controlled-system-update.service" \
    /etc/systemd/system/controlled-system-update.service
install -Dm644 "${SCRIPT_DIR}/systemd/controlled-system-update.timer" \
    /etc/systemd/system/controlled-system-update.timer
systemctl daemon-reload
echo "  -> Installed service + timer"

# 4. Create log directory
echo "[4/5] Creating log directory"
mkdir -p /var/log/controlled-system-update
echo "  -> /var/log/controlled-system-update/"

# 5. Enable timer
echo "[5/5] Enabling timer"
systemctl enable controlled-system-update.timer
systemctl start controlled-system-update.timer
echo "  -> Timer enabled and started"

echo
echo "=== Installation Complete ==="
echo
echo "Next steps:"
echo "  1. Edit ${CONFIG_DIR}/auto-update.conf — set TG_BOT_TOKEN and TG_CHAT_ID"
echo "  2. Test manually: ${INSTALL_PREFIX}/bin/auto-update.sh"
echo "  3. Check timer:  systemctl status controlled-system-update.timer"
echo "  4. View logs:    journalctl -u controlled-system-update -f"
echo "  5. Check next run: systemctl list-timers controlled-system-update"
echo
echo "To uninstall:"
echo "  systemctl disable --now controlled-system-update.timer"
echo "  rm ${INSTALL_PREFIX}/bin/auto-update.sh"
echo "  rm /etc/systemd/system/controlled-system-update.{service,timer}"
echo "  systemctl daemon-reload"
