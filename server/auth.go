package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

type contextKey string

const userKey contextKey = "user"

// ---- utilities ----

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func hashPassword(pw string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	return string(b), err
}

func checkPassword(hash, pw string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(pw)) == nil
}

// ---- JWT ----

func issueToken(secret string, u User) (string, error) {
	claims := jwt.MapClaims{
		"sub": u.ID,
		"usr": u.Username,
		"rol": u.Role,
		"exp": time.Now().Add(30 * 24 * time.Hour).Unix(),
		"iat": time.Now().Unix(),
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
}

// authMiddleware validates the Bearer token and injects the user.
func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, ok := s.authenticate(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, "not authenticated")
			return
		}
		ctx := context.WithValue(r.Context(), userKey, u)
		next(w, r.WithContext(ctx))
	}
}

func (s *Server) authenticate(r *http.Request) (*User, bool) {
	h := r.Header.Get("Authorization")
	tokenStr := ""
	if strings.HasPrefix(h, "Bearer ") {
		tokenStr = strings.TrimPrefix(h, "Bearer ")
	} else if q := r.URL.Query().Get("token"); q != "" {
		// players (e.g. <video> elements and native players) cannot always set
		// headers, so also accept the bearer token as a query parameter.
		tokenStr = q
	}
	if tokenStr == "" {
		return nil, false
	}

	token, err := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method")
		}
		return []byte(s.conf.JWTSecret), nil
	})
	if err != nil || !token.Valid {
		return nil, false
	}
	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		return nil, false
	}
	id, ok := claims["sub"].(float64)
	if !ok {
		return nil, false
	}
	u, err := s.getUserByID(int64(id))
	if err != nil {
		return nil, false
	}
	return u, true
}

func currentUser(r *http.Request) *User {
	u, _ := r.Context().Value(userKey).(*User)
	return u
}

// requireAdmin wraps authMiddleware and enforces the admin role.
func (s *Server) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return s.authMiddleware(func(w http.ResponseWriter, r *http.Request) {
		u := currentUser(r)
		if u == nil || u.Role != "admin" {
			writeError(w, http.StatusForbidden, "admin only")
			return
		}
		next(w, r)
	})
}

// ---- user helpers ----

func (s *Server) getUserByID(id int64) (*User, error) {
	row := s.db.QueryRow(`SELECT id, username, password_hash, role, avatar_color, audio_lang, created_at FROM users WHERE id = ?`, id)
	u := &User{}
	var created string
	err := row.Scan(&u.ID, &u.Username, &u.Password, &u.Role, &u.AvatarColor, &u.AudioLang, &created)
	if err != nil {
		return nil, err
	}
	u.CreatedAt = parseDBTime(created)
	return u, nil
}

func parseDBTime(t string) time.Time {
	for _, layout := range []string{"2006-01-02 15:04:05", time.RFC3339, "2006-01-02T15:04:05Z"} {
		if parsed, err := time.Parse(layout, t); err == nil {
			return parsed
		}
	}
	return time.Now()
}

// ---- handlers ----

// handleSetup creates the first admin user. Only works when no users exist.
func (s *Server) handleSetup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	if len(req.Username) < 2 || len(req.Password) < 6 {
		writeError(w, http.StatusBadRequest, "username (>=2 chars) and password (>=6 chars) required")
		return
	}

	var count int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&count); err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	if count > 0 {
		writeError(w, http.StatusConflict, "setup already done")
		return
	}

	hash, err := hashPassword(req.Password)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "hashing failed")
		return
	}
	res, err := s.db.Exec(`INSERT INTO users (username, password_hash, role, avatar_color) VALUES (?, ?, 'admin', '#E50914')`, req.Username, hash)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create admin")
		return
	}
	id, _ := res.LastInsertId()
	u := &User{ID: id, Username: req.Username, Role: "admin", AvatarColor: "#E50914"}
	tok, err := issueToken(s.conf.JWTSecret, *u)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token issue failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": tok, "user": u, "needs_setup": false})
}

// dummyHash is compared against when the username does not exist, so a wrong
// username costs the same bcrypt work as a wrong password and cannot be told
// apart by response time.
var dummyHash = func() []byte {
	h, err := bcrypt.GenerateFromPassword([]byte(randomHex(16)), bcrypt.DefaultCost)
	if err != nil {
		return nil
	}
	return h
}()

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	key := clientKey(r)
	if ok, wait := s.guard.allowed(key); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		writeError(w, http.StatusTooManyRequests, "too many failed attempts, try again later")
		return
	}

	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := readJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	row := s.db.QueryRow(`SELECT id, username, password_hash, role, avatar_color, audio_lang, created_at FROM users WHERE username = ?`, strings.TrimSpace(req.Username))
	u := &User{}
	var created string
	err := row.Scan(&u.ID, &u.Username, &u.Password, &u.Role, &u.AvatarColor, &u.AudioLang, &created)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}

	// Always spend the bcrypt work, whether or not the account exists.
	found := err == nil
	var ok bool
	if found {
		ok = checkPassword(u.Password, req.Password)
	} else {
		bcrypt.CompareHashAndPassword(dummyHash, []byte(req.Password))
		ok = false
	}
	if !ok {
		s.guard.fail(key)
		writeError(w, http.StatusUnauthorized, "invalid username or password")
		return
	}

	s.guard.success(key)
	u.CreatedAt = parseDBTime(created)
	tok, err := issueToken(s.conf.JWTSecret, *u)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token issue failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": tok, "user": u})
}

// who is the currently logged-in user (helper the frontend can trust)
func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, currentUser(r))
}

// platformCapabilities lets clients know this instance is ready.
func (s *Server) handleCapabilities(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"needs_setup":     s.userCount() == 0,
		"tmdb_configured": s.conf.TMDbAPIKey != "",
		"version":         s.version,
	})
}

func (s *Server) userCount() int {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n)
	return n
}
