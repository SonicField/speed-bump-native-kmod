#!/bin/bash
# Kernel build library for QEMU testing of speed-bump kernel module
# Provides functions to download, configure, and build a minimal Linux kernel

set -euo pipefail

# Configuration
KERNEL_VERSION="${KERNEL_VERSION:-6.6.72}"
KERNEL_MAJOR="${KERNEL_VERSION%%.*}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"

# Architecture detection
detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)
            KERNEL_ARCH=x86
            KERNEL_IMAGE=bzImage
            ;;
        aarch64)
            KERNEL_ARCH=arm64
            KERNEL_IMAGE=Image
            ;;
        *)
            echo "Error: Unsupported architecture: $arch" >&2
            return 1
            ;;
    esac
    ARCH_DIR="${CACHE_DIR}/kernel-${arch}"
    export KERNEL_ARCH KERNEL_IMAGE ARCH_DIR
}

# Check build dependencies
kernel_check_deps() {
    local missing=()

    echo "Checking kernel build dependencies..."

    # Check for compiler
    if ! command -v gcc &>/dev/null && ! command -v clang &>/dev/null; then
        missing+=("gcc or clang")
    fi

    # Check for required tools
    local tools=(make flex bison bc curl)
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    # Check for libelf development headers
    # Try multiple detection methods for different distros
    local has_libelf=false
    if pkg-config --exists libelf 2>/dev/null; then
        has_libelf=true
    elif [[ -f /usr/include/libelf.h ]] || [[ -f /usr/include/gelf.h ]]; then
        has_libelf=true
    elif [[ -f /usr/include/elfutils/libelf.h ]]; then
        has_libelf=true
    elif ldconfig -p 2>/dev/null | grep -q libelf; then
        has_libelf=true
    fi

    if [[ "$has_libelf" != "true" ]]; then
        missing+=("libelf-dev (or elfutils-libelf-devel)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing dependencies: ${missing[*]}" >&2
        echo "Install with:" >&2
        echo "  Debian/Ubuntu: sudo apt-get install build-essential flex bison bc libelf-dev curl" >&2
        echo "  RHEL/CentOS:   sudo dnf install gcc make flex bison bc elfutils-libelf-devel curl" >&2
        return 1
    fi

    echo "All dependencies satisfied."
    return 0
}

# Download kernel source
kernel_download() {
    detect_arch

    local kernel_url="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION}.tar.xz"
    local tarball="${CACHE_DIR}/linux-${KERNEL_VERSION}.tar.xz"
    local src_dir="${ARCH_DIR}/linux-${KERNEL_VERSION}"

    mkdir -p "${CACHE_DIR}" "${ARCH_DIR}"

    # Check if source already exists
    if [[ -d "${src_dir}" ]] && [[ -f "${src_dir}/Makefile" ]]; then
        echo "Kernel source already exists: ${src_dir}"
        export KERNEL_SRC="${src_dir}"
        return 0
    fi

    # Download tarball if needed
    if [[ ! -f "${tarball}" ]]; then
        echo "Downloading kernel ${KERNEL_VERSION}..."
        if ! curl -L --fail -o "${tarball}" "${kernel_url}"; then
            echo "Error: Failed to download kernel from ${kernel_url}" >&2
            rm -f "${tarball}"  # Clean up partial download
            return 1
        fi
        echo "Download complete: $(du -h "${tarball}" | cut -f1)"
    else
        echo "Using cached tarball: ${tarball}"
    fi

    # Verify tarball exists and is not empty
    if [[ ! -s "${tarball}" ]]; then
        echo "Error: Tarball is empty or missing: ${tarball}" >&2
        rm -f "${tarball}"
        return 1
    fi

    # Extract
    echo "Extracting kernel source..."
    if ! tar -xf "${tarball}" -C "${ARCH_DIR}"; then
        echo "Error: Failed to extract kernel source" >&2
        return 1
    fi

    # Verify extraction succeeded
    if [[ ! -f "${src_dir}/Makefile" ]]; then
        echo "Error: Kernel source extraction incomplete - Makefile not found" >&2
        return 1
    fi

    export KERNEL_SRC="${src_dir}"
    echo "Kernel source ready: ${KERNEL_SRC}"
}

# Configure kernel with minimal options for QEMU + uprobe support
kernel_configure() {
    detect_arch

    local src_dir="${ARCH_DIR}/linux-${KERNEL_VERSION}"

    if [[ ! -d "${src_dir}" ]]; then
        echo "Error: Kernel source not found. Run kernel_download first." >&2
        return 1
    fi

    cd "${src_dir}"

    echo "Creating minimal kernel configuration..."

    # Start with tinyconfig
    make ARCH="${KERNEL_ARCH}" tinyconfig

    # Apply required options
    local config_opts=(
        # 64-bit
        "CONFIG_64BIT=y"

        # Uprobe support
        "CONFIG_UPROBES=y"
        "CONFIG_UPROBE_EVENTS=y"

        # Module support
        "CONFIG_MODULES=y"
        "CONFIG_MODULE_UNLOAD=y"

        # Basic console
        "CONFIG_PRINTK=y"
        "CONFIG_TTY=y"
        "CONFIG_SERIAL_EARLYCON=y"
        "CONFIG_SERIAL_8250=y"
        "CONFIG_SERIAL_8250_CONSOLE=y"

        # ARM64 UART (PL011 for QEMU virt machine)
        "CONFIG_SERIAL_AMBA_PL011=y"
        "CONFIG_SERIAL_AMBA_PL011_CONSOLE=y"

        # ELF support
        "CONFIG_ELF_CORE=y"
        "CONFIG_BINFMT_ELF=y"
        "CONFIG_BINFMT_SCRIPT=y"

        # Filesystem support
        "CONFIG_DEVTMPFS=y"
        "CONFIG_DEVTMPFS_MOUNT=y"
        "CONFIG_TMPFS=y"
        "CONFIG_PROC_FS=y"
        "CONFIG_SYSFS=y"

        # 9P filesystem for host sharing
        "CONFIG_NET=y"
        "CONFIG_INET=y"
        "CONFIG_NET_9P=y"
        "CONFIG_NET_9P_VIRTIO=y"
        "CONFIG_9P_FS=y"

        # Virtio drivers
        "CONFIG_VIRTIO_MENU=y"
        "CONFIG_VIRTIO=y"
        "CONFIG_VIRTIO_PCI=y"
        "CONFIG_VIRTIO_PCI_LEGACY=y"
        "CONFIG_VIRTIO_CONSOLE=y"
        "CONFIG_HW_RANDOM_VIRTIO=y"

        # PCI support (needed for virtio-pci)
        "CONFIG_PCI=y"
        "CONFIG_PCI_HOST_GENERIC=y"

        # Block devices
        "CONFIG_BLOCK=y"
        "CONFIG_VIRTIO_BLK=y"

        # Initramfs support
        "CONFIG_BLK_DEV_INITRD=y"
        "CONFIG_RD_GZIP=y"

        # Required for modules
        "CONFIG_KMOD=y"
    )

    # Apply options to .config
    for opt in "${config_opts[@]}"; do
        local key="${opt%%=*}"
        local value="${opt#*=}"

        # Remove any existing line for this option
        sed -i "/^${key}=/d" .config 2>/dev/null || true
        sed -i "/^# ${key} is not set/d" .config 2>/dev/null || true

        # Add the option
        echo "${opt}" >> .config
    done

    # Resolve dependencies with olddefconfig
    make ARCH="${KERNEL_ARCH}" olddefconfig

    echo "Kernel configuration complete."
    echo "Verifying critical options..."

    # Verify critical options
    local critical_opts=("CONFIG_UPROBES" "CONFIG_MODULES" "CONFIG_BINFMT_ELF")
    for opt in "${critical_opts[@]}"; do
        if grep -q "^${opt}=y" .config; then
            echo "  ${opt}=y OK"
        else
            echo "  Warning: ${opt} not enabled" >&2
        fi
    done

    export KERNEL_SRC="${src_dir}"
}

# Build the kernel
kernel_build() {
    detect_arch

    local src_dir="${ARCH_DIR}/linux-${KERNEL_VERSION}"

    if [[ ! -d "${src_dir}" ]]; then
        echo "Error: Kernel source not found. Run kernel_download first." >&2
        return 1
    fi

    if [[ ! -f "${src_dir}/.config" ]]; then
        echo "Error: Kernel not configured. Run kernel_configure first." >&2
        return 1
    fi

    cd "${src_dir}"

    # Determine number of parallel jobs
    local jobs
    jobs=$(nproc 2>/dev/null || echo 4)

    echo "Building kernel with ${jobs} parallel jobs..."
    echo "This may take a while..."

    local start_time
    start_time=$(date +%s)

    make ARCH="${KERNEL_ARCH}" -j"${jobs}"

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Check for kernel image
    local image_path
    case "${KERNEL_ARCH}" in
        x86)
            image_path="${src_dir}/arch/x86/boot/bzImage"
            ;;
        arm64)
            image_path="${src_dir}/arch/arm64/boot/Image"
            ;;
    esac

    if [[ -f "${image_path}" ]]; then
        local size
        size=$(du -h "${image_path}" | cut -f1)
        echo "Kernel build complete in ${duration}s"
        echo "Kernel image: ${image_path} (${size})"

        # Create symlink in cache dir for easy access
        ln -sf "${image_path}" "${ARCH_DIR}/${KERNEL_IMAGE}"
        echo "Symlink created: ${ARCH_DIR}/${KERNEL_IMAGE}"

        export KERNEL_IMAGE_PATH="${image_path}"
        return 0
    else
        echo "Error: Kernel image not found at ${image_path}" >&2
        return 1
    fi
}

