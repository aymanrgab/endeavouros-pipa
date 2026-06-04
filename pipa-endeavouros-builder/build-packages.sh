#!/bin/bash
set -e

# Run this script inside an Arch Linux ARM container or natively on an AArch64 Arch system

PKGS=(
  "linux-pipa"
  "qbootctl"
  "xiaomi-pipa-firmware"
  "alsa-ucm-conf-sm8250"
  "pipa-kernel-flasher-hook"
  "bootmac"
  "hexagonrpc"
  "libssc"
  "iio-sensor-proxy"
  "pipa-dracut"
  "pipa-sensors"
  "pipa-sound-conf"
  "pipa-metapkg"
)

# Preinstall the Arch-side toolchain and libraries so makepkg never has to
# invoke pacman itself. That avoids sudo/nosuid problems inside Docker build.
pacman -Syu --needed --noconfirm \
  base-devel git sudo gcc make \
  arch-install-scripts e2fsprogs dosfstools zip unzip \
  bc bison flex cpio kmod python tar xz meson ninja cmake rsync wget \
  glib2 libgudev polkit libqmi protobuf-c qrtr dracut android-tools \
  pahole gtk-doc umockdev

# Create a local repo
REPO_DIR="/repo"
mkdir -p "$REPO_DIR"
chown -R builder:builder "$REPO_DIR"

for pkg in "${PKGS[@]}"; do
  echo "Building $pkg..."
  pkg_dir="/build/pkgbuilds/$pkg"

  # Build as the unprivileged builder user because makepkg refuses to run as root.
  su builder -c "cd '$pkg_dir' && makepkg --nodeps --noconfirm --nocheck"

  shopt -s nullglob
  built_packages=("$pkg_dir"/*.pkg.tar.zst "$pkg_dir"/*.pkg.tar.xz)
  shopt -u nullglob
  if [ ${#built_packages[@]} -eq 0 ]; then
    echo "No package archives were produced for $pkg in $pkg_dir"
    exit 1
  fi

  # Copy built packages to local repo
  cp "${built_packages[@]}" "$REPO_DIR/"

  # Add to local repo db
  repo-add "$REPO_DIR/pipa.db.tar.gz" "${built_packages[@]}"

  # Install the built package so it can satisfy dependencies of subsequent packages
  pacman -U --noconfirm "${built_packages[@]}"
done

echo "All packages built successfully and added to local repo at $REPO_DIR."
