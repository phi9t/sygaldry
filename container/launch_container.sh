#!/bin/bash
#
# Sygaldry Container Launcher
# ==========================
#
# This script launches a Docker container with a complete development environment
# for the Sygaldry build system, which combines Bazel, Spack, and Docker for
# reproducible mixed-language builds with scientific computing dependencies.
#
# OVERVIEW
# --------
# The launcher provides:
# - XDG Base Directory compliant persistent storage
# - Project-isolated container environments
# - Automatic Docker image building and caching
# - GPU support for CUDA workloads
# - Spack repository management
# - Bazel build system integration
#
# USAGE
# -----
# Basic usage:
#   ./launch_container.sh                      # Start interactive shell
#   ./launch_container.sh bazel build //...   # Run specific command
#   ./launch_container.sh spack install python # Install packages
#   ./launch_container.sh --entrypoint=dev    # Use container/entrypoints/dev.sh
#
# Environment variables for customization:
#   SYGALDRY_PROJECT_ID=myproject          # Custom project identifier
#   SYGALDRY_IMAGE=myimage:tag             # Custom Docker image
#   SYGALDRY_GPU=false                     # Disable GPU support
#   SYGALDRY_ENTRYPOINT=dev                # Use container/entrypoints/dev.sh
#   BAZEL_VERSION=6.4.0                    # Bazel version
#   PYTHON_VERSION=3.12                    # Python version
#   RUST_VERSION=1.79.0                    # Rust version
#   GO_VERSION=1.21.5                      # Go version
#
# PERSISTENT STORAGE
# ------------------
# All persistent data is stored in XDG-compliant locations:
#   /mnt/data_infra/zephyr_container_infra/<project_id>/
#   ├── monorepo_home/     # User home directory in container
#   ├── spack_store/       # Spack package installations
#   ├── bazel_cache/       # Bazel build cache
#   ├── hf_cache/          # HuggingFace models and datasets
#   └── config/            # Configuration files
#
# SECURITY FEATURES
# ----------------
# - Non-root user execution (UID/GID mapping)
# - Read-only mounts where appropriate
# - Host network isolation options
# - Sandboxed build environments
#
# DEPENDENCIES
# ------------
# - Docker daemon running
# - NVIDIA Docker runtime (optional, for GPU support)
#
# AUTHOR: Sygaldry Development Team
# VERSION: 1.0
# LICENSE: MIT
#

set -eu -o pipefail

# ============================================================================
# Configuration and Constants
# ============================================================================
#
# This section defines all configuration constants and paths used throughout
# the script. Most values can be overridden via environment variables.
#

# Script and project paths (resolve symlinks to absolute paths)
SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
readonly SCRIPT_DIR
PROJECT_ROOT="$(realpath "${SCRIPT_DIR}/..")"
readonly PROJECT_ROOT

# XDG Base Directory Specification compliance (for defaults and overrides)
# These follow the XDG standard for data, cache, and config locations when used
readonly XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
readonly XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
readonly XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"

# Project identification
# PROJECT_ID determines the isolation namespace for this project's data
PROJECT_ID="${SYGALDRY_PROJECT_ID:-$(basename "${PROJECT_ROOT}")}"
readonly PROJECT_ID
readonly SYGALDRY_CONTAINER_ROOT="${SYGALDRY_CONTAINER_ROOT:-/mnt/data_infra/zephyr_container_infra/${PROJECT_ID}}"

# Host paths (shared host storage with project isolation)
# These are the persistent storage locations on the host system
readonly HOST_MONOREPO_HOME="${SYGALDRY_CONTAINER_ROOT}/monorepo_home"
readonly HOST_SPACK_STORE="${SYGALDRY_CONTAINER_ROOT}/spack_store"
readonly HOST_BAZEL_CACHE="${SYGALDRY_CONTAINER_ROOT}/bazel_cache"
readonly HOST_HF_CACHE="${SYGALDRY_CONTAINER_ROOT}/hf_cache"
readonly HOST_CONFIG_DIR="${SYGALDRY_CONTAINER_ROOT}/config"

