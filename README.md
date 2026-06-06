# EndeavourOS for Xiaomi Pad 6 (Pipa)

This project contains the build infrastructure and packages to port EndeavourOS to the Xiaomi Pad 6 (Pipa) device.

The current boot flow uses the upstream [Mu-Silicium](https://github.com/onesaladleaf/Mu-Silicium) Pipa boot image release together with a custom Pipa-enabled EndeavourOS root filesystem.

## Automated Builds via CircleCI

This repository is configured with a CircleCI pipeline ([config.yml](file:///Users/ayman/Documents/trae_projects/endavouros_pipa/.circleci/config.yml)) that builds EndeavourOS images on native ARM hardware.
The pipeline uses CircleCI's `arm.large` machine resource class so the kernel build runs natively instead of under x86 emulation.

When a build completes, the generated image ZIP files are available as CircleCI job artifacts.

## Local Build Instructions

If you wish to build the images locally, you can do so using Docker on an ARM64 host, or an x86_64 host with QEMU binfmt configured. To use CircleCI with your GitLab repository, connect your GitLab account in CircleCI and create a project for this repository; CircleCI will automatically detect [config.yml](file:///Users/ayman/Documents/trae_projects/endavouros_pipa/.circleci/config.yml).

1. Build the Builder container:
   ```bash
   docker build pipa-endeavouros-builder -t 'pipa-endeavouros-builder'
   ```
   *Note: This step prepares the image builder. Device packages are fetched from the published `pipa-alarm` pacman repository by default instead of being built locally.*

2. Build the Desktop Environment image (e.g. Plasma):
   ```bash
   mkdir -p images
   docker run --privileged -v "$(pwd)/images:/build/images" -v "/dev:/dev" pipa-endeavouros-builder plasma
   ```

3. (Optional) Build the Gnome image:
   ```bash
   docker run --privileged -v "$(pwd)/images:/build/images" -v "/dev:/dev" pipa-endeavouros-builder gnome
   ```

The output ZIP file(s) will be placed in the `images/` directory. Each build archive currently contains:

- `silicium.img`: the Mu-Silicium boot image for Xiaomi Pad 6 / Pipa
- `endeavouros_esp.raw`: the EFI system partition image used by Mu-Silicium/UEFI
- `endeavouros_boot.raw`: a dedicated ext4 `/boot` image containing GRUB payloads, kernel, initramfs, and DTB
- `endeavouros_rootfs.raw`: the EndeavourOS root filesystem image mounted as `/`
- `flash.sh`: a helper script showing the expected fastboot flashing order
- `flash-multiboot.sh`: an interactive helper with simple menus for choosing the boot slot and entering only the rootfs partition name

The builder uses a pacstrap-based rootfs flow inspired by [endeavouros-arm/plasma-image](https://github.com/endeavouros-arm/plasma-image), while the boot image artifact is sourced from the Mu-Silicium release used by [pocketblue](https://github.com/pocketblue/pocketblue).
The generated GRUB configuration uses stable filesystem labels so recovery edits are less fragile after reflashing, and now redirects from the ESP into a dedicated `boot` filesystem instead of loading the kernel directly from the rootfs.
The image builder installs the device packages from [maakiopus/pipa-alarm](https://maakiopus.github.io/pipa-alarm/repo/) by default; set `PIPA_REPO_URL` if you want to point it at a different published pacman repo.

## Flashing Instructions

1. Ensure your device bootloader is unlocked.
2. Flash the generated `silicium.img` to the device boot slot(s).
3. Flash `endeavouros_esp.raw` to the EFI partition used by your current Pipa flashing layout.
4. Flash `endeavouros_boot.raw` to the `cust` partition.
5. Flash `endeavouros_rootfs.raw` to the `linux` partition.
6. Erase `dtbo_ab` if your current setup requires it before first boot.
7. Reboot the device.

The exact flashing sequence follows the same Mu-Silicium UEFI model used by pocketblue more closely than before by restoring a dedicated `cust`/`boot` partition for the kernel, initramfs, GRUB configuration, and device tree.
If you need a different slot or rootfs target for multiboot testing, use `flash-multiboot.sh`; it offers menu-based selection for the boot slot and asks only for the rootfs partition name, while keeping the ESP and dedicated boot partitions on the default `rawdump` and `cust` targets.

## Acknowledgements

This port is heavily based on the excellent work done in the [pipa-fedora-builder-43](https://github.com/rr1111/pipa-fedora-builder-43/) and [pipa-fedora-support](https://github.com/timoxa0/pipa-fedora-support) repositories, as well as the EndeavourOS ARM [plasma-image](https://github.com/endeavouros-arm/plasma-image), [Mu-Silicium](https://github.com/onesaladleaf/Mu-Silicium), and [pocketblue](https://github.com/pocketblue/pocketblue) projects.
