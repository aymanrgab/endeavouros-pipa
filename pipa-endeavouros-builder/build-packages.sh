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

# Ensure base-devel is installed
pacman -Syu --needed --noconfirm base-devel git sudo

# Create a local repo
REPO_DIR="/repo"
mkdir -p "$REPO_DIR"
chown -R builder:builder "$REPO_DIR"

for pkg in "${PKGS[@]}"; do
  echo "Building $pkg..."
  pkg_dir="/build/pkgbuilds/$pkg"

  # Build as the unprivileged builder user because makepkg refuses to run as root.
  su builder -c "cd '$pkg_dir' && makepkg -s --noconfirm --nocheck"

  # Copy built packages to local repo
  cp "$pkg_dir"/*.pkg.tar.zst "$REPO_DIR/"

  # Add to local repo db
  repo-add "$REPO_DIR/pipa.db.tar.gz" "$REPO_DIR"/*.pkg.tar.zst

  # Install the built package so it can satisfy dependencies of subsequent packages
  pacman -U --noconfirm "$pkg_dir"/*.pkg.tar.zst
done

echo "All packages built successfully and added to local repo at $REPO_DIR."
