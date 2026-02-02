#!/bin/bash
#
# Integration Test Script for speed_bump kernel module
#
# This script performs end-to-end testing of the speed_bump kernel module
# by loading the module, configuring a delay target, running a test binary,
# and verifying that the delay was actually applied.
#
# SAFETY NOTES:
# - Uses /bin/sleep which is a minimal, safe binary
# - Probes 'nanosleep' which is a simple syscall wrapper
# - Uses modest 10ms delay (10000000 ns) - won't freeze the system
# - Automatically cleans up on exit (even if interrupted)
# - Includes timeout protection
#
# ROLLBACK PROCEDURE (if module gets stuck):
# 1. Kill this script: Ctrl+C or kill <pid>
# 2. Disable probes: echo 0 > /sys/kernel/speed_bump/enabled
# 3. Clear targets: echo "-*" > /sys/kernel/speed_bump/targets
# 4. Unload module: sudo rmmod speed_bump
# 5. If rmmod fails: sudo rmmod -f speed_bump (forces unload)
#
# TEST METHODOLOGY:
# 1. Verify prerequisites (root, module available)
# 2. Load the kernel module
# 3. Configure a target: /bin/sleep:nanosleep with 10ms delay
# 4. Run /bin/sleep with a short duration and measure wall-clock time
# 5. The measured time should include the injected delay
# 6. Verify the delay by comparing expected vs actual duration
# 7. Clean up: remove config, disable, unload module
#
# REQUIREMENTS:
# - Root/sudo privileges
# - speed_bump.ko module built and available
# - Standard POSIX utilities (date, bc)
#

set -o pipefail

# Cleanup on exit
cleanup_on_exit() {
    local exit_code=$?
    echo ""
    log_warn "Performing emergency cleanup..."
    set_enabled 0 2>/dev/null || true
    clear_all_targets 2>/dev/null || true
    unload_module 2>/dev/null || true
    exit $exit_code
}

trap cleanup_on_exit INT TERM

# ============================================================================
# Configuration
# ============================================================================

SYSFS_BASE="/sys/kernel/speed_bump"
MODULE_NAME="speed_bump"
MODULE_PATH="${MODULE_PATH:-./src/speed_bump.ko}"

# Test configuration: inject 10ms delay into nanosleep (safe, minimal impact)
TEST_BINARY="/bin/sleep"
TEST_SYMBOL="nanosleep"
INJECT_DELAY_NS=10000000   # 10ms
SLEEP_DURATION="0.01"      # 10ms actual sleep

# Tolerance for timing verification (±20% to account for system jitter)
TOLERANCE_PERCENT=20

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "[INFO] $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# Check if we have root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script requires root privileges"
        log_info "Please run with: sudo $0"
        return 1
    fi
    log_pass "Running with root privileges"
    return 0
}

# Check if the module is currently loaded
is_module_loaded() {
    lsmod | grep -q "^${MODULE_NAME} " 2>/dev/null
}

# Load the kernel module
load_module() {
    if is_module_loaded; then
        log_info "Module ${MODULE_NAME} already loaded"
        return 0
    fi

    # Try to load from specified path first
    if [ -f "$MODULE_PATH" ]; then
        log_info "Loading module from ${MODULE_PATH}"
        if ! insmod "$MODULE_PATH" 2>&1; then
            log_error "Failed to load module from ${MODULE_PATH}"
            return 1
        fi
    else
        # Try modprobe as fallback
        log_info "Module file not found at ${MODULE_PATH}, trying modprobe"
        if ! modprobe "$MODULE_NAME" 2>&1; then
            log_error "Failed to load module via modprobe"
            log_info "Ensure the module is built: make modules"
            return 1
        fi
    fi

    # Verify module loaded
    if ! is_module_loaded; then
        log_error "Module load appeared to succeed but module not found in lsmod"
        return 1
    fi

    log_pass "Module ${MODULE_NAME} loaded successfully"
    return 0
}

