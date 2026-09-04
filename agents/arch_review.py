#!/usr/bin/env python3
"""Architecture review of a PR: repository map + change -> Markdown report posted as a PR comment.
  python3 agents/arch_review.py <pr-number>   (GITHUB_TOKEN, GITHUB_REPOSITORY)"""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import LLM, GitHub
import diffparse
HERE = os.path.dirname(os.path.abspath(__file__))
KEY_DOCS = ["README.md", "docs/architecture.md", "docs/plan/ROADMAP.md"]

def repo_map(gh, ref, max_entries=400):
    tree = [t["path"] for t in gh.tree(ref) if t["type"] == "blob"]
    docs = []
    for p in KEY_DOCS:
        try: docs.append(f"--- {p} ---\n" + gh.file(p, ref)[:6000])
        except Exception: pass
    try:
        adrs = [p for p in tree if p.startswith("docs/adr/")]
        for p in adrs[:6]: docs.append(f"--- {p} ---\n" + gh.file(p, ref)[:2500])
    except Exception: pass
    return "\n".join(tree[:max_entries]), "\n\n".join(docs)

def build_prompt(tree, docs, pr, files):
    changed = "\n".join(f"- {f['path']} (+{f['added']}/-{f['deleted']})" for f in files)
    excerpt = "\n\n".join(f"### {f['path']}\n```\n{diffparse.render(f)[:3000]}\n```" for f in files if diffparse.reviewable(f))[:14000]
    return (f"# Repository map\n```\n{tree}\n```\n\n# Key documents\n{docs}\n\n# Change under review\n"
            f"PR #{pr['number']}: {pr['title']}\n\n{(pr.get('body') or '')[:2000]}\n\nFiles:\n{changed}\n\n# Diff excerpts\n{excerpt}")

def main():
    n = int(sys.argv[1]); gh = GitHub(); llm = LLM()
    pr = gh.pr(n); files = diffparse.parse(gh.pr_diff(n))
    tree, docs = repo_map(gh, pr["base"]["sha"])
    system = open(os.path.join(HERE, "prompts", "arch_system.md")).read()
    report = llm.chat([{"role": "system", "content": system}, {"role": "user", "content": build_prompt(tree, docs, pr, files)}], max_tokens=1200, temperature=0.2)
    gh.comment(n, f"### Architecture review ({llm.model})\n\n{report.strip()}\n\n<sub>Generated on the office server; a human decides.</sub>")
    print("posted architecture review")

if __name__ == "__main__": main()
