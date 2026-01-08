#!/usr/bin/env bash
set -euo pipefail

# Configuration - embedded values
HOSTNAME="cm3588-nas"
USERNAME="user"
TIMEZONE="Asia/Bangkok"

MOUNT_POINT="/mnt"

echo "=== CM3588 NixOS eMMC Installation Script ==="
echo ""

# Auto-detect boot device (USB/SD we booted from)
# Use readlink -f to resolve symlinks (e.g., /dev/disk/by-label/NIXOS_SD -> /dev/mmcblk1p3)
BOOT_PARTITION_RAW=$(findmnt -n -o SOURCE /)
BOOT_PARTITION=$(readlink -f "$BOOT_PARTITION_RAW")
BOOT_DEVICE=$(echo "$BOOT_PARTITION" | sed 's/p[0-9]*$//')

echo "Detecting devices..."
echo "  Boot partition: $BOOT_PARTITION (was: $BOOT_PARTITION_RAW)"
echo "  Boot device: $BOOT_DEVICE"

# Auto-detect eMMC (has boot partitions, and is not our boot device)
EMMC_DEVICE=""
for dev in /dev/mmcblk[0-9]; do
    if [[ -b "${dev}boot0" ]] && [[ "$dev" != "$BOOT_DEVICE" ]]; then
        EMMC_DEVICE="$dev"
        break
    fi
done

if [[ -z "$EMMC_DEVICE" ]]; then
    echo "ERROR: Could not detect eMMC device"
    echo "Looking for mmcblk device with boot partitions that isn't $BOOT_DEVICE"
    echo ""
    echo "Available block devices:"
    lsblk
    exit 1
fi

echo "  eMMC device: $EMMC_DEVICE"

# Safety check: make sure we're not about to wipe the boot device
if [[ "$EMMC_DEVICE" == "$BOOT_DEVICE" ]]; then
    echo "ERROR: eMMC and boot device are the same! This would wipe the running system."
    exit 1
fi

echo ""
echo "Configuration:"
echo "  Hostname: $HOSTNAME"
echo "  Username: $USERNAME"
echo "  Timezone: $TIMEZONE"
echo ""

# Get SSH key from current system
SSH_KEY=""
if [[ -f /etc/ssh/authorized_keys.d/root ]]; then
    SSH_KEY=$(cat /etc/ssh/authorized_keys.d/root)
elif [[ -f /root/.ssh/authorized_keys ]]; then
    SSH_KEY=$(head -1 /root/.ssh/authorized_keys)
fi

if [[ -z "$SSH_KEY" ]]; then
    echo "ERROR: No SSH key found. Cannot proceed without SSH access."
    exit 1
fi
echo "SSH key found: ${SSH_KEY:0:50}..."

echo ""
echo "=== Current disk layout ==="
lsblk

echo ""
echo "WARNING: This will ERASE ALL DATA on $EMMC_DEVICE (eMMC)"
read -p "Type 'yes' to continue: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "=== Step 1: Partitioning eMMC ==="
# Wipe and create GPT partition table
parted -s "$EMMC_DEVICE" mklabel gpt

# Create partitions:
# Partition 1: idbloader (Rockchip first-stage loader) - 32KiB to 8MiB
# Partition 2: U-Boot - 8MiB to 16MiB
# Partition 3: Root filesystem - 16MiB to end
parted -s "$EMMC_DEVICE" mkpart idbloader 32KiB 8MiB
parted -s "$EMMC_DEVICE" mkpart uboot 8MiB 16MiB
parted -s "$EMMC_DEVICE" mkpart nixos 16MiB 100%
parted -s "$EMMC_DEVICE" set 3 legacy_boot on

echo "Partitions created:"
parted -s "$EMMC_DEVICE" print

echo ""
echo "=== Step 2: Copying bootloader to eMMC ==="
# Copy idbloader (first stage) - sectors 64-16383
echo "Copying idbloader..."
dd if="$BOOT_DEVICE" of="$EMMC_DEVICE" bs=512 skip=64 seek=64 count=16320 conv=fsync status=progress

