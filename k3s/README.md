# K3s Integration for Sygaldry

Lightweight Kubernetes substrate for GPU dev pods and batch jobs. Same images, same entrypoints, same volume layout as the Docker path — with K8s scheduling semantics and tmux-persistent interactive access.

K3s is **additive**. The Docker path (`launch_container.sh`) remains the default and is not modified.

## Quick Start

### 1. Bootstrap (one-time, as root)

```bash
sudo k3s/bootstrap/install-k3s.sh
sudo k3s/bootstrap/setup-nvidia.sh
sudo k3s/bootstrap/import-image.sh sygaldry/zephyr:spack-20260212-082355
```

### 2. Interactive Dev Pod

```bash
# Create or attach to a dev pod (uses tmux for persistence)
k3s/bin/kentai

# Specific project
k3s/bin/kentai --project-id my-project

# Multi-repo mode
k3s/bin/kentai --repo /path/to/external-repo

# Request 2 GPUs
k3s/bin/kentai --gpu 2

# Via sygaldry CLI
sygaldry k3s enter --project-id my-project
```

Disconnect from tmux (`Ctrl-b d`) and reconnect later — the session survives:

```bash
kentai --project-id my-project  # re-attaches to existing tmux session
```

### 3. Batch Jobs

```bash
k3s/bin/kjob run --project-id test --job gpu-check -- "nvidia-smi"
k3s/bin/kjob tail --project-id test --job gpu-check
k3s/bin/kjob status --project-id test
k3s/bin/kjob list --project-id test
k3s/bin/kjob stop --project-id test --job gpu-check

# Via sygaldry CLI
sygaldry k3s job run --project-id test --job train -- "python train.py"
```

### 4. Temporal Integration

Use `k8s_job` step type in pipeline YAML:

```yaml
steps:
  - id: gpu-check
    type: k8s_job
    k8s_job:
      project_id: my-project
      command: "nvidia-smi"
      gpu: true
      gpu_count: 1
```

## Architecture

### Docker vs K3s Equivalents

| Docker Flag | K8s Equivalent |
|---|---|
| `--runtime=nvidia --gpus=all` | `runtimeClassName: nvidia` + `resources.limits.nvidia.com/gpu: N` |
| `--net=host --ipc=host` | `hostNetwork: true`, `hostIPC: true` |
| `--user=${uid}:${gid}` | `securityContext.runAsUser/runAsGroup/fsGroup` |
| `-v host:container` | `hostPath` volumes |

### Volume Layout

Direct `hostPath` mounts (no PV/PVC — single-node K3s, same host storage):

- **5 per-project:** home, config, local_share, outputs, workspace
- **7 shared caches:** hf, uv, bazel, torch, triton, nv_compute, jax
- **1 spack store:** read-only, 42GB shared artifact
- **4 entrypoints/lib:** read-only from sygaldry repo

## Directory Structure

```
k3s/
├── bootstrap/
│   ├── install-k3s.sh            # K3s single-node install
│   ├── setup-nvidia.sh           # containerd nvidia runtime + device plugin
│   ├── import-image.sh           # Docker → K3s containerd image import
│   └── teardown.sh               # Clean uninstall
├── manifests/
│   ├── namespace.yaml            # sygaldry namespace
│   ├── nvidia-runtime-class.yaml # RuntimeClass: nvidia
│   └── configmap-env.yaml        # Environment ConfigMap
├── templates/
│   ├── dev-pod.yaml              # Interactive dev pod template
│   ├── dev-pod-multirepo.yaml    # Multi-repo variant
│   └── job.yaml                  # Batch job template
├── bin/
│   ├── kentai                    # Dev pod CLI
│   └── kjob                      # Batch job CLI
├── lib/
│   └── k3s-common.sh             # Shared functions
└── README.md
```

## GPU Quota and Affinity

K3s has no built-in GPU quota enforcement beyond what the NVIDIA device plugin provides.
Multiple concurrent `kentai` sessions or `kjob` runs can saturate all GPUs on the node.

**Checking GPU usage:**
```bash
nvidia-smi                     # live GPU utilization per process
kubectl get pods -n sygaldry  # all active pods
kubectl top pod -n sygaldry   # CPU/mem (does not show GPU)
```

**Limiting GPU count per job:**
```bash
# Request exactly 1 GPU for a batch job
k3s/bin/kjob run --project-id my-proj --job train --gpu 1 -- "python train.py"

# Interactive dev pod with 2 GPUs
k3s/bin/kentai --project-id ml-dev --gpu 2
```

**Namespace-level resource quota (optional):**
To cap total GPU allocation across all pods in the `sygaldry` namespace, apply a `ResourceQuota`:
```yaml
# k3s/manifests/gpu-quota.yaml (not applied by default)
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: sygaldry
spec:
  hard:
    requests.nvidia.com/gpu: "4"
    limits.nvidia.com/gpu: "4"
```
```bash
kubectl apply -f k3s/manifests/gpu-quota.yaml
kubectl describe resourcequota gpu-quota -n sygaldry  # check usage
```

**Notes:**
- GPU requests are exclusive: a pod requesting 2 GPUs holds them until the pod terminates.
- Batch jobs (`kjob`) default TTL is 24h; stopped jobs release GPUs immediately.
- There is no affinity policy — the scheduler places pods on the single node.
- For multi-GPU NCCL jobs, all GPUs must be on the same node (single-node K3s satisfies this).

## Teardown

```bash
sudo k3s/bootstrap/teardown.sh
```
