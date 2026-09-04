import json, sys
ts = json.load(sys.stdin)["data"]["activeTargets"]
for t in sorted(ts, key=lambda t: (t["labels"]["job"], t["labels"].get("service", ""))):
    print(f'  {t["labels"]["job"]:11s} {t["labels"].get("service", ""):13s} {t["health"]:5s} {t.get("lastError", "")[:60]}')
