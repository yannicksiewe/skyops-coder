#!/usr/bin/env bash
# Apply serving config from a checkout on the VM (used by cd.yml). Restarts only what changed.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p "$HOME/vllm"; changed=()
for u in vllm-chat vllm-autocomplete vllm-vision; do
  if ! cmp -s "$u.service" "/etc/systemd/system/$u.service"; then sudo cp "$u.service" /etc/systemd/system/; changed+=("$u"); fi
done
cp -f install.sh install_edge.sh webui_config.py vllm-*.service "$HOME/vllm/"
if [ ${#changed[@]} -gt 0 ]; then
  sudo systemctl daemon-reload; sudo systemctl restart "${changed[@]}"; echo "restarted: ${changed[*]}"
else echo "units unchanged"; fi
if [ -f /etc/caddy/Caddyfile ] && grep -q vision.skyops.lan /etc/caddy/Caddyfile; then sudo systemctl reload caddy || true; fi
