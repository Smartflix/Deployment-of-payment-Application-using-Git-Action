# ── Stage 1: Dependencies ─────────────────────────────────────────────────────
FROM python:3.12-slim AS deps

WORKDIR /app
COPY requirements.txt .
# Install into a separate directory so we can copy cleanly
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: Run ─────────────────────────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

# Create a non-root user for security
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

# Copy installed packages from the deps stage
COPY --from=deps /install /usr/local

# Copy application source
COPY app.py .

# Switch to non-root user
USER appuser

EXPOSE 8082

# gunicorn: production-grade WSGI server (4 workers)
CMD ["gunicorn", "--bind", "0.0.0.0:8082", "--workers", "4", "--timeout", "30", "app:app"]
