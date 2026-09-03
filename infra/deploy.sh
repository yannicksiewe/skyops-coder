#!/usr/bin/env bash
# One-shot provisioning of a fresh Ubuntu 24.04 GPU VM: driver, swap, uv/torch, training scripts.
# Usage: infra/deploy.sh user@host   (needs passwordless sudo on the VM)
set -euo pipefail
HOST="${1:?usage: deploy.sh user@host}"
cd "$(dirname "$0")/.."
ssh "$HOST" 'mkdir -p ~/ml'
scp -q infra/setup_gpu_vm.sh training/train.py training/infer.py "$HOST":~/ml/
ssh "$HOST" 'chmod +x ~/ml/setup_gpu_vm.sh && ~/ml/setup_gpu_vm.sh'
