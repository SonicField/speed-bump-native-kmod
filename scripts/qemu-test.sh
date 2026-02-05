#!/bin/bash
# qemu-test.sh - Main entry point for QEMU-based kernel module testing
#
# Usage:
#   ./scripts/qemu-test.sh              # Run tests with native architecture
#   ./scripts/qemu-test.sh arm64        # Run tests for ARM64
#   ./scripts/qemu-test.sh x86_64       # Run tests for x86_64
#   ./scripts/qemu-test.sh --clean      # Remove cache and rebuild everything
#   ./scripts/qemu-test.sh --help       # Show this help
#
# This script provides a "one script does everything" experience for running
# speed-bump kernel module integration tests in a QEMU VM.

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_DIR="${SCRIPT_DIR}/cache"

# Libraries
LIB_DIR="${SCRIPT_DIR}/lib"

# Test configuration
QEMU_TIMEOUT="${QEMU_TIMEOUT:-300}"  # 5 minutes default for full test run

# State
TEMP_DIR=""
TEST_EXIT_CODE=0

# =============================================================================
# Logging
# =============================================================================

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_ok() { echo "[OK] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_step() { echo ""; echo "=== $* ==="; }

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat << EOF
Usage: $(basename "$0") [ARCH] [OPTIONS]

Run speed-bump kernel module integration tests in a QEMU VM.

Arguments:
  ARCH              Target architecture: x86_64, arm64 (default: native)

Options:
  --clean           Remove cached builds and rebuild everything
  --help, -h        Show this help message

Examples:
  $(basename "$0")              # Run tests with native architecture
  $(basename "$0") arm64        # Run tests for ARM64
  $(basename "$0") --clean      # Clean build and run tests

Environment Variables:
  KERNEL_VERSION    Kernel version to build (default: 6.6.72)
  QEMU_TIMEOUT      Timeout for VM execution in seconds (default: 300)
EOF
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    local exit_code=$?
    log_info "Cleaning up..."

    # Remove temporary directory
    if [[ -n "${TEMP_DIR}" ]] && [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi

    exit "${exit_code}"
}

trap cleanup EXIT INT TERM

# =============================================================================
# Dependency Checking
# =============================================================================

check_all_deps() {
    log_step "Checking Dependencies"

    local missing_critical=false

    # Source libraries to access their check functions
    # shellcheck source=lib/kernel.sh
    source "${LIB_DIR}/kernel.sh"
    # shellcheck source=lib/rootfs.sh
    source "${LIB_DIR}/rootfs.sh"
    # shellcheck source=lib/qemu.sh
    source "${LIB_DIR}/qemu.sh"

    # Check kernel build dependencies
    log_info "Checking kernel build dependencies..."
    if ! kernel_check_deps; then
        log_error "Kernel build dependencies missing"
        missing_critical=true
    fi

    # Check rootfs dependencies
    log_info "Checking rootfs build dependencies..."
    if ! rootfs_check_deps; then
        log_error "Rootfs build dependencies missing"
        missing_critical=true
    fi

    # Check QEMU availability
    log_info "Checking QEMU availability..."
    if ! qemu_check_deps; then
        log_error "QEMU not available"
        missing_critical=true
    fi

    if [[ "${missing_critical}" == "true" ]]; then
        log_error "Critical dependencies missing. Cannot continue."
        return 1
    fi

    log_ok "All dependencies satisfied"
    return 0
}

# =============================================================================
# Build Functions
# =============================================================================

build_kernel() {
    log_step "Building Kernel"

    # Source kernel library (if not already sourced)
    # shellcheck source=lib/kernel.sh
    source "${LIB_DIR}/kernel.sh"

    # Run full build (will use cache if available)
    if ! kernel_full_build; then
        log_error "Kernel build failed"
        return 1
    fi

    log_ok "Kernel ready: ${KERNEL_IMAGE_PATH:-}"
    return 0
}

build_rootfs() {
    log_step "Building Root Filesystem"

    # Source rootfs library
    # shellcheck source=lib/rootfs.sh
    source "${LIB_DIR}/rootfs.sh"

    # Set architecture from kernel detection
    if [[ -n "${KERNEL_ARCH:-}" ]]; then
        case "${KERNEL_ARCH}" in
            x86)  export ARCH="x86_64" ;;
            arm64) export ARCH="aarch64" ;;
        esac
    fi

    # Run full build (will use cache if available)
    if ! rootfs_build_all; then
        log_error "Rootfs build failed"
        return 1
    fi

    INITRAMFS_PATH=$(rootfs_get_initramfs)
    log_ok "Rootfs ready: ${INITRAMFS_PATH}"
    return 0
}

