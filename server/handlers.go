package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ---- response helpers ----

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func readJSON(r *http.Request, v interface{}) error {
	defer r.Body.Close()
	return json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v)
}


// ---- users ----

// handleProfiles returns the public-facing list of profiles (id, username,
// avatar) so a logged-out user can pick who they are, Netflix-style.
func (s *Server) handleProfiles(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`SELECT id, username, avatar_color FROM users ORDER BY id`)
	if err != nil {
		writeError(w, 500, "db error")
		return
	}
	defer rows.Close()
	type profile struct {
		ID          int64  `json:"id"`
		Username    string `json:"username"`
		AvatarColor string `json:"avatar_color"`
	}
	out := make([]profile, 0)
	for rows.Next() {
		var p profile
		if err := rows.Scan(&p.ID, &p.Username, &p.AvatarColor); err != nil {
			writeError(w, 500, "db error")
			return
		}
		out = append(out, p)
	}
	writeJSON(w, 200, out)
}

func (s *Server) handleListUsers(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`SELECT id, username, role, avatar_color, created_at FROM users ORDER BY id`)
	if err != nil {
		writeError(w, 500, "db error")
		return
	}
	defer rows.Close()
	out := make([]User, 0)
	for rows.Next() {
		var u User
		var created string
		if err := rows.Scan(&u.ID, &u.Username, &u.Role, &u.AvatarColor, &created); err != nil {
			writeError(w, 500, "db error")
			return
		}
		u.CreatedAt = parseDBTime(created)
		out = append(out, u)
	}
	writeJSON(w, 200, out)
}

func (s *Server) handleCreateUser(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username    string `json:"username"`
		Password    string `json:"password"`
		Role        string `json:"role"`
		AvatarColor string `json:"avatar_color"`
	}
	if err := readJSON(r, &req); err != nil {
		writeError(w, 400, "invalid body")
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	if len(req.Username) < 2 || len(req.Password) < 6 {
		writeError(w, 400, "username (>=2) and password (>=6) required")
		return
	}
	if req.Role != "admin" && req.Role != "viewer" {
		req.Role = "viewer"
	}
	if req.AvatarColor == "" {
		req.AvatarColor = randomAvatarColor()
	}
	hash, err := hashPassword(req.Password)
	if err != nil {
		writeError(w, 500, "hashing failed")
		return
	}
	res, err := s.db.Exec(`INSERT INTO users (username, password_hash, role, avatar_color) VALUES (?,?,?,?)`,
		req.Username, hash, req.Role, req.AvatarColor)
	if err != nil {
		writeError(w, 409, "username already exists")
		return
	}
	id, _ := res.LastInsertId()
	u := &User{ID: id, Username: req.Username, Role: req.Role, AvatarColor: req.AvatarColor, CreatedAt: time.Now()}
	writeJSON(w, 201, u)
}

