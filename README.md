# EndeavourOS for Xiaomi Pad 6 (Pipa)

This project contains the build infrastructure and packages to port EndeavourOS to the Xiaomi Pad 6 (Pipa) device.

## Automated Builds via GitLab CI/CD

This repository is configured with a GitLab CI/CD pipeline (`.gitlab-ci.yml`) that automatically builds EndeavourOS images.
The build process runs on GitLab's SaaS ARM64 runners (`saas-linux-medium-arm64`) to quickly cross-compile the kernel and package the rootfs.

When a build completes on the default branch, the output images are available as job artifacts and a GitLab Release is automatically created.

## Local Build Instructions

If you wish to build the images locally, you can do so using Docker on an ARM64 host, or an x86_64 host with QEMU binfmt configured.

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
