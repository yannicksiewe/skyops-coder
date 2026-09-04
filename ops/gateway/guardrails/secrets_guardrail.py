"""Secrets guardrail for the LiteLLM gateway.

Runs BEFORE the request reaches the model: finds credentials in the prompt (API keys, tokens, private keys,
passwords in `key: value` form, credentials in URLs, high-entropy strings next to secret-like words) and either
REDACTS them (default) or BLOCKS the request. Because it runs pre-call, the model never sees the secret and
Langfuse only stores the redacted text. Detections are attached to the request metadata as tags
(`secrets-redacted`, `secret:<type>`) so they show up per trace and per user.

Config (ops/gateway/config.yaml):
  guardrails:
    - guardrail_name: secrets
      litellm_params: { guardrail: secrets_guardrail.SecretsGuardrail, mode: pre_call, default_on: true }
Env: SECRETS_GUARDRAIL_MODE=redact|block   (default redact)
The detection function is pure Python and unit-tested (tests/test_secrets_guardrail.py).
"""
import math, os, re

PATTERNS = [  # (type, regex)  order matters: specific before generic
    ("private_key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]{0,4000}", re.S)),
    ("aws_access_key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("github_token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{60,}\b")),
    ("slack_token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}\b")),
    ("google_api_key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("openai_style_key", re.compile(r"\bsk-(?:proj-|ant-|lf-|skyops-|master-)?[A-Za-z0-9_-]{16,}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    ("url_credentials", re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s/:@]+:([^\s/@]{3,})@")),
    ("password_assignment", re.compile(r"(?i)\b(pass(?:word|wd|phrase)?|pwd|secret(?:_key)?|api[_-]?key|access[_-]?token|auth[_-]?token|token|client[_-]?secret|private[_-]?key)\b\s*[:=]\s*[\"']?([^\s\"',;]{6,})")),
]
ENTROPY_CONTEXT = re.compile(r"(?i)(key|secret|token|password|passwd|credential|auth)[^\n]{0,40}?([A-Za-z0-9+/=_-]{32,})")
ALLOWLIST = re.compile(r"(?i)^(\$\{?[A-Z_]+\}?|<[^>]+>|\*{3,}|x{6,}|your[-_ ]?[a-z_]+|changeme|example|placeholder|redacted|none|null|true|false|os\.environ.*|\[REDACTED[^\]]*\])$")

def _entropy(s):
    if not s: return 0.0
    freq = {c: s.count(c) for c in set(s)}
    return -sum(n / len(s) * math.log2(n / len(s)) for n in freq.values())

def redact(text):
    """Return (redacted_text, {type: count})."""
    if not text or not isinstance(text, str): return text, {}
    found = {}
    def sub(kind, m, group=0):
        val = m.group(group)
        if ALLOWLIST.match(val.strip()) or "[REDACTED" in m.group(0): return m.group(0)   # already handled by an earlier pattern
        found[kind] = found.get(kind, 0) + 1
        return m.group(0).replace(val, f"[REDACTED_{kind.upper()}]")
    for kind, rx in PATTERNS:
        grp = 2 if kind == "password_assignment" else 1 if kind == "url_credentials" else 0
        text = rx.sub(lambda m, k=kind, g=grp: sub(k, m, g), text)
    def ent(m):
        val = m.group(2)
        if ALLOWLIST.match(val) or "[REDACTED" in m.group(0) or _entropy(val) < 3.8: return m.group(0)
        found["high_entropy_secret"] = found.get("high_entropy_secret", 0) + 1
        return m.group(0).replace(val, "[REDACTED_HIGH_ENTROPY_SECRET]")
    text = ENTROPY_CONTEXT.sub(ent, text)
    return text, found

def redact_messages(messages):
    """Redact every text part of every message in place-safe copy; return (messages, {type: count})."""
    total, out = {}, []
    for m in messages or []:
        m = dict(m); c = m.get("content")
        if isinstance(c, str):
            m["content"], f = redact(c)
        elif isinstance(c, list):
            parts = []
            for p in c:
                if isinstance(p, dict) and p.get("type") == "text":
                    t, f = redact(p.get("text", "")); parts.append({**p, "text": t})
                else:
                    parts.append(p); f = {}
                for k, v in f.items(): total[k] = total.get(k, 0) + v
            m["content"], f = parts, {}
        else:
            f = {}
        for k, v in f.items(): total[k] = total.get(k, 0) + v
        out.append(m)
    return out, total

try:  # Prometheus counter, served on the gateway's /metrics next to LiteLLM's own metrics
    from prometheus_client import Counter
    SECRETS_COUNTER = Counter("skyops_secrets_detected_total", "Secrets found in prompts by the gateway guardrail",
                              ["type", "user", "mode", "key_alias"])
except Exception:  # pragma: no cover
    SECRETS_COUNTER = None

try:  # LiteLLM integration (not needed for the unit tests)
    from litellm.integrations.custom_guardrail import CustomGuardrail
    from fastapi import HTTPException

    class SecretsGuardrail(CustomGuardrail):
        async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
            mode = os.environ.get("SECRETS_GUARDRAIL_MODE", "redact").lower()
            found = {}
            if "messages" in data:
                data["messages"], found = redact_messages(data["messages"])
            elif isinstance(data.get("prompt"), str):
                data["prompt"], found = redact(data["prompt"])
            if found:
                md = data.setdefault("metadata", {}) or {}
                user = data.get("user") or md.get("user_api_key_end_user_id") or getattr(user_api_key_dict, "end_user_id", None) or "unknown"
                alias = getattr(user_api_key_dict, "key_alias", None) or "unknown"
                if SECRETS_COUNTER is not None:
                    for k, n in found.items(): SECRETS_COUNTER.labels(type=k, user=str(user), mode=mode, key_alias=str(alias)).inc(n)
                tags = list(md.get("tags") or []) + ["secrets-redacted"] + [f"secret:{k}" for k in found]
                md["tags"] = tags; md["secrets_detected"] = found; data["metadata"] = md
                print(f"[secrets-guardrail] mode={mode} user={user} key={alias} found={found}", flush=True)
                if mode == "block":
                    raise HTTPException(status_code=400, detail={"error": "Request blocked: it contains what looks like a secret "
                                        f"({', '.join(found)}). Remove credentials from the prompt and retry."})
            return data
except ImportError:  # pragma: no cover
    pass
