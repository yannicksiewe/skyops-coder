#!/usr/bin/env bash
# Install a self-hosted GitHub Actions runner on this VM as a systemd service, plus the tools the workflows need.
# Usage: REPO=owner/name TOKEN=<registration token> ./install_runner.sh
#   (token: gh api -X POST repos/OWNER/NAME/actions/runners/registration-token -q .token ; valid 1 hour)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive PATH="$HOME/.local/bin:$PATH"
REPO="${REPO:?REPO=owner/name}"; TOKEN="${TOKEN:?TOKEN=registration token}"
DIR="$HOME/actions-runner"; LABELS="${LABELS:-self-hosted,linux,skyops}"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "Tools used by the workflows: shellcheck, gh, jq, aider, pytest venv"
sudo apt-get install -y -qq shellcheck jq >/dev/null
if ! command -v gh >/dev/null; then
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq gh >/dev/null
fi
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
command -v aider >/dev/null || uv tool install -q --python 3.12 aider-chat
[ -d "$HOME/agents/.venv" ] || uv venv -q "$HOME/agents/.venv" --python 3.12
uv pip install -q --python "$HOME/agents/.venv/bin/python" pytest

log "GitHub Actions runner"
mkdir -p "$DIR"; cd "$DIR"
if [ ! -x ./config.sh ]; then
  VER=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
  curl -fsSL -o runner.tar.gz "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-x64-${VER}.tar.gz"
  tar xzf runner.tar.gz && rm runner.tar.gz
fi
if [ ! -f .runner ]; then
  ./config.sh --unattended --url "https://github.com/${REPO}" --token "$TOKEN" \
    --name "$(hostname)" --labels "$LABELS" --work _work --replace
fi
sudo ./svc.sh install "$USER" >/dev/null 2>&1 || true
sudo ./svc.sh start >/dev/null 2>&1 || true
sudo ./svc.sh status | tail -2
echo "Done. Runner '$(hostname)' with labels [$LABELS] registered to $REPO."
