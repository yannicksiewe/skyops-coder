# skyops-coder

Self-hosted AI assistant for a small engineering team on a two-GPU office VM: a 7B coder model for chat, edits and
agents, a small fill-in-the-middle model for inline autocomplete, a 3B vision model for screenshots, server-side
Whisper for voice, **AI code review and architecture review on every pull request, an issue-to-PR coding agent, CI/CD
on a self-hosted runner, Prometheus/Grafana monitoring, an LLM gateway with per-user token accounting and budgets, request tracing with
content, and encrypted nightly backups**, an OpenAI-compatible API with a key, a web chat UI,
and a LoRA fine-tuning pipeline for training your own adapters. Everything runs as systemd services
and survives reboots.

```
                 ┌──────────────────────────── VM (Ubuntu 24.04) ────────────────────────────┐
 VS Code/Continue│  :8000  vllm-chat          GPU 0  RTX 3070 8 GB   Qwen2.5-Coder-7B-AWQ    │
 aider / any SDK ┼─►:8001  vllm-autocomplete  GPU 1  RTX 2080 8 GB   Qwen2.5-Coder-0.5B FIM  │
                 │  :8002  vllm-vision        GPU 1  (shared)         Qwen2.5-VL-3B-AWQ       │
 browser         │  :3000  open-webui  (docker) ──► both endpoints                             │
                 │  ~/ml   train.py / infer.py   LoRA + QLoRA fine-tuning (torch cu128)        │
                 └───────────────────────────────────────────────────────────────────────────┘
```

## Layout

| Path | What |
|---|---|
| `infra/setup_gpu_vm.sh` | Provision a fresh VM: NVIDIA driver, swap, uv + torch cu128 + HF stack. Idempotent. |
| `infra/deploy.sh user@host` | Copy + run the above from your laptop. |
| `training/train.py` | LoRA / QLoRA SFT on an instruction dataset, sized for 8 GB VRAM. |
| `training/infer.py` | Chat with a base model or adapter; `--serve` exposes an OpenAI-style endpoint. |
| `serving/install.sh` | vLLM in its own venv, three systemd services, Open WebUI in Docker, API key. |
| `serving/webui_config.py` | Writes connections / Whisper / feature flags into Open WebUI's persisted config (env vars are ignored after first start). |
| `serving/deploy_serving.sh user@host` | Copy + run the above. |
| `serving/install_edge.sh` | Local DNS zone (dnsmasq), mDNS (avahi), HTTPS reverse proxy with a private CA (Caddy). |
| `clients/mac-setup.sh user@host` | Trust the VM's CA on a Mac and print the resolver command for `*.skyops.lan`. |
| `clients/continue-config.yaml` | VS Code / JetBrains "Continue" config: chat + autocomplete. |
| `clients/aider.env` | Terminal coding agent config. |
| `tools/gpu_passthrough_check.sh` | Host-side diagnostic for GPU passthrough (see docs). |
| `clients/render.sh` | Writes ready-to-use copies of the client files to `clients/local/` (git-ignored). |
| `docs/architecture.md` | Deployment picture: layers, which process owns which GPU, memory budgets, ports. |
| `docs/usage.md` | How to use it from the browser, VS Code, aider, SDKs; fine-tuning. |
| `docs/operations.md` | CI/CD on the office runner, AI review/agents for the team, monitoring, backup & recovery runbook. |
| `docs/plan/ROADMAP.md`, `docs/adr/` | Roadmap and architecture decision records. |
| `docs/research/` | Measured research: running models on small GPUs. |
| `agents/` | AI code review, architecture review and issue-to-PR agents (local model, stdlib only, unit-tested). |
| `.github/workflows/` | `ci`, `ai-code-review`, `ai-architecture-review`, `ai-task`, `cd`; all run on the office runner. |
| `ops/runner/`, `ops/monitoring/`, `ops/backup/` | Self-hosted runner, Prometheus/Grafana stack, encrypted nightly backups. |
| `ops/gateway/`, `ops/langfuse/` | LiteLLM gateway (keys, budgets, per-user token/latency accounting) and Langfuse (traces with content). |
| `docs/governance.md` | What is measured and stored about usage, budgets in token units, privacy and retention. |
| `docs/gpu-passthrough-troubleshooting.md` | How a "healthy" GPU can be unusable in a VM, and how to prove why. |

