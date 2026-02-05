#!/bin/bash
# test-rootfs-build.sh - Test the rootfs build functions
#
# This script exercises all the functions in rootfs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the library
source "${SCRIPT_DIR}/lib/rootfs.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

passed=0
failed=0

test_pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    passed=$((passed + 1))
}

test_fail() {
    echo -e "${RED}FAIL${NC}: $1"
    failed=$((failed + 1))
}

test_skip() {
    echo -e "${YELLOW}SKIP${NC}: $1"
}

echo "=============================================="
echo "  Rootfs Build Test Suite"
echo "=============================================="
echo ""

# Test 1: Check dependencies
echo "Test 1: Checking build dependencies..."
if rootfs_check_deps; then
    test_pass "Dependencies check"
else
    test_fail "Dependencies check - missing tools"
    echo "Cannot continue without dependencies"
    exit 1
fi
echo ""

# Test 2: Get busybox
echo "Test 2: Getting busybox binary..."
if rootfs_get_busybox; then
    test_pass "Got busybox binary"

    if [[ -n "${BUSYBOX_BIN}" ]] && [[ -f "${BUSYBOX_BIN}" ]]; then
        SIZE=$(du -h "${BUSYBOX_BIN}" | cut -f1)
        echo "  - Binary: ${BUSYBOX_BIN}"
        echo "  - Size: ${SIZE}"
        echo "  - File type: $(file "${BUSYBOX_BIN}" | cut -d: -f2)"

        if file "${BUSYBOX_BIN}" | grep -q "statically linked"; then
            test_pass "Busybox is statically linked"
        else
            test_fail "Busybox is NOT statically linked"
        fi
    else
        test_fail "BUSYBOX_BIN not set correctly"
    fi
else
    test_fail "Could not get busybox"
    exit 1
fi
echo ""

# Test 3: Create structure
echo "Test 3: Creating rootfs structure..."
if rootfs_create_structure; then
    test_pass "Rootfs structure created"

    # Verify key directories exist
    for dir in bin sbin etc dev proc sys tmp mnt/host; do
        if [[ -d "${ROOTFS_DIR}/${dir}" ]]; then
            test_pass "Directory exists: /${dir}"
        else
            test_fail "Directory missing: /${dir}"
        fi
    done

    # Verify busybox and key symlinks
    if [[ -f "${ROOTFS_DIR}/bin/busybox" ]]; then
        test_pass "Busybox installed"
    else
        test_fail "Busybox not installed"
    fi

    for applet in sh insmod lsmod modprobe dmesg; do
        if [[ -L "${ROOTFS_DIR}/bin/${applet}" ]]; then
            test_pass "Symlink exists: /bin/${applet}"
        else
            test_fail "Symlink missing: /bin/${applet}"
        fi
    done
else
    test_fail "Rootfs structure creation"
    exit 1
fi
echo ""

# Test 4: Create init script
echo "Test 4: Creating init script..."
if rootfs_create_init; then
    test_pass "Init script created"

    if [[ -f "${ROOTFS_DIR}/init" ]]; then
        if [[ -x "${ROOTFS_DIR}/init" ]]; then
            test_pass "Init is executable"
        else
            test_fail "Init is not executable"
        fi

        # Check for key content
        if grep -q "mount -t 9p" "${ROOTFS_DIR}/init"; then
            test_pass "Init contains 9p mount"
        else
            test_fail "Init missing 9p mount"
        fi

        if grep -q "/mnt/host" "${ROOTFS_DIR}/init"; then
            test_pass "Init references /mnt/host"
        else
            test_fail "Init missing /mnt/host reference"
        fi
    else
        test_fail "Init script file not found"
    fi
else
    test_fail "Init script creation"
fi
echo ""

# Test 5: Pack initramfs
echo "Test 5: Packing initramfs..."
if rootfs_pack_initramfs; then
    test_pass "Initramfs packed"

    INITRAMFS=$(rootfs_get_initramfs)
    if [[ -f "${INITRAMFS}" ]]; then
        SIZE=$(du -h "${INITRAMFS}" | cut -f1)
        echo "  - Initramfs: ${INITRAMFS}"
        echo "  - Size: ${SIZE}"
        test_pass "Initramfs file exists"

        # Verify contents
        ENTRIES=$(zcat "${INITRAMFS}" | cpio -t 2>/dev/null | wc -l)
        echo "  - Entries: ${ENTRIES}"

        if zcat "${INITRAMFS}" | cpio -t 2>/dev/null | grep -q "^init$"; then
            test_pass "Initramfs contains /init"
        else
            test_fail "Initramfs missing /init"
        fi

        if zcat "${INITRAMFS}" | cpio -t 2>/dev/null | grep -q "bin/busybox"; then
            test_pass "Initramfs contains /bin/busybox"
        else
            test_fail "Initramfs missing /bin/busybox"
        fi

        if zcat "${INITRAMFS}" | cpio -t 2>/dev/null | grep -q "mnt/host"; then
            test_pass "Initramfs contains /mnt/host"
        else
            test_fail "Initramfs missing /mnt/host"
        fi
    else
        test_fail "Initramfs file not found"
    fi
else
    test_fail "Initramfs packing"
fi
echo ""

# Test 6: Cache detection
echo "Test 6: Testing cache detection..."
if rootfs_cached; then
    test_pass "Cache detection works (cached exists)"
else
    test_fail "Cache detection (should be cached after build)"
fi
echo ""

# Summary
echo "=============================================="
echo "  Test Summary"
echo "=============================================="
echo -e "Passed: ${GREEN}${passed}${NC}"
echo -e "Failed: ${RED}${failed}${NC}"
echo ""

if [[ ${failed} -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    echo ""
    echo "The initramfs is ready at:"
    echo "  $(rootfs_get_initramfs)"
    echo ""
    echo "To test with QEMU (requires a kernel):"
    echo "  qemu-system-x86_64 -kernel <vmlinuz> \\"
    echo "    -initrd $(rootfs_get_initramfs) \\"
    echo "    -append 'console=ttyS0' -nographic"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
