// SPDX-License-Identifier: GPL-2.0
/*
 * Speed Bump - Kernel Module Main
 *
 * Implements the sysfs interface for configuring uprobe-based delay injection.
 *
 * Sysfs Interface (/sys/kernel/speed_bump/):
 *   enabled         - RW: "0" or "1" - globally enable/disable all probes
 *   targets         - WO: Write commands to add/remove targets
 *   targets_list    - RO: Read current targets, one per line
 *   stats           - RO: Read hit counts and timing statistics
 *   default_delay_ns - RW: Default delay if not specified per-target
 *
 * Target Command Format:
 *   Add:    +PATH:SYMBOL [DELAY_NS]
 *   Remove: -PATH:SYMBOL or -* (remove all)
 *   Update: =PATH:SYMBOL DELAY_NS
 *
 * See docs/interface-spec.md for full specification.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/string.h>
#include <linux/ctype.h>

#include "speed_bump.h"
#include "speed_bump_internal.h"

/* Module metadata */
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Speed Bump Authors");
MODULE_DESCRIPTION("Uprobe-based delay injection for userspace functions");
MODULE_VERSION("1.0");

/* ============================================================
 * Global State
 * ============================================================ */

/* Global sysfs kobject */
static struct kobject *speed_bump_kobj;

/* Target list and synchronization (exported to speed_bump_uprobe.c) */
LIST_HEAD(speed_bump_targets);
DEFINE_MUTEX(speed_bump_mutex);
atomic_t speed_bump_enabled = ATOMIC_INIT(0);

/* Per-CPU counters - no explicit init needed, zero-initialised */
DEFINE_PER_CPU(u64, speed_bump_hits_percpu);
DEFINE_PER_CPU(u64, speed_bump_delay_percpu);

/* Module-local state */
static u64 speed_bump_default_delay = SPEED_BUMP_DEFAULT_DELAY_NS;
static atomic_t speed_bump_target_count = ATOMIC_INIT(0);

/* ============================================================
 * Target Management
 * ============================================================ */

/*
 * Free a target and its resources.
 * Caller must hold speed_bump_mutex.
 */
static void free_target(struct speed_bump_target *target)
{
	speed_bump_unregister_uprobe(target);
	list_del(&target->list);
	atomic_dec(&speed_bump_target_count);
	kfree(target);
}

/* ============================================================
 * Command Parsing
 * ============================================================ */

/*
 * Parse a target specification line.
 *
 * Format: PATH:SYMBOL [DELAY_NS] [pid=PID]
 *
 * Returns 0 on success, negative errno on failure.
 * On success, populates path, symbol, delay_ns, and pid_filter.
 */
static int parse_target_spec(const char *line, char *path, size_t path_len,
			     char *symbol, size_t symbol_len, u64 *delay_ns,
			     pid_t *pid_filter)
{
	const char *colon, *space, *pid_str;
	size_t plen, slen;
	int ret;

	/* Validate input */
	if (!line || !path || !symbol || !delay_ns || !pid_filter)
		return -EINVAL;

	/* Initialize pid_filter to 0 (no filter) */
	*pid_filter = 0;

	/* Find the colon separator */
	colon = strchr(line, ':');
	if (!colon)
		return -EINVAL;

	/* Extract path */
	plen = colon - line;
	if (plen == 0 || plen >= path_len)
		return -ENAMETOOLONG;

	/* Path must be absolute */
	if (line[0] != '/')
		return -EINVAL;

	memcpy(path, line, plen);
	path[plen] = '\0';

	/* Find space (optional delay and/or pid) */
	space = strchr(colon + 1, ' ');
	if (space) {
		slen = space - (colon + 1);
		if (slen == 0 || slen >= symbol_len)
			return -ENAMETOOLONG;

		memcpy(symbol, colon + 1, slen);
		symbol[slen] = '\0';

		/* Check for pid= in the remainder */
		pid_str = strstr(space + 1, "pid=");
		if (pid_str) {
			/* Parse PID */
			ret = kstrtoint(pid_str + 4, 10, pid_filter);
			if (ret)
				return ret;
			if (*pid_filter < 0)
				return -EINVAL;
		}

		/* Parse delay (everything between first space and pid= or end) */
		if (pid_str && pid_str > space + 1) {
			/* There's something before pid= - try to parse as delay */
			char delay_buf[32];
			size_t delay_len = pid_str - (space + 1);
			/* Skip trailing whitespace */
			while (delay_len > 0 && (space[delay_len] == ' ' || space[delay_len] == '\t'))
				delay_len--;
			if (delay_len > 0 && delay_len < sizeof(delay_buf)) {
				memcpy(delay_buf, space + 1, delay_len);
				delay_buf[delay_len] = '\0';
				ret = kstrtou64(delay_buf, 10, delay_ns);
				if (ret)
					return ret;
			} else {
				*delay_ns = speed_bump_default_delay;
			}
		} else if (!pid_str) {
			/* No pid=, just parse delay */
			ret = kstrtou64(space + 1, 10, delay_ns);
			if (ret)
				return ret;
		} else {
			/* pid= is right after space, use default delay */
			*delay_ns = speed_bump_default_delay;
		}

		if (*delay_ns > SPEED_BUMP_MAX_DELAY_NS)
			return -ERANGE;
	} else {
		slen = strlen(colon + 1);
		/* Strip trailing newline */
		while (slen > 0 && (colon[slen] == '\n' || colon[slen] == '\r'))
			slen--;

		if (slen == 0 || slen >= symbol_len)
			return -ENAMETOOLONG;

		memcpy(symbol, colon + 1, slen);
		symbol[slen] = '\0';

		/* Use default delay */
		*delay_ns = speed_bump_default_delay;
	}

	/* Validate symbol name (alphanumeric + underscore, starts with letter or _) */
	if (symbol[0] != '_' && !isalpha(symbol[0]))
		return -EINVAL;

	return 0;
}

