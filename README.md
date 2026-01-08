# NixOS on CM3588

Install NixOS on FriendlyELEC CM3588 (NAS Kit) to internal eMMC storage with full disk encryption (LUKS) and remote SSH unlock.

## Features

- Full LUKS2 encryption for root filesystem
- Remote unlock via SSH (no monitor/keyboard needed)
- Separate unencrypted `/boot` partition
- Automatic DHCP for network in initrd

## Prerequisites

- CM3588 NAS Kit with eMMC
- NixOS machine (for building)
- USB drive or microSD card (8GB+)
- Ethernet connection (required for remote unlock)
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

The script will:
1. Partition eMMC (idbloader, U-Boot, /boot, encrypted root)
2. Prompt you to create a LUKS passphrase
3. Generate SSH host keys for initrd
4. Install NixOS with remote unlock configuration

**Save the SSH fingerprint displayed at the end!**

### Step 4: First Boot with Remote Unlock

1. Power off and remove USB
2. Power on CM3588
3. Wait ~30 seconds for network initialization
4. SSH to initrd for unlock:
   ```bash
   ssh -p 2222 root@<IP>
   ```
5. Enter your LUKS passphrase when prompted
6. After successful unlock, SSH to the full system:
   ```bash
   ssh root@<IP>
   ```

## Partition Layout

| Partition | Size | Purpose |
|-----------|------|---------|
| 1 | 8 MiB | idbloader (Rockchip) |
| 2 | 8 MiB | U-Boot |
| 3 | 512 MiB | /boot (unencrypted) |
| 4 | Remaining | LUKS encrypted root |

## Customization

Edit `install-to-emmc.sh` before running to change:
- `HOSTNAME` (default: cm3588-nas)
- `USERNAME` (default: user)
- `TIMEZONE` (default: Asia/Bangkok)

## Troubleshooting

### Can't find IP address
- Check your router's DHCP lease table
- Use `nmap -sn 192.168.1.0/24` (adjust for your network)

### SSH connection refused on port 2222
- Wait longer for initrd network to initialize
- Verify ethernet cable is connected
- Check if board finished POST (LEDs active)

### Network driver issues
If ethernet doesn't work in initrd, you may need to add kernel modules. Edit the `boot.initrd.availableKernelModules` in the generated config.

### Recovery
If remote unlock fails, boot from USB and manually unlock:
```bash
cryptsetup luksOpen /dev/mmcblk0p4 cryptroot
mount /dev/mapper/cryptroot /mnt
mount /dev/mmcblk0p3 /mnt/boot
nixos-enter --root /mnt
# Debug and fix configuration
```

## Credits

Uses [Mic92/nixos-aarch64-images](https://github.com/Mic92/nixos-aarch64-images)
