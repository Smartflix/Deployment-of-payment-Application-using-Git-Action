import os
import uuid
import logging
from datetime import datetime
from flask import Flask, jsonify, request, abort
from prometheus_flask_exporter import PrometheusMetrics
import psycopg2
import psycopg2.extras

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

app = Flask(__name__)
metrics = PrometheusMetrics(app, group_by="endpoint")

# ── Database ──────────────────────────────────────────────────────────────────
def get_db():
    """Return a fresh DB connection (or None if not configured)."""
    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        return None
    try:
        conn = psycopg2.connect(dsn)
        return conn
    except Exception as e:
        logger.warning("DB connect failed: %s — using in-memory store", e)
        return None

# In-memory fallback (used when PostgreSQL is unavailable)
IN_MEMORY_PAYMENTS = {}

def seed_db(conn):
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
    logger.info("Database ready")

# Try DB on startup
_conn = get_db()
if _conn:
    seed_db(_conn)
    _conn.close()

# ── Helpers ───────────────────────────────────────────────────────────────────
def fetch_payments():
    conn = get_db()
    if conn:
        try:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute("SELECT * FROM payments ORDER BY created_at DESC LIMIT 100")
                rows = [dict(r) for r in cur.fetchall()]
            conn.close()
            return rows
        except Exception as e:
            logger.error("fetch_payments DB error: %s", e)
    return list(IN_MEMORY_PAYMENTS.values())

def fetch_payment(payment_id):
    conn = get_db()
    if conn:
        try:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute("SELECT * FROM payments WHERE id=%s", (payment_id,))
                row = cur.fetchone()
            conn.close()
            return dict(row) if row else None
        except Exception as e:
            logger.error("fetch_payment DB error: %s", e)
    return IN_MEMORY_PAYMENTS.get(payment_id)

def create_payment_db(payment):
    conn = get_db()
    if conn:
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO payments (id, merchant_id, amount, currency, status, description)
                    VALUES (%s, %s, %s, %s, %s, %s)
                """, (
                    payment["id"], payment["merchant_id"], payment["amount"],
                    payment["currency"], payment["status"], payment["description"]
                ))
                conn.commit()
            conn.close()
            return
        except Exception as e:
            logger.error("create_payment DB error: %s", e)
    IN_MEMORY_PAYMENTS[payment["id"]] = payment

# ── Routes ────────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    db_status = "connected" if get_db() else "disconnected"
    return jsonify({
        "status": "healthy",
        "service": "payments-api",
        "version": os.getenv("APP_VERSION", "1.0.0"),
        "db_status": db_status,
        "timestamp": datetime.utcnow().isoformat() + "Z",
    })

@app.get("/payments")
def list_payments():
    payments = fetch_payments()
    # Serialize datetime objects
    for p in payments:
        for k, v in p.items():
            if isinstance(v, datetime):
                p[k] = v.isoformat() + "Z"
    return jsonify({"payments": payments, "total": len(payments)})

@app.post("/payments")
def create_payment():
    data = request.get_json(force=True, silent=True)
    if not data:
        abort(400, description="Invalid JSON body")

    required = ["merchant_id", "amount"]
    for field in required:
        if field not in data:
            abort(400, description=f"Missing required field: {field}")

    try:
        amount = float(data["amount"])
        if amount <= 0:
            abort(400, description="Amount must be positive")
    except (TypeError, ValueError):
        abort(400, description="Invalid amount")

    payment = {
        "id": str(uuid.uuid4()),
        "merchant_id": str(data["merchant_id"]),
        "amount": amount,
        "currency": data.get("currency", "USD").upper(),
        "status": "pending",
        "description": data.get("description", ""),
        "created_at": datetime.utcnow().isoformat() + "Z",
        "updated_at": datetime.utcnow().isoformat() + "Z",
    }
    create_payment_db(payment)
    logger.info("Created payment %s for merchant %s amount %.2f", payment["id"], payment["merchant_id"], amount)
    return jsonify(payment), 201

@app.get("/payments/<payment_id>")
def get_payment(payment_id):
    payment = fetch_payment(payment_id)
    if not payment:
        abort(404, description=f"Payment {payment_id} not found")
    if isinstance(payment.get("created_at"), datetime):
        payment["created_at"] = payment["created_at"].isoformat() + "Z"
    if isinstance(payment.get("updated_at"), datetime):
        payment["updated_at"] = payment["updated_at"].isoformat() + "Z"
    return jsonify(payment)

@app.patch("/payments/<payment_id>/status")
def update_status(payment_id):
    data = request.get_json(force=True, silent=True)
    if not data or "status" not in data:
        abort(400, description="Missing 'status' field")

    allowed = {"pending", "processing", "completed", "failed", "refunded"}
    new_status = data["status"]
    if new_status not in allowed:
        abort(400, description=f"Status must be one of: {', '.join(allowed)}")

    conn = get_db()
    if conn:
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE payments SET status=%s, updated_at=NOW() WHERE id=%s RETURNING id",
                    (new_status, payment_id)
                )
                if cur.rowcount == 0:
                    abort(404, description=f"Payment {payment_id} not found")
                conn.commit()
            conn.close()
        except Exception as e:
            logger.error("update_status DB error: %s", e)
            abort(500)
    else:
        if payment_id not in IN_MEMORY_PAYMENTS:
            abort(404, description=f"Payment {payment_id} not found")
        IN_MEMORY_PAYMENTS[payment_id]["status"] = new_status

    return jsonify({"id": payment_id, "status": new_status})

@app.errorhandler(400)
@app.errorhandler(404)
@app.errorhandler(500)
def handle_error(e):
    return jsonify({"error": str(e)}), e.code

if __name__ == "__main__":
    port = int(os.getenv("PORT", 8082))
    app.run(host="0.0.0.0", port=port)
