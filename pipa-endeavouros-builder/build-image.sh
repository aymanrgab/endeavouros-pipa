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
BOOT_MNT="mnt_boot"
IMAGE_NAME="endeavouros-pipa-${DE_NAME}-${DATE}"
ROOTFS_LABEL="eos-pipa"
BOOT_LABEL="boot"
ESP_LABEL="EOSPIPAESP"
PACMAN_CONF="$(pwd)/pacman-pipa.conf"
SILICIUM_URL="https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img"
SILICIUM_SHA256="ea3e1e123beea7ee5394295bdfee75054711d4734e9403831fda7f037fc900b6"
ESP_SIZE_MB=128
BOOT_SIZE_MB=1024

cleanup() {
    if mountpoint -q "$IMAGE_MNT"; then
        umount "$IMAGE_MNT"
    fi
    if mountpoint -q "$ESP_MNT"; then
        umount "$ESP_MNT"
    fi
    if mountpoint -q "$BOOT_MNT"; then
        umount "$BOOT_MNT"
    fi
    rm -f "$PACMAN_CONF"
}
trap cleanup EXIT

mkdir -p "$IMAGE_DIR/$IMAGE_NAME" "$IMAGE_MNT" "$ESP_MNT" "$BOOT_MNT"
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
    iptables noto-fonts qt6-virtualkeyboard
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
sed -i '/^\[pipa\]/,/^Server = file:\/\/\/repo/d' "$ROOTFS_DIR/etc/pacman.conf"

