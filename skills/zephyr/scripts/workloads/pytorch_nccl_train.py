#!/usr/bin/env python3
import json
import os
import sys

import torch
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP


def main() -> int:
    if not dist.is_available():
        print("torch.distributed not available", file=sys.stderr)
        return 2

    rank = int(os.environ["RANK"])
    local_rank = int(os.environ["LOCAL_RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    steps = int(os.environ.get("NCCL_STEPS", "40"))

    torch.cuda.set_device(local_rank)
    dist.init_process_group(backend="nccl")
    device = torch.device(f"cuda:{local_rank}")

    torch.manual_seed(1337 + rank)
    model = torch.nn.Sequential(
        torch.nn.Linear(64, 128),
        torch.nn.GELU(),
        torch.nn.Linear(128, 16),
    ).to(device)
    ddp_model = DDP(model, device_ids=[local_rank], output_device=local_rank)
    opt = torch.optim.AdamW(ddp_model.parameters(), lr=3e-3)

    target_weight = torch.randn(64, 16, device=device)
    target_bias = torch.randn(16, device=device)

    losses = []
    for step in range(steps):
        x = torch.randn(256, 64, device=device)
        y = x @ target_weight + target_bias
        pred = ddp_model(x)
        loss = torch.nn.functional.mse_loss(pred, y)

        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()

        losses.append(float(loss.detach().item()))
        if step % 10 == 0:
            print(f"rank={rank} step={step} loss={losses[-1]:.6f}", flush=True)

    initial = torch.tensor(losses[0], device=device)
    final = torch.tensor(losses[-1], device=device)
    dist.all_reduce(initial, op=dist.ReduceOp.SUM)
    dist.all_reduce(final, op=dist.ReduceOp.SUM)

    mean_initial = float((initial / world_size).item())
    mean_final = float((final / world_size).item())

    if rank == 0:
        print(
            json.dumps(
                {
                    "workload": "pytorch_nccl_train",
                    "world_size": world_size,
                    "mean_initial_loss": mean_initial,
                    "mean_final_loss": mean_final,
                }
            )
        )

    ok = torch.isfinite(torch.tensor(mean_final)) and mean_final < mean_initial

    dist.barrier()
    dist.destroy_process_group()

    if not ok:
        if rank == 0:
            print(
                f"loss did not improve: initial={mean_initial:.6f} final={mean_final:.6f}",
                file=sys.stderr,
            )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
