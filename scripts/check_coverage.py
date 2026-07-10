#!/usr/bin/env python3
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
data = payload["data"][0]
overall = float(data["totals"]["lines"]["percent"])
if overall < 35.0:
    raise SystemExit(f"overall line coverage {overall:.2f}% is below 35%")

groups = {
    "display-safety": ("ProductPolicies.swift",),
    "clipboard-security": ("ClipboardSecurity.swift", "ProductPolicies.swift"),
    "finder-auth": ("FinderActionRequest.swift",),
    "config-recovery": ("ProductPolicies.swift",),
}
for name, suffixes in groups.items():
    summaries = [item["summary"]["lines"] for item in data["files"] if any(item["filename"].endswith(suffix) for suffix in suffixes)]
    count = sum(int(summary["count"]) for summary in summaries)
    covered = sum(int(summary["covered"]) for summary in summaries)
    percent = (covered / count * 100.0) if count else 0.0
    if percent < 80.0:
        raise SystemExit(f"{name} line coverage {percent:.2f}% is below 80%")
print(f"coverage accepted: overall {overall:.2f}%")
