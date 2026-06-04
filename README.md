# EndeavourOS for Xiaomi Pad 6 (Pipa)

This project contains the build infrastructure and packages to port EndeavourOS to the Xiaomi Pad 6 (Pipa) device.

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
   *Note: This step builds all the device-specific packages, including the custom Linux kernel, which may take some time.*

2. Build the Desktop Environment image (e.g. Plasma):
   ```bash
   mkdir -p images
   docker run --privileged -v "$(pwd)/images:/build/images" -v "/dev:/dev" pipa-endeavouros-builder plasma
   ```

3. (Optional) Build the Gnome image:
   ```bash
   docker run --privileged -v "$(pwd)/images:/build/images" -v "/dev:/dev" pipa-endeavouros-builder gnome
   ```

The output ZIP file(s) containing `root.img` and `boot.img` will be placed in the `images/` directory.

## Flashing Instructions

1. Ensure your device bootloader is unlocked.
2. Flash the generated `boot.img` to your device's boot partition.
3. Flash the generated `root.img` to your device's userdata/system partition (depending on your partitioning setup).
4. Reboot the device.

## Acknowledgements

This port is heavily based on the excellent work done in the [pipa-fedora-builder-43](https://github.com/rr1111/pipa-fedora-builder-43/) and [pipa-fedora-support](https://github.com/timoxa0/pipa-fedora-support) repositories.
