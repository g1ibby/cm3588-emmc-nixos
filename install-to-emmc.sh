#!/usr/bin/env bash
set -euo pipefail

# Configuration - embedded values
HOSTNAME="cm3588-nas"
USERNAME="user"
TIMEZONE="Asia/Bangkok"
LUKS_NAME="cryptroot"

MOUNT_POINT="/mnt"
BOOT_MOUNT="/mnt/boot"

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
echo "  LUKS encryption: ENABLED"
echo "  Remote SSH unlock: port 2222"
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
# Partition 3: /boot (unencrypted) - 16MiB to 528MiB (512MiB)
# Partition 4: LUKS encrypted root - 528MiB to end
parted -s "$EMMC_DEVICE" mkpart idbloader 32KiB 8MiB
parted -s "$EMMC_DEVICE" mkpart uboot 8MiB 16MiB
parted -s "$EMMC_DEVICE" mkpart boot 16MiB 528MiB
parted -s "$EMMC_DEVICE" mkpart nixos 528MiB 100%
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
echo "=== Step 3: Setting up LUKS encryption ==="

# Format /boot partition (unencrypted)
echo "Formatting /boot partition..."
mkfs.ext4 -L boot "${EMMC_DEVICE}p3"

# Setup LUKS encryption on partition 4
echo ""
echo "Setting up LUKS encryption on root partition..."
echo "You will be prompted to enter a passphrase."
echo "This passphrase will be required to unlock the system at every boot."
echo ""
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --label cryptroot \
    "${EMMC_DEVICE}p4"

# Open the LUKS volume
echo ""
echo "Opening LUKS volume..."
cryptsetup luksOpen "${EMMC_DEVICE}p4" "$LUKS_NAME"

# Get the UUID for NixOS configuration
LUKS_UUID=$(blkid -s UUID -o value "${EMMC_DEVICE}p4")
echo "LUKS UUID: $LUKS_UUID"

# Format the inner filesystem
echo "Formatting encrypted root filesystem..."
mkfs.ext4 -L nixos "/dev/mapper/$LUKS_NAME"

echo ""
echo "=== Step 4: Mounting filesystems ==="
mount "/dev/mapper/$LUKS_NAME" "$MOUNT_POINT"
mkdir -p "$BOOT_MOUNT"
mount "${EMMC_DEVICE}p3" "$BOOT_MOUNT"

echo ""
echo "=== Step 5: Generating NixOS configuration ==="
nixos-generate-config --root "$MOUNT_POINT"

# Fix hardware-configuration.nix to use /dev/mapper/cryptroot instead of inner UUID
# (systemd initrd needs this to properly wait for LUKS before mounting root)
echo "Fixing hardware-configuration.nix for LUKS..."
# Get the inner ext4 UUID that nixos-generate-config detected
INNER_UUID=$(grep -A2 'fileSystems."/" =' "$MOUNT_POINT/etc/nixos/hardware-configuration.nix" | grep 'device = ' | sed 's|.*by-uuid/\([^"]*\)".*|\1|')
if [ -n "$INNER_UUID" ]; then
    sed -i "s|/dev/disk/by-uuid/$INNER_UUID|/dev/mapper/cryptroot|" "$MOUNT_POINT/etc/nixos/hardware-configuration.nix"
    echo "  Replaced UUID $INNER_UUID with /dev/mapper/cryptroot"
else
    echo "  WARNING: Could not find root filesystem UUID to replace"
fi

echo ""
echo "=== Step 6: Generating initrd SSH host keys ==="
mkdir -p "$MOUNT_POINT/etc/secrets/initrd"
ssh-keygen -t ed25519 -N "" -f "$MOUNT_POINT/etc/secrets/initrd/ssh_host_ed25519_key"
chmod 600 "$MOUNT_POINT/etc/secrets/initrd/ssh_host_ed25519_key"
INITRD_SSH_FINGERPRINT=$(ssh-keygen -lf "$MOUNT_POINT/etc/secrets/initrd/ssh_host_ed25519_key.pub")
echo "Initrd SSH host key generated."
echo "Fingerprint: $INITRD_SSH_FINGERPRINT"

