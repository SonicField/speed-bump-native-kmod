# speed-bump-native-kmod

Kernel module for applying controlled delays to native code execution using uprobes.

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

## Licence

GPL-2.0 - See LICENSE file.
