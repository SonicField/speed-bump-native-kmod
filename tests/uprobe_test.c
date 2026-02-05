/*
 * uprobe_test.c - Simple test program for uprobe-based delay injection
 *
 * Compile statically for VM testing:
 *   aarch64-linux-gnu-gcc -static -O2 -o uprobe_test uprobe_test.c
 * or on native aarch64:
 *   gcc -static -O2 -o uprobe_test uprobe_test.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

/* Target function for uprobe - intentionally not inlined */
__attribute__((noinline))
void target_function(void) {
    /* This function does nothing - it's just a hook point */
    asm volatile("" ::: "memory");
}

/* Get current time in nanoseconds */
static long long get_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

int main(int argc, char *argv[]) {
    int iterations = 10;
    long long total_ns = 0;

    if (argc > 1) {
        iterations = atoi(argv[1]);
        if (iterations <= 0) iterations = 10;
    }

    printf("uprobe_test: Running %d iterations\n", iterations);
    printf("Binary path: %s\n", argv[0]);
    printf("Symbol to probe: target_function\n\n");

    /* Warm up */
    for (int i = 0; i < 3; i++) {
        target_function();
    }

    /* Timed runs */
    for (int i = 0; i < iterations; i++) {
        long long start = get_time_ns();
        target_function();
        long long end = get_time_ns();
        long long duration = end - start;
        total_ns += duration;
        printf("  Iteration %d: %lld ns\n", i + 1, duration);
    }

    long long avg_ns = total_ns / iterations;
    printf("\nAverage: %lld ns (%.3f ms)\n", avg_ns, avg_ns / 1000000.0);

    /* Print info for speed_bump configuration */
    printf("\nTo add delay to this binary:\n");
    printf("  echo \"+%s:target_function\" > /sys/kernel/speed_bump/targets\n", argv[0]);

    return 0;
}
