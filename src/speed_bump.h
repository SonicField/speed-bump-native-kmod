/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Speed Bump - Shared Declarations
 *
 * This header provides the public API for speed bump functionality.
 * Works in both kernel mode and userspace (with MOCK_KERNEL defined).
 */

#ifndef SPEED_BUMP_H
#define SPEED_BUMP_H

#ifdef MOCK_KERNEL
#include "mock_kernel.h"
#else
#include <linux/types.h>
#include <linux/ktime.h>
#include <linux/delay.h>
#endif

/* ============================================================
 * Configuration Limits (compile-time constants)
 * ============================================================ */

#define SPEED_BUMP_MAX_TARGETS      64
#define SPEED_BUMP_MAX_PATH_LEN     256
#define SPEED_BUMP_MAX_SYMBOL_LEN   128
#define SPEED_BUMP_MAX_LINE_LEN     512
#define SPEED_BUMP_MAX_DELAY_NS     10000000000ULL  /* 10 seconds */
#define SPEED_BUMP_DEFAULT_DELAY_NS 1000000ULL      /* 1 millisecond */

/*
 * Spin delay for the specified number of nanoseconds.
 *
 * Uses a busy-wait loop with cpu_relax() to minimize CPU impact while
 * maintaining precise timing. This is intentionally a spin-wait and
 * does not yield to the scheduler.
 *
 * @delay_ns: Number of nanoseconds to delay
 */
void speed_bump_spin_delay_ns(u64 delay_ns);

/*
 * Match a target pattern against a path and symbol.
 *
 * Pattern format: "PATH:SYMBOL"
 * - Exact match: "/path/to/binary:function_name"
 * - Prefix match: "/path/[*]:function_name" (any binary under /path/)
 *
 * @pattern: The pattern to match (PATH:SYMBOL format)
 * @path: The actual binary path
 * @symbol: The actual symbol name
 *
 * Returns: 1 if pattern matches, 0 otherwise
 */
int speed_bump_match_target(const char *pattern, const char *path, const char *symbol);

#endif /* SPEED_BUMP_H */
