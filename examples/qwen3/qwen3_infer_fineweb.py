#!/usr/bin/env python3
import argparse
import os
import random
import numpy as np
import torch
from datasets import load_dataset
from transformers import AutoModelForCausalLM, AutoTokenizer


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="Qwen/Qwen3-0.6B-Base")
    parser.add_argument("--max-new-tokens", type=int, default=64)
    parser.add_argument("--rows", type=int, default=5)
    parser.add_argument("--streaming", action="store_true", default=False)
    parser.add_argument(
        "--seed", type=int, default=None, help="Random seed for reproducibility"
    )
    args = parser.parse_args()

    if args.seed is not None:
        set_seed(args.seed)

    dtype = pick_dtype()
    tokenizer = AutoTokenizer.from_pretrained(args.model, use_fast=True)
    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        torch_dtype=dtype,
        device_map="auto",
    )
    model.eval()

    ds = load_dataset(
        "HuggingFaceFW/fineweb",
        "default",
        split="train",
        streaming=args.streaming,
    )

    print(f"Model: {args.model}")
    print(f"DType: {dtype}")
    print(f"Seed: {args.seed}")
    print(f"HF_HOME: {os.environ.get('HF_HOME')}")

    with torch.no_grad():
        for i, row in enumerate(ds.take(args.rows)):
            text = row["text"].strip().replace("\n", " ")
            prompt = text[:512]
            inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
            outputs = model.generate(**inputs, max_new_tokens=args.max_new_tokens)
            decoded = tokenizer.decode(outputs[0], skip_special_tokens=True)
            print(f"\n=== Sample {i+1} ===")
            print(decoded)


if __name__ == "__main__":
    main()
