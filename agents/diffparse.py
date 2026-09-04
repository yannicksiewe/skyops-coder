"""Minimal unified-diff parser: files -> hunks -> lines with new-file line numbers."""
import re
SKIP = re.compile(r"(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|uv\.lock|Cargo\.lock|go\.sum)$|\.(min\.js|min\.css|svg|png|jpg|jpeg|gif|pdf|ico|woff2?|rom|bin)$")

def parse(diff_text):
    """Return [{path, lines:[(new_lineno|None, kind, text)], added:int, deleted:int, binary:bool}]"""
    files, cur, new_no = [], None, 0
    for raw in diff_text.splitlines():
        if raw.startswith("diff --git"):
            m = re.match(r'diff --git a/(.*?) b/(.*)$', raw)
            cur = {"path": m.group(2) if m else raw, "lines": [], "added": 0, "deleted": 0, "binary": False}
            files.append(cur); continue
        if cur is None: continue
        if raw.startswith("Binary files"): cur["binary"] = True; continue
        if raw.startswith(("---", "+++", "index ", "new file", "deleted file", "similarity", "rename ", "old mode", "new mode")): continue
        if raw.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", raw); new_no = int(m.group(1)) if m else 0
            cur["lines"].append((None, "hunk", raw)); continue
        if raw.startswith("+"): cur["lines"].append((new_no, "add", raw[1:])); cur["added"] += 1; new_no += 1
        elif raw.startswith("-"): cur["lines"].append((None, "del", raw[1:])); cur["deleted"] += 1
        elif raw.startswith("\\"): continue
        else: cur["lines"].append((new_no, "ctx", raw[1:] if raw.startswith(" ") else raw)); new_no += 1
    return files

def reviewable(f, max_changes=600):
    return not f["binary"] and not SKIP.search(f["path"]) and (f["added"] + f["deleted"]) <= max_changes

def render(f):
    """Annotated text for the model: new-file line numbers on added/context lines, '-' on deletions."""
    out = []
    for no, kind, text in f["lines"]:
        if kind == "hunk": out.append(text)
        elif kind == "add": out.append(f"{no:>5} + {text}")
        elif kind == "del": out.append(f"      - {text}")
        else: out.append(f"{no:>5}   {text}")
    return "\n".join(out)

def added_lines(f):
    return {no for no, kind, _ in f["lines"] if kind == "add"}
