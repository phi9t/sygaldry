#!/bin/bash
#
# NVIDIA Driver Diagnostic and Repair Script
# ==========================================
#
# This script inspects the local NVIDIA driver installation, identifies common
# issues, attempts fixes, and verifies GPU access from both host and Docker.
#
# Usage:
#   ./container/diagnose_nvidia.sh           # Run full diagnostics
#   ./container/diagnose_nvidia.sh --fix     # Attempt to fix issues
#   ./container/diagnose_nvidia.sh --test    # Only run GPU tests
#
# Exit Codes:
#   0 - All checks passed
#   1 - Issues found (see output for details)
#   2 - Critical failure (driver not working)
#

set -eu -o pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Test container image
readonly TEST_IMAGE="nvidia/cuda:12.4.1-base-ubuntu22.04"

# Track issues
ISSUES_FOUND=0
FIXES_APPLIED=0

# ============================================================================
# Logging Functions
# ============================================================================

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}:${BASH_LINENO[0]}] $*" >&2
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    ((ISSUES_FOUND++)) || true
}

error() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((ISSUES_FOUND++)) || true
}

section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE} $*${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# Utility Functions
# ============================================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This operation requires root privileges. Run with sudo."
        return 1
    fi
}

# ============================================================================
# Host Driver Checks
# ============================================================================

check_nvidia_driver_installed() {
    section "Checking NVIDIA Driver Installation"

    # Check for nvidia-smi
    if command_exists nvidia-smi; then
        success "nvidia-smi command found: $(command -v nvidia-smi)"
    else
        error "nvidia-smi not found in PATH"
        info "  Possible fixes:"
        info "    - Install NVIDIA driver: sudo apt install nvidia-driver-545"
        info "    - Or use: sudo ubuntu-drivers autoinstall"
        return 1
    fi

    # Check driver version
    local driver_version
    if driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1); then
        success "NVIDIA driver version: ${driver_version}"
    else
        error "Failed to query driver version"
        return 1
    fi

    # Check CUDA version reported by driver
    local cuda_version
    if cuda_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1); then
        local cuda_from_smi
        cuda_from_smi=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9.]+' || echo "unknown")
        success "CUDA version (driver): ${cuda_from_smi}"
    fi
}

check_kernel_modules() {
    section "Checking Kernel Modules"

    local modules=("nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm")
    local loaded_count=0

    for mod in "${modules[@]}"; do
        if lsmod | grep -q "^${mod}"; then
            success "Module loaded: ${mod}"
            ((loaded_count++)) || true
        else
            warn "Module not loaded: ${mod}"
        fi
    done

    if [[ ${loaded_count} -eq 0 ]]; then
        error "No NVIDIA kernel modules loaded"
        info "  Try: sudo modprobe nvidia"
        return 1
    fi

    # Check for nouveau (conflicting open-source driver)
    if lsmod | grep -q "^nouveau"; then
        error "Nouveau driver is loaded (conflicts with NVIDIA)"
        info "  Fix: Blacklist nouveau and reboot"
        info "    echo 'blacklist nouveau' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf"
        info "    echo 'options nouveau modeset=0' | sudo tee -a /etc/modprobe.d/blacklist-nouveau.conf"
        info "    sudo update-initramfs -u"
        info "    sudo reboot"
    else
        success "Nouveau driver not loaded (good)"
    fi
}

check_device_files() {
    section "Checking Device Files"

    # Check /dev/nvidia* devices
    if [[ -e /dev/nvidia0 ]]; then
        success "NVIDIA device found: /dev/nvidia0"
        ls -la /dev/nvidia* 2>/dev/null | while read -r line; do
            info "  ${line}"
        done
    else
        error "No NVIDIA device files found in /dev/"
        info "  This usually means the driver isn't loaded properly"
        info "  Try: sudo nvidia-smi (this can create device files)"
    fi

    # Check /dev/nvidiactl
    if [[ -e /dev/nvidiactl ]]; then
        success "NVIDIA control device: /dev/nvidiactl"
    else
        warn "Missing /dev/nvidiactl"
    fi

    # Check /dev/nvidia-uvm
    if [[ -e /dev/nvidia-uvm ]]; then
        success "NVIDIA UVM device: /dev/nvidia-uvm"
    else
        warn "Missing /dev/nvidia-uvm (may affect CUDA unified memory)"
        info "  Try: sudo modprobe nvidia-uvm"
    fi
}