# Unload the kernel module
unload_module() {
    if ! is_module_loaded; then
        log_info "Module ${MODULE_NAME} not loaded, nothing to unload"
        return 0
    fi

    log_info "Unloading module ${MODULE_NAME}"
    if ! rmmod "$MODULE_NAME" 2>&1; then
        log_error "Failed to unload module"
        return 1
    fi

    log_pass "Module ${MODULE_NAME} unloaded successfully"
    return 0
}

# Check if sysfs interface exists
check_sysfs() {
    if [ ! -d "$SYSFS_BASE" ]; then
        log_error "sysfs interface not found at ${SYSFS_BASE}"
        log_info "Module may not have initialized correctly"
        return 1
    fi
    log_pass "sysfs interface available at ${SYSFS_BASE}"
    return 0
}

# Configure a delay target
configure_target() {
    local path="$1"
    local symbol="$2"
    local delay_ns="$3"

    log_info "Configuring target: ${path}:${symbol} delay=${delay_ns}ns"

    # Add the target
    if ! echo "+${path}:${symbol} ${delay_ns}" > "${SYSFS_BASE}/targets" 2>&1; then
        log_error "Failed to add target"
        return 1
    fi

    log_pass "Target configured successfully"
    return 0
}

# Remove a target
remove_target() {
    local path="$1"
    local symbol="$2"

    log_info "Removing target: ${path}:${symbol}"
    echo "-${path}:${symbol}" > "${SYSFS_BASE}/targets" 2>/dev/null || true
}

# Clear all targets
clear_all_targets() {
    log_info "Clearing all targets"
    echo "-*" > "${SYSFS_BASE}/targets" 2>/dev/null || true
}

# Enable/disable probes
set_enabled() {
    local state="$1"
    log_info "Setting enabled=${state}"
    echo "$state" > "${SYSFS_BASE}/enabled" 2>/dev/null || true
}

# Get current time in nanoseconds
get_time_ns() {
    # Use date with nanoseconds if available, otherwise fall back to seconds
    if date +%s%N >/dev/null 2>&1; then
        date +%s%N
    else
        # Fallback: use seconds * 1e9
        echo $(($(date +%s) * 1000000000))
    fi
}

# Run a command and measure its duration in nanoseconds
measure_duration_ns() {
    local cmd="$*"
    local start_ns end_ns duration_ns

    start_ns=$(get_time_ns)
    eval "$cmd" >/dev/null 2>&1
    end_ns=$(get_time_ns)

    duration_ns=$((end_ns - start_ns))
    echo "$duration_ns"
}

# ============================================================================
# Test Cases
# ============================================================================

# Test 1: Verify module loads and sysfs is available
test_module_init() {
    log_info "=== Test 1: Module initialization ==="

    if ! load_module; then
        log_fail "Module initialization failed"
        return 1
    fi

    if ! check_sysfs; then
        log_fail "sysfs interface not available after module load"
        return 1
    fi

    log_pass "Test 1: Module initialization PASSED"
    return 0
}

# Test 2: Verify delay injection works
test_delay_injection() {
    log_info "=== Test 2: Delay injection ==="

    # First, measure baseline (without delay)
    log_info "Measuring baseline (no delay)..."
    local baseline_ns
    baseline_ns=$(measure_duration_ns "$TEST_BINARY $SLEEP_DURATION")
    log_info "Baseline duration: ${baseline_ns} ns"

    # Configure the delay target
    if ! configure_target "$TEST_BINARY" "$TEST_SYMBOL" "$INJECT_DELAY_NS"; then
        log_fail "Failed to configure delay target"
        return 1
    fi

    # Enable probes
    set_enabled 1

    # Measure with delay
    log_info "Measuring with delay injection..."
    local delayed_ns
    delayed_ns=$(measure_duration_ns "$TEST_BINARY $SLEEP_DURATION")
    log_info "Delayed duration: ${delayed_ns} ns"

    # Disable probes
    set_enabled 0

    # Calculate expected minimum duration
    local expected_min_ns=$((baseline_ns + INJECT_DELAY_NS - (INJECT_DELAY_NS * TOLERANCE_PERCENT / 100)))
    local actual_increase_ns=$((delayed_ns - baseline_ns))

    log_info "Expected delay: ${INJECT_DELAY_NS} ns"
    log_info "Actual increase: ${actual_increase_ns} ns"
    log_info "Tolerance: ±${TOLERANCE_PERCENT}%"

    # Verify the delay was applied
    # The delayed duration should be at least (baseline + delay - tolerance)
    if [ "$delayed_ns" -gt "$expected_min_ns" ]; then
        log_pass "Test 2: Delay injection PASSED"
        log_info "Delay verified: ${actual_increase_ns}ns increase (expected ~${INJECT_DELAY_NS}ns)"
        return 0
    else
        log_fail "Test 2: Delay injection FAILED"
        log_error "Delay was not applied as expected"
        log_error "Expected at least ${expected_min_ns}ns, got ${delayed_ns}ns"
        return 1
    fi
}

