# Linux RTL8188CU comparison test (Pi 1B, second SD card)

## Why

DhruvaOS's WiFi join sends a byte-for-byte correct Authentication Request
(verified against a real Linux client's own usbmon-captured transfer to
this exact AP), gets a clean USB-level ACK/XFERCOMPL from the RTL8188CU
chip, and still produces zero over-the-air transmission (confirmed via two
independent, fully-covered external monitor-mode captures). Swapping
dongles, USB ports, and entire Pi 1B boards all reproduce the identical
failure. Everything checkable in DhruvaOS's own software, and everything
cross-referenced against Linux's and FreeBSD's independent RTL8188CU
drivers, has been checked. The one experiment left that can distinguish
"DhruvaOS software bug" from "every Pi 1B has this and Linux works around
it somehow we haven't found" is running an actual Linux kernel on this same
board, against the same dongle, against the same AP.

## Flashing instructions

1. Get **Raspberry Pi Imager** (official tool):
   https://www.raspberrypi.com/software/
2. **Choose OS → Raspberry Pi OS (other) → Raspberry Pi OS (Legacy, 32-bit)
   Lite.** "Legacy" is the current official build that still supports
   ARMv6 boards (original Pi 1, Zero) -- current non-Legacy releases have
   dropped that. Debian Bookworm-based, with the RTL8188CU driver
   (`rtl8192cu`/`rtl8xxxu`) already built into the kernel -- no extra
   firmware install needed.
3. **Choose Storage → the NEW SD card** (not the DhruvaOS one -- double
   check before writing).
4. Click the gear icon (or `Ctrl+Shift+X`) → **OS customization**, and set:
   - **General tab**: hostname (anything), username `virgo`, password
     `virgo`
   - **Services tab**: enable SSH, password authentication
   - **Wi-Fi tab**: SSID and password from `~/home-wifi-ssid.txt` /
     `~/home-wifi-pwd.txt` (type them in directly -- not reproduced here)
5. **Write.** Boot the Pi with this card. It auto-connects to *some* AP
   broadcasting that SSID on first boot -- but since both the main router
   and the extender share it, that connection might land on either one,
   which wouldn't test what we need.

## After first boot

SSH in (`ssh virgo@<its-dhcp-ip>`, password `virgo`), copy over
`test/linux_rtl8188_diag.sh` from this repo (e.g.
`scp test/linux_rtl8188_diag.sh virgo@<its-dhcp-ip>:`), and run:

```
sudo ./linux_rtl8188_diag.sh "<ssid>" "<password>"
```

This explicitly pins the connection to `C8:A7:0A:C6:DD:78` (the main
router DhruvaOS has been failing against -- *not* the extender), detects
whether the image uses NetworkManager or `wpa_supplicant` and handles
either, and captures `dmesg`, driver binding, a scan confirming the BSSID
is visible, the actual connection attempt, and final link state -- all
into one timestamped log file it tells you how to copy back.

To test the extender instead for comparison, pass its BSSID as a third
argument:

```
sudo ./linux_rtl8188_diag.sh "<ssid>" "<password>" B0:19:21:E1:69:E1
```

## What settles the question

- **Linux associates to `C8:A7:0A:C6:DD:78` successfully** → the problem is
  specific to DhruvaOS's own driver/bring-up sequence (or something about
  it that a from-scratch implementation hits and Linux's own driver
  avoids) -- not a property of this Pi 1B's own DWC2 silicon or this exact
  AP.
- **Linux also fails against `C8:A7:0A:C6:DD:78`** → investigate the
  board/AP combination itself (this exact BCM2835 unit's DWC2 controller,
  or something specific to this one AP), independent of DhruvaOS entirely.
