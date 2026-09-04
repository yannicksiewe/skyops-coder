# Governance and deep monitoring: who uses what, how much, how fast, and what was said

Two components, both on the VM, no GPU use:

| Component | Role | Where |
|---|---|---|
| **LiteLLM gateway** (`ops/gateway/`) | single entry point for every client; API keys per client/team with budgets and rate limits; token and latency accounting per user, key and model; Prometheus metrics; admin UI | `127.0.0.1:4000`, `https://api.skyops.lan` (external clients), admin UI `http://127.0.0.1:4000/ui` via SSH tunnel |
| **Langfuse** (`ops/langfuse/`) | one trace per request: prompt, response, user, model, latency, time to first token, tokens; search, scores, datasets | `https://langfuse.skyops.lan` (login in `/etc/langfuse/langfuse.env`) |

Traffic: Open WebUI, Continue, aider, SDKs and the CI agents -> gateway (`:4000`) -> vLLM (`:8000/:8001/:8002`).
Open WebUI forwards the logged-in user's e-mail (`X-OpenWebUI-User-Email`), the gateway records it as `end_user`
and passes it to Langfuse as `userId`. API clients are attributed by their key alias (and by `user` in the request
body if they set it).

## What you can answer now

| Question | Where |
|---|---|
| How many people are using it right now / today? | Grafana **Usage & governance**: *Users active*, *Requests in flight* |
| Tokens per user / model / client, last day / week | same dashboard (tables) or `litellm_input_tokens_metric_total` + `litellm_output_tokens_metric_total` by `end_user`, `model`, `api_key_alias` |
| Time to reply, p50/p95, per model | same dashboard (`litellm_request_total_latency_metric`, `litellm_llm_api_latency_metric`); TTFT per model in the **vLLM** dashboard |
| What exactly was asked and answered, by whom, how long it took | Langfuse -> Traces (filter by user, model, latency, date; full text search) |
| Who pasted secrets, how often, which kind? | Grafana **Usage & governance** -> section *Secrets in prompts* (counts by type and user, metric `skyops_secrets_detected_total`); the redacted content itself in Langfuse -> Traces, filter tag `secrets-redacted` / `secret:<type>` |
| Was the answer good? | Langfuse scores: thumbs from reviewers, or automated scoring later; Open WebUI's own thumbs up/down stay in its DB |
| Who is over budget? | gateway admin UI -> Keys / Users; metric `litellm_remaining_api_key_budget_metric` |
| Failures and their causes | dashboard *Failed requests*; Langfuse traces with `level=ERROR` |

## Units: budgets and "spend" are millions of tokens

The models cost nothing per token, so the gateway's cost is defined as `1e-6` per token
(`ops/gateway/config.yaml`). A budget of `200` therefore means **200 M tokens per 30 days**. Keys:

| Key alias | Team | Budget / 30 d | Rate | Used by |
|---|---|---|---|---|
| `webui` | engineering | unlimited (per-user limits go on users, see below) | 600 rpm | Open WebUI |
| `shared-clients` | engineering | 500 M tokens | 600 rpm | Continue / aider / SDKs via `https://api.skyops.lan` |
| `ci-agents` | agents | 200 M tokens | 300 rpm | review, architecture review, issue-to-PR |

Keys are in `/etc/litellm/keys.txt` (root). Create a personal key with its own budget:
```bash
MASTER=$(sudo grep LITELLM_MASTER_KEY /etc/litellm/litellm.env | cut -d= -f2)
curl -s -X POST localhost:4000/key/generate -H "Authorization: Bearer $MASTER" -H 'content-type: application/json' \
  -d '{"key_alias":"alice-laptop","team_id":"engineering","max_budget":50,"budget_duration":"30d","rpm_limit":120,"models":["coder-chat","coder-vision","coder-fim"]}'
```
Per-user limits for web users: `POST /user/new` with `user_id` = their e-mail and `max_budget`; the gateway matches the
forwarded e-mail. Or do it in the admin UI (Users tab).

