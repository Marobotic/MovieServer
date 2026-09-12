package main

import (
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// logRing is a fixed-size, thread-safe buffer of recent log lines so the admin
// panel can show server logs without touching the filesystem or journald.
type logRing struct {
	mu    sync.Mutex
	buf   []string
	times []time.Time
	max   int
	start int
	n     int
}

func newLogRing(max int) *logRing {
	return &logRing{buf: make([]string, max), times: make([]time.Time, max), max: max}
}

func (r *logRing) Write(p []byte) (int, error) {
	line := strings.TrimRight(string(p), "\n\r")
	if line == "" {
		return len(p), nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.n < r.max {
		i := (r.start + r.n) % r.max
		r.buf[i] = line
		r.times[i] = time.Now()
		r.n++
	} else {
		r.buf[r.start] = line
		r.times[r.start] = time.Now()
		r.start = (r.start + 1) % r.max
	}
	return len(p), nil
}

// snapshot returns the most recent lines, newest first.
func (r *logRing) snapshot() []logLine {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]logLine, 0, r.n)
	for i := 0; i < r.n; i++ {
		idx := (r.start + i) % r.max
		out = append(out, logLine{Time: r.times[idx], Text: r.buf[idx]})
	}
	// newest first
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

type logLine struct {
	Time time.Time `json:"time"`
	Text string    `json:"text"`
}

var serverLogs = newLogRing(4000)

func (s *Server) handleAdminLogs(w http.ResponseWriter, r *http.Request) {
	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 2000 {
			limit = n
		}
	}
	q := strings.ToLower(r.URL.Query().Get("q"))
	lines := serverLogs.snapshot()
	if q != "" {
		filtered := lines[:0]
		for _, l := range lines {
			if strings.Contains(strings.ToLower(l.Text), q) {
				filtered = append(filtered, l)
			}
		}
		lines = filtered
	}
	if len(lines) > limit {
		lines = lines[:limit]
	}
	writeJSON(w, 200, map[string]any{
		"lines": lines,
		"limit": limit,
	})
}