/*
 * Find a target by path and symbol.
 * Caller must hold speed_bump_mutex.
 */
static struct speed_bump_target *find_target(const char *path, const char *symbol)
{
	struct speed_bump_target *target;

	list_for_each_entry(target, &speed_bump_targets, list) {
		if (strcmp(target->path, path) == 0 &&
		    strcmp(target->symbol, symbol) == 0)
			return target;
	}
	return NULL;
}

/*
 * Add a new target.
 * Returns 0 on success, negative errno on failure.
 */
static int add_target(const char *spec)
{
	struct speed_bump_target *target;
	char path[SPEED_BUMP_MAX_PATH_LEN];
	char symbol[SPEED_BUMP_MAX_SYMBOL_LEN];
	u64 delay_ns;
	pid_t pid_filter;
	int ret;

	ret = parse_target_spec(spec, path, sizeof(path),
				symbol, sizeof(symbol), &delay_ns, &pid_filter);
	if (ret)
		return ret;

	mutex_lock(&speed_bump_mutex);

	/* Check for duplicate */
	if (find_target(path, symbol)) {
		ret = -EEXIST;
		goto out_unlock;
	}

	/* Check max targets */
	if (atomic_read(&speed_bump_target_count) >= SPEED_BUMP_MAX_TARGETS) {
		ret = -ENOSPC;
		goto out_unlock;
	}

	/* Allocate and initialize target */
	target = kzalloc(sizeof(*target), GFP_KERNEL);
	if (!target) {
		ret = -ENOMEM;
		goto out_unlock;
	}

	strscpy(target->path, path, sizeof(target->path));
	strscpy(target->symbol, symbol, sizeof(target->symbol));
	target->delay_ns = delay_ns;
	target->pid_filter = pid_filter;
	atomic64_set(&target->hit_count, 0);
	atomic64_set(&target->total_delay_ns, 0);
	INIT_LIST_HEAD(&target->list);

	/* Register uprobe */
	ret = speed_bump_register_uprobe(target);
	if (ret) {
		kfree(target);
		goto out_unlock;
	}

	/* Add to list */
	list_add_tail(&target->list, &speed_bump_targets);
	atomic_inc(&speed_bump_target_count);

	if (pid_filter)
		pr_info("speed_bump: added target %s:%s delay=%llu ns pid=%d\n",
			path, symbol, delay_ns, pid_filter);
	else
		pr_info("speed_bump: added target %s:%s delay=%llu ns\n",
			path, symbol, delay_ns);

out_unlock:
	mutex_unlock(&speed_bump_mutex);
	return ret;
}

/*
 * Remove a target by path and symbol, or remove all targets.
 */