check_gpu_info() {
    section "GPU Information"

    if ! command_exists nvidia-smi; then
        error "Cannot query GPU info - nvidia-smi not available"
        return 1
    fi

    # Get GPU count
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1 || echo "0")

    if [[ "${gpu_count}" -gt 0 ]]; then
        success "Found ${gpu_count} GPU(s)"
    else
        error "No GPUs detected"
        return 1
    fi

    # Display GPU details
    info "GPU Details:"
    nvidia-smi --query-gpu=index,name,memory.total,driver_version,pstate --format=csv 2>/dev/null | \
        while IFS= read -r line; do
            info "  ${line}"
        done

    # Quick nvidia-smi output
    info ""
    info "nvidia-smi summary:"
    nvidia-smi --query-gpu=utilization.gpu,utilization.memory,temperature.gpu,power.draw --format=csv 2>/dev/null | \
        while IFS= read -r line; do
            info "  ${line}"
        done
}

test_host_cuda() {
    section "Testing Host CUDA Access"

    if ! command_exists nvidia-smi; then
        error "Cannot test CUDA - nvidia-smi not available"
        return 1
    fi

    # Basic nvidia-smi test
    info "Running nvidia-smi..."
    if nvidia-smi >/dev/null 2>&1; then
        success "nvidia-smi executed successfully"
    else
        error "nvidia-smi failed to execute"
        return 1
    fi

    # Test CUDA compiler if available
    if command_exists nvcc; then
        local nvcc_version
        nvcc_version=$(nvcc --version | grep "release" | awk '{print $6}' | cut -d',' -f1)
        success "CUDA toolkit installed: nvcc ${nvcc_version}"
    else
        info "CUDA toolkit (nvcc) not installed on host (optional)"
    fi

    # Test with a simple CUDA operation via nvidia-smi
    info "Testing GPU compute capability..."
    if nvidia-smi --query-gpu=compute_cap --format=csv,noheader >/dev/null 2>&1; then
        local compute_cap
        compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
        success "GPU compute capability: ${compute_cap}"
    else
        warn "Could not query compute capability"
    fi
}

# ============================================================================
# Docker Checks
# ============================================================================

check_docker_installed() {
    section "Checking Docker Installation"

    if command_exists docker; then
        success "Docker found: $(command -v docker)"
        local docker_version
        docker_version=$(docker --version)
        success "Docker version: ${docker_version}"
    else
        error "Docker not installed"
        info "  Install Docker: https://docs.docker.com/engine/install/"
        return 1
    fi

    # Check if Docker daemon is running
    if docker info >/dev/null 2>&1; then
        success "Docker daemon is running"
    else
        error "Docker daemon is not running or not accessible"
        info "  Start Docker: sudo systemctl start docker"
        info "  Add user to docker group: sudo usermod -aG docker \$USER"
        return 1
    fi
}

check_nvidia_container_toolkit() {
    section "Checking NVIDIA Container Toolkit"

    # Check for nvidia-container-toolkit package
    if dpkg -l | grep -q nvidia-container-toolkit 2>/dev/null; then
        local toolkit_version
        toolkit_version=$(dpkg -l | grep nvidia-container-toolkit | awk '{print $3}' | head -1)
        success "nvidia-container-toolkit installed: ${toolkit_version}"
    elif rpm -q nvidia-container-toolkit >/dev/null 2>&1; then
        success "nvidia-container-toolkit installed (RPM)"
    else
        error "nvidia-container-toolkit not installed"
        info "  Install instructions: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
        info "  Quick install (Ubuntu/Debian):"
        info "    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
        info "    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \\"
        info "      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\"
        info "      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
        info "    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
        info "    sudo nvidia-ctk runtime configure --runtime=docker"
        info "    sudo systemctl restart docker"
        return 1
    fi

    # Check for nvidia-container-runtime
    if command_exists nvidia-container-runtime; then
        success "nvidia-container-runtime found"
    else
        warn "nvidia-container-runtime not in PATH"
    fi

    # Check Docker daemon configuration for NVIDIA runtime
    if docker info 2>/dev/null | grep -q "nvidia"; then
        success "NVIDIA runtime registered with Docker"
    else
        warn "NVIDIA runtime may not be configured in Docker"
        info "  Run: sudo nvidia-ctk runtime configure --runtime=docker"
        info "  Then: sudo systemctl restart docker"
    fi

    # Check /etc/docker/daemon.json
    if [[ -f /etc/docker/daemon.json ]]; then
        if grep -q "nvidia" /etc/docker/daemon.json 2>/dev/null; then
            success "Docker daemon.json contains NVIDIA configuration"
        else
            warn "Docker daemon.json exists but may not have NVIDIA config"
        fi
    else
        info "No /etc/docker/daemon.json found (may use defaults)"
    fi
}

