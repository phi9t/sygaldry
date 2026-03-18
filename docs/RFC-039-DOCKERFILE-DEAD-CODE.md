# RFC-039: Remove Commented-Out Dead Code from Dockerfile

**Status:** Proposed
**Priority:** Low
**Effort:** XS
**Area:** docker

## Problem

`container/dev_container.dockerfile` contains a commented-out block that COPY and RUN a `setup_user_environment.sh` script. The block appears to have been disabled intentionally at some point but was never removed. It creates ambiguity: does the setup still happen via another mechanism, or has it been abandoned?

Having dead code in a Dockerfile also causes Docker build context confusion — the file is still referenced in the `COPY` instruction comments, suggesting it may still be needed.

## Evidence

`container/dev_container.dockerfile` lines ~247-250 (approximate):
```dockerfile
# COPY container/setup_user_environment.sh /tmp/setup_user_environment.sh
# RUN /tmp/setup_user_environment.sh && rm /tmp/setup_user_environment.sh
```

The `container/setup_user_environment.sh` file does exist on disk (confirmed by Glob search), so the script is maintained but the Dockerfile no longer runs it.

## Proposed Changes

1. Determine whether `setup_user_environment.sh` is still needed during image build:
   - If yes: uncomment the `COPY`/`RUN` lines and verify the image builds correctly.
   - If no: delete the commented block from the Dockerfile and add a note explaining where (if anywhere) user environment setup now happens.

2. If the script is only needed at runtime (container startup), document this clearly and invoke it from the relevant entrypoint script instead.

3. Run `shellcheck` on `setup_user_environment.sh` to ensure it is still well-formed.

## Files Changed

- `container/dev_container.dockerfile` — remove or uncomment the dead block
- `container/setup_user_environment.sh` — verify still valid, or remove if unused

## Verification

```bash
# If uncommented:
docker build -f container/dev_container.dockerfile -t sygaldry/zephyr:test-setup .
# Image must build without error.
shellcheck -s bash -S warning container/setup_user_environment.sh
```