static int remove_target(const char *spec)
{
	struct speed_bump_target *target, *tmp;
	const char *colon;
	char path[SPEED_BUMP_MAX_PATH_LEN];
	char symbol[SPEED_BUMP_MAX_SYMBOL_LEN];
	size_t plen, slen;
	int removed = 0;

	/* Check for remove-all */
	if (spec[0] == '*' && (spec[1] == '\0' || spec[1] == '\n')) {
		mutex_lock(&speed_bump_mutex);
		list_for_each_entry_safe(target, tmp, &speed_bump_targets, list) {
			free_target(target);
			removed++;
		}
		mutex_unlock(&speed_bump_mutex);
		pr_info("speed_bump: removed all %d targets\n", removed);
		return 0;
	}

	/* Parse path:symbol */
	colon = strchr(spec, ':');
	if (!colon)
		return -EINVAL;

	plen = colon - spec;
	if (plen == 0 || plen >= sizeof(path))
		return -ENAMETOOLONG;

	memcpy(path, spec, plen);
	path[plen] = '\0';

	slen = strlen(colon + 1);
	/* Strip trailing newline */
	while (slen > 0 && (colon[slen] == '\n' || colon[slen] == '\r'))
		slen--;

	if (slen == 0 || slen >= sizeof(symbol))
		return -ENAMETOOLONG;

	memcpy(symbol, colon + 1, slen);
	symbol[slen] = '\0';

	mutex_lock(&speed_bump_mutex);

	target = find_target(path, symbol);
	if (!target) {
		mutex_unlock(&speed_bump_mutex);
		return -ENOENT;
	}

	free_target(target);
	mutex_unlock(&speed_bump_mutex);

	pr_info("speed_bump: removed target %s:%s\n", path, symbol);
	return 0;
}

/*
 * Update a target's delay.
 */
static int update_target(const char *spec)
{
	struct speed_bump_target *target;
	char path[SPEED_BUMP_MAX_PATH_LEN];
	char symbol[SPEED_BUMP_MAX_SYMBOL_LEN];
	u64 delay_ns;
	pid_t pid_filter;
	int ret;

	ret = parse_target_spec(spec, path, sizeof(path),
				symbol, sizeof(symbol), &delay_ns, &pid_filter);
	if (ret)
		return ret;

	mutex_lock(&speed_bump_mutex);

	target = find_target(path, symbol);
	if (!target) {
		mutex_unlock(&speed_bump_mutex);
		return -ENOENT;
	}

	target->delay_ns = delay_ns;
	/* Also update pid_filter if specified */
	if (pid_filter)
		target->pid_filter = pid_filter;
	mutex_unlock(&speed_bump_mutex);

	pr_info("speed_bump: updated target %s:%s delay=%llu ns\n",
		path, symbol, delay_ns);
	return 0;
}

/* ============================================================
 * Sysfs Interface
 * ============================================================ */

/*
 * /sys/kernel/speed_bump/enabled
 *
 * Read/write global enable flag. When disabled (0), uprobe handlers
 * return immediately without executing delays.
 */
static ssize_t enabled_show(struct kobject *kobj, struct kobj_attribute *attr,
			    char *buf)
{
	return sysfs_emit(buf, "%d\n", atomic_read(&speed_bump_enabled));
}

static ssize_t enabled_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	int val, ret;

	ret = kstrtoint(buf, 10, &val);
	if (ret)
		return ret;

	if (val != 0 && val != 1)
		return -EINVAL;

	atomic_set(&speed_bump_enabled, val);
	pr_info("speed_bump: %s\n", val ? "enabled" : "disabled");
	return count;
}

static struct kobj_attribute enabled_attr =
	__ATTR(enabled, 0644, enabled_show, enabled_store);

/*
 * /sys/kernel/speed_bump/targets
 *
 * Write-only: Add, remove, or update targets.
 * Format: +PATH:SYMBOL [DELAY], -PATH:SYMBOL, -*, =PATH:SYMBOL DELAY
 */
static ssize_t targets_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	int ret;

	if (count == 0)
		return -EINVAL;

	if (count > SPEED_BUMP_MAX_LINE_LEN)
		return -EINVAL;

	switch (buf[0]) {
	case '+':
		ret = add_target(buf + 1);
		break;
	case '-':
		ret = remove_target(buf + 1);
		break;
	case '=':
		ret = update_target(buf + 1);
		break;
	default:
		return -EINVAL;
	}

	return ret ? ret : count;
}

static struct kobj_attribute targets_attr =
	__ATTR(targets, 0200, NULL, targets_store);

/*
 * /sys/kernel/speed_bump/targets_list
 *
 * Read-only: List all configured targets with their delays and hit counts.
 * Format: PATH:SYMBOL delay_ns=N hits=M [pid=P]
 */
static ssize_t targets_list_show(struct kobject *kobj,
				 struct kobj_attribute *attr, char *buf)
{
	struct speed_bump_target *target;
	ssize_t len = 0;

	mutex_lock(&speed_bump_mutex);

