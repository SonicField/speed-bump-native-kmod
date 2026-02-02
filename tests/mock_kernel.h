/*
 * Mock Kernel Headers for Userspace Testing
 *
 * This header provides userspace implementations of kernel primitives
 * to allow testing kernel module logic without an actual kernel.
 *
 * Usage: Define MOCK_KERNEL before including, or compile with -DMOCK_KERNEL
 */

#ifndef MOCK_KERNEL_H
#define MOCK_KERNEL_H

#ifdef MOCK_KERNEL

#define _GNU_SOURCE
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <time.h>
#include <sched.h>
#include <string.h>

/* ============================================================
 * 1. Type Definitions
 * ============================================================ */

typedef uint8_t   u8;
typedef uint16_t  u16;
typedef uint32_t  u32;
typedef uint64_t  u64;

typedef int8_t    s8;
typedef int16_t   s16;
typedef int32_t   s32;
typedef int64_t   s64;

/* Size types */
typedef size_t    size_t;
typedef ssize_t   ssize_t;

/* Atomic types - simplified for userspace testing */
typedef struct {
    volatile int counter;
} atomic_t;

typedef struct {
    volatile long counter;
} atomic_long_t;

typedef struct {
    volatile s64 counter;
} atomic64_t;

#define ATOMIC_INIT(i)       { (i) }
#define atomic_read(v)       ((v)->counter)
#define atomic_set(v, i)     ((v)->counter = (i))
#define atomic_inc(v)        ((v)->counter++)
#define atomic_dec(v)        ((v)->counter--)
#define atomic_add(i, v)     ((v)->counter += (i))
#define atomic_sub(i, v)     ((v)->counter -= (i))

#define atomic64_read(v)     ((v)->counter)
#define atomic64_set(v, i)   ((v)->counter = (i))
#define atomic64_inc(v)      ((v)->counter++)
#define atomic64_add(i, v)   ((v)->counter += (i))

/* Likely/unlikely branch hints */
#define likely(x)            __builtin_expect(!!(x), 1)
#define unlikely(x)          __builtin_expect(!!(x), 0)

/* Memory barriers - using compiler barriers for userspace */
#define barrier()            __asm__ __volatile__("" : : : "memory")
#define smp_mb()             __sync_synchronize()
#define smp_rmb()            barrier()
#define smp_wmb()            barrier()

/* READ_ONCE/WRITE_ONCE for avoiding compiler optimizations */
#define READ_ONCE(x)         (*(volatile typeof(x) *)&(x))
#define WRITE_ONCE(x, val)   (*(volatile typeof(x) *)&(x) = (val))

/* ============================================================
 * 2. Time Functions
 * ============================================================ */

static inline u64 ktime_get_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (u64)ts.tv_sec * 1000000000ULL + (u64)ts.tv_nsec;
}

static inline u64 ktime_get_real_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (u64)ts.tv_sec * 1000000000ULL + (u64)ts.tv_nsec;
}

static inline u64 ktime_get_boottime_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (u64)ts.tv_sec * 1000000000ULL + (u64)ts.tv_nsec;
}

/* ktime_t handling */
typedef s64 ktime_t;

static inline ktime_t ktime_get(void)
{
    return (ktime_t)ktime_get_ns();
}

static inline s64 ktime_to_ns(ktime_t kt)
{
    return kt;
}

static inline s64 ktime_to_us(ktime_t kt)
{
    return kt / 1000;
}

static inline s64 ktime_to_ms(ktime_t kt)
{
    return kt / 1000000;
}

#define NSEC_PER_SEC    1000000000L
#define NSEC_PER_MSEC   1000000L
#define NSEC_PER_USEC   1000L

/* Delay functions */
static inline void ndelay(unsigned long nsecs)
{
    u64 start = ktime_get_ns();
    while (ktime_get_ns() - start < nsecs)
        ;
}

static inline void udelay(unsigned long usecs)
{
    ndelay(usecs * 1000);
}

static inline void mdelay(unsigned long msecs)
{
    ndelay(msecs * 1000000);
}

/* ============================================================
 * 3. CPU Hints
 * ============================================================ */

static inline void cpu_relax(void)
{
#if defined(__x86_64__) || defined(__i386__)
    __asm__ __volatile__("pause" ::: "memory");
#elif defined(__aarch64__)
    __asm__ __volatile__("yield" ::: "memory");
#else
    barrier();
#endif
}

/* rep_nop for spinning */
static inline void rep_nop(void)
{
    cpu_relax();
}

/* ============================================================
 * 4. Scheduler Hints
 * ============================================================ */

