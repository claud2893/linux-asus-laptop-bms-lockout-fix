#!/usr/bin/env bash
# ==============================================================================
# Fix Aftermarket Battery BMS Lockups on Asus UX535FTC (Linux) - v1.1.0
# ==============================================================================
# Automates:
#   1. Enforcing Windows ACPI compatibility (acpi_osi='Windows 2020') in GRUB
#   2. Disabling USB (XHC) ACPI wakeup at boot via systemd
#   3. Unloading asus_wmi holders and Asus WMI modules in late systemd-shutdown
# ==============================================================================

set -euo pipefail

# Ensure the script is run with root privileges
if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: This script must be run as root. Try: sudo $0" >&2
    exit 1
fi

echo "==> [1/3] Configuring GRUB ACPI compatibility (acpi_osi='Windows 2020')..."

GRUB_FILE="/etc/default/grub"
if [[ -f "${GRUB_FILE}" ]]; then
    if grep -q "acpi_osi=" "${GRUB_FILE}"; then
        echo "    acpi_osi parameter already present in ${GRUB_FILE}. Skipping modification."
    else
        BACKUP_FILE="${GRUB_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "${GRUB_FILE}" "${BACKUP_FILE}"
        echo "    Backed up ${GRUB_FILE} to ${BACKUP_FILE}"

        sed -i -E 's/^(GRUB_CMDLINE_LINUX="[^"]*)"/\1 acpi_osi='''Windows 2020'''"/' "${GRUB_FILE}"
        echo "    Added acpi_osi='Windows 2020' to GRUB_CMDLINE_LINUX."

        if command -v grub2-mkconfig >/dev/null 2>&1; then
            grub2-mkconfig -o /boot/grub2/grub.cfg
            echo "    Regenerated /boot/grub2/grub.cfg."
        elif command -v update-grub >/dev/null 2>&1; then
            update-grub
            echo "    Updated GRUB configuration."
        else
            echo "    Warning: Could not find grub2-mkconfig or update-grub. Update GRUB manually." >&2
        fi
    fi
else
    echo "    Warning: ${GRUB_FILE} not found. Skipping GRUB configuration." >&2
fi

echo "==> [2/3] Creating systemd service to disable XHC USB ACPI wakeup at boot..."

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

systemctl daemon-reload
systemctl enable --now disable-xhc-wakeup.service
echo "    Enabled and started disable-xhc-wakeup.service."

echo "==> [3/3] Installing late-stage systemd-shutdown hook for Asus WMI modules..."

# Remove permanent blacklist if present so Fn hotkeys remain functional during active sessions
if [[ -f /etc/modprobe.d/blacklist-asus-wmi.conf ]]; then
    rm -f /etc/modprobe.d/blacklist-asus-wmi.conf
    echo "    Removed /etc/modprobe.d/blacklist-asus-wmi.conf."
fi

# Migrate from v1.0.0 early shutdown.target unit if installed
if [[ -f /etc/systemd/system/unload-asus-wmi.service ]]; then
    systemctl disable unload-asus-wmi.service 2>/dev/null || true
    rm -f /etc/systemd/system/unload-asus-wmi.service
    systemctl daemon-reload
    echo "    Removed legacy unload-asus-wmi.service unit."
fi

mkdir -p /usr/lib/systemd/system-shutdown
cat << 'EOF' > /usr/lib/systemd/system-shutdown/unload-asus-wmi.shutdown
#!/bin/sh
if [ -d /sys/module/asus_wmi/holders ]; then
    for holder in /sys/module/asus_wmi/holders/*; do
        [ -e "$holder" ] && /usr/sbin/modprobe -r "$(basename "$holder")" 2>/dev/null || true
    done
fi
/usr/sbin/modprobe -r asus_nb_wmi asus_wmi 2>/dev/null || true
EOF

chmod +x /usr/lib/systemd/system-shutdown/unload-asus-wmi.shutdown
echo "    Installed /usr/lib/systemd/system-shutdown/unload-asus-wmi.shutdown."

echo ""
echo "Setup complete! Please reboot your system to ensure all changes are active."
