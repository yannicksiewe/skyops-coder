#!/usr/bin/env python3
"""AI code review for a pull request using the local model. Posts one PR review with inline comments.

  python3 agents/review.py <pr-number>            # needs GITHUB_TOKEN, GITHUB_REPOSITORY
  python3 agents/review.py --diff file.diff        # offline: print findings as JSON (no GitHub)
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import LLM, GitHub
import diffparse

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = {"type": "object", "properties": {
    "summary": {"type": "string"},
    "findings": {"type": "array", "items": {"type": "object", "properties": {
        "line": {"type": "integer"}, "severity": {"type": "string", "enum": ["high", "medium", "low"]},
        "title": {"type": "string"}, "comment": {"type": "string"}},
        "required": ["line", "severity", "title", "comment"]}}},
    "required": ["summary", "findings"]}
MARK = "<!-- ai-review:{sha} -->"
MAX_FILES, MAX_FINDINGS_PER_FILE = 25, 6

def review_file(llm, f):
    system = open(os.path.join(HERE, "prompts", "review_system.md")).read()
    user = f"File: {f['path']}\n\nDiff (new-file line numbers on the left):\n```\n{diffparse.render(f)}\n```"
    try:
        out = llm.chat_json([{"role": "system", "content": system}, {"role": "user", "content": user}], SCHEMA, max_tokens=1200)
    except Exception as e:  # model hiccup: skip the file rather than fail the review
        return {"summary": f"(review skipped: {e.__class__.__name__})", "findings": []}
    ok = diffparse.added_lines(f) | {no for no, kind, _ in f["lines"] if kind == "ctx"}
    findings = []
    for x in out.get("findings", [])[:MAX_FINDINGS_PER_FILE]:
        try: line = int(x["line"])
        except (KeyError, ValueError, TypeError): continue
        findings.append({"path": f["path"], "line": line, "inline": line in ok,
                         "severity": x.get("severity", "low"), "title": x.get("title", "").strip(), "comment": x.get("comment", "").strip()})
    return {"summary": out.get("summary", "").strip(), "findings": findings}

def analyze(diff_text, llm):
    files = diffparse.parse(diff_text)
    results, skipped = [], []
    for f in files:
        if not diffparse.reviewable(f): skipped.append(f["path"]); continue
        if len(results) >= MAX_FILES: skipped.append(f["path"]); continue
        r = review_file(llm, f); r["path"] = f["path"]; results.append(r)
    return {"files": results, "skipped": skipped}

def compose(result, sha, model):
    sev = {"high": "🔴", "medium": "🟠", "low": "🟡"}
    comments, lines = [], []
    n_find = sum(len(r["findings"]) for r in result["files"])
    lines.append(f"### AI code review ({model})\n")
    lines.append(f"{len(result['files'])} file(s) reviewed, {n_find} finding(s)." + (f" Skipped: {', '.join(result['skipped'])}." if result["skipped"] else ""))
    for r in result["files"]:
        if r["summary"] or r["findings"]:
            lines.append(f"\n**`{r['path']}`** — {r['summary']}")
        for x in r["findings"]:
            body = f"{sev.get(x['severity'],'')} **{x['title']}** ({x['severity']})\n\n{x['comment']}"
            if x["inline"]:
                comments.append({"path": x["path"], "line": x["line"], "side": "RIGHT", "body": body})
            else:
                lines.append(f"- {sev.get(x['severity'],'')} `{x['path']}:{x['line']}` **{x['title']}** ({x['severity']}): {x['comment']}")
    lines.append(f"\n<sub>Local model, no data left the office. Findings are suggestions; a human decides.</sub>\n{MARK.format(sha=sha)}")
    return "\n".join(lines), comments

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("pr", nargs="?", type=int); ap.add_argument("--diff"); ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(); llm = LLM()
    if a.diff:
        print(json.dumps(analyze(open(a.diff).read(), llm), indent=2)); return
    gh = GitHub(); pr = gh.pr(a.pr); sha = pr["head"]["sha"]
    if any(MARK.format(sha=sha) in (rv.get("body") or "") for rv in gh.pr_reviews(a.pr)):
        print("already reviewed this commit"); return
    result = analyze(gh.pr_diff(a.pr), llm)
    body, comments = compose(result, sha, llm.model)
    if a.dry_run: print(body); print(json.dumps(comments, indent=2)); return
    try:
        gh.post_review(a.pr, body, comments, sha)
    except RuntimeError as e:  # e.g. a line outside the diff: retry without inline comments
        print("inline review rejected, posting summary only:", e); gh.post_review(a.pr, body, [], sha)
    print(f"posted review with {len(comments)} inline comment(s)")

if __name__ == "__main__": main()
