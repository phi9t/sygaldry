import sys

errors = []

try:
    import torch

    if not torch.cuda.is_available():
        errors.append("torch.cuda.is_available() is False")
    elif torch.cuda.device_count() < 1:
        errors.append("torch reports zero CUDA devices")
    else:
        device = torch.device("cuda")
        a = torch.randn(64, 64, device=device)
        b = torch.randn(64, 64, device=device)
        c = torch.matmul(a, b)
        assert c.shape == (64, 64)
        print(
            f"PyTorch CUDA: OK (device={torch.cuda.get_device_name(0)})",
            file=sys.stderr,
        )
except Exception as exc:
    errors.append(f"torch: {exc}")

try:
    import jax

    devices = jax.devices()
    gpu_devices = [d for d in devices if d.platform == "gpu"]
    if not gpu_devices:
        errors.append(f"jax has no GPU devices (devices={devices})")
    else:
        import jax.numpy as jnp

        key = jax.random.PRNGKey(0)
        a = jax.random.normal(key, (64, 64))
        b = jax.random.normal(key, (64, 64))
        c = jnp.matmul(a, b)
        assert c.shape == (64, 64)
        print(f"JAX GPU: OK (devices={gpu_devices})", file=sys.stderr)
except Exception as exc:
    errors.append(f"jax: {exc}")

if errors:
    print("GPU validation FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print("GPU validation passed: Torch and JAX both see a CUDA GPU.", file=sys.stderr)
