# Operations: CI/CD, AI agents, monitoring, backup

## CI/CD on the office server

A GitHub Actions runner runs on the VM (`ops/runner/install_runner.sh`, systemd service
`actions.runner.*`), labelled `self-hosted, linux, skyops`. It polls GitHub; nothing is exposed inbound.

| Workflow | When | What |
|---|---|---|
| `ci` | every PR, every push to `main` | shellcheck, Python compile, agent unit tests, unit-file syntax |
| `ai-code-review` | PR opened / updated | local model reviews the diff and posts a PR review with inline comments |
| `ai-architecture-review` | label `architecture-review` on a PR, or comment `/arch-review` | repo map + diff -> architecture report as a comment |
| `ai-task` | label `ai-task` on an issue | aider implements the issue on branch `ai/issue-N`, opens a PR |
| `cd` | push to `main` touching `serving/`, `ops/`, `infra/` | `serving/apply.sh` on the VM: restart only changed units, health-check all endpoints |

How colleagues use it: open PRs as usual and read the AI review like any other reviewer's; add the label
`no-ai-review` to skip it. For a design discussion add `architecture-review`. To delegate a small, well-described
task, write an issue and label it `ai-task`; review the PR that comes back critically.

Runner operations: `sudo systemctl status 'actions.runner.*'`, logs in `~/actions-runner/_diag/`. Re-register with a
fresh token from `gh api -X POST repos/OWNER/REPO/actions/runners/registration-token -q .token`.

## Monitoring

`ops/monitoring/install.sh` runs Prometheus (30-day retention), Grafana and node_exporter in Docker on the host
network, plus `nvidia_gpu_exporter` as a host service. Grafana: `https://grafana.skyops.lan` (admin password in
`/etc/grafana_admin`), Prometheus: `https://prometheus.skyops.lan`. Dashboards are provisioned from files:
**vLLM (skyops)** (the upstream vLLM dashboard: request rate, TTFT, latency, KV cache, queue) and
**Host & GPUs (skyops)** (GPU util/memory/temperature/power, CPU, RAM, disk, tokens/s, p95 latency).

Alert rules (`ops/monitoring/alerts.yml`): model endpoint down 3 min, GPU > 85 C, KV cache > 95 % for 10 min,
root disk < 10 %. They show in Prometheus -> Alerts; wire an Alertmanager receiver (Slack/mail) when needed.

What to look at when something is slow: `vllm:num_requests_waiting` (queueing = KV cache full, lower
`--max-num-seqs` or context), `vllm:gpu_cache_usage_perc`, GPU temperature (thermal throttling on the 2080 shows
as rising temperature with falling tokens/s).

## Backup and recovery

Nightly at 03:00 (`skyops-backup.timer`), `ops/backup/backup.sh` writes an age-encrypted archive to `/srv/backups`
(14 kept) containing: `/etc/vllm.env` (API key + model names), Caddy CA and Caddyfile, dnsmasq zone, Grafana admin
password, runner identity, the Open WebUI volume (users, chats, uploads, RAG index; model caches excluded), the
Grafana volume, LoRA adapters, and a manifest of versions/models. Typical size: ~200 MB.

**Keep `/etc/skyops/backup-age.key` somewhere else** (password manager, second machine). Without it the archives
cannot be read. Set `BACKUP_REMOTE=user@host:/path` in `/etc/skyops-backup.env` to mirror off-box with rsync.

Recovery on a fresh VM (RTO ~1 h, dominated by model downloads):
```bash
infra/deploy.sh ubuntu@<VM_IP>                   # driver, torch, training scripts (reboots once)
serving/deploy_serving.sh ubuntu@<VM_IP>         # vLLM services, Open WebUI, API key (a new one, replaced next step)
ssh ubuntu@<VM_IP> 'ZONE=skyops.lan ~/vllm/install_edge.sh; ~/ops/monitoring/install.sh; ~/ops/backup/install.sh'
scp skyops-<date>.tar.gz.age backup-age.key ubuntu@<VM_IP>:
ssh ubuntu@<VM_IP> 'sudo install -m600 backup-age.key /etc/skyops/backup-age.key; ~/ops/backup/restore.sh ~/skyops-<date>.tar.gz.age'
```
Restore proof: `ops/backup/restore_test.sh` restores the UI volume into a scratch volume and checks users/chats;
run it after any change to the backup script. Last verified: 2026-09-04, `users=1 chats=4`, PASSED.

## Disk housekeeping

The 96 GB disk holds ~17 GB of production model weights, ~15 GB of Python environments and the Docker images.
Model *trials* add 6-12 GB each and once filled the disk mid-download (the `DiskLow` alert covers this). After a
trial: `rm -rf ~/.cache/huggingface/hub/models--<org>--<model>`; `research/trial.sh` does not delete downloads on
purpose so a second run is fast. `sudo docker image prune -f` and `sudo journalctl --vacuum-size=200M` reclaim a
few GB more. Keep >= 20 GB free before starting a trial.

## Routine
* Weekly: glance at Grafana, `journalctl -u vllm-chat --since -7d | grep -c ERROR`, `df -h /`.
* Monthly: `sudo apt-get update && sudo apt-get upgrade` (kernel updates rebuild the NVIDIA module via DKMS; reboot),
  bump image tags in `ops/monitoring/compose.yml` and `serving/install.sh`, re-run the installers (idempotent).
* Before a model change: edit `/etc/vllm.env`, `sudo systemctl restart vllm-chat`, watch `journalctl -u vllm-chat -f`
  for the KV-cache line; roll back by reverting the variable.
