#!/usr/bin/env python3
"""Small, honest coding benchmark for local models: 8 Python tasks with hidden tests, pass@1 + speed.
  python3 research/bench.py --base http://127.0.0.1:8000/v1 --model coder-chat [--no-think] [--runs 1]
Outputs one JSON line per run to research/results.jsonl and a summary table."""
import argparse, json, os, re, subprocess, sys, tempfile, time, urllib.request

TASKS = [
 ("lru_cache", "Write a Python class LRUCache(capacity) with get(key)->value or -1 and put(key, value); both O(1). Evicts least-recently-used on overflow.",
  "c=LRUCache(2); c.put(1,1); c.put(2,2); assert c.get(1)==1; c.put(3,3); assert c.get(2)==-1; c.put(4,4); assert c.get(1)==-1; assert c.get(3)==3; assert c.get(4)==4"),
 ("parse_duration", "Write parse_duration(s: str) -> int returning total seconds for strings like '1h30m', '45s', '2h', '90m10s'. Raise ValueError on invalid input.",
  "assert parse_duration('1h30m')==5400; assert parse_duration('45s')==45; assert parse_duration('2h')==7200; assert parse_duration('90m10s')==5410\ntry:\n    parse_duration('abc'); raise AssertionError('no error')\nexcept ValueError: pass"),
 ("merge_intervals", "Write merge_intervals(intervals: list[list[int]]) -> list[list[int]] that merges overlapping intervals and returns them sorted.",
  "assert merge_intervals([[1,3],[2,6],[8,10],[15,18]])==[[1,6],[8,10],[15,18]]; assert merge_intervals([[1,4],[4,5]])==[[1,5]]; assert merge_intervals([])==[]"),
 ("topo_sort", "Write topo_sort(edges: list[tuple[str,str]]) -> list[str] returning a topological order of a DAG given (from,to) edges; raise ValueError on a cycle.",
  "o=topo_sort([('a','b'),('b','c'),('a','c')]); assert o.index('a')<o.index('b')<o.index('c')\ntry:\n    topo_sort([('a','b'),('b','a')]); raise AssertionError('no cycle error')\nexcept ValueError: pass"),
 ("csv_to_dicts", "Write csv_to_dicts(text: str) -> list[dict] parsing CSV text with a header row; handle quoted fields containing commas (use the csv module).",
  "r=csv_to_dicts('name,city\\nAda,\"London, UK\"\\nBob,Paris\\n'); assert r==[{'name':'Ada','city':'London, UK'},{'name':'Bob','city':'Paris'}]"),
 ("rate_limiter", "Write class RateLimiter(max_calls: int, period: float) with allow(now: float) -> bool implementing a sliding window: at most max_calls calls within any window of `period` seconds.",
  "r=RateLimiter(3,10.0); assert all(r.allow(t) for t in (0,1,2)); assert not r.allow(3); assert r.allow(10.5); assert not r.allow(10.6); assert r.allow(11.5)"),
 ("roman", "Write int_to_roman(n: int) -> str for 1<=n<=3999 and roman_to_int(s: str) -> int.",
  "assert int_to_roman(1994)=='MCMXCIV'; assert roman_to_int('MCMXCIV')==1994; assert int_to_roman(3999)=='MMMCMXCIX'; assert roman_to_int('IV')==4"),
 ("word_freq", "Write top_words(text: str, k: int) -> list[tuple[str,int]] returning the k most frequent lowercase words (letters only), ties broken alphabetically.",
  "assert top_words('The cat and the hat. The CAT!',2)==[('the',3),('cat',2)]; assert top_words('b a b a c',3)==[('a',2),('b',2),('c',1)]"),
]
SYSTEM = "You are an expert Python programmer. Reply with ONLY one Python code block containing the complete solution, no explanations, no tests."

def ask(base, key, model, task, no_think, max_tokens):
    body = {"model": model, "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": task}], "temperature": 0, "max_tokens": max_tokens}
    if no_think: body["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(f"{base}/chat/completions", data=json.dumps(body).encode(), headers={"Authorization": f"Bearer {key}", "content-type": "application/json"})
    t = time.time(); d = json.load(urllib.request.urlopen(req, timeout=900)); dt = time.time() - t
    msg = d["choices"][0]["message"]; text = msg.get("content") or ""
    return text, d["usage"]["completion_tokens"], dt

def extract(text):
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
    m = re.findall(r"```(?:python)?\n(.*?)```", text, flags=re.S)
    return m[-1] if m else text

def run_tests(code, test):
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(code + "\n\n" + test + "\nprint('OK')\n"); path = f.name
    try:
        r = subprocess.run([sys.executable, path], capture_output=True, text=True, timeout=20)
        return r.returncode == 0 and "OK" in r.stdout, (r.stderr.strip().splitlines() or [""])[-1][:120]
    except subprocess.TimeoutExpired: return False, "timeout"
    finally: os.unlink(path)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--base", default="http://127.0.0.1:8000/v1"); ap.add_argument("--model", default="coder-chat")
    ap.add_argument("--key", default=None); ap.add_argument("--no-think", action="store_true"); ap.add_argument("--max-tokens", type=int, default=1500); ap.add_argument("--label", default="")
    a = ap.parse_args()
    key = a.key or next((l.split("=",1)[1].strip() for l in open("/etc/vllm.env") if l.startswith("VLLM_API_KEY=")), "")
    rows, passed, toks, secs = [], 0, 0, 0.0
    for name, task, test in TASKS:
        text, n, dt = ask(a.base, key, a.model, task, a.no_think, a.max_tokens)
        ok, err = run_tests(extract(text), test); passed += ok; toks += n; secs += dt
        rows.append({"task": name, "pass": ok, "tokens": n, "seconds": round(dt, 1), "error": "" if ok else err})
        print(f"  {name:16s} {'PASS' if ok else 'FAIL':4s} {n:5d} tok {dt:6.1f}s  {'' if ok else err}", flush=True)
    summary = {"label": a.label or a.model, "model": a.model, "no_think": a.no_think, "pass": passed, "total": len(TASKS),
               "tok_per_s": round(toks / secs, 1) if secs else 0, "avg_seconds": round(secs / len(TASKS), 1), "tasks": rows, "ts": time.strftime("%Y-%m-%d %H:%M")}
    print(f"RESULT {summary['label']}: {passed}/{len(TASKS)} pass, {summary['tok_per_s']} tok/s, {summary['avg_seconds']} s/task")
    with open(os.path.join(os.path.dirname(__file__), "results.jsonl"), "a") as f: f.write(json.dumps(summary) + "\n")

if __name__ == "__main__": main()