# Check if cached kernel exists
kernel_cached() {
    detect_arch

    local image_path="${ARCH_DIR}/${KERNEL_IMAGE}"
    local config_path="${ARCH_DIR}/linux-${KERNEL_VERSION}/.config"

    if [[ ! -f "${image_path}" ]]; then
        echo "No cached kernel found."
        return 1
    fi

    # Check if config is newer than image (needs rebuild)
    if [[ -f "${config_path}" ]] && [[ "${config_path}" -nt "${image_path}" ]]; then
        echo "Config newer than cached kernel - rebuild needed."
        return 1
    fi

    local size
    size=$(du -h "${image_path}" | cut -f1)
    echo "Using cached kernel: ${image_path} (${size})"
    export KERNEL_IMAGE_PATH="${image_path}"
    return 0
}

# Full build workflow
kernel_full_build() {
    echo "=== Kernel Build for QEMU Testing ==="
    echo "Kernel version: ${KERNEL_VERSION}"

    detect_arch
    echo "Architecture: ${KERNEL_ARCH} ($(uname -m))"
    echo "Cache directory: ${ARCH_DIR}"
    echo ""

    # Check if we have a cached build
    if kernel_cached; then
        echo "Cached kernel is up to date."
        return 0
    fi

    # Full build sequence
    kernel_check_deps
    kernel_download
    kernel_configure
    kernel_build

    echo ""
    echo "=== Kernel Build Complete ==="
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    kernel_full_build
fi
