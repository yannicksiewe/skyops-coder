#!/usr/bin/env bash
# Coding agent: implement a GitHub issue with aider on the local model, push a branch, open a PR.
# Usage (inside a checkout on the runner): agents/issue_to_pr.sh <issue-number>
# Needs: GH_TOKEN (or GITHUB_TOKEN), GITHUB_REPOSITORY, /etc/vllm.env for the model key, aider on PATH.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
N="${1:?issue number}"; REPO="${GITHUB_REPOSITORY:?}"; export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:?}}"
. /etc/vllm.env
export OPENAI_API_BASE="${LLM_BASE_URL:-http://127.0.0.1:8000/v1}" OPENAI_API_KEY="$VLLM_API_KEY"
MODEL="openai/${LLM_MODEL:-coder-chat}"
TITLE=$(gh issue view "$N" --repo "$REPO" --json title -q .title)
BODY=$(gh issue view "$N" --repo "$REPO" --json body -q .body)
BRANCH="ai/issue-${N}"
git config user.name "skyops-coder agent"; git config user.email "agent@skyops.lan"
git checkout -B "$BRANCH"
gh issue comment "$N" --repo "$REPO" --body "🤖 Working on this with the local model (\`$MODEL\`) on branch \`$BRANCH\`." >/dev/null
TASK=$(printf 'Implement GitHub issue #%s: %s\n\n%s\n\nRules: change only what the issue asks; keep the existing style; add or update tests when behaviour changes; do not touch unrelated files.' "$N" "$TITLE" "$BODY")
aider --model "$MODEL" --yes-always --no-show-model-warnings --no-stream --auto-commits --message "$TASK" 2>&1 | tail -40
if [ -z "$(git log --oneline origin/main..HEAD 2>/dev/null)" ] && [ -z "$(git status --porcelain)" ]; then
  gh issue comment "$N" --repo "$REPO" --body "🤖 The agent made no changes for this issue. It may need a clearer description or a smaller scope." >/dev/null
  exit 0
fi
git add -A; git diff --cached --quiet || git commit -q -m "AI agent: ${TITLE} (#${N})"
git push -f origin "$BRANCH"
PR=$(gh pr list --repo "$REPO" --head "$BRANCH" --json number -q '.[0].number')
if [ -z "$PR" ]; then
  gh pr create --repo "$REPO" --head "$BRANCH" --title "AI: ${TITLE}" --body "$(printf 'Implements #%s with the local model `%s` via aider.\n\nCloses #%s\n\n🤖 Review carefully: this PR was produced by an agent.' "$N" "$MODEL" "$N")"
else
  gh pr comment "$PR" --repo "$REPO" --body "🤖 Updated from issue #$N." >/dev/null
fi
