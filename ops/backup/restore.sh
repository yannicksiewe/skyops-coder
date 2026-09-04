#!/usr/bin/env bash
# Restore state from a backup archive onto a VM that already has the base stack installed
# (infra/deploy.sh + serving/deploy_serving.sh). Usage: restore.sh /srv/backups/skyops-<date>.tar.gz[.age] [--dry-run]
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
UHOME="${UHOME:-/home/ubuntu}"
[ -f /etc/skyops-backup.env ] && . /etc/skyops-backup.env
ARCHIVE="${1:?archive}"; DRY="${2:-}"
WORK=$(mktemp -d /tmp/skyops-restore.XXXXXX); trap 'rm -rf "$WORK"' EXIT
case "$ARCHIVE" in
  *.age) age -d -i "${AGE_IDENTITY:?AGE_IDENTITY=path to age key}" "$ARCHIVE" > "$WORK/a.tar.gz" ;;
  *) cp "$ARCHIVE" "$WORK/a.tar.gz" ;;
esac
tar -C "$WORK" -xzf "$WORK/a.tar.gz"; S="$WORK/state"
echo "archive contents:"; ls -la "$S" | awk 'NR>1{print "  "$NF, $5}'; cat "$S/MANIFEST.txt"
[ "$DRY" = "--dry-run" ] && { echo "dry run, nothing restored"; exit 0; }

install -m 640 -o root -g ubuntu "$S/vllm.env" /etc/vllm.env
[ -f "$S/grafana_admin" ] && install -m 644 "$S/grafana_admin" /etc/grafana_admin
[ -f "$S/Caddyfile" ] && install -m 644 "$S/Caddyfile" /etc/caddy/Caddyfile
[ -f "$S/caddy-pki.tgz" ] && mkdir -p /var/lib/caddy && tar -C /var/lib/caddy -xzf "$S/caddy-pki.tgz" && chown -R caddy:caddy /var/lib/caddy
for t in "$S"/etc-*.tgz; do [ -f "$t" ] && tar -C /etc -xzf "$t"; done
for c in "$S"/*.conf; do [ -f "$c" ] && install -m 644 "$c" /etc/dnsmasq.d/; done
for t in "$S"/volume-*.tgz; do
  [ -f "$t" ] || continue; v=$(basename "$t" .tgz); v=${v#volume-}
  docker volume create "$v" >/dev/null
  docker run --rm -v "$v":/data -v "$S":/in:ro alpine:3.20 sh -c "rm -rf /data/* && tar -C /data -xzf /in/volume-$v.tgz"
  echo "restored volume $v"
done
[ -f "$S/ml-outputs.tgz" ] && mkdir -p "$UHOME/ml" && tar -C "$UHOME/ml" -xzf "$S/ml-outputs.tgz"
[ -f "$S/runner-identity.tgz" ] && [ -d "$UHOME/actions-runner" ] && tar -C "$UHOME/actions-runner" -xzf "$S/runner-identity.tgz"
systemctl restart caddy dnsmasq 2>/dev/null || true
docker restart open-webui >/dev/null 2>&1 || true
for d in gateway langfuse monitoring; do [ -f "$UHOME/ops/$d/compose.yml" ] && ( cd "$UHOME/ops/$d" && docker compose -f compose.yml up -d >/dev/null 2>&1 ) || true; done
systemctl restart vllm-chat vllm-autocomplete vllm-vision 2>/dev/null || true
echo "restore done; check: nvidia-smi, curl localhost:3000, systemctl status vllm-chat"
