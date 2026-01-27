# syntax=docker/dockerfile:1
#
# MLSys Baked Venv Image
# =======================
#
# Parameterized dockerfile that bakes UV virtual environments on top of the
# Spack snapshot image.  Build arg MLSYS_ENV selects which env to bake.
#
# BUILD (via helper script — recommended):
#   ./container/snapshot_mlsys.sh vllm
#   ./container/snapshot_mlsys.sh sglang
#   ./container/snapshot_mlsys.sh hf-transformers
#   ./container/snapshot_mlsys.sh llm-serving-all
#
# BUILD (manual):
#   DOCKER_BUILDKIT=1 docker build \
#     -f container/mlsys_venv.dockerfile \
#     --build-arg MLSYS_ENV=vllm \
#     -t sygaldry/zephyr:vllm .
#
# RUN (standalone — venv auto-activates, prompt shows env name):
#   docker run --rm -it --gpus all sygaldry/zephyr:vllm
#
# RUN (execute a command — venv is active, import works):
#   docker run --rm --gpus all sygaldry/zephyr:vllm \
#     python3 -c "import vllm; print(vllm.__version__)"
#

ARG SPACK_SNAPSHOT_IMAGE=sygaldry/zephyr:spack
FROM ${SPACK_SNAPSHOT_IMAGE}

ARG MLSYS_ENV=hf-transformers
ARG VENV_ROOT=/opt/mlsys-envs

# ---------------------------------------------------------------------------
# Bake MLSys skill scripts and env definitions
# ---------------------------------------------------------------------------

USER root

COPY --chown=kvothe:kvothe skills/zephyr /opt/sygaldry/skills/zephyr
RUN chmod +x /opt/sygaldry/skills/zephyr/scripts/*.sh

# Update entrypoints with auto-activation support.
# This ensures the MLSys image has the auto-activation code even if the
# spack snapshot was built before it was added.
COPY --chown=kvothe:kvothe container/entrypoints/default.sh /opt/container_entrypoints/default.sh
COPY --chown=kvothe:kvothe container/entrypoints/run-job.sh /opt/container_entrypoints/run-job.sh
COPY --chown=kvothe:kvothe container/entrypoints/uv-install.sh /opt/container_entrypoints/uv-install.sh
RUN chmod +x /opt/container_entrypoints/default.sh /opt/container_entrypoints/run-job.sh /opt/container_entrypoints/uv-install.sh

# Update override/constraint files so latest fixes are available during build
COPY --chown=kvothe:kvothe container/nvidia_overrides.txt /opt/container_entrypoints/nvidia_overrides.txt
COPY --chown=kvothe:kvothe container/llm_serving_overrides.txt /opt/container_entrypoints/llm_serving_overrides.txt
COPY --chown=kvothe:kvothe container/spack_owned_packages.conf /opt/container_entrypoints/spack_owned_packages.conf

# Fix broken Spack dist-info: python-dateutil reports 0.0.0 but is actually 2.8.2.
# UV sees this via --system-site-packages and refuses to resolve deps needing >=2.8.2.
RUN SITE="/opt/spack_store/view/lib/python3.13/site-packages" && \
    if [ -d "${SITE}/python_dateutil-0.0.0.dist-info" ]; then \
        sed -i 's/^Version: 0.0.0$/Version: 2.8.2/' "${SITE}/python_dateutil-0.0.0.dist-info/METADATA" && \
        mv "${SITE}/python_dateutil-0.0.0.dist-info" "${SITE}/python_dateutil-2.8.2.dist-info"; \
    fi

# Ensure venv root is writable by kvothe
RUN mkdir -p "${VENV_ROOT}" && chown kvothe:kvothe "${VENV_ROOT}"

# ---------------------------------------------------------------------------
# Build UV venv(s)
# ---------------------------------------------------------------------------
# - BuildKit cache mount on /opt/uv_cache avoids baking download cache into layer
# - --no-validate because Docker build has no GPU; verification is post-build
# - VENV_ROOT is set to /opt/mlsys-envs so venvs persist in the image layer

USER kvothe

SHELL ["/bin/bash", "-c"]
RUN --mount=type=cache,target=/opt/uv_cache,uid=1000,gid=1000 \
    set -eu -o pipefail && \
    . /opt/spack_src/share/spack/setup-env.sh && \
    spack env activate /opt/spack_env/default 2>/dev/null || true && \
    export UV_CACHE_DIR=/opt/uv_cache && \
    VENV_ROOT="${VENV_ROOT}" SKIP_VALIDATE=1 \
        /opt/sygaldry/skills/zephyr/scripts/uv-env-build.sh \
        "${MLSYS_ENV}" --no-validate --venv-root "${VENV_ROOT}" && \
    echo "${MLSYS_ENV}" > "${VENV_ROOT}/.default-env" && \
    ls -d "${VENV_ROOT}"/*/ 2>/dev/null | sed 's|/$||' | xargs -I{} basename {} > "${VENV_ROOT}/.manifest"