# Copy U-Boot (second stage) - sectors 16384-32767
echo "Copying U-Boot..."
dd if="$BOOT_DEVICE" of="$EMMC_DEVICE" bs=512 skip=16384 seek=16384 count=16384 conv=fsync status=progress

sync

# Verify bootloader was copied correctly (check for RKNS magic)
echo "Verifying bootloader..."
MAGIC=$(dd if="$EMMC_DEVICE" bs=512 skip=64 count=1 2>/dev/null | head -c 4)
if [[ "$MAGIC" == "RKNS" ]]; then
    echo "Bootloader verified: RKNS signature found"
else
    echo "WARNING: Bootloader verification failed!"
    echo "Expected RKNS magic, got: $(echo "$MAGIC" | hexdump -C | head -1)"
    echo "eMMC may not boot. Check device paths."
    read -p "Continue anyway? [y/N]: " cont
    if [[ "$cont" != "y" && "$cont" != "Y" ]]; then
        exit 1
    fi
fi

echo ""
echo "=== Step 3: Formatting root partition ==="
mkfs.ext4 -L nixos "${EMMC_DEVICE}p3"

echo ""
echo "=== Step 4: Mounting eMMC ==="
mount "${EMMC_DEVICE}p3" "$MOUNT_POINT"

echo ""
echo "=== Step 5: Generating NixOS configuration ==="
nixos-generate-config --root "$MOUNT_POINT"

echo ""
echo "=== Step 6: Writing custom configuration ==="
cat > "$MOUNT_POINT/etc/nixos/configuration.nix" << 'NIXCONFIG'
{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Bootloader - use extlinux (U-Boot compatible)
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Network
  networking.hostName = "HOSTNAME_PLACEHOLDER";
  networking.networkmanager.enable = true;

  # Enable SSH
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "prohibit-password";
  };

  # Root SSH access
  users.users.root.openssh.authorizedKeys.keys = [
    "SSH_KEY_PLACEHOLDER"
  ];

  # Regular user
  users.users.USERNAME_PLACEHOLDER = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      "SSH_KEY_PLACEHOLDER"
    ];
  };

  # Passwordless sudo for wheel group
  security.sudo.wheelNeedsPassword = false;

  # Basic packages
  environment.systemPackages = with pkgs; [
    vim
    htop
    git
    wget
    curl
  ];

  # Timezone
  time.timeZone = "TIMEZONE_PLACEHOLDER";

  # System version
  system.stateVersion = "24.11";
}
NIXCONFIG

# Replace placeholders with actual values
sed -i "s/HOSTNAME_PLACEHOLDER/$HOSTNAME/g" "$MOUNT_POINT/etc/nixos/configuration.nix"
sed -i "s/USERNAME_PLACEHOLDER/$USERNAME/g" "$MOUNT_POINT/etc/nixos/configuration.nix"
sed -i "s|TIMEZONE_PLACEHOLDER|$TIMEZONE|g" "$MOUNT_POINT/etc/nixos/configuration.nix"
sed -i "s|SSH_KEY_PLACEHOLDER|$SSH_KEY|g" "$MOUNT_POINT/etc/nixos/configuration.nix"

echo "Configuration written to $MOUNT_POINT/etc/nixos/configuration.nix"

echo ""
echo "=== Step 7: Installing NixOS ==="
echo "This may take several minutes..."
nixos-install --root "$MOUNT_POINT" --no-root-passwd

echo ""
echo "=== Step 8: Cleanup ==="
umount "$MOUNT_POINT"
sync

echo ""
echo "=== Installation Complete! ==="
echo ""
echo "Next steps:"
echo "1. Power off: poweroff"
echo "2. Remove the USB drive"
echo "3. Power on - CM3588 will boot from eMMC"
echo "4. SSH in: ssh $USERNAME@<IP> or ssh root@<IP>"
echo ""
read -p "Power off now? [y/N]: " poweroff_confirm
if [[ "$poweroff_confirm" == "y" || "$poweroff_confirm" == "Y" ]]; then
    poweroff
fi
