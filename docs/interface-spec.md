# Speed Bump Sysfs Interface Specification

## Overview

The speed_bump kernel module exposes a sysfs interface under `/sys/kernel/speed_bump/` for configuring uprobe-based delay injection into userspace functions.

## Sysfs File Layout

```
/sys/kernel/speed_bump/
├── enabled           # Global enable/disable (RW)
├── targets           # Target management (WO)
├── targets_list      # Current targets (RO)
├── stats             # Statistics (RO)
└── default_delay_ns  # Default delay (RW)
```

### File Descriptions

| File | Mode | Description |
|------|------|-------------|
| `enabled` | RW | "0" or "1" - globally enable/disable all probes |
| `targets` | WO | Write commands to add/remove targets |
| `targets_list` | RO | Read current targets, one per line |
| `stats` | RO | Read hit counts and timing statistics |
| `default_delay_ns` | RW | Default delay if not specified per-target |

## Target Specification Format

### Adding a Target

Write to `targets` with format:
```
+PATH:SYMBOL [DELAY_NS]
```

Components:
- `+` - Add operation prefix
- `PATH` - Absolute path to ELF binary or shared library
- `:` - Separator (literal colon)
- `SYMBOL` - Symbol name (function name in ELF symbol table)
- `DELAY_NS` - Optional delay in nanoseconds (uses default if omitted)

**Constraints:**
- PATH must be absolute (starts with `/`)
- PATH max length: 256 bytes
- SYMBOL max length: 128 bytes
- DELAY_NS range: 0 to 10000000000 (10 seconds)
- No spaces in PATH or SYMBOL
- Total line max: 512 bytes

### Removing a Target

Write to `targets` with format:
```
-PATH:SYMBOL
```

Or remove all targets:
```
-*
```

### Updating a Target's Delay

Remove and re-add with new delay, or use:
```
=PATH:SYMBOL DELAY_NS
```

## Symbol Resolution

The kernel module resolves PATH:SYMBOL to inode+offset:

1. Open file at PATH, get inode
2. Parse ELF headers to find symbol table
3. Look up SYMBOL in .symtab or .dynsym
4. Extract symbol's st_value (offset within file)
5. Register uprobe with inode + offset

If PATH is a shared library, the symbol offset is relative to the library's load address in the ELF file, not the runtime address.

## Example Usage

```bash
# Load the module
sudo modprobe speed_bump

# Set default delay to 1ms
echo 1000000 > /sys/kernel/speed_bump/default_delay_ns

# Add target with explicit delay (10us)
echo "+/usr/lib/libcuda.so:cudaLaunchKernel 10000" > /sys/kernel/speed_bump/targets

# Add target using default delay
echo "+/usr/bin/myapp:process_request" > /sys/kernel/speed_bump/targets

# Enable probes
echo 1 > /sys/kernel/speed_bump/enabled

# Check current targets
cat /sys/kernel/speed_bump/targets_list
# Output:
# /usr/lib/libcuda.so:cudaLaunchKernel delay_ns=10000 hits=0
# /usr/bin/myapp:process_request delay_ns=1000000 hits=0

# Read statistics
cat /sys/kernel/speed_bump/stats
# Output:
# enabled: 1
# targets: 2
# total_hits: 0
# total_delay_ns: 0

# Run workload...

# Check stats again
cat /sys/kernel/speed_bump/stats
# Output:
# enabled: 1
# targets: 2
# total_hits: 1523
# total_delay_ns: 15230000

# Disable probes
echo 0 > /sys/kernel/speed_bump/enabled

# Remove specific target
echo "-/usr/lib/libcuda.so:cudaLaunchKernel" > /sys/kernel/speed_bump/targets

# Remove all targets
echo "-*" > /sys/kernel/speed_bump/targets

# Unload module
sudo rmmod speed_bump
```

## Error Handling

### Write Errors

All errors are reported via the write() return value:

