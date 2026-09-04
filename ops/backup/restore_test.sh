#!/usr/bin/env bash
# Prove a backup is restorable without touching production: restore the Open WebUI volume into a scratch volume and compare.
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
UHOME="${UHOME:-/home/ubuntu}"
ARCHIVE="${1:-$(ls -1t /srv/backups/skyops-*.tar.gz* | head -1)}"
[ -f /etc/skyops-backup.env ] && . /etc/skyops-backup.env
WORK=$(mktemp -d /tmp/skyops-rtest.XXXXXX); trap 'rm -rf "$WORK"; docker volume rm -f skyops-restore-test >/dev/null 2>&1 || true' EXIT
case "$ARCHIVE" in *.age) age -d -i "${AGE_IDENTITY:?}" "$ARCHIVE" > "$WORK/a.tar.gz" ;; *) cp "$ARCHIVE" "$WORK/a.tar.gz" ;; esac
tar -C "$WORK" -xzf "$WORK/a.tar.gz"
docker volume create skyops-restore-test >/dev/null
docker run --rm -v skyops-restore-test:/data -v "$WORK/state":/in:ro alpine:3.20 tar -C /data -xzf /in/volume-open-webui.tgz
LIVE=$(docker run --rm -v open-webui:/a:ro alpine:3.20 sh -c 'cd /a && find . -type f | sort | wc -l')
REST=$(docker run --rm -v skyops-restore-test:/b:ro alpine:3.20 sh -c 'cd /b && find . -type f | sort | wc -l')
DB=$(docker run --rm -v skyops-restore-test:/b:ro python:3.12-alpine python3 -c "import sqlite3;c=sqlite3.connect('/b/webui.db');print('users=%d chats=%d' % (c.execute('select count(*) from user').fetchone()[0], c.execute('select count(*) from chat').fetchone()[0]))")
echo "restore test: archive=$(basename "$ARCHIVE") files live=$LIVE restored=$REST ($DB)"
[ "$REST" -ge 1 ] && [ "$REST" -le "$LIVE" ] && echo "RESTORE TEST PASSED" || { echo "RESTORE TEST FAILED"; exit 1; }
