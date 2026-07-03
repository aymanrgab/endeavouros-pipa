# EndeavourOS for Xiaomi Pad 6 (Pipa)

This project contains the build infrastructure used to produce EndeavourOS images for the Xiaomi Pad 6 (Pipa). Device support packages are published separately through the `pipa-pkgs` pacman repo.

The current boot flow uses the upstream [Mu-Silicium](https://github.com/onesaladleaf/Mu-Silicium) Pipa boot image release together with a custom Pipa-enabled EndeavourOS root filesystem.

## Automated Builds via CircleCI

This repository is configured with a [CircleCI pipeline](.circleci/config.yml) that builds EndeavourOS images on native ARM hardware.
The pipeline uses CircleCI's `arm.large` machine resource class so the kernel build runs natively instead of under x86 emulation.

When a build completes, the generated image ZIP files are available as CircleCI job artifacts.

Pipeline parameters let you build only one desktop environment when needed:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `build_plasma` | `true` | Build the Plasma image |
| `build_gnome` | `true` | Build the GNOME image |

## Local Build Instructions

The easiest way to build locally is with the included `Makefile`:

```bash
make builder    # build the Docker image (once)
make plasma     # build the Plasma image
make gnome      # build the GNOME image
make all        # build both images
```

You can also build manually with Docker on an ARM64 host, or on x86_64 with QEMU binfmt configured:

1. Build the builder container:
   ```bash
   docker build pipa-endeavouros-builder -t pipa-endeavouros-builder
   ```

2. Build a desktop image:
   ```bash
   mkdir -p images
   docker run --rm --privileged \
     -v "$(pwd)/images:/build/images" \
     -v "/dev:/dev" \
     -e "BUILD_GIT_REV=$(git rev-parse --short HEAD)" \
     pipa-endeavouros-builder plasma
   ```

   Replace `plasma` with `gnome` for the GNOME image.

### Build environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PIPA_REPO_URL` | `https://thespider2.github.io/pipa-pkgs/repo/` | Pacman repo URL for device packages |
| `PIPA_REPO_NAME` | `pipa-pkgs` | Pacman repo section name |
| `PIPA_INCLUDE_SENSORS` | `1` | Set to `0` to omit sensor packages |
| `BUILD_GIT_REV` | `unknown` | Git revision stamped into `BUILDINFO.txt` |

Example: build without sensors from a custom repo:

```bash
PIPA_REPO_URL=https://example.com/pipa/repo/ PIPA_INCLUDE_SENSORS=0 make plasma
```

The output ZIP file(s) will be placed in the `images/` directory. Each build archive currently contains:

- `silicium.img`: the Mu-Silicium boot image for Xiaomi Pad 6 / Pipa
- `endeavouros_esp.raw`: the EFI system partition image used by Mu-Silicium/UEFI
- `endeavouros_boot.raw`: a dedicated ext4 `/boot` image containing GRUB payloads, kernel, initramfs, and DTB
- `endeavouros_rootfs.raw`: the EndeavourOS root filesystem image mounted as `/`
- `vbmeta-disabled.img`: optional disabled vbmeta image for verified-boot layouts
- `flash.sh`: a helper script showing the expected fastboot flashing order
- `flash-multiboot.sh`: an interactive helper with simple menus for choosing the boot slot and entering only the rootfs partition name
- `BUILDINFO.txt`: build metadata (desktop, date, git revision, kernel version, repo URL)
- `SHA256SUMS`: checksums for all files in the archive

The builder uses a pacstrap-based rootfs flow inspired by [endeavouros-arm/plasma-image](https://github.com/endeavouros-arm/plasma-image), while the boot image artifact is sourced from the Mu-Silicium release used by [pocketblue](https://github.com/pocketblue/pocketblue).
The generated GRUB configuration uses stable filesystem labels so recovery edits are less fragile after reflashing, and now redirects from the ESP into a dedicated `boot` filesystem instead of loading the kernel directly from the rootfs.
The image builder installs the device packages from [thespider2/pipa-pkgs](https://thespider2.github.io/pipa-pkgs/repo/) by default; set `PIPA_REPO_URL` if you want to point it at a different published pacman repo.

## Flashing Instructions

1. Ensure your device bootloader is unlocked.
2. Extract the ZIP archive and `cd` into the extracted directory.
3. Verify checksums (optional but recommended):
   ```bash
   sha256sum -c SHA256SUMS
   ```
4. Run `./flash.sh` for a single-boot layout, or `./flash-multiboot.sh` for multiboot testing.
5. Reboot the device.

Default partition targets for `flash.sh`:

| Image | Partition |
|-------|-----------|
| `silicium.img` | `boot_ab` |
| `endeavouros_esp.raw` | `rawdump` |
| `endeavouros_boot.raw` | `cust` |
| `endeavouros_rootfs.raw` | `userdata` |

The exact flashing sequence follows the same Mu-Silicium UEFI model used by pocketblue more closely than before by restoring a dedicated `cust`/`boot` partition for the kernel, initramfs, GRUB configuration, and device tree.
If you need a different slot or rootfs target for multiboot testing, use `flash-multiboot.sh`; it offers menu-based selection for the boot slot and asks only for the rootfs partition name, while keeping the ESP and dedicated boot partitions on the default `rawdump` and `cust` targets.

## Acknowledgements

This port is heavily based on the excellent work done in the [pipa-fedora-builder-43](https://github.com/rr1111/pipa-fedora-builder-43/) and [pipa-fedora-support](https://github.com/timoxa0/pipa-fedora-support) repositories, as well as the EndeavourOS ARM [plasma-image](https://github.com/endeavouros-arm/plasma-image), [Mu-Silicium](https://github.com/onesaladleaf/Mu-Silicium), and [pocketblue](https://github.com/pocketblue/pocketblue) projects.
