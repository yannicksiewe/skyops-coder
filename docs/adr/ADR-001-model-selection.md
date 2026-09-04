# ADR-001: Which models run on the office server

**Status:** accepted (2026-09-04)   **Context:** 2 x 8 GB GPUs (RTX 3070 Ampere, RTX 2080 Turing), 46 GB RAM.

## Constraints that decide everything

* A model's weights must fit in one card with room for KV cache: ~5.5 GB of weights is the practical ceiling,
  i.e. **7-9B parameters at 4-bit**, 3B at fp16. No tensor-parallel across the two cards: different generations,
  PCIe only, and it would halve the capacity for the other roles.
* The RTX 2080 has no bf16 and no FlashAttention-2; anything on it runs fp16 with fallback kernels.
* One vLLM process serves one model. "Many models" means one per card plus what fits alongside.

## Options considered

| Model | Size | Fits? | Verdict |
|---|---|---|---|
| **Qwen2.5-Coder-7B-Instruct-AWQ** (current chat) | 7B, int4 = 5.4 GB | yes, 16k ctx | strong coder, tool calling, proven here at 81 tok/s |
| **Qwen3.5-9B** (AWQ / w4a16) | 9B dense, int4 ~5.5 GB, **vision + text + thinking** in one | to be measured | could replace chat *and* vision with one better model (LiveCodeBench 65.6) |
| Qwen3.5-35B-A3B-GPTQ-Int4 | 35B MoE, ~19 GB | no | needs a 24 GB card |
| GLM-5.3-Flash | 320B MoE, 18B active | no (~160 GB at int4) | API-only for us |
| GLM-5 / 5.1 / 5.2 | larger still | no | |
| GLM-4-9B-0414 / GLM-Z1-9B | 9B, int4 ~5.5 GB | yes | older generation than Qwen3.5-9B; no advantage |
| GLM-4.1V-9B-Thinking | 9B vision | yes | vision only; Qwen3.5-9B covers it |
| Qwen2.5-Coder-0.5B (FIM) | 0.5B fp16 = 1 GB | yes | autocomplete, stays |
| Qwen2.5-VL-3B-AWQ (vision) | 3B | yes | stays unless Qwen3.5-9B takes over vision |

## Decision

1. Keep the current trio in production. 2. Run a measured trial of Qwen3.5-9B-AWQ (throughput, VRAM, coding and
vision quality on our smoke tests). 3. If it fits with >= 8k context and matches the coder on code tasks, switch
`CHAT_MODEL` to it and drop the separate vision service, freeing the 2080 for a bigger autocomplete model.
4. GLM: none of the 5.x family is deployable here; revisit only with a >= 48 GB GPU or a hosted API.

## Consequences

* The best model per card is the objective; more models are not better on 16 GB total.
* Model changes are a one-line change in `/etc/vllm.env` plus a service restart, and are recorded here.
