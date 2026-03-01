# Temporal Plan Schema Reference

Source of truth: `temporal/schema/pipeline.schema.json`

A plan file is a YAML document with a required `steps` array and optional top-level fields.

## Top-Level Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `steps` | array | yes | Ordered list of step definitions |
| `params` | object (string values) | no | Plan-level parameters; overridable with `-set k=v` at runtime |
| `env` | object (string values) | no | Environment variables injected into all steps |
| `log_dir` | string | no | Override the log output directory |
| `imports` | array of strings | no | Paths to YAML files whose `templates` block is merged in |
| `templates` | object | no | Named step templates; steps reference them with `template:` |

## Step Fields (Common to All Types)

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Unique step identifier; used in `depends_on` and interpolation |
| `type` | string | yes* | Step type (see below). Required unless `template` is set |
| `name` | string | no | Human-readable label shown in logs and visualizer |
| `template` | string | no | Name of a template to inherit from; overrides `type` requirement |
| `depends_on` | array of strings | no | Step IDs that must complete before this step runs |
| `when` | object | no | Conditional execution based on another step's status |
| `allow_failure` | boolean | no | If true, pipeline continues even if this step fails |
| `timeout_seconds` | integer (≥1) | no | Per-step timeout; step is failed if exceeded |
| `retry` | object | no | Retry policy (see below) |
| `command` | string | no | Shell command (used by `command` and `package_build` types) |
| `args` | array of strings | no | Arguments passed to `command` |
| `env` | object | no | Step-level environment variables (merged with plan-level `env`) |
| `working_dir` | string | no | Working directory for the step |

### `when` Clause

Runs the step only when a specific dependency has a given outcome:

```yaml
when:
  step: <step-id>       # must be in depends_on
  status: success       # or: failure
```

A step with `when: {step: X, status: failure}` is a failure handler for step X.

### `retry` Policy

```yaml
retry:
  max_attempts: 3               # total attempts (including the first)
  initial_interval_seconds: 10  # wait before first retry
  backoff_coefficient: 2.0      # multiplier applied each retry
  maximum_interval_seconds: 300 # cap on wait interval
```

## Step Types

### `command`

Run an arbitrary shell command on the worker host.

```yaml
- id: greet
  type: command
  command: bash
  args: [-lc, "echo hello from $USER"]
```

Required payload fields: `command` (at the step level, not in a sub-object).

### `download`

Download a file, with optional SHA-256 verification.

```yaml
- id: get-data
  type: download
  download:
    url: https://example.com/data.tar.gz
    output: /workspace/data.tar.gz
    sha256: abc123...          # optional
```

| Field | Required | Description |
|---|---|---|
| `url` | yes | URL to download |
| `output` | yes | Destination path |
| `sha256` | no | Expected SHA-256 hex digest |

### `docker_build`

Build a Docker image.

```yaml
- id: build-image
  type: docker_build
  docker_build:
    image: ghcr.io/myorg/myimage:latest
    context: .
    dockerfile: Dockerfile
    build_args:
      VERSION: "1.0"
    target: prod
```

| Field | Required | Description |
|---|---|---|
| `image` | yes | Image name and tag |
| `context` | no | Build context path (default: `.`) |
| `dockerfile` | no | Path to Dockerfile |
| `build_args` | no | `--build-arg` key/value pairs |
| `labels` | no | Image label key/value pairs |
| `platform` | no | Target platform (e.g. `linux/amd64`) |
| `target` | no | Build stage target |

### `docker_push`

Push a Docker image to a registry.

```yaml
- id: push-image
  type: docker_push
  docker_push:
    image: ghcr.io/myorg/myimage:latest
```

| Field | Required | Description |
|---|---|---|
| `image` | yes | Image name and tag to push |

### `package_build`

Run a package build command with optional environment and working directory.

```yaml
- id: build-pkg
  type: package_build
  package_build:
    command: make
    args: ["-j4", "install"]
    working_dir: /workspace/mylib
    env:
      PREFIX: /opt/mylib
```

| Field | Required | Description |
|---|---|---|
| `command` | yes | Command to run |
| `args` | no | Arguments |
| `env` | no | Environment variables |
| `working_dir` | no | Working directory |

### `container_job`

Run a command inside a Sygaldry GPU container.

```yaml
- id: train
  type: container_job
  container_job:
    project_id: my-project
    entrypoint: run-job.sh
    gpu: true
    command: python train.py --epochs 10
    env:
      BATCH_SIZE: "32"
  timeout_seconds: 86400
```