# Container paths
# These are the mount points inside the Docker container
readonly CONTAINER_HOME="/home/kvothe"
readonly CONTAINER_SPACK_STORE="/opt/spack_store"
readonly CONTAINER_BAZEL_CACHE="/opt/bazel_cache"
readonly CONTAINER_HF_CACHE="/opt/hf_cache"
readonly CONTAINER_SPACK_SRC="/opt/spack_src"
readonly CONTAINER_WORKSPACE="/workspace"
readonly CONTAINER_ENTRYPOINT_DIR="/workspace/container/entrypoints"
readonly REQUIRED_CUDA_VERSION="${SYGALDRY_REQUIRED_CUDA_VERSION:-12.9}"

# Container configuration
# These control the Docker container behavior and user mapping
readonly CONTAINER_IMAGE="${SYGALDRY_IMAGE:-sygaldry/zephyr:base}"
readonly CONTAINER_USER="kvothe"
readonly CONTAINER_UID="${SYGALDRY_UID:-1000}"
readonly CONTAINER_GID="${SYGALDRY_GID:-1000}"

# Build configuration
# These specify the versions of build tools and languages
readonly BAZEL_VERSION="${BAZEL_VERSION:-6.4.0}"
readonly PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
readonly RUST_VERSION="${RUST_VERSION:-1.79.0}"
readonly GO_VERSION="${GO_VERSION:-1.21.5}"

# ============================================================================
# Helper Functions
# ============================================================================
#
# Utility functions for logging, error handling, and system operations
#

log() {
    # Get caller information for better debugging
    local caller_info=""
    if [[ "${BASH_VERSION:-}" ]]; then
        # Use bash-specific caller information
        local caller_line="${BASH_LINENO[0]:-unknown}"
        local caller_file="${BASH_SOURCE[1]:-unknown}"
        caller_file=$(basename "${caller_file}")
        caller_info="[${caller_file}:${caller_line}]"
    else
        # Fallback for non-bash shells
        caller_info="[$(basename "${BASH_SOURCE[0]:-unknown}")]"
    fi
    
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ${caller_info} $*" >&2
}

version_lt() {
    # Compare semantic-like versions "MAJOR.MINOR"
    local a="$1"
    local b="$2"
    local a_major="${a%%.*}"
    local a_minor="${a#*.}"
    local b_major="${b%%.*}"
    local b_minor="${b#*.}"
    if [[ "${a_major}" -lt "${b_major}" ]]; then
        return 0
    fi
    if [[ "${a_major}" -gt "${b_major}" ]]; then
        return 1
    fi
    if [[ "${a_minor:-0}" -lt "${b_minor:-0}" ]]; then
        return 0
    fi
    return 1
}

detect_host_cuda_version() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        return 1
    fi
    local cuda_line
    cuda_line="$(nvidia-smi 2>/dev/null | rg -o "CUDA Version: [0-9]+\\.[0-9]+" -m 1 || true)"
    if [[ -z "${cuda_line}" ]]; then
        return 1
    fi
    echo "${cuda_line##*CUDA Version: }"
}

error() {
    log "ERROR: $*"
    exit 1
}

# ============================================================================
# Path Resolution Utilities
# ============================================================================

resolve_mount_path() {
    # Resolve symlinks and return absolute path for Docker volume mounting
    # Creates the directory if it doesn't exist to ensure realpath works
    local path="$1"
    
    # Create parent directory if it doesn't exist
    local parent_dir
    parent_dir="$(dirname "${path}")"
    if [[ ! -d "${parent_dir}" ]]; then
        mkdir -p "${parent_dir}"
    fi
    
    # Create the directory if it doesn't exist
    if [[ ! -e "${path}" ]]; then
        mkdir -p "${path}"
    fi
    
    # Resolve symlinks and return absolute path
    realpath "${path}"
}

