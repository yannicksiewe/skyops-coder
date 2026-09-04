#!/usr/bin/env bash
# One-time client setup on a Mac: trust the VM's local CA and resolve *.<ZONE> via the VM's DNS.
# Usage: clients/mac-setup.sh ubuntu@<VM_IP> [zone]
set -euo pipefail
HOST="${1:?usage: mac-setup.sh user@vm-ip [zone]}"; ZONE="${2:-skyops.lan}"; IP="${HOST#*@}"
cd "$(dirname "$0")"; mkdir -p local
scp -q "$HOST:~/${ZONE}-root.crt" "local/${ZONE}-root.crt"
echo "Trusting ${ZONE} CA in your login keychain (macOS may show a prompt)..."
security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "local/${ZONE}-root.crt"
echo "Now point *.${ZONE} at the VM (needs sudo once):"
echo "  sudo mkdir -p /etc/resolver && printf 'nameserver ${IP}\n' | sudo tee /etc/resolver/${ZONE}"
echo "Then open https://coder.${ZONE}  (or https://$(ssh -o BatchMode=yes "$HOST" hostname).local without any DNS change)"
