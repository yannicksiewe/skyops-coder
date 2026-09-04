"""Shared helpers for the agents: local-LLM client (OpenAI-compatible), GitHub REST client, config."""
import http.client, json, os, re, time, urllib.request, urllib.error

def _env_file(path="/etc/vllm.env"):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                if "=" in line and not line.startswith("#"):
                    k, v = line.rstrip("\n").split("=", 1); out[k] = v
    except OSError:
        pass
    return out

def llm_config():
    env = _env_file()
    return {
        "base_url": os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8000/v1").rstrip("/"),
        "api_key": os.environ.get("LLM_API_KEY") or env.get("VLLM_API_KEY", ""),
        "model": os.environ.get("LLM_MODEL", "coder-chat"),
    }

class LLM:
    def __init__(self, base_url=None, api_key=None, model=None, timeout=600):
        cfg = llm_config()
        self.base_url = base_url or cfg["base_url"]; self.api_key = api_key or cfg["api_key"]
        self.model = model or cfg["model"]; self.timeout = timeout

    def chat(self, messages, max_tokens=1500, temperature=0.1, json_schema=None):
        body = {"model": self.model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature}
        if json_schema:
            body["response_format"] = {"type": "json_schema", "json_schema": {"name": "out", "schema": json_schema}}
        req = urllib.request.Request(f"{self.base_url}/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Authorization": f"Bearer {self.api_key}", "content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            d = json.load(r)
        return d["choices"][0]["message"]["content"]

    def chat_json(self, messages, schema, **kw):
        text = self.chat(messages, json_schema=schema, **kw)
        text = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
        m = re.search(r"\{.*\}", text, flags=re.S)
        return json.loads(m.group(0) if m else text)

class GitHubTransport(Exception):
    """Connection dropped; a write may or may not have been applied."""

class GitHub:
    def __init__(self, repo=None, token=None):
        self.repo = repo or os.environ["GITHUB_REPOSITORY"]
        self.token = token or os.environ.get("GH_TOKEN") or os.environ["GITHUB_TOKEN"]

    def _req(self, method, path, data=None, accept="application/vnd.github+json"):
        req = urllib.request.Request(f"https://api.github.com{path}", method=method,
                                     data=json.dumps(data).encode() if data is not None else None,
                                     headers={"Authorization": f"Bearer {self.token}", "Accept": accept,
                                              "X-GitHub-Api-Version": "2022-11-28", "content-type": "application/json"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    raw = r.read()
                    return json.loads(raw) if accept.endswith("json") and raw else raw.decode()
            except urllib.error.HTTPError as e:
                if e.code in (502, 503) and attempt < 2: time.sleep(2); continue
                raise RuntimeError(f"GitHub {method} {path} -> {e.code}: {e.read()[:300]}") from None
            except (http.client.RemoteDisconnected, ConnectionResetError, urllib.error.URLError) as e:
                # GitHub sometimes closes the connection after accepting a write; retry reads, verify writes
                if method == "GET" and attempt < 2: time.sleep(2); continue
                raise GitHubTransport(f"GitHub {method} {path}: {e}") from None

    def pr(self, n): return self._req("GET", f"/repos/{self.repo}/pulls/{n}")
    def pr_diff(self, n): return self._req("GET", f"/repos/{self.repo}/pulls/{n}", accept="application/vnd.github.diff")
    def pr_reviews(self, n): return self._req("GET", f"/repos/{self.repo}/pulls/{n}/reviews")
    def post_review(self, n, body, comments, commit_id):
        try:
            return self._req("POST", f"/repos/{self.repo}/pulls/{n}/reviews",
                             {"body": body, "event": "COMMENT", "commit_id": commit_id, "comments": comments})
        except GitHubTransport:
            time.sleep(3)
            for rv in self.pr_reviews(n):
                if (rv.get("body") or "") == body: return rv
            raise
    def comments(self, n): return self._req("GET", f"/repos/{self.repo}/issues/{n}/comments?per_page=100")
    def comment(self, n, body):
        try:
            return self._req("POST", f"/repos/{self.repo}/issues/{n}/comments", {"body": body})
        except GitHubTransport:
            time.sleep(3)  # verify whether the write landed before giving up
            for c in self.comments(n):
                if (c.get("body") or "") == body: return c
            raise
    def issue(self, n): return self._req("GET", f"/repos/{self.repo}/issues/{n}")
    def tree(self, ref):
        return self._req("GET", f"/repos/{self.repo}/git/trees/{ref}?recursive=1").get("tree", [])
    def file(self, path, ref):
        d = self._req("GET", f"/repos/{self.repo}/contents/{path}?ref={ref}")
        import base64; return base64.b64decode(d["content"]).decode(errors="replace")