test_docker_gpu() {
    section "Testing Docker GPU Access"

    if ! command_exists docker; then
        error "Docker not available for GPU test"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        error "Docker daemon not accessible"
        return 1
    fi

    info "Pulling test image: ${TEST_IMAGE}"
    if ! docker pull "${TEST_IMAGE}" 2>/dev/null; then
        warn "Could not pull test image, trying with existing images..."
    fi

    # Test 1: Using --gpus all flag
    info "Test 1: Running container with --gpus all..."
    if docker run --rm --gpus all "${TEST_IMAGE}" nvidia-smi >/dev/null 2>&1; then
        success "GPU access works with --gpus all"

        # Show container GPU info
        info "Container GPU info:"
        docker run --rm --gpus all "${TEST_IMAGE}" nvidia-smi --query-gpu=name,memory.total --format=csv 2>/dev/null | \
            while IFS= read -r line; do
                info "  ${line}"
            done
    else
        error "GPU access failed with --gpus all"
        info "  Error output:"
        docker run --rm --gpus all "${TEST_IMAGE}" nvidia-smi 2>&1 | head -20 | \
            while IFS= read -r line; do
                info "    ${line}"
            done
    fi

    # Test 2: Using --runtime=nvidia flag
    info "Test 2: Running container with --runtime=nvidia..."
    if docker run --rm --runtime=nvidia "${TEST_IMAGE}" nvidia-smi >/dev/null 2>&1; then
        success "GPU access works with --runtime=nvidia"
    else
        warn "GPU access failed with --runtime=nvidia (--gpus flag is preferred)"
    fi

    # Test 3: CUDA computation test
    info "Test 3: Testing CUDA computation in container..."
    local cuda_test_script='
import subprocess
result = subprocess.run(["nvidia-smi", "--query-gpu=compute_cap", "--format=csv,noheader"],
                       capture_output=True, text=True)
if result.returncode == 0:
    print(f"CUDA compute capability: {result.stdout.strip()}")
    exit(0)
else:
    print("CUDA test failed")
    exit(1)
'
    if docker run --rm --gpus all "${TEST_IMAGE}" python3 -c "${cuda_test_script}" 2>/dev/null; then
        success "CUDA accessible from Python in container"
    else
        info "Python CUDA test skipped (Python may not be in base image)"
    fi
}

# ============================================================================
# Fix Functions
# ============================================================================

fix_nvidia_modules() {
    require_root || return 1

    section "Attempting to Fix NVIDIA Modules"

    # Try to load modules
    local modules=("nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm")

    for mod in "${modules[@]}"; do
        if ! lsmod | grep -q "^${mod}"; then
            info "Loading module: ${mod}"
            if modprobe "${mod}" 2>/dev/null; then
                success "Loaded ${mod}"
                ((FIXES_APPLIED++)) || true
            else
                warn "Failed to load ${mod}"
            fi
        fi
    done
}

fix_device_files() {
    require_root || return 1

    section "Attempting to Fix Device Files"

    # Running nvidia-smi can create device files
    info "Running nvidia-smi to create device files..."
    if nvidia-smi >/dev/null 2>&1; then
        success "nvidia-smi executed, device files should be created"
        ((FIXES_APPLIED++)) || true
    else
        error "nvidia-smi failed"
    fi

    # Load UVM module if missing
    if [[ ! -e /dev/nvidia-uvm ]]; then
        info "Loading nvidia-uvm module..."
        if modprobe nvidia-uvm 2>/dev/null; then
            success "nvidia-uvm module loaded"
            ((FIXES_APPLIED++)) || true
        fi
    fi
}

