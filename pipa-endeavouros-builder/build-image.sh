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
EFI_TEMPLATE_DIR="$(pwd)/efi-template"
LOCAL_PKG_DIR="$(pwd)/pkgbuilds"
LOCAL_REPO_DIR="$(pwd)/local-repo"
PIPA_REPO_URL="${PIPA_REPO_URL:-https://maakiopus.github.io/pipa-alarm/repo/}"
SILICIUM_URL="https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img"
SILICIUM_SHA256="ea3e1e123beea7ee5394295bdfee75054711d4734e9403831fda7f037fc900b6"
ESP_SIZE_MB=128
BOOT_SIZE_MB=1024
LOCAL_RUNTIME_PACKAGES=(
    qrtr
    rmtfs
    tqftpserv
    pd-mapper
)

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

first_existing_file() {
    local candidate
    for candidate in "$@"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

first_existing_dir() {
    local candidate
    for candidate in "$@"; do
        if [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

prepare_local_repo() {
    local makepkg_user="${SUDO_USER:-builder}"
    local pkg pkg_dir built_packages package_path install_packages

    if ! id -u "$makepkg_user" >/dev/null 2>&1; then
        useradd -m "$makepkg_user"
    fi

    install -d -m 0755 "$LOCAL_REPO_DIR"
    chown -R "$makepkg_user:$makepkg_user" "$LOCAL_REPO_DIR"
    rm -f "$LOCAL_REPO_DIR"/*.pkg.tar.* "$LOCAL_REPO_DIR"/pipa-local.db* "$LOCAL_REPO_DIR"/pipa-local.files*

    for pkg in "${LOCAL_RUNTIME_PACKAGES[@]}"; do
        pkg_dir="$LOCAL_PKG_DIR/$pkg"
        echo "### Building local runtime package: $pkg"
        chown -R "$makepkg_user:$makepkg_user" "$pkg_dir"
        su "$makepkg_user" -c "cd '$pkg_dir' && rm -f ./*.pkg.tar.* && makepkg --nodeps --noconfirm --nocheck"

        built_packages=()
        shopt -s nullglob
        for package_path in "$pkg_dir"/*.pkg.tar.zst "$pkg_dir"/*.pkg.tar.xz; do
            case "$(basename "$package_path")" in
                *-debug-*.pkg.tar.*|*-headers-*.pkg.tar.*) ;;
                *) built_packages+=("$package_path") ;;
            esac
        done
        shopt -u nullglob

        if [ ${#built_packages[@]} -eq 0 ]; then
            echo "No package archives were produced for $pkg in $pkg_dir" >&2
            exit 1
        fi

        cp "${built_packages[@]}" "$LOCAL_REPO_DIR/"
        repo-add "$LOCAL_REPO_DIR/pipa-local.db.tar.gz" "${built_packages[@]}"

        install_packages=()
        for package_path in "${built_packages[@]}"; do
            case "$(basename "$package_path")" in
                *-debug-*.pkg.tar.*|*-headers-*.pkg.tar.*) ;;
                *) install_packages+=("$package_path") ;;
            esac
        done

        if [ ${#install_packages[@]} -gt 0 ]; then
            pacman -U --noconfirm --ask=4 "${install_packages[@]}"
        fi
    done
}

write_uefi_csv() {
    local csv_path="$1"
    local entry_image="$2"
    local title="$3"
    local description="$4"

    python - "$csv_path" "$entry_image" "$title" "$description" <<'PY'
import pathlib
import sys

csv_path, entry_image, title, description = sys.argv[1:5]
text = f"{entry_image},{title},,{description}\r\n"
pathlib.Path(csv_path).write_bytes(b"\xff\xfe" + text.encode("utf-16le"))
PY
}

write_grub_splash_png() {
    local png_path="$1"

    python - "$png_path" <<'PY'
import pathlib
import struct
import zlib
import sys

png_path = pathlib.Path(sys.argv[1])
width, height = 1280, 800

def chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )

rows = []
for y in range(height):
    row = bytearray([0])
    for x in range(width):
        mix = (x * 255) // max(width - 1, 1)
        mix2 = (y * 255) // max(height - 1, 1)

        r = 24 + (56 * mix) // 255 + (18 * mix2) // 255
        g = 8 + (18 * mix) // 255
        b = 48 + (110 * mix) // 255

        # Soft diagonal highlight for a more Endeavour-like splash.
        band = abs((x * 10 // width) - (y * 10 // height))
        if band <= 1:
            r = min(255, r + 18)
            g = min(255, g + 10)
            b = min(255, b + 24)

        # Bottom glow bar to frame the menu area.
        if y > height - 140:
            glow = min(60, y - (height - 140))
            r = min(255, r + glow // 2)
            g = min(255, g + glow // 4)
            b = min(255, b + glow)

        row.extend((r, g, b))
    rows.append(bytes(row))

raw = b"".join(rows)
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw, level=9))
png += chunk(b"IEND", b"")
png_path.write_bytes(png)
PY
}

if [ ! -f "$EFI_TEMPLATE_DIR/EFI/BOOT/BOOTAA64.EFI" ] || [ ! -f "$EFI_TEMPLATE_DIR/EFI/endeavour/grubaa64.efi" ]; then
    echo "Missing Endeavour-style EFI template files in $EFI_TEMPLATE_DIR"
    exit 1
fi

echo "### Preparing pacman configuration..."
prepare_local_repo
cp /etc/pacman.conf "$PACMAN_CONF"
sed -i '/^DisableSandbox$/d' "$PACMAN_CONF"
sed -i '/^\[options\]$/a DisableSandbox' "$PACMAN_CONF"
cat <<EOF >> "$PACMAN_CONF"

[pipa-local]
SigLevel = Optional TrustAll
Server = file://$LOCAL_REPO_DIR

[pipa-alarm]
SigLevel = Optional TrustAll
Server = $PIPA_REPO_URL

[endeavouros]
SigLevel = Optional TrustAll
Server = https://mirror.moson.org/endeavouros/repo/\$repo/\$arch
EOF

BASE_PACKAGES=(
    base base-devel sudo nano vim git wget rsync openssh lsb-release
    networkmanager iwd mesa
    archlinuxarm-keyring
    alsa-ucm-conf alsa-utils
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    power-profiles-daemon modemmanager xdg-user-dirs
    iptables noto-fonts qt6-virtualkeyboard
    fish fastfetch
    grub
    endeavouros-keyring endeavouros-mirrorlist endeavouros-theming
    eos-hooks eos-update-notifier welcome
)

# Install the published Pipa device package set explicitly from the external
# pipa-alarm repo so the kernel and device support do not depend on a local
# metapackage build existing in /repo.
PIPA_REPO_PACKAGES=(
    bluez-git
    bootmac
    box64
    device-xiaomi-pipa
    gamescope
    hexagonrpcd
    iio-sensor-proxy-libssc
    libssc
    linux-firmware-pipa-adreno
    linux-firmware-pipa-adsp
    linux-firmware-pipa-awinic
    linux-firmware-pipa-cdsp
    linux-firmware-pipa-hexagonfs
    linux-firmware-pipa-novatek
    linux-firmware-pipa-nuvolta
    linux-firmware-pipa-slpi
    linux-firmware-pipa-venus
    linux-pipa
    mangohud-git
    mkbootimg-pipa
    pipa-kernel-hooks
    qbootctl
    swclock-offset
    widevine
    wine-aarch64
)

LOCAL_IMAGE_PACKAGES=(
    "${LOCAL_RUNTIME_PACKAGES[@]}"
)

case "$DE_NAME" in
    plasma)
        DESKTOP_PACKAGES=(
            plasma-meta plasma-login-manager plasma-keyboard xdg-desktop-portal-kde
            firefox flatpak
            kdeconnect discover konsole dolphin ark filelight
            gwenview okular spectacle elisa kate kcalc kalk
            plasma-browser-integration plasma-systemmonitor
            qt6-multimedia-ffmpeg
        )
        DISPLAY_MANAGER="plasmalogin"
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
pacstrap -C "$PACMAN_CONF" -KGM "$ROOTFS_DIR" "${BASE_PACKAGES[@]}" "${PIPA_REPO_PACKAGES[@]}" "${LOCAL_IMAGE_PACKAGES[@]}" "${DESKTOP_PACKAGES[@]}"

echo "### Writing target pacman configuration..."
cp "$PACMAN_CONF" "$ROOTFS_DIR/etc/pacman.conf"

echo "### Installing local Pipa audio configuration..."
install -Dm644 \
    "$LOCAL_PKG_DIR/alsa-ucm-conf-sm8250/Xiaomi Pad 6.conf" \
    "$ROOTFS_DIR/usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi Pad 6.conf"
install -Dm644 \
    "$LOCAL_PKG_DIR/alsa-ucm-conf-sm8250/HiFi_pipa.conf" \
    "$ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sm8250/HiFi_pipa.conf"
install -Dm644 \
    "$LOCAL_PKG_DIR/pipa-sound-conf/51-pipa.conf" \
    "$ROOTFS_DIR/usr/share/wireplumber/wireplumber.conf.d/51-pipa.conf"
ln -sf "Xiaomi Pad 6.conf" \
    "$ROOTFS_DIR/usr/share/alsa/ucm2/conf.d/sm8250/sm8250.conf"
ln -sf "Xiaomi Pad 6.conf" \
    "$ROOTFS_DIR/usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi-Pad6-pipa-M82.conf"
install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/systemd/system/iio-sensor-proxy.service.d/10-pipa-audio.conf" <<'EOF'
[Unit]
Wants=
After=
Wants=hexagonrpcd-adsp-rootpd.service
Wants=hexagonrpcd-sdsp.service
After=hexagonrpcd-adsp-rootpd.service
After=hexagonrpcd-sdsp.service
EOF

install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/pipa-audio-init" <<'EOF'
#!/bin/sh
set -eu

for _ in $(seq 1 20); do
    if [ -r /proc/asound/cards ] && ! grep -q '^--- no soundcards ---$' /proc/asound/cards; then
        break
    fi
    sleep 1
done

alsactl init 0 || true
EOF

install -Dm644 /dev/stdin "$ROOTFS_DIR/usr/lib/systemd/system/pipa-audio-init.service" <<'EOF'
[Unit]
Description=Initialize Xiaomi Pad 6 ALSA state
After=systemd-udev-settle.service pd-mapper.service rmtfs.service tqftpserv.service hexagonrpcd-adsp-rootpd.service hexagonrpcd-sdsp.service
Wants=systemd-udev-settle.service pd-mapper.service rmtfs.service tqftpserv.service hexagonrpcd-adsp-rootpd.service hexagonrpcd-sdsp.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pipa-audio-init
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

KERNEL_VER=$(find "$ROOTFS_DIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
KERNEL_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/Image.gz" \
    "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER" \
)"
KERNEL_IMAGE_UNCOMPRESSED="$(first_existing_file \
    "$ROOTFS_DIR/boot/Image" \
    "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER.uncompressed" \
    || true \
)"
KERNEL_IMAGE_DTB="$ROOTFS_DIR/boot/$(basename "$KERNEL_IMAGE").dtb"
if [ -n "${KERNEL_IMAGE_UNCOMPRESSED:-}" ]; then
    KERNEL_IMAGE_UNCOMPRESSED_DTB="$ROOTFS_DIR/boot/$(basename "$KERNEL_IMAGE_UNCOMPRESSED").dtb"
else
    KERNEL_IMAGE_UNCOMPRESSED_DTB=""
fi
INITRAMFS_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" \
    "$ROOTFS_DIR/boot/initramfs.img" \
)"
DTB_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/dtbs/qcom/sm8250-xiaomi-pipa.dtb" \
    "$ROOTFS_DIR/usr/lib/modules/$KERNEL_VER/devicetree/sm8250-xiaomi-pipa.dtb" \
)"

if [ -z "${KERNEL_IMAGE:-}" ] || [ ! -f "$KERNEL_IMAGE" ]; then
    echo "Kernel image was not found in the target rootfs for $KERNEL_VER" >&2
    exit 1
fi

if [ -z "${DTB_IMAGE:-}" ] || [ ! -f "$DTB_IMAGE" ]; then
    echo "Device tree was not found in the target rootfs for $KERNEL_VER" >&2
    exit 1
fi

echo "### Preparing initramfs configuration..."
echo 'LANG=C.UTF-8' > "$ROOTFS_DIR/etc/locale.conf"
echo 'KEYMAP=us' > "$ROOTFS_DIR/etc/vconsole.conf"

echo "### Generating initramfs..."
if arch-chroot "$ROOTFS_DIR" sh -c 'command -v dracut >/dev/null'; then
    mkdir -p "$ROOTFS_DIR/etc/dracut.conf.d"
    cat > "$ROOTFS_DIR/etc/dracut.conf.d/pipa.conf" <<EOF
i18n_vars="/etc/locale.conf /etc/vconsole.conf"
EOF
    arch-chroot "$ROOTFS_DIR" dracut --force --kver "$KERNEL_VER" "/boot/initramfs-$KERNEL_VER.img"
elif arch-chroot "$ROOTFS_DIR" sh -c 'command -v mkinitcpio >/dev/null'; then
    arch-chroot "$ROOTFS_DIR" mkinitcpio -P
else
    echo "No supported initramfs generator found in target rootfs" >&2
    exit 1
fi

if [ ! -f "$INITRAMFS_IMAGE" ]; then
    echo "Initramfs image was not generated for $KERNEL_VER" >&2
    exit 1
fi

echo "### Preparing kernel+dtb images..."
cat "$KERNEL_IMAGE" "$DTB_IMAGE" > "$KERNEL_IMAGE_DTB"
if [ -n "${KERNEL_IMAGE_UNCOMPRESSED:-}" ] && [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ]; then
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
arch-chroot "$ROOTFS_DIR" systemctl enable NetworkManager sshd bluetooth systemd-resolved systemd-timesyncd
arch-chroot "$ROOTFS_DIR" systemctl enable power-profiles-daemon
arch-chroot "$ROOTFS_DIR" systemctl enable bootmac-bluetooth || true
arch-chroot "$ROOTFS_DIR" systemctl enable pd-mapper rmtfs tqftpserv || true
arch-chroot "$ROOTFS_DIR" systemctl enable hexagonrpcd-sdsp hexagonrpcd-adsp-rootpd iio-sensor-proxy pipa-audio-init || true
arch-chroot "$ROOTFS_DIR" systemctl mask hexagonrpcd-adsp-sensorspd || true

echo "### Configuring Plasma login and virtual keyboard defaults..."
if [ "$DE_NAME" = "plasma" ]; then
    mkdir -p "$ROOTFS_DIR/etc/environment.d"
    cat > "$ROOTFS_DIR/etc/environment.d/90-plasma-keyboard.conf" <<EOF
KWIN_IM_SHOW_ALWAYS=1
PLASMA_KEYBOARD_USE_QT_LAYOUTS=1
EOF

    arch-chroot "$ROOTFS_DIR" sh -eu <<'EOF'
desktop_file=""
for candidate in \
    /usr/share/applications/org.kde.plasma.keyboard.desktop \
    /usr/share/applications/org.kde.plasma-keyboard.desktop \
    /usr/share/applications/plasma-keyboard.desktop
do
    if [ -f "$candidate" ]; then
        desktop_file="$candidate"
        break
    fi
done

if [ -z "$desktop_file" ]; then
    desktop_file="$(grep -rl '^X-KDE-Wayland-VirtualKeyboard=true' /usr/share/applications 2>/dev/null | grep 'plasma' | head -n 1 || true)"
fi

for config_root in /root /etc/skel; do
    install -d "$config_root/.config"
    cat > "$config_root/.config/kwinrc" <<CONFIG
[Wayland]
InputMethod=$desktop_file
CONFIG
done
EOF
fi

echo "### Configuring fish shell defaults..."
for config_root in /root /etc/skel; do
    install -d "$config_root/.config/fish"
    cat > "$config_root/.config/fish/config.fish" <<'EOF'
if status is-interactive
    if test "$SHLVL" = 1
        if command -q fastfetch
            fastfetch
        end
    end
end
EOF
done
arch-chroot "$ROOTFS_DIR" usermod -s /usr/bin/fish root
arch-chroot "$ROOTFS_DIR" useradd -D -s /usr/bin/fish

echo "### Setting root password..."
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
mkfs.ext4 -F -L "$BOOT_LABEL" -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file "$IMAGE_DIR/$IMAGE_NAME/endeavouros_boot.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/endeavouros_boot.raw" "$BOOT_MNT"
mkdir -p "$BOOT_MNT/boot/devicetree" "$BOOT_MNT/grub2/themes/endeavour" "$BOOT_MNT/efi"
cp "$KERNEL_IMAGE" "$BOOT_MNT/boot/"
cp "$KERNEL_IMAGE_DTB" "$BOOT_MNT/boot/"
cp "$INITRAMFS_IMAGE" "$BOOT_MNT/boot/"
if [ -f "$ROOTFS_DIR/boot/System.map-$KERNEL_VER" ]; then
    cp "$ROOTFS_DIR/boot/System.map-$KERNEL_VER" "$BOOT_MNT/boot/"
fi
if [ -f "$ROOTFS_DIR/boot/config-$KERNEL_VER" ]; then
    cp "$ROOTFS_DIR/boot/config-$KERNEL_VER" "$BOOT_MNT/boot/"
fi
cp "$DTB_IMAGE" "$BOOT_MNT/boot/devicetree/"
if [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ]; then
    cp "$KERNEL_IMAGE_UNCOMPRESSED" "$BOOT_MNT/boot/"
fi
if [ -f "$KERNEL_IMAGE_UNCOMPRESSED_DTB" ]; then
    cp "$KERNEL_IMAGE_UNCOMPRESSED_DTB" "$BOOT_MNT/boot/"
fi
GRUB_THEME_SOURCE="$(first_existing_dir \
    "$ROOTFS_DIR/usr/share/grub/themes/EndeavourOS" \
    "$ROOTFS_DIR/usr/share/grub/themes/endeavouros" \
    "$ROOTFS_DIR/boot/grub/themes/EndeavourOS" \
    "$ROOTFS_DIR/boot/grub/themes/endeavouros" \
    || true \
)"
GRUB_THEME_NAME=""
if [ -n "$GRUB_THEME_SOURCE" ]; then
    GRUB_THEME_NAME="$(basename "$GRUB_THEME_SOURCE")"
    rm -rf "$BOOT_MNT/grub2/themes/$GRUB_THEME_NAME"
    cp -r "$GRUB_THEME_SOURCE" "$BOOT_MNT/grub2/themes/"
else
    write_grub_splash_png "$BOOT_MNT/grub2/themes/endeavour/background.png"
fi
cat > "$BOOT_MNT/grub2/grub.cfg" <<EOF
set default=0
set timeout=5

search --no-floppy --label --set=boot $BOOT_LABEL
set root=(\$boot)

if loadfont unicode; then
    set gfxmode=auto
    set gfxpayload=keep
    terminal_output gfxterm
fi
EOF
if [ -n "$GRUB_THEME_NAME" ] && [ -f "$BOOT_MNT/grub2/themes/$GRUB_THEME_NAME/theme.txt" ]; then
cat >> "$BOOT_MNT/grub2/grub.cfg" <<EOF
set theme=(\$boot)/grub2/themes/$GRUB_THEME_NAME/theme.txt
EOF
else
cat >> "$BOOT_MNT/grub2/grub.cfg" <<EOF
if background_image -m stretch (\$boot)/grub2/themes/endeavour/background.png; then
    set color_normal=white/black
    set color_highlight=black/light-cyan
fi
set menu_color_normal=white/black
set menu_color_highlight=black/light-cyan
EOF
fi
cat >> "$BOOT_MNT/grub2/grub.cfg" <<EOF

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
# FAT cannot store Unix ownership, so avoid archive mode here.
cp -r "$EFI_TEMPLATE_DIR/EFI" "$ESP_MNT/"
mkdir -p "$ESP_MNT/EFI/fedora"
cp -r "$ESP_MNT/EFI/endeavour/." "$ESP_MNT/EFI/fedora/"
for shim_vendor in endeavour fedora; do
cat > "$ESP_MNT/EFI/$shim_vendor/grub.cfg" <<EOF
if [ -e (md/md-boot) ]; then
  # The search command might pick a RAID component rather than the RAID,
  # since the /boot RAID currently uses superblock 1.0.  See the comment in
  # the main grub.cfg.
  set prefix=md/md-boot
else
  if [ -f \${config_directory}/bootuuid.cfg ]; then
    source \${config_directory}/bootuuid.cfg
  fi
  if [ -n "\${BOOT_UUID}" ]; then
    search --fs-uuid "\${BOOT_UUID}" --set prefix --no-floppy
  else
    search --label $BOOT_LABEL --set prefix --no-floppy
  fi
fi
if [ -d (\$prefix)/grub2 ]; then
  set prefix=(\$prefix)/grub2
  configfile \$prefix/grub.cfg
else
  set prefix=(\$prefix)/boot/grub2
  configfile \$prefix/grub.cfg
fi
boot
EOF
cat > "$ESP_MNT/EFI/$shim_vendor/bootuuid.cfg" <<EOF
set BOOT_UUID=""
EOF
done
write_uefi_csv \
    "$ESP_MNT/EFI/fedora/BOOTAA64.CSV" \
    "shimaa64.efi" \
    "Fedora" \
    "This is the boot entry for Fedora"
write_uefi_csv \
    "$ESP_MNT/EFI/endeavour/BOOTAA64.CSV" \
    "shimaa64.efi" \
    "EndeavourOS" \
    "This is the boot entry for EndeavourOS"
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
