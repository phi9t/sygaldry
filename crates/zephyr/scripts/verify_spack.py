import sys

errors = []

# === Torch ===
print("[verify-spack] --- PyTorch verification ---")
try:
    import torch

    if not torch.cuda.is_available():
        raise RuntimeError("CUDA not available")
    device = torch.device("cuda")
    print("[verify-spack] torch.cuda.is_available(): True")
    print(f"[verify-spack] Device: {torch.cuda.get_device_name(0)}")

    a = torch.randn(100, 100, device=device)
    b = torch.randn(100, 100, device=device)
    c = torch.matmul(a, b)
    assert c.shape == (100, 100)
    print("[verify-spack] Tensor matmul: OK")

    model = torch.nn.Sequential(
        torch.nn.Linear(100, 64), torch.nn.ReLU(), torch.nn.Linear(64, 10)
    ).to(device)
    x = torch.randn(32, 100, device=device)
    y = model(x)
    y.sum().backward()
    for name, param in model.named_parameters():
        if param.grad is None:
            raise RuntimeError(f"No gradient for {name}")
    print("[verify-spack] Neural network forward + backward: OK")
    print("[verify-spack] torch: PASSED")
except Exception as e:
    errors.append(f"torch: {e}")
    print(f"[verify-spack] torch: FAILED - {e}", file=sys.stderr)

# === JAX ===
print("[verify-spack] --- JAX verification ---")
try:
    import jax
    import jax.numpy as jnp

    devices = jax.devices()
    gpu_devices = [d for d in devices if d.platform == "gpu"]
    if not gpu_devices:
        raise RuntimeError(f"No GPU devices (available: {devices})")
    print(f"[verify-spack] JAX devices: {devices}")

    key = jax.random.PRNGKey(0)
    a = jax.random.normal(key, (100, 100))
    c = jnp.matmul(a, a)
    assert c.shape == (100, 100)
    print("[verify-spack] Tensor matmul: OK")

    def loss_fn(params, x, y):
        W1, b1, W2, b2 = params
        h = jax.nn.relu(x @ W1 + b1)
        return jnp.mean((h @ W2 + b2 - y) ** 2)

    k1, k2, k3, k4 = jax.random.split(key, 4)
    params = (
        jax.random.normal(k1, (100, 64)) * 0.01,
        jnp.zeros(64),
        jax.random.normal(k2, (64, 10)) * 0.01,
        jnp.zeros(10),
    )
    grads = jax.grad(loss_fn)(
        params, jax.random.normal(k3, (32, 100)), jax.random.normal(k4, (32, 10))
    )
    assert grads[0].shape == (100, 64)
    print("[verify-spack] Neural network forward + gradient: OK")
    print("[verify-spack] jax: PASSED")
except Exception as e:
    errors.append(f"jax: {e}")
    print(f"[verify-spack] jax: FAILED - {e}", file=sys.stderr)

if errors:
    print("\n[verify-spack] === VERIFICATION FAILED ===", file=sys.stderr)
    for e in errors:
        print(f"[verify-spack] ERROR: {e}", file=sys.stderr)
    sys.exit(1)
print("\n[verify-spack] === VERIFICATION PASSED ===")
