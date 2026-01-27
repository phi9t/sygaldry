#!/usr/bin/env python3
import argparse
import json
import os
import random
import time
import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

DEFAULT_MODELS = [
    "Qwen/Qwen3-0.6B-Base",
    "Qwen/Qwen3-1.7B-Base",
    "Qwen/Qwen3-4B-Base",
    "Qwen/Qwen3-8B-Base",
    "Qwen/Qwen3-14B-Base",
    "Qwen/Qwen3-32B-Base",
]


def pick_dtype():
    if torch.cuda.is_available():
        if torch.cuda.is_bf16_supported():
            return torch.bfloat16
        return torch.float16
    return torch.float32


def set_seed(seed: int):
    """Set random seeds for reproducibility."""
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def gpu_mem():
    if not torch.cuda.is_available():
        return []
    mem = []
    for i in range(torch.cuda.device_count()):
        free, total = torch.cuda.mem_get_info(i)
        mem.append(
            {"gpu": i, "free_gb": free / (1024**3), "total_gb": total / (1024**3)}
        )
    return mem


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", nargs="*", default=DEFAULT_MODELS)
    parser.add_argument(
        "--model",
        type=str,
        default=None,
        help="Single model to test (overrides --models)",
    )
    parser.add_argument("--max-new-tokens", type=int, default=16)
    parser.add_argument("--out", default="/opt/bazel_cache/qwen3_scale_test.json")
    parser.add_argument(
        "--seed", type=int, default=None, help="Random seed for reproducibility"
    )
    args = parser.parse_args()

    if args.seed is not None:
        set_seed(args.seed)

    if args.model:
        args.models = [args.model]

    results = []
    dtype = pick_dtype()
    print(f"DType: {dtype}")
    print(f"GPUs: {torch.cuda.device_count()}")
    print(f"Seed: {args.seed}")
    print(f"HF_HOME: {os.environ.get('HF_HOME')}")

    for model_id in args.models:
        print(f"\n=== Trying {model_id} ===")
        start = time.time()
        ok = True
        err = None
        try:
            tokenizer = AutoTokenizer.from_pretrained(model_id, use_fast=True)
            model = AutoModelForCausalLM.from_pretrained(
                model_id,
                torch_dtype=dtype,
                device_map="auto",
            )
            model.eval()
            inputs = tokenizer("Hello from Qwen3.", return_tensors="pt").to(
                model.device
            )
            with torch.no_grad():
                _ = model.generate(**inputs, max_new_tokens=args.max_new_tokens)
        except Exception as e:
            ok = False
            err = repr(e)
        finally:
            try:
                del model
            except Exception:
                pass
            torch.cuda.empty_cache()
        duration = time.time() - start
        entry = {
            "model": model_id,
            "ok": ok,
            "error": err,
            "seconds": round(duration, 2),
            "gpu_mem": gpu_mem(),
        }
        results.append(entry)
        print(entry)
        if not ok:
            break

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nWrote: {args.out}")


if __name__ == "__main__":
    main()
