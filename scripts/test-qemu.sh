#!/bin/bash
# test-qemu.sh - Test QEMU VM launch and control
#
# This script tests the qemu.sh library by:
# 1. Building kernel and rootfs (using cache if available)
# 2. Launching a VM
# 3. Running a simple command (uname -a)
# 4. Shutting down the VM
# 5. Reporting pass/fail

set -euo pipefail

# Save the test script directory before sourcing libraries (they overwrite SCRIPT_DIR)
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; return 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; }

echo "==========================================="
echo "QEMU VM Test"
echo "==========================================="
echo ""

# Source libraries
source "${TEST_SCRIPT_DIR}/lib/kernel.sh"
source "${TEST_SCRIPT_DIR}/lib/rootfs.sh"
source "${TEST_SCRIPT_DIR}/lib/qemu.sh"

# Test 1: Check QEMU dependencies
info "Test 1: Checking QEMU availability..."
if qemu_check_deps; then
    pass "QEMU is available"
else
    skip "QEMU not installed - cannot run VM tests"
    echo ""
    echo "The qemu.sh library syntax is valid, but QEMU is not available."
    echo "To install QEMU:"
    echo "  Debian/Ubuntu: sudo apt-get install qemu-system-x86"
    echo "  RHEL/CentOS:   sudo dnf install qemu-system-x86"
    echo ""
    echo "Performing syntax validation only..."
    echo ""

    # Validate bash syntax
    if bash -n "${TEST_SCRIPT_DIR}/lib/qemu.sh"; then
        pass "qemu.sh passes bash syntax check"
    else
        fail "qemu.sh has syntax errors"
        exit 1
    fi

    # List functions
    info "Functions defined in qemu.sh:"
    grep "^qemu_" "${TEST_SCRIPT_DIR}/lib/qemu.sh" | grep "()" | sed 's/().*//' | while read -r func; do
        echo "  - ${func}"
    done

    echo ""
    echo "==========================================="
    echo "Syntax tests passed (QEMU not available)"
    echo "==========================================="
    exit 0
fi
echo ""

# Test 2: Architecture detection
info "Test 2: Architecture detection..."
ARCH=$(qemu_get_arch)
pass "Architecture: ${ARCH}"
echo ""

# Test 3: Build/cache kernel
info "Test 3: Preparing kernel..."
detect_arch
if kernel_cached; then
    pass "Using cached kernel: ${KERNEL_IMAGE_PATH}"
else
    info "Building kernel (this may take a while)..."
    if kernel_full_build; then
        pass "Kernel built successfully"
    else
        fail "Kernel build failed"
        exit 1
    fi
fi
KERNEL_PATH="${KERNEL_IMAGE_PATH}"
echo ""

# Test 4: Build/cache rootfs
info "Test 4: Preparing rootfs..."
if rootfs_cached; then
    pass "Using cached rootfs"
else
    info "Building rootfs..."
    if rootfs_build_all; then
        pass "Rootfs built successfully"
    else
        fail "Rootfs build failed"
        exit 1
    fi
fi
INITRAMFS_PATH=$(rootfs_get_initramfs)
pass "Initramfs: ${INITRAMFS_PATH}"
echo ""

# Test 5: Run simple command in VM
info "Test 5: Running 'uname -a' in VM..."
echo ""

OUTPUT=$(qemu_run_command "${KERNEL_PATH}" "${INITRAMFS_PATH}" "uname -a" 30) || {
    echo "${OUTPUT}"
    fail "Command execution failed"
    exit 1
}

echo "--- VM Output ---"
echo "${OUTPUT}"
echo "--- End VM Output ---"
echo ""

# Check if uname output is present
if echo "${OUTPUT}" | grep -q "Linux"; then
    pass "VM successfully executed 'uname -a'"
else
    fail "Did not find expected output from 'uname -a'"
    exit 1
fi
echo ""

# Test 6: Verify exit code parsing
info "Test 6: Testing exit code parsing..."
OUTPUT=$(qemu_run_command "${KERNEL_PATH}" "${INITRAMFS_PATH}" "true" 30) && {
    pass "Exit code 0 correctly returned for 'true'"
} || {
    fail "Exit code should be 0 for 'true'"
}

# Test with failing command
if qemu_run_command "${KERNEL_PATH}" "${INITRAMFS_PATH}" "false" 30 >/dev/null 2>&1; then
    fail "Exit code should be non-zero for 'false'"
else
    pass "Exit code correctly non-zero for 'false'"
fi
echo ""

echo "==========================================="
echo "All QEMU tests passed!"
echo "==========================================="
echo ""
echo "The QEMU orchestration layer is working correctly."
echo "  Kernel: ${KERNEL_PATH}"
echo "  Initramfs: ${INITRAMFS_PATH}"
echo ""
