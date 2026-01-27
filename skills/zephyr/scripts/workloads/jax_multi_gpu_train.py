#!/usr/bin/env python3
import json
import sys

import jax
import jax.numpy as jnp


def main() -> int:
    gpu_devices = [d for d in jax.devices() if d.platform == "gpu"]
    if len(gpu_devices) < 2:
        print(f"need >=2 GPUs, found {gpu_devices}", file=sys.stderr)
        return 2

    ndev = len(gpu_devices)
    key = jax.random.PRNGKey(2026)

    in_dim = 32
    out_dim = 8
    batch_per_dev = 128
    steps = 60

    k1, k2, k3 = jax.random.split(key, 3)
    true_w = jax.random.normal(k1, (in_dim, out_dim))
    true_b = jax.random.normal(k2, (out_dim,))

    params = {
        "w": jax.random.normal(k3, (in_dim, out_dim)) * 0.05,
        "b": jnp.zeros((out_dim,)),
    }

    params = jax.device_put_replicated(params, gpu_devices)

    def loss_fn(p, x, y):
        pred = x @ p["w"] + p["b"]
        return jnp.mean((pred - y) ** 2)

    @jax.pmap(axis_name="data")
    def train_step(p, x, y):
        loss, grads = jax.value_and_grad(loss_fn)(p, x, y)
        grads = jax.lax.pmean(grads, axis_name="data")
        lr = 1e-2
        new_p = {
            "w": p["w"] - lr * grads["w"],
            "b": p["b"] - lr * grads["b"],
        }
        mean_loss = jax.lax.pmean(loss, axis_name="data")
        return new_p, mean_loss

    losses = []
    for step in range(steps):
        kb = jax.random.fold_in(key, step)
        x = jax.random.normal(kb, (ndev, batch_per_dev, in_dim))
        y = jnp.einsum("dbi,io->dbo", x, true_w) + true_b
        params, loss = train_step(params, x, y)
        loss_scalar = float(loss[0])
        losses.append(loss_scalar)
        if step % 10 == 0:
            print(f"step={step} loss={loss_scalar:.6f}", flush=True)

    initial = losses[0]
    final = losses[-1]
    print(
        json.dumps(
            {
                "workload": "jax_multi_gpu_train",
                "devices": [str(d) for d in gpu_devices],
                "initial_loss": initial,
                "final_loss": final,
            }
        )
    )

    if not jnp.isfinite(final) or final >= initial:
        print(f"loss did not improve: initial={initial:.6f} final={final:.6f}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
