# ── Stage 1: Dependencies ─────────────────────────────────────────────────────
FROM python:3.12-slim AS deps

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: Run ─────────────────────────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

COPY --from=deps /install /usr/local
COPY worker.py .

USER appuser

EXPOSE 8083

CMD ["python", "worker.py"]
