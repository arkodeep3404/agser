#!/usr/bin/env bash
# Guard: the three config files must register the SAME graph set.
# (aegra.json = local, aegra.aws.json = AWS, langgraph.json = official parity build)
# A graph missing from one silently breaks that target — this caught a real
# omission where `workflow` was absent from langgraph.json and 35 parity
# checks failed with "Invalid assistant".
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json, sys

def graphs(path):
    cfg = json.load(open(path))
    return set(cfg.get("graphs", {}))

local = graphs("aegra.json")
aws = graphs("aegra.aws.json")
official = graphs("langgraph.json")

ok = True
for name, a, b in (("local vs aws", local, aws), ("local vs official", local, official)):
    if a != b:
        ok = False
        print(f"MISMATCH {name}: only-in-first={sorted(a - b)} only-in-second={sorted(b - a)}")

if ok:
    print(f"config sync OK — {len(local)} graphs registered in all three: {sorted(local)}")
sys.exit(0 if ok else 1)
PY
