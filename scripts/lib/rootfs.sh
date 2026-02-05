#!/bin/bash
# rootfs.sh - Minimal busybox-based root filesystem for QEMU testing
#
# Functions for building a minimal initramfs with busybox for kernel module testing.
# Supports: system busybox package, source build, or pre-built binary

set -euo pipefail

# Configuration
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.35.0}"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
ARCH="${ARCH:-x86_64}"

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache/rootfs-${ARCH}"
BUILD_DIR="${CACHE_DIR}/build"
ROOTFS_DIR="${CACHE_DIR}/rootfs"
BUSYBOX_SRC="${BUILD_DIR}/busybox-${BUSYBOX_VERSION}"
BUSYBOX_BIN=""  # Set by rootfs_get_busybox or rootfs_build_busybox

# Output
INITRAMFS_CPIO="${CACHE_DIR}/initramfs.cpio"
INITRAMFS_GZ="${CACHE_DIR}/initramfs.cpio.gz"

# Logging
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_ok() { echo "[OK] $*"; }
log_warn() { echo "[WARN] $*" >&2; }

# Check if cached rootfs exists and is valid
rootfs_cached() {
    local version_file="${CACHE_DIR}/.version"

    if [[ ! -f "${INITRAMFS_GZ}" ]]; then
        return 1
    fi

    if [[ ! -f "${version_file}" ]]; then
        return 1
    fi

    local cached_version
    cached_version=$(cat "${version_file}")
    if [[ "${cached_version}" != "${BUSYBOX_VERSION}" ]]; then
        log_info "Busybox version changed (${cached_version} -> ${BUSYBOX_VERSION}), rebuilding"
        return 1
    fi

    # Check if rootfs.sh is newer than initramfs
    if [[ "${BASH_SOURCE[0]}" -nt "${INITRAMFS_GZ}" ]]; then
        log_info "rootfs.sh updated, rebuilding"
        return 1
    fi

    return 0
}

# Verify build dependencies are available
rootfs_check_deps() {
    local missing=()
    local optional_missing=()

    # Required for all modes
    for cmd in cpio gzip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # Required for source build mode
    for cmd in gcc make tar bzip2; do
        if ! command -v "$cmd" &>/dev/null; then
            optional_missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        return 1
    fi

    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        log_warn "Missing build dependencies (source build unavailable): ${optional_missing[*]}"
    fi

    log_ok "All required dependencies present"
    return 0
}

# Find or obtain busybox binary
# Returns path to busybox binary via BUSYBOX_BIN variable
rootfs_get_busybox() {
    mkdir -p "${BUILD_DIR}"

    # Strategy 1: Check for existing built binary
    if [[ -f "${BUSYBOX_SRC}/busybox" ]]; then
        if file "${BUSYBOX_SRC}/busybox" | grep -q "statically linked"; then
            BUSYBOX_BIN="${BUSYBOX_SRC}/busybox"
            log_ok "Using previously built busybox: ${BUSYBOX_BIN}"
            return 0
        fi
    fi

    # Strategy 2: Check for busybox-static system package
    local system_busybox=""
    for path in /usr/bin/busybox /bin/busybox /usr/sbin/busybox; do
        if [[ -f "${path}" ]]; then
            if file "${path}" | grep -q "statically linked"; then
                system_busybox="${path}"
                break
            fi
        fi
    done

    if [[ -n "${system_busybox}" ]]; then
        BUSYBOX_BIN="${system_busybox}"
        # Update version from binary
        BUSYBOX_VERSION=$("${BUSYBOX_BIN}" 2>&1 | head -1 | sed -n 's/.*v\([0-9.]*\).*/\1/p' || echo "system")
        log_ok "Using system busybox: ${BUSYBOX_BIN} (version ${BUSYBOX_VERSION})"
        return 0
    fi

    # Strategy 3: Try to install via package manager (requires sudo)
    if command -v dnf &>/dev/null; then
        log_info "Attempting to install busybox via dnf..."
        if sudo dnf install -y busybox &>/dev/null; then
            for path in /usr/sbin/busybox /usr/bin/busybox /bin/busybox; do
                if [[ -f "${path}" ]] && file "${path}" | grep -q "statically linked"; then
                    BUSYBOX_BIN="${path}"
                    BUSYBOX_VERSION=$("${BUSYBOX_BIN}" 2>&1 | head -1 | sed -n 's/.*v\([0-9.]*\).*/\1/p' || echo "system")
                    log_ok "Installed and using system busybox: ${BUSYBOX_BIN}"
                    return 0
                fi
            done
        fi
    fi

    # Strategy 4: Build from source (if network available)
    log_info "No system busybox found, attempting source build..."
    if rootfs_download_busybox && rootfs_build_busybox; then
        return 0
    fi

    log_error "Could not obtain busybox binary"
    log_error "Options:"
    log_error "  1. Install busybox-static: sudo dnf install busybox"
    log_error "  2. Place a static busybox at: ${BUILD_DIR}/busybox"
    log_error "  3. Ensure network access for source download"
    return 1
}