# ============================================================================
# System Validation
# ============================================================================

check_requirements() {
    log "Checking system requirements..."
    
    # Check Docker availability
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is not installed or not in PATH"
    fi
    
    # Check Docker daemon accessibility
    if ! docker info >/dev/null 2>&1; then
        error "Docker daemon is not running or not accessible"
    fi
    
    # Check NVIDIA runtime if GPU support requested
    if [[ "${SYGALDRY_GPU:-true}" == "true" ]]; then
        if ! docker info 2>/dev/null | grep -q nvidia; then
            log "WARNING: NVIDIA Docker runtime not detected. GPU support will be disabled."
        fi
    fi
    
    log "System requirements check passed"
}

# ============================================================================
# Host Environment Setup
# ============================================================================

setup_host_directories() {
    log "Setting up host directories..."
    
    # Create all required persistent storage directories
    local dirs=(
        "${HOST_MONOREPO_HOME}"
        "${HOST_SPACK_STORE}"
        "${HOST_BAZEL_CACHE}"
        "${HOST_HF_CACHE}"
        "${HOST_CONFIG_DIR}"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            log "Creating directory: ${dir}"
            mkdir -p "${dir}"
        fi
    done
}

# ============================================================================
# Docker Image Management
# ============================================================================

build_container_image() {
    log "Checking Docker image: ${CONTAINER_IMAGE}"
    
    # Check if image exists
    if docker image inspect "${CONTAINER_IMAGE}" >/dev/null 2>&1; then
        log "Docker image ${CONTAINER_IMAGE} already exists"
        
        # Check if we should rebuild (dockerfile is newer than image)
        local dockerfile_path="${SCRIPT_DIR}/dev_container.dockerfile"
        if [[ -f "${dockerfile_path}" ]]; then
            local dockerfile_mtime
            dockerfile_mtime=$(stat -c %Y "${dockerfile_path}" 2>/dev/null || echo 0)
            local image_created
            image_created=$(docker image inspect "${CONTAINER_IMAGE}" --format='{{.Created}}' 2>/dev/null)
            local image_timestamp
            image_timestamp=$(date -d "${image_created}" +%s 2>/dev/null || echo 0)
            
            if [[ ${dockerfile_mtime} -gt ${image_timestamp} ]]; then
                log "Dockerfile is newer than image, rebuilding..."
                build_image=true
            else
                build_image=false
            fi
        else
            build_image=false
        fi
    else
        log "Docker image ${CONTAINER_IMAGE} not found, building..."
        build_image=true
    fi
    
    # Build the image if needed
    if [[ "${build_image}" == "true" ]]; then
        local dockerfile_path="${SCRIPT_DIR}/dev_container.dockerfile"
        
        if [[ ! -f "${dockerfile_path}" ]]; then
            error "Dockerfile not found at ${dockerfile_path}"
        fi
        
        log "Building Docker image: ${CONTAINER_IMAGE}"
        log "Using Dockerfile: ${dockerfile_path}"
        
        # Get host UID/GID for user creation in container
        local host_uid
        host_uid=$(id -u)
        local host_gid
        host_gid=$(id -g)
        
        log "Building with host UID=${host_uid} GID=${host_gid}"
        
        # Build with build context at script directory
        if ! docker build \
            --file "${dockerfile_path}" \
            --tag "${CONTAINER_IMAGE}" \
            --build-arg "BAZEL_VERSION=${BAZEL_VERSION:-6.4.0}" \
            --build-arg "PYTHON_VERSION=${PYTHON_VERSION:-3.12}" \
            --build-arg "RUST_VERSION=${RUST_VERSION:-1.79.0}" \
            --build-arg "GO_VERSION=${GO_VERSION:-1.21.5}" \
            --build-arg "HOST_UID=${host_uid}" \
            --build-arg "HOST_GID=${host_gid}" \
            "${SCRIPT_DIR}"; then
            error "Failed to build Docker image"
        fi
        
        log "Successfully built Docker image: ${CONTAINER_IMAGE}"
    fi
}

# ============================================================================
# Docker Command Construction
# ============================================================================

build_docker_args() {
    local docker_args=()
    
    # Basic container configuration
    # --rm: Remove container when it exits
    # --init: Use init process for proper signal handling
    docker_args+=(
        "--rm"
        "--init"
    )
    if [[ -t 0 ]]; then
        docker_args+=(
            "--interactive"
            "--tty"
        )
    fi
    
    # Network and IPC configuration
    # --net=host: Use host network (for development convenience)
    # --ipc=host: Use host IPC namespace
    docker_args+=(
        "--net=host"
        "--ipc=host"
    )
    
    # User mapping for file permissions
    # Maps host user to container user for proper file ownership
    local host_uid
    host_uid=$(id -u)
    local host_gid
    host_gid=$(id -g)
    docker_args+=(
        "--user=${host_uid}:${host_gid}"
    )
    
    # Host user/group information
    # Mounts host user database for proper user resolution
    docker_args+=(
        "--volume=/etc/passwd:/etc/passwd:ro"
        "--volume=/etc/group:/etc/group:ro"
    )
    
    # XDG-compliant volume mounts with symlink resolution
    # These provide persistent storage across container restarts
    # Parameters: resolved_monorepo_home resolved_spack_store resolved_bazel_cache resolved_hf_cache resolved_project_root entrypoint_path
    local resolved_monorepo_home="$1"
    local resolved_spack_store="$2"
    local resolved_bazel_cache="$3"
    local resolved_hf_cache="$4"
    local resolved_project_root="$5"
    local entrypoint_path="$6"

    docker_args+=(
        "--volume=${resolved_monorepo_home}:${CONTAINER_HOME}"
        "--volume=${resolved_spack_store}:${CONTAINER_SPACK_STORE}"
        "--volume=${resolved_bazel_cache}:${CONTAINER_BAZEL_CACHE}"
        "--volume=${resolved_hf_cache}:${CONTAINER_HF_CACHE}"
    )
    
    # Project workspace with symlink resolution
    # Mounts the current project directory into the container
    docker_args+=(
        "--volume=${resolved_project_root}:${CONTAINER_WORKSPACE}"
        "--workdir=${CONTAINER_WORKSPACE}"
    )
    
    # Entrypoint
    # Specifies the script to run when container starts
    docker_args+=(
        "--entrypoint=${entrypoint_path}"
    )
    
    # GPU support
    # Enables NVIDIA GPU access if available and requested
    if [[ "${SYGALDRY_GPU:-true}" == "true" ]] && docker info 2>/dev/null | grep -q nvidia; then
        docker_args+=(
            "--runtime=nvidia"
            "--gpus=all"
        )
        log "GPU support enabled"
    fi
    
    # Environment variables
    # Sets container-specific environment variables
    docker_args+=(
        "--env=SYGALDRY_IN_CONTAINER=1"
        "--env=USER=${CONTAINER_USER}"
        "--env=HOME=${CONTAINER_HOME}"
        "--env=HF_HOME=${CONTAINER_HF_CACHE}"
    )
    
    # Pass through common environment variables
    # These allow host environment settings to be used in container
    local env_vars=(
        "TERM"
        "LANG"
        "LC_ALL"
        "BAZEL_VERSION"
    )
    
    for var in "${env_vars[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            docker_args+=("--env=${var}=${!var}")
        fi
    done
    
    printf '%s\n' "${docker_args[@]}"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    log "Starting Sygaldry container launcher..."

    # Parse arguments (entrypoint selection + passthrough)
    local entrypoint_name="${SYGALDRY_ENTRYPOINT:-default}"
    local passthrough_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --entrypoint=*)
                entrypoint_name="${1#*=}"
                shift
                ;;
            --entrypoint|-e)
                entrypoint_name="${2:-}"
                if [[ -z "${entrypoint_name}" ]]; then
                    error "Missing value for --entrypoint"
                fi
                shift 2
                ;;
            --)
                shift
                passthrough_args+=("$@")
                break
                ;;
            *)
                passthrough_args+=("$1")
                shift
                ;;
        esac
    done
    
    # Validate environment and system requirements
    check_requirements
    
    # Setup host environment (directories)
    setup_host_directories
    
    # Build container image if needed
    build_container_image
    
    # Resolve all mount paths to absolute paths (resolving symlinks)
    local resolved_monorepo_home
    resolved_monorepo_home="$(resolve_mount_path "${HOST_MONOREPO_HOME}")"
    local resolved_spack_store
    resolved_spack_store="$(resolve_mount_path "${HOST_SPACK_STORE}")"
    local resolved_bazel_cache
    resolved_bazel_cache="$(resolve_mount_path "${HOST_BAZEL_CACHE}")"
    local resolved_hf_cache
    resolved_hf_cache="$(resolve_mount_path "${HOST_HF_CACHE}")"
    local resolved_project_root
    resolved_project_root="$(resolve_mount_path "${PROJECT_ROOT}")"

    # GPU compatibility check against required CUDA version
    if [[ "${SYGALDRY_GPU:-true}" == "true" ]]; then
        local host_cuda_version
        host_cuda_version="$(detect_host_cuda_version || true)"
        if [[ -n "${host_cuda_version}" ]] && version_lt "${host_cuda_version}" "${REQUIRED_CUDA_VERSION}"; then
            log "WARNING: Host CUDA ${host_cuda_version} < required ${REQUIRED_CUDA_VERSION}; disabling GPU for this launch."
            export SYGALDRY_GPU=false
        fi
    fi

    # Resolve entrypoint path inside container
    local entrypoint_path="${CONTAINER_ENTRYPOINT_DIR}/${entrypoint_name}.sh"
    if [[ ! -f "${PROJECT_ROOT}/container/entrypoints/${entrypoint_name}.sh" ]]; then
        error "Entrypoint not found: ${PROJECT_ROOT}/container/entrypoints/${entrypoint_name}.sh"
    fi
    
    # Build Docker command arguments with resolved paths
    local docker_args
    readarray -t docker_args < <(build_docker_args "${resolved_monorepo_home}" "${resolved_spack_store}" "${resolved_bazel_cache}" "${resolved_hf_cache}" "${resolved_project_root}" "${entrypoint_path}")
    
    # Log launch information
    log "Launching container: ${CONTAINER_IMAGE}"
    log "Project ID: ${PROJECT_ID}"
    log "Container root: ${SYGALDRY_CONTAINER_ROOT}"
    log "Volume mounts (resolved absolute paths):"
    log "  Home: ${resolved_monorepo_home} -> ${CONTAINER_HOME}"
    log "  Spack: ${resolved_spack_store} -> ${CONTAINER_SPACK_STORE}"
    log "  Cache: ${resolved_bazel_cache} -> ${CONTAINER_BAZEL_CACHE}"
    log "  HF Cache: ${resolved_hf_cache} -> ${CONTAINER_HF_CACHE}"
    log "  Workspace: ${resolved_project_root} -> ${CONTAINER_WORKSPACE}"
    log "  Entrypoint: ${entrypoint_path}"
    
    # Execute Docker container with all arguments
    exec docker run "${docker_args[@]}" "${CONTAINER_IMAGE}" "${passthrough_args[@]}"
}

# ============================================================================
# Script Entry Point
# ============================================================================
#
# This ensures the script only runs when executed directly,
# not when sourced by another script
#

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
