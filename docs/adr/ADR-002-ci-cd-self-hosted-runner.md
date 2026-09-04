# ADR-002: CI, code review and CD run on a self-hosted GitHub Actions runner on the office VM

**Status:** accepted (2026-09-04)

## Context
GitHub-hosted runners cannot reach the office LAN, so they cannot call the local models or deploy to the VM.
The VM can reach GitHub outbound.

## Decision
Install the GitHub Actions runner on the VM (`ops/runner/`), labelled `self-hosted, skyops`. Workflows:

| Workflow | Trigger | Runs |
|---|---|---|
| `ci.yml` | every PR and push to main | shellcheck, python compile, unit tests of the agents |
| `review.yml` | PR opened / synchronised (same-repo branches only) | `agents/review.py`: local model reviews the diff, posts a PR review |
| `arch-review.yml` | PR labelled `architecture-review` or comment `/arch-review` | `agents/arch_review.py`: repo map + diff -> architecture report comment |
| `ai-task.yml` | issue labelled `ai-task` | `agents/issue_to_pr.sh`: aider implements the issue on a branch, opens a PR |
| `cd.yml` | push to main touching `serving/**`, `ops/**`, `infra/**` | `serving/apply.sh`: apply units/config on the VM with change detection |

## Security consequences
* A self-hosted runner executes repository code. On a **public** repo, fork PRs must not run on it:
  workflows check `github.event.pull_request.head.repo.full_name == github.repository`, and the repo setting
  "Require approval for all outside collaborators" stays on. If the repo becomes company-internal, make it private.
* The runner runs as user `ubuntu` with sudo, because CD needs it. Only this repository is registered to it.
* Secrets: the model API key is read from `/etc/vllm.env` on the VM, never stored in GitHub.
