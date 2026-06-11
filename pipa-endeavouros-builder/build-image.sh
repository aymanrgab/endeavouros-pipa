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
TARGET_KERNEL_CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 console=ttyS0 earlycon quiet splash"
TARGET_KERNEL_DEBUG_CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 console=ttyS0 earlycon ignore_loglevel loglevel=8 no_console_suspend rd.debug systemd.log_level=debug systemd.log_target=console plymouth.enable=0"
PACMAN_CONF="$(pwd)/pacman-pipa.conf"
EFI_TEMPLATE_DIR="$(pwd)/efi-template"
VBMETA_DISABLED_IMG="$(pwd)/vbmeta-disabled.img"
PIPA_REPO_URL="${PIPA_REPO_URL:-https://thespider2.github.io/pipa-pkgs/repo/}"
SILICIUM_URL="https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img"
SILICIUM_SHA256="ea3e1e123beea7ee5394295bdfee75054711d4734e9403831fda7f037fc900b6"
GRUB_THEME_ARCHIVE_URL="${GRUB_THEME_ARCHIVE_URL:-https://codeload.github.com/EndeavourOS-archive/grub2-theme-endeavouros/tar.gz/refs/heads/main}"
GRUB_GFXMODE="${GRUB_GFXMODE:-1280x800,1024x768,auto}"
PIPA_REPO_NAME="${PIPA_REPO_NAME:-pipa-pkgs}"
PIPA_INCLUDE_SENSORS="${PIPA_INCLUDE_SENSORS:-1}"
ESP_SIZE_MB=128
BOOT_SIZE_MB=1024
PIPA_CORE_PACKAGES=(
    alsa-ucm-conf-sm8250
    bluez-git
    bootmac
    linux-pipa
    pd-mapper
    pipa-dracut
    pipa-kernel-flasher-hook
    pipa-sound-conf
    qbootctl
    qrtr
    rmtfs
    tqftpserv
    xiaomi-pipa-firmware
)
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
    PIPA_CORE_PACKAGES+=(
        hexagonrpc
        iio-sensor-proxy-pipa
        libssc
        pipa-sensors
    )
fi

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

qualify_repo_targets() {
    local pkg
    for pkg in "$@"; do
        printf '%s/%s\n' "$PIPA_REPO_NAME" "$pkg"
    done
}

assert_required_rootfs_files() {
    local file_path
    for file_path in "$@"; do
        if [ ! -f "$ROOTFS_DIR/$file_path" ]; then
            echo "Missing required file in target rootfs: /$file_path" >&2
            exit 1
        fi
    done
}

