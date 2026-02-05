# Testing Guide for speed-bump-native-kmod

## Why This Testing Approach

Kernel modules present unique testing challenges: you can't simply run them like userspace programs, they require root privileges, and bugs can crash the entire system. Testing directly against a live kernel is slow, risky, and impractical for development iteration.

Our solution: **separate what CAN be tested in userspace from what MUST be tested in the kernel**.

### The Core Insight

The speed_bump module consists of:
1. **Pure logic** - Delay timing, pattern matching, configuration parsing
2. **Kernel integration** - uprobe registration, sysfs interface, module lifecycle

Pure logic doesn't need the kernel. By providing mock implementations of kernel primitives (`ktime_get_ns()`, `cpu_relax()`, etc.), we can compile and test the same source files as regular userspace programs. This gives us:

- **Fast feedback** - Tests run in milliseconds, not minutes
- **No root required** - Any developer can run tests
- **No crash risk** - Bugs don't take down the system
- **Easy debugging** - Standard tools like gdb, valgrind, sanitizers

Integration tests then verify that the kernel integration works correctly, but only after we're confident the core logic is sound.

## Three-Tier Testing Strategy

### Tier 1: Userspace Unit Tests (Primary)

**What it tests:** Core logic - delay accuracy, pattern matching, mock kernel primitives

**Requirements:** GCC, no special privileges

**When to use:** Every code change during development

```bash
# From repository root
cd tests && make test
```

**Expected output:**
```
=== Running test_delay ===
./test_delay
=== Speed Bump Delay Tests ===

[PASS] zero_delay: actual=153 ns (< 1000000 ns overhead)
[PASS] 1us: target=1000 ns, actual=1152 ns (115.2% of target)
[PASS] 10us: target=10000 ns, actual=10127 ns (101.3% of target)
[PASS] 100us: target=100000 ns, actual=100113 ns (100.1% of target)
[PASS] 1ms: target=1000000 ns, actual=1000082 ns (100.0% of target)
[PASS] 10ms: target=10000000 ns, actual=10000082 ns (100.0% of target)
[PASS] 50ms: target=50000000 ns, actual=50000145 ns (100.0% of target)

=== Results: 7/7 tests passed ===

=== Running test_match ===
./test_match
=== Speed Bump Match Tests ===

--- Exact Match Tests ---
[PASS] Exact match: simple path and symbol
[PASS] Exact match: library path with version
[PASS] Exact match: minimal path and symbol
[PASS] Exact mismatch: different path
[PASS] Exact mismatch: different symbol
...
=== Results: 20/20 tests passed ===

=== Running test_mock ===
./test_mock
[INFO] Testing mock kernel headers
[INFO] Test 1: ktime_get_ns() monotonicity
[INFO]   PASS: t1=... < t2=... < t3=...
...
[INFO]
All tests passed!

All tests completed!
```

**Test files:**
| File | Tests |
|------|-------|
| `test_delay.c` | Spin delay accuracy (0-50ms range, ±10% tolerance) |
| `test_match.c` | Pattern matching: exact, prefix wildcards, edge cases |
| `test_mock.c` | Mock kernel primitives: timing, atomics, uprobe stubs |

### Tier 2: Module Compilation Verification

**What it tests:** Module compiles against current kernel headers, symbol resolution, BTF generation

**Requirements:** Kernel headers for running kernel, compiler matching kernel (auto-detected)

**When to use:** After Tier 1 passes, before integration testing

```bash
# From repository root
make modules
```

**Expected output (success):**
```
make -C /lib/modules/6.13.2-.../build M=/path/to/src CC=clang LD=ld.lld modules
  CC [M]  /path/to/src/speed_bump_main.o
  CC [M]  /path/to/src/speed_bump_delay.o
  CC [M]  /path/to/src/speed_bump_match.o
  CC [M]  /path/to/src/speed_bump_uprobe.o
  CC [M]  /path/to/src/speed_bump_sysfs.o
  LD [M]  /path/to/src/speed_bump.o
  MODPOST /path/to/src/Module.symvers
  CC [M]  /path/to/src/speed_bump.mod.o
  LD [M]  /path/to/src/speed_bump.ko
  BTF [M] /path/to/src/speed_bump.ko
```

**Common warnings (safe to ignore):**
- "Compiler version mismatch" - Minor version differences are OK
- "EXPORT symbol version generation failed" - Internal symbols, not kernel ABI

**Verification:**
```bash
# Confirm module was built
ls -la src/speed_bump.ko

# Check module info
modinfo src/speed_bump.ko
```

### Tier 3: Integration Tests (Real Kernel)

**What it tests:** End-to-end: module loading, sysfs interface, uprobe registration, delay injection

