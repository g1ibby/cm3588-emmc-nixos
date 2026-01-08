# NixOS on CM3588

Install NixOS on FriendlyELEC CM3588 (NAS Kit) to internal eMMC storage.

Two installation options:
- **Standard** - Simple installation without encryption
- **LUKS Encrypted** - Full disk encryption with remote SSH unlock

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

Choose one option:

#### Option A: Standard Installation (no encryption)

```bash
bash /root/install-to-emmc.sh
```

After installation, remove USB and reboot. SSH directly to the system.

#### Option B: LUKS Encrypted Installation (recommended for NAS)

```bash
bash /root/install-to-emmc-with-luks.sh
```

The script will:
1. Partition eMMC (idbloader, U-Boot, /boot, encrypted root)
2. Prompt you to create a LUKS passphrase (type `YES` in uppercase to confirm)
3. Generate SSH host keys for initrd
4. Install NixOS with remote unlock configuration

**Save the SSH fingerprint displayed at the end!**

## Remote Unlock (LUKS only)

After installing with LUKS encryption, each boot requires remote unlock:

1. Power on CM3588
2. Wait ~30 seconds for network initialization
3. SSH to initrd:
   ```bash
   ssh -p 2222 root@<IP>
   ```
4. Run the unlock command:
   ```bash
   systemd-tty-ask-password-agent --query
   ```
5. Enter your LUKS passphrase when prompted
6. Connection closes automatically after unlock
7. Wait ~10 seconds, then SSH to the full system:
   ```bash
   ssh root@<IP>
   ```

## Partition Layout

### Standard Installation

| Partition | Size | Purpose |
|-----------|------|---------|
| 1 | 8 MiB | idbloader (Rockchip) |
| 2 | 8 MiB | U-Boot |
| 3 | Remaining | Root filesystem |

### LUKS Installation

| Partition | Size | Purpose |
|-----------|------|---------|
| 1 | 8 MiB | idbloader (Rockchip) |
| 2 | 8 MiB | U-Boot |
| 3 | 512 MiB | /boot (unencrypted) |
| 4 | Remaining | LUKS encrypted root |

## Customization

Edit the install script before running to change:
- `HOSTNAME` (default: cm3588-nas)
- `USERNAME` (default: user)
- `TIMEZONE` (default: Asia/Bangkok)

## Troubleshooting

### Can't find IP address
- Check your router's DHCP lease table
- Use `nmap -sn 192.168.1.0/24` (adjust for your network)

### SSH connection refused on port 2222 (LUKS)
- Wait longer for initrd network to initialize (~30 seconds)
- Verify ethernet cable is connected
- Check if board finished POST (LEDs active)

### Two different IPs appear in router
This is normal with LUKS setup - initrd and full system may get different DHCP leases. Set a static lease on your router to fix this.

### Network driver issues
If ethernet doesn't work in initrd, you may need to add kernel modules. Edit `boot.initrd.availableKernelModules` in the generated config.

### Recovery (LUKS)
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
