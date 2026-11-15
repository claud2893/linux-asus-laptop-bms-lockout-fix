#!/usr/bin/env bash
set -euo pipefail

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with sudo or as root."
   echo "Usage: sudo ./install.sh"
   exit 1
fi

echo "=== Asus UX535FTC Aftermarket Battery BMS Fix ==="

# 1. Configure GRUB ACPI parameter
GRUB_FILE="/etc/default/grub"
if [[ -f "$GRUB_FILE" ]]; then
    if grep -q "acpi_osi='Windows 2020'" "$GRUB_FILE"; then
        echo "[1/3] GRUB already contains acpi_osi='Windows 2020'. Skipping."
    else
        echo "[1/3] Backing up $GRUB_FILE to ${GRUB_FILE}.bak and adding ACPI parameter..."
        cp "$GRUB_FILE" "${GRUB_FILE}.bak"
        sed -i 's/^\(GRUB_CMDLINE_LINUX="[^"]*\)"/\1 acpi_osi='\''Windows 2020'\''"/' "$GRUB_FILE"
        
        if command -v grub2-mkconfig &> /dev/null; then
            grub2-mkconfig -o /boot/grub2/grub.cfg
        elif command -v update-grub &> /dev/null; then
            update-grub
        else
            echo "Warning: Could not find grub2-mkconfig or update-grub. Please update GRUB manually."
        fi
    fi
else
    echo "Warning: $GRUB_FILE not found. Skipping GRUB configuration."
fi

# 2. Create systemd service to disable XHC USB wakeup
echo "[2/3] Creating disable-xhc-wakeup.service..."
cat << 'EOF' > /etc/systemd/system/disable-xhc-wakeup.service
[Unit]
Description=Disable XHC USB Wakeup to allow clean S5 power state
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'grep -q "XHC.*enabled" /proc/acpi/wakeup && echo XHC > /proc/acpi/wakeup || true'

[Install]
WantedBy=multi-user.target
EOF

# 3. Create systemd service to cleanly unload asus_wmi before shutdown
echo "[3/3] Creating unload-asus-wmi.service..."
cat << 'EOF' > /etc/systemd/system/unload-asus-wmi.service
[Unit]
Description=Unload ASUS WMI modules cleanly before shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=-/usr/sbin/modprobe -r asus_nb_wmi asus_wmi

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF

# Reload systemd and enable both services
echo "Reloading systemd daemon and enabling services..."
systemctl daemon-reload
systemctl enable --now disable-xhc-wakeup.service
systemctl enable unload-asus-wmi.service

echo "=== Setup Complete ==="
echo "Please reboot your laptop to apply the GRUB ACPI changes."
