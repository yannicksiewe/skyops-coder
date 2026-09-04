#!/usr/bin/env bash
# Install Langfuse (traces with content) and connect the LiteLLM gateway to it. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }
ZONE=$(grep -oE 'coder\.[a-z0-9.-]+' /etc/caddy/Caddyfile 2>/dev/null | head -1 | sed 's/^coder\.//' || echo skyops.lan)

log "Secrets in /etc/langfuse"
sudo mkdir -p /etc/langfuse
for f in pg_password clickhouse_password redis_password; do [ -f /etc/langfuse/$f ] || openssl rand -hex 16 | sudo tee /etc/langfuse/$f >/dev/null; done
sudo chmod 644 /etc/langfuse/*_password   # read inside containers by non-root users (clickhouse, redis)
if [ ! -f /etc/langfuse/langfuse.env ]; then
  PG=$(sudo cat /etc/langfuse/pg_password); CH=$(sudo cat /etc/langfuse/clickhouse_password); RD=$(sudo cat /etc/langfuse/redis_password)
  MINIO_PW=$(openssl rand -hex 16); PUB="pk-lf-$(openssl rand -hex 12)"; SEC="sk-lf-$(openssl rand -hex 12)"; ADMIN_PW=$(openssl rand -base64 12)
  sudo tee /etc/langfuse/langfuse.env >/dev/null <<ENV
DATABASE_URL=postgresql://langfuse:${PG}@postgres:5432/langfuse
NEXTAUTH_URL=https://langfuse.${ZONE}
NEXTAUTH_SECRET=$(openssl rand -hex 32)
SALT=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
TELEMETRY_ENABLED=false
LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES=false
CLICKHOUSE_MIGRATION_URL=clickhouse://clickhouse:9000
CLICKHOUSE_URL=http://clickhouse:8123
CLICKHOUSE_USER=clickhouse
CLICKHOUSE_PASSWORD=${CH}
CLICKHOUSE_CLUSTER_ENABLED=false
LANGFUSE_USE_AZURE_BLOB=false
LANGFUSE_S3_EVENT_UPLOAD_BUCKET=langfuse
LANGFUSE_S3_EVENT_UPLOAD_REGION=auto
LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID=minio
LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=${MINIO_PW}
LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT=http://minio:9000
LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE=true
LANGFUSE_S3_EVENT_UPLOAD_PREFIX=events/
LANGFUSE_S3_MEDIA_UPLOAD_BUCKET=langfuse
LANGFUSE_S3_MEDIA_UPLOAD_REGION=auto
LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID=minio
LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY=${MINIO_PW}
LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT=http://127.0.0.1:9095
LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE=true
LANGFUSE_S3_MEDIA_UPLOAD_PREFIX=media/
LANGFUSE_S3_BATCH_EXPORT_ENABLED=false
LANGFUSE_INGESTION_QUEUE_DELAY_MS=
LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS=
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_AUTH=${RD}
REDIS_TLS_ENABLED=false
LANGFUSE_INIT_ORG_ID=skyops
LANGFUSE_INIT_ORG_NAME=skyops
LANGFUSE_INIT_PROJECT_ID=coder
LANGFUSE_INIT_PROJECT_NAME=coder
LANGFUSE_INIT_PROJECT_PUBLIC_KEY=${PUB}
LANGFUSE_INIT_PROJECT_SECRET_KEY=${SEC}
LANGFUSE_INIT_USER_EMAIL=admin@${ZONE}
LANGFUSE_INIT_USER_NAME=admin
LANGFUSE_INIT_USER_PASSWORD=${ADMIN_PW}
ENV
  printf 'MINIO_ROOT_USER=minio\nMINIO_ROOT_PASSWORD=%s\n' "$MINIO_PW" | sudo tee /etc/langfuse/minio.env >/dev/null
  sudo chmod 600 /etc/langfuse/langfuse.env /etc/langfuse/minio.env
fi

log "Containers (first pull is ~3 GB)"
sudo docker compose -f compose.yml up -d --remove-orphans 2>&1 | grep -vE "^\s*$" | tail -3
for _ in $(seq 1 120); do curl -sf -o /dev/null localhost:3002/api/public/health && break; sleep 5; done
echo "langfuse web: $(curl -s localhost:3002/api/public/health | tr -d '\n' | cut -c1-80)"

log "LiteLLM -> Langfuse (traces with content)"
PUB=$(sudo grep '^LANGFUSE_INIT_PROJECT_PUBLIC_KEY=' /etc/langfuse/langfuse.env | cut -d= -f2)
SEC=$(sudo grep '^LANGFUSE_INIT_PROJECT_SECRET_KEY=' /etc/langfuse/langfuse.env | cut -d= -f2)
if ! sudo grep -q '^LANGFUSE_PUBLIC_KEY=' /etc/litellm/litellm.env; then
  printf 'LANGFUSE_PUBLIC_KEY=%s\nLANGFUSE_SECRET_KEY=%s\nLANGFUSE_HOST=http://127.0.0.1:3002\n' "$PUB" "$SEC" | sudo tee -a /etc/litellm/litellm.env >/dev/null
fi
( cd "$(dirname "$0")/../gateway" && sudo docker compose -f compose.yml up -d --force-recreate litellm >/dev/null 2>&1 )

log "Caddy host langfuse.$ZONE"
if [ -f /etc/caddy/Caddyfile ] && ! grep -q "langfuse.${ZONE}" /etc/caddy/Caddyfile; then
  printf 'langfuse.%s {\n\treverse_proxy 127.0.0.1:3002\n}\n' "$ZONE" | sudo tee -a /etc/caddy/Caddyfile >/dev/null; sudo systemctl reload caddy
fi
echo "Langfuse: https://langfuse.$ZONE  login admin@$ZONE / $(sudo grep '^LANGFUSE_INIT_USER_PASSWORD=' /etc/langfuse/langfuse.env | cut -d= -f2)"
echo "Done."
