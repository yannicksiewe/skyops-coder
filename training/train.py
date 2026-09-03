#!/usr/bin/env python
"""LoRA fine-tune of a small causal LM on an instruction dataset. Sized for an 8 GB GPU.

Examples:
  python train.py                                   # Qwen2.5-0.5B-Instruct, 500 steps, bf16 LoRA
  python train.py --model HuggingFaceTB/SmolLM2-360M-Instruct --steps 300
  python train.py --model Qwen/Qwen2.5-1.5B-Instruct --load-4bit   # QLoRA for the bigger one
"""
import argparse, os, time
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "0")  # one GPU by default; override e.g. CUDA_VISIBLE_DEVICES=1
import torch
from datasets import load_dataset
from peft import LoraConfig
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
from trl import SFTConfig, SFTTrainer

p = argparse.ArgumentParser()
p.add_argument("--model", default="Qwen/Qwen2.5-0.5B-Instruct")
p.add_argument("--dataset", default="yahma/alpaca-cleaned")
p.add_argument("--samples", type=int, default=5000, help="training rows to use")
p.add_argument("--steps", type=int, default=500)
p.add_argument("--max-len", type=int, default=1024)
p.add_argument("--batch", type=int, default=4)
p.add_argument("--grad-accum", type=int, default=4)
p.add_argument("--lr", type=float, default=2e-4)
p.add_argument("--lora-r", type=int, default=16)
p.add_argument("--load-4bit", action="store_true", help="QLoRA: 4-bit base weights")
p.add_argument("--out", default="outputs/lora")
args = p.parse_args()

assert torch.cuda.is_available(), "CUDA not available - run setup_gpu_vm.sh and reboot first"
os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")
print(f"GPU: {torch.cuda.get_device_name(0)} | VRAM {torch.cuda.get_device_properties(0).total_memory/2**30:.1f} GB")

tokenizer = AutoTokenizer.from_pretrained(args.model)
if tokenizer.pad_token_id is None:
    tokenizer.pad_token_id = tokenizer.eos_token_id

quant = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                           bnb_4bit_compute_dtype=torch.bfloat16, bnb_4bit_use_double_quant=True) if args.load_4bit else None
model = AutoModelForCausalLM.from_pretrained(
    args.model, dtype=torch.bfloat16, quantization_config=quant, device_map={"": 0},
    attn_implementation="sdpa",
)

ds = load_dataset(args.dataset, split=f"train[:{args.samples}]")

def to_chat(row):
    user = row["instruction"] + (f"\n\n{row['input']}" if row.get("input") else "")
    return {"messages": [{"role": "user", "content": user}, {"role": "assistant", "content": row["output"]}]}

ds = ds.map(to_chat, remove_columns=ds.column_names)
split = ds.train_test_split(test_size=0.02, seed=0)

lora = LoraConfig(r=args.lora_r, lora_alpha=2 * args.lora_r, lora_dropout=0.05, bias="none",
                  task_type="CAUSAL_LM",
                  target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"])

cfg = SFTConfig(
    output_dir=args.out, max_steps=args.steps, per_device_train_batch_size=args.batch,
    gradient_accumulation_steps=args.grad_accum, learning_rate=args.lr, lr_scheduler_type="cosine",
    warmup_steps=max(1, args.steps // 20), bf16=True, gradient_checkpointing=True, logging_steps=10,
    eval_strategy="steps", eval_steps=100, save_steps=100, save_total_limit=2,
    max_length=args.max_len, packing=False, report_to="none", dataloader_num_workers=2,
)

trainer = SFTTrainer(model=model, args=cfg, train_dataset=split["train"], eval_dataset=split["test"],
                     processing_class=tokenizer, peft_config=lora)
t0 = time.time()
trainer.train()
trainer.save_model(args.out)
tokenizer.save_pretrained(args.out)
print(f"\nDone in {(time.time()-t0)/60:.1f} min. Adapter saved to {args.out}")
print(f"Peak VRAM: {torch.cuda.max_memory_allocated()/2**30:.2f} GB")
