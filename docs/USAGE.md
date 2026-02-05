# Speed Bump Native Module Usage Guide

Quick reference for using the speed_bump kernel module.

## Quick Start

```bash
# 1. Load the module
sudo modprobe speed_bump

# 2. Add a target (delay in nanoseconds)
echo "+/usr/lib64/libpython3.9.so:PyObject_GetAttr 10000000" | sudo tee /sys/kernel/speed_bump/targets

# 3. Enable probes
echo 1 | sudo tee /sys/kernel/speed_bump/enabled

# Run your benchmark...

# 4. Disable and cleanup
echo 0 | sudo tee /sys/kernel/speed_bump/enabled
echo "-*" | sudo tee /sys/kernel/speed_bump/targets
```

## sysfs Interface

All configuration is done via `/sys/kernel/speed_bump/`:

| File | Access | Description |
|------|--------|-------------|
| `enabled` | RW | `0` or `1` - globally enable/disable probes |
| `default_delay_ns` | RW | Default delay when not specified per-target |
| `targets` | WO | Add, remove, or update targets |
| `targets_list` | RO | List configured targets with hit counts |
| `stats` | RO | Overall statistics |

## Target Format

### Add Target

```
+/path/to/binary:symbol_name [delay_ns] [pid=N]
```

**Examples:**
```bash
# Add with explicit delay (10ms)
echo "+/usr/lib/libcuda.so:cudaLaunchKernel 10000000" | sudo tee /sys/kernel/speed_bump/targets

# Add using default delay
echo "+/usr/bin/python3:PyGILState_Ensure" | sudo tee /sys/kernel/speed_bump/targets

# Add with PID filtering (only affects this process tree)
echo "+/usr/bin/python3:PyObject_GetAttr 5000 pid=$$" | sudo tee /sys/kernel/speed_bump/targets
```

### Remove Target

```
-/path/to/binary:symbol_name
```

**Examples:**
```bash
# Remove specific target
echo "-/usr/lib/libcuda.so:cudaLaunchKernel" | sudo tee /sys/kernel/speed_bump/targets

# Remove all targets
echo "-*" | sudo tee /sys/kernel/speed_bump/targets
```

### Update Target Delay

```
=/path/to/binary:symbol_name new_delay_ns
```

**Example:**
```bash
echo "=/usr/lib/libcuda.so:cudaLaunchKernel 50000" | sudo tee /sys/kernel/speed_bump/targets
```

## PID Filtering

By default, probes affect **all processes** calling the target function. Use `pid=N` to restrict delays to a specific process tree:

```bash
# Only delay the current shell and children
echo "+/bin/sleep:nanosleep 1000000 pid=$$" | sudo tee /sys/kernel/speed_bump/targets

# Only delay a specific process
echo "+/usr/bin/python3:PyObject_GetAttr 5000 pid=12345" | sudo tee /sys/kernel/speed_bump/targets
```

When PID filtering is active:
- The specified process and all its descendants are delayed
- Other processes calling the same function are unaffected
- Essential for benchmarking without impacting system services

## Using sbctl

The `sbctl` utility provides a more convenient command-line interface:

```bash
# Add target with delay
sbctl add /usr/lib/libcuda.so:cudaLaunchKernel 10000

# Add with PID filtering
sbctl add /usr/bin/python3:PyObject_GetAttr 1000 --pid=$$

# Update delay
sbctl update /usr/bin/myapp:process_request 50000

# Set default delay
sbctl delay 1000000

# Enable/disable
sbctl enable
sbctl disable

# List targets and status
sbctl list
sbctl status

# Remove targets
sbctl remove /usr/lib/libcuda.so:cudaLaunchKernel
sbctl clear
```

## Checking Status

```bash
# View configured targets
cat /sys/kernel/speed_bump/targets_list

# View statistics
cat /sys/kernel/speed_bump/stats

# Check if enabled
cat /sys/kernel/speed_bump/enabled
```

## Common Use Cases

### Benchmarking Python Code

```bash
# Add delay to attribute lookup (affects performance-sensitive code)
echo "+/usr/lib64/libpython3.9.so:PyObject_GetAttr 10000000 pid=$$" | sudo tee /sys/kernel/speed_bump/targets
echo 1 | sudo tee /sys/kernel/speed_bump/enabled

# Run benchmark
python3 my_benchmark.py

# Cleanup
echo 0 | sudo tee /sys/kernel/speed_bump/enabled
```

### Testing CUDA Workloads

```bash
# Add delay to kernel launches
echo "+/usr/lib/libcuda.so:cudaLaunchKernel 100000" | sudo tee /sys/kernel/speed_bump/targets
echo 1 | sudo tee /sys/kernel/speed_bump/enabled
```

## Troubleshooting

### Module Will Not Unload

```bash
# 1. Disable probes
echo 0 | sudo tee /sys/kernel/speed_bump/enabled

# 2. Clear all targets
echo "-*" | sudo tee /sys/kernel/speed_bump/targets

# 3. Unload module
sudo rmmod speed_bump

# 4. If rmmod hangs, force unload (last resort)
sudo rmmod -f speed_bump
```

### Symbol Not Found

- Verify the symbol exists: `nm -D /path/to/library | grep symbol_name`
- Use the exact symbol name from the ELF file
- For C++ symbols, use the mangled name

### Probes Not Triggering

1. Check enabled: `cat /sys/kernel/speed_bump/enabled`
2. Verify target is registered: `cat /sys/kernel/speed_bump/targets_list`
3. Confirm process is using the expected binary path
4. Check PID filtering is not excluding your process

## Error Codes

| Error | Meaning |
|-------|---------|
| EINVAL | Invalid format (missing separator, invalid prefix) |
| ENOENT | Path or symbol not found |
| ENOEXEC | Not a valid ELF file |
| ENAMETOOLONG | Path (>256) or symbol (>128) too long |
| ERANGE | Delay > 10 seconds |
| EEXIST | Target already registered |
| ENOSPC | Maximum targets reached (64) |

## Limits

| Parameter | Limit |
|-----------|-------|
| Maximum targets | 64 |
| Maximum path length | 256 bytes |
| Maximum symbol length | 128 bytes |
| Maximum delay | 10 seconds (10,000,000,000 ns) |

For the complete interface specification, see `docs/interface-spec.md`.
