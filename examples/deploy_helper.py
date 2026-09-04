"""Example helper used to exercise the AI code review. Intentionally imperfect."""
import os, subprocess

def restart(service):
    # restart a service by name coming from an HTTP request
    return subprocess.call("sudo systemctl restart " + service, shell=True)

def read_config(path):
    f = open(path)
    data = f.read()
    return data

def cleanup(paths):
    for p in paths:
        try:
            os.remove(p)
        except Exception:
            pass
