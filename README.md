# Asus Aftermarket Battery BMS Fix (Linux)

A solution for replacement (non-OEM) battery safety lockouts and Real-Time Clock (RTC) resets on Asus laptops running Linux, while keeping proprietary `Fn` hotkeys functional. The following method has been tested on an **Asus ZenBook Pro 15 (UX535FTC)** running Fedora Linux.

## Root Cause Summary

Non-original replacement batteries use generic Battery Management System (BMS) microcontrollers to emulate Asus SMBus communication protocols. During a standard Linux shutdown, proprietary Asus WMI driver teardown packets and active USB controller wake states cause the motherboard's Embedded Controller (EC) to continue polling the battery or send unrecognized commands.

This triggers a safety lockout inside the replacement battery's BMS, cutting the main voltage rail to $0\text{V}$ (requiring physical battery disconnection to recover). Because the Asus UX535FTC lacks a separate CMOS coin-cell battery, losing main battery power also resets the motherboard's Real-Time Clock (RTC).

Because desktop power daemons (`upowerd`, `systemd-backlight`) and dependent sub-modules hold active references to `asus_wmi` until userspace has completely stopped, unloading the modules must occur in a late-stage `systemd-shutdown` hook after clearing `/sys/module/asus_wmi/holders`.

## Repository Contents

* `fix-asus-battery-bms.sh` — Automated setup script that configures GRUB, disables `XHC` USB wakeup, and installs the late-stage `systemd-shutdown` hook (also automatically upgrades installations from `v1.0.0`).
* `README.md` — Technical overview, manual installation steps, verification, and recovery instructions.

---

## Option 1: Quick Setup (Automated Script)

> **Safety Note:** Always inspect scripts before executing them with `sudo`. This script automatically creates a timestamped backup of `/etc/default/grub` before modifying it and supports Fedora/RHEL (`grub2-mkconfig`) as well as Debian/Ubuntu (`update-grub`).

1. Download the latest release script (or use the copy in this repository) and make it executable:

   ```bash
   curl -LO https://github.com/claud2893/asus-ux535-linux-battery-fix/releases/latest/download/fix-asus-battery-bms.sh
   chmod +x fix-asus-battery-bms.sh
   ```

2. Run the script with root privileges:

   ```bash
   sudo ./fix-asus-battery-bms.sh
   ```

3. **Reboot** your system so the GRUB kernel parameter takes effect.

---

## Option 2: Manual Installation

If you prefer to apply the changes step by step without running the script, complete the three steps below.

### Step 1: Enforce Windows ACPI Compatibility in GRUB

Asus BIOS firmware frequently contains ACPI Dynamic Platform and Thermal Framework (DPTF) table references that throw `AE_NOT_FOUND` errors under default Linux ACPI identification. Passing `acpi_osi='Windows 2020'` forces the BIOS to expose standard Windows-compatible ACPI power methods.

1. Open the GRUB configuration file:

   ```bash
   sudo nano /etc/default/grub
   ```

2. Locate the `GRUB_CMDLINE_LINUX` line and append `acpi_osi='Windows 2020'` inside the quotes:

   ```bash
   GRUB_CMDLINE_LINUX="rhgb quiet acpi_osi='Windows 2020'"
   ```

   *(Keep any existing parameters such as `resume=...` or `rd.lvm.lv=...` intact).*

3. Regenerate the GRUB configuration file to apply the kernel parameter:

   * **Fedora / RHEL:**
     ```bash
     sudo grub2-mkconfig -o /boot/grub2/grub.cfg
     ```
   * **Ubuntu / Debian:**
     ```bash
     sudo update-grub
     ```

### Step 2: Disable USB (XHC) ACPI Wakeup at Boot

If the Intel xHCI USB Host Controller (`XHC`) remains enabled as an ACPI wake source, it stays in a powered standby state (`D3hot`) instead of powering down completely (`D3cold`). This keeps the EC partially active after shutdown, continuously pinging the battery over SMBus until the aftermarket BMS crashes.

