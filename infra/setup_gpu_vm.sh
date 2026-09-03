#!/usr/bin/env bash
# One-shot setup for the skyops GPU VM (Ubuntu 24.04, RTX 3070 8GB passthrough).
# Idempotent: safe to re-run. Reboots once after a fresh driver install.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

DRIVER_PKG="nvidia-driver-580-server"
VENV="$HOME/ml/.venv"
SWAP_GB=8

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "Base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential git curl htop tmux python3-venv python3-pip pkg-config >/dev/null

log "Swap (${SWAP_GB}G) - protects the 19G RAM box when loading models"
if ! swapon --show | grep -q /swapfile; then
  sudo fallocate -l ${SWAP_GB}G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

log "GPU preflight: expansion ROM handed to the guest by the hypervisor"
GPU_BDF=$(lspci -D | awk '/NVIDIA/ && /VGA|3D/ {print $1; exit}')
if [ -n "$GPU_BDF" ]; then
  echo 1 | sudo tee /sys/bus/pci/devices/$GPU_BDF/rom >/dev/null 2>&1 || true
  if sudo strings -n 6 /sys/bus/pci/devices/$GPU_BDF/rom 2>/dev/null | grep -q SeaVGABIOS; then
    echo "!! $GPU_BDF: host passes SeaVGABIOS instead of the NVIDIA VBIOS. The driver will fail with"
    echo "!! 'RmInitAdapter failed (0x25:0xffff:1636)'. Ask the provider to fix the passthrough config."
  fi
  echo 0 | sudo tee /sys/bus/pci/devices/$GPU_BDF/rom >/dev/null 2>&1 || true
fi

log "NVIDIA driver"
NEED_REBOOT=0
if ! command -v nvidia-smi >/dev/null 2>&1; then
  sudo apt-get install -y -qq "$DRIVER_PKG" nvidia-utils-580-server >/dev/null  # note: 535/550/570-server on 24.04 are aliases for 580
  NEED_REBOOT=1
fi

log "Python environment (uv + torch cu128 + HF stack)"
mkdir -p "$HOME/ml"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
fi
export PATH="$HOME/.local/bin:$PATH"
[ -d "$VENV" ] || uv venv "$VENV" --python 3.12 >/dev/null
# shellcheck disable=SC1091
source "$VENV/bin/activate"
uv pip install -q --index-url https://download.pytorch.org/whl/cu128 torch torchvision
uv pip install -q transformers datasets accelerate peft trl bitsandbytes sentencepiece \
  hf_transfer huggingface_hub fastapi "uvicorn[standard]" pydantic
grep -q 'ml/.venv/bin/activate' "$HOME/.bashrc" || {
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  echo 'source ~/ml/.venv/bin/activate' >> "$HOME/.bashrc"
  echo 'export HF_HUB_ENABLE_HF_TRANSFER=1' >> "$HOME/.bashrc"
}

if [ "$NEED_REBOOT" = 1 ]; then
  log "Driver installed - rebooting now. Re-connect in ~60s and run: nvidia-smi"
  sudo reboot
else
  log "Done. GPU status:"
  nvidia-smi
  python -c "import torch; print('torch', torch.__version__, '| cuda', torch.cuda.is_available(), '|', torch.cuda.get_device_name(0) if torch.cuda.is_available() else '-')"
fi