## Secrets in prompts: detected and redacted at the gateway, before the model and before Langfuse

Langfuse only records; it cannot stop a password from reaching the model. The gateway can, because it sees every
request first. `ops/gateway/guardrails/secrets_guardrail.py` runs as a LiteLLM **pre-call guardrail** on every
request (chat, completions, agents, review diffs):

* Detects: AWS / GitHub / Slack / Google / OpenAI-style API keys, JWTs, private-key blocks, credentials inside
  URLs (`scheme://user:pass@host`), `password: ...` / `api_key=...` style assignments, and high-entropy strings next
  to words like key/secret/token. Placeholders (`${VAR}`, `<your-token>`, `os.environ[...]`) are left alone.
* **Redact mode (default):** the secret is replaced by `[REDACTED_<TYPE>]`. The model answers on the redacted text;
  Langfuse stores only the redacted text; the trace gets the tags `secrets-redacted` and `secret:<type>`, so
  Langfuse can list who sends secrets, how often, and of which kind (filter by tag; the user is attributed).
* **Block mode:** `SECRETS_GUARDRAIL_MODE=block` in `ops/gateway/compose.yml` (or the shell) returns HTTP 400 with
  an explanation instead of forwarding. Use it once the team has seen the redaction reports for a while.
* Verified end to end: a prompt containing an AWS key id and a password reached the model as
  `aws_access_key_id = [REDACTED_AWS_ACCESS_KEY]`, `password: [REDACTED_PASSWORD_ASSIGNMENT]`, and the Langfuse trace
  stores exactly that, tagged `secret:aws_access_key`, `secret:password_assignment`.
* Limits: pattern-based; unusual credential formats or secrets split across messages can slip through. Extend
  `PATTERNS` and add a test in `ops/gateway/guardrails/tests/` (CI runs them). The gateway log line
  `[secrets-guardrail] ... user=... found=...` is the audit trail on the server side.

What the model can "read": nothing by itself. It has no tools, no file or network access; it only sees the prompt
that a client sends (chat text, attached images, the diff the review agent posts). Governance is therefore about
what people and agents put into prompts, which is what the guardrail and the traces cover.

## Privacy and retention: decide, then write it down here

* Langfuse stores **full prompts and responses**. Everyone using the assistant must know this. It stays on the
  office server; access is by Langfuse login (admin creates accounts, project "coder").
* To keep accounting but stop content logging: remove `success_callback`/`failure_callback` from
  `ops/gateway/config.yaml` and restart the gateway; token/latency metrics keep working.
* Redaction option: LiteLLM `litellm_settings: turn_off_message_logging: true` keeps traces with metadata only.
* Retention: Langfuse project settings -> Data retention (days). Suggested: 90 days for content, metrics 30 days
  (Prometheus). Backups contain the Langfuse database: same rule applies to backup archives.
* Do not paste secrets into prompts; the review agent's diff also travels through the gateway and into traces.

## Operate

```bash
cd ~/ops/gateway  && sudo docker compose -f compose.yml ps ; sudo docker compose -f compose.yml logs -f litellm
cd ~/ops/langfuse && sudo docker compose -f compose.yml ps ; sudo docker compose -f compose.yml logs -f langfuse-web
ssh -L 4000:127.0.0.1:4000 ubuntu@<VM_IP>   # then http://localhost:4000/ui  (admin, password in /etc/litellm/litellm.env)
```
Both stacks restart with Docker; state is in named volumes, included in the nightly backup. Bypass for emergencies:
the vLLM ports still accept the raw `VLLM_API_KEY` directly (no accounting).

## Resource footprint (measured on the VM)

Gateway + Postgres ~0.5 GB RAM; Langfuse (web, worker, Postgres, ClickHouse, Redis, MinIO) ~2.5 GB RAM, ~3 GB of
images; ~50 ms added latency per request through the gateway.
