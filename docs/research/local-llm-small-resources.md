# Running LLMs for a team on small local resources: what fits, what it costs, how to operate it

*Measured on the skyops office VM: RTX 3070 8 GB (Ampere) + RTX 2080 8 GB (Turing), 14 vCPU, 46 GB RAM,
Ubuntu 24.04, NVIDIA 580, vLLM 0.28. Numbers are from this repository's scripts (`research/bench.py`,
`serving/`), not from vendor claims. Last update: 2026-09-04.*

## 1. The sizing rule that decides everything

VRAM per model ≈ **weights + KV cache + ~0.5 GB working set**.

| Term | How to compute | Example (Qwen2.5-Coder-7B, AWQ) |
|---|---|---|
| Weights | params × bytes/param (fp16 = 2, int8 = 1, int4 ≈ 0.55 incl. scales) | 7.6 B × 0.55 ≈ 4.2 GB + embeddings ≈ **5.4 GB** measured |
| KV cache per token | 2 × layers × kv_heads × head_dim × bytes | 2 × 28 × 4 × 128 × 2 B = **57 KB/token** |
| KV cache for N tokens | N × per-token | 16k tokens ≈ 0.9 GB; 27k tokens fit in the 1.4 GB left |
| Concurrency | cache tokens ÷ tokens per request | 27k ÷ 16k ≈ 1.6 full-context requests |

Consequences on an 8 GB card: **7-9B at 4-bit** with 8-16k context, or **3B at fp16**, or **1-2B with a huge
cache** (the autocomplete model: 0.5B fp16 = 1 GB weights, 135k cache tokens = 16 parallel editors).
Models with grouped-query attention (small kv_heads) are what make 16k context possible at all.

## 2. What we run and what it measures

| Role | Model | GPU share | Measured |
|---|---|---|---|
| Chat / edit / agents | Qwen2.5-Coder-7B-Instruct-AWQ | RTX 3070, 93 % | 81-82 tok/s single stream; **6/8** on `bench.py` |
| Autocomplete (FIM) | Qwen2.5-Coder-0.5B fp16 | RTX 2080, 25 % | 48-token completion ≈ 350 ms |
| Vision | Qwen2.5-VL-3B-Instruct-AWQ | RTX 2080, 68 % | 1024-px screenshot described in 1.7 s |
| Speech-to-text | Whisper small (CPU) | 0 | 2 s/utterance, language auto-detected (medium: 5 s) |
| AI code review | chat model via `agents/review.py` | | a 40-line diff reviewed in ~10 s |

`bench.py` is 8 small Python tasks with hidden tests (LRU cache, interval merge, topological sort, sliding-window
rate limiter, ...). It is deliberately small; it discriminates between "usable for a team" and not, no more.

## 3. Candidates for the same hardware (trial results)

| Model | Why interesting | Fits? | bench.py | tok/s | Notes |
|---|---|---|---|---|---|
| Qwen2.5-Coder-7B-AWQ (baseline) | current | yes | 6/8 | 82 | RTX 3070 |
| Qwen3.5-9B-AWQ | one model for text **and** vision, thinking mode, newer | TRIAL_FITS | TRIAL_BENCH | TRIAL_TPS | TRIAL_NOTES |
| GLM-4-9B-0414 (bnb 4-bit) | the only GLM that fits | GLM_FITS | GLM_BENCH | GLM_TPS | GLM_NOTES |
| GLM-5.x (Flash, 5.2, 5.3) | requested | **no**: 320B MoE, 18B active ≈ 160 GB at int4 | – | – | API only |
| Qwen3.5-35B-A3B-GPTQ-Int4 | MoE, fast | no: ~19 GB | – | – | needs a 24 GB card |
| Qwen3.5-4B-AWQ | small multimodal for the 2080 | ~2.5 GB | – | – | could replace vision + serve a second chat |

## 4. "Can we run many models?"

On 16 GB total: **one 7-9B model per card**, plus small helpers (0.5B autocomplete) squeezed next to a 3B. Options
for "more models" without more hardware:

1. **Switch, don't stack.** Changing `CHAT_MODEL` and restarting takes ~60 s (weights are cached on disk).
2. **On-demand loading** with llama.cpp + `llama-swap`: models load when first called and unload on idle. Good
   for many rarely-used models; ~3-10× lower throughput than vLLM and no continuous batching. Not used here.
3. **A second box** or **one 24 GB card** (RTX 3090/4090-class): a 32B model at 4-bit *or* two 7-9B models with
   full context. That is the single most effective upgrade; everything in this repo stays the same.

## 5. Operating: what mattered in practice

* **Pin services to GPUs and fix memory shares** (`CUDA_VISIBLE_DEVICES`, `--gpu-memory-utilization`). Two vLLM
  processes on one card only work when their shares add up below ~0.95 and both start reliably.
* **Turing (sm75) is fine but different:** `--dtype half`, no FlashAttention-2, no bf16. AWQ works.
* **No CUDA toolkit needed** for inference; disable FlashInfer's JIT sampler (`VLLM_USE_FLASHINFER_SAMPLER=0`).
* **Open WebUI persists settings in its DB**; env vars only seed the first start (`serving/webui_config.py`).
* **Startup time** is the real "cold start": 20-70 s per model. Health-check endpoints before routing traffic.
* **Metrics you actually watch:** `vllm:num_requests_waiting` (queueing), `vllm:gpu_cache_usage_perc`,
  GPU temperature (the 2080 throttles hot), root disk (model caches grow: 17 GB of weights, 15 GB of venvs).
* **Whisper on CPU is enough** for voice at team scale; GPUs stay for the LLMs.

## 6. Cost and capacity for a small team

Measured single-stream chat throughput 82 tok/s; with continuous batching vLLM sustains several parallel
requests at reduced per-request speed. Rough capacity of the current chat model: ~5 concurrent active users
with 16k context (KV cache is the limit, not compute). Electricity: 2 GPUs idle ≈ 50 W, under load ≈ 300-400 W.
No per-token cost, no data leaving the office.

## 7. Backup and recovery in numbers

State worth backing up is ~200 MB (users, chats, keys, CA, adapters); models and environments (~32 GB) are
re-downloadable. Nightly encrypted backup, restore tested (`ops/backup/restore_test.sh`). Full rebuild of a VM:
~1 h, dominated by downloads.

## 8. What we would do with more

| Budget | Change | Effect |
|---|---|---|
| +1 × 24 GB GPU | Qwen3.5-27B-GPTQ-Int4 or 35B-A3B as chat model | frontier-class coding at office scale |
| +NVMe | none needed; 9 GB/s already | – |
| +RAM | irrelevant for inference here | – |
| GLM-5 | hosted API with a data-processing agreement | only path to that family |
