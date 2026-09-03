# skyops-coder

Self-hosted coding assistant on a two-GPU VM: a 7B coder model for chat, edits and agents, a small
fill-in-the-middle model for inline autocomplete, an OpenAI-compatible API with a key, a web chat UI,
and a LoRA fine-tuning pipeline for training your own adapters. Everything runs as systemd services
and survives reboots.

```
                 ┌──────────────────────────── VM (Ubuntu 24.04) ────────────────────────────┐
 VS Code/Continue│  :8000  vllm-chat          GPU 0  RTX 3070 8 GB   Qwen2.5-Coder-7B-AWQ    │
 aider / any SDK ┼─►:8001  vllm-autocomplete  GPU 1  RTX 2080 8 GB   Qwen2.5-Coder-1.5B FIM  │
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
| `serving/install.sh` | vLLM in its own venv, two systemd services, Open WebUI in Docker, API key. |
| `serving/deploy_serving.sh user@host` | Copy + run the above. |
| `clients/continue-config.yaml` | VS Code / JetBrains "Continue" config: chat + autocomplete. |
| `clients/aider.env` | Terminal coding agent config. |
| `tools/gpu_passthrough_check.sh` | Host-side diagnostic for GPU passthrough (see docs). |
| `docs/gpu-passthrough-troubleshooting.md` | How a "healthy" GPU can be unusable in a VM, and how to prove why. |

## Quick start

```bash
# 1. provision (reboots once after the driver install; re-run afterwards if needed)
infra/deploy.sh ubuntu@<VM_IP>

# 2. serving stack (downloads ~9 GB of models on first run)
serving/deploy_serving.sh ubuntu@<VM_IP>
#    prints the API key; it lives in /etc/vllm.env on the VM

# 3. clients
#    web:      http://<VM_IP>:3000
#    VS Code:  install "Continue", copy clients/continue-config.yaml to ~/.continue/config.yaml,
#              replace <VM_IP> and <VLLM_API_KEY>
#    terminal: edit clients/aider.env, then:  source clients/aider.env && aider
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

Measured on the RTX 3070: 20 LoRA steps on Qwen2.5-0.5B in 29 s at 2 GB peak VRAM; inference 68 tok/s
(0.5B) and 47 tok/s (1.5B) in bf16; vLLM 7B-AWQ chat with 16k context.

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
* The Trainer will try to data-parallel across both GPUs; the scripts pin `CUDA_VISIBLE_DEVICES=0` by default.
* Passing a consumer GPU through **two** hypervisor layers (e.g. a Nova compute node that is itself a VM) does not
  work: the driver fails with `RmInitAdapter failed (0x62:0x56)`. See `docs/`.

## License

MIT