# =============================================================================
# Test Harness
# =============================================================================

prepare_test_harness() {
    log_step "Preparing Test Harness"

    # Create temporary directory for 9p share
    TEMP_DIR=$(mktemp -d /tmp/qemu-test-harness.XXXXXX)
    log_info "Test harness directory: ${TEMP_DIR}"

    # Copy kernel module source
    log_info "Copying kernel module source..."
    cp -r "${PROJECT_ROOT}/src" "${TEMP_DIR}/"
    cp -r "${PROJECT_ROOT}/tests" "${TEMP_DIR}/"
    cp "${PROJECT_ROOT}/Makefile" "${TEMP_DIR}/" 2>/dev/null || true
    cp "${PROJECT_ROOT}/Kbuild" "${TEMP_DIR}/" 2>/dev/null || true

    # Create run-tests.sh script for VM to execute
    cat > "${TEMP_DIR}/run-tests.sh" << 'HARNESS_EOF'
#!/bin/sh
# Auto-generated test harness for QEMU VM
# This script runs inside the VM

set -e

echo "========================================"
echo "  Speed-Bump Integration Test Harness"
echo "========================================"
echo ""

cd /mnt/host

# Build the kernel module
echo "[HARNESS] Building kernel module..."
if [ -f Makefile ]; then
    make modules 2>&1 || {
        echo "[HARNESS] ERROR: Module build failed"
        echo "TEST_EXIT_CODE=1"
        exit 1
    }
elif [ -f src/Kbuild ]; then
    # Build directly with kbuild
    make -C /lib/modules/$(uname -r)/build M=/mnt/host/src modules 2>&1 || {
        echo "[HARNESS] ERROR: Module build failed"
        echo "TEST_EXIT_CODE=1"
        exit 1
    }
fi

# Check if module was built
MODULE_PATH=""
if [ -f src/speed_bump.ko ]; then
    MODULE_PATH="src/speed_bump.ko"
elif [ -f speed_bump.ko ]; then
    MODULE_PATH="speed_bump.ko"
fi

if [ -z "${MODULE_PATH}" ]; then
    echo "[HARNESS] ERROR: speed_bump.ko not found after build"
    echo "TEST_EXIT_CODE=1"
    exit 1
fi

echo "[HARNESS] Module built: ${MODULE_PATH}"

# Load the kernel module
echo "[HARNESS] Loading kernel module..."
insmod "${MODULE_PATH}" 2>&1 || {
    echo "[HARNESS] ERROR: Failed to load module"
    dmesg | tail -20
    echo "TEST_EXIT_CODE=1"
    exit 1
}

echo "[HARNESS] Module loaded successfully"

# Run integration tests
echo ""
echo "[HARNESS] Running integration tests..."
echo ""

EXIT_CODE=0
if [ -x tests/integration_test.sh ]; then
    # Set MODULE_PATH for integration test
    export MODULE_PATH="${MODULE_PATH}"
    ./tests/integration_test.sh || EXIT_CODE=$?
else
    echo "[HARNESS] WARNING: tests/integration_test.sh not found or not executable"
    echo "[HARNESS] Performing basic module verification..."

    # Basic verification
    if [ -d /sys/kernel/speed_bump ]; then
        echo "[HARNESS] sysfs interface present: /sys/kernel/speed_bump"
        ls -la /sys/kernel/speed_bump/
        EXIT_CODE=0
    else
        echo "[HARNESS] ERROR: sysfs interface not found"
        EXIT_CODE=1
    fi
fi

# Unload the module
echo ""
echo "[HARNESS] Unloading kernel module..."
rmmod speed_bump 2>&1 || {
    echo "[HARNESS] WARNING: Failed to unload module"
}

echo ""
echo "========================================"
if [ ${EXIT_CODE} -eq 0 ]; then
    echo "  TESTS PASSED"
else
    echo "  TESTS FAILED"
fi
echo "========================================"

echo "TEST_EXIT_CODE=${EXIT_CODE}"
HARNESS_EOF

    chmod +x "${TEMP_DIR}/run-tests.sh"

    log_ok "Test harness prepared"
    return 0
}

# =============================================================================
# Run Tests
# =============================================================================

