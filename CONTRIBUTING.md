# Contributing to speed-bump-native-kmod

Thank you for your interest in contributing to speed-bump-native-kmod. This document provides guidelines for contributing to the project.

## Reporting Bugs

Before reporting a bug, please:

1. Check existing issues to avoid duplicates
2. Ensure you're using the latest version
3. Collect relevant information (kernel version, architecture, dmesg output)

To report a bug, [open an issue](../../issues/new?template=bug_report.md) using the bug report template.

## Submitting Patches

### Workflow

1. **Fork** the repository on GitHub
2. **Clone** your fork locally
3. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. **Make your changes** following the coding style below
5. **Test your changes** (see Testing Requirements)
6. **Commit** with a clear message (see Commit Message Format)
7. **Push** to your fork
8. **Open a Pull Request** against the `main` branch

### Coding Style

This is a Linux kernel module. Follow the **Linux kernel coding style**:

- **Indentation**: Tabs (8 spaces wide)
- **Line length**: 80 columns maximum
- **Braces**: Opening brace on same line (except functions)
- **Naming**: `lowercase_with_underscores` for functions and variables
- **Comments**: `/* C-style */` only, no `//`

Key resources:
- [Linux kernel coding style](https://www.kernel.org/doc/html/latest/process/coding-style.html)
- Run `scripts/checkpatch.pl` from kernel source on your patches

For userspace code (`sbctl`, tests), follow the same conventions for consistency.

### Commit Message Format

Write clear, descriptive commit messages:

```
component: brief summary (50 chars or less)

Longer explanation of the change if needed. Wrap at 72 characters.
Explain what and why, not how (the code shows how).

- Bullet points are fine for listing changes
- Keep each point concise

Signed-off-by: Your Name <your.email@example.com>
```

Examples of good prefixes:
- `uprobe: fix race condition in handler registration`
- `sysfs: add pid filter attribute`
- `tests: add delay accuracy test`
- `docs: update interface specification`

### Testing Requirements

Before submitting a pull request:

1. **Tier 1 (Required)**: Userspace unit tests must pass
   ```bash
   make tests
   ```

2. **Tier 2 (Required)**: Module must build without errors
   ```bash
   make modules
   ```

3. **Tier 3 (If applicable)**: Integration tests should pass
   ```bash
   sudo ./tests/integration_test.sh
   ```

If you cannot run Tier 3 tests (requires root, specific kernel), note this in your PR. Maintainers will test on appropriate systems.

## Code Review

All submissions require review. Expect feedback on:

- Correctness and safety (kernel code must not crash or leak)
- Coding style compliance
- Test coverage
- Documentation updates

Be patient and responsive to feedback. Multiple review rounds are normal.

## License

By contributing, you agree that your contributions will be licensed under the **GPL-2.0** license.

All new source files must include the SPDX license identifier:

```c
// SPDX-License-Identifier: GPL-2.0
```

## Getting Help

- **Questions**: Open a [discussion](../../discussions) or issue
- **Security issues**: See SECURITY.md (do not open public issues)

## Recognition

Contributors are valued members of our community. Significant contributors may be acknowledged in release notes.
