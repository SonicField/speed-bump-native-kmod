# speed-bump-native-kmod

Kernel module for applying controlled delays to native code execution using uprobes.

## Recommended Usage

The easiest way to use this module is via the **speed-bump Python package**, which provides a high-level API:

```python
from speed_bump import native

with native.probe("/usr/bin/python3", "PyObject_GetAttr", delay_ns=1000):
    run_benchmark()  # Only this process tree is affected
```

The Python API automatically handles PID filtering, probe cleanup, and kernel module communication. See the speed-bump package README for details.

**Direct usage** via `sbctl` or sysfs is also supported for shell scripts, other languages, or advanced use cases.

## Overview

This kernel module uses uprobes to inject configurable delays into native function calls, providing speed-bump functionality for compiled binaries. Configuration is exposed via sysfs.

See `docs/interface-spec.md` for the complete interface specification.

## Prerequisites

### Required

- **Kernel headers** - For the running kernel: `kernel-devel` package or equivalent
- **Compiler** - The build system automatically detects and uses the compiler that built your kernel (typically clang or gcc)
- **dwarves** - Provides `pahole` for BTF (BPF Type Format) generation. Install: `sudo dnf install dwarves` or equivalent
- **LLVM tools** (if kernel built with clang) - Specifically `ld.lld` linker

### Compiler Auto-Detection

The Makefile automatically detects which compiler built your running kernel by reading `CONFIG_CC_VERSION_TEXT` from the kernel's `.config` file. It then uses the same compiler (clang or gcc) to build the module, ensuring compatibility.

If your kernel was built with clang, the module will be built with clang + ld.lld. If built with gcc, the module uses gcc.

**Fallback:** If detection fails, defaults to gcc.

### Build Warnings

You may see these warnings during build - they are non-fatal:

- **Compiler version mismatch** - "The kernel was built by: clang version X.Y, You are using: clang version A.B"
  - Safe to ignore if only minor version differs
  - Module will still work correctly

- **EXPORT symbol version generation failed** - For `speed_bump_spin_delay_ns` and `speed_bump_match_target`
  - These symbols are internal to the module, not part of kernel ABI
  - Safe to ignore

## Building

### Kernel Module

```bash
make modules
```

### Userspace Control Tool

```bash
make -C userspace
```

Install to system (optional):

```bash
sudo make -C userspace install
```

### Userspace Tests

Userspace tests use mock kernel headers to test module logic without loading into the kernel:

```bash
make userspace
make tests
```

## Usage

### sbctl Control Tool

The `sbctl` utility provides a command-line interface for configuring the kernel module.

```bash
# Load the module
sudo modprobe speed_bump

# Add a target with explicit delay (10 microseconds)
sbctl add /usr/lib/libcuda.so:cudaLaunchKernel 10000

# Add a target using default delay
sbctl add /usr/bin/myapp:process_request

# Add a target with PID filtering (only affects this process tree)
sbctl add /usr/bin/python3:PyObject_GetAttr 1000 --pid=$$

# Update a target's delay
sbctl update /usr/bin/myapp:process_request 50000

# Set default delay to 1ms
sbctl delay 1000000

# Enable probes
sbctl enable

# List current targets
sbctl list

# Show statistics
sbctl status

# Remove a specific target
sbctl remove /usr/lib/libcuda.so:cudaLaunchKernel

# Remove all targets
sbctl clear

# Disable probes
sbctl disable
```

### PID Filtering

By default, probes affect **all processes** that execute the target function. Use the `--pid` option to restrict delays to a specific process and its descendants:

```bash
# Only delay the current shell and its children
sbctl add /bin/sleep:nanosleep 1000000 --pid=$$

# Only delay a specific process tree
sbctl add /usr/bin/python3:PyObject_GetAttr 5000 --pid=12345
```

When PID filtering is active:
- The specified process and all its descendants (children, grandchildren, etc.) are delayed
- Other processes calling the same function are not affected
- This is essential for benchmarking without impacting system services

The sysfs format supports PID filtering via `pid=N` suffix:
```bash
echo "+/path/to/binary:symbol 1000 pid=12345" > /sys/kernel/speed_bump/targets
```

For help:

```bash
sbctl --help
```

See `docs/interface-spec.md` for the complete interface specification and sysfs format.

## Testing

### Userspace Tests

The project includes userspace-testable mock kernel headers in `tests/mock_kernel.h`. This allows testing uprobe registration logic and delay injection without requiring a running kernel or root privileges.

```bash
make tests
```

### Integration Tests

The integration test script (`tests/integration_test.sh`) performs end-to-end testing with the real kernel module:

```bash
# Build the kernel module first
make modules

# Run integration tests (requires root)
sudo ./tests/integration_test.sh
```

**Note:** Integration tests require:
- Root privileges
- The kernel module to be built (`make modules`)

The integration test will:
1. Load the kernel module
2. Configure a delay target via sysfs
3. Run a test binary and measure actual delay
4. Verify the delay was applied within tolerance
5. Clean up (remove config, unload module)

Exit codes:
- `0`: All tests passed
- `1`: One or more tests failed
- `77`: Tests skipped (e.g., not running as root, module not available)

## Known Limitations

### Integration Test Status

The integration test script (`tests/integration_test.sh`) has been designed and implemented with safety features but **has not been verified in a live environment**. The test:

- Uses `/bin/sleep` (minimal, safe binary)
- Probes `nanosleep` (simple syscall wrapper)
- Injects a modest 10ms delay (won't freeze the system)
- Includes automatic cleanup on exit/interrupt
- Provides documented rollback procedures

**Verification requires:**
- Root/sudo privileges
- Safe test environment (VM recommended for first run)
- Kernel module successfully loaded

**Rollback procedure** (if module gets stuck):
```bash
# 1. Disable probes
echo 0 > /sys/kernel/speed_bump/enabled

# 2. Clear all targets
echo "-*" > /sys/kernel/speed_bump/targets

# 3. Unload module
sudo rmmod speed_bump

# 4. If rmmod fails
sudo rmmod -f speed_bump
```

### Architecture-Specific Support

- Currently supports **x86_64 only** (64-bit ELF symbol resolution)
- Other architectures would require updates to `speed_bump_uprobe.c`

### Compiler Requirements

- Module must be built with the same compiler (clang or gcc) used to build the running kernel
- The Makefile auto-detects this from `/lib/modules/$(uname -r)/build/.config`
- Minor version mismatches (e.g., clang 19.1 vs 21.1) generate warnings but usually work
- Major version or toolchain mismatches (gcc vs clang) will cause build failures

## Licence

GPL-2.0 - See LICENSE file.