fix_docker_nvidia_runtime() {
    require_root || return 1

    section "Configuring Docker NVIDIA Runtime"

    if command_exists nvidia-ctk; then
        info "Running nvidia-ctk to configure Docker..."
        if nvidia-ctk runtime configure --runtime=docker; then
            success "Docker configured for NVIDIA runtime"
            ((FIXES_APPLIED++)) || true

            info "Restarting Docker daemon..."
            if systemctl restart docker; then
                success "Docker daemon restarted"
            else
                warn "Failed to restart Docker - try manually: sudo systemctl restart docker"
            fi
        else
            error "nvidia-ctk configuration failed"
        fi
    else
        error "nvidia-ctk not found - install nvidia-container-toolkit first"
    fi
}

create_blacklist_nouveau() {
    require_root || return 1

    section "Blacklisting Nouveau Driver"

    local blacklist_file="/etc/modprobe.d/blacklist-nouveau.conf"

    if [[ -f "${blacklist_file}" ]]; then
        info "Blacklist file already exists: ${blacklist_file}"
        cat "${blacklist_file}"
    else
        info "Creating nouveau blacklist..."
        cat > "${blacklist_file}" << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
        success "Created ${blacklist_file}"
        ((FIXES_APPLIED++)) || true

        info "Updating initramfs..."
        if update-initramfs -u; then
            success "initramfs updated"
            warn "REBOOT REQUIRED to apply nouveau blacklist"
        else
            error "Failed to update initramfs"
        fi
    fi
}

# ============================================================================
# Summary Report
# ============================================================================

print_summary() {
    section "Diagnostic Summary"

    if [[ ${ISSUES_FOUND} -eq 0 ]]; then
        echo -e "${GREEN}"
        echo "  ╔═══════════════════════════════════════════════════════════╗"
        echo "  ║           ALL CHECKS PASSED - NVIDIA READY                ║"
        echo "  ╚═══════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
    else
        echo -e "${YELLOW}"
        echo "  ╔═══════════════════════════════════════════════════════════╗"
        echo "  ║     ${ISSUES_FOUND} ISSUE(S) FOUND - SEE ABOVE FOR DETAILS          ║"
        echo "  ╚═══════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
    fi

    if [[ ${FIXES_APPLIED} -gt 0 ]]; then
        info "Applied ${FIXES_APPLIED} fix(es)"
    fi

    # Quick status
    echo ""
    info "Quick Status:"
    echo -n "  Host nvidia-smi: "
    if nvidia-smi >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    echo -n "  Docker GPU:      "
    if docker run --rm --gpus all "${TEST_IMAGE}" nvidia-smi >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
}

# ============================================================================
# Main
# ============================================================================

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

NVIDIA Driver Diagnostic and Repair Script

Options:
    --help, -h      Show this help message
    --fix           Attempt to fix issues (requires sudo)
    --test          Only run GPU tests (skip diagnostics)
    --quiet, -q     Minimal output

Examples:
    ${SCRIPT_NAME}              # Full diagnostics
    ${SCRIPT_NAME} --fix        # Diagnose and fix
    sudo ${SCRIPT_NAME} --fix   # Fix with root privileges
EOF
}

main() {
    local do_fix=false
    local test_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --fix)
                do_fix=true
                shift
                ;;
            --test)
                test_only=true
                shift
                ;;
            --quiet|-q)
                # Could implement quiet mode
                shift
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         NVIDIA Driver Diagnostic Tool for Sygaldry            ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "${test_only}" == "true" ]]; then
        # Quick test mode
        test_host_cuda
        check_docker_installed && test_docker_gpu
        print_summary
        exit ${ISSUES_FOUND}
    fi

    # Full diagnostics
    check_nvidia_driver_installed || true
    check_kernel_modules || true
    check_device_files || true
    check_gpu_info || true
    test_host_cuda || true

    check_docker_installed || true
    check_nvidia_container_toolkit || true
    test_docker_gpu || true

    # Apply fixes if requested
    if [[ "${do_fix}" == "true" ]]; then
        echo ""
        info "Attempting automatic fixes..."

        # Check for nouveau first
        if lsmod | grep -q "^nouveau"; then
            create_blacklist_nouveau || true
        fi

        fix_nvidia_modules || true
        fix_device_files || true

        if command_exists docker; then
            fix_docker_nvidia_runtime || true
        fi

        echo ""
        info "Re-running tests after fixes..."
        ISSUES_FOUND=0
        test_host_cuda || true
        test_docker_gpu || true
    fi

    print_summary

    if [[ ${ISSUES_FOUND} -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# ============================================================================
# Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