# Download busybox source
rootfs_download_busybox() {
    mkdir -p "${BUILD_DIR}"

    local tarball="${BUILD_DIR}/busybox-${BUSYBOX_VERSION}.tar.bz2"

    if [[ -f "${tarball}" ]] && [[ -s "${tarball}" ]]; then
        log_info "Busybox tarball already exists: ${tarball}"
        return 0
    fi

    # Check network connectivity first
    if ! wget -q --spider "https://busybox.net" 2>/dev/null; then
        log_warn "No network access to busybox.net"
        return 1
    fi

    log_info "Downloading busybox ${BUSYBOX_VERSION}..."
    if wget -q -O "${tarball}.tmp" "${BUSYBOX_URL}" && [[ -s "${tarball}.tmp" ]]; then
        mv "${tarball}.tmp" "${tarball}"
        log_ok "Downloaded busybox to ${tarball}"
        return 0
    else
        rm -f "${tarball}.tmp"
        log_error "Download failed"
        return 1
    fi
}

# Build static busybox with required applets
rootfs_build_busybox() {
    local tarball="${BUILD_DIR}/busybox-${BUSYBOX_VERSION}.tar.bz2"

    if [[ ! -f "${tarball}" ]] || [[ ! -s "${tarball}" ]]; then
        log_error "Busybox tarball not found or empty. Run rootfs_download_busybox first."
        return 1
    fi

    # Check for required build tools
    for cmd in gcc make tar; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Missing build tool: $cmd"
            return 1
        fi
    done

    # Extract if needed
    if [[ ! -d "${BUSYBOX_SRC}" ]]; then
        log_info "Extracting busybox..."
        if ! tar -xjf "${tarball}" -C "${BUILD_DIR}"; then
            log_error "Failed to extract tarball"
            return 1
        fi
    fi

    cd "${BUSYBOX_SRC}"

    # Start with default config
    log_info "Configuring busybox..."
    make defconfig >/dev/null

    # Enable static build
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config

    log_info "Building static busybox (this may take a moment)..."
    if ! make -j"$(nproc)" >/dev/null 2>&1; then
        log_error "Busybox build failed"
        cd - >/dev/null
        return 1
    fi

    if [[ ! -f "busybox" ]]; then
        log_error "Busybox binary not created"
        cd - >/dev/null
        return 1
    fi

    # Verify static build
    if ! file busybox | grep -q "statically linked"; then
        log_error "Busybox is not statically linked"
        cd - >/dev/null
        return 1
    fi

    local size
    size=$(du -h busybox | cut -f1)
    log_ok "Built static busybox: ${size}"
    file busybox

    BUSYBOX_BIN="${BUSYBOX_SRC}/busybox"

    cd - >/dev/null
    return 0
}

# Create rootfs directory structure
rootfs_create_structure() {
    log_info "Creating rootfs directory structure..."

    # Get busybox if not already set
    if [[ -z "${BUSYBOX_BIN}" ]] || [[ ! -f "${BUSYBOX_BIN}" ]]; then
        rootfs_get_busybox || return 1
    fi

    rm -rf "${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}"

    # Create directory layout
    mkdir -p "${ROOTFS_DIR}"/{bin,sbin,etc/init.d,dev,proc,sys,tmp,mnt/host,lib,lib64,root}

    # Install busybox
    cp "${BUSYBOX_BIN}" "${ROOTFS_DIR}/bin/busybox"
    chmod 755 "${ROOTFS_DIR}/bin/busybox"

    # Get list of available applets from this busybox
    local available_applets
    available_applets=$("${BUSYBOX_BIN}" --list 2>/dev/null || echo "")

    # Create symlinks for required applets
    local applets=(
        # Shell
        sh ash
        # Init
        init
        # Mount
        mount umount
        # Module loading
        insmod rmmod lsmod modprobe
        # File operations
        cat echo ls mkdir rm cp mv ln chmod chown
        # Time
        sleep
        # Kernel messages
        dmesg
        # Text processing
        grep head tail sed awk
        # Test
        test "["
        # Additional useful applets
        pwd env true false
        poweroff reboot halt
        clear
    )

    for applet in "${applets[@]}"; do
        # Check if applet is available in this busybox
        if echo "${available_applets}" | grep -qw "${applet}" 2>/dev/null || [[ -z "${available_applets}" ]]; then
            ln -sf busybox "${ROOTFS_DIR}/bin/${applet}"
        fi
    done

    # Also create sbin symlinks for module commands
    for cmd in insmod rmmod lsmod modprobe; do
        ln -sf ../bin/busybox "${ROOTFS_DIR}/sbin/${cmd}"
    done

    log_ok "Created rootfs structure with busybox symlinks"
}

