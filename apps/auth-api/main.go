package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/golang-jwt/jwt/v5"
	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// --- Metrics ---
var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "auth_http_requests_total",
		Help: "Total HTTP requests to auth-api",
	}, []string{"method", "path", "status"})

	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "auth_http_duration_seconds",
		Help:    "HTTP request duration in seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"path"})
)

// --- Types ---
type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type LoginResponse struct {
	Token   string `json:"token"`
	Message string `json:"message"`
}

type ValidateResponse struct {
	Valid    bool   `json:"valid"`
	Username string `json:"username,omitempty"`
	Message  string `json:"message,omitempty"`
}

type HealthResponse struct {
	Status    string `json:"status"`
	Service   string `json:"service"`
	Timestamp string `json:"timestamp"`
	DBStatus  string `json:"db_status"`
}

// --- JWT helpers ---
func jwtSecret() []byte {
	s := os.Getenv("JWT_SECRET")
	if s == "" {
		s = "dev-secret-change-in-production"
	}
	return []byte(s)
}

func generateToken(username string) (string, error) {
	claims := jwt.MapClaims{
		"sub": username,
		"exp": time.Now().Add(24 * time.Hour).Unix(),
		"iat": time.Now().Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(jwtSecret())
}

func validateToken(tokenStr string) (string, bool) {
	token, err := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) {
		return jwtSecret(), nil
	})
	if err != nil || !token.Valid {
		return "", false
	}
	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		return "", false
	}
	username, _ := claims["sub"].(string)
	return username, true
}

// --- Database ---
var db *sql.DB

func initDB() {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Println("DATABASE_URL not set — running with in-memory users only")
		return
	}
	var err error
	db, err = sql.Open("postgres", dsn)
	if err != nil {
		log.Printf("DB open error: %v — falling back to in-memory users", err)
		return
	}
	if err = db.Ping(); err != nil {
		log.Printf("DB ping error: %v — falling back to in-memory users", err)
		db = nil
		return
	}
	log.Println("Connected to PostgreSQL")
	_, _ = db.Exec(`
		CREATE TABLE IF NOT EXISTS users (
			id SERIAL PRIMARY KEY,
			username VARCHAR(64) UNIQUE NOT NULL,
			password_hash VARCHAR(255) NOT NULL,
			created_at TIMESTAMPTZ DEFAULT NOW()
		)
	`)
	// Seed a default user (in production use bcrypt hashing)
	_, _ = db.Exec(`
		INSERT INTO users (username, password_hash) VALUES ('admin', 'password123')
		ON CONFLICT (username) DO NOTHING
	`)
}

// In-memory fallback users (for local/dev when no DB)
var inMemoryUsers = map[string]string{
	"admin":     "password123",
	"merchant1": "merchant123",
	"demo":      "demo1234",
}

func checkCredentials(username, password string) bool {
	if db != nil {
		var hash string
		err := db.QueryRow("SELECT password_hash FROM users WHERE username=$1", username).Scan(&hash)
		if err == nil {
			// In production replace with bcrypt.CompareHashAndPassword
			return hash == password
		}
	}
	// Fallback to in-memory
	p, ok := inMemoryUsers[username]
	return ok && p == password
}

// --- Handlers ---
func handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	timer := prometheus.NewTimer(httpDuration.WithLabelValues("/auth/login"))
	defer timer.ObserveDuration()

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(LoginResponse{Message: "Invalid request body"})
		httpRequests.WithLabelValues(r.Method, "/auth/login", "400").Inc()
		return
	}

	if !checkCredentials(req.Username, req.Password) {
		w.WriteHeader(http.StatusUnauthorized)
		json.NewEncoder(w).Encode(LoginResponse{Message: "Invalid credentials"})
		httpRequests.WithLabelValues(r.Method, "/auth/login", "401").Inc()
		return
	}

	token, err := generateToken(req.Username)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(LoginResponse{Message: "Token generation failed"})
		httpRequests.WithLabelValues(r.Method, "/auth/login", "500").Inc()
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(LoginResponse{Token: token, Message: "Login successful"})
	httpRequests.WithLabelValues(r.Method, "/auth/login", "200").Inc()
}

func handleValidate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	timer := prometheus.NewTimer(httpDuration.WithLabelValues("/auth/validate"))
	defer timer.ObserveDuration()

	authHeader := r.Header.Get("Authorization")
	if len(authHeader) < 8 || authHeader[:7] != "Bearer " {
		w.WriteHeader(http.StatusUnauthorized)
		json.NewEncoder(w).Encode(ValidateResponse{Valid: false, Message: "Missing or malformed token"})
		httpRequests.WithLabelValues(r.Method, "/auth/validate", "401").Inc()
		return
	}

	tokenStr := authHeader[7:]
	username, valid := validateToken(tokenStr)
	w.Header().Set("Content-Type", "application/json")
	if !valid {
		w.WriteHeader(http.StatusUnauthorized)
		json.NewEncoder(w).Encode(ValidateResponse{Valid: false, Message: "Invalid or expired token"})
		httpRequests.WithLabelValues(r.Method, "/auth/validate", "401").Inc()
		return
	}
	json.NewEncoder(w).Encode(ValidateResponse{Valid: true, Username: username})
	httpRequests.WithLabelValues(r.Method, "/auth/validate", "200").Inc()
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	dbStatus := "disconnected"
	if db != nil {
		if err := db.Ping(); err == nil {
			dbStatus = "connected"
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(HealthResponse{
		Status:    "healthy",
		Service:   "auth-api",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		DBStatus:  dbStatus,
	})
}

func main() {
	initDB()

	mux := http.NewServeMux()
	mux.HandleFunc("/auth/login", handleLogin)
	mux.HandleFunc("/auth/validate", handleValidate)
	mux.HandleFunc("/health", handleHealth)
	mux.Handle("/metrics", promhttp.Handler())

	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}
	log.Printf("auth-api listening on :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
