#!/bin/bash
#
# Sygaldry User Environment Setup Script
# =====================================
#
# This script installs and configures user-specific tools:
# - Rust toolchain with rustfmt and clippy
# - uv Python package manager
# - Comprehensive bashrc configuration
# - Development aliases and environment variables
#
# The script is designed to run as the target user (kvothe) and
# handles all user-specific installations that require proper
# home directory permissions and PATH configuration.
#
# Usage:
#   ./setup_user_environment.sh [RUST_VERSION] [PYTHON_VERSION]
#
# Environment Variables:
#   RUST_VERSION   - Rust version to install (default: 1.79.0)
#   PYTHON_VERSION - Python version for configuration (default: 3.12)
#

set -eu -o pipefail

# ============================================================================
# Configuration and Constants
# ============================================================================

# Version configuration with defaults
readonly RUST_VERSION="${1:-${RUST_VERSION:-1.79.0}}"
readonly PYTHON_VERSION="${2:-${PYTHON_VERSION:-3.12}}"

# Paths and directories
readonly HOME_DIR="${HOME}"
readonly BASHRC="${HOME_DIR}/.bashrc"
readonly CARGO_HOME="${HOME_DIR}/.cargo"
readonly LOCAL_BIN="${HOME_DIR}/.local/bin"

# Tool URLs and installers
readonly RUSTUP_INSTALLER="https://sh.rustup.rs"
readonly UV_INSTALLER="https://astral.sh/uv/install.sh"

# ============================================================================
# Helper Functions
# ============================================================================

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
    
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [setup] ${caller_info} $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        log "$1 is already installed"
        return 0
    else
        log "$1 not found, installing..."
        return 1
    fi
}

# ============================================================================
# Rust Installation
# ============================================================================

install_rust() {
    log "Installing Rust toolchain version ${RUST_VERSION}..."
    
    # Ensure we're running as the correct user
    if [[ "$(id -u)" == "0" ]]; then
        error "This script should not be run as root. Run as the target user."
    fi
    
    # Clean up any existing rustup installation to avoid conflicts
    if [[ -d "${HOME_DIR}/.rustup" ]]; then
        log "Removing existing rustup installation to avoid conflicts..."
        rm -rf "${HOME_DIR}/.rustup" "${HOME_DIR}/.cargo"
    fi
    
    if check_command rustc; then
        local current_version
        current_version=$(rustc --version | awk '{print $2}')
        if [[ "${current_version}" == "${RUST_VERSION}" ]]; then
            log "Rust ${RUST_VERSION} already installed"
            return 0
        else
            log "Rust version mismatch (${current_version} != ${RUST_VERSION}), reinstalling..."
        fi
    fi
    
    # # Ensure HOME environment is correctly set
    # export HOME="${HOME_DIR}"
    # export CARGO_HOME="${HOME_DIR}/.cargo"
    # export RUSTUP_HOME="${HOME_DIR}/.rustup"

    log "Installing Rust with HOME=${HOME}, CARGO_HOME=${CARGO_HOME}"
    
    # Install rustup and Rust
    curl --proto '=https' --tlsv1.2 -sSf "${RUSTUP_INSTALLER}" | \
        sh -s -- -y --default-toolchain "${RUST_VERSION}" --no-modify-path
    
    # Source cargo environment
    if [[ -f "${CARGO_HOME}/env" ]]; then
        source "${CARGO_HOME}/env"
    else
        export PATH="${CARGO_HOME}/bin:${PATH}"
    fi
    
    # Install essential components
    log "Installing Rust components..."
    rustup component add rustfmt clippy
    
    # Verify installation
    if command -v rustc >/dev/null 2>&1; then
        log "Rust installation successful: $(rustc --version)"
    else
        error "Rust installation failed"
    fi
}

# ============================================================================
# uv Installation
# ============================================================================

install_uv() {
    log "Installing uv Python package manager..."
    export PATH="${HOME_DIR}/.local/bin:${PATH}"

    if check_command uv; then
        log "uv already installed: $(uv --version)"
        return 0
    fi
    
    # Install uv
    curl -LsSf "${UV_INSTALLER}" | sh
    
    # Verify installation
    if command -v uv >/dev/null 2>&1; then
        log "uv installation successful: $(uv --version)"
    else
        error "uv installation failed"
    fi
}

