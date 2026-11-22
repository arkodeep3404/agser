"""Complex operations deep agent — deployed as `complex`.

A deliberately full-featured agent exercising every deep-agents capability:

  * Planning (built into deep agents) with persistent notes
  * File system tools (built in) for long-task scratch state
  * 6 custom tools spanning lookups, deterministic data queries,
    computation, formatting and escalation
  * 3 specialist subagents (researcher / analyst / writer), each with its
    own toolset and prompt
  * SummarizationMiddleware — long conversations get compacted instead of
    blowing the context window
  * Human-in-the-loop: `interrupt_on=["format_report"]` — the run pauses for
    a human to approve before any report is formatted (resume with a Command)
  * Structured final output via `response_format` (Report)
  * Factory registration `make(config)` — per-assistant model overrides,
    lazy credentials, no import-time crashes

Run it:
    POST /threads/{tid}/runs/wait {"assistant_id":"complex",
      "input":{"messages":[{"role":"user","content":
        "Research our billing-api, analyze Q3 orders for anomalies,
         then write the incident report."}]}}
    # it will pause at format_report for human approval; resume with
    # {"command":{"resume": [{"type":"accept"}]}}
"""

import json
import os
from typing import Optional

from deepagents import create_deep_agent
from langchain.agents.middleware import SummarizationMiddleware
from pydantic import BaseModel, Field


# --------------------------------------------------------------------------- tools
def internal_catalog(tool_name: str) -> str:
    """Look up what an internal system/tool does and how to call it."""
    catalog = {
        "billing-api": "Invoices, subscriptions, refunds. REST at /v1/billing.",
        "crm": "Accounts, contacts, deals. Read-only access enabled.",
        "warehouse": "Events and metrics tables. Athena access, 24h delay.",
        "payments": "Charges, disputes, payout schedule. REST at /v1/payments.",
        "notifications": "Email/push sending service. Idempotency keys required.",
    }
    return catalog.get(
        tool_name, f"No entry for {tool_name!r} in the internal catalog."
    )


def query_orders(system: str, month: str) -> str:
    """Query (deterministic mock) order rows for a system and month."""
    rows = {
        ("billing-api", "2026-07"): [
            {"order": "O-1001", "amount": 129.90, "status": "paid"},
            {"order": "O-1002", "amount": 89.00, "status": "paid"},
            {"order": "O-1003", "amount": 129.90, "status": "refunded"},
        ],
        ("payments", "2026-07"): [
            {"order": "O-2001", "amount": 340.00, "status": "paid"},
            {"order": "O-2002", "amount": 340.00, "status": "disputed"},
        ],
    }
    key = (system, month)
    if key in rows:
        return json.dumps(rows[key])
    return json.dumps([{"order": "O-9999", "amount": 42.00, "status": "paid"}])


def calc(expression: str) -> str:
    """Evaluate an arithmetic expression (numbers and + - * / ( ) only)."""
    allowed = set("0123456789+-*/(). ")
    if not set(expression) <= allowed:
        return "error: only arithmetic expressions are allowed"
    try:
        return str(eval(expression, {"__builtins__": {}}, {}))  # noqa: S307 — sandboxed charset
    except Exception as exc:  # noqa: BLE001
        return f"error: {exc}"


def word_count(text: str) -> str:
    """Count the words in a piece of text."""
    return f"{len(text.split())} words"


def escalate(reason: str, severity: str) -> str:
    """Escalate an issue to the on-call human channel."""
    return f"Escalated (severity={severity}): {reason} — ack 24/7 on-call."


def format_report(title: str, body: str) -> str:
    """Format a final incident/analysis report. INTERRUPTED FOR HUMAN
    APPROVAL before it runs (see interrupt_on below)."""
    return f"# {title}\n\n{body}\n\n---\nApproved formatting applied."


# --------------------------------------------------------------------------- schema
class Report(BaseModel):
    """Structured output the agent must produce before finishing."""
    title: str = Field(description="Short report title")
    summary: str = Field(description="Executive summary, 2-3 sentences")
    findings: list[str] = Field(description="Bullet findings with evidence")
    recommendation: Optional[str] = Field(
        default=None, description="Recommended next action"
    )


# --------------------------------------------------------------------------- factory
def resolve_model(config: dict | None):
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
        from langchain_aws import ChatBedrockConverse

        return ChatBedrockConverse(
            model=cfg.get("bedrock_model_id")
            or os.environ.get(
                "BEDROCK_MODEL_ID", "anthropic.claude-sonnet-4-5-20250929-v1:0"
            ),
            region_name=os.environ.get("AWS_REGION") or None,
        )
    return model_spec or "anthropic:claude-sonnet-4-5"


def make(config=None):
    """Graph factory — invoked per run by the Agent Server."""
    model = resolve_model(config)
    return create_deep_agent(
        model=model,
        system_prompt=(
            "You are the company Operations Agent. You coordinate research, "
            "data analysis and report writing across internal systems. Always: "
            "plan first in your todo file, delegate single-system deep-dives to "
            "the researcher, all numeric analysis to the analyst, and all "
            "written deliverables to the writer. Escalate anomalies with "
            "severity high|low. Finish with a structured Report."
        ),
        tools=[
            internal_catalog,
            query_orders,
            calc,
            word_count,
            escalate,
            format_report,
        ],
        subagents=[
            {
                "name": "researcher",
                "description": (
                    "Deep-dives into ONE internal system or topic using the "
                    "catalog; returns a structured findings summary."
                ),
                "prompt": (
                    "You are a meticulous researcher. Establish exactly what a "
                    "system does and its interfaces. Return findings as short "
                    "markdown bullets with evidence."
                ),
                "tools": [internal_catalog],
            },
            {
                "name": "analyst",
                "description": (
                    "Performs ALL numeric/data analysis: queries orders, runs "
                    "calculations, detects anomalies. Never writes prose."
                ),
                "prompt": (
                    "You are a quantitative analyst. Pull the data with "
                    "query_orders, verify arithmetic with calc, and report "
                    "numbers with exact totals and anomaly flags only."
                ),
                "tools": [query_orders, calc],
            },
            {
                "name": "writer",
                "description": (
                    "Turns findings into the final deliverable; asks the lead "
                    "for format_report approval via the human gate."
                ),
                "prompt": (
                    "You are a precise technical writer. Compose the report "
                    "body from the researcher's and analyst's outputs, keep it "
                    "under 300 words, and use format_report for final layout."
                ),
                "tools": [word_count, format_report],
            },
        ],
        middleware=[
            SummarizationMiddleware(model=model),
        ],
        interrupt_on={"format_report": True},  # human approval gate
        response_format=Report,
    )
