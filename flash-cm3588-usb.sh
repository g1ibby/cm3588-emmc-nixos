#!/usr/bin/env bash
set -euo pipefail

# Configuration
USB_DEVICE="/dev/sdb"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
MOUNT_POINT="/mnt/nixos-usb"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install-to-emmc.sh"
INSTALL_SCRIPT_LUKS="$SCRIPT_DIR/install-to-emmc-with-luks.sh"

echo "=== CM3588 NixOS USB Flash Script ==="
echo ""

# Check SSH key exists
if [[ ! -f "$SSH_KEY" ]]; then
    echo "ERROR: SSH key not found at $SSH_KEY"
    exit 1
fi
echo "SSH key: $SSH_KEY"

# Check install scripts exist
if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "ERROR: Install script not found at $INSTALL_SCRIPT"
    exit 1
fi
if [[ ! -f "$INSTALL_SCRIPT_LUKS" ]]; then
    echo "ERROR: LUKS install script not found at $INSTALL_SCRIPT_LUKS"
    exit 1
fi
echo "Install scripts: $INSTALL_SCRIPT, $INSTALL_SCRIPT_LUKS"

# Generate a random locally-administered MAC address
# First byte: 02 (unicast, locally administered)
# Remaining bytes: random
generate_mac() {
    printf '02:%02x:%02x:%02x:%02x:%02x\n' \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) \
        $((RANDOM % 256)) $((RANDOM % 256))
}
GENERATED_MAC=$(generate_mac)
echo "Generated MAC address: $GENERATED_MAC"

# Show USB device info
echo ""
echo "Target USB device: $USB_DEVICE"
lsblk "$USB_DEVICE" 2>/dev/null || { echo "ERROR: Device $USB_DEVICE not found"; exit 1; }

echo ""
echo "=== Step 1: Building CM3588 NixOS image ==="

# Check if image already exists and is valid
if [[ -L "./result" ]] && [[ -e "./result" ]]; then
    IMAGE_PATH=$(readlink -f ./result)
    echo "Image already exists: $IMAGE_PATH"
    echo "Skipping build. Delete ./result to force rebuild."
else
    echo "Building image (this may take a few minutes)..."
    nix build 'github:Mic92/nixos-aarch64-images#cm3588NAS' --no-write-lock-file

    if [[ ! -L "./result" ]]; then
        echo "ERROR: Build failed - ./result not found"
        exit 1
    fi

    IMAGE_PATH=$(readlink -f ./result)
    echo "Image built: $IMAGE_PATH"
fi

echo ""
echo "=== Step 2: Ready to flash ==="
echo ""
echo "WARNING: This will ERASE ALL DATA on $USB_DEVICE"
lsblk "$USB_DEVICE"
echo ""
read -p "Type 'yes' to continue: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "=== Step 3: Unmounting USB partitions ==="
# Unmount all partitions on the device
for part in "${USB_DEVICE}"*; do
    if mountpoint -q "$part" 2>/dev/null || mount | grep -q "^$part "; then
        echo "Unmounting $part..."
        sudo umount "$part" 2>/dev/null || true
    fi
done

echo ""
echo "=== Step 4: Flashing image to USB ==="
sudo dd if="$IMAGE_PATH" of="$USB_DEVICE" bs=16M status=progress conv=fsync
sync
echo "Flash complete!"

echo ""
echo "=== Step 5: Adding SSH keys and install script ==="
sleep 2  # Give kernel time to re-read partition table

# Find the root partition (should be partition 3)
ROOT_PART="${USB_DEVICE}3"
if [[ ! -b "$ROOT_PART" ]]; then
    echo "Waiting for partitions..."
    sudo partprobe "$USB_DEVICE"
    sleep 2
fi

if [[ ! -b "$ROOT_PART" ]]; then
    echo "ERROR: Root partition $ROOT_PART not found"
    echo "Available partitions:"
    lsblk "$USB_DEVICE"
    exit 1
fi

sudo mkdir -p "$MOUNT_POINT"
sudo mount "$ROOT_PART" "$MOUNT_POINT"

# Add SSH key
sudo mkdir -p "$MOUNT_POINT/etc/ssh/authorized_keys.d"
cat "$SSH_KEY" | sudo tee "$MOUNT_POINT/etc/ssh/authorized_keys.d/root" > /dev/null
echo "SSH key added for root user"

# Copy install scripts to /root (create dir if needed)
sudo mkdir -p "$MOUNT_POINT/root"
sudo cp "$INSTALL_SCRIPT" "$MOUNT_POINT/root/install-to-emmc.sh"
sudo cp "$INSTALL_SCRIPT_LUKS" "$MOUNT_POINT/root/install-to-emmc-with-luks.sh"
# Replace MAC placeholder with generated MAC in LUKS script
sudo sed -i "s/MAC_ADDRESS_PLACEHOLDER/$GENERATED_MAC/g" "$MOUNT_POINT/root/install-to-emmc-with-luks.sh"
sudo chmod +x "$MOUNT_POINT/root/install-to-emmc.sh"
sudo chmod +x "$MOUNT_POINT/root/install-to-emmc-with-luks.sh"
echo "Install scripts copied to /root/"
echo "  MAC address embedded: $GENERATED_MAC"

sudo umount "$MOUNT_POINT"
sync

echo ""
echo "=== Done! ==="
echo ""
echo "USB drive is ready. Next steps:"
echo "1. Insert USB into CM3588 and power on"
echo "2. Find CM3588 IP: nmap -sn 192.168.1.0/24"
echo "3. SSH in: ssh root@<IP>"
echo "4. Run one of:"
echo "   - bash /root/install-to-emmc.sh              (without encryption)"
echo "   - bash /root/install-to-emmc-with-luks.sh    (with LUKS encryption + remote unlock)"
