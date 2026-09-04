#!/usr/bin/env bash
# Install/upgrade the LLM gateway. Idempotent. Creates /etc/litellm/{litellm.env,pg_password} on first run
# and virtual keys for the standard clients (printed once, also kept in /etc/litellm/keys.txt, root-only).
set -euo pipefail
cd "$(dirname "$0")"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }
. /etc/vllm.env

log "Secrets"
sudo mkdir -p /etc/litellm
[ -f /etc/litellm/pg_password ] || openssl rand -hex 16 | sudo tee /etc/litellm/pg_password >/dev/null
if [ ! -f /etc/litellm/litellm.env ]; then
  PG=$(sudo cat /etc/litellm/pg_password)
  printf 'LITELLM_MASTER_KEY=sk-master-%s\nDATABASE_URL=postgresql://litellm:%s@127.0.0.1:5432/litellm\nVLLM_API_KEY=%s\nLITELLM_LOG=INFO\nUI_USERNAME=admin\nUI_PASSWORD=%s\n' \
    "$(openssl rand -hex 16)" "$PG" "$VLLM_API_KEY" "$(openssl rand -base64 12)" | sudo tee /etc/litellm/litellm.env >/dev/null
fi
# Langfuse keys are appended by ops/langfuse/install.sh when that stack is installed
sudo chmod 600 /etc/litellm/litellm.env /etc/litellm/pg_password; sudo chown root:root /etc/litellm/*

log "Containers"
sudo docker compose -f compose.yml up -d --remove-orphans 2>&1 | grep -vE "^\s*$" | tail -3
MASTER=$(sudo grep '^LITELLM_MASTER_KEY=' /etc/litellm/litellm.env | cut -d= -f2)
for _ in $(seq 1 60); do curl -sf -o /dev/null -H "Authorization: Bearer $MASTER" localhost:4000/health/liveliness && break; sleep 3; done
curl -s -H "Authorization: Bearer $MASTER" localhost:4000/models | python3 -c 'import sys,json; print("  models:", [m["id"] for m in json.load(sys.stdin)["data"]])'

log "Virtual keys (per client; budgets in USD-equivalent units, 0 = unlimited)"
mk() {  # name alias, team, max_budget in M tokens ("null" = unlimited), rpm
  local existing; existing=$(sudo grep -s "^$1=" /etc/litellm/keys.txt | cut -d= -f2 || true)
  local body; body="{\"key_alias\":\"$1\",\"team_id\":\"$2\",\"max_budget\":$3,\"budget_duration\":\"30d\",\"rpm_limit\":$4,\"models\":[\"coder-chat\",\"coder-vision\",\"coder-fim\"],\"metadata\":{\"purpose\":\"$1\"}}"
  if [ -n "$existing" ]; then
    curl -s -o /dev/null -X POST localhost:4000/key/update -H "Authorization: Bearer $MASTER" -H 'content-type: application/json' -d "{\"key\":\"$existing\",\"max_budget\":$3,\"budget_duration\":\"30d\",\"rpm_limit\":$4}"; echo "  $1: updated"; return
  fi
  local key; key=$(curl -s -X POST localhost:4000/key/generate -H "Authorization: Bearer $MASTER" -H 'content-type: application/json' -d "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])')
  echo "$1=$key" | sudo tee -a /etc/litellm/keys.txt >/dev/null; echo "  $1: created"
}
for t in engineering agents; do curl -s -o /dev/null -X POST localhost:4000/team/new -H "Authorization: Bearer $MASTER" -H 'content-type: application/json' -d "{\"team_id\":\"$t\",\"team_alias\":\"$t\"}" || true; done
mk webui engineering null 600            # unlimited; per-user limits are better set on user objects (docs/governance.md)
mk ci-agents agents 200 300              # 200 M tokens / 30 days
mk shared-clients engineering 500 600    # 500 M tokens / 30 days
sudo cp /dev/null /etc/litellm/metrics_token; sudo sh -c "echo '$MASTER' > /etc/litellm/metrics_token"; sudo chmod 644 /etc/litellm/metrics_token   # Prometheus scrapes /metrics with it
sudo chmod 600 /etc/litellm/keys.txt
# agents on the CI runner (user ubuntu) talk to the gateway with their own key
printf 'LLM_BASE_URL=http://127.0.0.1:4000/v1\nLLM_API_KEY=%s\nLLM_MODEL=coder-chat\n' "$(sudo grep '^ci-agents=' /etc/litellm/keys.txt | cut -d= -f2)" | sudo tee /etc/litellm/agents.env >/dev/null
sudo chown root:ubuntu /etc/litellm/agents.env; sudo chmod 640 /etc/litellm/agents.env
# external clients (Continue, aider, SDKs) reach the gateway through Caddy's api.<zone>
if [ -f /etc/caddy/Caddyfile ] && grep -qE "^api\.[a-z0-9.-]+ \{" /etc/caddy/Caddyfile; then
  sudo sed -i -E '/^api\.[a-z0-9.-]+ \{/,/^\}/ s#reverse_proxy 127.0.0.1:8000#reverse_proxy 127.0.0.1:4000#' /etc/caddy/Caddyfile && sudo systemctl reload caddy && echo "  api.<zone> now routes to the gateway"
fi
echo "keys in /etc/litellm/keys.txt (root). Admin UI: http://127.0.0.1:4000/ui  (user admin, password in /etc/litellm/litellm.env)"
echo "Done."