# ---------------------------------------------------------------------------
# Shell integration — auto-activate venv in interactive sessions
# ---------------------------------------------------------------------------
# When default.sh does `exec bash --login` (or `exec bash -i`), the new bash
# process inherits VIRTUAL_ENV and PATH but loses the PS1 modification from
# `source activate`.  This .bashrc snippet re-activates the venv so the
# prompt shows (vllm), (sglang), etc.  It also provides `mlsys-activate` for
# switching between venvs in multi-venv images.

RUN cat >> /home/kvothe/.bashrc <<'BASHRC_EOF'

# ============================================================================
# Baked MLSys Venv — shell integration
# ============================================================================

if [[ -n "${SYGALDRY_MLSYS_ENV:-}" ]]; then
    _mlsys_vr="${SYGALDRY_MLSYS_VENV_ROOT:-/opt/mlsys-envs}"
    _mlsys_en="${SYGALDRY_MLSYS_ENV}"
    _mlsys_tgt="${SYGALDRY_MLSYS_TARGET:-}"
    _mlsys_vd=""

    if [[ -n "${_mlsys_tgt}" ]] && [[ -f "${_mlsys_vr}/${_mlsys_en}/${_mlsys_tgt}/bin/activate" ]]; then
        _mlsys_vd="${_mlsys_vr}/${_mlsys_en}/${_mlsys_tgt}"
    elif [[ -f "${_mlsys_vr}/${_mlsys_en}/bin/activate" ]]; then
        _mlsys_vd="${_mlsys_vr}/${_mlsys_en}"
    else
        _mlsys_first="$(find "${_mlsys_vr}/${_mlsys_en}" -maxdepth 3 -name activate -path '*/bin/activate' 2>/dev/null | sort | head -1)"
        if [[ -n "${_mlsys_first:-}" ]]; then
            _mlsys_vd="$(dirname "$(dirname "${_mlsys_first}")")"
        fi
    fi

    if [[ -n "${_mlsys_vd}" ]] && [[ -f "${_mlsys_vd}/bin/activate" ]]; then
        source "${_mlsys_vd}/bin/activate"
    fi
    unset _mlsys_vr _mlsys_en _mlsys_tgt _mlsys_vd _mlsys_first 2>/dev/null
fi

# Switch between venvs in multi-venv images (e.g. sygaldry/zephyr:mlsys)
mlsys-activate() {
    local target="${1:-}"
    local vr="${SYGALDRY_MLSYS_VENV_ROOT:-/opt/mlsys-envs}"
    local en="${SYGALDRY_MLSYS_ENV:-}"
    if [[ -z "${en}" ]]; then echo "Not an MLSys image." >&2; return 1; fi
    if [[ -z "${target}" ]]; then
        echo "Usage: mlsys-activate <venv-name>"
        echo "Available:"
        for _a in "${vr}/${en}"/*/bin/activate "${vr}"/*/bin/activate; do
            [[ -f "$_a" ]] && echo "  $(basename "$(dirname "$(dirname "$_a")")")"
        done 2>/dev/null
        return 0
    fi
    if [[ -f "${vr}/${en}/${target}/bin/activate" ]]; then
        source "${vr}/${en}/${target}/bin/activate"
    elif [[ -f "${vr}/${target}/bin/activate" ]]; then
        source "${vr}/${target}/bin/activate"
    else
        echo "Venv '${target}' not found." >&2; return 1
    fi
}
BASHRC_EOF

# ---------------------------------------------------------------------------
# Environment and metadata
# ---------------------------------------------------------------------------

ENV SYGALDRY_MLSYS_VENV_ROOT=${VENV_ROOT}
ENV SYGALDRY_MLSYS_ENV=${MLSYS_ENV}

# Suppress the duplicate sygaldry-info welcome from .bashrc — default.sh
# already prints a welcome banner with MLSys env info.
ENV SYGALDRY_SETUP_COMPLETE=1

# Clear inherited CMD so `docker run -it <image>` drops into the interactive
# path of default.sh (welcome banner + exec bash -i) rather than exec'ing
# `bash --login` which skips the banner.
CMD []

LABEL sygaldry.mlsys.baked="true"
LABEL sygaldry.mlsys.env="${MLSYS_ENV}"
LABEL description="Sygaldry MLSys image with baked ${MLSYS_ENV} venv"
