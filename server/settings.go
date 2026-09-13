package main

import (
	"encoding/json"
	"net/http"
	"strconv"
)

// Subtitle delay is stored per media item (movie or episode). Every user sees
// the same delay for a given item; only admins can change it.
func (s *Server) subtitleDelay(kind string, id int64) int {
	var ms int
	err := s.db.QueryRow(
		`SELECT subtitle_delay_ms FROM subtitle_delays WHERE kind=? AND media_id=?`,
		kind, id).Scan(&ms)
	if err != nil {
		return 0
	}
	return ms
}

func (s *Server) setSubtitleDelay(kind string, id int64, ms int) error {
	_, err := s.db.Exec(
		`INSERT INTO subtitle_delays (kind, media_id, subtitle_delay_ms) VALUES (?, ?, ?)
		 ON CONFLICT(kind, media_id) DO UPDATE SET subtitle_delay_ms=excluded.subtitle_delay_ms`,
		kind, id, ms)
	return err
}

func (s *Server) handleGetSubtitleDelay(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	writeJSON(w, 200, map[string]any{
		"subtitle_delay_ms": s.subtitleDelay(kind, id),
	})
}

func (s *Server) handleUpdateSubtitleDelay(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	var body struct {
		SubtitleDelayMs *int `json:"subtitle_delay_ms"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, 400, "invalid JSON body")
		return
	}
	if body.SubtitleDelayMs == nil {
		writeError(w, 400, "missing subtitle_delay_ms")
		return
	}
	if err := s.setSubtitleDelay(kind, id, *body.SubtitleDelayMs); err != nil {
		writeError(w, 500, "failed to store subtitle delay")
		return
	}
	writeJSON(w, 200, map[string]any{
		"subtitle_delay_ms": s.subtitleDelay(kind, id),
	})
}