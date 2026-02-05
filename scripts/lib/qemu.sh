#!/bin/bash
# qemu.sh - QEMU VM launch and control library for speed-bump kernel module testing
#
# Functions for launching QEMU VMs with kernel and rootfs, running commands
# inside the VM, and capturing output/exit codes.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-60}"  # Default timeout in seconds

# State
QEMU_PID=""
QEMU_OUTPUT_FILE=""
QEMU_HOST_DIR=""

# Logging
qemu_log_info() { echo "[INFO] $*"; }
qemu_log_error() { echo "[ERROR] $*" >&2; }
qemu_log_ok() { echo "[OK] $*"; }
qemu_log_warn() { echo "[WARN] $*" >&2; }

# Get current architecture
qemu_get_arch() {
    uname -m
}

# Check if QEMU is available for the current architecture
qemu_check_deps() {
    local arch
    arch=$(qemu_get_arch)
    local qemu_bin

    case "${arch}" in
        x86_64)
            qemu_bin="qemu-system-x86_64"
            ;;
        aarch64)
            qemu_bin="qemu-system-aarch64"
            ;;
        *)
            qemu_log_error "Unsupported architecture: ${arch}"
            return 1
            ;;
    esac

    if command -v "${qemu_bin}" &>/dev/null; then
        local version
        version=$("${qemu_bin}" --version 2>/dev/null | head -1 || echo "unknown")
        qemu_log_ok "QEMU found: ${qemu_bin}"
        qemu_log_info "Version: ${version}"
        return 0
    else
        qemu_log_error "QEMU not found: ${qemu_bin}"
        qemu_log_error "Install with:"
        qemu_log_error "  Debian/Ubuntu: sudo apt-get install qemu-system-x86"
        qemu_log_error "  RHEL/CentOS:   sudo dnf install qemu-system-x86"
        return 1
    fi
}

# Get QEMU binary for current architecture
qemu_get_binary() {
    local arch
    arch=$(qemu_get_arch)

    case "${arch}" in
        x86_64)
            echo "qemu-system-x86_64"
            ;;
        aarch64)
            echo "qemu-system-aarch64"
            ;;
        *)
            return 1
            ;;
    esac
}

# Get QEMU machine arguments for current architecture
qemu_get_machine_args() {
    local arch
    arch=$(qemu_get_arch)

    case "${arch}" in
        x86_64)
            # No special machine args needed for x86_64
            echo ""
            ;;
        aarch64)
            echo "-M virt -cpu cortex-a57"
            ;;
        *)
            return 1
            ;;
    esac
}

# Get console device for current architecture
qemu_get_console() {
    local arch
    arch=$(qemu_get_arch)

    case "${arch}" in
        x86_64)
            echo "ttyS0"
            ;;
        aarch64)
            echo "ttyAMA0"
            ;;
        *)
            echo "ttyS0"
            ;;
    esac
}