func (s *Server) handleUpdateUser(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	var req struct {
		Password    *string `json:"password"`
		Role        *string `json:"role"`
		AvatarColor *string `json:"avatar_color"`
	}
	if err := readJSON(r, &req); err != nil {
		writeError(w, 400, "invalid body")
		return
	}
	me := currentUser(r)
	var role, color string
	s.db.QueryRow(`SELECT role, avatar_color FROM users WHERE id=?`, id).Scan(&role, &color)
	if role == "" {
		writeError(w, 404, "user not found")
		return
	}
	updates := []string{}
	args := []any{}
	if req.Password != nil {
		hash, err := hashPassword(*req.Password)
		if err != nil {
			writeError(w, 500, "hashing failed")
			return
		}
		updates = append(updates, "password_hash=?")
		args = append(args, hash)
	}
	if req.Role != nil {
		if role == "admin" && *req.Role != "admin" && me.ID == id {
			writeError(w, 400, "cannot demote yourself")
			return
		}
		if adminCount(s.db) <= 1 && role == "admin" && *req.Role != "admin" {
			writeError(w, 400, "cannot remove the last admin")
			return
		}
		role = *req.Role
		updates = append(updates, "role=?")
		args = append(args, role)
	}
	if req.AvatarColor != nil {
		color = *req.AvatarColor
		updates = append(updates, "avatar_color=?")
		args = append(args, color)
	}
	if len(updates) == 0 {
		writeError(w, 400, "nothing to update")
		return
	}
	args = append(args, id)
	s.db.Exec(`UPDATE users SET `+strings.Join(updates, ", ")+` WHERE id=?`, args...)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleDeleteUser(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	me := currentUser(r)
	if me.ID == id {
		writeError(w, 400, "cannot delete yourself")
		return
	}
	var role string
	s.db.QueryRow(`SELECT role FROM users WHERE id=?`, id).Scan(&role)
	if role == "admin" && adminCount(s.db) <= 1 {
		writeError(w, 400, "cannot delete the last admin")
		return
	}
	s.db.Exec(`DELETE FROM users WHERE id=?`, id)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func adminCount(db *sql.DB) int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM users WHERE role='admin'`).Scan(&n)
	return n
}

// ---- library ----

func (s *Server) handleMovies(w http.ResponseWriter, r *http.Request) {
	list, err := s.listMovies()
	if err != nil {
		writeError(w, 500, "db error")
		return
	}
	writeJSON(w, 200, list)
}

func (s *Server) handleShows(w http.ResponseWriter, r *http.Request) {
	list, err := s.listShows()
	if err != nil {
		writeError(w, 500, "db error")
		return
	}
	writeJSON(w, 200, list)
}

func (s *Server) handleMovieDetail(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	m, err := s.getMovie(id)
	if err != nil {
		writeError(w, 404, "movie not found")
		return
	}
	u := currentUser(r)
	if p, _ := s.progressFor(u.ID, m.ID, "movie"); p != nil {
		m.Duration = p.Duration
	}
	writeJSON(w, 200, m)
}

func (s *Server) handleShowDetail(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	sh, err := s.getShow(id)
	if err != nil {
		writeError(w, 404, "show not found")
		return
	}
	eps, err := s.episodesForShow(id)
	if err != nil {
		writeError(w, 500, "db error")
		return
	}
	u := currentUser(r)
	// attach watched state
	progress := map[string]Progress{}
	rows, _ := s.db.Query(`SELECT media_id, position, duration, completed FROM progress WHERE user_id=? AND media_kind='episode'`, u.ID)
	if rows != nil {
		defer rows.Close()
		for rows.Next() {
			var p Progress
			rows.Scan(&p.MediaID, &p.Position, &p.Duration, &p.Completed)
			progress[strconv.FormatInt(p.MediaID, 10)] = p
		}
	}
	type jsonEp struct {
		Episode
		Position       int64 `json:"position_sec"`
		Progressed     int64 `json:"watched_sec"`
		Completed      bool  `json:"completed"`
	}
	out := make([]jsonEp, 0, len(eps))
	for _, e := range eps {
		je := jsonEp{Episode: e}
		if p, ok := progress[strconv.FormatInt(e.ID, 10)]; ok {
			je.Position = p.Position
			je.Progressed = p.Position
			je.Completed = p.Completed
		}
		out = append(out, je)
	}
	writeJSON(w, 200, map[string]any{"show": sh, "episodes": out})
}

func (s *Server) handleContinueWatching(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
	list, err := s.continueWatching(u.ID)
	if err != nil {
		writeError(w, 500, "db error")
		return
	}
	writeJSON(w, 200, list)
}

func (s *Server) handleProgress(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
	var req struct {
		MediaKind string `json:"media_kind"`
		MediaID   int64  `json:"media_id"`
		Position  int64  `json:"position"`
		Duration  int64  `json:"duration"`
		Completed bool   `json:"completed"`
	}
	if err := readJSON(r, &req); err != nil {
		writeError(w, 400, "invalid body")
		return
	}
	if req.MediaKind != "movie" && req.MediaKind != "episode" {
		writeError(w, 400, "media_kind must be movie or episode")
		return
	}
	if err := s.saveProgress(u.ID, req.MediaKind, req.MediaID, req.Position, req.Duration, req.Completed); err != nil {
		writeError(w, 500, "db error")
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleClearProgress(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
	q := r.URL.Query()
	kind := q.Get("media_kind")
	id, _ := strconv.ParseInt(q.Get("media_id"), 10, 64)
	if kind == "" || id == 0 {
		writeError(w, 400, "media_kind and media_id required")
		return
	}
	s.clearProgress(u.ID, kind, id)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	movies, _ := s.listMovies()
	shows, _ := s.listShows()
	var mv = []Movie{}
	var sh = []Show{}
	for _, m := range movies {
		if q == "" || strings.Contains(strings.ToLower(m.Title), q) {
			mv = append(mv, m)
		}
	}
	for _, s := range shows {
		if q == "" || strings.Contains(strings.ToLower(s.Title), q) {
			sh = append(sh, s)
		}
	}
	writeJSON(w, 200, map[string]any{"movies": mv, "shows": sh})
}

// ---- admin ----

func (s *Server) handleScan(w http.ResponseWriter, r *http.Request) {
	res, err := s.scanLibrary()
	if err != nil {
		writeError(w, 500, "scan failed: "+err.Error())
		return
	}
	go s.enrichLibrary()
	writeJSON(w, 200, res)
}

func (s *Server) handleAsset(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	dest := filepath.Join(s.conf.DataDir, "covers", filepath.Base(name))
	f, err := os.Open(dest)
	if err != nil || !fileExists(dest) {
		writeError(w, 404, "not found")
		if f != nil {
			f.Close()
		}
		return
	}
	defer f.Close()
	http.ServeContent(w, r, filepath.Base(dest), time.Time{}, f)
}

// handleTMDBSearch lets clients search TMDB for title + trailer info.
func (s *Server) handleTMDBSearch(w http.ResponseWriter, r *http.Request) {
	if s.conf.TMDbAPIKey == "" {
		writeError(w, 503, "TMDB API key not configured")
		return
	}
	q := r.URL.Query().Get("q")
	if strings.TrimSpace(q) == "" {
		writeError(w, 400, "q required")
		return
	}
	kind := r.URL.Query().Get("type")
	if kind == "" {
		kind = "movie"
	}
	c := s.tmdb()
	out := make([]map[string]any, 0)
	if kind == "tv" {
		res, err := c.searchTV(q, 0)
		if err != nil {
			writeError(w, 502, err.Error())
			return
		}
		for _, r := range res {
			out = append(out, map[string]any{"tmdb_id": r.ID, "title": r.Name, "year": derpYear(r.FirstAirDate), "overview": r.Overview, "poster": tmdbThumb(r.PosterPath, "w342"), "type": "show"})
		}
	} else {
		res, err := c.searchMovie(q, 0)
		if err != nil {
			writeError(w, 502, err.Error())
			return
		}
		for _, r := range res {
			out = append(out, map[string]any{"tmdb_id": r.ID, "title": r.Title, "year": derpYear(r.ReleaseDate), "overview": r.Overview, "poster": tmdbThumb(r.PosterPath, "w342"), "type": "movie"})
		}
	}
	writeJSON(w, 200, out)
}

func tmdbThumb(path, size string) string {
	if path == "" {
		return ""
	}
	return posterURL(path, size)
}

// handleUpload stores a video file into the library and rescans.
func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	kind := r.FormValue("kind")
	if kind != "movie" && kind != "show" {
		writeError(w, 400, "kind must be movie or show")
		return
	}
	r.ParseMultipartForm(1 << 30) // allow up to 1GB in RAM, streams remainder to disk
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, 400, "file part missing")
		return
	}
	defer file.Close()

	name := filepath.Base(header.Filename)
	if !isVideo(name) {
		writeError(w, 400, "not a video file")
		return
	}

	var dest string
	if kind == "movie" {
		dest = filepath.Join(s.conf.MediaDir, "Movies", name)
		os.MkdirAll(filepath.Dir(dest), 0o755)
	} else {
		showTitle := strings.TrimSpace(r.FormValue("show_title"))
		season := r.FormValue("season")
		if showTitle == "" {
			writeError(w, 400, "show_title required for shows")
			return
		}
		if season == "" {
			season = "1"
		}
		sub := "Season " + season
		if n, err := strconv.Atoi(season); err == nil {
			sub = fmt.Sprintf("Season %02d", n)
		}
		dest = filepath.Join(s.conf.MediaDir, "Shows", showTitle, sub, name)
		os.MkdirAll(filepath.Dir(dest), 0o755)
	}

	out, err := os.Create(dest)
	if err != nil {
		writeError(w, 500, "cannot create file")
		return
	}
	defer out.Close()
	if _, err := io.Copy(out, file); err != nil {
		writeError(w, 500, "upload failed")
		return
	}
	res, _ := s.scanLibrary()
	writeJSON(w, 200, res)
}

// ---- requests ----

func (s *Server) handleCreateRequest(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
	var req struct {
		Kind   string `json:"kind"`
		Title  string `json:"title"`
		Year   int    `json:"year"`
		Note   string `json:"note"`
		TMDbID int    `json:"tmdb_id"`
	}
	if err := readJSON(r, &req); err != nil {
		writeError(w, 400, "invalid body")
		return
	}
	req.Title = strings.TrimSpace(req.Title)
	if req.Kind != "movie" && req.Kind != "show" {
		req.Kind = "movie"
	}
	if req.Title == "" {
		writeError(w, 400, "title required")
		return
	}
	res, err := s.db.Exec(`INSERT INTO requests (user_id, kind, title, year, note, status, tmdb_id) VALUES (?,?,?,?,?,'pending',?)`,
		u.ID, req.Kind, req.Title, req.Year, req.Note, req.TMDbID)
	if err != nil {
		writeError(w, 500, "db error")
		return
	}
	id, _ := res.LastInsertId()
	writeJSON(w, 201, map[string]int64{"id": id})
}

func (s *Server) handleListRequests(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
	var query = "SELECT r.id, r.user_id, r.kind, r.title, r.year, r.note, r.status, r.tmdb_id, r.created_at, us.username FROM requests r JOIN users us ON us.id = r.user_id"
	var args []any
	if u.Role != "admin" {
		if q := r.URL.Query().Get("status"); q != "" {
			query += " WHERE r.user_id=? AND r.status=?"
			args = append(args, u.ID, q)
		} else {
			query += " WHERE r.user_id=?"
			args = append(args, u.ID)
		}
	} else if q := r.URL.Query().Get("status"); q != "" {
		query += " WHERE r.status=?"
		args = append(args, q)
	}
	query += " ORDER BY r.created_at DESC"
	rows, err := s.db.Query(query, args...)
	if err != nil {
		writeError(w, 500, "db error")
		return
	}
	defer rows.Close()
	out := make([]Request, 0)
	for rows.Next() {
		var req Request
		var created string
		if err := rows.Scan(&req.ID, &req.UserID, &req.Kind, &req.Title, &req.Year, &req.Note, &req.Status, &req.TMDbID, &created, &req.Username); err != nil {
			continue
		}
		req.CreatedAt = parseDBTime(created)
		out = append(out, req)
	}
	writeJSON(w, 200, out)
}

func (s *Server) handleUpdateRequest(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	var req struct {
		Status string `json:"status"`
	}
	if err := readJSON(r, &req); err != nil {
		writeError(w, 400, "invalid body")
		return
	}
	switch req.Status {
	case "approved", "denied", "pending":
	default:
		writeError(w, 400, "status must be approved/denied/pending")
		return
	}
	res, err := s.db.Exec(`UPDATE requests SET status=? WHERE id=?`, req.Status, id)
	if err != nil {
		writeError(w, 500, "db error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeError(w, 404, "not found")
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) handleDeleteRequest(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	u := currentUser(r)
	query := `DELETE FROM requests WHERE id=?`
	args := []any{id}
	if u.Role != "admin" {
		query += ` AND user_id=?`
		args = append(args, u.ID)
	}
	s.db.Exec(query, args...)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func randomAvatarColor() string {
	palette := []string{"#E50914", "#0D7C66", "#3D5AFE", "#9C27B0", "#F9A825", "#00897B", "#FF5722", "#5E35B1"}
	return palette[time.Now().UnixNano()%int64(len(palette))]
}