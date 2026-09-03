#!/usr/bin/env python
"""Chat with the base model or a trained LoRA adapter. Also runs as an OpenAI-style HTTP server.

  python infer.py --prompt "Explain LoRA in two sentences"
  python infer.py --adapter outputs/lora --prompt "..."
  python infer.py --adapter outputs/lora --serve --port 8000
    curl localhost:8000/v1/chat/completions -H 'content-type: application/json' \
      -d '{"messages":[{"role":"user","content":"hi"}]}'
"""
import argparse, os, time
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "0")  # one GPU by default; override e.g. CUDA_VISIBLE_DEVICES=1
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

p = argparse.ArgumentParser()
p.add_argument("--model", default=None, help="base model; defaults to the adapter's base, else Qwen2.5-0.5B-Instruct")
p.add_argument("--adapter", default=None)
p.add_argument("--prompt", default="Give me three tips for training small language models.")
p.add_argument("--max-new", type=int, default=256)
p.add_argument("--serve", action="store_true")
p.add_argument("--port", type=int, default=8000)
args = p.parse_args()

if args.model is None:
    if args.adapter:
        import json
        with open(os.path.join(args.adapter, "adapter_config.json")) as f:
            args.model = json.load(f)["base_model_name_or_path"]
    else:
        args.model = "Qwen/Qwen2.5-0.5B-Instruct"
print(f"base model: {args.model}" + (f" | adapter: {args.adapter}" if args.adapter else ""))

tokenizer = AutoTokenizer.from_pretrained(args.adapter or args.model)
model = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16, device_map={"": 0})
if args.adapter:
    from peft import PeftModel
    model = PeftModel.from_pretrained(model, args.adapter).merge_and_unload()
model.eval()

@torch.inference_mode()
def chat(messages, max_new=256, temperature=0.7):
    enc = tokenizer.apply_chat_template(messages, add_generation_prompt=True, return_tensors="pt", return_dict=True).to(model.device)
    t0 = time.time()
    out = model.generate(**enc, max_new_tokens=max_new, do_sample=temperature > 0, temperature=temperature or None,
                         pad_token_id=tokenizer.eos_token_id)
    new = out[0, enc["input_ids"].shape[1]:]
    return tokenizer.decode(new, skip_special_tokens=True), len(new), time.time() - t0

if not args.serve:
    text, n, dt = chat([{"role": "user", "content": args.prompt}], args.max_new)
    print(text)
    print(f"\n[{n} tokens in {dt:.2f}s = {n/dt:.1f} tokenizer/s | VRAM {torch.cuda.max_memory_allocated()/2**30:.2f} GB]")
    raise SystemExit

from fastapi import FastAPI
from pydantic import BaseModel
import uvicorn

class Req(BaseModel):
    messages: list[dict]
    max_tokens: int = 256
    temperature: float = 0.7

app = FastAPI()

@app.post("/v1/chat/completions")
def completions(r: Req):
    text, n, dt = chat(r.messages, r.max_tokens, r.temperature)
    return {"choices": [{"message": {"role": "assistant", "content": text}}],
            "usage": {"completion_tokens": n, "tok_per_s": round(n / dt, 1)}}

uvicorn.run(app, host="0.0.0.0", port=args.port)
