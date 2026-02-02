/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Speed Bump - Internal Kernel Declarations
 *
 * Shared declarations between speed_bump_main.c and speed_bump_uprobe.c.
 * Not part of the public API.
 */

#ifndef SPEED_BUMP_INTERNAL_H
#define SPEED_BUMP_INTERNAL_H

#include <linux/types.h>
#include <linux/list.h>
#include <linux/atomic.h>
#include <linux/uprobes.h>

#include "speed_bump.h"

/* ============================================================
 * Target Management Structure
 * ============================================================ */

struct speed_bump_target {
	struct list_head list;
	char path[SPEED_BUMP_MAX_PATH_LEN];
	char symbol[SPEED_BUMP_MAX_SYMBOL_LEN];
	u64 delay_ns;
	loff_t offset;
	atomic64_t hit_count;
	atomic64_t total_delay_ns;
	struct inode *inode;
	struct uprobe *uprobe;
	struct uprobe_consumer uc;
	bool registered;
};

/* ============================================================
 * Global State (defined in speed_bump_main.c)
 * ============================================================ */

extern struct list_head speed_bump_targets;
extern struct mutex speed_bump_mutex;
extern atomic_t speed_bump_enabled;
extern atomic64_t speed_bump_total_hits;
extern atomic64_t speed_bump_total_delay;

/* ============================================================
 * Uprobe Functions (defined in speed_bump_uprobe.c)
 * ============================================================ */

/*
 * Register a uprobe for a target.
 * Resolves the symbol, sets up the uprobe consumer, and registers with kernel.
 *
 * Caller must hold speed_bump_mutex.
 *
 * Returns: 0 on success, negative error code on failure
 */
int speed_bump_register_uprobe(struct speed_bump_target *target);

/*
 * Unregister a uprobe for a target.
 * Unregisters the uprobe and releases resources.
 *
 * Caller must hold speed_bump_mutex.
 */
void speed_bump_unregister_uprobe(struct speed_bump_target *target);

#endif /* SPEED_BUMP_INTERNAL_H */
