"""Pick the UDID of the best available iPhone simulator for CI."""
import json
import subprocess
import sys

out = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"])
devs = json.loads(out)["devices"]
phones = [
    d for runtimes in devs.values() for d in runtimes
    if d.get("isAvailable") and "iPhone" in d.get("name", "")
]
if not phones:
    print("No available iPhone simulator found", file=sys.stderr)
    sys.exit(1)
phones.sort(key=lambda d: d["name"], reverse=True)
print(phones[0]["udid"])
