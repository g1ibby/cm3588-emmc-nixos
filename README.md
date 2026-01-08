# NixOS on CM3588

Install NixOS on FriendlyELEC CM3588 (NAS Kit) to internal eMMC storage.

## Prerequisites

- CM3588 NAS Kit with eMMC
- NixOS machine (for building)
- USB drive or microSD card (8GB+)
- Ethernet connection
- SSH key at `~/.ssh/id_ed25519.pub`

## Installation

### Step 1: Flash USB

```bash
bash flash-cm3588-usb.sh
```

This builds the NixOS image, flashes it to USB, and adds your SSH key.

### Step 2: Boot and SSH

1. Insert USB into CM3588
2. Connect Ethernet
3. Power on and wait ~1 minute
4. Find IP: `nmap -sn 192.168.1.0/24`
5. SSH in: `ssh root@<IP>`

### Step 3: Install to eMMC

```bash
bash /root/install-to-emmc.sh
```

The script partitions eMMC, copies bootloader, and installs NixOS. When done, power off, remove USB, and boot from eMMC.

## Customization

Edit `install-to-emmc.sh` before running to change:
- `HOSTNAME` (default: cm3588-nas)
- `USERNAME` (default: user)
- `TIMEZONE` (default: Asia/Bangkok)

## Credits

Uses [Mic92/nixos-aarch64-images](https://github.com/Mic92/nixos-aarch64-images)
