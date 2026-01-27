# syntax=docker/dockerfile:1
#
# Sygaldry Spack Snapshot Image
# ==============================
#
# Self-contained image with the full Spack store (PyTorch, JAX, CUDA, etc.)
# baked in.  No host-side Spack store mount is required.
#
# BUILD (via helper script):
#   ./container/snapshot_spack.sh
#
# BUILD (manual):
#   DOCKER_BUILDKIT=1 docker build \
#     -f container/spack_snapshot.dockerfile \
#     --build-context spack_store=/mnt/data_infra/zephyr_container_infra/sygaldry/spack_store \
#     -t sygaldry/zephyr:spack \
#     .
#
# RUN (standalone -- no launcher needed):
#   docker run --rm -it --gpus all sygaldry/zephyr:spack
#
# RUN (via launcher):
#   SYGALDRY_IMAGE=sygaldry/zephyr:spack ./container/launch_container.sh
#

FROM sygaldry/zephyr:base

# ---------------------------------------------------------------------------
# Bake Spack store into the image
# ---------------------------------------------------------------------------
# Uses BuildKit named context "spack_store" which points at the host-side
# spack store directory.  Only runtime-essential components are copied;
# build_stage (~5.5 GB) and source_cache (~14 GB) are excluded.

USER root

# install_tree: compiled packages + .spack-db index (~22 GB)
COPY --from=spack_store --chown=kvothe:kvothe install_tree /opt/spack_store/install_tree

# misc_cache: Spack metadata (~700 KB)
COPY --from=spack_store --chown=kvothe:kvothe misc_cache /opt/spack_store/misc_cache

# Prepare view directory (final view symlink is created after regeneration).
RUN mkdir -p /opt/spack_store/._view

# Create empty build_stage and source_cache so Spack doesn't complain
RUN mkdir -p /opt/spack_store/build_stage /opt/spack_store/source_cache && \
    chown kvothe:kvothe /opt/spack_store/build_stage /opt/spack_store/source_cache

# ---------------------------------------------------------------------------
# Bake Zephyr Spack environment metadata
# ---------------------------------------------------------------------------
# These files let `spack env activate` work without the sygaldry repo.

RUN mkdir -p /opt/spack_env/default && chown -R kvothe:kvothe /opt/spack_env
COPY --chown=kvothe:kvothe pkg/zephyr /opt/spack_env/default

# ---------------------------------------------------------------------------
# Bake entrypoints
# ---------------------------------------------------------------------------
# So the image works without any host-mounted sygaldry repo.

COPY --chown=kvothe:kvothe container/entrypoints /opt/container_entrypoints
COPY --chown=kvothe:kvothe container/lib /opt/lib
COPY --chown=kvothe:kvothe container/spack_owned_packages.conf /opt/container_entrypoints/spack_owned_packages.conf
COPY --chown=kvothe:kvothe container/nvidia_overrides.txt /opt/container_entrypoints/nvidia_overrides.txt
COPY --chown=kvothe:kvothe container/llm_serving_overrides.txt /opt/container_entrypoints/llm_serving_overrides.txt
RUN chmod +x /opt/container_entrypoints/*.sh
RUN chmod +x /opt/lib/*.sh

# ---------------------------------------------------------------------------
# Reindex Spack database
# ---------------------------------------------------------------------------
# Ensures the DB in install_tree/.spack-db is consistent with the copied files.

RUN /bin/bash -lc "set -e; \
    source /opt/spack_src/share/spack/setup-env.sh; \
    spack reindex; \
    rm -rf /opt/spack_store/._view/*; \
    spack -e /opt/spack_env/default env view regenerate; \
    VIEW_TARGET=\$(ls -d /opt/spack_store/._view/*/ | head -1); \
    ln -sfn \${VIEW_TARGET%/} /opt/spack_store/view; \
    echo \"Regenerated Spack view -> \$(readlink /opt/spack_store/view)\""

# ---------------------------------------------------------------------------
# Environment and metadata
# ---------------------------------------------------------------------------

USER kvothe

# SYGALDRY_SPACK_ENV tells entrypoints where the default baked env lives.
ENV SYGALDRY_SPACK_ENV=/opt/spack_env/default
ENV SYGALDRY_IN_CONTAINER=1

WORKDIR /workspace

ENTRYPOINT ["/opt/container_entrypoints/default.sh"]
CMD ["bash", "--login"]

LABEL sygaldry.spack.baked="true"
LABEL sygaldry.entrypoints.baked="true"
LABEL maintainer="Sygaldry Development Team"
LABEL description="Self-contained Sygaldry image with baked Spack store (PyTorch, JAX, CUDA)"
