#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "You must be root to run this script."
    exit 1
fi

DE_NAME="${1:-plasma}"
DATE=$(date +%Y%m%d)
ROOTFS_DIR="rootfs"
IMAGE_DIR="images"
IMAGE_MNT="mnt_image"
IMAGE_NAME="endeavouros-pipa-${DE_NAME}-${DATE}"
ROOTFS_UUID=$(cat /proc/sys/kernel/random/uuid)
PACMAN_CONF="$(pwd)/pacman-pipa.conf"

cleanup() {
    if mountpoint -q "$IMAGE_MNT"; then
        umount "$IMAGE_MNT"
    fi
    rm -f "$PACMAN_CONF"
}
trap cleanup EXIT

mkdir -p "$IMAGE_DIR/$IMAGE_NAME" "$IMAGE_MNT"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

shopt -s nullglob
LOCAL_PACKAGES=(/repo/*.pkg.tar.zst /repo/*.pkg.tar.xz)
shopt -u nullglob
if [ ${#LOCAL_PACKAGES[@]} -eq 0 ]; then
    echo "No local packages found in /repo. Run build-packages.sh first."
    exit 1
fi

echo "### Preparing pacman configuration..."
cp /etc/pacman.conf "$PACMAN_CONF"
sed -i '/^DisableSandbox$/d' "$PACMAN_CONF"
sed -i '/^\[options\]$/a DisableSandbox' "$PACMAN_CONF"
cat <<EOF >> "$PACMAN_CONF"

[pipa]
SigLevel = Optional TrustAll
Server = file:///repo

[endeavouros]
SigLevel = Optional TrustAll
Server = https://mirror.moson.org/endeavouros/repo/\$repo/\$arch
EOF

BASE_PACKAGES=(
    base base-devel sudo nano vim git wget rsync openssh
    networkmanager bluez bluez-utils iwd
    pipewire pipewire-alsa pipewire-pulse wireplumber
    power-profiles-daemon modemmanager xdg-user-dirs
    endeavouros-keyring endeavouros-mirrorlist endeavouros-theming
    eos-hooks eos-update-notifier welcome
    pipa-metapkg
)

case "$DE_NAME" in
    plasma)
        DESKTOP_PACKAGES=(plasma konsole dolphin sddm firefox)
        DISPLAY_MANAGER="sddm"
        ;;
    gnome)
        DESKTOP_PACKAGES=(gnome gnome-tweaks gdm firefox)
        DISPLAY_MANAGER="gdm"
        ;;
    *)
        echo "Unsupported desktop environment: $DE_NAME"
        exit 1
        ;;
esac

echo "### Bootstrapping rootfs with pacstrap..."
pacstrap -C "$PACMAN_CONF" -KGM "$ROOTFS_DIR" "${BASE_PACKAGES[@]}" "${DESKTOP_PACKAGES[@]}"

echo "### Writing target pacman configuration..."
cp "$PACMAN_CONF" "$ROOTFS_DIR/etc/pacman.conf"

echo "### Setting up /etc/cmdline..."
echo "root=UUID=$ROOTFS_UUID rw rootwait console=tty0 quiet splash" > "$ROOTFS_DIR/etc/cmdline"

echo "### Setting up /etc/fstab..."
echo "UUID=$ROOTFS_UUID / ext4 defaults 0 1" > "$ROOTFS_DIR/etc/fstab"

echo "### Configuring system services..."
arch-chroot "$ROOTFS_DIR" systemctl enable "$DISPLAY_MANAGER"
arch-chroot "$ROOTFS_DIR" systemctl enable NetworkManager sshd bluetooth systemd-resolved
arch-chroot "$ROOTFS_DIR" systemctl enable bootmac-bluetooth || true

echo "### Creating user..."
arch-chroot "$ROOTFS_DIR" useradd -m -G audio,video,wheel,storage -s /bin/bash user || true
echo 'user:147147' | arch-chroot "$ROOTFS_DIR" chpasswd
echo 'root:root' | arch-chroot "$ROOTFS_DIR" chpasswd

echo "### Generating boot image..."
KERNEL_VER=$(find "$ROOTFS_DIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
arch-chroot "$ROOTFS_DIR" kernel-install add "$KERNEL_VER" "/usr/lib/modules/$KERNEL_VER/vmlinuz"

echo "### Creating root.img..."
SIZE=$(du -sBM --exclude="$ROOTFS_DIR/boot" "$ROOTFS_DIR" | awk '{print $1}' | tr -d 'M')
SIZE=$((SIZE + (SIZE / 8) + 512))
truncate -s "${SIZE}M" "$IMAGE_DIR/$IMAGE_NAME/root.img"

MKE2FS_DEVICE_PHYS_SECTSIZE=4096 MKE2FS_DEVICE_SECTSIZE=4096 \
    mkfs.ext4 -U "$ROOTFS_UUID" -L 'endeavouros' "$IMAGE_DIR/$IMAGE_NAME/root.img"

mount -o loop "$IMAGE_DIR/$IMAGE_NAME/root.img" "$IMAGE_MNT"
rsync -aHAX --exclude '/tmp/*' --exclude '/boot/efi' --exclude '/efi' "$ROOTFS_DIR/" "$IMAGE_MNT/"
umount "$IMAGE_MNT"

echo "### Collecting boot artifacts..."
cp "$ROOTFS_DIR/boot/boot-$KERNEL_VER.img" "$IMAGE_DIR/$IMAGE_NAME/boot.img" || \
    echo "Warning: boot.img not found"

echo "### Compressing image..."
pushd "$IMAGE_DIR/$IMAGE_NAME" > /dev/null
zip -r "../$IMAGE_NAME.zip" .
popd > /dev/null

echo "### Done! Image available at $IMAGE_DIR/$IMAGE_NAME.zip"
