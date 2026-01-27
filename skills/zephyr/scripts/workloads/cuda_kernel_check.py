#!/usr/bin/env python3
import json
import sys

import numpy as np
from numba import cuda


@cuda.jit
def vec_add(a, b, out):
    i = cuda.grid(1)
    if i < out.size:
        out[i] = a[i] + b[i]


def main() -> int:
    if not cuda.is_available():
        print("CUDA is not available", file=sys.stderr)
        return 2

    n = 1 << 20
    a = np.random.default_rng(0).standard_normal(n, dtype=np.float32)
    b = np.random.default_rng(1).standard_normal(n, dtype=np.float32)

    d_a = cuda.to_device(a)
    d_b = cuda.to_device(b)
    d_out = cuda.device_array(n, dtype=np.float32)

    threads = 256
    blocks = (n + threads - 1) // threads
    vec_add[blocks, threads](d_a, d_b, d_out)
    cuda.synchronize()

    out = d_out.copy_to_host()
    ref = a + b
    max_abs = float(np.max(np.abs(out - ref)))
    ok = np.allclose(out, ref, atol=1e-5)

    device = cuda.get_current_device()
    print(
        json.dumps(
            {
                "workload": "cuda_kernel_check",
                "device": str(device.name),
                "n": n,
                "threads": threads,
                "blocks": blocks,
                "max_abs_error": max_abs,
            }
        )
    )

    if not ok:
        print(f"kernel mismatch: max_abs_error={max_abs}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
