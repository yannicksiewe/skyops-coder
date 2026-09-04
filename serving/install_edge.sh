#!/usr/bin/env bash
# Edge for the coding-assistant VM: local DNS zone (dnsmasq), mDNS (avahi) and HTTPS reverse proxy (Caddy, local CA).
#   https://coder.<ZONE>  -> Open WebUI :3000        https://api.<ZONE> -> chat :8000        https://fim.<ZONE> -> autocomplete :8001
#   https://<hostname>.local (mDNS, no client DNS change needed) -> Open WebUI
# Idempotent. Usage: ZONE=skyops.lan ./install_edge.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
ZONE="${ZONE:-skyops.lan}"
IP="${IP:-$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)}"
HOST="$(hostname)"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "Packages (dnsmasq, avahi, caddy) for $HOST at $IP, zone $ZONE"
if ! command -v caddy >/dev/null; then
  sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
fi
sudo apt-get update -qq
sudo apt-get install -y -qq dnsmasq avahi-daemon caddy >/dev/null

log "dnsmasq: authoritative for *.$ZONE, listening on $IP only (systemd-resolved keeps 127.0.0.53)"
sudo tee /etc/dnsmasq.d/${ZONE}.conf >/dev/null <<CONF
listen-address=${IP}
bind-interfaces
no-resolv
no-hosts
address=/${ZONE}/${IP}
local=/${ZONE}/
CONF
sudo systemctl enable --now dnsmasq >/dev/null
sudo systemctl restart dnsmasq

log "avahi: ${HOST}.local via mDNS (LAN interface only, not docker0)"
IFACE="$(ip -4 -o addr show scope global | awk '{print $2}' | head -1)"
sudo sed -i -E "s/^#?allow-interfaces=.*/allow-interfaces=${IFACE}/" /etc/avahi/avahi-daemon.conf
sudo systemctl enable --now avahi-daemon >/dev/null
sudo systemctl restart avahi-daemon

log "Caddy: HTTPS with an internal CA"
sudo tee /etc/caddy/Caddyfile >/dev/null <<CONF
{
	local_certs
}
coder.${ZONE}, ${HOST}.local, ${IP} {
	reverse_proxy 127.0.0.1:3000
}
api.${ZONE} {
	reverse_proxy 127.0.0.1:8000
}
fim.${ZONE} {
	reverse_proxy 127.0.0.1:8001
}
vision.${ZONE} {
	reverse_proxy 127.0.0.1:8002
}
CONF
sudo caddy validate --config /etc/caddy/Caddyfile >/dev/null
sudo systemctl enable --now caddy >/dev/null
sudo systemctl reload caddy || sudo systemctl restart caddy
sleep 3
ROOT=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
sudo cp "$ROOT" "$HOME/${ZONE}-root.crt"; sudo chown "$USER" "$HOME/${ZONE}-root.crt"

log "Self-test"
dig +short "@${IP}" "coder.${ZONE}" | grep -q "$IP" && echo "DNS  coder.${ZONE} -> $IP  OK"
curl -s --cacert "$HOME/${ZONE}-root.crt" --resolve "coder.${ZONE}:443:${IP}" -o /dev/null -w "HTTPS coder.${ZONE} -> HTTP %{http_code}\n" "https://coder.${ZONE}/"
curl -s --cacert "$HOME/${ZONE}-root.crt" --resolve "api.${ZONE}:443:${IP}" -o /dev/null -w "HTTPS api.${ZONE}   -> HTTP %{http_code} (401 = up, needs key)\n" "https://api.${ZONE}/v1/models"
echo "CA root certificate for clients: $HOME/${ZONE}-root.crt"
echo "Done."