# Create init script
rootfs_create_init() {
    log_info "Creating init script..."

    cat > "${ROOTFS_DIR}/init" << 'INIT_EOF'
#!/bin/sh
# Minimal init for speed-bump kernel module testing

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# Enable kernel messages to console
echo 1 > /proc/sys/kernel/printk

echo "=================================="
echo "  Speed-Bump Test Environment"
echo "=================================="
echo ""

# Try to mount host directory via 9p
if mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/host 2>/dev/null; then
    echo "[OK] Host directory mounted at /mnt/host"

    # Run tests if available
    if [ -x /mnt/host/run-tests.sh ]; then
        echo "[INFO] Running tests from /mnt/host/run-tests.sh..."
        echo ""
        /mnt/host/run-tests.sh
        TEST_EXIT=$?
        echo ""
        echo "TEST_EXIT_CODE=${TEST_EXIT}"

        # If kernel param contains 'autopower', poweroff after tests
        if grep -q 'autopower' /proc/cmdline 2>/dev/null; then
            echo "[INFO] Auto-poweroff enabled, shutting down..."
            poweroff -f
        fi
    fi
else
    echo "[WARN] Could not mount host share (9p not available)"
fi

echo ""
echo "[INFO] Dropping to shell (type 'poweroff -f' to exit)"
exec /bin/sh
INIT_EOF

    chmod 755 "${ROOTFS_DIR}/init"

    log_ok "Created init script"
}

# Pack rootfs into cpio archive
rootfs_pack_initramfs() {
    log_info "Packing initramfs..."

    if [[ ! -d "${ROOTFS_DIR}" ]]; then
        log_error "Rootfs directory not found. Run rootfs_create_structure first."
        return 1
    fi

    cd "${ROOTFS_DIR}"

    # Create cpio archive
    find . -print0 | cpio --null -ov --format=newc > "${INITRAMFS_CPIO}" 2>/dev/null

    # Compress
    gzip -9 -c "${INITRAMFS_CPIO}" > "${INITRAMFS_GZ}"

    # Save version
    echo "${BUSYBOX_VERSION}" > "${CACHE_DIR}/.version"

    local size
    size=$(du -h "${INITRAMFS_GZ}" | cut -f1)
    log_ok "Created initramfs: ${INITRAMFS_GZ} (${size})"

    cd - >/dev/null

    # Show contents summary
    log_info "Initramfs contents:"
    cpio -t < "${INITRAMFS_CPIO}" 2>/dev/null | head -30
    echo "  ... ($(cpio -t < "${INITRAMFS_CPIO}" 2>/dev/null | wc -l) total entries)"
}

# Full build pipeline
rootfs_build_all() {
    log_info "Building minimal rootfs for QEMU testing..."

    if rootfs_cached; then
        log_ok "Using cached initramfs: ${INITRAMFS_GZ}"
        return 0
    fi

    rootfs_check_deps || return 1
    rootfs_get_busybox || return 1
    rootfs_create_structure || return 1
    rootfs_create_init || return 1
    rootfs_pack_initramfs || return 1

    log_ok "Rootfs build complete!"
    echo ""
    echo "Output: ${INITRAMFS_GZ}"
    echo ""
    echo "Quick test with QEMU:"
    echo "  qemu-system-x86_64 -kernel <kernel> -initrd ${INITRAMFS_GZ} \\"
    echo "    -append 'console=ttyS0' -nographic"
}

# Get path to initramfs
rootfs_get_initramfs() {
    echo "${INITRAMFS_GZ}"
}

# Clean build artifacts
rootfs_clean() {
    log_info "Cleaning rootfs build artifacts..."
    rm -rf "${CACHE_DIR}"
    log_ok "Cleaned"
}
