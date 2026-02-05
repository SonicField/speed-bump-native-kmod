#!/bin/bash
# Test script for kernel build functions
# Exercises all functions in scripts/lib/kernel.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; return 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# Source the kernel library
source "${SCRIPT_DIR}/lib/kernel.sh"

echo "==========================================="
echo "Kernel Build Script Test"
echo "==========================================="
echo ""

# Test 1: Architecture detection
info "Testing architecture detection..."
if detect_arch; then
    pass "Architecture detected: ${KERNEL_ARCH} ($(uname -m))"
    echo "    KERNEL_IMAGE: ${KERNEL_IMAGE}"
    echo "    ARCH_DIR: ${ARCH_DIR}"
else
    fail "Architecture detection failed"
    exit 1
fi
echo ""

# Test 2: Dependency checking
info "Testing dependency checking..."
if kernel_check_deps; then
    pass "All build dependencies satisfied"
else
    fail "Missing build dependencies"
    echo "    Install missing packages and retry"
    exit 1
fi
echo ""

# Test 3: Check for cached kernel (before build)
info "Testing cache check..."
if kernel_cached; then
    pass "Cached kernel found - skipping build tests"
    echo ""
    echo "==========================================="
    echo "Tests complete - using cached kernel"
    echo "==========================================="
    echo "Kernel path: ${KERNEL_IMAGE_PATH}"
    echo ""
    echo "To force a rebuild, delete: ${ARCH_DIR}"
    exit 0
else
    info "No cached kernel - proceeding with build tests"
fi
echo ""

# Test 4: Kernel download
info "Testing kernel download..."
if kernel_download; then
    pass "Kernel source downloaded"
    echo "    Source: ${KERNEL_SRC}"
    if [[ -f "${KERNEL_SRC}/Makefile" ]]; then
        local_version=$(head -5 "${KERNEL_SRC}/Makefile" | grep "^VERSION" | cut -d= -f2 | tr -d ' ')
        local_patchlevel=$(head -5 "${KERNEL_SRC}/Makefile" | grep "^PATCHLEVEL" | cut -d= -f2 | tr -d ' ')
        echo "    Kernel version from source: ${local_version}.${local_patchlevel}.x"
    fi
else
    fail "Kernel download failed"
    exit 1
fi
echo ""

# Test 5: Kernel configuration
info "Testing kernel configuration..."
if kernel_configure; then
    pass "Kernel configured"
    echo "    Config file: ${KERNEL_SRC}/.config"

    # Show some enabled options
    echo "    Key options enabled:"
    for opt in CONFIG_UPROBES CONFIG_MODULES CONFIG_VIRTIO CONFIG_9P_FS; do
        if grep -q "^${opt}=y" "${KERNEL_SRC}/.config"; then
            echo "      ${opt}=y"
        else
            echo "      ${opt}=(not set)"
        fi
    done
else
    fail "Kernel configuration failed"
    exit 1
fi
echo ""

# Test 6: Kernel build (this takes a while)
info "Testing kernel build..."
echo "    This may take several minutes..."
echo ""
if kernel_build; then
    pass "Kernel built successfully"
    echo "    Image: ${KERNEL_IMAGE_PATH}"
    echo "    Size: $(du -h "${KERNEL_IMAGE_PATH}" | cut -f1)"
else
    fail "Kernel build failed"
    exit 1
fi
echo ""

# Test 7: Verify caching works
info "Testing cache verification..."
if kernel_cached; then
    pass "Cache check works correctly"
else
    fail "Cache check failed after build"
    exit 1
fi
echo ""

echo "==========================================="
echo "All tests passed!"
echo "==========================================="
echo ""
echo "Kernel ready for QEMU testing:"
echo "  Image: ${KERNEL_IMAGE_PATH}"
echo "  Arch: ${KERNEL_ARCH}"
echo ""
