#!/usr/bin/env python3
"""Apply settings to Open WebUI's persisted config (its DB wins over env vars after the first start).
Run inside the container:  python3 webui_config.py '<json>'   then restart the container."""
import json, sqlite3, sys, time
wanted = json.loads(sys.argv[1])
db = sqlite3.connect("/app/backend/data/webui.db")
for key, value in wanted.items():
    db.execute("insert into config (key, value, updated_at) values (?, ?, ?) "
               "on conflict(key) do update set value=excluded.value, updated_at=excluded.updated_at",
               (key, json.dumps(value), time.time()))
db.commit()
for key, in db.execute("select key from config where key in (%s)" % ",".join("?"*len(wanted)), list(wanted)):
    print("set", key)
