#!/usr/bin/env bash
# Coding-assistant stack on gpu-direct: vLLM chat model (GPU0) + FIM autocomplete model (GPU1) + Open WebUI.
# Idempotent. Run as ubuntu with passwordless sudo.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.local/bin:$PATH"
VENV="$HOME/vllm/.venv"
CHAT_MODEL="${CHAT_MODEL:-Qwen/Qwen2.5-Coder-7B-Instruct-AWQ}"
FIM_MODEL="${FIM_MODEL:-Qwen/Qwen2.5-Coder-0.5B}"
VISION_MODEL="${VISION_MODEL:-Qwen/Qwen2.5-VL-3B-Instruct-AWQ}"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "API key"
if [ ! -f /etc/vllm.env ]; then
  KEY="sk-skyops-$(openssl rand -hex 16)"
  printf 'VLLM_API_KEY=%s\nCHAT_MODEL=%s\nFIM_MODEL=%s\nVISION_MODEL=%s\nHF_HOME=/home/ubuntu/.cache/huggingface\n' "$KEY" "$CHAT_MODEL" "$FIM_MODEL" "$VISION_MODEL" | sudo tee /etc/vllm.env >/dev/null
  sudo chmod 640 /etc/vllm.env; sudo chown root:ubuntu /etc/vllm.env
fi
grep -q '^VISION_MODEL=' /etc/vllm.env || echo "VISION_MODEL=$VISION_MODEL" | sudo tee -a /etc/vllm.env >/dev/null
# shellcheck disable=SC1091
. /etc/vllm.env

log "vLLM venv (separate from ~/ml so torch versions never clash)"
mkdir -p "$HOME/vllm"
[ -d "$VENV" ] || uv venv "$VENV" --python 3.12 >/dev/null
# shellcheck disable=SC1091
source "$VENV/bin/activate"
uv pip install -q vllm huggingface_hub hf_xet

log "Pre-download models (chat: $CHAT_MODEL, autocomplete: $FIM_MODEL, vision: $VISION_MODEL)"
HF_XET_HIGH_PERFORMANCE=1 hf download "$CHAT_MODEL"   >/dev/null
HF_XET_HIGH_PERFORMANCE=1 hf download "$FIM_MODEL"    >/dev/null
HF_XET_HIGH_PERFORMANCE=1 hf download "$VISION_MODEL" >/dev/null

log "systemd services"
sudo cp "$HOME/vllm/vllm-chat.service" "$HOME/vllm/vllm-autocomplete.service" "$HOME/vllm/vllm-vision.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vllm-chat vllm-autocomplete vllm-vision

log "Docker + Open WebUI"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh >/dev/null 2>&1
  sudo usermod -aG docker ubuntu
fi
sudo docker rm -f open-webui >/dev/null 2>&1 || true
# Chat + vision endpoints are exposed to the UI; the FIM model is not a chat model, and the UI's "Arena" feature
# would otherwise route chats (and tool definitions) to it, which the FIM server rejects with HTTP 400.
sudo docker run -d --name open-webui --restart unless-stopped --network host \
  -v open-webui:/app/backend/data \
  -e PORT=3000 \
  -e OPENAI_API_BASE_URLS="http://127.0.0.1:8000/v1;http://127.0.0.1:8002/v1" \
  -e OPENAI_API_KEYS="$VLLM_API_KEY;$VLLM_API_KEY" \
  -e ENABLE_OLLAMA_API=false -e WEBUI_AUTH=true \
  -e ENABLE_EVALUATION_ARENA_MODELS=false \
  -e ENABLE_FOLLOW_UP_GENERATION=false \
  -e WHISPER_MODEL="${WHISPER_MODEL:-small}" -e WHISPER_MODEL_AUTO_UPDATE=true -e WHISPER_VAD_FILTER=true \
  ghcr.io/open-webui/open-webui:${OPEN_WEBUI_TAG:-v0.11.3} >/dev/null

log "Open WebUI persisted settings (its DB overrides env vars after the first start)"
for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:3000)" = 200 ] && break; sleep 5; done
sudo docker cp "$HOME/vllm/webui_config.py" open-webui:/tmp/webui_config.py
sudo docker exec open-webui python3 /tmp/webui_config.py "$(python3 - "$VLLM_API_KEY" "${WHISPER_MODEL:-small}" <<'PY'
import json, sys
key, whisper = sys.argv[1], sys.argv[2]
print(json.dumps({
  "openai.api_base_urls": ["http://127.0.0.1:8000/v1", "http://127.0.0.1:8002/v1"],
  "openai.api_keys": [key, key],
  "openai.api_configs": {},
  "evaluation.arena.enable": False,
  "task.follow_up.enable": False,
  "audio.stt.engine": "",
  "audio.stt.whisper_model": whisper,
}))
PY
)"
sudo docker restart open-webui >/dev/null

log "Waiting for the chat endpoint"
for i in $(seq 1 90); do curl -s -H "Authorization: Bearer $VLLM_API_KEY" localhost:8000/v1/models | grep -q "$CHAT_MODEL" && break; sleep 5; done
curl -s -H "Authorization: Bearer $VLLM_API_KEY" localhost:8000/v1/models | python3 -c "import sys,json; print('chat models:', [m['id'] for m in json.load(sys.stdin)['data']])"
echo "API key: $VLLM_API_KEY"
echo "Done."
