# RFC-013: Dockerfile Cache Invalidation and Layer Optimization

**Status:** Proposed
**File:** `container/dev_container.dockerfile`

---

## Problem

`container/dev_container.dockerfile` has several patterns that cause unnecessary
cache invalidation, ambiguous reproducibility, and a dead commented-out block
that silently omits user environment setup.

---

## Key Findings

### 1. Repo cleanup as a separate RUN layer before apt-get

Lines 29–37 remove stale apt list files in their own `RUN` layer:

```dockerfile
# container/dev_container.dockerfile:29-37
RUN rm -f /etc/apt/sources.list.d/kubernetes.list \
    /etc/apt/sources.list.d/google-cloud-sdk.list \
    /etc/apt/sources.list.d/cuda*.list \
    /etc/apt/sources.list.d/nvidia*.list \
    /etc/apt/trusted.gpg.d/kubernetes.gpg \
    /etc/apt/trusted.gpg.d/google-cloud-sdk.gpg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
```

The subsequent apt install (lines 39–98) is in a separate `RUN`. Because Docker
layers are immutable, the cleanup layer provides no security value — a deleted
file in a prior layer is still present in the image history. The two layers
should be merged so the cleanup runs immediately before `apt-get update`.

### 2. Mutable git branch ref for Spack

Line 191 clones Spack using a branch tag:

```dockerfile
# container/dev_container.dockerfile:191-192
RUN git clone -c feature.manyFiles=true --branch "${SPACK_VERSION}" --depth 1 \
    https://github.com/spack/spack.git /opt/spack_src
```

`SPACK_VERSION` is set to `v1.1.0` (line 10). A git tag can be force-pushed;
using `--branch` with a `v`-prefixed tag and `--depth 1` does not guarantee the
same content across rebuilds if the tag is moved. Pinning by commit SHA
eliminates this ambiguity.

### 3. COPY order puts pkg/zephyr before user setup

Lines 233–237 copy `pkg/zephyr` and entrypoints before the user environment
section. Any change to `pkg/zephyr` (which changes frequently during Spack
iteration) invalidates all subsequent layers, including user creation. The
`pkg/zephyr` COPY should move to the last possible position before it is
actually needed.

```dockerfile
# container/dev_container.dockerfile:233-237 (current order)
COPY --chown=kvothe:kvothe pkg/zephyr /opt/spack_env/default
COPY --chown=kvothe:kvothe container/entrypoints /opt/container_entrypoints
COPY --chown=kvothe:kvothe container/spack_owned_packages.conf /opt/container_entrypoints/spack_owned_packages.conf
COPY --chown=kvothe:kvothe container/nvidia_overrides.txt /opt/container_entrypoints/nvidia_overrides.txt
RUN chmod +x /opt/container_entrypoints/*.sh
```

### 4. Commented-out setup_user_environment.sh

Lines 247–250 contain a commented-out block:

```dockerfile
# container/dev_container.dockerfile:247-250
# # Copy and run user environment setup script
# COPY setup_user_environment.sh /tmp/setup_user_environment.sh
# RUN /tmp/setup_user_environment.sh ${RUST_VERSION} ${PYTHON_VERSION} && \
#     rm /tmp/setup_user_environment.sh
```

The script is referenced in the `ARG` declarations (`RUST_VERSION`, `PYTHON_VERSION`)
but never executed. The comment block has been present without explanation. Either
the script should be re-enabled with a note explaining its purpose, or the dead
block and the related `ARG` declarations should be removed to avoid confusion.

### 5. Missing build-time labels on intermediate layers

Labels (lines 264–274) are added only at the end of the Dockerfile. Labels on
intermediate stages (e.g., `ARG`/`ENV` declarations) would help cache
introspection. The existing labels do not include a `git.commit` or
`build.timestamp` label, making it impossible to correlate an image to the
exact source revision that produced it.

---

## Proposed Changes

### 1. Merge the apt cleanup and install layers

```dockerfile
# Single RUN: clean stale lists, then install
RUN rm -f /etc/apt/sources.list.d/kubernetes.list \
    /etc/apt/sources.list.d/google-cloud-sdk.list \
    /etc/apt/sources.list.d/cuda*.list \
    /etc/apt/sources.list.d/nvidia*.list \
    /etc/apt/trusted.gpg.d/kubernetes.gpg \
    /etc/apt/trusted.gpg.d/google-cloud-sdk.gpg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get update && apt-get install -y --no-install-recommends \
    ...
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
```

### 2. Add a `SPACK_SHA` ARG and verify the clone

```dockerfile
ARG SPACK_SHA=<40-char-sha>
RUN git clone -c feature.manyFiles=true --depth 1 \
    https://github.com/spack/spack.git /opt/spack_src \
    && git -C /opt/spack_src checkout "${SPACK_SHA}"
```

Keeping `SPACK_VERSION` as a human-readable label is acceptable; the integrity
guarantee comes from the SHA.

### 3. Reorder COPY to defer frequently-changing content

Move `COPY pkg/zephyr` to after the user setup block (i.e., just before the
`WORKDIR /workspace` line). Entrypoints change less frequently than Spack
environment specs.

### 4. Resolve the setup_user_environment.sh dead code

If the script is not required, remove the commented block and drop the
unreferenced `RUST_VERSION` ARG from the Dockerfile. If it is required, restore
the `COPY`/`RUN` block and document what it does.

### 5. Add reproducibility labels

```dockerfile
ARG GIT_COMMIT=unknown
ARG BUILD_DATE=unknown
LABEL git.commit="${GIT_COMMIT}"
LABEL build.date="${BUILD_DATE}"
```

Pass these in the build invocation:
```bash
docker build \
  --build-arg GIT_COMMIT="$(git rev-parse HEAD)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  ...
```

---

## Files Changed

| File | Action |
|------|--------|
| `container/dev_container.dockerfile` | Merge apt layers, pin Spack SHA, reorder COPY, resolve dead code, add reproducibility labels |

---

## Verification

```bash
docker build \
  --build-arg HOST_UID="$(id -u)" \
  --build-arg HOST_GID="$(id -g)" \
  -t sygaldry/zephyr:rfc013-test \
  -f container/dev_container.dockerfile .

docker image inspect sygaldry/zephyr:rfc013-test | jq '.[0].Config.Labels'
```

Confirm the image builds to completion and labels include `git.commit` and
`build.date`.
