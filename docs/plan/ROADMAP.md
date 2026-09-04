# Roadmap: team AI assistant on the office GPU server

Goal: give colleagues an AI assistant for **coding, code review, architecture review, CI and CD**, running on the
office VM (2 x 8 GB GPUs, 14 vCPU, 46 GB RAM), with everything reproducible from this repository.

## Phases

| # | Phase | Deliverable | Status |
|---|---|---|---|
| 0 | Serving base | vLLM chat / autocomplete / vision, Open WebUI, HTTPS + local DNS | done |
| 1 | CI/CD on the office server | self-hosted GitHub Actions runner on the VM; `ci.yml` (lint + tests), `cd.yml` (deploy on merge) | this iteration |
| 2 | AI code review | `review.yml` posts a review on every PR using the local model; architecture review on request | this iteration |
| 3 | AI coding agent | issue labelled `ai-task` -> agent implements it with aider -> opens a PR | this iteration |
| 4 | Monitoring | Prometheus + Grafana + node/GPU exporters + vLLM metrics, dashboards in the repo | this iteration |
| 5 | Backup & recovery | nightly encrypted backup of state (keys, UI data, CA, adapters), tested restore | this iteration |
| 6 | Model research | measured comparison of what fits on 8 GB cards, incl. Qwen3.5-9B trial; GLM assessment | this iteration |
| 7 | Team rollout | accounts, usage guide for colleagues, feedback loop | next |

## Principles

* **Everything is code.** Services are systemd units and compose files in `serving/` and `ops/`; a fresh VM is
  rebuilt with `infra/deploy.sh` + `serving/deploy_serving.sh` + `ops/*/install.sh`.
* **The office server pulls, the cloud never pushes.** The GitHub runner polls GitHub over outbound HTTPS; no
  inbound port is opened. Deploys happen because the runner on the VM runs the deploy job.
* **Small model, tight prompts.** A 7B/9B model is not a frontier model. Agents get narrow tasks, structured
  output, and a human stays in the loop (reviews are comments, coding tasks are PRs).
* **One GPU, one job.** No time-sharing of a card between unrelated workloads; memory shares are fixed.

## Decisions

See `docs/adr/`. Short version: keep Qwen2.5-Coder-7B as chat model until the Qwen3.5-9B trial proves better
*and* fits; GLM-5.x cannot run on this hardware (320B MoE); GLM-4-9B-0414 is the only GLM that fits and is
older than the Qwen options.