write_placeholder_initramfs() {
    local initramfs_path="$1"

    python - "$initramfs_path" <<'PY'
import gzip
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_bytes(gzip.compress(b"pipa placeholder initramfs\n"))
PY
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

if [ ! -f "$VBMETA_DISABLED_IMG" ]; then
    echo "Missing disabled vbmeta image: $VBMETA_DISABLED_IMG"
    exit 1
fi

echo "### Preparing pacman configuration..."
cp /etc/pacman.conf "$PACMAN_CONF"
sed -i '/^DisableSandbox$/d' "$PACMAN_CONF"
sed -i '/^\[options\]$/a DisableSandbox' "$PACMAN_CONF"
cat <<EOF >> "$PACMAN_CONF"

[$PIPA_REPO_NAME]
SigLevel = Optional TrustAll
Server = $PIPA_REPO_URL

[endeavouros]
SigLevel = Optional TrustAll
Server = https://mirror.moson.org/endeavouros/repo/\$repo/\$arch
EOF

BASE_PACKAGES=(
    base base-devel sudo nano vim git wget rsync openssh lsb-release
    networkmanager iwd mesa
    linux-firmware
    archlinuxarm-keyring
    alsa-ucm-conf alsa-utils
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    power-profiles-daemon upower modemmanager xdg-user-dirs
    iptables noto-fonts qt6-virtualkeyboard
    dracut
    fish fastfetch zenity
    grub
    endeavouros-branding endeavouros-keyring endeavouros-mirrorlist endeavouros-theming
    eos-bash-shared eos-hooks eos-rankmirrors eos-translations eos-update eos-update-notifier welcome
)

# Install the published Pipa packages directly from the hosted repo.
# `pipa-metapkg` pulls the core tablet stack from the repo. Only list
# additional repo packages here that do not overlap with that dependency set.
PIPA_REPO_PACKAGES=(
    box64
    gamescope
    mangohud-git
    mkbootimg-pipa
    pipa-kernel-flasher-hook
    swclock-offset
    widevine
    wine-aarch64
)
mapfile -t QUALIFIED_PIPA_CORE_PACKAGES < <(qualify_repo_targets "${PIPA_CORE_PACKAGES[@]}")
mapfile -t QUALIFIED_PIPA_REPO_PACKAGES < <(qualify_repo_targets "${PIPA_REPO_PACKAGES[@]}")

case "$DE_NAME" in
    plasma)
        DESKTOP_PACKAGES=(
            plasma-meta plasma-login-manager plasma-keyboard xdg-desktop-portal-kde
            firefox flatpak
            kdeconnect discover konsole dolphin ark filelight
            gwenview okular spectacle elisa kate kcalc kalk
            plasma-browser-integration plasma-systemmonitor
            endeavouros-konsole-colors eos-settings-plasma kdialog
            qt6-multimedia-ffmpeg
        )
        DISPLAY_MANAGER="plasmalogin"
        ;;
    gnome)
        DESKTOP_PACKAGES=(
            gnome-shell gnome-session gnome-control-center gnome-console
            nautilus eog evince file-roller gnome-text-editor gnome-tweaks
            gdm xdg-desktop-portal-gnome
            firefox flatpak
            eos-settings-gnome
        )
        DISPLAY_MANAGER="gdm"
        ;;
    *)
        echo "Unsupported desktop environment: $DE_NAME"
        exit 1
        ;;
esac

echo "### Seeding kernel cmdline for package hooks..."
install -d "$ROOTFS_DIR/etc" "$ROOTFS_DIR/boot"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/etc/cmdline"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/boot/cmdline.txt"
write_placeholder_initramfs "$ROOTFS_DIR/boot/initramfs.img"

echo "### Bootstrapping rootfs with pacstrap..."
pacstrap -C "$PACMAN_CONF" -KGM "$ROOTFS_DIR" "${BASE_PACKAGES[@]}" "${QUALIFIED_PIPA_CORE_PACKAGES[@]}" "${QUALIFIED_PIPA_REPO_PACKAGES[@]}" "${DESKTOP_PACKAGES[@]}"

echo "### Writing target pacman configuration..."
cp "$PACMAN_CONF" "$ROOTFS_DIR/etc/pacman.conf"

echo "### Validating repo-provided Pipa audio configuration..."
assert_required_rootfs_files \
    "usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi Pad 6.conf" \
    "usr/share/alsa/ucm2/Qualcomm/sm8250/HiFi_pipa.conf" \
    "usr/share/wireplumber/wireplumber.conf.d/51-pipa.conf"
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
    echo "### Validating repo-provided Pipa sensor configuration..."
    assert_required_rootfs_files \
        "usr/lib/libssc.so.0" \
        "usr/lib/udev/rules.d/81-libssc-xiaomi-pipa.rules" \
        "usr/share/hexagonrpcd/hexagonrpcd-sdsp.conf" \
        "usr/share/hexagonrpcd/hexagonrpcd-adsp-rootpd.conf" \
        "usr/share/hexagonrpcd/hexagonrpcd-adsp-sensorspd.conf"
fi
ln -sf "Xiaomi Pad 6.conf" \
    "$ROOTFS_DIR/usr/share/alsa/ucm2/conf.d/sm8250/sm8250.conf"
ln -sf "Xiaomi Pad 6.conf" \
    "$ROOTFS_DIR/usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi-Pad6-pipa-M82.conf"
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
    install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/systemd/system/iio-sensor-proxy.service.d/10-pipa-audio.conf" <<'EOF'
