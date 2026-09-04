# ADR-005: An LLM gateway and a trace store for governance

**Status:** accepted (2026-09-04)

## Context
vLLM's metrics are per model, not per user. The team wants: number of simultaneous users, requests and tokens per
person, time to reply, and the ability to inspect request and response content and quality.

## Decision
* **LiteLLM proxy** as the single entry point (keys, teams, budgets in token units, rate limits, per-user
  accounting via the forwarded Open WebUI user header, Prometheus metrics, admin UI).
* **Langfuse v3 self-hosted** for traces with content, fed by the gateway's callback; scores for quality.
* All clients go through the gateway; raw vLLM ports remain for emergencies and are not exposed by name.
* A pre-call **secrets guardrail** in the gateway redacts (or blocks) credentials before the model and before tracing.

## Alternatives considered
* Only vLLM metrics + Open WebUI's DB: no per-user token view for API clients, no content search, no budgets.
* OpenTelemetry + Phoenix/OpenLIT: lighter than Langfuse, but no per-key budgets and weaker user management.
* Langfuse v2 (Postgres only): simpler, but end-of-life; v3 needs ClickHouse/Redis/MinIO (~2.5 GB RAM, acceptable).

## Consequences
* Prompts and responses are stored on the office server; documented in `docs/governance.md`, retention to be set.
* One more hop (~50 ms) and two more stacks to back up and update (`ops/backup` covers their volumes).
* Budget numbers are millions of tokens, not money; keep that convention or set real prices in `config.yaml`.
