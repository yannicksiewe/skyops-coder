#!/usr/bin/env python3
"""MCP server that gives Claude Code (or any MCP client) tools backed by the office models through the gateway.

Tools: local_ask (chat model), local_review (code review of a diff), local_describe_image (vision model),
local_models (what is available). Runs over stdio; configured in .mcp.json at the repo root.
Env: SKYOPS_API_BASE (default https://api.skyops.lan/v1), SKYOPS_API_KEY (gateway key), SKYOPS_CA (CA cert path).
Run:  uv run --with mcp clients/mcp/skyops_mcp.py
"""
import base64, json, os, ssl, urllib.request
try:  # mcp >= 2
    from mcp.server.mcpserver import MCPServer as FastMCP
except ImportError:  # mcp 1.x
    from mcp.server.fastmcp import FastMCP

BASE = os.environ.get("SKYOPS_API_BASE", "https://api.skyops.lan/v1").rstrip("/")
KEY = os.environ.get("SKYOPS_API_KEY", "")
CA = os.environ.get("SKYOPS_CA")
CTX = ssl.create_default_context(cafile=CA) if CA else None
mcp = FastMCP("skyops-local-models")

def _chat(model, messages, max_tokens=1200, temperature=0.2):
    req = urllib.request.Request(f"{BASE}/chat/completions", data=json.dumps({"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature}).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=600, context=CTX) as r:
        d = json.load(r)
    return d["choices"][0]["message"]["content"], d.get("usage", {})

@mcp.tool()
def local_ask(prompt: str, system: str = "You are a concise senior software engineer.", max_tokens: int = 1200) -> str:
    """Ask the office-hosted coder model (Qwen2.5-Coder-7B). Data stays on the office server. Good for bulk or private text."""
    text, usage = _chat("coder-chat", [{"role": "system", "content": system}, {"role": "user", "content": prompt}], max_tokens)
    return f"{text}\n\n[coder-chat, {usage.get('prompt_tokens')}+{usage.get('completion_tokens')} tokens]"

@mcp.tool()
def local_review(diff: str, focus: str = "bugs, security, error handling, missing tests") -> str:
    """Review a unified diff with the office coder model and return findings (severity, file:line, comment)."""
    system = ("You are a senior engineer doing code review. Report only real problems: " + focus +
              ". Format: one finding per line as '<severity> <file>:<line> - <comment>'. If nothing is wrong, say 'No findings.'")
    text, _ = _chat("coder-chat", [{"role": "system", "content": system}, {"role": "user", "content": f"```diff\n{diff[:40000]}\n```"}], 1500, 0.1)
    return text

@mcp.tool()
def local_describe_image(path: str, question: str = "Describe this image precisely. If it shows an error, quote it.") -> str:
    """Describe or read a local image file (screenshot, diagram) with the office vision model (Qwen2.5-VL-3B)."""
    ext = os.path.splitext(path)[1].lower().lstrip(".") or "png"; mime = {"jpg": "jpeg"}.get(ext, ext)
    with open(os.path.expanduser(path), "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    text, _ = _chat("coder-vision", [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": f"data:image/{mime};base64,{b64}"}}, {"type": "text", "text": question}]}], 600, 0.1)
    return text

@mcp.tool()
def local_models() -> str:
    """List the models available on the office gateway."""
    req = urllib.request.Request(f"{BASE}/models", headers={"Authorization": f"Bearer {KEY}"})
    with urllib.request.urlopen(req, timeout=30, context=CTX) as r:
        return ", ".join(m["id"] for m in json.load(r)["data"])

if __name__ == "__main__":
    mcp.run()
