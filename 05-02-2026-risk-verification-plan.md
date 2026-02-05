# Risk Verification Plan

**Date**: 05-02-2026
**Target**: Verify risks #1-4 from `docs/risks-todo.md`
**Environment**: ARM64 host (devgpu004) with kernel 6.13.2-0_fbk8

## Repositories

| Repo | Path | Contents |
|------|------|----------|
| speed-bump | `~/local/speed-bump/` | Python package with native module |
| speed-bump-native-kmod | `~/local/speed-bump-native-kmod/` | Kernel module source |

Python native module location: `~/local/speed-bump/src/speed_bump/native.py`

---

## Dependencies

```
Item 2 (Python native module) ─┬─→ Item 1 (PID filtering with subprocesses)
                               └─→ Item 3 (Probe cleanup race condition)

Item 4 (PIE binary support) ───→ (independent)
```

Items 1 and 3 MUST NOT proceed until Item 2 is verified.
Item 4 MAY proceed in parallel with Items 1-3.

---

## Item 2: Python Native Module Kernel Interaction

**Hypothesis**: The Python `native` module correctly communicates with the kernel module via sysfs.

**Preconditions**:
- Kernel module `speed_bump` is loaded on ARM64 host
- Python package `speed_bump` is installed or `PYTHONPATH` includes `~/local/speed-bump/src/`

**Test Procedure**:
1. Load kernel module: `sudo modprobe speed_bump`
2. Verify `native.is_available()` returns `True`
3. Call `native.add_probe("/usr/lib64/libpython3.9.so", "PyObject_GetAttr", delay_ns=10000000)`
4. Verify probe appears: `cat /sys/kernel/speed_bump/targets_list`
5. Call `getattr(object(), "foo")` in a loop (100 iterations)
6. Measure elapsed time
7. Call `native.remove_probe("/usr/lib64/libpython3.9.so", "PyObject_GetAttr")`

**Success Criterion**: Elapsed time MUST be >= 1000ms (100 * 10ms). Probe MUST appear in targets_list. Probe MUST be removed after `remove_probe()`.

**Failure Criterion**: `is_available()` returns False OR elapsed time < 1000ms OR probe does not appear OR probe not removed.

---

## Item 1: PID Filtering with Python Subprocesses

**Hypothesis**: PID filtering works correctly when Python spawns subprocesses.

**Preconditions**:
- Item 2 verified
- Kernel module loaded

**Test Procedure**:
1. Python parent calls `native.add_probe(..., pid=os.getpid())`
2. Parent spawns subprocess via `subprocess.Popen()`
3. Subprocess calls probed function (e.g., `getattr`)
4. Measure subprocess elapsed time
5. Unrelated process (different shell) calls same function
6. Measure unrelated process elapsed time
7. Parent calls `native.remove_probe(...)`

**Success Criterion**: Subprocess elapsed time MUST show delay. Unrelated process elapsed time MUST NOT show delay.

**Failure Criterion**: Subprocess is not delayed OR unrelated process is delayed.

---

## Item 3: Probe Cleanup Race Condition

**Hypothesis**: Orphan probes from killed processes do not cause system instability.

**Preconditions**:
- Item 2 verified
- Kernel module loaded

**Test Procedure**:
1. Python process enters `with native.probe(...)` context manager
2. External process sends SIGKILL to Python process mid-execution
3. Check `/sys/kernel/speed_bump/targets_list` for orphan probe
4. IF orphan exists, verify:
   - Module can still add/remove other probes
   - Module can be unloaded cleanly (`sudo rmmod speed_bump`)
   - No kernel warnings in `dmesg`

**Success Criterion**: System remains stable. Module operations succeed. No kernel warnings.

**Failure Criterion**: Module operations fail OR kernel warnings appear OR module cannot unload.

**Note**: This test verifies stability, not automatic cleanup. Manual cleanup of orphan probes via `sbctl clear` MAY be acceptable behaviour.

---

## Item 4: PIE Binary Support

**Hypothesis**: ELF symbol resolution works correctly for Position-Independent Executables.

**Preconditions**:
- Kernel module loaded
- Compiler available (gcc or clang)

**Test Procedure**:
1. Compile test binary with PIE: `gcc -pie -fPIE -o test_pie test_pie.c`
2. Verify binary is PIE: `file test_pie` shows "pie executable"
3. Add probe for symbol in PIE binary
4. Execute PIE binary
5. Measure elapsed time

**Success Criterion**: Probe registers successfully. Delay is applied.

**Failure Criterion**: Probe registration fails OR no delay observed.

---

## Execution Order (Parallelised)

```
Time ──────────────────────────────────────────────────────────►

Phase 1:  ┌─────────────────┐   ┌─────────────────┐
          │ Item 2 (Python) │   │ Item 4 (PIE)    │
          └────────┬────────┘   └─────────────────┘
                   │
Phase 2:  ┌────────┴────────┐   ┌─────────────────┐
          │ Item 1 (PID)    │   │ Item 3 (SIGKILL)│
          └─────────────────┘   └─────────────────┘
```

**Phase 1**: Items 2 and 4 execute in PARALLEL (no dependency between them)
**Phase 2**: Items 1 and 3 execute in PARALLEL AFTER Item 2 completes

---

## Verification of This Plan

After all items complete:
1. Update `docs/risks-todo.md` with verification status for each item
2. Commit changes
3. Push to origin

---

## Open Questions

None. All questions resolved.
