#!/usr/bin/env bash
# Trial a candidate model on one GPU with vLLM, run bench.py against it, record results, clean up.
# Usage: research/trial.sh <hf-model> <gpu-index> "<label>" [extra vllm args...]
# Writes research/results.jsonl (via bench.py) and research/trial-<label>.log. Needs /etc/vllm.env.
set -euo pipefail
MODEL="$1"; GPU="$2"; LABEL="$3"; shift 3
. /etc/vllm.env; export PATH="$HOME/.local/bin:$PATH" HF_XET_HIGH_PERFORMANCE=1
cd "$(dirname "$0")"; SAFE=$(echo "$LABEL" | tr -c 'A-Za-z0-9._-' '_'); LOG="trial-$SAFE.log"
"$HOME/vllm/.venv/bin/hf" download "$MODEL" >/dev/null 2>&1 || true
echo "weights on disk: $(du -sh "$HOME/.cache/huggingface/hub/models--${MODEL//\//--}" 2>/dev/null | cut -f1)"
pkill -f "served-model-name trial" 2>/dev/null || true; sleep 3
nohup env CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES="$GPU" VLLM_USE_FLASHINFER_SAMPLER=0 \
  "$HOME/vllm/.venv/bin/vllm" serve "$MODEL" --host 127.0.0.1 --port 8009 --api-key "$VLLM_API_KEY" --served-model-name trial \
  --max-model-len 8192 --max-num-seqs 2 --gpu-memory-utilization 0.95 "$@" > "$LOG" 2>&1 < /dev/null &
up=0
for _ in $(seq 1 90); do
  if curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $VLLM_API_KEY" localhost:8009/v1/models | grep -q 200; then up=1; break; fi
  if grep -qE "OutOfMemory|ValueError|RuntimeError: Engine|Error: " "$LOG"; then break; fi
  sleep 10
done
if [ "$up" = 0 ]; then
  echo "TRIAL FAILED: $LABEL -> $(grep -E "OutOfMemory|ValueError|Error" "$LOG" | tail -1 | cut -c1-200)"
  pkill -f "served-model-name trial" 2>/dev/null || true; exit 1
fi
grep -E "Free memory on device|KV cache size" "$LOG" | sed "s/.*\] //" | tail -2 | cut -c1-200
echo "VRAM: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader -i "$GPU")"
python3 bench.py --base http://127.0.0.1:8009/v1 --model trial --label "$LABEL" --no-think 2>&1 | tail -9
pkill -f "served-model-name trial" 2>/dev/null || true; sleep 3
