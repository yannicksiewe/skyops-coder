#!/usr/bin/env bash
# Install the coding-assistant serving stack (vLLM x2 + Open WebUI) on a provisioned VM.
# Usage: serving/deploy_serving.sh user@host
set -euo pipefail
HOST="${1:?usage: deploy_serving.sh user@host}"
cd "$(dirname "$0")"
ssh "$HOST" 'mkdir -p ~/vllm'
scp -q install.sh vllm-chat.service vllm-autocomplete.service "$HOST":~/vllm/
ssh "$HOST" 'chmod +x ~/vllm/install.sh && ~/vllm/install.sh'
