#!/usr/bin/env bash
# Installs the read-only Blackwell eGPU Status widget for the current user.
# Everything is user-level: no sudo, no sudoers entries, no udev rules.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
PLASMOID_DIR="$HOME/.local/share/plasma/plasmoids/com.github.blackwellegpu.status"

echo "=== Installing status backend to $BIN_DIR ==="
mkdir -p "$BIN_DIR"
install -m 755 "$SCRIPT_DIR/blackwell-egpu-status" "$BIN_DIR/blackwell-egpu-status"

echo "=== Installing Plasma 6 applet ==="
rm -rf "$PLASMOID_DIR"
mkdir -p "$(dirname "$PLASMOID_DIR")"
cp -r "$SCRIPT_DIR/com.github.blackwellegpu.status" "$PLASMOID_DIR"
# The applet calls the backend by absolute path; point it at this user's home
sed -i "s|__HOME__|$HOME|g" "$PLASMOID_DIR/contents/ui/main.qml"

echo "=== Verifying backend output ==="
"$BIN_DIR/blackwell-egpu-status" || { echo "[-] Backend failed to run"; exit 1; }

echo ""
echo "[+] Installed. Restart plasmashell to register the widget:"
echo "      systemctl --user restart plasma-plasmashell.service"
echo "    then add it to a panel via Edit Mode -> Add Widgets -> 'Blackwell eGPU Status',"
echo "    or from a terminal:"
echo "      qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \\"
echo "        'panels()[0].addWidget(\"com.github.blackwellegpu.status\")'"
echo "    You can also run it as a standalone window without touching any panel:"
echo "      plasmawindowed com.github.blackwellegpu.status"
echo ""
echo "    Uninstall: remove the widget from your panel, then delete"
echo "      $BIN_DIR/blackwell-egpu-status"
echo "      $PLASMOID_DIR"