| Field | Required | Description |
|---|---|---|
| `command` | yes | Command to run inside the container |
| `project_id` | no | Project isolation namespace (default: `default`) |
| `entrypoint` | no | Container entrypoint script (default: `run-job.sh`) |
| `gpu` | no | If true, NVIDIA GPU is requested (default: false) |
| `env` | no | Extra environment variables |
| `launcher_path` | no | Override path to `launch_container.sh` |

### `hf_download_dataset`

Download a HuggingFace dataset to the shared HF cache.

```yaml
- id: get-dataset
  type: hf_download_dataset
  hf_download_dataset:
    dataset_id: allenai/c4
    config: en
    split: train
```

| Field | Required | Description |
|---|---|---|
| `dataset_id` | yes | HuggingFace dataset identifier |
| `config` | no | Dataset configuration/subset |
| `split` | no | Dataset split (e.g. `train`, `validation`) |
| `cache_dir` | no | Override cache directory (default: `$HF_HOME`) |

### `hf_download_model`

Download a HuggingFace model to the shared HF cache.

```yaml
- id: get-model
  type: hf_download_model
  hf_download_model:
    model_id: Qwen/Qwen3-0.6B-Base
```

| Field | Required | Description |
|---|---|---|
| `model_id` | yes | HuggingFace model identifier |
| `cache_dir` | no | Override cache directory (default: `$HF_HOME`) |

## Output Propagation

Steps can emit named outputs by printing to stdout:

```
::set-output name=<key>::<value>
```

Example:

```bash
echo "::set-output name=checkpoint_path::/workspace/outputs/ckpt.pt"
echo "::set-output name=eval_loss::0.42"
```

Outputs are captured and stored in the run manifest. Downstream steps reference them
via interpolation.

## Interpolation

| Syntax | Resolves to |
|---|---|
| `${{ params.key }}` | Value of plan-level parameter `key` |
| `${{ env.KEY }}` | Value of plan-level env variable `KEY` |
| `${{ steps.step-id.outputs.key }}` | Output emitted by step `step-id` |

Interpolation is resolved at step execution time, so downstream steps see upstream outputs.

## Full Example

A complete GPU experiment pipeline (download model → train → evaluate → report):

```yaml
params:
  model_id: Qwen/Qwen3-0.6B-Base
  project_id: quickstart-gpu
  max_epochs: "3"
  batch_size: "8"
  learning_rate: "5e-5"

env:
  HF_HOME: /opt/hf_cache

steps:
  - id: download-model
    name: Download model from HuggingFace
    type: hf_download_model
    hf_download_model:
      model_id: ${{ params.model_id }}
    timeout_seconds: 1800

  - id: prepare-config
    name: Prepare experiment config
    type: command
    command: bash
    args:
      - -lc
      - |
        echo "model=${{ params.model_id }} epochs=${{ params.max_epochs }}"
        echo "::set-output name=config::model=${{ params.model_id }} bs=${{ params.batch_size }}"

  - id: train
    name: Train model
    type: container_job
    depends_on: [download-model, prepare-config]
    allow_failure: true
    retry:
      max_attempts: 2
      initial_interval_seconds: 10
      backoff_coefficient: 2
      maximum_interval_seconds: 60
    container_job:
      project_id: ${{ params.project_id }}
      entrypoint: run-job.sh
      gpu: true
      command: |
        python train.py \
          --model ${{ params.model_id }} \
          --epochs ${{ params.max_epochs }} \
          --batch-size ${{ params.batch_size }} \
          --lr ${{ params.learning_rate }}
    timeout_seconds: 86400

  - id: evaluate
    name: Evaluate model
    type: container_job
    depends_on: [train]
    when:
      step: train
      status: success
    container_job:
      project_id: ${{ params.project_id }}
      entrypoint: run-job.sh
      gpu: true
      command: python evaluate.py --checkpoint ${{ steps.train.outputs.checkpoint_path }}
    timeout_seconds: 3600

  - id: report-failure
    name: Triage failed training
    type: command
    depends_on: [train]
    when:
      step: train
      status: failure
    command: bash
    args:
      - -lc
      - echo "Training failed. Config was: ${{ steps.prepare-config.outputs.config }}"
```

Run it:

```bash
cd temporal
go run ./cmd/orchestrate run \
  -plan examples/quickstart/06_gpu_experiment.yaml \
  -set model_id=Qwen/Qwen3-0.6B-Base \
  -set project_id=my-experiment
```
