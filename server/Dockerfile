# Agent Server image — public langgraph-api source, company-internal deployment.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8123

WORKDIR /app

COPY server/requirements.txt server/entrypoint.sh server/healthcheck.py server/watchdog.py ./
RUN pip install --no-cache-dir -r requirements.txt \
    && chmod +x entrypoint.sh

COPY langgraph.json auth.py ./
COPY agents/ ./agents/

EXPOSE 8123

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD ["python", "/app/healthcheck.py"]

ENTRYPOINT ["./entrypoint.sh"]
