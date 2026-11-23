"""Multi-gate human-in-the-loop workflow — deployed as `workflow`.

A deliberately complex, deterministic (no LLM) pipeline with THREE
sequential human-approval gates and THREE side-effect stages, purpose-built
to prove the platform's hardest guarantee:

  "the system recovers from the exact point where it was left off
   before the human was called — and nothing ever runs twice."

Pipeline:
  intake ──► GATE 1 ──► enrich ──► GATE 2 ──► execute ──► GATE 3 ──► report
  (fx #1)   approve     (fx #2)   approve    (fx #3)    confirm
             data                  plan                   execution

Every stage appends a unique marker to `side_effects` — the exactly-once
counter used by the test suites. `stage_results` accumulates structured
data at each stage, so a resume after a crash can be verified to carry
forward EVERYTHING that was already computed (the "exact point" test).

Resume shape: `{"command":{"resume":{"approved":true,"note":"..."}}}`
  — approved=true  → proceed to the next stage
  — approved=false → the workflow exits cleanly at that gate with
                     status "rejected at gate N" in the final result

Edge cases this graph exists to exercise (all covered by
scripts/test-workflow.sh):
  - approve gate 1, crash while paused at gate 2 → restart → resume from
    the exact pre-gate-2 state (enrich data intact, intake never re-runs)
  - crash mid-stage (reaper recovery) → resume from checkpoint → gate
  - sequential crash at each gate → full 3-crash recovery chain
  - reject at any gate → early exit, later stages never execute
"""

import uuid
from typing import Annotated, TypedDict

from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.types import interrupt


class State(TypedDict, total=False):
    messages: Annotated[list, add_messages]
    # Exactly-once instrumentation: one marker per stage execution.
    side_effects: Annotated[list, add_messages]
    # Structured results accumulated at each stage — the "exact point" data.
    stage_results: Annotated[list, add_messages]


def _content(msg) -> str:
    """Extract content from a message that may be a dict or a Message object."""
    if isinstance(msg, dict):
        return msg.get("content", "")
    return getattr(msg, "content", "")


def _fx(state: State, stage: str) -> dict:
    """Record a side effect (business action) with a unique marker."""
    return {
        "side_effects": [{"role": "assistant", "content": f"fx:{stage}:{uuid.uuid4()}"}],
    }


def _result(state: State, key: str, value: dict) -> dict:
    """Accumulate structured data that must survive any crash."""
    return {
        "stage_results": [{"role": "assistant", "content": f"{key}={value}"}],
        "messages": [{"role": "assistant", "content": f"{key} done: {value}"}],
    }


# ------------------------------------------------------------------ stages
def intake(state: State) -> dict:
    """Stage 1: analyze input, record side effect #1."""
    out = _fx(state, "intake")
    user_msg = _content(state["messages"][-1]) if state["messages"] else ""
    out.update(_result(state, "intake", {
        "user_message": user_msg,
        "analyzed": True,
    }))
    return out


def enrich(state: State) -> dict:
    """Stage 2: enrich the analysis, record side effect #2."""
    out = _fx(state, "enrich")
    out.update(_result(state, "enrich", {
        "enrichment": "extra-data-from-enrich-stage",
        "timestamp": str(uuid.uuid4()),  # unique per execution
    }))
    return out


def execute_action(state: State) -> dict:
    """Stage 3: the irreversible business action — side effect #3.

    This is the step that must NEVER run twice. In production this would
    be the booking / payment / visa-submission tool.
    """
    out = _fx(state, "execute")
    out.update(_result(state, "execute", {
        "action": "irreversible-business-action",
        "transaction_id": str(uuid.uuid4()),
    }))
    return out


def report(state: State) -> dict:
    """Final: assemble everything that was accumulated across all stages."""
    stage_keys = [str(_content(r)) for r in state.get("stage_results", [])]
    out = _fx(state, "report")
    out["messages"] = [{
        "role": "assistant",
        "content": f"report complete: {len(stage_keys)} stage results preserved"
    }]
    return out


def rejected(state: State) -> dict:
    """Early exit path when a human rejects at any gate."""
    return {"messages": [{"role": "assistant", "content": "workflow rejected"}]}


# ------------------------------------------------------------------ gates
def gate_approve_data(state: State) -> dict:
    """GATE 1: human approves the intake analysis."""
    answer = interrupt({
        "gate": 1,
        "question": "Approve the intake analysis?",
        "context": {
            "stage_results": [str(_content(r)) for r in state.get("stage_results", [])],
        },
    })
    if not answer.get("approved"):
        return {"messages": [{"role": "assistant", "content": "rejected at gate 1"}]}
    return {"messages": [{"role": "assistant", "content": "gate 1 approved"}]}


def gate_approve_plan(state: State) -> dict:
    """GATE 2: human approves the enriched plan (this is the key test gate:
    the state here carries intake + enrich results and must survive crashes)."""
    answer = interrupt({
        "gate": 2,
        "question": "Approve the enriched plan?",
        "context": {
            "stage_results": [str(_content(r)) for r in state.get("stage_results", [])],
        },
    })
    if not answer.get("approved"):
        return {"messages": [{"role": "assistant", "content": "rejected at gate 2"}]}
    return {"messages": [{"role": "assistant", "content": "gate 2 approved"}]}


def gate_confirm_execution(state: State) -> dict:
    """GATE 3: human confirms the irreversible action was correct."""
    answer = interrupt({
        "gate": 3,
        "question": "Confirm the execution result?",
        "context": {
            "stage_results": [str(_content(r)) for r in state.get("stage_results", [])],
        },
    })
    if not answer.get("approved"):
        return {"messages": [{"role": "assistant", "content": "rejected at gate 3"}]}
    return {"messages": [{"role": "assistant", "content": "gate 3 confirmed"}]}


# ------------------------------------------------------------------ routing
def _gate_route(state: State, gate_number: int, on_approve: str) -> str:
    """After a gate node, route to the next stage or the rejected exit."""
    last = _content(state["messages"][-1]) if state["messages"] else ""
    if f"rejected at gate {gate_number}" in str(last):
        return "rejected"
    return on_approve


def route_gate1(state: State) -> str:
    return _gate_route(state, 1, "enrich")


def route_gate2(state: State) -> str:
    return _gate_route(state, 2, "execute_action")


def route_gate3(state: State) -> str:
    return _gate_route(state, 3, "report")


# ------------------------------------------------------------------ assembly
builder = StateGraph(State)
builder.add_node("intake", intake)
builder.add_node("gate_approve_data", gate_approve_data)
builder.add_node("enrich", enrich)
builder.add_node("gate_approve_plan", gate_approve_plan)
builder.add_node("execute_action", execute_action)
builder.add_node("gate_confirm_execution", gate_confirm_execution)
builder.add_node("report", report)
builder.add_node("rejected", rejected)

builder.add_edge(START, "intake")
builder.add_edge("intake", "gate_approve_data")
builder.add_conditional_edges("gate_approve_data", route_gate1, ["enrich", "rejected"])
builder.add_edge("enrich", "gate_approve_plan")
builder.add_conditional_edges("gate_approve_plan", route_gate2, ["execute_action", "rejected"])
builder.add_edge("execute_action", "gate_confirm_execution")
builder.add_conditional_edges("gate_confirm_execution", route_gate3, ["report", "rejected"])
builder.add_edge("report", END)
builder.add_edge("rejected", END)

graph = builder.compile()