static inline void cond_resched(void)
{
    /* In userspace, optionally yield to other threads */
    sched_yield();
}

static inline int cond_resched_rcu(void)
{
    cond_resched();
    return 0;
}

/* ============================================================
 * 5. Print Macros
 * ============================================================ */

/* Kernel log levels */
#define KERN_EMERG      "<0>"
#define KERN_ALERT      "<1>"
#define KERN_CRIT       "<2>"
#define KERN_ERR        "<3>"
#define KERN_WARNING    "<4>"
#define KERN_NOTICE     "<5>"
#define KERN_INFO       "<6>"
#define KERN_DEBUG      "<7>"

/* Strip log level prefixes for userspace printing */
#define __MOCK_STRIP_LEVEL(fmt) \
    ((fmt)[0] == '<' && (fmt)[2] == '>' ? (fmt) + 3 : (fmt))

#define pr_emerg(fmt, ...)   fprintf(stderr, "[EMERG] " fmt, ##__VA_ARGS__)
#define pr_alert(fmt, ...)   fprintf(stderr, "[ALERT] " fmt, ##__VA_ARGS__)
#define pr_crit(fmt, ...)    fprintf(stderr, "[CRIT] " fmt, ##__VA_ARGS__)
#define pr_err(fmt, ...)     fprintf(stderr, "[ERR] " fmt, ##__VA_ARGS__)
#define pr_warn(fmt, ...)    fprintf(stderr, "[WARN] " fmt, ##__VA_ARGS__)
#define pr_warning(fmt, ...) fprintf(stderr, "[WARN] " fmt, ##__VA_ARGS__)
#define pr_notice(fmt, ...)  fprintf(stderr, "[NOTICE] " fmt, ##__VA_ARGS__)
#define pr_info(fmt, ...)    fprintf(stderr, "[INFO] " fmt, ##__VA_ARGS__)
#define pr_debug(fmt, ...)   fprintf(stderr, "[DEBUG] " fmt, ##__VA_ARGS__)
#define pr_cont(fmt, ...)    fprintf(stderr, fmt, ##__VA_ARGS__)

#define printk(fmt, ...)     fprintf(stderr, __MOCK_STRIP_LEVEL(fmt), ##__VA_ARGS__)

/* ============================================================
 * 6. Module Macros
 * ============================================================ */

#define MODULE_LICENSE(x)
#define MODULE_AUTHOR(x)
#define MODULE_DESCRIPTION(x)
#define MODULE_VERSION(x)
#define MODULE_ALIAS(x)
#define MODULE_INFO(tag, info)

#define module_init(fn)      static int (*__module_init_fn)(void) = fn
#define module_exit(fn)      static void (*__module_exit_fn)(void) = fn

#define __init
#define __exit
#define __initdata
#define __exitdata

/* Module parameters - no-ops in userspace */
#define module_param(name, type, perm)
#define module_param_named(name, value, type, perm)
#define module_param_string(name, string, len, perm)
#define module_param_array(name, type, nump, perm)
#define MODULE_PARM_DESC(parm, desc)

/* Export symbols - no-ops */
#define EXPORT_SYMBOL(sym)
#define EXPORT_SYMBOL_GPL(sym)

/* ============================================================
 * 7. Uprobe Stubs
 * ============================================================ */

/* Uprobe return value structure */
struct pt_regs {
    /* x86_64 register layout (simplified) */
    u64 r15, r14, r13, r12;
    u64 bp, bx;
    u64 r11, r10, r9, r8;
    u64 ax, cx, dx;
    u64 si, di;
    u64 orig_ax;
    u64 ip;
    u64 cs;
    u64 flags;
    u64 sp;
    u64 ss;
};

/* Uprobe filter context - must be declared before uprobe_consumer */
enum uprobe_filter_ctx {
    UPROBE_FILTER_REGISTER,
    UPROBE_FILTER_UNREGISTER,
    UPROBE_FILTER_MMAP,
};

/* Uprobe consumer structure */
struct uprobe_consumer {
    int (*handler)(struct uprobe_consumer *self, struct pt_regs *regs);
    int (*ret_handler)(struct uprobe_consumer *self,
                       unsigned long func,
                       struct pt_regs *regs);
    bool (*filter)(struct uprobe_consumer *self,
                   enum uprobe_filter_ctx ctx,
                   void *data);
};

/* Tracking structure for mock uprobe calls */
struct mock_uprobe_record {
    const char *path;
    unsigned long offset;
    struct uprobe_consumer *uc;
    int registered;  /* 1 if registered, 0 if unregistered */
};

