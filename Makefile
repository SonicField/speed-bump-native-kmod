KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# Auto-detect compiler used to build kernel
# Kernel modules must be built with the same toolchain as the kernel itself
# to avoid incompatible compiler flags (e.g., -fsplit-lto-unit) and linker issues.
#
# This extracts the compiler name from CONFIG_CC_VERSION_TEXT in the kernel's .config.
# Example: 'CONFIG_CC_VERSION_TEXT="clang version 19.1.3"' -> KERNEL_CC=clang
KERNEL_CC := $(shell grep 'CONFIG_CC_VERSION_TEXT' $(KDIR)/.config 2>/dev/null | \
	cut -d'"' -f2 | cut -d' ' -f1)

# Fallback to gcc if detection fails
ifeq ($(KERNEL_CC),)
    KERNEL_CC := gcc
endif

# Use LLVM linker (ld.lld) if kernel was built with clang
ifeq ($(KERNEL_CC),clang)
    KERNEL_LD := LD=ld.lld
else
    KERNEL_LD :=
endif

.PHONY: all modules userspace tests clean help

all: modules userspace

modules:
	$(MAKE) -C $(KDIR) M=$(PWD)/src CC=$(KERNEL_CC) $(KERNEL_LD) modules

userspace:
	$(CC) -DMOCK_KERNEL -o tests/test_mock tests/test_mock.c -lrt

tests: userspace
	$(MAKE) -C tests test

clean:
	$(MAKE) -C $(KDIR) M=$(PWD)/src clean
	rm -f tests/test_mock

help:
	@echo "Available targets:"
	@echo "  all       - Build kernel module and userspace tests"
	@echo "  modules   - Build kernel module only"
	@echo "  userspace - Build userspace tests only"
	@echo "  tests     - Build and run userspace tests"
	@echo "  clean     - Remove build artifacts"
