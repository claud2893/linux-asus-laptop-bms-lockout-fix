# Fixing Aftermarket Battery BMS Lockups on Asus UX535FTC (Fedora Linux)

## Root Cause Summary

Non-original replacement batteries use generic Battery Management System (BMS) microcontrollers to emulate Asus SMBus communication protocols. During a standard Fedora shutdown, proprietary Asus WMI driver teardown packets and active USB controller wake states cause the motherboard's Embedded Controller (EC) to continue polling the battery or send unrecognized commands.

This triggers a safety lockout inside the replacement battery's BMS, cutting the main voltage rail to $0\text{V}$. Because the Asus UX535FTC lacks a separate CMOS coin-cell battery, losing main battery power also resets the motherboard's Real-Time Clock (RTC).

## Step 1: Enforce Windows ACPI Compatibility in GRUB

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

   ```bash
   sudo grub2-mkconfig -o /boot/grub2/grub.cfg
   ```

## Step 2: Disable USB (XHC) ACPI Wakeup at Boot

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

## Step 3: Unload Asus WMI Modules Cleanly Before Shutdown

The `asus_wmi` and `asus_nb_wmi` kernel modules are required during an active session to translate proprietary hotkeys such as `Fn+F6` (touchpad toggle) and `Fn+F7` (keyboard backlight). However, their driver unbind routines during standard shutdown teardown can crash a third-party BMS. Unloading these modules via a pre-shutdown hook preserves hotkey support while ensuring a clean power-off.

1. Ensure no modprobe blacklist or custom option files are blocking the modules, and rebuild `initramfs` if needed:

   ```bash
   sudo rm -f /etc/modprobe.d/blacklist-asus-wmi.conf /etc/modprobe.d/asus_wmi.conf
   sudo dracut --force
   ```

2. Create a `systemd` service that unloads `asus_nb_wmi` and `asus_wmi` right before the kernel executes shutdown or reboot:

   ```bash
   cat << 'EOF' | sudo tee /etc/systemd/system/unload-asus-wmi.service
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
   ```

3. Reload `systemd` and enable the service *(do **not** use `--now`, as it should only run when shutting down or rebooting)*:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable unload-asus-wmi.service
   ```

*(Note: If you ever need a stricter fallback, permanently blacklisting `asus_wmi` and `asus_nb_wmi` in `/etc/modprobe.d/blacklist-asus-wmi.conf` followed by `sudo dracut --force` will isolate the battery completely at the cost of `Fn+F6` and `Fn+F7`).*

## Verification & Recovery Steps

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