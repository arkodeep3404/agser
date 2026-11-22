"""Research deep agent — planning, subagents, filesystem tools, interrupts.

Deployed as `research`. Uses LangChain's `deepagents` package, which compiles
to a standard LangGraph graph, so the Agent Server gives it durable execution,
checkpoints, streaming and human-in-the-loop interrupts for free.

Registered as a FACTORY (`make(config)`), per the Agent Server's
recommended pattern: the graph (and its model) is constructed per run from
the assistant's config, so

  - model/provider can differ per assistant (registry + config overrides),
  - a missing or bad credential fails that run, not the whole server boot.

Model resolution order (first match wins):
  1. assistant config: {"configurable": {"model": "anthropic:claude-..."}}
  2. MODEL_PROVIDER env (bedrock default in AWS, or direct provider string
     via AGENT_MODEL + its API key).
"""

import os

from deepagents import create_deep_agent


def word_count(text: str) -> str:
    """Count the words in a piece of text."""
    return f"{len(text.split())} words"


def current_capabilities(tool_name: str) -> str:
    """Return the capabilities of a named internal tool/system (stub lookup).

    Replace this with a real call into your systems (SQL, APIs, internal docs).
    """
    catalog = {
        "billing-api": "Invoices, subscriptions, refunds. REST at /v1/billing.",
        "crm": "Accounts, contacts, deals. Read-only access enabled.",
        "warehouse": "Events and metrics tables, Athena access.",
    }
    return catalog.get(
        tool_name, f"No entry for {tool_name!r} in the internal catalog."
    )


def resolve_model(config: dict | None):
    """Build the chat model from assistant config or environment, lazily."""
    cfg = (config or {}).get("configurable", {}) if config else {}
    model_spec = cfg.get("model") or os.environ.get("AGENT_MODEL")
    provider = cfg.get("model_provider") or os.environ.get(
        "MODEL_PROVIDER", "bedrock"
    ).lower()

    if provider == "openrouter":
        from langchain_openai import ChatOpenAI

        return ChatOpenAI(
            model=cfg.get("openrouter_model")
            or os.environ.get("OPENROUTER_MODEL", "google/gemini-3.5-flash-lite"),
            api_key=os.environ.get("OPENROUTER_API_KEY"),
            base_url=os.environ.get(
                "OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"
            ),
        )
    if provider == "bedrock" and not model_spec:
        # In-account inference via IAM role — no static keys.
        from langchain_aws import ChatBedrockConverse

        return ChatBedrockConverse(
            model=cfg.get("bedrock_model_id")
            or os.environ.get(
                "BEDROCK_MODEL_ID", "anthropic.claude-sonnet-4-5-20250929-v1:0"
            ),
            region_name=os.environ.get("AWS_REGION") or None,
        )
    # Direct provider string, e.g. "anthropic:claude-sonnet-4-5".
    return model_spec or "anthropic:claude-sonnet-4-5"


def make(config=None):
    """Graph factory — invoked per run by the Agent Server."""
    return create_deep_agent(
        model=resolve_model(config),
        system_prompt=(
            "You are the company research agent. Plan multi-step work, use the "
            "file system to keep notes for long tasks, and delegate deep-dives to "
            "the researcher subagent. Cite which internal systems you consulted."
        ),
        tools=[word_count, current_capabilities],
        subagents=[
            {
                "name": "researcher",
                "description": (
                    "Deep-dives into a single internal system or topic and "
                    "returns a structured summary with findings."
                ),
                "prompt": (
                    "You are a focused researcher. Investigate exactly what is "
                    "asked, use the catalog tool for internal system questions, "
                    "and return findings as a markdown summary."
                ),
                "tools": [current_capabilities],
            }
        ],
    )