# Launch QEMU VM
# Arguments:
#   $1 - kernel image path
#   $2 - initramfs path
#   $3 - host directory to share via 9p (optional)
#   $4 - extra kernel cmdline args (optional)
qemu_launch() {
    local kernel_image="$1"
    local initramfs="$2"
    local host_dir="${3:-}"
    local extra_cmdline="${4:-}"

    # Validate inputs
    if [[ ! -f "${kernel_image}" ]]; then
        qemu_log_error "Kernel image not found: ${kernel_image}"
        return 1
    fi

    if [[ ! -f "${initramfs}" ]]; then
        qemu_log_error "Initramfs not found: ${initramfs}"
        return 1
    fi

    # Check QEMU availability
    if ! qemu_check_deps; then
        return 1
    fi

    local qemu_bin
    qemu_bin=$(qemu_get_binary)

    local machine_args
    machine_args=$(qemu_get_machine_args)

    local console
    console=$(qemu_get_console)

    # Build command line
    local cmdline="console=${console} quiet"
    if [[ -n "${extra_cmdline}" ]]; then
        cmdline="${cmdline} ${extra_cmdline}"
    fi

    # Create output file
    QEMU_OUTPUT_FILE=$(mktemp /tmp/qemu-output.XXXXXX)

    # Build QEMU command
    local qemu_cmd=(
        "${qemu_bin}"
    )

    # Add machine args if present
    if [[ -n "${machine_args}" ]]; then
        # shellcheck disable=SC2206
        qemu_cmd+=(${machine_args})
    fi

    qemu_cmd+=(
        -kernel "${kernel_image}"
        -initrd "${initramfs}"
        -append "${cmdline}"
        -nographic
        -m 512M
        -no-reboot
    )

    # Add 9p share if host directory specified
    if [[ -n "${host_dir}" ]]; then
        if [[ ! -d "${host_dir}" ]]; then
            qemu_log_error "Host directory not found: ${host_dir}"
            return 1
        fi
        QEMU_HOST_DIR="${host_dir}"
        qemu_cmd+=(
            -virtfs "local,path=${host_dir},mount_tag=hostshare,security_model=none"
        )
        qemu_log_info "9p share enabled: ${host_dir} -> /mnt/host"
    fi

    qemu_log_info "Launching QEMU..."
    qemu_log_info "  Kernel: ${kernel_image}"
    qemu_log_info "  Initramfs: ${initramfs}"
    qemu_log_info "  Output: ${QEMU_OUTPUT_FILE}"

    # Launch QEMU in background
    "${qemu_cmd[@]}" > "${QEMU_OUTPUT_FILE}" 2>&1 &
    QEMU_PID=$!

    qemu_log_ok "QEMU started with PID ${QEMU_PID}"

    # Brief pause to let QEMU start
    sleep 0.5

    # Check if still running
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
        qemu_log_error "QEMU exited immediately"
        qemu_log_error "Output:"
        cat "${QEMU_OUTPUT_FILE}" >&2
        QEMU_PID=""
        return 1
    fi

    return 0
}

# Wait for QEMU to finish and return output
# Arguments:
#   $1 - timeout in seconds (optional, default: QEMU_TIMEOUT)
qemu_wait() {
    local timeout="${1:-${QEMU_TIMEOUT}}"

    if [[ -z "${QEMU_PID}" ]]; then
        qemu_log_error "No QEMU process running"
        return 1
    fi

    qemu_log_info "Waiting for QEMU (timeout: ${timeout}s)..."

    local waited=0
    while kill -0 "${QEMU_PID}" 2>/dev/null; do
        if [[ ${waited} -ge ${timeout} ]]; then
            qemu_log_warn "QEMU timed out after ${timeout}s, killing..."
            kill -9 "${QEMU_PID}" 2>/dev/null || true
            QEMU_PID=""
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Wait for process to fully exit
    wait "${QEMU_PID}" 2>/dev/null || true
    QEMU_PID=""

    qemu_log_ok "QEMU finished"
    return 0
}

# Get QEMU output
qemu_get_output() {
    if [[ -n "${QEMU_OUTPUT_FILE}" ]] && [[ -f "${QEMU_OUTPUT_FILE}" ]]; then
        cat "${QEMU_OUTPUT_FILE}"
    fi
}

# Shutdown QEMU cleanly
qemu_shutdown() {
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        qemu_log_info "Shutting down QEMU (PID ${QEMU_PID})..."

        # Try graceful shutdown first
        kill -TERM "${QEMU_PID}" 2>/dev/null || true
        sleep 1

        # Force kill if still running
        if kill -0 "${QEMU_PID}" 2>/dev/null; then
            qemu_log_warn "Force killing QEMU..."
            kill -9 "${QEMU_PID}" 2>/dev/null || true
        fi

        wait "${QEMU_PID}" 2>/dev/null || true
        qemu_log_ok "QEMU stopped"
    fi

    QEMU_PID=""

    # Cleanup output file
    if [[ -n "${QEMU_OUTPUT_FILE}" ]] && [[ -f "${QEMU_OUTPUT_FILE}" ]]; then
        rm -f "${QEMU_OUTPUT_FILE}"
        QEMU_OUTPUT_FILE=""
    fi

    # Cleanup host directory if we created it
    if [[ -n "${QEMU_HOST_DIR}" ]]; then
        QEMU_HOST_DIR=""
    fi
}

