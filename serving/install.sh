#!/usr/bin/env bash
# Coding-assistant stack on gpu-direct: vLLM chat model (GPU0) + FIM autocomplete model (GPU1) + Open WebUI.
# Idempotent. Run as ubuntu with passwordless sudo.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.local/bin:$PATH"
VENV="$HOME/vllm/.venv"
CHAT_MODEL="${CHAT_MODEL:-Qwen/Qwen2.5-Coder-7B-Instruct-AWQ}"
FIM_MODEL="${FIM_MODEL:-Qwen/Qwen2.5-Coder-1.5B}"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "API key"
if [ ! -f /etc/vllm.env ]; then
  KEY="sk-skyops-$(openssl rand -hex 16)"
  printf 'VLLM_API_KEY=%s\nCHAT_MODEL=%s\nFIM_MODEL=%s\nHF_HOME=/home/ubuntu/.cache/huggingface\n' "$KEY" "$CHAT_MODEL" "$FIM_MODEL" | sudo tee /etc/vllm.env >/dev/null
  sudo chmod 640 /etc/vllm.env; sudo chown root:ubuntu /etc/vllm.env
fi
# shellcheck disable=SC1091
. /etc/vllm.env

log "vLLM venv (separate from ~/ml so torch versions never clash)"
mkdir -p "$HOME/vllm"
[ -d "$VENV" ] || uv venv "$VENV" --python 3.12 >/dev/null
# shellcheck disable=SC1091
source "$VENV/bin/activate"
uv pip install -q vllm huggingface_hub hf_xet

log "Pre-download models (chat: $CHAT_MODEL, autocomplete: $FIM_MODEL)"
HF_XET_HIGH_PERFORMANCE=1 hf download "$CHAT_MODEL" >/dev/null
HF_XET_HIGH_PERFORMANCE=1 hf download "$FIM_MODEL"  >/dev/null

log "systemd services"
sudo cp "$HOME/vllm/vllm-chat.service" "$HOME/vllm/vllm-autocomplete.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vllm-chat vllm-autocomplete

log "Docker + Open WebUI"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh >/dev/null 2>&1
  sudo usermod -aG docker ubuntu
fi
sudo docker rm -f open-webui >/dev/null 2>&1 || true
# Only the chat endpoint is exposed to the UI: the FIM model is not a chat model, and the UI's "Arena" feature
# would otherwise route chats (and tool definitions) to it, which the FIM server rejects with HTTP 400.
sudo docker run -d --name open-webui --restart unless-stopped --network host \
  -v open-webui:/app/backend/data \
  -e PORT=3000 \
  -e OPENAI_API_BASE_URLS="http://127.0.0.1:8000/v1" \
  -e OPENAI_API_KEYS="$VLLM_API_KEY" \
  -e ENABLE_OLLAMA_API=false -e WEBUI_AUTH=true \
  -e ENABLE_EVALUATION_ARENA_MODELS=false \
  -e ENABLE_FOLLOW_UP_GENERATION=false \
  ghcr.io/open-webui/open-webui:${OPEN_WEBUI_TAG:-v0.11.3} >/dev/null

log "Waiting for the chat endpoint"
for i in $(seq 1 90); do curl -s -H "Authorization: Bearer $VLLM_API_KEY" localhost:8000/v1/models | grep -q "$CHAT_MODEL" && break; sleep 5; done
curl -s -H "Authorization: Bearer $VLLM_API_KEY" localhost:8000/v1/models | python3 -c "import sys,json; print('chat models:', [m['id'] for m in json.load(sys.stdin)['data']])"
echo "API key: $VLLM_API_KEY"
echo "Done."
