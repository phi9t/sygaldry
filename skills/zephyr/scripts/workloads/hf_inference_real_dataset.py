#!/usr/bin/env python3
import argparse
import json
import os
import statistics
import sys
import time
from pathlib import Path


def _prefer_active_venv_site_packages() -> None:
    venv = os.environ.get("VIRTUAL_ENV", "")
    if not venv:
        return
    py_ver = f"{sys.version_info.major}.{sys.version_info.minor}"
    venv_site = os.path.join(venv, "lib", f"python{py_ver}", "site-packages")
    if not os.path.isdir(venv_site):
        return
    sys.path[:] = [venv_site] + [p for p in sys.path if p != venv_site]


_prefer_active_venv_site_packages()

import torch  # noqa: E402
from datasets import load_dataset  # noqa: E402
from transformers import AutoModelForSequenceClassification, AutoTokenizer  # noqa: E402


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run real HF inference workload on CUDA")
    p.add_argument(
        "--model-id", default="distilbert-base-uncased-finetuned-sst-2-english"
    )
    p.add_argument("--dataset-id", default="ag_news")
    p.add_argument("--dataset-config", default="")
    p.add_argument("--split", default="test[:5000]")
    p.add_argument("--text-column", default="text")
    p.add_argument("--batch-size", type=int, default=64)
    p.add_argument("--max-length", type=int, default=256)
    p.add_argument("--seed", type=int, default=2026)
    p.add_argument(
        "--report-path",
        default="/workspace/zephyr_validation/reports/hf_inference_report.json",
    )
    return p.parse_args()


def percentile(vals: list[float], q: float) -> float:
    if not vals:
        return 0.0
    vals = sorted(vals)
    idx = (len(vals) - 1) * q
    lo = int(idx)
    hi = min(lo + 1, len(vals) - 1)
    f = idx - lo
    return vals[lo] * (1.0 - f) + vals[hi] * f


def main() -> int:
    args = parse_args()

    if not torch.cuda.is_available():
        print("CUDA unavailable for hf inference workload", file=sys.stderr)
        return 2

    torch.manual_seed(args.seed)
    torch.cuda.manual_seed_all(args.seed)

    device = torch.device("cuda")
    hf_home = os.environ.get("HF_HOME", "")

    load_start = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(args.model_id)
    model = AutoModelForSequenceClassification.from_pretrained(args.model_id)
    model.to(device)
    model.eval()
    model_load_seconds = time.perf_counter() - load_start

    ds_kwargs = {"path": args.dataset_id, "split": args.split}
    if args.dataset_config:
        ds_kwargs["name"] = args.dataset_config
    if hf_home:
        ds_kwargs["cache_dir"] = hf_home

    data_start = time.perf_counter()
    ds = load_dataset(**ds_kwargs)
    data_load_seconds = time.perf_counter() - data_start

    if args.text_column not in ds.column_names:
        print(
            f"text column '{args.text_column}' not in dataset columns {ds.column_names}",
            file=sys.stderr,
        )
        return 2

    texts = ds[args.text_column]
    total_samples = len(texts)
    if total_samples == 0:
        print("dataset split returned zero rows", file=sys.stderr)
        return 2

    latencies_ms: list[float] = []
    processed = 0

    torch.cuda.reset_peak_memory_stats(device)
    start = time.perf_counter()
    with torch.inference_mode():
        for i in range(0, total_samples, args.batch_size):
            batch = texts[i : i + args.batch_size]
            tok = tokenizer(
                batch,
                return_tensors="pt",
                truncation=True,
                padding=True,
                max_length=args.max_length,
            )
            tok = {k: v.to(device, non_blocking=True) for k, v in tok.items()}

            step_start = time.perf_counter()
            with torch.autocast(device_type="cuda", dtype=torch.float16):
                out = model(**tok)
                _ = out.logits.argmax(dim=-1)
            torch.cuda.synchronize(device)
            step_ms = (time.perf_counter() - step_start) * 1000.0
            latencies_ms.append(step_ms)
            processed += len(batch)

    elapsed = time.perf_counter() - start
    throughput = processed / elapsed if elapsed > 0 else 0.0
    peak_mem = int(torch.cuda.max_memory_allocated(device))

    result = {
        "suite": "hf_inference_real_dataset",
        "status": "PASS",
        "image": os.environ.get("SYGALDRY_IMAGE", "unknown"),
        "model_id": args.model_id,
        "dataset_id": args.dataset_id,
        "dataset_config": args.dataset_config,
        "split": args.split,
        "text_column": args.text_column,
        "batch_size": args.batch_size,
        "max_length": args.max_length,
        "device": str(device),
        "dtype": "fp16-autocast",
        "timings": {
            "model_load_seconds": round(model_load_seconds, 6),
            "dataset_load_seconds": round(data_load_seconds, 6),
            "inference_seconds": round(elapsed, 6),
        },
        "throughput": {
            "samples": processed,
            "samples_per_second": round(throughput, 3),
        },
        "latency_ms": {
            "count": len(latencies_ms),
            "mean": round(statistics.fmean(latencies_ms), 3),
            "p50": round(percentile(latencies_ms, 0.5), 3),
            "p95": round(percentile(latencies_ms, 0.95), 3),
            "max": round(max(latencies_ms), 3),
        },
        "cuda_memory_bytes": {
            "max_allocated": peak_mem,
        },
        "env": {
            "HF_HOME": hf_home,
        },
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    report_path = Path(args.report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    print(json.dumps(result))

    if processed != total_samples or throughput <= 0 or peak_mem <= 0:
        print(
            f"bad metrics: processed={processed}/{total_samples} throughput={throughput:.3f} peak_mem={peak_mem}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