**Requirements:** Root privileges, built kernel module, safe test environment (VM recommended)

**When to use:** Before deployment, after significant changes to kernel integration code

```bash
# Build module first
make modules

# Run integration tests (requires root)
sudo ./tests/integration_test.sh
```

**Expected output (success):**
```
==========================================
 Speed Bump Integration Tests
==========================================

[PASS] Running with root privileges
[INFO] =Test 1: Module initialization ===
[INFO] Loading module from ./src/speed_bump.ko
[PASS] Module speed_bump loaded successfully
[PASS] sysfs interface available at /sys/kernel/speed_bump
[PASS] Test 1: Module initialization PASSED

[INFO] === Test 2: Delay injection ===
[INFO] Measuring baseline (no delay)...
[INFO] Baseline duration: 10234567 ns
[INFO] Configuring target: /bin/sleep:nanosleep delay=10000000ns
[PASS] Target configured successfully
[INFO] Setting enabled=1
[INFO] Measuring with delay injection...
[INFO] Delayed duration: 20456789 ns
[INFO] Setting enabled=0
[INFO] Expected delay: 10000000 ns
[INFO] Actual increase: 10222222 ns
[INFO] Tolerance: ±20%
[PASS] Test 2: Delay injection PASSED

[INFO] === Test 3: Cleanup verification ===
[INFO] Clearing all targets
[PASS] All targets cleared
[INFO] Unloading module speed_bump
[PASS] Module speed_bump unloaded successfully
[PASS] Test 3: Cleanup PASSED

==========================================
 Test Summary
==========================================
 Run:     3
 Passed:  3
 Failed:  0
 Skipped: 0

Result: ALL TESTS PASSED
```

**Exit codes:**
| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |
| 77 | Tests skipped (not root, module unavailable) |

## Development Workflow

### Quick Iteration (Most Common)

For changes to delay logic, pattern matching, or other pure functions:

```bash
# Edit source file in src/
vim src/speed_bump_delay.c

# Run Tier 1 tests
cd tests && make test

# Fix issues, repeat until all pass
```

This loop takes seconds, not minutes.

### Pre-Commit Checklist

Before committing changes:

```bash
# 1. Run userspace tests
cd tests && make test

# 2. Verify module compiles
cd .. && make modules

# 3. (Optional) Run integration tests in VM
# Only needed for uprobe/sysfs changes
```

### Integration Testing Workflow

For changes to kernel integration (uprobe, sysfs, module lifecycle):

```bash
# 1. Ensure userspace tests pass first
cd tests && make test

# 2. Build module
cd .. && make modules

# 3. (Recommended) Copy to VM for testing
scp src/speed_bump.ko qemu-vm:/tmp/

# 4. SSH into VM and run integration tests
ssh qemu-vm
cd /tmp && sudo ./integration_test.sh
```

## Safety Considerations for Kernel Testing

### Why Integration Tests Need Care

Kernel module bugs can:
- Crash the system (kernel panic)
- Corrupt memory
- Leave the system in an unrecoverable state
- Require a hard reboot

### Built-in Safety Features

The integration test script includes multiple safety measures:

1. **Safe target selection**
   - Uses `/bin/sleep` - a minimal, stateless binary
   - Probes `nanosleep` - a simple, well-understood syscall
   - No complex applications or system services affected

2. **Modest delays**
   - 10ms injection delay (10,000,000 ns)
   - Won't freeze the system or cause timeouts
   - Short enough to detect quickly if something goes wrong

3. **Automatic cleanup**
   - Cleanup runs on exit, Ctrl+C, and SIGTERM
   - Disables probes, clears targets, unloads module
   - No manual cleanup required even on test failure

4. **Explicit rollback procedure**
   If the module gets stuck or tests hang:
   ```bash
   # 1. Disable probes
   echo 0 > /sys/kernel/speed_bump/enabled

   # 2. Clear all targets
   echo "-*" > /sys/kernel/speed_bump/targets

   # 3. Unload module
   sudo rmmod speed_bump

   # 4. Force unload if needed
   sudo rmmod -f speed_bump
   ```

### Recommended: QEMU VM for First-Time Testing

For initial verification or after significant changes, use a VM:

1. **Set up a test VM** with the same kernel version
2. **Copy the module** to the VM
3. **Run tests inside the VM** - crashes only affect the VM
4. **Snapshot before testing** for quick recovery

See `~/local/qemu/` for VM setup scripts and images.

### What NOT to Do

- Do NOT test on production systems
- Do NOT inject delays into critical system binaries
- Do NOT use delays longer than 100ms for testing
- Do NOT skip Tier 1/2 and jump straight to integration tests

## Interpreting Test Results

