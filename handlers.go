package main

import (
	"embed"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

//go:embed web/portal.html
var portalFS embed.FS

// ── Rate limiting ──────────────────────────────────────────────────────────

const (
	rlRate  = rate.Limit(5.0 / 60) // 5 requests per minute
	rlBurst = 3
)

type rateLimiterStore struct {
	mu       sync.Mutex
	limiters map[string]*rate.Limiter
}

func newRateLimiterStore() *rateLimiterStore {
	s := &rateLimiterStore{limiters: make(map[string]*rate.Limiter)}
	go s.cleanup()
	return s
}

func (s *rateLimiterStore) allow(ip string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	l, ok := s.limiters[ip]
	if !ok {
		l = rate.NewLimiter(rlRate, rlBurst)
		s.limiters[ip] = l
	}
	return l.Allow()
}

// cleanup removes limiters that are fully refilled (idle IPs).
func (s *rateLimiterStore) cleanup() {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for range ticker.C {
		s.mu.Lock()
		for ip, l := range s.limiters {
			if l.Tokens() >= float64(rlBurst) {
				delete(s.limiters, ip)
			}
		}
		s.mu.Unlock()
	}
}

var submitLimiter = newRateLimiterStore()

// ── Helpers ────────────────────────────────────────────────────────────────

func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func clientIP(r *http.Request) string {
	if ip := r.Header.Get("X-Real-IP"); ip != "" {
		return ip
	}
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		return strings.SplitN(fwd, ",", 2)[0]
	}
	// Strip port from RemoteAddr
	addr := r.RemoteAddr
	if i := strings.LastIndex(addr, ":"); i != -1 {
		return addr[:i]
	}
	return addr
}

// ── Handlers ───────────────────────────────────────────────────────────────

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func portalHandler(w http.ResponseWriter, r *http.Request) {
	data, err := portalFS.ReadFile("web/portal.html")
	if err != nil {
		http.Error(w, "portal unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}

func statusHandler(w http.ResponseWriter, r *http.Request) {
	jobID := r.PathValue("id")
	if jobID == "" {
		jsonError(w, "job ID is required", http.StatusBadRequest)
		return
	}

	status, err := bg.GetStatus(jobID)
	if err != nil {
		log.Printf("bytegrader status error: %v", err)
		jsonError(w, "status check failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
}

func submitHandler(w http.ResponseWriter, r *http.Request) {
	if !submitLimiter.allow(clientIP(r)) {
		jsonError(w, "too many requests — please wait before submitting again", http.StatusTooManyRequests)
		return
	}

	assignment := r.URL.Query().Get("assignment")
	if assignment == "" {
		jsonError(w, "assignment query parameter is required", http.StatusBadRequest)
		return
	}

	if err := r.ParseMultipartForm(32 << 20); err != nil {
		jsonError(w, "invalid form data", http.StatusBadRequest)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		jsonError(w, "file is required", http.StatusBadRequest)
		return
	}
	defer file.Close()

	// Validate ZIP magic bytes (PK\x03\x04)
	var magic [4]byte
	if n, _ := file.Read(magic[:]); n < 4 || magic[0] != 'P' || magic[1] != 'K' || magic[2] != 3 || magic[3] != 4 {
		jsonError(w, "file must be a ZIP archive (.zip)", http.StatusBadRequest)
		return
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}

	email := r.FormValue("email")

	jobID, err := bg.Submit(assignment, email, file, header.Filename)
	if err != nil {
		log.Printf("bytegrader submit error: %v", err)
		jsonError(w, "submission failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"job_id": jobID})
}