[Unit]
Wants=
After=
Wants=hexagonrpcd-adsp-rootpd.service
Wants=hexagonrpcd-sdsp.service
After=hexagonrpcd-adsp-rootpd.service
After=hexagonrpcd-sdsp.service
EOF
fi

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
EOF
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
cat >> "$ROOTFS_DIR/usr/lib/systemd/system/pipa-audio-init.service" <<'EOF'
After=systemd-udev-settle.service pd-mapper.service rmtfs.service tqftpserv.service hexagonrpcd-adsp-rootpd.service hexagonrpcd-sdsp.service
Wants=systemd-udev-settle.service pd-mapper.service rmtfs.service tqftpserv.service hexagonrpcd-adsp-rootpd.service hexagonrpcd-sdsp.service
EOF
else
cat >> "$ROOTFS_DIR/usr/lib/systemd/system/pipa-audio-init.service" <<'EOF'
After=systemd-udev-settle.service pd-mapper.service rmtfs.service tqftpserv.service
Wants=systemd-udev-settle.service pd-mapper.service rmtfs.service tqftpserv.service
EOF
fi
cat >> "$ROOTFS_DIR/usr/lib/systemd/system/pipa-audio-init.service" <<'EOF'
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pipa-audio-init
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/pipa-prepare-sensor-persist" <<'EOF'
#!/bin/sh
set -eu

for dir in \
    /mnt/vendor/persist \
    /mnt/vendor/persist/sensors \
    /mnt/vendor/persist/sensors/registry \
    /mnt/vendor/persist/sensors/registry/registry
do
    install -d -m 0775 -o fastrpc -g fastrpc "$dir"
done
EOF

install -Dm644 /dev/stdin "$ROOTFS_DIR/usr/lib/systemd/system/pipa-sensors-persist.service" <<'EOF'
[Unit]
Description=Prepare Xiaomi Pad 6 sensor persist directories
DefaultDependencies=no
After=local-fs.target systemd-sysusers.service
Before=hexagonrpcd-adsp-rootpd.service hexagonrpcd-sdsp.service hexagonrpcd-adsp-sensorspd.service iio-sensor-proxy.service
Wants=systemd-sysusers.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pipa-prepare-sensor-persist

[Install]
WantedBy=multi-user.target
EOF

install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/lib/systemd/system-sleep/pipa-sensors-resume" <<'EOF'
#!/bin/sh
set -eu

