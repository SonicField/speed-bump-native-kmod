/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Speed Bump - Pattern Matching Implementation
 *
 * Matches "PATH:SYMBOL" patterns against target path and symbol.
 * Supports exact match and prefix match (PATH ending in *).
 */

#ifdef MOCK_KERNEL
#include "mock_kernel.h"
#include <string.h>
#else
#include <linux/types.h>
#include <linux/string.h>
#endif

#include "speed_bump.h"

/*
 * Match a target pattern against path and symbol.
 *
 * Pattern format: "PATH:SYMBOL"
 * - Exact: "/usr/bin/app:func" matches only that exact path and symbol
 * - Prefix: path ending in asterisk matches any path with that prefix
 *
 * Returns 1 on match, 0 on no match.
 */
int speed_bump_match_target(const char *pattern, const char *path, const char *symbol)
{
    const char *colon;
    size_t path_pattern_len;
    const char *symbol_pattern;
    size_t symbol_pattern_len;
    int is_prefix_match;

    if (!pattern || !path || !symbol)
        return 0;

    /* Find the colon separator */
    colon = strchr(pattern, ':');
    if (!colon)
        return 0;

    path_pattern_len = (size_t)(colon - pattern);
    symbol_pattern = colon + 1;
    symbol_pattern_len = strlen(symbol_pattern);

    /* Check for prefix match (path pattern ending in *) */
    is_prefix_match = (path_pattern_len > 0 && pattern[path_pattern_len - 1] == '*');

    /* Match the symbol first (must be exact) */
    if (strlen(symbol) != symbol_pattern_len)
        return 0;
    if (strncmp(symbol, symbol_pattern, symbol_pattern_len) != 0)
        return 0;

    /* Match the path */
    if (is_prefix_match) {
        /* Prefix match: compare up to the * (excluding it) */
        size_t prefix_len = path_pattern_len - 1;
        if (strlen(path) < prefix_len)
            return 0;
        if (strncmp(path, pattern, prefix_len) != 0)
            return 0;
    } else {
        /* Exact match */
        if (strlen(path) != path_pattern_len)
            return 0;
        if (strncmp(path, pattern, path_pattern_len) != 0)
            return 0;
    }

    return 1;
}

#ifndef MOCK_KERNEL
EXPORT_SYMBOL_GPL(speed_bump_match_target);
#endif