# ============================================================================
# Git Configuration
# ============================================================================

configure_git() {
    log "Configuring git for development..."
    
    # Set default branch to main
    git config --global init.defaultBranch main
    
    # Configure pull behavior
    git config --global pull.rebase false
    
    # Set up basic user info if not already configured
    if [[ -z "$(git config --global user.name)" ]]; then
        git config --global user.name "Sygaldry Developer"
    fi
    
    if [[ -z "$(git config --global user.email)" ]]; then
        git config --global user.email "developer@sygaldry.local"
    fi
    
    # Enable helpful git features
    git config --global core.autocrlf input
    git config --global core.editor "${EDITOR:-nano}"
    
    log "Git configuration completed"
}

# ============================================================================
# Bashrc Configuration
# ============================================================================

configure_bashrc() {
    log "Configuring bashrc with development environment..."
    
    # Create backup of existing bashrc
    if [[ -f "${BASHRC}" ]]; then
        cp "${BASHRC}" "${BASHRC}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Created bashrc backup"
    fi
    
    # Add Sygaldry environment configuration
    cat >> "${BASHRC}" << '_BASHRC_EOF_'
# ============================================================================
# Sygaldry Development Environment Configuration
# ============================================================================
# This section is automatically generated by setup_user_environment.sh
# Do not edit manually - regenerate by running the setup script

# PATH Configuration
# Add Rust cargo bin directory if it exists
if [[ -d "$HOME/.cargo/bin" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

# Add local bin directory if it exists
if [[ -d "$HOME/.local/bin" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Add Go bin directory if it exists
if [[ -d "/usr/local/go/bin" ]]; then
    export PATH="/usr/local/go/bin:$PATH"
fi

# Development Environment
export EDITOR="${EDITOR:-nano}"
export TERM="${TERM:-xterm-256color}"

# Spack Configuration
export SPACK_ROOT="/opt/spack_src"

# Bazel Configuration
export BAZEL_CACHE="/opt/bazel_cache"
export USE_BAZEL_VERSION="${BAZEL_VERSION:-6.4.0}"

# uv Configuration for Spack Integration
export UV_CACHE_DIR="/opt/bazel_cache/uv"
export UV_SYSTEM_PYTHON=1
export UV_LINK_MODE=copy

# Python Configuration
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

# ============================================================================
# Development Functions
# ============================================================================

# Function to configure uv with Spack environment
configure_uv_spack() {
    if [ -n "${SPACK_ENV:-}" ] && [ -d "/opt/spack_store/view" ]; then
        export PYTHONPATH="/opt/spack_store/view/lib/python*/site-packages:${PYTHONPATH:-}"
        export UV_FIND_LINKS="/opt/spack_store/view/lib/python*/site-packages"
        export UV_NO_BUILD_ISOLATION_PACKAGE="numpy,scipy,torch,torchvision,matplotlib,pandas,polars"
        echo "uv configured for Spack integration"
    else
        echo "Warning: Spack environment not active or view not found"
    fi
}

# Function to activate Spack environment and configure uv
spack-env-activate() {
    if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
        source "/opt/spack_src/share/spack/setup-env.sh"
        if [[ $# -gt 0 ]]; then
            spack env activate "$@"
        else
            spack env activate .
        fi
        configure_uv_spack
        echo "Spack environment activated with uv integration"
    else
        echo "Error: Spack setup script not found"
        return 1
    fi
}

# Quick development commands
alias spack-info='spack find && spack env status'
alias bazel-clean='bazel clean --expunge'
alias bazel-info='bazel info && bazel version'
alias uv-info='uv --version && echo "Cache: $UV_CACHE_DIR"'

# ============================================================================
# Enhanced Aliases
# ============================================================================

# File operations
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias lt='ls -altr'  # sort by time, newest last
alias lh='ls -alh'   # human-readable sizes

# Grep with color
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Development tools
alias py='python3'
alias pip='python3 -m pip'
alias venv='python3 -m venv'
alias server='python3 -m http.server'

# Git shortcuts
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -10'
alias ga='git add'
alias gc='git commit'
alias gp='git push'

# System information
alias disk='df -h'
alias mem='free -h'
alias cpu='lscpu'
alias ports='netstat -tuln'

# Container helpers
alias docker-clean='docker system prune -f'
alias docker-images='docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"'

# Development shortcuts
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias src='cd /workspace'
alias home='cd $HOME'

# PATH management
check-path() {
    echo "Current PATH components:"
    echo "$PATH" | tr ':' '\n' | nl
    echo ""
    echo "Tool availability:"
    for tool in cargo rustc uv python3 bazel spack git; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf "  [+] %-10s: %s\n" "$tool" "$(command -v "$tool")"
        else
            printf "  [-] %-10s: not found\n" "$tool"
        fi
    done
}

# ============================================================================
# Prompt Configuration
# ============================================================================

# Enhanced prompt with git branch and virtual environment info
parse_git_branch() {
    git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1)/'
}

# Set a colorful prompt
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[01;31m\]$(parse_git_branch)\[\033[00m\]\$ '

# ============================================================================
# Auto-completion and History
# ============================================================================

# History configuration
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoredups:erasedups
shopt -s histappend

# Enable bash completion if available
if [[ -f /etc/bash_completion ]]; then
    source /etc/bash_completion
fi

# Enable cargo completion if available
if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
fi

# ============================================================================
# Welcome Message Function
# ============================================================================

sygaldry-info() {
    echo "╭─────────────────────────────────────────────────────────────"
    echo "│                 Sygaldry Development Environment            "
    echo "│                                                             "
    echo "│  [T] Tools: Bazel $(bazel version 2>/dev/null | head -1 | cut -d' ' -f3 || echo 'N/A'), Spack, uv $(uv --version 2>/dev/null | cut -d' ' -f2 || echo 'N/A')                      "
    echo "│  [R] Rust: $(rustc --version 2>/dev/null | cut -d' ' -f2 || echo 'Not installed')                                      "
    echo "│  [P] Python: $(python3 --version 2>/dev/null | cut -d' ' -f2 || echo 'N/A')                                   "
    echo "│  [W] Workspace: /workspace                                  "
    echo "│  [H] Home: $HOME                                            "
    echo "│                                                             "
    echo "│  Quick commands:                                            "
    echo "│    spack-env-activate    - Activate Spack + uv              "
    echo "│    check-path            - Check PATH and tool availability "
    echo "│    sygaldry-info         - Show this message                "
    echo "│    bazel build //...     - Build all targets                "
    echo "│    uv add <package>      - Add Python package               "
    echo "╰─────────────────────────────────────────────────────────────"
}

# Show info on first login
if [[ -z "${SYGALDRY_SETUP_COMPLETE:-}" ]]; then
    export SYGALDRY_SETUP_COMPLETE=1
    sygaldry-info
fi

# End of Sygaldry Development Environment Configuration
_BASHRC_EOF_

    log "Bashrc configuration completed"
}

# ============================================================================
# Main Installation Function
# ============================================================================

main() {
    log "Starting Sygaldry user environment setup..."
    log "Target user: $(whoami)"
    log "Home directory: ${HOME_DIR}"
    log "Rust version: ${RUST_VERSION}"
    log "Python version: ${PYTHON_VERSION}"
    
    # Ensure local bin directory exists
    mkdir -p "${LOCAL_BIN}"
    
    # Install tools
    install_rust
    install_uv
    
    # Configure development environment
    configure_git
    configure_bashrc
    
    # Verify installations
    log "Verifying installations..."
    if command -v rustc >/dev/null 2>&1; then
        log "[+] Rust: $(rustc --version)"
    else
        error "[-] Rust installation verification failed"
    fi
    
    if command -v uv >/dev/null 2>&1; then
        log "[+] uv: $(uv --version)"
    else
        error "[-] uv installation verification failed"
    fi
    
    log "Setup completed successfully!"
    log "Please reload your shell or run: source ~/.bashrc"
}

# ============================================================================
# Script Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
