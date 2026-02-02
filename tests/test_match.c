/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Speed Bump - Pattern Matching Tests
 *
 * Tests pattern matching for exact, prefix, and mismatch cases.
 * Compile with -DMOCK_KERNEL
 */

#include "mock_kernel.h"
#include "speed_bump.h"

#include <stdio.h>
#include <stdlib.h>

static int tests_run = 0;
static int tests_passed = 0;

static void test_match(const char *pattern, const char *path, const char *symbol,
                       int expected, const char *description)
{
    int result;

    tests_run++;
    result = speed_bump_match_target(pattern, path, symbol);

    if (result == expected) {
        tests_passed++;
        printf("[PASS] %s\n", description);
    } else {
        printf("[FAIL] %s: pattern='%s', path='%s', symbol='%s', "
               "expected=%d, got=%d\n",
               description, pattern, path, symbol, expected, result);
    }
}

int main(void)
{
    printf("=== Speed Bump Match Tests ===\n\n");

    printf("--- Exact Match Tests ---\n");

    /* Exact match - positive cases */
    test_match("/usr/bin/app:main", "/usr/bin/app", "main", 1,
               "Exact match: simple path and symbol");

    test_match("/lib/x86_64-linux-gnu/libc.so.6:malloc",
               "/lib/x86_64-linux-gnu/libc.so.6", "malloc", 1,
               "Exact match: library path with version");

    test_match("/a:b", "/a", "b", 1,
               "Exact match: minimal path and symbol");

    /* Exact match - negative cases */
    test_match("/usr/bin/app:main", "/usr/bin/other", "main", 0,
               "Exact mismatch: different path");

    test_match("/usr/bin/app:main", "/usr/bin/app", "other", 0,
               "Exact mismatch: different symbol");

    test_match("/usr/bin/app:main", "/usr/bin/app/", "main", 0,
               "Exact mismatch: path with trailing slash");

    test_match("/usr/bin/app:main", "/usr/bin/application", "main", 0,
               "Exact mismatch: path is prefix of actual");

    printf("\n--- Prefix Match Tests ---\n");

    /* Prefix match - positive cases */
    test_match("/usr/*:main", "/usr/bin/app", "main", 1,
               "Prefix match: wildcard matches subpath");

    test_match("/usr/bin/*:func", "/usr/bin/any_app", "func", 1,
               "Prefix match: wildcard at directory level");

    test_match("/*:main", "/usr/bin/app", "main", 1,
               "Prefix match: root wildcard");

    test_match("/home/user/project/*:test_func",
               "/home/user/project/build/bin/app", "test_func", 1,
               "Prefix match: deep path match");

    /* Prefix match - negative cases */
    test_match("/usr/*:main", "/opt/bin/app", "main", 0,
               "Prefix mismatch: different root");

    test_match("/usr/*:main", "/usr/bin/app", "other", 0,
               "Prefix mismatch: symbol doesn't match");

    test_match("/usr/bin/*:func", "/usr/lib/app", "func", 0,
               "Prefix mismatch: different directory under prefix");

    printf("\n--- Edge Cases ---\n");

    /* Edge cases */
    test_match(NULL, "/path", "sym", 0,
               "Null pattern returns 0");

    test_match("/path:sym", NULL, "sym", 0,
               "Null path returns 0");

    test_match("/path:sym", "/path", NULL, 0,
               "Null symbol returns 0");

    test_match("nocolon", "/path", "sym", 0,
               "Pattern without colon returns 0");

    test_match(":sym", "", "sym", 1,
               "Empty path pattern matches empty path");

    test_match("/path:", "/path", "", 1,
               "Empty symbol pattern matches empty symbol");

    printf("\n=== Results: %d/%d tests passed ===\n", tests_passed, tests_run);

    return (tests_passed == tests_run) ? 0 : 1;
}
