# Usage guide

Replace `<VM_IP>` with the VM address and `<VLLM_API_KEY>` with the key from `/etc/vllm.env` on the VM
(`ssh ubuntu@<VM_IP> sudo cat /etc/vllm.env`), or better a **gateway key** from `/etc/litellm/keys.txt` so your usage is
accounted. Run `clients/render.sh https://api.skyops.lan/v1 <key>` once: it writes ready-to-use copies of every
client file to `clients/local/` (git-ignored).

## 0. Names and HTTPS (optional, recommended)

`serving/install_edge.sh` on the VM adds a local DNS zone, mDNS and an HTTPS reverse proxy with a private CA:

| Name | Goes to | Notes |
|---|---|---|
| `https://coder.skyops.lan` | Open WebUI | needs the resolver entry below |
| `https://api.skyops.lan/v1` | **gateway**: all three models, per-key accounting and budgets | use a gateway key (`/etc/litellm/keys.txt`), not the raw vLLM key |
| `https://fim.skyops.lan/v1` | autocomplete API (`coder-fim`) | |
| `https://vision.skyops.lan/v1` | vision API (`coder-vision`) | API only: the root path answers `{"detail":"Not Found"}`; use `/v1/models`, `/v1/chat/completions` with the key |
| `https://gpu-direct.local` | Open WebUI | mDNS; works only on the same L2 network as the VM |
| `http://<VM_IP>:3000 / :8000 / :8001` | everything, unchanged | still available without TLS |

Client side, once per machine (`clients/mac-setup.sh ubuntu@<VM_IP>` does the first two):

