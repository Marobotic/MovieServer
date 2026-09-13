package main

import (
	"encoding/json"
	"net/http"
	"strconv"
)

// Global (server-wide) settings. These apply to every user and are only
// writable by admins. Kept in the `settings` table as key/value strings.
const (
	settingSubtitleDelayMs = "subtitle_delay_ms"
)

func (s *Server) settingInt(key string, def int) int {
	var v string
	if err := s.db.QueryRow(`SELECT value FROM settings WHERE key=?`, key).Scan(&v); err != nil {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

func (s *Server) setSettingInt(key string, n int) error {
	_, err := s.db.Exec(
		`INSERT INTO settings (key, value) VALUES (?, ?)
		 ON CONFLICT(key) DO UPDATE SET value=excluded.value`,
		key, strconv.Itoa(n))
	return err
}

func (s *Server) handleGetSettings(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, 200, map[string]any{
		"subtitle_delay_ms": s.settingInt(settingSubtitleDelayMs, 0),
	})
}

func (s *Server) handleUpdateSettings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		SubtitleDelayMs *int `json:"subtitle_delay_ms"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, 400, "invalid JSON body")
		return
	}
	if body.SubtitleDelayMs != nil {
		if err := s.setSettingInt(settingSubtitleDelayMs, *body.SubtitleDelayMs); err != nil {
			writeError(w, 500, "failed to store setting")
			return
		}
	}
	writeJSON(w, 200, map[string]any{
		"subtitle_delay_ms": s.settingInt(settingSubtitleDelayMs, 0),
	})
}