case "${1:-}/${2:-}" in
    post/*)
        ;;
    *)
        exit 0
        ;;
esac

# Give the fastrpc devices a moment to reappear after resume.
sleep 2

/usr/local/bin/pipa-prepare-sensor-persist || true
systemctl restart hexagonrpcd-adsp-rootpd.service || true
systemctl restart hexagonrpcd-sdsp.service || true
systemctl restart hexagonrpcd-adsp-sensorspd.service || true
systemctl restart iio-sensor-proxy.service || true
EOF
fi

install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/pipa-set-power-profile" <<'EOF'
#!/bin/sh
set -eu

profile="${1:-}"

case "$profile" in
    battery)
        governor_preferences="powersave schedutil ondemand conservative performance"
        max_percent=60
        ;;
    balanced)
        governor_preferences="schedutil ondemand conservative powersave performance"
        max_percent=85
        ;;
    performance)
        governor_preferences="performance schedutil ondemand conservative powersave"
        max_percent=100
        ;;
    *)
        echo "Usage: $0 {battery|balanced|performance}" >&2
        exit 1
        ;;
esac

pick_governor() {
    available_governors="$1"

    for candidate in $governor_preferences; do
        case " $available_governors " in
            *" $candidate "*) printf '%s\n' "$candidate"; return 0 ;;
        esac
    done

    return 1
}

applied=0
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    applied=1

    available_governors="$(cat "$policy/scaling_available_governors" 2>/dev/null || true)"
    governor="$(pick_governor "$available_governors" || cat "$policy/scaling_governor")"
    cpuinfo_max="$(cat "$policy/cpuinfo_max_freq")"
    cpuinfo_min="$(cat "$policy/cpuinfo_min_freq" 2>/dev/null || cat "$policy/scaling_min_freq")"
    target_max=$((cpuinfo_max * max_percent / 100))

    if [ "$target_max" -lt "$cpuinfo_min" ]; then
        target_max="$cpuinfo_min"
    fi

    if [ -w "$policy/scaling_governor" ]; then
        printf '%s\n' "$governor" > "$policy/scaling_governor"
    fi

    if [ -w "$policy/scaling_min_freq" ]; then
        printf '%s\n' "$cpuinfo_min" > "$policy/scaling_min_freq"
    fi

    if [ -w "$policy/scaling_max_freq" ]; then
        printf '%s\n' "$target_max" > "$policy/scaling_max_freq"
    fi
done

if [ "$applied" -eq 0 ]; then
    echo "No cpufreq policies were found" >&2
    exit 1
fi
EOF

install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/pipa-power-battery" <<'EOF'
#!/bin/sh
set -eu
if [ "$(id -u)" -eq 0 ]; then
    exec /usr/local/bin/pipa-set-power-profile battery
fi
exec sudo /usr/local/bin/pipa-set-power-profile battery
EOF

install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/pipa-power-balanced" <<'EOF'
#!/bin/sh
set -eu
if [ "$(id -u)" -eq 0 ]; then
    exec /usr/local/bin/pipa-set-power-profile balanced
fi
exec sudo /usr/local/bin/pipa-set-power-profile balanced
EOF

install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/pipa-power-performance" <<'EOF'
#!/bin/sh
set -eu
if [ "$(id -u)" -eq 0 ]; then
    exec /usr/local/bin/pipa-set-power-profile performance
fi
exec sudo /usr/local/bin/pipa-set-power-profile performance
EOF

install -Dm644 /dev/stdin "$ROOTFS_DIR/usr/lib/systemd/system/pipa-power-profile@.service" <<'EOF'
[Unit]
Description=Apply Xiaomi Pad 6 power profile %I
ConditionPathExists=/sys/devices/system/cpu/cpufreq
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pipa-set-power-profile %I
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

install -Dm755 /dev/stdin "$ROOTFS_DIR/usr/local/bin/pipa-firstboot-setup" <<'EOF'
#!/bin/sh
set -eu

TITLE="EndeavourOS Pipa Setup"
STATE_DIR=/var/lib/pipa-firstboot
SENTINEL="$STATE_DIR/needs-setup"
LOCK_FILE="$STATE_DIR/lock"
AUTOSTART_FILE=/root/.config/autostart/pipa-firstboot-setup.desktop
DEFAULT_HOSTNAME="pipa"
DEFAULT_SHELL="/usr/bin/fish"
PIPA_FIRSTBOOT_DM="$(cat /etc/pipa-firstboot-dm 2>/dev/null || printf '%s' plasmalogin)"

[ -f "$SENTINEL" ] || exit 0

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

dialog_backend() {
    if command -v zenity >/dev/null 2>&1; then
        printf '%s\n' zenity
        return 0
    fi

    if command -v kdialog >/dev/null 2>&1; then
        printf '%s\n' kdialog
        return 0
    fi

    return 1
}

prompt_info() {
    message="$1"

    case "$(dialog_backend)" in
        zenity)
            zenity --info --title "$TITLE" --text "$message" >/dev/null 2>&1 || return 1
            ;;
        kdialog)
            kdialog --title "$TITLE" --msgbox "$message" >/dev/null 2>&1 || return 1
            ;;
    esac
}

prompt_error() {
    message="$1"

    case "$(dialog_backend)" in
        zenity)
            zenity --error --title "$TITLE" --text "$message" >/dev/null 2>&1 || true
            ;;
        kdialog)
            kdialog --title "$TITLE" --error "$message" >/dev/null 2>&1 || true
            ;;
    esac
}

trim_whitespace() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

prompt_required_text() {
    prompt="$1"
    default_value="${2:-}"

    while :; do
        case "$(dialog_backend)" in
            zenity)
                answer="$(zenity --entry --title "$TITLE" --text "$prompt" --entry-text "$default_value" 2>/dev/null)" || return 1
                ;;
            kdialog)
                answer="$(kdialog --title "$TITLE" --inputbox "$prompt" "$default_value" 2>/dev/null)" || return 1
                ;;
        esac
        answer="$(trim_whitespace "$answer")"
        if [ -n "$answer" ]; then
            printf '%s\n' "$answer"
            return 0
        fi
        prompt_error "This field cannot be empty."
    done
}

prompt_optional_text() {
    prompt="$1"
    default_value="${2:-}"

    case "$(dialog_backend)" in
        zenity)
            answer="$(zenity --entry --title "$TITLE" --text "$prompt" --entry-text "$default_value" 2>/dev/null)" || return 1
            ;;
        kdialog)
            answer="$(kdialog --title "$TITLE" --inputbox "$prompt" "$default_value" 2>/dev/null)" || return 1
            ;;
    esac
    trim_whitespace "$answer"
}

prompt_password() {
    prompt="$1"

    while :; do
        case "$(dialog_backend)" in
            zenity)
                password="$(zenity --entry --title "$TITLE" --text "$prompt" --hide-text 2>/dev/null)" || return 1
                ;;
            kdialog)
                password="$(kdialog --title "$TITLE" --password "$prompt" 2>/dev/null)" || return 1
                ;;
        esac
        if [ -z "$password" ]; then
            prompt_error "Password cannot be empty."
            continue
        fi

        case "$(dialog_backend)" in
            zenity)
                confirmation="$(zenity --entry --title "$TITLE" --text "Confirm the password." --hide-text 2>/dev/null)" || return 1
                ;;
            kdialog)
                confirmation="$(kdialog --title "$TITLE" --password "Confirm the password." 2>/dev/null)" || return 1
                ;;
        esac
        if [ "$password" != "$confirmation" ]; then
            prompt_error "Passwords do not match. Please try again."
            continue
        fi

        printf '%s\n' "$password"
        return 0
    done
}

valid_username() {
    printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]*[$]?$'
}

valid_hostname() {
    printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
}

prompt_info "Welcome to EndeavourOS ARM for Xiaomi Pad 6.\n\nThis first-boot setup will create your user account, set the hostname, and then reboot into the normal login screen." || exit 0

while :; do
    fullname="$(prompt_optional_text 'Full name (optional):' '')" || exit 0
    username="$(prompt_required_text 'Username:' '')" || exit 0
    username="$(printf '%s' "$username" | tr '[:upper:]' '[:lower:]')"

    if ! valid_username "$username"; then
        prompt_error "Username must start with a letter or underscore and may contain lowercase letters, numbers, hyphens, or underscores."
        continue
    fi

    if id "$username" >/dev/null 2>&1; then
        prompt_error "User '$username' already exists. Choose another username."
        continue
    fi

    hostname="$(prompt_required_text 'Hostname:' "$DEFAULT_HOSTNAME")" || exit 0
    hostname="$(printf '%s' "$hostname" | tr '[:upper:]' '[:lower:]')"

    if ! valid_hostname "$hostname"; then
        prompt_error "Hostname may only contain lowercase letters, numbers, and hyphens, and it must begin and end with a letter or number."
        continue
    fi

    password="$(prompt_password "Password for $username:")" || exit 0
    break
done

if [ -n "$fullname" ]; then
    useradd -m -G wheel -s "$DEFAULT_SHELL" -c "$fullname" "$username"
else
    useradd -m -G wheel -s "$DEFAULT_SHELL" "$username"
fi

printf 'root:%s\n%s:%s\n' "$password" "$username" "$password" | chpasswd

printf '%s\n' "$hostname" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 $hostname.localdomain $hostname
HOSTS

case "$PIPA_FIRSTBOOT_DM" in
    plasmalogin)
        rm -f /etc/plasmalogin.conf.d/10-firstboot-autologin.conf /etc/plasmalogin.conf.d/05-default-session.conf
        ;;
    gdm)
        rm -f /etc/gdm/custom.conf.d/10-firstboot-autologin.conf
        ;;
esac
rm -f "$AUTOSTART_FILE" "$SENTINEL"

prompt_info "Setup complete.\n\nUser '$username' was created, the hostname was set to '$hostname', and the system will now reboot." || true
systemctl reboot
EOF

if [ "$DE_NAME" = "plasma" ]; then
    SESSION_FILE="$(first_existing_file \
        "$ROOTFS_DIR/usr/share/wayland-sessions/plasmawayland.desktop" \
        "$ROOTFS_DIR/usr/share/wayland-sessions/plasma.desktop" \
        "$ROOTFS_DIR/usr/share/xsessions/plasma.desktop" \
    )"
    SESSION_NAME="$(basename "$SESSION_FILE")"
    FIRSTBOOT_DM="plasmalogin"

    install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/plasmalogin.conf.d/05-default-session.conf" <<EOF
[Sessions]
DefaultSession=$SESSION_NAME
EOF

    install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/plasmalogin.conf.d/10-firstboot-autologin.conf" <<EOF
[Autologin]
User=root
Session=$SESSION_NAME
Relogin=false
EOF
else
    SESSION_FILE="$(first_existing_file \
        "$ROOTFS_DIR/usr/share/xsessions/gnome.desktop" \
        "$ROOTFS_DIR/usr/share/xsessions/gnome-xorg.desktop" \
        "$ROOTFS_DIR/usr/share/wayland-sessions/gnome.desktop" \
    )"
    SESSION_NAME="$(basename "$SESSION_FILE" .desktop)"
    FIRSTBOOT_DM="gdm"

    install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/gdm/custom.conf.d/10-firstboot-autologin.conf" <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=root
DefaultSession=$SESSION_NAME
EOF
fi

printf '%s\n' "$FIRSTBOOT_DM" > "$ROOTFS_DIR/etc/pipa-firstboot-dm"

install -Dm644 /dev/stdin "$ROOTFS_DIR/root/.config/autostart/pipa-firstboot-setup.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=EndeavourOS Pipa First Boot Setup
Exec=sh -lc 'sleep 3; exec /usr/local/bin/pipa-firstboot-setup'
NoDisplay=true
EOF

install -d "$ROOTFS_DIR/var/lib/pipa-firstboot"
: > "$ROOTFS_DIR/var/lib/pipa-firstboot/needs-setup"

echo "### Validating critical firmware payloads..."
assert_required_rootfs_files \
    "usr/lib/firmware/qcom/a650_sqe.fw" \
    "usr/lib/firmware/qcom/a650_gmu.bin" \
    "usr/lib/firmware/qca/htbtfw20.tlv" \
    "usr/lib/firmware/ath11k/QCA6390/hw2.0/amss.bin" \
    "usr/lib/firmware/ath11k/QCA6390/hw2.0/board-2.bin" \
    "usr/lib/firmware/ath11k/QCA6390/hw2.0/m3.bin"

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

INITRAMFS_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" \
    "$ROOTFS_DIR/boot/initramfs.img" \
)"

if [ ! -f "$INITRAMFS_IMAGE" ]; then
    echo "Initramfs image was not generated for $KERNEL_VER" >&2
    exit 1
fi

if [ "$(stat -c '%s' "$INITRAMFS_IMAGE")" -lt 1048576 ]; then
    echo "Initramfs image for $KERNEL_VER is unexpectedly small: $INITRAMFS_IMAGE" >&2
    exit 1
fi

if [ "$INITRAMFS_IMAGE" != "$ROOTFS_DIR/boot/initramfs.img" ]; then
    cp "$INITRAMFS_IMAGE" "$ROOTFS_DIR/boot/initramfs.img"
fi

if [ "$(stat -c '%s' "$ROOTFS_DIR/boot/initramfs.img")" -lt 1048576 ]; then
    echo "Canonical /boot/initramfs.img is unexpectedly small after copy" >&2
    exit 1
fi

echo "### Preparing kernel+dtb images..."
cat "$KERNEL_IMAGE" "$DTB_IMAGE" > "$KERNEL_IMAGE_DTB"
if [ -n "${KERNEL_IMAGE_UNCOMPRESSED:-}" ] && [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ]; then
    cat "$KERNEL_IMAGE_UNCOMPRESSED" "$DTB_IMAGE" > "$KERNEL_IMAGE_UNCOMPRESSED_DTB"
fi

GRUB_PRIMARY_KERNEL="$(basename "$KERNEL_IMAGE_DTB")"
GRUB_SEPARATE_DTB_KERNEL="$(basename "$KERNEL_IMAGE")"
if [ -n "${KERNEL_IMAGE_UNCOMPRESSED:-}" ] && [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ]; then
    GRUB_SEPARATE_DTB_KERNEL="$(basename "$KERNEL_IMAGE_UNCOMPRESSED")"
fi
if [ -n "${KERNEL_IMAGE_UNCOMPRESSED_DTB:-}" ] && [ -f "$KERNEL_IMAGE_UNCOMPRESSED_DTB" ]; then
    GRUB_PRIMARY_KERNEL="$(basename "$KERNEL_IMAGE_UNCOMPRESSED_DTB")"
fi

echo "### Setting up /etc/cmdline..."
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/etc/cmdline"

echo "### Setting up /etc/fstab..."
cat > "$ROOTFS_DIR/etc/fstab" <<EOF
LABEL=$ROOTFS_LABEL / ext4 defaults,x-systemd.growfs 0 1
LABEL=$BOOT_LABEL /boot ext4 defaults 0 2
EOF

echo "### Configuring system services..."
arch-chroot "$ROOTFS_DIR" systemctl enable "$DISPLAY_MANAGER"
arch-chroot "$ROOTFS_DIR" systemctl enable NetworkManager sshd bluetooth systemd-resolved systemd-timesyncd
arch-chroot "$ROOTFS_DIR" systemctl enable power-profiles-daemon
arch-chroot "$ROOTFS_DIR" systemctl enable pipa-power-profile@balanced.service
arch-chroot "$ROOTFS_DIR" systemctl enable bootmac-bluetooth || true
arch-chroot "$ROOTFS_DIR" systemctl enable pd-mapper rmtfs tqftpserv || true
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
    arch-chroot "$ROOTFS_DIR" systemctl enable \
        pipa-sensors-persist \
        hexagonrpcd-sdsp \
        hexagonrpcd-adsp-rootpd \
        hexagonrpcd-adsp-sensorspd \
        iio-sensor-proxy \
        pipa-audio-init || true
else
    arch-chroot "$ROOTFS_DIR" systemctl enable pipa-audio-init || true
fi

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
mkdir -p "$BOOT_MNT/boot/devicetree" "$BOOT_MNT/dtbs/qcom" "$BOOT_MNT/grub2/themes/endeavour" "$BOOT_MNT/efi"
cp "$KERNEL_IMAGE" "$BOOT_MNT/boot/"
cp "$KERNEL_IMAGE" "$BOOT_MNT/Image.gz"
cp "$KERNEL_IMAGE_DTB" "$BOOT_MNT/boot/"
cp "$INITRAMFS_IMAGE" "$BOOT_MNT/boot/"
cp "$INITRAMFS_IMAGE" "$BOOT_MNT/initramfs.img"
if [ -f "$ROOTFS_DIR/boot/System.map-$KERNEL_VER" ]; then
    cp "$ROOTFS_DIR/boot/System.map-$KERNEL_VER" "$BOOT_MNT/boot/"
fi
if [ -f "$ROOTFS_DIR/boot/config-$KERNEL_VER" ]; then
    cp "$ROOTFS_DIR/boot/config-$KERNEL_VER" "$BOOT_MNT/boot/"
fi
cp "$DTB_IMAGE" "$BOOT_MNT/boot/devicetree/"
cp "$DTB_IMAGE" "$BOOT_MNT/dtbs/qcom/"
if [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ]; then
    cp "$KERNEL_IMAGE_UNCOMPRESSED" "$BOOT_MNT/boot/"
    cp "$KERNEL_IMAGE_UNCOMPRESSED" "$BOOT_MNT/Image"
fi
if [ -f "$KERNEL_IMAGE_UNCOMPRESSED_DTB" ]; then
    cp "$KERNEL_IMAGE_UNCOMPRESSED_DTB" "$BOOT_MNT/boot/"
fi
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$BOOT_MNT/cmdline.txt"
GRUB_THEME_SOURCE="$(first_existing_dir \
    "$ROOTFS_DIR/usr/share/grub/themes/EndeavourOS" \
    "$ROOTFS_DIR/usr/share/grub/themes/endeavouros" \
    "$ROOTFS_DIR/boot/grub/themes/EndeavourOS" \
    "$ROOTFS_DIR/boot/grub/themes/endeavouros" \
    || true \
)"
GRUB_THEME_TMP=""
if [ -z "$GRUB_THEME_SOURCE" ]; then
    GRUB_THEME_TMP="$(mktemp -d)"
    wget -O "$GRUB_THEME_TMP/endeavouros-grub-theme.tar.gz" "$GRUB_THEME_ARCHIVE_URL"
    tar -xzf "$GRUB_THEME_TMP/endeavouros-grub-theme.tar.gz" -C "$GRUB_THEME_TMP"
    GRUB_THEME_SOURCE="$(first_existing_dir \
        "$GRUB_THEME_TMP"/grub2-theme-endeavouros-*/EndeavourOS \
        "$GRUB_THEME_TMP"/grub2-theme-endeavouros-*/endeavouros \
        || true \
    )"
