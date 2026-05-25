"""
Payment Worker — polls PostgreSQL for pending payments and processes them.
Exposes Prometheus metrics on :8083/metrics and a health endpoint on :8083/health.
"""
import os
import time
import logging
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg2
import psycopg2.extras
from prometheus_client import Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("worker")

# ── Metrics ───────────────────────────────────────────────────────────────────
PROCESSED = Counter("worker_payments_processed_total", "Payments processed", ["status"])
ERRORS     = Counter("worker_errors_total", "Worker processing errors")
PENDING    = Gauge("worker_pending_payments", "Payments currently pending")
PROC_TIME  = Histogram("worker_processing_seconds", "Time to process a payment")

# ── Database ──────────────────────────────────────────────────────────────────
def get_conn():
    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        return None
    return psycopg2.connect(dsn)

def ensure_table(conn):
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS payments (
                id          VARCHAR(36) PRIMARY KEY,
                merchant_id VARCHAR(64) NOT NULL,
                amount      NUMERIC(12,2) NOT NULL,
                currency    VARCHAR(3) DEFAULT 'USD',
                status      VARCHAR(20) DEFAULT 'pending',
                description TEXT,
                created_at  TIMESTAMPTZ DEFAULT NOW(),
                updated_at  TIMESTAMPTZ DEFAULT NOW()
            )
        """)
        conn.commit()

# ── Processing logic ──────────────────────────────────────────────────────────
def process_payment(conn, payment_id: str, amount: float) -> str:
    """
    Simulate payment processing.
    In a real system this would call a payment gateway (Stripe, etc.).
    Returns the new status: 'completed' or 'failed'.
    """
    time.sleep(0.1)  # simulate network call
    # Simple rule: amounts over $9999 need manual review → mark failed
    new_status = "failed" if amount > 9999 else "completed"
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE payments SET status=%s, updated_at=NOW() WHERE id=%s",
            (new_status, payment_id)
        )
        conn.commit()
    return new_status

def poll_and_process():
    """Main loop: fetch pending payments, process each one."""
    interval = int(os.getenv("POLL_INTERVAL_SECONDS", "5"))
    logger.info("Worker starting — poll interval: %ds", interval)

    while True:
        conn = None
        try:
            conn = get_conn()
            if conn is None:
                logger.warning("No DATABASE_URL — worker sleeping")
                time.sleep(interval)
                continue

            ensure_table(conn)

            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute(
                    "SELECT id, amount FROM payments WHERE status='pending' LIMIT 10"
                )
                rows = cur.fetchall()

            PENDING.set(len(rows))

            for row in rows:
                start = time.time()
                try:
                    new_status = process_payment(conn, row["id"], float(row["amount"]))
                    PROC_TIME.observe(time.time() - start)
                    PROCESSED.labels(status=new_status).inc()
                    logger.info("Payment %s → %s (%.2fs)",
                                row["id"], new_status, time.time() - start)
                except Exception as e:
                    ERRORS.inc()
                    logger.error("Failed to process payment %s: %s", row["id"], e)

        except Exception as e:
            ERRORS.inc()
            logger.error("Worker poll error: %s", e)
        finally:
            if conn:
                conn.close()

        time.sleep(interval)

# ── HTTP server for health + metrics ──────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # silence access logs

    def do_GET(self):
        if self.path == "/health":
            body = (
                f'{{"status":"healthy","service":"worker",'
                f'"timestamp":"{datetime.utcnow().isoformat()}Z"}}'
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/metrics":
            body = generate_latest()
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

def run_http_server():
    port = int(os.getenv("PORT", "8083"))
    server = HTTPServer(("0.0.0.0", port), Handler)
    logger.info("Worker HTTP server on :%d", port)
    server.serve_forever()

if __name__ == "__main__":
    # Run HTTP server in a background thread
    t = threading.Thread(target=run_http_server, daemon=True)
    t.start()
    # Run the processing loop in the main thread
    poll_and_process()