1. Create a `systemd` service that automatically disables `XHC` wakeup on every boot:

   ```bash
   cat << 'EOF' | sudo tee /etc/systemd/system/disable-xhc-wakeup.service
   [Unit]
   Description=Disable XHC USB Wakeup to allow clean S5 power state
   After=multi-user.target

   [Service]
   Type=oneshot
   ExecStart=/bin/sh -c 'grep -q "XHC.*enabled" /proc/acpi/wakeup && echo XHC > /proc/acpi/wakeup || true'

   [Install]
   WantedBy=multi-user.target
   EOF
   ```

2. Reload `systemd` and enable the service:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now disable-xhc-wakeup.service
   ```

### Step 3: Unload Asus WMI Modules via Late-Stage `systemd-shutdown`

The `asus_wmi` and `asus_nb_wmi` kernel modules are required during an active session to translate proprietary hotkeys such as `Fn+F6` (touchpad toggle) and `Fn+F7` (keyboard backlight). However, unloading them at `shutdown.target` often fails (`Module asus_wmi is in use`) because desktop services and dependent sub-modules still hold open references. Placing an executable script in `/usr/lib/systemd/system-shutdown/` ensures `asus_wmi` and its holders are unloaded right before kernel power-off after all userspace processes have exited.

1. Ensure no modprobe blacklist or custom option files are blocking the modules, and remove any legacy `unload-asus-wmi.service` unit:

   ```bash
   sudo rm -f /etc/modprobe.d/blacklist-asus-wmi.conf /etc/modprobe.d/asus_wmi.conf
   sudo systemctl disable unload-asus-wmi.service 2>/dev/null || true
   sudo rm -f /etc/systemd/system/unload-asus-wmi.service
   sudo systemctl daemon-reload
   ```

2. Create the late-stage shutdown hook and make it executable:

   ```bash
   sudo mkdir -p /usr/lib/systemd/system-shutdown
   cat << 'EOF' | sudo tee /usr/lib/systemd/system-shutdown/unload-asus-wmi.shutdown
   #!/bin/sh
   if [ -d /sys/module/asus_wmi/holders ]; then
       for holder in /sys/module/asus_wmi/holders/*; do
           [ -e "$holder" ] && /usr/sbin/modprobe -r "$(basename "$holder")" 2>/dev/null || true
       done
   fi
   /usr/sbin/modprobe -r asus_nb_wmi asus_wmi 2>/dev/null || true
   EOF
   sudo chmod +x /usr/lib/systemd/system-shutdown/unload-asus-wmi.shutdown
   ```

> **Dual-Boot Tip (Windows):** If you dual-boot with Windows, disable **Turn on fast startup** under *Control Panel → Power Options → Choose what the power buttons do* so Windows performs a cold shutdown instead of leaving Embedded Controller states latched across reboots.

> **Fallback Option:** If you ever need a stricter fallback, permanently blacklisting `asus_wmi` and `asus_nb_wmi` in `/etc/modprobe.d/blacklist-asus-wmi.conf` followed by `sudo dracut --force` will isolate the battery completely at the cost of `Fn+F6` and `Fn+F7`.

---

## Verification, Recovery & Uninstallation

### Verify Hardware RTC Stability

To confirm the motherboard's Real-Time Clock retained power across shutdowns (before network time sync runs), check the boot log timestamp:

```bash
sudo dmesg | grep -i "setting system clock"
```

### Resynchronize the Hardware Clock (If Power Was Cut)

If the BMS ever cuts standby power and resets your system date/time, restore the system clock via NTP and write the corrected time back to the motherboard's hardware clock:

```bash
sudo timedatectl set-ntp true
sudo hwclock --systohc
```

### Revert / Uninstall Changes

To remove the `systemd` units, shutdown hook, and restore your original GRUB configuration:

1. Remove the shutdown hook and wakeup service:

   ```bash
   sudo rm -f /usr/lib/systemd/system-shutdown/unload-asus-wmi.shutdown
   sudo systemctl disable --now disable-xhc-wakeup.service
   sudo rm -f /etc/systemd/system/disable-xhc-wakeup.service
   sudo systemctl daemon-reload
   ```

2. Restore your GRUB backup (replace `<timestamp>` with your backup filename) and regenerate GRUB:

   ```bash
   sudo cp /etc/default/grub.bak.<timestamp> /etc/default/grub
   sudo grub2-mkconfig -o /boot/grub2/grub.cfg
   ```

## License

This project is licensed under the MIT License.
