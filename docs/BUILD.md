# Building on ARM64

This document describes the procedure for building the speed-bump kernel module natively on ARM64 systems.

## Prerequisites

- Linux kernel 6.x with kernel-devel package installed
- Clang 19.x compiler (kernel requirement)
- LLVM linker (ld.lld)
- dwarves package (provides pahole for BTF generation)

## Known Issues

### 1. kernel-devel Ships x86_64 Host Tools

The kernel-devel package for ARM64 incorrectly contains x86_64 binaries for kernel build tools.
Symptom: Exec format error when running fixdep, modpost, or genksyms.
Solution: Rebuild from source (see Step 2 below).

### 2. Clang 19 Required

The kernel was built with clang 19. Download LLVM 19 for aarch64.

### 3. Missing GLIBCXX_3.4.30

Downloaded clang 19 may need newer libstdc++. Use CUDA toolkit libstdc++ via LD_LIBRARY_PATH.

### 4. Missing autoconf.h or rustc_cfg

Regenerate autoconf.h with make oldconfig && make prepare.
Create empty rustc_cfg: touch scripts/rustc_cfg

## Build Procedure

### Step 1: Identify Kernel Build Directory

KDIR=/lib/modules/$(uname -r)/build

### Step 2: Rebuild Host Tools

Rebuild the x86_64 binaries as native ARM64:

cd $KDIR
gcc -o scripts/basic/fixdep scripts/basic/fixdep.c
gcc -o scripts/mod/modpost scripts/mod/modpost.c scripts/mod/file2alias.c scripts/mod/sumversion.c
gcc -o scripts/genksyms/genksyms scripts/genksyms/genksyms.c scripts/genksyms/parse.tab.c scripts/genksyms/lex.lex.c

### Step 3: Set Up Clang 19

Download LLVM 19 for aarch64 from github.com/llvm/llvm-project/releases
export PATH=/path/to/llvm-19/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH  # for GLIBCXX

### Step 4: Build the Module

cd /path/to/speed-bump-native-kmod
make CC=clang LD=ld.lld CONFIG_DEBUG_INFO_BTF_MODULES= modules

## Troubleshooting

### Exec format error
Rebuild host tools as described in Step 2.

### GLIBCXX_3.4.30 not found
Set LD_LIBRARY_PATH to a directory with newer libstdc++.

### autoconf.h not found
Run make oldconfig && make prepare in kernel build directory.

### rustc_cfg not found
Run: touch /lib/modules/$(uname -r)/build/scripts/rustc_cfg

### BTF errors
Add CONFIG_DEBUG_INFO_BTF_MODULES= to make command.
