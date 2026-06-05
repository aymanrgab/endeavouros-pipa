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
ESP_MNT="mnt_esp"
IMAGE_NAME="endeavouros-pipa-${DE_NAME}-${DATE}"
ROOTFS_LABEL="eos-pipa"
ESP_LABEL="EOSPIPAESP"
PACMAN_CONF="$(pwd)/pacman-pipa.conf"
SILICIUM_URL="https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img"
SILICIUM_SHA256="ea3e1e123beea7ee5394295bdfee75054711d4734e9403831fda7f037fc900b6"
ESP_SIZE_MB=128

cleanup() {
    if mountpoint -q "$IMAGE_MNT"; then
        umount "$IMAGE_MNT"
    fi
    if mountpoint -q "$ESP_MNT"; then
        umount "$ESP_MNT"
    fi
    rm -f "$PACMAN_CONF"
}
trap cleanup EXIT

mkdir -p "$IMAGE_DIR/$IMAGE_NAME" "$IMAGE_MNT" "$ESP_MNT"
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
    base base-devel sudo nano vim git wget rsync openssh lsb-release
    networkmanager bluez bluez-utils iwd
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    power-profiles-daemon modemmanager xdg-user-dirs
    iptables noto-fonts
    grub
    endeavouros-keyring endeavouros-mirrorlist endeavouros-theming
    eos-hooks eos-update-notifier welcome
    pipa-metapkg
)

case "$DE_NAME" in
    plasma)
        DESKTOP_PACKAGES=(
            plasma-desktop plasma-nm plasma-pa systemsettings
            konsole dolphin sddm firefox xdg-desktop-portal-kde
        )
        DISPLAY_MANAGER="sddm"
        ;;
    gnome)
        DESKTOP_PACKAGES=(
            gdm gnome-shell gnome-session gnome-control-center
            gnome-settings-daemon gnome-keyring gnome-terminal
            gnome-tweaks nautilus gvfs xdg-desktop-portal-gnome
            firefox
        )
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