run_tests() {
    log_step "Running Tests in QEMU VM"

    # Source QEMU library
    # shellcheck source=lib/qemu.sh
    source "${LIB_DIR}/qemu.sh"

    # Get paths
    local kernel_image="${KERNEL_IMAGE_PATH:-}"
    local initramfs="${INITRAMFS_PATH:-}"

    if [[ -z "${kernel_image}" ]] || [[ ! -f "${kernel_image}" ]]; then
        log_error "Kernel image not found"
        return 1
    fi

    if [[ -z "${initramfs}" ]] || [[ ! -f "${initramfs}" ]]; then
        log_error "Initramfs not found"
        return 1
    fi

    log_info "Kernel: ${kernel_image}"
    log_info "Initramfs: ${initramfs}"
    log_info "Test directory: ${TEMP_DIR}"
    log_info "Timeout: ${QEMU_TIMEOUT}s"

    echo ""

    # Launch VM with test harness
    if ! qemu_launch "${kernel_image}" "${initramfs}" "${TEMP_DIR}" "autopower"; then
        log_error "Failed to launch QEMU"
        return 1
    fi

    # Wait for completion
    if ! qemu_wait "${QEMU_TIMEOUT}"; then
        log_error "QEMU timed out or failed"
        qemu_shutdown
        return 1
    fi

    # Get and display output
    local output
    output=$(qemu_get_output)

    echo ""
    log_step "VM Output"
    echo "${output}"
    echo ""

    # Parse exit code
    if echo "${output}" | grep -q "TEST_EXIT_CODE="; then
        TEST_EXIT_CODE=$(echo "${output}" | grep "TEST_EXIT_CODE=" | tail -1 | sed 's/.*TEST_EXIT_CODE=//' | tr -d '[:space:]')
    else
        log_warn "Could not parse exit code from VM output"
        TEST_EXIT_CODE=1
    fi

    # Cleanup QEMU
    qemu_shutdown

    return 0
}

# =============================================================================
# Report Results
# =============================================================================

report_results() {
    log_step "Test Results"

    if [[ "${TEST_EXIT_CODE}" -eq 0 ]]; then
        echo ""
        echo "========================================"
        echo "  ALL TESTS PASSED"
        echo "========================================"
        echo ""
        log_ok "Integration tests completed successfully"
        return 0
    else
        echo ""
        echo "========================================"
        echo "  TESTS FAILED (exit code: ${TEST_EXIT_CODE})"
        echo "========================================"
        echo ""
        log_error "Some tests failed"
        return 1
    fi
}

# =============================================================================
# Clean Cache
# =============================================================================

clean_cache() {
    log_step "Cleaning Cache"

    if [[ -d "${CACHE_DIR}" ]]; then
        log_info "Removing ${CACHE_DIR}..."
        rm -rf "${CACHE_DIR}"
        log_ok "Cache cleaned"
    else
        log_info "No cache directory to clean"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    local target_arch=""
    local do_clean=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --clean)
                do_clean=true
                shift
                ;;
            x86_64|x86)
                target_arch="x86_64"
                shift
                ;;
            arm64|aarch64)
                target_arch="aarch64"
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo ""
    echo "=========================================="
    echo "  Speed-Bump QEMU Integration Tests"
    echo "=========================================="
    echo ""

    log_info "Project root: ${PROJECT_ROOT}"
    log_info "Script directory: ${SCRIPT_DIR}"

    # Handle architecture selection
    if [[ -n "${target_arch}" ]]; then
        log_info "Target architecture: ${target_arch}"
        # Check if cross-compilation is needed
        local native_arch
        native_arch=$(uname -m)
        if [[ "${target_arch}" != "${native_arch}" ]]; then
            log_warn "Cross-compilation requested: ${native_arch} -> ${target_arch}"
            log_error "Cross-compilation is not yet implemented"
            exit 1
        fi
    else
        log_info "Using native architecture: $(uname -m)"
    fi

    # Clean if requested
    if [[ "${do_clean}" == "true" ]]; then
        clean_cache
    fi

    # Check dependencies
    if ! check_all_deps; then
        log_error "Dependency check failed"
        exit 1
    fi

    # Build kernel
    if ! build_kernel; then
        log_error "Kernel build failed"
        exit 1
    fi

    # Build rootfs
    if ! build_rootfs; then
        log_error "Rootfs build failed"
        exit 1
    fi

    # Prepare test harness
    if ! prepare_test_harness; then
        log_error "Test harness preparation failed"
        exit 1
    fi

    # Run tests
    if ! run_tests; then
        log_error "Test execution failed"
        exit 1
    fi

    # Report results
    report_results
    exit "${TEST_EXIT_CODE}"
}

# Run main
main "$@"
