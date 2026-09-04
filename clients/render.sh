#!/usr/bin/env bash
# Render ready-to-use client configs into clients/local/ (git-ignored).
# Usage: clients/render.sh <VM_IP> <VLLM_API_KEY>
set -euo pipefail
IP="${1:?usage: render.sh <VM_IP> <VLLM_API_KEY>}"; KEY="${2:?usage: render.sh <VM_IP> <VLLM_API_KEY>}"
cd "$(dirname "$0")"; mkdir -p local
for f in continue-config.yaml aider.env; do
  sed -e "s#<VM_IP>#${IP}#g" -e "s#<VLLM_API_KEY>#${KEY}#g" "$f" > "local/$f"
done
echo "written: $(ls local | sed 's#^#clients/local/#' | tr '\n' ' ')"
