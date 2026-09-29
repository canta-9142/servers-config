#!/usr/bin/env python3
"""Read-only acceptance check for the Ryzen release and public website."""
import argparse
import hashlib
import json
import re
import shlex
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("release", help="Expected full Git commit SHA")
parser.add_argument("sha256", help="Expected SHA-256 of index.html")
args = parser.parse_args()


def run(*command):
    return subprocess.check_output(command, timeout=30)


snapshot = run(
    "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "ryzen.home.arpa",
    "sh -c " + shlex.quote("set -eu; "
    "readlink /srv/www/floating-gate/current; "
    "sha256sum /srv/www/floating-gate/current/index.html; "
    "curl -fsS -w '%{http_code}\\n' -H 'Host: floating-gate.com' http://127.0.0.1:8080/healthz; "
    "curl -fsS -H 'Host: floating-gate.com' http://127.0.0.1:8080/ | sha256sum"),
).decode().splitlines()
assert snapshot[0] == f"releases/{args.release}", snapshot
assert snapshot[1].split()[0] == args.sha256, snapshot
assert snapshot[2] == "ok", snapshot
assert snapshot[3] == "200", snapshot
assert snapshot[4].split()[0] == args.sha256, snapshot

nonce = time.time_ns()
public = run("curl", "-fsS", "-w", "%{http_code}", "--max-time", "20", "-H", "Cache-Control: no-cache",
             f"https://floating-gate.com/?release-test={nonce}")
health = run("curl", "-fsS", "-w", "%{http_code}", "--max-time", "20", "-H", "Cache-Control: no-cache",
             f"https://floating-gate.com/healthz?release-test={nonce}")
assert public[-3:] == health[-3:] == b"200", "Public HTTP status is not 200"
public, health = public[:-3], health[:-3]
# Cloudflare injects a per-request hidden link and JS challenge into HTML.
# Ignore only those known additions; compare all remaining bytes to the origin.
public = re.sub(
    rb'<a href="https://floating-gate.com/cdn-cgi/content\?[^\"]*" '
    rb'aria-hidden="true"[^>]*></a>', b"", public,
)
public = re.sub(
    rb"<script>.*?</script>",
    lambda m: b"" if b"window.__CF$cv$params" in m[0]
    and b"/cdn-cgi/challenge-platform/" in m[0] else m[0],
    public, flags=re.DOTALL,
)
assert hashlib.sha256(public).hexdigest() == args.sha256, "Public HTML changed"
assert health.strip() == b"ok", health
print(json.dumps({"release": args.release, "sha256": args.sha256,
                  "origin": "ok", "public": "ok"}))
