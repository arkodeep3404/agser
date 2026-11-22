"""Human-in-the-loop approval graph — deployed as `approval`.

Demonstrates and verifies the interrupt/resume contract the Agent Server
provides for deep agents (deep agents use the same `interrupt()` primitive
for tool-call approval):

  1. `prep` performs a side effect recorded in thread state (runs ONCE —
     checkpointed before the interrupt).
  2. `gate` calls `interrupt()` — the run pauses, thread status becomes
     `interrupted`, and a human resumes it later with a Command:
       POST /threads/{id}/runs/wait
         {"assistant_id": "approval", "command": {"resume": {"approved": true}}}
  3. `finish` completes the graph with the human's decision.

Because `prep` is checkpointed before the interrupt, resuming (even several
times, even after a server crash) never re-executes it.
"""

import uuid
from typing import Annotated, TypedDict

from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.types import interrupt


class State(TypedDict, total=False):
    messages: Annotated[list, add_messages]
    # Side-effect audit trail: one entry per execution of `prep`.
    side_effects: Annotated[list, add_messages]


def _content(msg) -> str:
    if isinstance(msg, dict):
        return msg.get("content", "")
    return getattr(msg, "content", "")


def prep(state: State) -> dict:
    """Side-effectful step. Its execution count is visible in the final state."""
    return {
        "messages": [{"role": "assistant", "content": "prep: side effect done"}],
        "side_effects": [{"role": "assistant", "content": f"prep:{uuid.uuid4()}"}],
    }


def gate(state: State) -> dict:
    """Pause for a human decision. Resumes with the Command above."""
    answer = interrupt(
        {"question": "Approve the plan?", "context": _content(state["messages"][-1])}
    )
    approved = bool(answer.get("approved"))
    return {"messages": [{"role": "assistant", "content": f"gate: human approved={approved}"}]}


def finish(state: State) -> dict:
    return {"messages": [{"role": "assistant", "content": "finish: done"}]}


builder = StateGraph(State)
builder.add_node("prep", prep)
builder.add_node("gate", gate)
builder.add_node("finish", finish)
builder.add_edge(START, "prep")
builder.add_edge("prep", "gate")
builder.add_edge("gate", "finish")
builder.add_edge("finish", END)

graph = builder.compile()