#define MOCK_UPROBE_MAX_RECORDS 64
static struct mock_uprobe_record __mock_uprobe_records[MOCK_UPROBE_MAX_RECORDS];
static int __mock_uprobe_record_count = 0;

static inline int uprobe_register(const char *path,
                                  unsigned long offset,
                                  struct uprobe_consumer *uc)
{
    if (__mock_uprobe_record_count < MOCK_UPROBE_MAX_RECORDS) {
        struct mock_uprobe_record *rec =
            &__mock_uprobe_records[__mock_uprobe_record_count++];
        rec->path = path;
        rec->offset = offset;
        rec->uc = uc;
        rec->registered = 1;
    }
    pr_debug("mock: uprobe_register(%s, 0x%lx)\n", path, offset);
    return 0;
}

static inline void uprobe_unregister(const char *path,
                                     unsigned long offset,
                                     struct uprobe_consumer *uc)
{
    if (__mock_uprobe_record_count < MOCK_UPROBE_MAX_RECORDS) {
        struct mock_uprobe_record *rec =
            &__mock_uprobe_records[__mock_uprobe_record_count++];
        rec->path = path;
        rec->offset = offset;
        rec->uc = uc;
        rec->registered = 0;
    }
    pr_debug("mock: uprobe_unregister(%s, 0x%lx)\n", path, offset);
}

/* Helper to check mock uprobe registrations */
static inline int mock_uprobe_get_record_count(void)
{
    return __mock_uprobe_record_count;
}

static inline struct mock_uprobe_record *mock_uprobe_get_record(int idx)
{
    if (idx >= 0 && idx < __mock_uprobe_record_count) {
        return &__mock_uprobe_records[idx];
    }
    return NULL;
}

static inline void mock_uprobe_reset(void)
{
    __mock_uprobe_record_count = 0;
    memset(__mock_uprobe_records, 0, sizeof(__mock_uprobe_records));
}

/* ============================================================
 * Additional Kernel Utilities
 * ============================================================ */

/* Error pointer handling */
#define MAX_ERRNO   4095
#define IS_ERR_VALUE(x) unlikely((unsigned long)(void *)(x) >= (unsigned long)-MAX_ERRNO)

static inline void *ERR_PTR(long error)
{
    return (void *)error;
}

static inline long PTR_ERR(const void *ptr)
{
    return (long)ptr;
}

static inline bool IS_ERR(const void *ptr)
{
    return IS_ERR_VALUE((unsigned long)ptr);
}

static inline bool IS_ERR_OR_NULL(const void *ptr)
{
    return unlikely(!ptr) || IS_ERR_VALUE((unsigned long)ptr);
}

/* Min/max macros */
#define min(a, b) ((a) < (b) ? (a) : (b))
#define max(a, b) ((a) > (b) ? (a) : (b))
#define min_t(type, a, b) ((type)(a) < (type)(b) ? (type)(a) : (type)(b))
#define max_t(type, a, b) ((type)(a) > (type)(b) ? (type)(a) : (type)(b))
#define clamp(val, lo, hi) min((typeof(val))max(val, lo), hi)

/* ARRAY_SIZE */
#define ARRAY_SIZE(arr) (sizeof(arr) / sizeof((arr)[0]))

/* container_of */
#define container_of(ptr, type, member) \
    ((type *)((char *)(ptr) - offsetof(type, member)))

/* BUG/WARN macros */
#define BUG() do { \
    fprintf(stderr, "BUG at %s:%d\n", __FILE__, __LINE__); \
    __builtin_trap(); \
} while (0)

#define BUG_ON(condition) do { \
    if (unlikely(condition)) BUG(); \
} while (0)

#define WARN(condition, fmt, ...) ({ \
    int __ret_warn_on = !!(condition); \
    if (unlikely(__ret_warn_on)) \
        fprintf(stderr, "WARNING at %s:%d: " fmt, \
                __FILE__, __LINE__, ##__VA_ARGS__); \
    unlikely(__ret_warn_on); \
})

#define WARN_ON(condition) WARN(condition, "")

#define WARN_ON_ONCE(condition) ({ \
    static int __warned = 0; \
    int __ret = !!(condition); \
    if (unlikely(__ret) && !__warned) { \
        __warned = 1; \
        fprintf(stderr, "WARNING at %s:%d\n", __FILE__, __LINE__); \
    } \
    unlikely(__ret); \
})

/* RCU stubs - simplified for userspace */
#define rcu_read_lock()
#define rcu_read_unlock()
#define rcu_dereference(p)       (p)
#define rcu_assign_pointer(p, v) ((p) = (v))
#define synchronize_rcu()

#endif /* MOCK_KERNEL */

#endif /* MOCK_KERNEL_H */
