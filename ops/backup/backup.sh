#!/usr/bin/env bash
# Nightly backup of everything that is state (not re-downloadable) on the coding-assistant VM.
# Produces /srv/backups/skyops-<date>.tar.gz.age (age-encrypted) and keeps the newest $KEEP.
# Config (optional, /etc/skyops-backup.env): BACKUP_DIR, KEEP, AGE_RECIPIENT, BACKUP_REMOTE (rsync target user@host:/path)
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
UHOME="${UHOME:-/home/ubuntu}"
[ -f /etc/skyops-backup.env ] && . /etc/skyops-backup.env
BACKUP_DIR="${BACKUP_DIR:-/srv/backups}"; KEEP="${KEEP:-14}"
STAMP=$(date +%Y%m%d-%H%M%S); WORK=$(mktemp -d /tmp/skyops-backup.XXXXXX); trap 'rm -rf "$WORK"' EXIT
OUT="$BACKUP_DIR/skyops-$STAMP.tar.gz"
mkdir -p "$BACKUP_DIR" "$WORK/state"

# 1. secrets & identity
cp /etc/vllm.env /etc/grafana_admin "$WORK/state/" 2>/dev/null || true
tar -C /var/lib/caddy -czf "$WORK/state/caddy-pki.tgz" .local/share/caddy/pki 2>/dev/null || true
[ -d "$UHOME/actions-runner" ] && tar -C "$UHOME/actions-runner" -czf "$WORK/state/runner-identity.tgz" .runner .credentials .credentials_rsaparams 2>/dev/null || true
cp /etc/caddy/Caddyfile "$WORK/state/" 2>/dev/null || true
cp /etc/dnsmasq.d/*.conf "$WORK/state/" 2>/dev/null || true
# 2. user data: docker volumes
for v in open-webui monitoring_grafana-data; do
  docker volume inspect "$v" >/dev/null 2>&1 && docker run --rm -v "$v":/data:ro -v "$WORK/state":/out alpine:3.20 tar -C /data --exclude=./cache -czf "/out/volume-$v.tgz" .  # ./cache = re-downloadable whisper/embedding models || true
done
# 3. work products: LoRA adapters
[ -d "$UHOME/ml/outputs" ] && tar -C "$UHOME/ml" -czf "$WORK/state/ml-outputs.tgz" outputs || true
# 4. manifest: what to re-download / versions, for the restore runbook
{
  echo "date=$STAMP host=$(hostname)"; grep -E '^(CHAT|FIM|VISION)_MODEL=' /etc/vllm.env 2>/dev/null || true
  echo "driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  echo "vllm=$("$UHOME/vllm/.venv/bin/python" -c 'import vllm;print(vllm.__version__)' 2>/dev/null | tail -1)"
  docker ps --format 'container={{.Names}} image={{.Image}}'
} > "$WORK/state/MANIFEST.txt"

tar -C "$WORK" -czf "$OUT" state
if [ -n "${AGE_RECIPIENT:-}" ] && command -v age >/dev/null; then
  age -r "$AGE_RECIPIENT" -o "$OUT.age" "$OUT" && rm -f "$OUT"; OUT="$OUT.age"
fi
chmod 600 "$OUT"; echo "backup: $OUT ($(du -h "$OUT" | cut -f1))"
# rotation
ls -1t "$BACKUP_DIR"/skyops-*.tar.gz* 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
# optional off-box copy
if [ -n "${BACKUP_REMOTE:-}" ]; then rsync -a --delete "$BACKUP_DIR"/ "$BACKUP_REMOTE"/ && echo "mirrored to $BACKUP_REMOTE"; fi
