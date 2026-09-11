package main

import (
	"database/sql"
	"errors"
	"time"
)

// ---- movie queries ----

func scanMovie(rows interface{ Scan(...any) error }, m *Movie) error {
	var added string
	err := rows.Scan(&m.ID, &m.Title, &m.Year, &m.FilePath, &m.SizeBytes, &m.Overview,
		&m.Poster, &m.Backdrop, &m.TrailerURL, &m.Duration, &m.TMDbID, &added)
	if err != nil {
		return err
	}
	m.AddedAt = parseDBTime(added)
	return nil
}

const movieCols = `id, title, year, file_path, size_bytes, overview, poster, backdrop, trailer_url, duration_sec, tmdb_id, added_at`

func (s *Server) listMovies() ([]Movie, error) {
	rows, err := s.db.Query(`SELECT ` + movieCols + ` FROM movies ORDER BY title COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Movie, 0)
	for rows.Next() {
		var m Movie
		if err := scanMovie(rows, &m); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (s *Server) getMovie(id int64) (*Movie, error) {
	row := s.db.QueryRow(`SELECT `+movieCols+` FROM movies WHERE id = ?`, id)
	var m Movie
	if err := scanMovie(row, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

// ---- show / episode queries ----

func (s *Server) listShows() ([]Show, error) {
	rows, err := s.db.Query(`SELECT id, title, year, overview, poster, backdrop, trailer_url, tmdb_id, added_at FROM shows ORDER BY title COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Show, 0)
	for rows.Next() {
		var sh Show
		var added string
		if err := rows.Scan(&sh.ID, &sh.Title, &sh.Year, &sh.Overview, &sh.Poster, &sh.Backdrop, &sh.TrailerURL, &sh.TMDbID, &added); err != nil {
			return nil, err
		}
		sh.AddedAt = parseDBTime(added)
		out = append(out, sh)
	}
	return out, rows.Err()
}

func (s *Server) getShow(id int64) (*Show, error) {
	row := s.db.QueryRow(`SELECT id, title, year, overview, poster, backdrop, trailer_url, tmdb_id, added_at FROM shows WHERE id = ?`, id)
	var sh Show
	var added string
	if err := row.Scan(&sh.ID, &sh.Title, &sh.Year, &sh.Overview, &sh.Poster, &sh.Backdrop, &sh.TrailerURL, &sh.TMDbID, &added); err != nil {
		return nil, err
	}
	sh.AddedAt = parseDBTime(added)
	return &sh, nil
}

func (s *Server) episodesForShow(showID int64) ([]Episode, error) {
	rows, err := s.db.Query(`SELECT id, show_id, season, episode, title, overview, still, file_path, size_bytes, duration_sec FROM episodes WHERE show_id = ? ORDER BY season, episode`, showID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Episode, 0)
	for rows.Next() {
		var e Episode
		if err := rows.Scan(&e.ID, &e.ShowID, &e.Season, &e.Episode, &e.Title, &e.Overview, &e.Still, &e.FilePath, &e.SizeBytes, &e.Duration); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (s *Server) getEpisode(id int64) (*Episode, error) {
	row := s.db.QueryRow(`SELECT ep.id, ep.show_id, ep.season, ep.episode, ep.title, ep.overview, ep.still, ep.file_path, ep.size_bytes, ep.duration_sec, sh.title, sh.trailer_url
		FROM episodes ep JOIN shows sh ON sh.id = ep.show_id WHERE ep.id = ?`, id)
	e := &Episode{}
	if err := row.Scan(&e.ID, &e.ShowID, &e.Season, &e.Episode, &e.Title, &e.Overview, &e.Still, &e.FilePath, &e.SizeBytes, &e.Duration, &e.ShowTitle, &e.TrailerURL); err != nil {
		return nil, err
	}
	return e, nil
}

// ---- progress ----

type watchedKey struct{ kind string; id int64 }

func (s *Server) saveProgress(userID int64, kind string, mediaID, pos, dur int64, completed bool) error {
	_, err := s.db.Exec(`INSERT INTO progress (user_id, media_kind, media_id, position, duration, completed, updated_at)
		VALUES (?,?,?,?,?,?,CURRENT_TIMESTAMP)
		ON CONFLICT(user_id, media_kind, media_id) DO UPDATE SET
			position=excluded.position, duration=excluded.duration, completed=excluded.completed, updated_at=CURRENT_TIMESTAMP`,
		userID, kind, mediaID, pos, dur, boolToInt(completed))
	return err
}

func (s *Server) clearProgress(userID int64, kind string, mediaID int64) error {
	_, err := s.db.Exec(`DELETE FROM progress WHERE user_id=? AND media_kind=? AND media_id=?`, userID, kind, mediaID)
	return err
}

// continueWatching returns movies and episodes the user has started but not finished.
func (s *Server) continueWatching(userID int64) ([]Progress, error) {
	rows, err := s.db.Query(`SELECT media_kind, media_id, position, duration, completed FROM progress WHERE user_id=? AND completed=0 ORDER BY updated_at DESC LIMIT 40`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Progress, 0)
	for rows.Next() {
		var p Progress
		if err := rows.Scan(&p.MediaKind, &p.MediaID, &p.Position, &p.Duration, &p.Completed); err != nil {
			return nil, err
		}
		switch p.MediaKind {
		case "movie":
			m, err := s.getMovie(p.MediaID)
			if err != nil || m == nil {
				continue
			}
			p.Title, p.Poster = m.Title, m.Poster
		case "episode":
			e, err := s.getEpisode(p.MediaID)
			if err != nil || e == nil {
				continue
			}
			p.ShowID = e.ShowID
			p.Season = e.Season
			p.Episode = e.Episode
			p.Title = e.ShowTitle + " - " + e.Title
			p.Poster = e.Still
			if p.Poster == "" {
				if sh, err := s.getShow(e.ShowID); err == nil {
					p.Poster = sh.Poster
				}
			}
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Server) progressFor(userID, mediaID int64, kind string) (*Progress, error) {
	p := &Progress{}
	err := s.db.QueryRow(`SELECT media_kind, media_id, position, duration, completed FROM progress WHERE user_id=? AND media_kind=? AND media_id=?`,
		userID, kind, mediaID).Scan(&p.MediaKind, &p.MediaID, &p.Position, &p.Duration, &p.Completed)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return p, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

var _ = time.Now