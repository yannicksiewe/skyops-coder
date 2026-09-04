#!/usr/bin/env bash
# Render ready-to-use client configs into clients/local/ (git-ignored).
# Usage: clients/render.sh <API_BASE> <KEY>     e.g. clients/render.sh https://api.skyops.lan/v1 sk-...   (gateway key)
#        clients/render.sh http://<VM_IP>:8000/v1 <VLLM_API_KEY>   (direct to vLLM, no accounting)
set -euo pipefail
BASE="${1:?usage: render.sh <API_BASE> <KEY>}"; KEY="${2:?usage: render.sh <API_BASE> <KEY>}"
cd "$(dirname "$0")"; mkdir -p local
for f in continue-config.yaml aider.env; do
  sed -e "s#<API_BASE>#${BASE}#g" -e "s#<VLLM_API_KEY>#${KEY}#g" "$f" > "local/$f"
done
echo "written: $(ls local | sed 's#^#clients/local/#' | tr '\n' ' ')"