### Tier 1 Failures

**Delay accuracy failure:**
```
[FAIL] 1us: target=1000 ns, actual=5000 ns (500.0% of target, expected 90%-110%)
```
Cause: Spin delay implementation is too slow. Check `speed_bump_spin_delay_ns()` logic.

**Pattern match failure:**
```
[FAIL] Prefix match: pattern='/usr/*:main', path='/usr/bin/app', symbol='main', expected=1, got=0
```
Cause: Wildcard matching logic broken. Check `speed_bump_match_target()`.

**Mock primitive failure:**
```
[ERR] FAIL: ktime_get_ns not monotonic
```
Cause: Mock implementation bug. Check `mock_kernel.h` time functions.

### Tier 2 Failures

**Missing kernel headers:**
```
make[1]: *** /lib/modules/.../build: No such file or directory
```
Solution: Install kernel-devel package for your running kernel.

**Compiler mismatch:**
```
error: unknown option '-fsplit-lto-unit'
```
Solution: The kernel was built with clang, but gcc is being used. The Makefile should auto-detect this; verify `/lib/modules/$(uname -r)/build/.config` exists.

**Symbol resolution:**
```
error: implicit declaration of function 'uprobe_register'
```
Solution: Missing kernel header or API change. Check kernel version compatibility.

### Tier 3 Failures

**Module load failure:**
```
[FAIL] Module initialization failed
insmod: ERROR: could not insert module: Invalid module format
```
Solution: Module was built for different kernel version. Rebuild with `make modules`.

**Delay not applied:**
```
[FAIL] Test 2: Delay injection FAILED
Expected at least 18000000ns, got 10234567ns
```
Cause: Uprobe not registering correctly, or symbol not found. Check dmesg for errors:
```bash
dmesg | tail -20
```

**Cleanup failure:**
```
[FAIL] Test 3: Cleanup FAILED - module unload failed
rmmod: ERROR: Module speed_bump is in use
```
Cause: Probe still active or reference count wrong. Follow manual rollback procedure.

## Adding New Tests

### Tier 1: New Unit Test

1. Create `tests/test_newfeature.c`:
   ```c
   #include "mock_kernel.h"
   #include "speed_bump.h"
   #include <stdio.h>

   static int tests_run = 0;
   static int tests_passed = 0;

   static void test_something(void)
   {
       tests_run++;
       // Test logic here
       if (/* condition */) {
           tests_passed++;
           printf("[PASS] description\n");
       } else {
           printf("[FAIL] description\n");
       }
   }

   int main(void)
   {
       printf("=== New Feature Tests ===\n");
       test_something();
       printf("\n=== Results: %d/%d tests passed ===\n", tests_passed, tests_run);
       return (tests_passed == tests_run) ? 0 : 1;
   }
   ```

2. Add to `tests/Makefile`:
   ```makefile
   TESTS = test_delay test_match test_mock test_newfeature

   test_newfeature: test_newfeature.c $(SRC_DIR)/speed_bump_newfeature.c
       $(CC) $(CFLAGS) -I$(SRC_DIR) -o $@ $^ $(LDFLAGS)
   ```

3. Run: `cd tests && make test`

### Tier 3: New Integration Test

Add a new test function to `tests/integration_test.sh`:

```bash
test_new_feature() {
    log_info "=== Test N: New feature ==="

    # Setup
    configure_target "/bin/test" "symbol" "10000"
    set_enabled 1

    # Execute and measure
    # ...

    # Verify
    if [ "$result" -eq "$expected" ]; then
        log_pass "Test N: New feature PASSED"
        return 0
    else
        log_fail "Test N: New feature FAILED"
        return 1
    fi
}
```

Call from `main()` and update the test count.

## Quick Reference

| Task | Command |
|------|---------|
| Run all userspace tests | `cd tests && make test` |
| Build single test | `cd tests && make test_delay` |
| Build kernel module | `make modules` |
| Run integration tests | `sudo ./tests/integration_test.sh` |
| Clean all builds | `make clean && cd tests && make clean` |
| Check module info | `modinfo src/speed_bump.ko` |
| View kernel logs | `dmesg \| tail -50` |

---

# Testing Strategy

This document describes the two-tier testing strategy for the speed-bump kernel module.

## Overview

Testing kernel modules that interact with uprobes requires both **safety verification** (ensuring the module does not crash the kernel) and **functionality verification** (ensuring uprobes actually work). These have fundamentally different requirements:

| Concern | Environment | What it verifies |
|---------|-------------|------------------|
| Safety | Isolated VM | Module loads, sysfs works, no kernel panic |
| Functionality | Real host | Uprobes fire, delays are injected |