echo ""
echo "=== Step 7: Writing custom configuration ==="
cat > "$MOUNT_POINT/etc/nixos/configuration.nix" << 'NIXCONFIG'
{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Bootloader - use extlinux (U-Boot compatible)
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Kernel parameters for DHCP in initrd
  boot.kernelParams = [ "ip=dhcp" ];

  # Initrd configuration for LUKS and remote unlock
  boot.initrd = {
    # Use systemd in initrd for proper device dependency handling
    # (PCIe NIC takes ~25 seconds to initialize, systemd waits for it properly)
    systemd.enable = true;

    # Kernel modules needed for early boot
    availableKernelModules = [
      # Network driver for RTL8125B 2.5GbE (PCIe attached)
      "r8169"
      "realtek"
      # PCIe support (ethernet is PCIe-attached on CM3588)
      "pcie_rockchip_host"
      "phy_rockchip_naneng_combphy"
      # eMMC storage
      "mmc_block"
      "sdhci_of_dwcmshc"
      # Crypto support
      "dm-crypt"
      "cryptd"
      "aes_generic"
    ];

    kernelModules = [ "dm-crypt" ];

    # Secrets for initrd (lib.mkForce needed to override initrd-ssh.nix automatic
    # definition with unquoted path required by extlinux bootloader)
    secrets = lib.mkForce {
      "/etc/secrets/initrd/ssh_host_ed25519_key" = /mnt/etc/secrets/initrd/ssh_host_ed25519_key;
    };

    # LUKS device configuration
    luks.devices."cryptroot" = {
      device = "/dev/disk/by-uuid/LUKS_UUID_PLACEHOLDER";
      allowDiscards = true;
    };

    # Network configuration for remote unlock
    network = {
      enable = true;

      # SSH server in initrd for remote unlock
      ssh = {
        enable = true;
        # Use different port to avoid host key conflicts with main SSH
        port = 2222;

        # Same authorized keys as root user
        authorizedKeys = [
          "SSH_KEY_PLACEHOLDER"
        ];

        # Dedicated host keys for initrd
        hostKeys = [
          "/etc/secrets/initrd/ssh_host_ed25519_key"
        ];
      };
    };
  };

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
    cryptsetup
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
sed -i "s|LUKS_UUID_PLACEHOLDER|$LUKS_UUID|g" "$MOUNT_POINT/etc/nixos/configuration.nix"

echo "Configuration written to $MOUNT_POINT/etc/nixos/configuration.nix"

echo ""
echo "=== Step 8: Installing NixOS ==="
echo "This may take several minutes..."
nixos-install --root "$MOUNT_POINT" --no-root-passwd

# Fix initrd secrets path for post-install rebuilds
# During install: /mnt/etc/secrets/... (file is at mount point)
# After install: /etc/secrets/... (file is at root)
echo "Fixing initrd secrets path for future rebuilds..."
sed -i "s|/mnt/etc/secrets|/etc/secrets|g" "$MOUNT_POINT/etc/nixos/configuration.nix"

echo ""
echo "=== Step 9: Cleanup ==="
umount "$BOOT_MOUNT"
umount "$MOUNT_POINT"
cryptsetup luksClose "$LUKS_NAME"
sync

echo ""
echo "=============================================="
echo "=== Installation Complete! ==="
echo "=============================================="
echo ""
echo "IMPORTANT: Save this information for remote unlock!"
echo ""
echo "Initrd SSH fingerprint (port 2222):"
echo "  $INITRD_SSH_FINGERPRINT"
echo ""
echo "Remote Unlock Instructions:"
echo "  1. Power off: poweroff"
echo "  2. Remove the USB drive"
echo "  3. Power on CM3588 - wait ~30 seconds for network"
echo "  4. SSH to initrd for unlock:"
echo "       ssh -p 2222 root@<CM3588-IP>"
echo "  5. Enter your LUKS passphrase when prompted"
echo "  6. After unlock, SSH to the full system:"
echo "       ssh root@<CM3588-IP>"
echo "       ssh $USERNAME@<CM3588-IP>"
echo ""
echo "If you don't know the IP, check your router's DHCP leases."
echo ""
read -p "Power off now? [y/N]: " poweroff_confirm
if [[ "$poweroff_confirm" == "y" || "$poweroff_confirm" == "Y" ]]; then
    poweroff
fi