KERNEL_VER=$(find "$ROOTFS_DIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
KERNEL_IMAGE="$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER"
KERNEL_IMAGE_UNCOMPRESSED="$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER.uncompressed"
KERNEL_IMAGE_DTB="$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER.dtb"
KERNEL_IMAGE_UNCOMPRESSED_DTB="$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER.uncompressed.dtb"
INITRAMFS_IMAGE="$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img"
DTB_IMAGE="$ROOTFS_DIR/usr/lib/modules/$KERNEL_VER/devicetree/sm8250-xiaomi-pipa.dtb"

echo "### Preparing dracut configuration..."
echo 'LANG=C.UTF-8' > "$ROOTFS_DIR/etc/locale.conf"
echo 'KEYMAP=us' > "$ROOTFS_DIR/etc/vconsole.conf"
mkdir -p "$ROOTFS_DIR/etc/dracut.conf.d"
cat > "$ROOTFS_DIR/etc/dracut.conf.d/pipa.conf" <<EOF
i18n_vars="/etc/locale.conf /etc/vconsole.conf"
EOF

echo "### Generating initramfs..."
arch-chroot "$ROOTFS_DIR" dracut --force --kver "$KERNEL_VER" "/boot/initramfs-$KERNEL_VER.img"

echo "### Preparing kernel+dtb images..."
cat "$KERNEL_IMAGE" "$DTB_IMAGE" > "$KERNEL_IMAGE_DTB"
if [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ]; then
    cat "$KERNEL_IMAGE_UNCOMPRESSED" "$DTB_IMAGE" > "$KERNEL_IMAGE_UNCOMPRESSED_DTB"
fi

echo "### Setting up /etc/cmdline..."
echo "root=LABEL=$ROOTFS_LABEL rw rootwait console=tty0 quiet splash" > "$ROOTFS_DIR/etc/cmdline"

echo "### Setting up /etc/fstab..."
cat > "$ROOTFS_DIR/etc/fstab" <<EOF
LABEL=$ROOTFS_LABEL / ext4 defaults 0 1
LABEL=$BOOT_LABEL /boot ext4 defaults 0 2
EOF

echo "### Configuring system services..."
arch-chroot "$ROOTFS_DIR" systemctl enable "$DISPLAY_MANAGER"
arch-chroot "$ROOTFS_DIR" systemctl enable NetworkManager sshd bluetooth systemd-resolved
arch-chroot "$ROOTFS_DIR" systemctl enable bootmac-bluetooth || true
arch-chroot "$ROOTFS_DIR" systemctl enable qrtr-ns pd-mapper rmtfs tqftpserv || true

echo "### Configuring SDDM for Touch/Wayland..."
if [ "$DE_NAME" = "plasma" ]; then
    mkdir -p "$ROOTFS_DIR/etc/sddm.conf.d"
    cat > "$ROOTFS_DIR/etc/sddm.conf.d/10-wayland.conf" <<EOF
[General]
DisplayServer=wayland
InputMethod=qtvirtualkeyboard
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1 --inputmethod qtvirtualkeyboard

[Theme]
Current=breeze
EOF
fi

echo "### Creating user..."
arch-chroot "$ROOTFS_DIR" useradd -m -G audio,video,wheel,storage -s /bin/bash user || true
echo 'user:147147' | arch-chroot "$ROOTFS_DIR" chpasswd
echo 'root:root' | arch-chroot "$ROOTFS_DIR" chpasswd

echo "### Configuring sudo..."
echo "%wheel ALL=(ALL:ALL) ALL" > "$ROOTFS_DIR/etc/sudoers.d/wheel"
chmod 0440 "$ROOTFS_DIR/etc/sudoers.d/wheel"

echo "### Fetching Mu-Silicium boot image..."
wget -O "$IMAGE_DIR/$IMAGE_NAME/silicium.img" "$SILICIUM_URL"
echo "$SILICIUM_SHA256  $IMAGE_DIR/$IMAGE_NAME/silicium.img" | sha256sum -c -

echo "### Installing GRUB redirect on rootfs..."
mkdir -p "$ROOTFS_DIR/boot/efi" "$ROOTFS_DIR/boot/grub"
cat > "$ROOTFS_DIR/boot/grub/grub.cfg" <<EOF
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
EOF

echo "### Creating dedicated boot image..."
truncate -s "${BOOT_SIZE_MB}M" "$IMAGE_DIR/$IMAGE_NAME/endeavouros_boot.raw"
mkfs.ext4 -F -L "$BOOT_LABEL" "$IMAGE_DIR/$IMAGE_NAME/endeavouros_boot.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/endeavouros_boot.raw" "$BOOT_MNT"
mkdir -p "$BOOT_MNT/boot/devicetree" "$BOOT_MNT/grub2" "$BOOT_MNT/efi"
cp "$KERNEL_IMAGE" "$BOOT_MNT/boot/"
cp "$KERNEL_IMAGE_DTB" "$BOOT_MNT/boot/"
cp "$INITRAMFS_IMAGE" "$BOOT_MNT/boot/"
cp "$ROOTFS_DIR/boot/System.map-$KERNEL_VER" "$BOOT_MNT/boot/"
cp "$ROOTFS_DIR/boot/config-$KERNEL_VER" "$BOOT_MNT/boot/"
cp "$DTB_IMAGE" "$BOOT_MNT/boot/devicetree/"
if [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ]; then
    cp "$KERNEL_IMAGE_UNCOMPRESSED" "$BOOT_MNT/boot/"
fi
if [ -f "$KERNEL_IMAGE_UNCOMPRESSED_DTB" ]; then
    cp "$KERNEL_IMAGE_UNCOMPRESSED_DTB" "$BOOT_MNT/boot/"
fi
cat > "$BOOT_MNT/grub2/grub.cfg" <<EOF
set default=0
set timeout=5

search --no-floppy --label --set=boot $BOOT_LABEL
set root=(\$boot)

menuentry "EndeavourOS ARM (Pipa)" {
    devicetree (\$boot)/boot/devicetree/sm8250-xiaomi-pipa.dtb
    linux (\$boot)/boot/$(basename "$KERNEL_IMAGE_UNCOMPRESSED") root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 console=ttyS0 earlycon quiet splash
    initrd (\$boot)/boot/$(basename "$INITRAMFS_IMAGE")
}

menuentry "EndeavourOS ARM (Pipa) - Gzipped Kernel Fallback" {
    devicetree (\$boot)/boot/devicetree/sm8250-xiaomi-pipa.dtb
    linux (\$boot)/boot/$(basename "$KERNEL_IMAGE") root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 console=ttyS0 earlycon quiet splash
    initrd (\$boot)/boot/$(basename "$INITRAMFS_IMAGE")
}
EOF
umount "$BOOT_MNT"

echo "### Creating EFI system partition image..."
truncate -s "${ESP_SIZE_MB}M" "$IMAGE_DIR/$IMAGE_NAME/endeavouros_esp.raw"
mkfs.fat -F 16 -n "$ESP_LABEL" "$IMAGE_DIR/$IMAGE_NAME/endeavouros_esp.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/endeavouros_esp.raw" "$ESP_MNT"
mkdir -p "$ESP_MNT/EFI/BOOT"
cat > "$IMAGE_DIR/$IMAGE_NAME/grub-embedded.cfg" <<EOF
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
EOF
grub-mkstandalone \
    -O arm64-efi \
    --modules="part_gpt part_msdos fat ext2 normal search search_label configfile linux gzio efi_gop efi_uga all_video" \
    -o "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI" \
    "boot/grub/grub.cfg=$IMAGE_DIR/$IMAGE_NAME/grub-embedded.cfg"
cat > "$ESP_MNT/EFI/BOOT/grub.cfg" <<EOF
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
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

echo "### Generating disabled vbmeta image..."
base64 -d > "$IMAGE_DIR/$IMAGE_NAME/vbmeta-disabled.img" << 'EOF'
QVZCMAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAABhdmJ0b29sIDEuNC4wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
EOF

echo "### Writing fastboot helper script..."
cat > "$IMAGE_DIR/$IMAGE_NAME/flash.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fastboot getvar product 2>&1 | grep pipa
fastboot erase dtbo_ab
fastboot flash vbmeta_ab vbmeta-disabled.img
fastboot flash boot_ab silicium.img
fastboot flash rawdump endeavouros_esp.raw
fastboot flash cust endeavouros_boot.raw
fastboot flash linux endeavouros_rootfs.raw
fastboot reboot
EOF
chmod +x "$IMAGE_DIR/$IMAGE_NAME/flash.sh"

echo "### Writing multiboot flash helper script..."
cat > "$IMAGE_DIR/$IMAGE_NAME/flash-multiboot.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

choose_from_menu() {
    local prompt="$1"
    local default_index="$2"
    shift 2

    local options=("$@")
    local answer
    local index

    echo "$prompt"
    for index in "${!options[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${options[$index]}"
    done

    while true; do
        read -r -p "Select an option [$default_index]: " answer
        if [ -z "$answer" ]; then
            answer="$default_index"
        fi
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
            printf '%s\n' "${options[$((answer - 1))]}"
            return 0
        fi
        echo "Invalid selection: $answer" >&2
    done
}

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    local value

    read -r -p "$prompt [$default_value]: " value
    if [ -z "$value" ]; then
        value="$default_value"
    fi
    printf '%s\n' "$value"
}