	list_for_each_entry(target, &speed_bump_targets, list) {
		if (target->pid_filter)
			len += sysfs_emit_at(buf, len,
					     "%s:%s delay_ns=%llu hits=%lld pid=%d\n",
					     target->path, target->symbol,
					     target->delay_ns,
					     atomic64_read(&target->hit_count),
					     target->pid_filter);
		else
			len += sysfs_emit_at(buf, len,
					     "%s:%s delay_ns=%llu hits=%lld\n",
					     target->path, target->symbol,
					     target->delay_ns,
					     atomic64_read(&target->hit_count));
	}

	mutex_unlock(&speed_bump_mutex);
	return len;
}

static struct kobj_attribute targets_list_attr =
	__ATTR(targets_list, 0444, targets_list_show, NULL);

/*
 * Aggregate per-CPU counters.
 * Returns the sum of all per-CPU values.
 */
static u64 aggregate_percpu_hits(void)
{
	u64 total = 0;
	int cpu;

	for_each_possible_cpu(cpu)
		total += per_cpu(speed_bump_hits_percpu, cpu);

	return total;
}

static u64 aggregate_percpu_delay(void)
{
	u64 total = 0;
	int cpu;

	for_each_possible_cpu(cpu)
		total += per_cpu(speed_bump_delay_percpu, cpu);

	return total;
}

/*
 * /sys/kernel/speed_bump/stats
 *
 * Read-only: Global statistics.
 */
static ssize_t stats_show(struct kobject *kobj, struct kobj_attribute *attr,
			  char *buf)
{
	return sysfs_emit(buf,
			  "enabled: %d\n"
			  "targets: %d\n"
			  "total_hits: %llu\n"
			  "total_delay_ns: %llu\n",
			  atomic_read(&speed_bump_enabled),
			  atomic_read(&speed_bump_target_count),
			  aggregate_percpu_hits(),
			  aggregate_percpu_delay());
}

static struct kobj_attribute stats_attr =
	__ATTR(stats, 0444, stats_show, NULL);

/*
 * /sys/kernel/speed_bump/default_delay_ns
 *
 * Read/write: Default delay applied to targets without explicit delay.
 */
static ssize_t default_delay_ns_show(struct kobject *kobj,
				     struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%llu\n", speed_bump_default_delay);
}

static ssize_t default_delay_ns_store(struct kobject *kobj,
				      struct kobj_attribute *attr,
				      const char *buf, size_t count)
{
	u64 val;
	int ret;

	ret = kstrtou64(buf, 10, &val);
	if (ret)
		return ret;

	if (val > SPEED_BUMP_MAX_DELAY_NS)
		return -ERANGE;

	speed_bump_default_delay = val;
	return count;
}

static struct kobj_attribute default_delay_ns_attr =
	__ATTR(default_delay_ns, 0644, default_delay_ns_show,
	       default_delay_ns_store);

/* Attribute group */
static struct attribute *speed_bump_attrs[] = {
	&enabled_attr.attr,
	&targets_attr.attr,
	&targets_list_attr.attr,
	&stats_attr.attr,
	&default_delay_ns_attr.attr,
	NULL,
};

static struct attribute_group speed_bump_attr_group = {
	.attrs = speed_bump_attrs,
};

/* ============================================================
 * Module Init/Exit
 * ============================================================ */

static int __init speed_bump_init(void)
{
	int ret;

	/* Create sysfs directory under /sys/kernel/speed_bump */
	speed_bump_kobj = kobject_create_and_add("speed_bump", kernel_kobj);
	if (!speed_bump_kobj)
		return -ENOMEM;

	/* Create sysfs files */
	ret = sysfs_create_group(speed_bump_kobj, &speed_bump_attr_group);
	if (ret) {
		kobject_put(speed_bump_kobj);
		return ret;
	}

	pr_info("speed_bump: module loaded (max_targets=%d, max_delay=%llu ns)\n",
		SPEED_BUMP_MAX_TARGETS, SPEED_BUMP_MAX_DELAY_NS);
	return 0;
}

static void __exit speed_bump_exit(void)
{
	struct speed_bump_target *target, *tmp;

	/* Disable all probes */
	atomic_set(&speed_bump_enabled, 0);

	/* Remove all targets */
	mutex_lock(&speed_bump_mutex);
	list_for_each_entry_safe(target, tmp, &speed_bump_targets, list) {
		free_target(target);
	}
	mutex_unlock(&speed_bump_mutex);

	/* Remove sysfs entries */
	sysfs_remove_group(speed_bump_kobj, &speed_bump_attr_group);
	kobject_put(speed_bump_kobj);

	pr_info("speed_bump: module unloaded\n");
}

module_init(speed_bump_init);
module_exit(speed_bump_exit);