1. Trust the CA: `security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db clients/local/skyops.lan-root.crt`
2. Resolve the zone through the VM: `sudo mkdir -p /etc/resolver && printf 'nameserver <VM_IP>\n' | sudo tee /etc/resolver/skyops.lan`
   (Linux: add `<VM_IP>` as a DNS server for `~skyops.lan` in systemd-resolved, or point the router's DNS at it.)

HTTPS is what unlocks the browser features that need a secure origin: microphone, voice calls, clipboard, PWA install.

## 1. Web chat (nothing to install)

Open `http://<VM_IP>:3000`. The first account created becomes admin. The model picker shows `coder-chat`; the
autocomplete model is deliberately not connected to the UI (it is not a chat model).

What this UI can and cannot do with the current models:

* **Images: pick `coder-vision`.** `coder-chat` (Qwen2.5-Coder) is text-only and answers "not a multimodal model"
  to attachments. `coder-vision` (Qwen2.5-VL-3B, GPU 1, port 8002) reads screenshots, diagrams and photos: paste an
  image, ask "what error is this?" / "describe this UI". One image per message, downscaled to ~600k pixels; 4k-token context. Neither model *generates*
  images; that would need a diffusion backend (ComfyUI / AUTOMATIC1111) that Open WebUI can be pointed at.
* **Voice.** Speech-to-text runs on the VM (Whisper `small`, auto-detects the spoken language per utterance,
  ~2 s). In *Settings -> Audio* keep "Speech-to-Text Engine" on *Default* (server), not *Web API* (that is the
  browser's own recogniser, fixed to one language). For more accuracy set `WHISPER_MODEL=medium` before running
  `serving/install.sh` (~5 s per utterance on CPU).
* **Tool calling** works on `coder-chat` (hermes parser). In the chat "Controls" panel leave *Function Calling*
  on *Default*; *Native* only makes sense with tools/functions configured in the workspace.
* **Microphone / voice input** needs a secure origin. Browsers allow it only on `https://` or `localhost`; over
  plain `http://<VM_IP>:3000` you get "Only secure origins are allowed". Either put a TLS reverse proxy in front
  (Caddy with a LAN certificate), or for testing enable `chrome://flags/#unsafely-treat-insecure-origin-as-secure`
  for `http://<VM_IP>:3000`.
* The "Arena" (random model comparison) and auto-generated "Follow up" questions are disabled by the install
  script (`ENABLE_EVALUATION_ARENA_MODELS=false`, `ENABLE_FOLLOW_UP_GENERATION=false`).

## 2. VS Code / JetBrains with Continue

1. Install the **Continue** extension.
2. `cp clients/local/continue-config.yaml ~/.continue/config.yaml` (or copy `clients/continue-config.yaml` and fill in the placeholders).
3. Reload the editor. You now have:
   * **Chat** (Cmd/Ctrl+L): ask about the open file, selected code, or `@codebase`.
   * **Edit** (Cmd/Ctrl+I): select code, describe the change, review the diff, apply.
   * **Tab autocomplete**: ghost-text suggestions as you type, served by the 0.5B FIM model on GPU 1.
   * Context providers enabled in the config: `@code`, `@docs`, `@diff`, `@terminal`, `@problems`, `@folder`, `@codebase`.

## 3. Terminal coding agent (aider)

```bash
uv tool install --python 3.12 aider-chat   # once, on your laptop (or: pipx install aider-chat)
source clients/local/aider.env    # sets OPENAI_API_BASE / OPENAI_API_KEY / AIDER_MODEL
cd <any git repo> && aider        # edits files and commits with the 7B model
```

## 4. From code (any OpenAI-compatible SDK)

```python
from openai import OpenAI
client = OpenAI(base_url="http://<VM_IP>:8000/v1", api_key="<VLLM_API_KEY>")
r = client.chat.completions.create(model="coder-chat",
        messages=[{"role": "user", "content": "Write a Python LRU cache."}], max_tokens=400)
print(r.choices[0].message.content)
```

Fill-in-the-middle on the autocomplete endpoint (raw completions API, Qwen FIM tokens):

```bash
curl http://<VM_IP>:8001/v1/completions -H "Authorization: Bearer <VLLM_API_KEY>" -H 'content-type: application/json' \
  -d '{"model":"coder-fim","prompt":"<|fim_prefix|>def add(a, b):\n<|fim_suffix|>\nprint(add(1,2))<|fim_middle|>","max_tokens":64,"temperature":0}'
```

Tool calling is enabled on `coder-chat` (`--enable-auto-tool-choice --tool-call-parser hermes`), so agent
frameworks that send `tools=[...]` work.

## 5. Fine-tuning your own adapter

```bash
ssh ubuntu@<VM_IP>
cd ~/ml                                    # venv auto-activates on login
python train.py --steps 500                # LoRA on Qwen2.5-0.5B-Instruct, alpaca-cleaned, ~12 min on GPU 0
python train.py --model Qwen/Qwen2.5-1.5B-Instruct --load-4bit --steps 500      # QLoRA
python train.py --dataset <hf-dataset> --samples 20000                          # your own instruction data
python infer.py --adapter outputs/lora --prompt "..."                           # test; base model comes from the adapter
python infer.py --adapter outputs/lora --serve --port 8010                      # quick endpoint for the adapter
```

The training scripts share GPU 0 with the chat service; for a long run either stop `vllm-chat` first or point the
run at GPU 1 after stopping `vllm-autocomplete`:

```bash
sudo systemctl stop vllm-autocomplete && CUDA_VISIBLE_DEVICES=1 python train.py --steps 2000
sudo systemctl start vllm-autocomplete
```

## 6. Operating

```bash
sudo systemctl status vllm-chat vllm-autocomplete      # state
journalctl -u vllm-chat -f                             # live log (requests, errors)
sudo docker logs -f open-webui
nvidia-smi                                             # who is on which GPU
curl -s -H "Authorization: Bearer $KEY" localhost:8000/v1/models   # health
```

Change a model: edit `CHAT_MODEL` or `FIM_MODEL` in `/etc/vllm.env`, then `sudo systemctl restart vllm-chat`
(or `vllm-autocomplete`). vLLM downloads the new weights on first start. Candidates that fit 8 GB: any
`*-7B-Instruct-AWQ` / `-GPTQ-Int4` for chat; `Qwen2.5-Coder-1.5B` for better autocomplete if you drop the vision model.

Re-running `serving/install.sh` is safe; it keeps the existing key and only re-does what is missing.

## 7. Troubleshooting

| Symptom | Look at |
|---|---|
| `nvidia-smi: No devices were found` | `docs/gpu-passthrough-troubleshooting.md` |
| chat service restarts in a loop | `journalctl -u vllm-chat -n 200`; an OOM at start-up means the KV cache does not fit: lower `--max-model-len` in the unit file |
| `Could not find nvcc` in the log | the unit must have `VLLM_USE_FLASHINFER_SAMPLER=0` (already set) |
| 401 from the API | wrong or missing `Authorization: Bearer` header |
| autocomplete returns chatty prose | you are hitting `coder-chat`; autocomplete must use `coder-fim` on :8001 with FIM tokens |
| web UI settings (connections, Whisper model, arena) do not change after editing env vars | Open WebUI persists them in its DB on first start and ignores env afterwards; `serving/install.sh` writes them with `serving/webui_config.py` on every run (Admin -> Settings also works) |
| web UI: `'JSONResponse' object has no attribute 'body_iterator'` | the UI got an HTTP 400 from a model server and its error path crashed; `docker logs open-webui \| grep upstream_error` shows the real reason (seen: tool definitions sent to the FIM server) |
