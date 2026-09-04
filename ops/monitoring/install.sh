#!/usr/bin/env bash
# Monitoring stack on the VM: Prometheus, Grafana, node exporter (docker compose) + NVIDIA exporter (host binary) + Caddy host.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "NVIDIA exporter (nvidia_gpu_exporter, wraps nvidia-smi; no container toolkit needed)"
if ! command -v nvidia_gpu_exporter >/dev/null; then
  VER=$(curl -fsSL https://api.github.com/repos/utkuozdemir/nvidia_gpu_exporter/releases/latest | grep -oE '"tag_name": *"v[^"]+"' | grep -oE '[0-9.]+')
  curl -fsSL -o /tmp/nvexp.deb "https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v${VER}/nvidia-gpu-exporter_${VER}_linux_amd64.deb"
  sudo dpkg -i /tmp/nvexp.deb >/dev/null && rm -f /tmp/nvexp.deb
fi
sudo mkdir -p /etc/systemd/system/nvidia_gpu_exporter.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/nvidia_gpu_exporter --web.listen-address=127.0.0.1:9835\n' | sudo tee /etc/systemd/system/nvidia_gpu_exporter.service.d/override.conf >/dev/null
sudo systemctl daemon-reload; sudo systemctl enable --now nvidia_gpu_exporter >/dev/null; sudo systemctl restart nvidia_gpu_exporter

log "Grafana admin password (kept in /etc/grafana_admin)"
[ -f /etc/grafana_admin ] || { openssl rand -base64 18 | sudo tee /etc/grafana_admin >/dev/null; sudo chmod 644 /etc/grafana_admin; }

log "Prometheus + Grafana + node exporter"
sudo docker compose -f compose.yml up -d --remove-orphans 2>&1 | grep -vE "^\s*$" | tail -3

log "Caddy host grafana.<zone>"
ZONE=$(grep -oE 'coder\.[a-z0-9.-]+' /etc/caddy/Caddyfile 2>/dev/null | head -1 | sed 's/^coder\.//' || true)
if [ -n "${ZONE:-}" ] && ! grep -q "grafana.${ZONE}" /etc/caddy/Caddyfile; then
  printf 'grafana.%s {\n\treverse_proxy 127.0.0.1:3001\n}\nprometheus.%s {\n\treverse_proxy 127.0.0.1:9090\n}\n' "$ZONE" "$ZONE" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
  sudo systemctl reload caddy
fi

log "Self-test"
for _ in $(seq 1 30); do curl -sf localhost:9090/-/ready >/dev/null && break; sleep 2; done
curl -s 'localhost:9090/api/v1/targets' | python3 targets.py
for _ in $(seq 1 30); do curl -sf localhost:3001/api/health >/dev/null && break; sleep 2; done
echo "grafana: $(curl -s localhost:3001/api/health | tr -d '\n')  login admin / $(sudo cat /etc/grafana_admin)"
echo "Done."
