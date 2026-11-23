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

base = graphs("aegra.json")
others = {
    "aegra.aws.json": graphs("aegra.aws.json"),
    "aegra.aws.emulator.json": graphs("aegra.aws.emulator.json"),
    "langgraph.json": graphs("langgraph.json"),
}
local = base
official = others["langgraph.json"]

ok = True
for name, a, b in [("local vs " + k, base, v) for k, v in others.items()]:
    if a != b:
        ok = False
        print(f"MISMATCH {name}: only-in-first={sorted(a - b)} only-in-second={sorted(b - a)}")

if ok:
    print(f"config sync OK — {len(local)} graphs registered in all four configs: {sorted(local)}")
sys.exit(0 if ok else 1)
PY
