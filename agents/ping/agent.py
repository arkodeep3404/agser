"""No-LLM smoke-test graph.

Deployed as `ping` so the platform can be verified end to end with no API
keys: threads, runs, streaming, checkpoints all work through this graph.
"""

from typing import Annotated, TypedDict

from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages


class State(TypedDict):
    messages: Annotated[list, add_messages]


def echo(state: State) -> dict:
    text = ""
    if state["messages"]:
        last = state["messages"][-1]
        if isinstance(last, dict):
            text = last.get("content", "")
        else:
            text = getattr(last, "content", "")
    content = f"pong: {text}" if text else "pong"
    return {"messages": [{"role": "assistant", "content": content}]}


builder = StateGraph(State)
builder.add_node("echo", echo)
builder.add_edge(START, "echo")
builder.add_edge("echo", END)

graph = builder.compile()
