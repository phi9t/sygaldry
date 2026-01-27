#!/usr/bin/env python3
import argparse
import os
import time

import torch


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="GPU sanity checks for Zephyr container"
    )
    parser.add_argument(
        "--size",
        type=int,
        default=int(os.getenv("MATMUL_SIZE", "2048")),
        help="Matrix size for matmul test (default: env MATMUL_SIZE or 2048)",
    )
    parser.add_argument(
        "--dtype",
        type=str,
        default=os.getenv("MATMUL_DTYPE", "float32"),
        choices=["float16", "float32", "bfloat16"],
        help="Matrix dtype for matmul test (default: env MATMUL_DTYPE or float32)",
    )
    return parser.parse_args()


def get_dtype(name: str) -> torch.dtype:
    mapping = {
        "float16": torch.float16,
        "float32": torch.float32,
        "bfloat16": torch.bfloat16,
    }
    return mapping[name]


def main() -> int:
    args = parse_args()
    dtype = get_dtype(args.dtype)

    print(f"torch={torch.__version__}")
    print(f"cuda_available={torch.cuda.is_available()}")

    if not torch.cuda.is_available():
        print("cuda_unavailable: ensure SYGALDRY_GPU=true and nvidia runtime")
        return 1

    count = torch.cuda.device_count()
    print(f"device_count={count}")

    for i in range(count):
        props = torch.cuda.get_device_properties(i)
        total_gb = props.total_memory / (1024**3)
        cc = f"{props.major}.{props.minor}"
        print(f"cuda:{i} name={props.name} cc={cc} mem_gb={total_gb:.1f}")

        device = torch.device(f"cuda:{i}")
        torch.cuda.set_device(device)
        torch.cuda.reset_peak_memory_stats(device)

        a = torch.randn(args.size, args.size, device=device, dtype=dtype)
        b = torch.randn(args.size, args.size, device=device, dtype=dtype)
        torch.cuda.synchronize(device)
        t0 = time.time()
        c = a @ b
        torch.cuda.synchronize(device)
        dt = time.time() - t0

        checksum = float(c.float().sum().item())
        allocated = torch.cuda.memory_allocated(device) / (1024**2)
        reserved = torch.cuda.memory_reserved(device) / (1024**2)
        peak = torch.cuda.max_memory_allocated(device) / (1024**2)

        mem_info = "n/a"
        if hasattr(torch.cuda, "mem_get_info"):
            free_b, total_b = torch.cuda.mem_get_info(device)
            mem_info = (
                f"free_gb={free_b / (1024**3):.1f} total_gb={total_b / (1024**3):.1f}"
            )

        print(
            " ".join(
                [
                    f"cuda:{i}",
                    f"matmul_s={dt:.3f}",
                    f"alloc_mb={allocated:.1f}",
                    f"reserved_mb={reserved:.1f}",
                    f"peak_mb={peak:.1f}",
                    f"checksum={checksum:.4f}",
                    mem_info,
                ]
            )
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
