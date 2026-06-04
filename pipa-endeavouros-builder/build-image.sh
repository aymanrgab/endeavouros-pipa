#!/bin/bash
set -e

if [ "$(whoami)" != 'root' ]; then
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

mkdir -p "$IMAGE_DIR/$IMAGE_NAME" "$IMAGE_MNT" "$ROOTFS_DIR"

echo "### Downloading Arch Linux ARM rootfs..."
if [ ! -f "ArchLinuxARM-aarch64-latest.tar.gz" ]; then
    wget http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
fi

echo "### Extracting rootfs..."
rm -rf "$ROOTFS_DIR"/*
bsdtar -xpf ArchLinuxARM-aarch64-latest.tar.gz -C "$ROOTFS_DIR"

echo "### Setting up QEMU static (if needed for cross-arch chroot)"
cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/" || true

echo "### Initializing pacman keyring..."
arch-chroot "$ROOTFS_DIR" pacman-key --init
arch-chroot "$ROOTFS_DIR" pacman-key --populate archlinuxarm

echo "### Setting up local repo..."
mkdir -p "$ROOTFS_DIR/repo"
cp /repo/*.pkg.tar.zst "$ROOTFS_DIR/repo/" || echo "No local packages found. Make sure to run build-packages.sh first."
cp /repo/pipa.db* "$ROOTFS_DIR/repo/" || true

cat <<EOF >> "$ROOTFS_DIR/etc/pacman.conf"
[pipa]
SigLevel = Optional TrustAll
Server = file:///repo

[endeavouros]
SigLevel = Optional TrustAll
Server = https://mirror.moson.org/endeavouros/repo/\$repo/\$arch
EOF

echo "### Setting up /etc/cmdline..."
echo "root=UUID=$ROOTFS_UUID rw rootwait console=tty0 quiet splash" > "$ROOTFS_DIR/etc/cmdline"

echo "### Setting up /etc/fstab..."
echo "UUID=$ROOTFS_UUID / ext4 defaults 0 1" > "$ROOTFS_DIR/etc/fstab"

echo "### Updating system and installing base packages..."
arch-chroot "$ROOTFS_DIR" pacman -Syu --noconfirm
arch-chroot "$ROOTFS_DIR" pacman -S --noconfirm base-devel systemd systemd-sysvcompat nano vim git wget rsync

echo "### Removing default kernel if present..."
arch-chroot "$ROOTFS_DIR" pacman -Rsn --noconfirm linux-aarch64 || true

echo "### Installing EndeavourOS specific packages (simulated) and Pipa packages..."
# Install our meta package which brings in the kernel, firmware, configs, and hooks
arch-chroot "$ROOTFS_DIR" pacman -S --noconfirm pipa-metapkg

echo "### Installing Desktop Environment ($DE_NAME)..."
if [ "$DE_NAME" == "plasma" ]; then
    arch-chroot "$ROOTFS_DIR" pacman -S --noconfirm plasma-meta konsole dolphin sddm networkmanager
    arch-chroot "$ROOTFS_DIR" systemctl enable sddm
elif [ "$DE_NAME" == "gnome" ]; then
    arch-chroot "$ROOTFS_DIR" pacman -S --noconfirm gnome gnome-tweaks gdm networkmanager
    arch-chroot "$ROOTFS_DIR" systemctl enable gdm
fi

echo "### Configuring system services..."
arch-chroot "$ROOTFS_DIR" systemctl enable NetworkManager sshd systemd-resolved bootmac-bluetooth

echo "### Creating user..."
arch-chroot "$ROOTFS_DIR" useradd -m -G audio,video,wheel,storage -s /bin/bash user || true
echo 'user:147147' | arch-chroot "$ROOTFS_DIR" chpasswd
echo 'root:root' | arch-chroot "$ROOTFS_DIR" chpasswd

echo "### Generating Boot Image via kernel-install..."
# We reinstall the kernel to trigger the 99-android-boot.install hook
KERNEL_VER=$(ls -1 "$ROOTFS_DIR/usr/lib/modules" | grep -v "extramodules" | head -n 1)
arch-chroot "$ROOTFS_DIR" kernel-install add "$KERNEL_VER" "/usr/lib/modules/$KERNEL_VER/vmlinuz"

echo "### Creating root.img..."
SIZE=$(du -BM -s --exclude="$ROOTFS_DIR/boot" "$ROOTFS_DIR" | cut -dM -f1)
SIZE=$((SIZE + (SIZE / 8) + 512))
truncate -s ${SIZE}M "$IMAGE_DIR/$IMAGE_NAME/root.img"

MKE2FS_DEVICE_PHYS_SECTSIZE=4096 MKE2FS_DEVICE_SECTSIZE=4096 mkfs.ext4 -U "$ROOTFS_UUID" -L 'endeavouros' "$IMAGE_DIR/$IMAGE_NAME/root.img"

mount -o loop "$IMAGE_DIR/$IMAGE_NAME/root.img" "$IMAGE_MNT"
rsync -aHAX --exclude '/tmp/*' --exclude '/boot/efi' --exclude '/efi' --exclude '/repo/*' "$ROOTFS_DIR/" "$IMAGE_MNT/"
umount "$IMAGE_MNT"

echo "### Extracting boot.img..."
# The kernel flasher hook creates the Android boot image in /boot
cp "$ROOTFS_DIR/boot/boot-$KERNEL_VER.img" "$IMAGE_DIR/$IMAGE_NAME/boot.img" || echo "Warning: boot.img not found!"

echo "### Compressing image..."
pushd "$IMAGE_DIR/$IMAGE_NAME" > /dev/null
zip -r "../$IMAGE_NAME.zip" .
popd > /dev/null

echo "### Done! Image available at $IMAGE_DIR/$IMAGE_NAME.zip"
