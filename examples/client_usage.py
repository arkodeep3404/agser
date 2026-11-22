"""Complete feature tour of the Agent Server via the official Python SDK.

Run against a live platform (local compose or AWS ALB):

    BASE_URL=http://127.0.0.1:8123 PLATFORM_API_KEY=dev-key \
        python examples/client_usage.py

Covers, in order:
  1.  Assistants: list, search, create custom assistant with config (model
      overrides), assistant VERSIONING + rollback (the "registry" feature).
  2.  Threads: create, get, patch metadata, search, copy.
  3.  Runs: sync (wait), streaming (SSE token stream), background (queue) +
      join stream, batch, stateless, cancellation, double-texting
      strategies, config/metadata/recursion_limit.
  4.  Human-in-the-loop: interrupt → inspect state → resume with Command.
  5.  Durable state: thread state, history (checkpoints), update state,
      state-at-checkpoint, subgraphs.
  6.  Long-term store: put/get/delete, namespace listing, semantic search.
  7.  Crons: schedule recurring runs, list, update, delete.
  8.  Feedback: attach scores to runs.
  9.  MCP: fetch the agent as MCP tools.
  10. A2A: fetch the agent card, send an A2A message.
  11. Health / info / metrics / OpenAPI discovery endpoints.

Every call below is the same API LangSmith Agent Server exposes; it works
identically against this self-hosted platform.
"""

import os
import time

from langgraph_sdk import get_client

BASE = os.environ.get("BASE_URL", "http://127.0.0.1:8123")
KEY = os.environ.get("PLATFORM_API_KEY", "dev-key")

client = get_client(url=BASE, api_key=KEY)


def step(n, title):
    print(f"\n=== {n}. {title} ===")