A single environment cannot satisfy both: VMs provide safety but may lack working uprobes; hosts provide real uprobes but risk the system.

## Tier 1: QEMU VM Testing (Safety)

### Purpose

Verify the kernel module does not crash the kernel and that the sysfs interface works correctly.

### Environment

- QEMU with KVM acceleration
- Minimal Linux kernel (e.g., 6.6.x)
- BusyBox userspace

### What This Tests

- Module loads without kernel panic
- Sysfs interface responds correctly
- Basic read/write operations work
- Module unloads cleanly

### What This Cannot Test

- **Real uprobe functionality** - BusyBox binaries are typically statically linked and stripped, making uprobe attachment impossible
- **Actual delay injection** - No suitable dynamic binaries to probe

### Running QEMU Tests

```bash
# Build the module for the VM kernel
make KDIR=/path/to/vm-kernel-build modules

# Start QEMU with the test kernel
qemu-system-x86_64 -kernel bzImage -initrd initramfs.cpio.gz \
    -append "console=ttyS0" -nographic -m 512M -enable-kvm

# Inside VM: load and test
insmod /speed_bump.ko
cat /sys/kernel/speed_bump/enabled
echo 1 > /sys/kernel/speed_bump/enabled
cat /sys/kernel/speed_bump/enabled
rmmod speed_bump
```

### Expected Results

- Module loads: `insmod` returns 0
- Sysfs readable: `cat enabled` shows 0 or 1
- Sysfs writable: `echo 1 > enabled` succeeds
- Module unloads: `rmmod` returns 0

## Tier 2: Host Testing (Functionality)

### Purpose

Verify that uprobes actually fire and delays are injected into real processes.

### Environment

- Real Linux host with kernel 6.x or later
- Dynamically linked binaries with debug symbols
- Root/sudo access

### What This Tests

- Uprobe registration succeeds
- Uprobe handler fires on function entry
- Delays are actually injected
- Measured timing matches expected delays

### Prerequisites

- Kernel module built for the host kernel
- Target binary with symbols (e.g., `libpython3.x.so`)
- Process executing the target function

### Example: Python Attribute Access Test

This test probes `PyObject_GetAttr` in the Python shared library and verifies delays are injected.

```bash
# 1. Load the module
sudo insmod speed_bump.ko

# 2. Find libpython path
LIBPYTHON=$(python3 -c "import sysconfig; print(sysconfig.get_config_var('LIBDIR'))")/libpython3.*.so.1.0

# 3. Configure a 10ms delay on PyObject_GetAttr
echo "+${LIBPYTHON}:PyObject_GetAttr 10000000" | sudo tee /sys/kernel/speed_bump/targets

# 4. Enable probes
echo 1 | sudo tee /sys/kernel/speed_bump/enabled

# 5. Run test
python3 -c "
import time
class Obj:
    attr = 42

o = Obj()
start = time.perf_counter()
for _ in range(100):
    _ = o.attr  # Each triggers PyObject_GetAttr
elapsed = time.perf_counter() - start
print(f'100 attribute accesses took {elapsed*1000:.0f}ms')
"

# 6. Cleanup
echo 0 | sudo tee /sys/kernel/speed_bump/enabled
sudo rmmod speed_bump
```

### Expected Results

With a 10ms delay on `PyObject_GetAttr`:
- 100 attribute accesses should take approximately 1000ms (100 × 10ms)
- Actual measured: ~1010ms (includes Python overhead)
- Tolerance: ±5% is acceptable

### Interpreting Results

| Measured Time | Interpretation |
|---------------|----------------|
| ~1000ms | Delays working correctly |
| ~0ms | Uprobe not firing (check symbol name, path) |
| Kernel panic | Module bug (use QEMU tier first\!) |

## Testing Workflow

1. **Always start with Tier 1** - Verify safety in QEMU before touching host
2. **Build for target kernel** - Module must match the running kernel version
3. **Use safe probes first** - Start with functions that are called rarely
4. **Monitor dmesg** - Watch for warnings or errors during testing
5. **Have rollback ready** - Know how to disable probes and unload module

## Rollback Procedure

If something goes wrong during host testing:

```bash
# 1. Disable all probes immediately
echo 0 | sudo tee /sys/kernel/speed_bump/enabled

# 2. Clear all targets
echo "-*" | sudo tee /sys/kernel/speed_bump/targets

# 3. Unload the module
sudo rmmod speed_bump

# 4. If rmmod hangs, force unload (last resort)
sudo rmmod -f speed_bump
```

## Architecture Notes

- QEMU testing works on x86_64 with KVM acceleration
- Host testing verified on both x86_64 and ARM64
- Uprobe support requires `CONFIG_UPROBES=y` in kernel config