fi
GRUB_THEME_NAME=""
if [ -n "$GRUB_THEME_SOURCE" ]; then
    GRUB_THEME_NAME="$(basename "$GRUB_THEME_SOURCE")"
    rm -rf "$BOOT_MNT/grub2/themes/$GRUB_THEME_NAME"
    cp -r "$GRUB_THEME_SOURCE" "$BOOT_MNT/grub2/themes/"
else
    write_grub_splash_png "$BOOT_MNT/grub2/themes/endeavour/background.png"
fi
if [ -n "$GRUB_THEME_TMP" ]; then
    rm -rf "$GRUB_THEME_TMP"
fi
cat > "$BOOT_MNT/grub2/grub.cfg" <<EOF
set default=1
set timeout=5

search --no-floppy --label --set=boot $BOOT_LABEL
set root=(\$boot)

if loadfont unicode; then
    set gfxmode=$GRUB_GFXMODE
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
    linux (\$boot)/boot/$GRUB_PRIMARY_KERNEL root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 console=ttyS0 earlycon quiet splash
    initrd (\$boot)/boot/$(basename "$INITRAMFS_IMAGE")
}

menuentry "EndeavourOS ARM (Pipa) - Separate DTB Fallback" {
    devicetree (\$boot)/boot/devicetree/sm8250-xiaomi-pipa.dtb
    linux (\$boot)/boot/$GRUB_SEPARATE_DTB_KERNEL root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 console=ttyS0 earlycon quiet splash
    initrd (\$boot)/boot/$(basename "$INITRAMFS_IMAGE")
}

menuentry "EndeavourOS ARM (Pipa) - Gzipped Kernel Fallback" {
    devicetree (\$boot)/boot/devicetree/sm8250-xiaomi-pipa.dtb
    linux (\$boot)/boot/$(basename "$KERNEL_IMAGE") root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 console=ttyS0 earlycon quiet splash
    initrd (\$boot)/boot/$(basename "$INITRAMFS_IMAGE")
}

menuentry "EndeavourOS ARM (Pipa) - Debug Verbose" {
    devicetree (\$boot)/boot/devicetree/sm8250-xiaomi-pipa.dtb
    linux (\$boot)/boot/$GRUB_SEPARATE_DTB_KERNEL $TARGET_KERNEL_DEBUG_CMDLINE
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

echo "### Copying disabled vbmeta image..."
cp "$VBMETA_DISABLED_IMG" "$IMAGE_DIR/$IMAGE_NAME/vbmeta-disabled.img"

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

    echo "$prompt" >&2
    for index in "${!options[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${options[$index]}" >&2
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
