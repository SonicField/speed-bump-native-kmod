# Risks and Future Investigation Topics

These are identified risks and uncertainties that should be investigated before relying on this code in production.

## 1. PID Filtering with Python Subprocesses

**Hypothesis**: PID filtering works correctly when Python spawns subprocesses via `subprocess.Popen()` or `multiprocessing`.

**Uncertainty**: We verified PID filtering with SSH session ancestry in QEMU, but not with Python's subprocess spawning mechanisms.

**Falsification test**:
- Python parent adds probe with its own PID
- Spawns subprocess that calls probed function
- Measure if subprocess is delayed (should be) vs unrelated process (should not be)

## 2. Python Native Module Kernel Interaction

**Hypothesis**: The Python `native` module correctly communicates with the kernel module via sysfs.

**Uncertainty**: We verified spec string formatting, but not actual sysfs writes with a loaded kernel module.

**Falsification test**:
- Load kernel module
- Call `native.add_probe()` from Python
- Verify probe appears in `/sys/kernel/speed_bump/targets_list`
- Call probed function, verify delay occurs

## 3. Probe Cleanup Race Condition

**Hypothesis**: The context manager correctly removes probes even under abnormal exit conditions.

**Uncertainty**: If a Python process is killed (SIGKILL) while a probe is active, the probe may remain registered.

**Falsification test**:
- Add probe via context manager
- Kill process with SIGKILL mid-execution
- Check if orphan probe remains in kernel module
- Determine if this causes issues (memory leak? stale probe?)

## 4. PIE Binary Support

**Hypothesis**: ELF symbol resolution works correctly for Position-Independent Executables (PIE).

**Uncertainty**: We tested with a non-PIE test binary. Modern distros compile binaries as PIE by default.

**Falsification test**:
- Compile test binary with `-pie -fPIE`
- Add probe for symbol in PIE binary
- Verify uprobe_register succeeds
- Verify delay is applied

**Note**: PIE binaries have different ELF structure - the vaddr in program headers may be 0-based, requiring different offset calculation.

## 5. ARM64 Architecture Support

**Hypothesis**: The kernel module works correctly on ARM64 (aarch64).

**Uncertainty**: Only tested on x86_64. ARM64 has different:
- ELF format details
- Uprobe implementation
- Potential endianness considerations

**Falsification test**:
- Build module on ARM64 kernel
- Run same verification tests as x86_64
- Verify delays are applied correctly

---

*Created: 2026-02-05*
*Status: Unverified - these are identified risks, not confirmed bugs*