# Run a command inside the VM
# This creates a test script, launches QEMU with autopower, and captures output
# Arguments:
#   $1 - kernel image path
#   $2 - initramfs path
#   $3 - command to run
#   $4 - timeout (optional)
# Returns: exit code from the command
qemu_run_command() {
    local kernel_image="$1"
    local initramfs="$2"
    local command="$3"
    local timeout="${4:-${QEMU_TIMEOUT}}"

    # Create temporary host directory
    local host_dir
    host_dir=$(mktemp -d /tmp/qemu-host.XXXXXX)

    # Create test script
    cat > "${host_dir}/run-tests.sh" << EOF
#!/bin/sh
# Auto-generated test script
${command}
EOF
    chmod +x "${host_dir}/run-tests.sh"

    qemu_log_info "Running command in VM: ${command}"

    # Launch with autopower for automatic shutdown
    if ! qemu_launch "${kernel_image}" "${initramfs}" "${host_dir}" "autopower"; then
        rm -rf "${host_dir}"
        return 1
    fi

    # Wait for completion
    if ! qemu_wait "${timeout}"; then
        qemu_log_error "Command timed out"
        qemu_shutdown
        rm -rf "${host_dir}"
        return 1
    fi

    # Get output
    local output
    output=$(qemu_get_output)

    # Parse exit code from output
    local exit_code=1
    if echo "${output}" | grep -q "TEST_EXIT_CODE="; then
        exit_code=$(echo "${output}" | grep "TEST_EXIT_CODE=" | tail -1 | sed 's/.*TEST_EXIT_CODE=//' | tr -d '[:space:]')
        qemu_log_info "Command exit code: ${exit_code}"
    else
        qemu_log_warn "Could not parse exit code from VM output"
    fi

    # Cleanup
    rm -rf "${host_dir}"
    qemu_shutdown

    # Output the VM output (excluding our markers)
    echo "${output}"

    return "${exit_code}"
}

# Run integration test suite in VM
# Arguments:
#   $1 - kernel image path
#   $2 - initramfs path
#   $3 - test directory (contains run-tests.sh or individual test scripts)
#   $4 - timeout (optional)
qemu_run_tests() {
    local kernel_image="$1"
    local initramfs="$2"
    local test_dir="$3"
    local timeout="${4:-${QEMU_TIMEOUT}}"

    if [[ ! -d "${test_dir}" ]]; then
        qemu_log_error "Test directory not found: ${test_dir}"
        return 1
    fi

    # Check for run-tests.sh in test directory
    if [[ ! -x "${test_dir}/run-tests.sh" ]]; then
        qemu_log_error "No executable run-tests.sh found in ${test_dir}"
        return 1
    fi

    qemu_log_info "Running test suite from: ${test_dir}"

    # Launch with autopower for automatic shutdown
    if ! qemu_launch "${kernel_image}" "${initramfs}" "${test_dir}" "autopower"; then
        return 1
    fi

    # Wait for completion
    if ! qemu_wait "${timeout}"; then
        qemu_log_error "Tests timed out"
        qemu_shutdown
        return 1
    fi

    # Get output
    local output
    output=$(qemu_get_output)

    # Parse exit code
    local exit_code=1
    if echo "${output}" | grep -q "TEST_EXIT_CODE="; then
        exit_code=$(echo "${output}" | grep "TEST_EXIT_CODE=" | tail -1 | sed 's/.*TEST_EXIT_CODE=//' | tr -d '[:space:]')
    fi

    # Output results
    echo "${output}"

    # Cleanup
    qemu_shutdown

    if [[ "${exit_code}" -eq 0 ]]; then
        qemu_log_ok "All tests passed"
    else
        qemu_log_error "Tests failed with exit code: ${exit_code}"
    fi

    return "${exit_code}"
}

# Cleanup on script exit
qemu_cleanup() {
    qemu_shutdown
}

# Register cleanup trap
trap qemu_cleanup EXIT

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "QEMU library for speed-bump kernel module testing"
    echo ""
    echo "Functions available:"
    echo "  qemu_check_deps    - Check if QEMU is available"
    echo "  qemu_get_arch      - Get current architecture"
    echo "  qemu_launch        - Launch VM with kernel and initramfs"
    echo "  qemu_run_command   - Run a command in VM"
    echo "  qemu_shutdown      - Stop running VM"
    echo "  qemu_run_tests     - Run test suite in VM"
    echo ""
    echo "Checking QEMU availability..."
    qemu_check_deps || true
fi
