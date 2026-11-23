# Agser server image — built ENTIRELY from our own repo-owned code.
#
#   server-core/  (in this repo, ours — MIT-licensed, owner-granted)
#   agents/      (ours)   auth.py (ours)   aegra.json (ours)
#
# External dependencies are pinned public libraries only: FastAPI, SQLAlchemy,
# langgraph engine + postgres checkpointer (MIT, library usage — never server
# internals), Redis, Alembic. All MIT.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8123

WORKDIR /app

# Our vendored server core (owns its pinned public dependencies).
# requirements.lock.txt records the tested set — reference only, not enforced.
COPY server-core/ ./server-core/
RUN pip install --no-cache-dir ./server-core \
    'deepagents>=0.6,<1.0' \
    'langchain-anthropic>=1.0' \
    'langchain-aws>=1.0' \
    'langchain-openai>=1.0' \
    'cryptography>=42' \
    'boto3>=1.34'

COPY aegra.json aegra.aws.json auth.py ./
COPY agents/ ./agents/
COPY extensions/ ./extensions/

EXPOSE 8123

HEALTHCHECK --interval=15s --timeout=5s --start-period=25s --retries=5 \
  CMD python -c "import urllib.request,sys; \
urllib.request.urlopen('http://127.0.0.1:8123/health',timeout=3); sys.exit(0)"

CMD python -m uvicorn aegra_api.main:app --host 0.0.0.0 --port "${PORT:-8123}"