| Error | Errno | Cause |
|-------|-------|-------|
| Invalid format | EINVAL | Missing separator, invalid prefix, malformed line |
| Path not found | ENOENT | File at PATH does not exist |
| Symbol not found | ENOENT | SYMBOL not in ELF symbol table |
| Not an ELF | ENOEXEC | PATH is not a valid ELF file |
| Path too long | ENAMETOOLONG | PATH exceeds 256 bytes |
| Symbol too long | ENAMETOOLONG | SYMBOL exceeds 128 bytes |
| Delay out of range | ERANGE | DELAY_NS > 10 seconds |
| Permission denied | EACCES | Cannot read file at PATH |
| Target not found | ENOENT | Remove operation for non-existent target |
| Duplicate target | EEXIST | Add operation for already-registered target |
| Max targets | ENOSPC | Maximum target limit reached (default: 64) |
| Module busy | EBUSY | Operation not allowed in current state |

### Partial Writes

Each write to `targets` is atomic for a single command. Multi-line writes are not supported; each command must be a separate write() call.

### Read Errors

Read operations do not fail under normal conditions. If the module is in an error state, reads may return truncated data.

## Concurrency

### Thread Safety

- All sysfs operations are serialized via an internal mutex
- Statistics are updated atomically with per-CPU counters

### Modifying Active Targets

Targets can be added or removed while `enabled=1`:

| Operation | Effect |
|-----------|--------|
| Add target while enabled | Probe becomes active immediately |
| Remove target while enabled | Probe is unregistered immediately |
| Disable while probes active | All probes deactivated, state preserved |
| Re-enable | All previously configured probes reactivated |

### In-flight Probes

When removing a target or disabling:
- Any currently executing probe handlers complete normally
- uprobe_unregister() synchronizes with active handlers
- No delay operations are interrupted mid-spin

### Module Unload

`rmmod speed_bump` will:
1. Disable all probes
2. Wait for any in-flight handlers
3. Unregister all uprobes
4. Free all resources

## Limits and Tunables

| Parameter | Default | Description |
|-----------|---------|-------------|
| MAX_TARGETS | 64 | Maximum simultaneous targets |
| MAX_PATH_LEN | 256 | Maximum path length in bytes |
| MAX_SYMBOL_LEN | 128 | Maximum symbol name length |
| MAX_DELAY_NS | 10000000000 | Maximum delay (10 seconds) |

These are compile-time constants defined in `speed_bump.h`.

## Format Grammar

```
command     := add_cmd | remove_cmd | update_cmd
add_cmd     := "+" target [ " " delay ]
remove_cmd  := "-" ( target | "*" )
update_cmd  := "=" target " " delay

target      := path ":" symbol
path        := "/" [^\s:]+
symbol      := [a-zA-Z_][a-zA-Z0-9_]*
delay       := [0-9]+
```

## Internal Resolution Process

When adding a target:

```
User writes: "+/usr/lib/libcuda.so:cudaLaunchKernel 10000"

Kernel module:
1. Parse: path="/usr/lib/libcuda.so", symbol="cudaLaunchKernel", delay=10000
2. kern_path(path) → get struct path
3. file_inode(path.dentry) → get struct inode
4. kernel_read() ELF header, find .dynsym/.symtab
5. Iterate symbols, match "cudaLaunchKernel" → offset=0x12345
6. Allocate target struct, store inode, offset, delay
7. uprobe_register(inode, offset, &consumer) → activate probe
8. Add to targets list
9. Return success (bytes written)
```

## Comparison with Alternatives

| Approach | Pros | Cons |
|----------|------|------|
| sysfs (this spec) | Simple, standard, no extra tools | Limited expressiveness |
| configfs | Hierarchical, atomic transactions | More complex implementation |
| debugfs | Flexible format | Not intended for production |
| ioctl | Binary interface, efficient | Requires custom tool, not inspectable |
| netlink | Async, rich | Complex, overkill for this use |

sysfs was chosen for simplicity and compatibility with standard shell tools.
