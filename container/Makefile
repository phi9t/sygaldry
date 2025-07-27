##
# Sygaldry Build System Makefile
# ===============================
#
# This Makefile orchestrates the complete Sygaldry build pipeline:
# - Docker container image building
# - Spack environment creation and package installation
# - Integration between container environments and build systems
#
# @file
# @version 0.2

# =============================================================================
# Configuration
# =============================================================================

# Docker image configuration
SOURCE_SUFFIX = dockerfile
TARGET_SUFFIX = container_image_tag.makefile.autogen
IMAGE_REPO = sygaldry/sympathy-forgery

# Spack environment paths
TOOLS_DIR = ../tools
TORCH_CUDA_DIR = ../pkg/torch_cuda

# Container launcher script
LAUNCHER = ./launch_container.sh

# =============================================================================
# Main Targets
# =============================================================================

# Default target: build everything
all: container spack-environments

# Build container and all Spack environments
full: container tools torch-cuda
	@echo "✓ Full Sygaldry build system ready"

# =============================================================================
# Container Targets
# =============================================================================

# Build the base development container
container: base.$(TARGET_SUFFIX)
	@echo "✓ Container image ready"

base.$(TARGET_SUFFIX): dev_container.$(SOURCE_SUFFIX)
	@echo "🐳 Building Docker container image..."
	docker build -f $< -t $(IMAGE_REPO):base . && touch $@

# Force rebuild container (ignores cache)
rebuild-container:
	@echo "🔄 Force rebuilding Docker container..."
	docker build --no-cache -f dev_container.$(SOURCE_SUFFIX) -t $(IMAGE_REPO):base .
	touch base.$(TARGET_SUFFIX)

# =============================================================================
# Spack Environment Targets
# =============================================================================

# Build all Spack environments
spack-environments: tools torch-cuda
	@echo "✓ All Spack environments built"

# Helper function to resolve symlinks (used in volume mounts)
define resolve_path
$(shell realpath $(1) 2>/dev/null || echo $(1))
endef

# Build base development tools environment
tools: container
	@echo "🔧 Building tools Spack environment..."
	docker run --rm \
		--volume=$(call resolve_path,$(HOME)/.local/share/sygaldry_container/sygaldry/monorepo_home):/home/kvothe \
		--volume=$(call resolve_path,$(HOME)/.local/share/sygaldry_container/sygaldry/spack_store):/opt/spack_store \
		--volume=$(call resolve_path,$(HOME)/.local/share/sygaldry_container/sygaldry/bazel_cache):/opt/bazel_cache \
		--volume=$(call resolve_path,$(HOME)/.local/share/sygaldry_container/sygaldry/spack_src):/opt/spack_src \
		--volume=$(call resolve_path,$(shell pwd)/..):/workspace \
		--workdir=/workspace/tools \
		--user=1000:1000 \
		$(IMAGE_REPO):base \
		./build.sh
	@echo "✓ Tools environment ready"

# Build PyTorch CUDA machine learning environment
torch-cuda: container
	@echo "🔥 Building PyTorch CUDA environment..."
	docker run --rm \
		--volume=$(call resolve_path,$(HOME)/.local/share/sygaldry_container/sygaldry/monorepo_home):/home/kvothe \
		--volume=$(call resolve_path,$(HOME)/.local/share/sygaldry_container/sygaldry/spack_store):/opt/spack_store \
		--volume=$(call resolve_path,$(HOME)/.local/share/sygaldry_container/sygaldry/bazel_cache):/opt/bazel_cache \
		--volume=$(call resolve_path,$(HOME)/.local/share/sygaldry_container/sygaldry/spack_src):/opt/spack_src \
		--volume=$(call resolve_path,$(shell pwd)/..):/workspace \
		--workdir=/workspace/pkg/torch_cuda \
		--user=1000:1000 \
		$(IMAGE_REPO):base \
		./build.sh
	@echo "✓ PyTorch CUDA environment ready"

# =============================================================================
# Development and Maintenance Targets
# =============================================================================

# Launch interactive development container
shell: container
	@echo "🚀 Launching interactive development shell..."
	$(LAUNCHER)

# Show environment status and information
status: container
	@echo "📊 Sygaldry Build System Status"
	@echo "================================"
	@echo ""
	@echo "Container Images:"
	@docker images $(IMAGE_REPO) --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
	@echo ""
	@echo "Spack Environments:"
	@echo "  Tools: $(TOOLS_DIR)"
	@if [ -f "$(TOOLS_DIR)/spack.yaml" ]; then echo "    ✓ Built"; else echo "    ✗ Not built"; fi
	@echo "  PyTorch CUDA: $(TORCH_CUDA_DIR)"
	@if [ -f "$(TORCH_CUDA_DIR)/spack.yaml" ]; then echo "    ✓ Built"; else echo "    ✗ Not built"; fi

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	rm -f *.$(TARGET_SUFFIX)
	@echo "✓ Build artifacts cleaned"

# Deep clean: remove everything including Spack builds
deep-clean: clean
	@echo "🗑️  Deep cleaning: removing Spack environments..."
	@if [ -f "$(TOOLS_DIR)/spack.yaml" ]; then rm -f "$(TOOLS_DIR)/spack.yaml"; echo "  Removed tools/spack.yaml"; fi
	@if [ -f "$(TORCH_CUDA_DIR)/spack.yaml" ]; then rm -f "$(TORCH_CUDA_DIR)/spack.yaml"; echo "  Removed torch_cuda/spack.yaml"; fi
	@echo "✓ Deep clean completed"

# =============================================================================
# Container Management
# =============================================================================

# Remove Docker containers and images
clean-docker:
	@echo "🐳 Cleaning Docker resources..."
	@docker system prune -f
	@docker rmi $(IMAGE_REPO):base 2>/dev/null || true
	@echo "✓ Docker resources cleaned"

# =============================================================================
# Help and Documentation
# =============================================================================

# Show available targets and usage
help:
	@echo "Sygaldry Build System - Available Targets"
	@echo "=========================================="
	@echo ""
	@echo "Main Build Targets:"
	@echo "  all              - Build container and Spack environments"
	@echo "  full             - Complete build (container + tools + torch-cuda)"
	@echo "  container        - Build Docker development container"
	@echo "  spack-environments - Build all Spack environments"
	@echo ""
	@echo "Spack Environment Targets:"
	@echo "  tools            - Build base development tools environment"
	@echo "  torch-cuda       - Build PyTorch CUDA ML environment"
	@echo ""
	@echo "Development Targets:"
	@echo "  shell            - Launch interactive development shell"
	@echo "  status           - Show build system status"
	@echo ""
	@echo "Maintenance Targets:"
	@echo "  clean            - Clean build artifacts"
	@echo "  deep-clean       - Clean everything including Spack builds"
	@echo "  clean-docker     - Remove Docker containers and images"
	@echo "  rebuild-container - Force rebuild container (no cache)"
	@echo ""
	@echo "Usage Examples:"
	@echo "  make full        # Complete build from scratch"
	@echo "  make tools       # Just build tools environment"
	@echo "  make shell       # Start development session"
	@echo "  make status      # Check what's built"

# =============================================================================
# Special Targets
# =============================================================================

.PHONY: all full container spack-environments tools torch-cuda
.PHONY: shell status clean deep-clean clean-docker rebuild-container help

# end
