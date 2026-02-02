/*
 * Test file to verify mock_kernel.h works correctly
 * Compile with -DMOCK_KERNEL
 */

#include "mock_kernel.h"

#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    u64 t1, t2, t3;
    int i;

    pr_info("Testing mock kernel headers\n");

    /* Test 1: ktime_get_ns returns monotonically increasing values */
    pr_info("Test 1: ktime_get_ns() monotonicity\n");
    t1 = ktime_get_ns();
    for (i = 0; i < 1000; i++) {
        cpu_relax();
    }
    t2 = ktime_get_ns();
    for (i = 0; i < 1000; i++) {
        cpu_relax();
    }
    t3 = ktime_get_ns();

    if (t2 <= t1 || t3 <= t2) {
        pr_err("FAIL: ktime_get_ns not monotonic: t1=%llu, t2=%llu, t3=%llu\n",
               (unsigned long long)t1,
               (unsigned long long)t2,
               (unsigned long long)t3);
        return 1;
    }
    pr_info("  PASS: t1=%llu < t2=%llu < t3=%llu\n",
            (unsigned long long)t1,
            (unsigned long long)t2,
            (unsigned long long)t3);

    /* Test 2: cpu_relax compiles and runs */
    pr_info("Test 2: cpu_relax() execution\n");
    cpu_relax();
    pr_info("  PASS: cpu_relax executed\n");

    /* Test 3: cond_resched compiles and runs */
    pr_info("Test 3: cond_resched() execution\n");
    cond_resched();
    pr_info("  PASS: cond_resched executed\n");

    /* Test 4: Atomic operations */
    pr_info("Test 4: atomic operations\n");
    atomic_t counter = ATOMIC_INIT(0);
    atomic_inc(&counter);
    atomic_add(5, &counter);
    if (atomic_read(&counter) != 6) {
        pr_err("FAIL: atomic operations incorrect\n");
        return 1;
    }
    pr_info("  PASS: atomic counter = %d\n", atomic_read(&counter));

    /* Test 5: Type sizes */
    pr_info("Test 5: type sizes\n");
    if (sizeof(u8) != 1 || sizeof(u16) != 2 ||
        sizeof(u32) != 4 || sizeof(u64) != 8) {
        pr_err("FAIL: type sizes incorrect\n");
        return 1;
    }
    pr_info("  PASS: u8=%zu, u16=%zu, u32=%zu, u64=%zu\n",
            sizeof(u8), sizeof(u16), sizeof(u32), sizeof(u64));

    /* Test 6: Uprobe stubs */
    pr_info("Test 6: uprobe stubs\n");
    struct uprobe_consumer uc = { 0 };
    mock_uprobe_reset();
    uprobe_register("/usr/bin/test", 0x1234, &uc);
    uprobe_unregister("/usr/bin/test", 0x1234, &uc);
    if (mock_uprobe_get_record_count() != 2) {
        pr_err("FAIL: uprobe record count incorrect\n");
        return 1;
    }
    struct mock_uprobe_record *rec = mock_uprobe_get_record(0);
    if (rec->offset != 0x1234 || rec->registered != 1) {
        pr_err("FAIL: uprobe record data incorrect\n");
        return 1;
    }
    pr_info("  PASS: uprobe stubs recorded %d calls\n",
            mock_uprobe_get_record_count());

    pr_info("\nAll tests passed!\n");
    return 0;
}
