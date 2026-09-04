# ADR-004: Backup and recovery

**Status:** accepted (2026-09-04)

## What is state, what is not
| Category | Examples | Strategy |
|---|---|---|
| Code & config | this repo | GitHub is the copy; the VM is rebuilt from it |
| Secrets & identity | `/etc/vllm.env` (API key), Caddy CA (`/var/lib/caddy/.../pki`), runner credentials | nightly encrypted backup |
| User data | Open WebUI volume (accounts, chats, uploads), Grafana volume (dashboards edited by hand) | nightly backup |
| Work products | LoRA adapters in `~/ml/outputs` | nightly backup |
| Re-downloadable | model weights (~17 GB), venvs (~15 GB) | not backed up; manifest of model ids is |

## Decision
`ops/backup/backup.sh` produces one `age`-encrypted tarball per night (systemd timer 03:00), keeps 14 locally in
`/srv/backups`, and optionally mirrors to a second machine with rsync (`BACKUP_REMOTE`). `ops/backup/restore.sh`
rebuilds state on a fresh VM after `infra/deploy.sh` + `serving/deploy_serving.sh`. Restore is tested by restoring
the UI volume into a scratch volume and comparing. RPO 24 h, RTO ~1 h (dominated by model download).
