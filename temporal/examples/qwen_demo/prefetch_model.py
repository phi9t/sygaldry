import os
from huggingface_hub import snapshot_download

MODEL_ID = os.environ.get("QWEN_MODEL_ID", "Qwen/Qwen3-0.6B-Base")


def main() -> None:
    snapshot_download(
        repo_id=MODEL_ID,
        allow_patterns=[
            "*.json",
            "*.txt",
            "*.model",
            "*.safetensors",
        ],
    )
    print(f"prefetched {MODEL_ID}")


if __name__ == "__main__":
    main()