## Quick start

```bash
# 1. provision (reboots once after the driver install; re-run afterwards if needed)
infra/deploy.sh ubuntu@<VM_IP>

# 2. serving stack (downloads ~9 GB of models on first run)
serving/deploy_serving.sh ubuntu@<VM_IP>
#    prints the API key; it lives in /etc/vllm.env on the VM

# 3. clients
#    edge (optional): ssh ubuntu@<VM_IP> ZONE=skyops.lan ~/vllm/install_edge.sh ; clients/mac-setup.sh ubuntu@<VM_IP>
#    web:      http://<VM_IP>:3000   or  https://coder.skyops.lan after the edge step
#    clients/render.sh <VM_IP> <VLLM_API_KEY>      -> clients/local/*  (filled in, git-ignored)
#    VS Code:  install "Continue", cp clients/local/continue-config.yaml ~/.continue/config.yaml
#    terminal: uv tool install --python 3.12 aider-chat   (once)
#              source clients/local/aider.env && aider     (run from the repo root)
#    SDK:      base_url=http://<VM_IP>:8000/v1  model=coder-chat
```

Smoke test:

```bash
curl http://<VM_IP>:8000/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d '{"model":"coder-chat","messages":[{"role":"user","content":"Write a Python LRU cache."}],"max_tokens":300}'
```

## Fine-tuning

```bash
ssh ubuntu@<VM_IP>; cd ~/ml
python train.py --steps 500                                           # Qwen2.5-0.5B-Instruct, LoRA r=16, ~12 min
python train.py --model Qwen/Qwen2.5-1.5B-Instruct --load-4bit        # QLoRA for a bigger base
python infer.py --adapter outputs/lora --prompt "..."                  # base model is read from the adapter
CUDA_VISIBLE_DEVICES=1 python train.py ...                            # use the second GPU
```

## Measured

| Workload | Result |
|---|---|
| Chat, Qwen2.5-Coder-7B-AWQ on RTX 3070 via vLLM, single request | 81 tok/s, 16k context, 7.3 GB VRAM |
| Autocomplete, Qwen2.5-Coder-0.5B on RTX 2080 (25% of the card) | sub-second FIM completions |
| Vision, Qwen2.5-VL-3B-AWQ on RTX 2080 (68% of the card), 1024px screenshot | 2-sentence description in 1.7 s |
| Speech-to-text, Whisper small on 14 vCPU | ~2 s per utterance, language auto-detected |
| LoRA training, Qwen2.5-0.5B, 20 steps, RTX 3070 | 29 s, 2.0 GB peak VRAM |
| `infer.py` bf16 inference, 0.5B / 1.5B | 68 / 47 tok/s |

## Operate

```bash
sudo systemctl status vllm-chat vllm-autocomplete      # services
journalctl -u vllm-chat -f                             # logs
sudo docker logs -f open-webui
nvidia-smi
# change models: edit CHAT_MODEL / FIM_MODEL in /etc/vllm.env, then
sudo systemctl restart vllm-chat vllm-autocomplete
```

## Hardware notes

* 8 GB cards: 7B models need 4-bit weights (AWQ/GPTQ); 3B fits in fp16; LoRA training is realistic up to ~1.5B.
* The RTX 2080 (Turing) has no bf16: serve with `--dtype half` (already set in its unit file).
* No CUDA toolkit is installed on the VM, so the unit files set `VLLM_USE_FLASHINFER_SAMPLER=0`; FlashInfer's
  sampler would otherwise try to JIT-compile a kernel with nvcc and crash the engine at start-up.
* The Trainer will try to data-parallel across both GPUs; the scripts pin `CUDA_VISIBLE_DEVICES=0` by default.
* Passing a consumer GPU through **two** hypervisor layers (e.g. a Nova compute node that is itself a VM) does not
  work: the driver fails with `RmInitAdapter failed (0x62:0x56)`. See `docs/`.

## License

MIT
