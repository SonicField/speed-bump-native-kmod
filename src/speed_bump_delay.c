/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Speed Bump - Spin Delay Implementation
 *
 * Provides precise nanosecond-level spin delay using busy-wait loop.
 */

#ifdef MOCK_KERNEL
#include "mock_kernel.h"
#else
#include <linux/types.h>
#include <linux/ktime.h>
#include <linux/processor.h>
#endif

#include "speed_bump.h"

/*
 * Spin delay for the specified number of nanoseconds.
 *
 * Uses ktime_get_ns() for high-resolution timing and cpu_relax()
 * to reduce power consumption during the spin wait.
 */
void speed_bump_spin_delay_ns(u64 delay_ns)
{
    u64 start_ns;
    u64 elapsed_ns;

    if (delay_ns == 0)
        return;

    start_ns = ktime_get_ns();

    do {
        cpu_relax();
        elapsed_ns = ktime_get_ns() - start_ns;
    } while (elapsed_ns < delay_ns);
}

#ifndef MOCK_KERNEL
EXPORT_SYMBOL_GPL(speed_bump_spin_delay_ns);
#endif
