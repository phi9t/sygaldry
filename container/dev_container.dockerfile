# Sygaldry Development Container
# Ubuntu 24.04 based container with Bazel + Spack + Docker build system
FROM ubuntu:24.04

# Build arguments
ARG BAZEL_VERSION=6.4.0
ARG PYTHON_VERSION=3.12
ARG RUST_VERSION=1.79.0
ARG GO_VERSION=1.21.5
ARG HOST_UID=1000
ARG HOST_GID=1000

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV TZ=UTC

# ============================================================================
# System Dependencies and Base Tools
# ============================================================================

# Clean up any problematic repository configurations first
RUN rm -f /etc/apt/sources.list.d/kubernetes.list \
    /etc/apt/sources.list.d/google-cloud-sdk.list \
    /etc/apt/sources.list.d/cuda*.list \
    /etc/apt/sources.list.d/nvidia*.list \
    /etc/apt/trusted.gpg.d/kubernetes.gpg \
    /etc/apt/trusted.gpg.d/google-cloud-sdk.gpg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essential build tools
    build-essential \
    cmake \
    ninja-build \
    pkg-config \
    autoconf \
    automake \
    libtool \
    make \
    # Version control and networking
    git \
    git-lfs \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    # Compression and archiving
    zip \
    unzip \
    bzip2 \
    xz-utils \
    tar \
    gzip \
    # Development utilities
    nano \
    htop \
    tree \
    jq \
    ripgrep \
    fd-find \
    # Python and development
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    # Language runtimes
    nodejs \
    npm \
    # System administration
    sudo \
    # System libraries often needed by Spack packages
    libssl-dev \
    libffi-dev \
    libxml2-dev \
    libxslt1-dev \
    libbz2-dev \
    liblzma-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncurses5-dev \
    libncursesw5-dev \
    tk-dev \
    libgdbm-dev \
    libc6-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
# Bazel Installation
# ============================================================================

RUN curl -fsSL https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 \
    -o /usr/local/bin/bazel && \
    chmod +x /usr/local/bin/bazel && \
    # Verify installation
    bazel version

# ============================================================================
# Go Installation (needed for some Bazel rules)
# ============================================================================

RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz \
    -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && \
    rm go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"

# ============================================================================
# Rust Installation - Handled by setup script
# ============================================================================

# Rust will be installed by setup script for proper user configuration

# ============================================================================
# Python Development Tools - uv handled by setup script
# ============================================================================

# uv will be installed by setup script for proper user configuration

# ============================================================================
# Spack Dependencies
# ============================================================================

# Ensure clean package state before installing Spack dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Spack requirements
    environment-modules \
    tcl \
    # Compilers that Spack might need
    gfortran \
    clang \
    libc++-dev \
    libc++abi-dev \
    # Additional build tools
    ccache \
    distcc \
    # MPI (commonly used in HPC)
    libopenmpi-dev \
    openmpi-bin \
    # Linear algebra libraries
    libblas-dev \
    liblapack-dev \
    libatlas-base-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configure ccache
RUN /usr/sbin/update-ccache-symlinks && \
    mkdir -p /opt/ccache && \
    ccache --set-config=cache_dir=/opt/ccache

# ============================================================================
# User Setup
# ============================================================================

# Create kvothe user with host UID and GID for proper file permissions
# Force exact IDs by handling existing conflicts
RUN set -e && \
    # Remove any existing user/group with target UID/GID
    if getent passwd ${HOST_UID} >/dev/null 2>&1; then \
        existing_user=$(getent passwd ${HOST_UID} | cut -d: -f1); \
        echo "Removing existing user with UID ${HOST_UID}: $existing_user"; \
        userdel -r "$existing_user" 2>/dev/null || true; \
    fi && \
    if getent group ${HOST_GID} >/dev/null 2>&1; then \
        existing_group=$(getent group ${HOST_GID} | cut -d: -f1); \
        echo "Removing existing group with GID ${HOST_GID}: $existing_group"; \
        groupdel "$existing_group" 2>/dev/null || true; \
    fi && \
    # Create kvothe group with host GID
    groupadd -g ${HOST_GID} kvothe && \
    # Create kvothe user with host UID and GID
    useradd -u ${HOST_UID} -g ${HOST_GID} -m -s /bin/bash kvothe && \
    # Add to sudo group for development convenience
    usermod -aG sudo kvothe && \
    # Allow passwordless sudo
    echo 'kvothe ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Create mount point directories with proper ownership
RUN mkdir -p /opt/spack_store /opt/spack_src /opt/bazel_cache && \
    chown -R kvothe:kvothe /opt/spack_store /opt/spack_src /opt/bazel_cache

# ============================================================================
# Environment Configuration
# ============================================================================

# Set up environment for kvothe user
USER kvothe
WORKDIR /home/kvothe

# # Copy and run user environment setup script
# COPY setup_user_environment.sh /tmp/setup_user_environment.sh
# RUN /tmp/setup_user_environment.sh ${RUST_VERSION} ${PYTHON_VERSION} && \
#     rm /tmp/setup_user_environment.sh

# ============================================================================
# Final Configuration
# ============================================================================

# Set default working directory
WORKDIR /workspace

# Default command
CMD ["/bin/bash", "--login"]

# Labels for metadata
LABEL maintainer="Sygaldry Development Team"
LABEL description="Ubuntu 24.04 based development container with Bazel + Spack + Docker build system"
LABEL version="1.0"
LABEL bazel.version="${BAZEL_VERSION}"
LABEL python.version="${PYTHON_VERSION}"
LABEL rust.version="${RUST_VERSION}"
LABEL go.version="${GO_VERSION}"
