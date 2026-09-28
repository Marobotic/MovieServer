package main

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// loginGuard throttles password guessing. The server sits on a home LAN with
// no public user list, so a small in-memory counter per client address is
// enough: after maxFailures wrong passwords inside failureWindow the address
// is refused until the window rolls off. A successful login clears it.
type loginGuard struct {
	mu      sync.Mutex
	entries map[string]*guardEntry
}

type guardEntry struct {
	failures int
	first    time.Time
	lockedAt time.Time
}

const (
	maxFailures    = 8
	failureWindow  = 15 * time.Minute
	lockoutPeriod  = 15 * time.Minute
	guardSweepSize = 1024
)

func newLoginGuard() *loginGuard {
	return &loginGuard{entries: make(map[string]*guardEntry)}
}

// allowed reports whether the address may attempt a login right now, and how
// long it must wait when it may not.
func (g *loginGuard) allowed(key string) (bool, time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	e, ok := g.entries[key]
	if !ok {
		return true, 0
	}
	now := time.Now()
	if !e.lockedAt.IsZero() {
		if wait := lockoutPeriod - now.Sub(e.lockedAt); wait > 0 {
			return false, wait
		}
		delete(g.entries, key)
		return true, 0
	}
	if now.Sub(e.first) > failureWindow {
		delete(g.entries, key)
	}
	return true, 0
}

func (g *loginGuard) fail(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := time.Now()
	e, ok := g.entries[key]
	if !ok || now.Sub(e.first) > failureWindow {
		if len(g.entries) > guardSweepSize {
			g.sweepLocked(now)
		}
		g.entries[key] = &guardEntry{failures: 1, first: now}
		return
	}
	e.failures++
	if e.failures >= maxFailures && e.lockedAt.IsZero() {
		e.lockedAt = now
	}
}

func (g *loginGuard) success(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.entries, key)
}

// sweepLocked drops entries whose window and lockout have both expired.
func (g *loginGuard) sweepLocked(now time.Time) {
	for k, e := range g.entries {
		expired := now.Sub(e.first) > failureWindow
		if !e.lockedAt.IsZero() {
			expired = now.Sub(e.lockedAt) > lockoutPeriod
		}
		if expired {
			delete(g.entries, k)
		}
	}
}

// clientKey identifies the caller for throttling. Only the peer address is
// used; forwarded headers are attacker-controlled and this server is not
// behind a trusted proxy.
func clientKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return strings.TrimSpace(r.RemoteAddr)
	}
	return host
}
