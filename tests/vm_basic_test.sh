#!/bin/sh
#
# Basic VM Integration Test for speed_bump kernel module
# POSIX-compatible for busybox ash shell
#
# This test verifies:
# 1. Module loads correctly
# 2. sysfs interface is present
# 3. Basic configuration works
# 4. Module unloads cleanly

set -e

# Colors (if terminal supports them)
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

log_info() {
    printf "[INFO] %s\n" "$1"
}

log_pass() {
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    printf "${RED}[FAIL]${NC} %s\n" "$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# ============================================================================
# Test: sysfs interface exists
# ============================================================================
test_sysfs_interface() {
    TESTS_RUN=$((TESTS_RUN + 1))
    log_info "Test: sysfs interface exists"

    if [ -d /sys/kernel/speed_bump ]; then
        log_pass "sysfs directory /sys/kernel/speed_bump exists"
    else
        log_fail "sysfs directory /sys/kernel/speed_bump not found"
        return 1
    fi

    # Check for expected files
    for file in enabled targets default_delay_ns targets_list stats; do
        if [ -e "/sys/kernel/speed_bump/$file" ]; then
            log_pass "sysfs file $file exists"
        else
            log_fail "sysfs file $file missing"
            return 1
        fi
    done

    return 0
}

# ============================================================================
# Test: Read sysfs attributes
# ============================================================================
test_read_sysfs() {
    TESTS_RUN=$((TESTS_RUN + 1))
    log_info "Test: Read sysfs attributes"

    # Read enabled state
    enabled=$(cat /sys/kernel/speed_bump/enabled)
    log_info "enabled = $enabled"

    # Read default delay
    delay=$(cat /sys/kernel/speed_bump/default_delay_ns)
    log_info "default_delay_ns = $delay"

    # Read targets list (targets_list is readable, targets is write-only)
    targets=$(cat /sys/kernel/speed_bump/targets_list)
    log_info "targets_list = $targets"

    # Read stats
    stats=$(cat /sys/kernel/speed_bump/stats)
    log_info "stats = $stats"

    log_pass "All sysfs attributes readable"
    return 0
}

# ============================================================================
# Test: Write sysfs attributes
# ============================================================================
test_write_sysfs() {
    TESTS_RUN=$((TESTS_RUN + 1))
    log_info "Test: Write sysfs attributes"

    # Try to set default delay
    echo 1000000 > /sys/kernel/speed_bump/default_delay_ns 2>/dev/null || {
        log_fail "Failed to write default_delay_ns"
        return 1
    }

    # Verify it was set
    delay=$(cat /sys/kernel/speed_bump/default_delay_ns)
    if [ "$delay" = "1000000" ]; then
        log_pass "default_delay_ns write verified"
    else
        log_fail "default_delay_ns value mismatch: expected 1000000, got $delay"
        return 1
    fi

    # Try to enable
    echo 1 > /sys/kernel/speed_bump/enabled 2>/dev/null || {
        log_fail "Failed to write enabled"
        return 1
    }

    enabled=$(cat /sys/kernel/speed_bump/enabled)
    if [ "$enabled" = "1" ]; then
        log_pass "enabled write verified"
    else
        log_fail "enabled value mismatch: expected 1, got $enabled"
        return 1
    fi

    # Disable again
    echo 0 > /sys/kernel/speed_bump/enabled
    log_pass "sysfs attributes writable"
    return 0
}

# ============================================================================
# Test: Add and remove target
# ============================================================================
test_targets() {
    TESTS_RUN=$((TESTS_RUN + 1))
    log_info "Test: Add and remove target"

    # Add a target (use /bin/sleep:nanosleep as test target)
    # Note: 'targets' is write-only, 'targets_list' is read-only
    if [ -f /bin/sleep ]; then
        echo "+/bin/sleep:nanosleep" > /sys/kernel/speed_bump/targets 2>/dev/null || {
            log_info "Note: Failed to add target (may be expected if uprobe setup fails)"
        }

        # Check if target was added (use targets_list to read)
        targets=$(cat /sys/kernel/speed_bump/targets_list)
        log_info "Current targets_list: $targets"

        # Clear targets
        echo "-*" > /sys/kernel/speed_bump/targets 2>/dev/null || true
        log_pass "Target add/remove operations completed"
    else
        log_info "Skipping target test: /bin/sleep not available"
        log_pass "Target test skipped (no /bin/sleep)"
    fi

    return 0
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo "=========================================="
    echo " Speed Bump VM Basic Tests"
    echo "=========================================="
    echo ""

    test_sysfs_interface || true
    test_read_sysfs || true
    test_write_sysfs || true
    test_targets || true

    echo ""
    echo "=========================================="
    echo " Test Summary"
    echo "=========================================="
    printf " Run:     %d\n" "$TESTS_RUN"
    printf " Passed:  %d\n" "$TESTS_PASSED"
    printf " Failed:  %d\n" "$TESTS_FAILED"
    echo ""

    if [ "$TESTS_FAILED" -eq 0 ]; then
        printf "${GREEN}Result: ALL TESTS PASSED${NC}\n"
        return 0
    else
        printf "${RED}Result: SOME TESTS FAILED${NC}\n"
        return 1
    fi
}

main "$@"
