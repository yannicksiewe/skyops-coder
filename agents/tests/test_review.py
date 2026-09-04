import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import diffparse, review
from common import LLM

DIFF = """diff --git a/app.py b/app.py
index 1..2 100644
--- a/app.py
+++ b/app.py
@@ -1,4 +1,6 @@
 import os
-def run(cmd):
-    return os.system(cmd)
+import subprocess
+def run(cmd):
+    return subprocess.run(cmd, shell=True)
+PASSWORD = "hunter2"
diff --git a/package-lock.json b/package-lock.json
--- a/package-lock.json
+++ b/package-lock.json
@@ -1 +1 @@
-x
+y
"""

def test_parse_and_render():
    files = diffparse.parse(DIFF)
    assert [f["path"] for f in files] == ["app.py", "package-lock.json"]
    f = files[0]; assert f["added"] == 4 and f["deleted"] == 2
    assert diffparse.added_lines(f) == {2, 3, 4, 5}
    assert "    5 + PASSWORD" in diffparse.render(f)
    assert diffparse.reviewable(f) and not diffparse.reviewable(files[1])

class FakeLLM(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers["content-length"]); body = json.loads(self.rfile.read(n))
        assert body["response_format"]["type"] == "json_schema"
        out = {"summary": "shell=True and a hardcoded secret", "findings": [
            {"line": 4, "severity": "high", "title": "Shell injection", "comment": "shell=True with user input"},
            {"line": 5, "severity": "high", "title": "Hardcoded secret", "comment": "move to env"},
            {"line": 999, "severity": "low", "title": "off-diff", "comment": "not in diff"}]}
        resp = json.dumps({"choices": [{"message": {"content": "<think>hmm</think>" + json.dumps(out)}}]}).encode()
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(resp)
    def log_message(self, *a): pass

def test_analyze_and_compose():
    srv = HTTPServer(("127.0.0.1", 0), FakeLLM); threading.Thread(target=srv.serve_forever, daemon=True).start()
    llm = LLM(base_url=f"http://127.0.0.1:{srv.server_port}/v1", api_key="x", model="fake")
    result = review.analyze(DIFF, llm); srv.shutdown()
    assert result["skipped"] == ["package-lock.json"] and len(result["files"]) == 1
    f = result["files"][0]; assert [x["inline"] for x in f["findings"]] == [True, True, False]
    body, comments = review.compose(result, "abc123", "fake")
    assert len(comments) == 2 and comments[0]["line"] == 4 and comments[0]["side"] == "RIGHT"
    assert "ai-review:abc123" in body and "`app.py:999`" in body  # off-diff finding lands in the summary

def test_github_comment_verifies_after_dropped_connection():
    """POST drops the connection, but the comment exists on the next GET -> treated as success."""
    import common
    state = {"posted": False}
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers["content-length"]); body = json.loads(self.rfile.read(n))
            state["posted"] = True; state["body"] = body["body"]
            self.connection.close()  # drop without a response
        def do_GET(self):
            out = json.dumps([{"body": state.get("body", "")}]).encode()
            self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(out)
        def log_message(self, *a): pass
    srv = HTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
    gh = common.GitHub(repo="o/r", token="t")
    gh._req.__func__  # noqa - ensure attribute exists
    common.time.sleep = lambda s: None  # no waiting in tests
    orig = urllib_base = f"http://127.0.0.1:{srv.server_port}"
    import urllib.request
    real_Request = urllib.request.Request
    def patched(url, *a, **k): return real_Request(url.replace("https://api.github.com", urllib_base), *a, **k)
    common.urllib.request.Request = patched
    try:
        assert gh.comment(1, "hello")["body"] == "hello" and state["posted"]
    finally:
        common.urllib.request.Request = real_Request; srv.shutdown()