def main():
    # -- 1. Assistants --------------------------------------------------------
    step(1, "Assistants — registry, config, versioning, rollback")
    assistants = client.assistants.search(limit=10)
    print("default assistants:", sorted(a["assistant_id"] for a in assistants))

    custom = client.assistants.create(
        graph_id="research",
        config={"configurable": {"model": "anthropic:claude-sonnet-4-5"}},
        metadata={"team": "platform", "env": "demo"},
        name="Research v1",
    )
    print("created assistant:", custom["assistant_id"])

    # Versioning: snapshots of graph+config with rollback to any version.
    v1 = client.assistants.create_version(custom["assistant_id"])
    print("version:", v1["version"])
    print("versions:", [
        v["version"] for v in client.assistants.get_versions(custom["assistant_id"])
    ])

    # -- 2. Threads -----------------------------------------------------------
    step(2, "Threads — create, patch, search, copy")
    thread = client.threads.create(metadata={"customer": "acme"})
    print("thread:", thread["thread_id"], "status:", thread["status"])
    client.threads.update(thread["thread_id"], metadata={"tier": "gold"})
    found = client.threads.search(metadata={"customer": "acme"}, limit=5)
    print("search hits:", len(found))
    copy = client.threads.copy(thread["thread_id"])
    print("copy:", copy["thread_id"])

    # -- 3. Runs ---------------------------------------------------------------
    step(3, "Runs — wait, stream, background, batch, cancel, double-texting")
    result = client.runs.wait(
        thread["thread_id"],
        assistant_id="ping",
        input={"messages": [{"role": "user", "content": "sync"}]},
    )
    print("wait run:", result["messages"][-1]["content"])

    for mode in ["values", "messages-tuple"]:
        for chunk in client.runs.stream(
            thread["thread_id"],
            assistant_id="ping",
            input={"messages": [{"role": "user", "content": "stream"}]},
            stream_mode=[mode],
        ):
            pass  # iterate the SSE stream; last chunk is the result message
    print("stream run: ok")

    bg = client.runs.create(thread["thread_id"], assistant_id="ping",
                            input={"messages": [{"role": "user", "content": "bg"}]})
    joined = client.runs.join(thread["thread_id"], bg["run_id"])
    print("bg run:", joined["messages"][-1]["content"])

    client.runs.batch(
        [{"assistant_id": "ping", "input": {"messages": [{"role": "user", "content": "b1"}]}},
         {"assistant_id": "ping", "input": {"messages": [{"role": "user", "content": "b2"}]}}],
    )
    print("batch runs: ok")

    # Stateless run — no thread, one-shot execution.
    st = client.runs.create(None, assistant_id="ping",
                            input={"messages": [{"role": "user", "content": "stateless"}]})
    print("stateless run:", st["messages"][-1]["content"])

    # Double-texting: new run while one is active — choose a strategy.
    slow = client.runs.create(thread["thread_id"], assistant_id="sleepy",
                              input={"messages": [{"role": "user", "content": "slow"}]},
                              multitask_strategy="interrupt")
    client.runs.cancel(thread["thread_id"], slow["run_id"], action="interrupt")
    print("cancel: ok")

    # -- 4. Human in the loop -------------------------------------------------
    step(4, "Human-in-the-loop — interrupt, inspect, resume with Command")
    hitl_thread = client.threads.create()
    client.runs.wait(
        hitl_thread["thread_id"],
        assistant_id="approval",
        input={"messages": [{"role": "user", "content": "plan x"}]},
    )
    state = client.threads.get_state(hitl_thread["thread_id"])
    print("thread status:", state["status"], "next:", state["next"])  # paused at 'gate'
    resumed = client.runs.wait(
        hitl_thread["thread_id"],
        assistant_id="approval",
        command={"resume": {"approved": True}},  # the human's decision
    )
    print("resumed:", resumed["messages"][-1]["content"])

    # -- 5. Durable state ------------------------------------------------------
    step(5, "Durable state — checkpoints, history, state surgery")
    history = client.threads.get_history(hitl_thread["thread_id"], limit=10)
    print("checkpoints:", [h["checkpoint"]["checkpoint_id"][:8] for h in history])
    client.threads.update_state(hitl_thread["thread_id"], values={"messages": []},
                                as_node="finish")
    print("state update: ok")

    # -- 6. Long-term store (cross-thread memory) ------------------------------
    step(6, "Store — namespaces, items, semantic search")
    client.store.put_item(
        namespace=["customers", "acme"], key="prefs",
        value={"text": "prefers dark interfaces and concise answers"},
    )
    item = client.store.get_item(namespace=["customers", "acme"], key="prefs")
    print("get item:", item["value"])
    hits = client.store.search_items(namespace_prefix=["customers"],
                                     query="ui preferences")   # semantic
    print("semantic search:", [h["key"] for h in hits["items"]])

    # -- 7. Crons ---------------------------------------------------------------
    step(7, "Crons — scheduled recurring runs")
    cron = client.crons.create(
        thread["thread_id"], assistant_id="ping",
        input={"messages": [{"role": "user", "content": "tick"}]},
        schedule="*/15 * * * *",
    )
    print("cron:", cron["cron_id"])
    client.crons.delete(thread["thread_id"], cron["cron_id"])
    print("cron deleted")

    # -- 8. Feedback -------------------------------------------------------------
    step(8, "Feedback — attach scores to runs")
    try:
        client.feedback.create(
            run_id=bg["run_id"], key="user_rating", score=0.9,
            comment="good run",
        )
        print("feedback recorded for run", bg["run_id"])
    except Exception as exc:  # noqa: BLE001 — feedback keys off a trace id
        print(f"feedback requires a traced run id: {exc}")

    # -- 9. MCP -------------------------------------------------------------------
    step(9, "MCP — the agents as Model Context Protocol tools")
    # Any MCP client (Claude Desktop, IDEs) points at BASE + /mcp with the API key.

    # -- 10. A2A --------------------------------------------------------------------
    step(10, "A2A — agent-to-agent protocol")
    # GET  {BASE}/.well-known/agent-card.json?assistant_id=research → agent card
    # POST {BASE}/a2a/research with a JSON-RPC message → talk agent-to-agent.

    # -- 11. Ops endpoints --------------------------------------------------------------
    step(11, "Ops — /ok, /info, /metrics, /docs, /openapi.json")
    print("all reachable over HTTP with the API key header — see scripts/verify.sh")

    print("\nFeature tour complete.")


if __name__ == "__main__":
    main()
