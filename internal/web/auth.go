package web

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const (
	sessionCookie = "minordlna_session"
	sessionTTL    = 30 * 24 * time.Hour
	maxFailures   = 5
	lockout       = time.Minute
)

// sessions outlive in-process restarts (settings saves), so remote users stay logged in.
var sessions = &sessionStore{tokens: map[string]time.Time{}, failures: map[string]failure{}}

type failure struct {
	count int
	until time.Time
}

type sessionStore struct {
	mu       sync.Mutex
	tokens   map[string]time.Time
	failures map[string]failure
}

func (s *sessionStore) create(w http.ResponseWriter) {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	token := hex.EncodeToString(b)
	s.mu.Lock()
	now := time.Now()
	for t, exp := range s.tokens {
		if now.After(exp) {
			delete(s.tokens, t)
		}
	}
	s.tokens[token] = now.Add(sessionTTL)
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: token, Path: "/", MaxAge: int(sessionTTL.Seconds()),
		HttpOnly: true, SameSite: http.SameSiteStrictMode})
}

func (s *sessionStore) valid(r *http.Request) bool {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	exp, ok := s.tokens[c.Value]
	return ok && time.Now().Before(exp)
}

func (s *sessionStore) drop(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookie); err == nil {
		s.mu.Lock()
		delete(s.tokens, c.Value)
		s.mu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteStrictMode})
}

// allow reports whether the client may try a password now (brute-force protection).
func (s *sessionStore) allow(ip string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	f := s.failures[ip]
	return f.count < maxFailures || time.Now().After(f.until)
}

func (s *sessionStore) record(ip string, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ok {
		delete(s.failures, ip)
		return
	}
	f := s.failures[ip]
	if time.Now().After(f.until) && f.count >= maxFailures {
		f.count = 0
	}
	f.count++
	f.until = time.Now().Add(lockout)
	s.failures[ip] = f
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !s.remoteEnabled() {
		writeError(w, "Přístup z jiných zařízení je vypnutý.")
		return
	}
	if !sessions.allow(ip) {
		writeError(w, "Příliš mnoho pokusů, zkuste to za minutu.")
		return
	}
	var req struct {
		Password string `json:"password"`
	}
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req)
	ok := bcrypt.CompareHashAndPassword([]byte(s.Cfg.Remote.PasswordHash), []byte(req.Password)) == nil
	sessions.record(ip, ok)
	if !ok {
		slog.Warn("failed login", "remote", ip)
		writeError(w, "Nesprávné heslo.")
		return
	}
	sessions.create(w)
	writeJSON(w, map[string]bool{"ok": true})
}
