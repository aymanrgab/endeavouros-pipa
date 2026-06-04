FROM menci/archlinuxarm:base-devel

# Initialize keyring and install dependencies for building and image creation.
# Docker CI lacks the kernel features pacman uses for sandboxing, so the option
# must live inside the [options] section or pacman will ignore it.
RUN pacman-key --init && \
    pacman-key --populate archlinuxarm && \
    sed -i '/^CheckSpace$/s/^/#/' /etc/pacman.conf && \
    sed -i '/^DisableSandbox$/d' /etc/pacman.conf && \
    sed -i '/^\[options\]$/a DisableSandbox' /etc/pacman.conf && \
    pacman -Sy --noconfirm archlinuxarm-keyring && \
    pacman -Su --noconfirm && \
    pacman -S --noconfirm \
    git sudo wget rsync \
    arch-install-scripts e2fsprogs dosfstools zip unzip \
    bc bison flex cpio kmod python tar xz meson ninja cmake \
    glib2 libgudev polkit libqmi protobuf-c dracut android-tools

# Set up a non-root user for makepkg
RUN useradd -m -G wheel builder && \
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /build

# Copy the entire builder directory into the container
COPY . /build/

# Make scripts executable
RUN chmod +x *.sh && chown -R builder:builder /build

# Build packages during container build to cache them
RUN sudo -u builder bash ./build-packages.sh

CMD []
ENTRYPOINT ["/bin/bash", "./build-image.sh"]
