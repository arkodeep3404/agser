"""agser: official assistant-create semantics.

The official LangSmith Agent Server assigns a fresh random assistant_id on
every create — multiple assistants per (user, graph, config) are allowed and
common (one Deep Agent codebase, many configured variants). The vendored
core's UNIQUE index idx_assistant_user_graph_config rejected such creates
with a conflict. We drop the uniqueness and keep a plain index for lookup
speed, matching the official behavior.

Revision ID: agser0001_assistants
Revises: a3f7c1d9e2b4
"""

from alembic import op

revision = "agser0001_assistants"
down_revision = "a3f7c1d9e2b4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_index("idx_assistant_user_graph_config", table_name="assistant")
    op.create_index(
        "idx_assistant_user_graph_config",
        "assistant",
        ["user_id", "graph_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("idx_assistant_user_graph_config", table_name="assistant")
    # Restores the vendored unique index (config-hash based, per b88bb61be638).
    op.create_index(
        "idx_assistant_user_graph_config",
        "assistant",
        ["user_id", "graph_id", "config_hash"],
        unique=True,
    )
