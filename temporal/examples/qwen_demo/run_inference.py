import os
import textwrap

from datasets import load_dataset
from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL_ID = os.environ.get("QWEN_MODEL_ID", "Qwen/Qwen3-0.6B-Base")
DATASET_ID = os.environ.get("FINEWEB_DATASET_ID", "HuggingFaceFW/fineweb")
MAX_ITEMS = int(os.environ.get("FINEWEB_ITEMS", "3"))
MAX_NEW_TOKENS = int(os.environ.get("MAX_NEW_TOKENS", "32"))


def main() -> None:
    os.environ["CUDA_VISIBLE_DEVICES"] = ""
    import torch  # imported after disabling CUDA

    device = "cpu"
    torch.set_num_threads(1)

    print(f"loading model {MODEL_ID} on {device}...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.float32,
        low_cpu_mem_usage=True,
        trust_remote_code=True,
    )
    model.to(device)
    model.eval()

    print(f"streaming dataset {DATASET_ID}...")
    dataset = load_dataset(DATASET_ID, split="train", streaming=True)

    for idx, item in enumerate(dataset.take(MAX_ITEMS), start=1):
        text = item.get("text") or ""
        prompt = f"Summarize:\n{text[:400]}\n\nSummary:"
        inputs = tokenizer(
            prompt, return_tensors="pt", truncation=True, max_length=512
        ).to(device)
        with torch.no_grad():
            output_ids = model.generate(
                **inputs,
                max_new_tokens=MAX_NEW_TOKENS,
                do_sample=False,
            )
        decoded = tokenizer.decode(output_ids[0], skip_special_tokens=True)
        summary = decoded[len(prompt) :].strip()

        print("=" * 80)
        print(f"example {idx}")
        print(textwrap.shorten(text.replace("\n", " "), width=200, placeholder="..."))
        print("summary:")
        print(summary)


if __name__ == "__main__":
    main()
