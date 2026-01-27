# Zephyr release manifests

Each release writes an immutable image manifest at:

- `container/releases/<release_id>/image-set.json`

The manifest schema version is `sygaldry-zephyr-image-set/v1` and is used by
`container/publish.sh` for candidate verification, promotion, and rollback.

## Shape

```json
{
  "schema_version": "sygaldry-zephyr-image-set/v1",
  "release_id": "20260226-190000",
  "generated_at_utc": "2026-02-26T19:00:00Z",
  "registry_base": "ghcr.io/phi9t/sygaldry/zephyr",
  "images": [
    {
      "name": "spack",
      "stable_tag": "spack",
      "candidate_tag": "spack-20260226-ab12cd3",
      "source_ref": "ghcr.io/phi9t/sygaldry/zephyr:spack-20260226-ab12cd3",
      "source_digest": "sha256:..."
    }
  ]
}
```