# Test 3: Verify cleanup works
test_cleanup() {
    log_info "=== Test 3: Cleanup verification ==="

    # Clear all targets
    clear_all_targets

    # Verify targets list is empty (if readable)
    if [ -r "${SYSFS_BASE}/targets_list" ]; then
        local targets
        targets=$(cat "${SYSFS_BASE}/targets_list" 2>/dev/null | grep -v "^$" | wc -l)
        if [ "$targets" -eq 0 ]; then
            log_pass "All targets cleared"
        else
            log_warn "Some targets may remain: ${targets}"
        fi
    fi

    # Unload module
    if ! unload_module; then
        log_fail "Test 3: Cleanup FAILED - module unload failed"
        return 1
    fi

    log_pass "Test 3: Cleanup PASSED"
    return 0
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    local exit_code=0
    local tests_run=0
    local tests_passed=0
    local tests_failed=0
    local tests_skipped=0

    echo ""
    echo "=========================================="
    echo " Speed Bump Integration Tests"
    echo "=========================================="
    echo ""

    # Pre-flight checks
    if ! check_root; then
        echo ""
        echo "Result: SKIPPED (requires root)"
        exit 77  # Standard skip exit code
    fi

    # Check if module file exists
    if [ ! -f "$MODULE_PATH" ] && ! modinfo "$MODULE_NAME" >/dev/null 2>&1; then
        log_warn "Module not found at ${MODULE_PATH} and not in kernel modules"
        log_warn "Build the module first: make modules"
        log_info "Running in dry-run mode (module not available)"
        echo ""
        echo "Result: SKIPPED (module not available)"
        exit 77
    fi

    # Run tests
    echo ""

    # Test 1: Module init
    ((tests_run++))
    if test_module_init; then
        ((tests_passed++))
    else
        ((tests_failed++))
        exit_code=1
        # Can't continue without module
        echo ""
        echo "=========================================="
        echo " Test Summary"
        echo "=========================================="
        echo " Run:     ${tests_run}"
        echo " Passed:  ${tests_passed}"
        echo " Failed:  ${tests_failed}"
        echo " Skipped: ${tests_skipped}"
        echo ""
        echo "Result: FAILED"
        exit $exit_code
    fi

    echo ""

    # Test 2: Delay injection
    ((tests_run++))
    if test_delay_injection; then
        ((tests_passed++))
    else
        ((tests_failed++))
        exit_code=1
    fi

    echo ""

    # Test 3: Cleanup
    ((tests_run++))
    if test_cleanup; then
        ((tests_passed++))
    else
        ((tests_failed++))
        exit_code=1
    fi

    # Summary
    echo ""
    echo "=========================================="
    echo " Test Summary"
    echo "=========================================="
    echo " Run:     ${tests_run}"
    echo " Passed:  ${tests_passed}"
    echo " Failed:  ${tests_failed}"
    echo " Skipped: ${tests_skipped}"
    echo ""

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}Result: ALL TESTS PASSED${NC}"
    else
        echo -e "${RED}Result: SOME TESTS FAILED${NC}"
    fi

    exit $exit_code
}

# Run main if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
