#!/usr/bin/env bash
# Install the backup scripts, an age key (if none), and the nightly timer. Usage: ./install.sh [age-recipient]
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"; chmod +x backup.sh restore.sh restore_test.sh
sudo apt-get install -y -qq age rsync >/dev/null
if [ ! -f /etc/skyops-backup.env ]; then
  sudo mkdir -p /etc/skyops
  if [ ! -f /etc/skyops/backup-age.key ]; then sudo sh -c 'age-keygen -o /etc/skyops/backup-age.key 2>/dev/null'; sudo chmod 600 /etc/skyops/backup-age.key; fi
  REC="${1:-$(sudo grep -oE 'age1[0-9a-z]+' /etc/skyops/backup-age.key | head -1)}"
  printf 'BACKUP_DIR=/srv/backups\nKEEP=14\nAGE_RECIPIENT=%s\nAGE_IDENTITY=/etc/skyops/backup-age.key\n#BACKUP_REMOTE=user@host:/backups/skyops\n' "$REC" | sudo tee /etc/skyops-backup.env >/dev/null
  echo "KEEP A COPY OF /etc/skyops/backup-age.key OFF THIS MACHINE: without it the backups cannot be decrypted."
fi
sudo cp skyops-backup.service skyops-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload; sudo systemctl enable --now skyops-backup.timer >/dev/null
sudo mkdir -p /srv/backups
echo "timer: $(systemctl list-timers skyops-backup.timer --no-pager | sed -n 2p | awk '{print $1, $2, $3}')"
