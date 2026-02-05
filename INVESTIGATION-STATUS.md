# Investigation: GitHub Readiness for speed-bump-native-kmod

**Status**: In Progress
**Started**: 2026-02-05
**Hypothesis**: The project has gaps preventing it from being a credible, usable GitHub repository for a kernel module.

**Terminal Goal**: Make the repo "clone → build → test → contribute" ready for the open-source community.

**Falsification criteria**: If all required artifacts exist and are complete, the hypothesis is falsified.

---

## Checklist: Required for GitHub-Ready Kernel Module

### License & Legal
- [x] LICENSE file (GPL-2.0-only for kernel modules) - EXISTS
- [x] SPDX identifiers in source files - EXISTS (all .c and .h files)
- [ ] Copyright headers - PARTIAL (no author/year in headers)

### GitHub Artifacts
- [x] README.md - EXISTS (good quality)
- [ ] CONTRIBUTING.md - MISSING
- [ ] CODE_OF_CONDUCT.md - MISSING
- [x] .gitignore - EXISTS (comprehensive)
- [ ] Issue templates (.github/ISSUE_TEMPLATE/) - MISSING
- [ ] Pull request template (.github/PULL_REQUEST_TEMPLATE.md) - MISSING

### Documentation
- [x] Build instructions - EXISTS (in README)
- [x] Testing guide - EXISTS (docs/TESTING.md - comprehensive!)
- [ ] Architecture support matrix - MISSING
- [ ] Troubleshooting guide - PARTIAL (in TESTING.md)

### Testing Infrastructure
- [x] Tier 1: Userspace unit tests - EXISTS (tests/*.c)
- [x] Tier 2: Module compilation check - EXISTS (make modules)
- [x] Tier 3: Integration test script - EXISTS (tests/integration_test.sh)
- [ ] Automated QEMU setup script - MISSING (TESTING.md references ~/local/qemu/ which doesn't exist in repo)
- [ ] QEMU VM image or build instructions - MISSING
- [ ] CI/CD configuration (GitHub Actions) - MISSING

### Architecture Support
- [x] x86_64 tested - YES (verified in QEMU)
- [ ] ARM64 tested - NOT TESTED
- [ ] Architecture matrix documented - MISSING

---

## Experiment Log

### Experiment 1: Audit existing files

**What we did**: Listed all files and checked their contents.

**Findings**:

| Category | Status | Notes |
|----------|--------|-------|
| LICENSE | ✓ Complete | GPL-2.0 full text |
| SPDX headers | ✓ Complete | All source files have SPDX-License-Identifier: GPL-2.0 |
| README | ✓ Good | Comprehensive, now includes PID filtering docs |
| TESTING.md | ✓ Excellent | 462 lines, three-tier testing strategy |
| .gitignore | ✓ Complete | Covers build artifacts, editors, .nbs/ |
| Unit tests | ✓ Working | test_delay, test_match, test_mock |
| Integration tests | ✓ Script exists | tests/integration_test.sh |
| CONTRIBUTING | ✗ Missing | No contribution guidelines |
| CODE_OF_CONDUCT | ✗ Missing | No community standards |
| .github/ | ✗ Missing | No issue/PR templates |
| QEMU automation | ✗ Missing | Manual setup required |
| ARM64 | ✗ Untested | README says "x86_64 only" |
| CI/CD | ✗ Missing | No GitHub Actions |

---

## Gap Analysis

### Critical Gaps (Blocks GitHub release)

1. **QEMU automation**: TESTING.md says "See ~/local/qemu/" but this doesn't exist in the repo. Someone cloning has no path to run integration tests.

2. **ARM64 support unknown**: README explicitly says "x86_64 only" but this may just be untested, not unsupported.

### Standard Gaps (Expected for professional repo)

3. **CONTRIBUTING.md**: How to submit patches, coding style, etc.

4. **CODE_OF_CONDUCT.md**: Community standards

5. **.github/ templates**: Issue and PR templates

6. **CI/CD**: GitHub Actions for automated builds/tests

### Nice-to-Have

7. **Copyright headers**: Source files have SPDX but no author/year

---

## Verdict

**Result**: Hypothesis confirmed - significant gaps exist.

**Key evidence**:
- No QEMU automation (critical for anyone cloning)
- ARM64 completely untested
- Missing standard GitHub artifacts (CONTRIBUTING, CODE_OF_CONDUCT, templates)
- No CI/CD

**Confidence**: High

---

## Remediation Plan

### Phase 1: QEMU Automation (Critical)

Create a comprehensive "one script does everything" solution:

```
scripts/
├── qemu-test.sh          # Main entry point - does everything
├── qemu/
│   ├── build-kernel.sh   # Build minimal kernel (x86_64 + arm64)
│   ├── build-rootfs.sh   # Build minimal rootfs with busybox
│   ├── launch-vm.sh      # Start QEMU with correct options
│   └── run-tests.sh      # Copy module, run integration tests
└── ci/
    └── github-actions.yml
```

**User experience**:
```bash
git clone <repo>
./scripts/qemu-test.sh        # Downloads/builds everything, runs tests
./scripts/qemu-test.sh arm64  # Same for ARM64
```

### Phase 2: ARM64 Testing

1. Test on actual ARM64 machine first (faster, more reliable)
2. Document ARM64 support status
3. Add ARM64 to QEMU automation (slow but works for CI)

### Phase 3: GitHub Artifacts

1. CONTRIBUTING.md - kernel coding style, patch submission
2. CODE_OF_CONDUCT.md - standard Contributor Covenant
3. .github/ISSUE_TEMPLATE/ - bug report, feature request
4. .github/PULL_REQUEST_TEMPLATE.md
5. .github/workflows/ci.yml - Tier 1 + Tier 2 only

### Phase 4: Documentation Updates

1. Update TESTING.md to reference scripts/qemu-test.sh
2. Add architecture support matrix
3. Remove reference to ~/local/qemu/

---

## Implementation Considerations

### QEMU Kernel Build

Options:
1. **Build from source**: Most flexible, but slow (~30 min first time)
2. **Use distro kernel**: Faster, but may not match user's kernel version
3. **Provide pre-built images**: Fastest, but hosting/versioning issues

Recommendation: Build from source with caching. First run is slow, subsequent runs use cached kernel.

### Minimal Rootfs

Options:
1. **Busybox + static binaries**: Tiny (~5MB), fast boot
2. **Alpine Linux**: Small (~50MB), has package manager
3. **Fedora/Ubuntu cloud image**: Large (~500MB), familiar

Recommendation: Busybox-based minimal rootfs. Only needs: init, shell, insmod, test binaries.

### ARM64 in QEMU

- `qemu-system-aarch64 -M virt -cpu cortex-a57`
- Full emulation on x86 is ~10-50x slower than native
- CI may need 30+ minute timeout for ARM64 tests
- Alternative: Skip ARM64 in CI, require manual testing
