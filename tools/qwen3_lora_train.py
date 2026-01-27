#!/usr/bin/env python3
import argparse
import random
import numpy as np
import torch
from datasets import load_dataset
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    TrainingArguments,
    Trainer,
    DataCollatorForLanguageModeling,
)
from peft import LoraConfig, get_peft_model


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
    parser.add_argument("--dataset", default="HuggingFaceFW/fineweb-edu")
    parser.add_argument("--dataset-config", default="default")
    parser.add_argument("--output", default="/opt/bazel_cache/qwen3-0.6b-lora")
    parser.add_argument("--rows", type=int, default=200)
    parser.add_argument("--max-length", type=int, default=512)
    parser.add_argument("--steps", type=int, default=20)
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

    lora = LoraConfig(
        r=8,
        lora_alpha=16,
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
    )
    model = get_peft_model(model, lora)
    model.print_trainable_parameters()

    ds = load_dataset(
        args.dataset,
        args.dataset_config,
        split="train",
        streaming=True,
    )
    ds = ds.take(args.rows)

    def tokenize_fn(batch):
        text = batch["text"]
        return tokenizer(
            text,
            truncation=True,
            max_length=args.max_length,
        )

    tokenized = ds.map(tokenize_fn)
    data_collator = DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)

    training_args = TrainingArguments(
        output_dir=args.output,
        per_device_train_batch_size=1,
        gradient_accumulation_steps=1,
        max_steps=args.steps,
        logging_steps=5,
        save_steps=args.steps,
        fp16=(dtype == torch.float16),
        bf16=(dtype == torch.bfloat16),
        report_to=[],
        seed=args.seed if args.seed is not None else 42,
    )

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized,
        data_collator=data_collator,
    )
    trainer.train()
    trainer.save_model(args.output)
    tokenizer.save_pretrained(args.output)
    print(f"Saved LoRA model to {args.output}")


if __name__ == "__main__":
    main()
