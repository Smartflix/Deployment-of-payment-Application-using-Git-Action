# ── Stage 1: Build ───────────────────────────────────────────────────────────
FROM golang:1.24-alpine AS builder

WORKDIR /app

# Download dependencies first (layer caches this step separately from source)
COPY go.mod go.sum ./
RUN go mod download

# Copy source and build a statically-linked binary
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o auth-api .

# ── Stage 2: Run ─────────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12

WORKDIR /app
COPY --from=builder /app/auth-api .

USER 65532:65532

EXPOSE 8081

ENTRYPOINT ["/app/auth-api"]
