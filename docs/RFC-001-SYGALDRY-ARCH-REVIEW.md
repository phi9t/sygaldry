# RFC-001: Sygaldry Architectural Review and System Specification

**Status:** Draft / Pending Review
**Author:** Gemini CLI (Agentic Reviewer)
**Date:** 2026-03-11
**Target:** Sygaldry Engineering Team

---

## 1. Abstract
This RFC provides a comprehensive architectural review of the **Sygaldry** repository. Sygaldry is a specialized GPU-native infrastructure monorepo designed for reproducible, high-performance machine learning research. It integrates Docker, Spack, and Temporal to provide a "Zephyr" environment for ML workloads.

## 2. System Identity & Purpose
The primary goal of Sygaldry is to solve "dependency hell" in scientific computing by providing a hermetic, standardized environment (Zephyr) that supports PyTorch, JAX, and CUDA 12.9.1. It functions as both a standalone workspace and a portable "skill" that can be injected into external repositories.

> **[COMMENT_NEEDED]**: Is the "Zephyr" branding consistently used across the codebase, or should we consolidate naming conventions to avoid confusion with the RTOS of the same name?

## 3. Core Architecture: The Two-Tier Model
Sygaldry employs a hybrid virtualization and package management strategy:

1.  **System Tier (Docker):** Provides the base OS (Ubuntu 24.04) and the NVIDIA CUDA runtime. It maps host UID/GID to the container user `kvothe` for seamless file permissions.
2.  **Scientific Tier (Spack):** Manages the HPC software stack (NumPy, PyTorch, JAX, MPI). This ensures binary compatibility and performance optimizations decoupled from the host OS.

> **[COMMENT_NEEDED]**: The 42GB Spack store (`spack_store/`) is a "precious artifact." Should we explore a decentralized distribution method (e.g., CVMFS or an OCI registry layer) for scaling beyond a single host?

## 4. Key Subsystems

### 4.1 Orchestration (Temporal)
Located in `temporal/`, this Go-based system handles long-running ML pipelines.
- **Worker:** Executes activities defined in YAML plans.
- **Orchestrator:** Handles dependency resolution and step execution.

### 4.2 Unified CLI (`bin/sygaldry` & `crates/zephyr`)
The project is transitioning from shell-based dispatching to a Rust-native CLI.
- **Current:** `bin/sygaldry` dispatches to `launch_container.sh` or the Rust binary.
- **Future:** Full port of "Outer Loop" logic to Rust (`crates/zephyr`).

> **[COMMENT_NEEDED]**: What is the timeline for deprecating the shell-based `launch_container.sh` in favor of the Rust implementation?

### 4.3 SAIL: Sygaldry Agentic Improvement Loop
An autonomous self-healing loop built into the repo (`tools/agentic/`).
- **Function:** Discovers issues, plans fixes via LLMs, and executes them via Temporal.
- **Recursive:** Includes a "self-fix" pass for the loop itself.

## 5. Workflow Specifications

### 5.1 Interactive Shell
`sygaldry shell` provides a GPU-validated environment with Spack paths pre-configured.

### 5.2 Multi-Repo "Skill" Mode
`sygaldry --repo /path/to/project` mounts external code into the Zephyr environment.
- Shared: Spack store, UV cache, HF cache.
- Isolated: Virtual environments, project configs.

## 6. Engineering Standards & Validation
- **Quality Gates:** `validate_all.sh` (Ruff, Black, ShellCheck, Go tests, Cargo tests).
- **Documentation:** `CLAUDE.md` serves as the source of truth for AI assistants and human contributors.

> **[COMMENT_NEEDED]**: Should we integrate `just validate` into a pre-commit hook or a mandatory CI check to prevent regression in the "Agentic Improvement" loop?

## 7. Open Questions for Review
1. **Host-Side Dependencies:** The requirement for the NVIDIA Docker runtime on the host is a hard constraint. Should we provide a "Pre-flight" diagnostic tool for new host setups?
2. **Snapshot Strategy:** Currently, snapshots are built for MLSys images (vLLM, SGLang). How do we handle version drift between these snapshots and the base Spack environment?
3. **Temporal Scaling:** Is the current dev-server approach sufficient for production ML jobs, or should we define a standard deployment for a full Temporal cluster?

---
*End of RFC-001*
