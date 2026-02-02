/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Speed Bump - Delay Function Tests
 *
 * Tests spin delay accuracy within +/- 10% tolerance.
 * Compile with -DMOCK_KERNEL
 */

#include "mock_kernel.h"
#include "speed_bump.h"

#include <stdio.h>
#include <stdlib.h>

#define TEST_TOLERANCE_PERCENT 10
#define TEST_MIN_OVERHEAD_NS   500  /* Minimum overhead for timing measurement */

static int tests_run = 0;
static int tests_passed = 0;

static void test_delay_accuracy(u64 target_ns, const char *name)
{
    u64 start_ns, end_ns, actual_ns;
    u64 tolerance_ns, min_acceptable, max_acceptable;
    int passed;

    tests_run++;

    /* Use percentage-based tolerance, but with a minimum floor for short delays */
    tolerance_ns = target_ns * TEST_TOLERANCE_PERCENT / 100;
    if (tolerance_ns < TEST_MIN_OVERHEAD_NS)
        tolerance_ns = TEST_MIN_OVERHEAD_NS;

    min_acceptable = (target_ns > tolerance_ns) ? target_ns - tolerance_ns : 0;
    max_acceptable = target_ns + tolerance_ns;

    start_ns = ktime_get_ns();
    speed_bump_spin_delay_ns(target_ns);
    end_ns = ktime_get_ns();

    actual_ns = end_ns - start_ns;

    passed = (actual_ns >= min_acceptable && actual_ns <= max_acceptable);

    if (passed) {
        tests_passed++;
        printf("[PASS] %s: target=%llu ns, actual=%llu ns (%.1f%% of target)\n",
               name,
               (unsigned long long)target_ns,
               (unsigned long long)actual_ns,
               (double)actual_ns * 100.0 / (double)target_ns);
    } else {
        printf("[FAIL] %s: target=%llu ns, actual=%llu ns (%.1f%% of target, expected %d%%-%d%%)\n",
               name,
               (unsigned long long)target_ns,
               (unsigned long long)actual_ns,
               (double)actual_ns * 100.0 / (double)target_ns,
               100 - TEST_TOLERANCE_PERCENT,
               100 + TEST_TOLERANCE_PERCENT);
    }
}

static void test_zero_delay(void)
{
    u64 start_ns, end_ns, actual_ns;
    u64 max_overhead = 1000000; /* 1ms max overhead for zero delay */

    tests_run++;

    start_ns = ktime_get_ns();
    speed_bump_spin_delay_ns(0);
    end_ns = ktime_get_ns();

    actual_ns = end_ns - start_ns;

    if (actual_ns < max_overhead) {
        tests_passed++;
        printf("[PASS] zero_delay: actual=%llu ns (< %llu ns overhead)\n",
               (unsigned long long)actual_ns,
               (unsigned long long)max_overhead);
    } else {
        printf("[FAIL] zero_delay: actual=%llu ns (expected < %llu ns)\n",
               (unsigned long long)actual_ns,
               (unsigned long long)max_overhead);
    }
}

int main(void)
{
    printf("=== Speed Bump Delay Tests ===\n\n");

    /* Test zero delay (edge case) */
    test_zero_delay();

    /* Test various delay durations */
    test_delay_accuracy(1000,       "1us");
    test_delay_accuracy(10000,      "10us");
    test_delay_accuracy(100000,     "100us");
    test_delay_accuracy(1000000,    "1ms");
    test_delay_accuracy(10000000,   "10ms");
    test_delay_accuracy(50000000,   "50ms");

    printf("\n=== Results: %d/%d tests passed ===\n", tests_passed, tests_run);

    return (tests_passed == tests_run) ? 0 : 1;
}
