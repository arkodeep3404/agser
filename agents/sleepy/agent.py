"""Slow graph for auto-recovery verification — deployed as `sleepy`.

Two steps:
  1. `prep` — immediate side effect, checkpointed instantly.
  2. `long_work` — sleeps SLEEPY_SECS (default 45), then finishes.

Kill the server while `long_work` sleeps; the watchdog resubmits the run
and the engine resumes from the checkpoint. `prep`'s audit entry must still
appear exactly once in the final state — the proof of once-only step
execution across a crash + auto-recovery cycle.
"""

import os
import time
import uuid
from typing import Annotated, TypedDict

from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages


class State(TypedDict, total=False):
    messages: Annotated[list, add_messages]
    side_effects: Annotated[list, add_messages]


SLEEP_SECS = int(os.environ.get("SLEEPY_SECS", "45"))


def prep(state: State) -> dict:
    return {
        "messages": [{"role": "assistant", "content": "prep: starting long work"}],
        "side_effects": [{"role": "assistant", "content": f"prep:{uuid.uuid4()}"}],
    }


def long_work(state: State) -> dict:
    time.sleep(SLEEP_SECS)
    return {"messages": [{"role": "assistant", "content": f"long_work: finished after {SLEEP_SECS}s"}]}


builder = StateGraph(State)
builder.add_node("prep", prep)
builder.add_node("long_work", long_work)
builder.add_edge(START, "prep")
builder.add_edge("prep", "long_work")
builder.add_edge("long_work", END)

graph = builder.compile()