KERNEL_VER=$(find "$ROOTFS_DIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
KERNEL_IMAGE=$(find "$ROOTFS_DIR/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | head -n 1)
INITRAMFS_IMAGE="$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img"

echo "### Preparing dracut configuration..."
echo 'LANG=C.UTF-8' > "$ROOTFS_DIR/etc/locale.conf"
echo 'KEYMAP=us' > "$ROOTFS_DIR/etc/vconsole.conf"
mkdir -p "$ROOTFS_DIR/etc/dracut.conf.d"
cat > "$ROOTFS_DIR/etc/dracut.conf.d/pipa.conf" <<EOF
i18n_vars="/etc/locale.conf /etc/vconsole.conf"
EOF

echo "### Generating initramfs..."
arch-chroot "$ROOTFS_DIR" dracut --force --kver "$KERNEL_VER" "/boot/initramfs-$KERNEL_VER.img"

echo "### Setting up /etc/cmdline..."
echo "root=LABEL=$ROOTFS_LABEL rw rootwait console=tty0 quiet splash" > "$ROOTFS_DIR/etc/cmdline"

echo "### Setting up /etc/fstab..."
cat > "$ROOTFS_DIR/etc/fstab" <<EOF
LABEL=$ROOTFS_LABEL / ext4 defaults 0 1
LABEL=$ESP_LABEL /boot/efi vfat defaults 0 2
EOF

echo "### Configuring system services..."
arch-chroot "$ROOTFS_DIR" systemctl enable "$DISPLAY_MANAGER"
arch-chroot "$ROOTFS_DIR" systemctl enable NetworkManager sshd bluetooth systemd-resolved
arch-chroot "$ROOTFS_DIR" systemctl enable bootmac-bluetooth || true

echo "### Creating user..."
arch-chroot "$ROOTFS_DIR" useradd -m -G audio,video,wheel,storage -s /bin/bash user || true
echo 'user:147147' | arch-chroot "$ROOTFS_DIR" chpasswd
echo 'root:root' | arch-chroot "$ROOTFS_DIR" chpasswd

echo "### Fetching Mu-Silicium boot image..."
wget -O "$IMAGE_DIR/$IMAGE_NAME/silicium.img" "$SILICIUM_URL"
echo "$SILICIUM_SHA256  $IMAGE_DIR/$IMAGE_NAME/silicium.img" | sha256sum -c -

echo "### Installing GRUB files..."
mkdir -p "$ROOTFS_DIR/boot/efi" "$ROOTFS_DIR/boot/grub"
cat > "$ROOTFS_DIR/boot/grub/grub.cfg" <<EOF
search --no-floppy --label --set=rootfs $ROOTFS_LABEL
menuentry "EndeavourOS ARM (Pipa)" {
    linux (\$rootfs)/boot/$(basename "$KERNEL_IMAGE") root=LABEL=$ROOTFS_LABEL rw rootwait console=tty0 quiet splash
    initrd (\$rootfs)/boot/$(basename "$INITRAMFS_IMAGE")
}
EOF

echo "### Creating EFI system partition image..."
truncate -s "${ESP_SIZE_MB}M" "$IMAGE_DIR/$IMAGE_NAME/endeavouros_esp.raw"
mkfs.fat -F 16 -n "$ESP_LABEL" "$IMAGE_DIR/$IMAGE_NAME/endeavouros_esp.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/endeavouros_esp.raw" "$ESP_MNT"
grub-install \
    --target=arm64-efi \
    --efi-directory="$ESP_MNT" \
    --boot-directory="$ROOTFS_DIR/boot" \
    --removable \
    --no-nvram
mkdir -p "$ESP_MNT/EFI/BOOT"
cat > "$ESP_MNT/EFI/BOOT/grub.cfg" <<EOF
search --no-floppy --label --set=rootfs $ROOTFS_LABEL
set prefix=(\$rootfs)/boot/grub
configfile (\$rootfs)/boot/grub/grub.cfg
EOF
umount "$ESP_MNT"

echo "### Creating root filesystem image..."
SIZE=$(du -sBM "$ROOTFS_DIR" | awk '{print $1}' | tr -d 'M')
SIZE=$((SIZE + (SIZE / 8) + 512))
truncate -s "${SIZE}M" "$IMAGE_DIR/$IMAGE_NAME/endeavouros_rootfs.raw"

MKE2FS_DEVICE_PHYS_SECTSIZE=4096 MKE2FS_DEVICE_SECTSIZE=4096 \
    mkfs.ext4 -L "$ROOTFS_LABEL" "$IMAGE_DIR/$IMAGE_NAME/endeavouros_rootfs.raw"

mount -o loop "$IMAGE_DIR/$IMAGE_NAME/endeavouros_rootfs.raw" "$IMAGE_MNT"
rsync -aHAX --exclude '/tmp/*' --exclude '/boot/efi' --exclude '/efi' "$ROOTFS_DIR/" "$IMAGE_MNT/"
umount "$IMAGE_MNT"

echo "### Writing fastboot helper script..."
cat > "$IMAGE_DIR/$IMAGE_NAME/flash.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fastboot getvar product 2>&1 | grep pipa
fastboot erase dtbo_ab
fastboot flash boot_ab silicium.img
fastboot flash rawdump endeavouros_esp.raw
fastboot flash userdata endeavouros_rootfs.raw
fastboot reboot
EOF
chmod +x "$IMAGE_DIR/$IMAGE_NAME/flash.sh"

echo "### Compressing image..."
pushd "$IMAGE_DIR/$IMAGE_NAME" > /dev/null
zip -r "../$IMAGE_NAME.zip" .
popd > /dev/null

echo "### Done! Image available at $IMAGE_DIR/$IMAGE_NAME.zip"