echo "### Xiaomi Pad 6 multiboot flasher"
echo "### Press Enter to accept the default shown in brackets."
echo

BOOT_SLOT_TARGET="${BOOT_SLOT_TARGET:-}"
ROOTFS_PARTITION="${ROOTFS_PARTITION:-}"
ERASE_DTBO="${ERASE_DTBO:-}"
ESP_PARTITION="rawdump"
BOOT_PARTITION="cust"

if [ -z "$BOOT_SLOT_TARGET" ]; then
    BOOT_SLOT_TARGET="$(choose_from_menu 'Choose the boot slot target:' 3 \
        'boot_a' \
        'boot_b' \
        'boot_ab')"
fi

if [ -z "$ROOTFS_PARTITION" ]; then
    ROOTFS_PARTITION="$(prompt_with_default 'Root filesystem partition name' 'linux')"
fi

if [ -z "$ERASE_DTBO" ]; then
    ERASE_DTBO="$(choose_from_menu 'Erase dtbo_ab before flashing?' 1 \
        'yes' \
        'no')"
fi

case "$BOOT_SLOT_TARGET" in
    boot_a|boot_b|boot_ab) ;;
    *)
        echo "Unsupported boot slot target: $BOOT_SLOT_TARGET" >&2
        exit 1
        ;;
esac

case "$ERASE_DTBO" in
    yes|y|Y)
        ERASE_DTBO="yes"
        ;;
    no|n|N)
        ERASE_DTBO="no"
        ;;
    *)
        echo "ERASE_DTBO must be yes or no" >&2
        exit 1
        ;;
esac

fastboot getvar product 2>&1 | grep pipa

if [ "$ERASE_DTBO" = "yes" ]; then
    fastboot erase dtbo_ab
fi

echo "### Flash plan"
echo "vbmeta      -> vbmeta_ab"
echo "boot image  -> $BOOT_SLOT_TARGET"
echo "esp image   -> $ESP_PARTITION"
echo "boot image  -> $BOOT_PARTITION"
echo "rootfs      -> $ROOTFS_PARTITION"
echo "erase dtbo  -> $ERASE_DTBO"
echo

read -r -p "Proceed with flashing? [Y/n]: " CONFIRM_FLASH
case "${CONFIRM_FLASH:-Y}" in
    y|Y|yes|YES|"")
        ;;
    *)
        echo "Aborted."
        exit 0
        ;;
esac

fastboot flash vbmeta_ab vbmeta-disabled.img
fastboot flash "$BOOT_SLOT_TARGET" silicium.img
fastboot flash "$ESP_PARTITION" endeavouros_esp.raw
fastboot flash "$BOOT_PARTITION" endeavouros_boot.raw
fastboot flash "$ROOTFS_PARTITION" endeavouros_rootfs.raw
fastboot reboot
EOF
chmod +x "$IMAGE_DIR/$IMAGE_NAME/flash-multiboot.sh"

echo "### Compressing image..."
pushd "$IMAGE_DIR/$IMAGE_NAME" > /dev/null
zip -r "../$IMAGE_NAME.zip" .
popd > /dev/null

echo "### Done! Image available at $IMAGE_DIR/$IMAGE_NAME.zip"
