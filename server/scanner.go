package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var videoExts = map[string]bool{
	".mp4": true, ".m4v": true, ".mkv": true, ".avi": true, ".mov": true,
	".webm": true, ".wmv": true, ".flv": true, ".ts": true, ".mpg": true,
	".mpeg": true, ".3gp": true,
}

var (
	yearRe         = regexp.MustCompile(`.*?[\(\[]?\s*((?:19|20)\d{2})\s*[\)\]]?.*`)
	seasonFolderRe = regexp.MustCompile(`(?i)(?:season[\s._-]*|s)(\d{1,2})`)
	episodeNameRe  = regexp.MustCompile(`(?i)[sS](\d{1,2})[eE](\d{1,3})`)
	episodeXRe     = regexp.MustCompile(`(?i)(?:^|[^0-9])(\d{1,2})[xX](\d{1,3})`)
	episodeWordRe  = regexp.MustCompile(`(?i)(?:episode|ep)[\s._-]?(\d{1,3})`)
	releaseTagRe   = regexp.MustCompile(`(?i)\b(?:720p|1080p|2160p|480p|360p|1440p|uhd|hdr10?|dovi|sdr|web-?rip|web-?dl|webdl|blu-?ray|brrip|bdrip|hdtv|dvdr|dvd?rip|hdrip|remux|amzn|nf|netflix|disney(?:\.\+)?|german|french|francais|français|ita|italian|english|eng|spanish|espa[ñn]ol|castellano|sub(?:bed)?|x264|x265|h264|h265|hevc|avc|av1|vp9|vp8|aac|ac3|dts(?:-hd)?|flac|truehd|10bit|8bit|proper|repack|extended|unrated|imax|uncut|multi|dual|hardcoded|\d{3,4}p|\d+mb|\d+bit)\b`)
	audioNumRe     = regexp.MustCompile(`(?i)\b(?:dd\s?5?[.\s]?1|ddp5?[.\s]?1|5[.\s]?1|7[.\s]?1)\b`)
	bracketTagRe   = regexp.MustCompile(`[\[\(][^\]\)]*[\]\)]`)
)

// releaseGroups lists common release-group names that end filenames.
var releaseGroups = map[string]bool{
	"yify": true, "yts": true, "ytsag": true, "ytis": true, "galaxyrg": true,
	"galaxy": true, "mircrew": true, "gaz": true, "ozlem": true, "tigole": true,
	"etrg": true, "fgt": true, "x0rbit": true, "ctrlhd": true, "sp33dy94": true,
	"aspide": true, "amiable": true, "pwn": true, "rips": true,
}

// isReleaseGroup reports whether a trailing title token looks like a release
// group: an exact known name, or a long name with digits (e.g. GalaxyRG265).
func isReleaseGroup(tok string) bool {
	low := strings.ToLower(tok)
	if releaseGroups[low] {
		return true
	}
	if len(low) >= 5 && strings.ContainsAny(low, "0123456789") {
		for g := range releaseGroups {
			if g != "galaxy" && strings.HasPrefix(low, g) {
				return true
			}
		}
	}
	return false
}

func isVideo(f string) bool { return videoExts[strings.ToLower(filepath.Ext(f))] }

// cleanTitle converts filenames like "The.Wire.2002" into "The Wire",
// stripping release tags, groups, and bracket noise.
func cleanTitle(s string) string {
	s = strings.TrimSpace(s)
	s = bracketTagRe.ReplaceAllString(s, " ")
	s = audioNumRe.ReplaceAllString(s, " ")
	s = strings.ReplaceAll(s, "_", " ")
	s = strings.ReplaceAll(s, ".", " ")
	s = strings.ReplaceAll(s, "-", " ")
	// collapse whitespace
	s = strings.Join(strings.Fields(s), " ")
	// strip quality/release tags, then a trailing release group
	s = releaseTagRe.ReplaceAllString(s, " ")
	fields := strings.Fields(s)
	for len(fields) > 1 && isReleaseGroup(fields[len(fields)-1]) {
		fields = fields[:len(fields)-1]
	}
	s = releaseTagRe.ReplaceAllString(strings.Join(fields, " "), " ")
	s = strings.Join(strings.Fields(s), " ")
	// strip trailing season/episode marker like "S01" or "Season 1"
	s = strings.TrimSpace(s)
	return s
}

// extractYear pulls a 4-digit year from a string.
func extractYear(s string) int {
	m := yearRe.FindStringSubmatch(s)
	if m == nil {
		return 0
	}
	y, _ := strconv.Atoi(m[1])
	if y > 1900 && y < 2100 {
		return y
	}
	return 0
}

// stripYearMark removes " (2014)" and similar from a title string.
func stripYearMark(s string) string {
	re := regexp.MustCompile(`[\(\[]?\s*(?:19|20)\d{2}\s*[\)\]]?`)
	return strings.TrimSpace(re.ReplaceAllString(s, ""))
}

type scanResult struct {
	Movies   int `json:"movies"`
	Shows    int `json:"shows"`
	Episodes int `json:"episodes"`
}

// scanLibrary walks the media folders and syncs the DB.
func (s *Server) scanLibrary() (*scanResult, error) {
	res := &scanResult{}
	movieDir := filepath.Join(s.conf.MediaDir, "Movies")
	showDir := filepath.Join(s.conf.MediaDir, "Shows")

	seenMovies, err := s.scanMovies(movieDir)
	if err != nil {
		return res, err
	}
	res.Movies = len(seenMovies)
	shows, eps, err := s.scanShows(showDir)
	if err != nil {
		return res, err
	}
	res.Shows = shows
	res.Episodes = eps

	// prune movies that disappeared from disk
	if err := s.pruneMovies(movieDir); err != nil {
		return res, err
	}
	// prune episodes whose files vanished
	if err := s.pruneEpisodes(showDir); err != nil {
		return res, err
	}
	return res, nil
}

func (s *Server) scanMovies(dir string) (map[string]bool, error) {
	seen := map[string]bool{}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return seen, err
	}
	for _, e := range entries {
		full := filepath.Join(dir, e.Name())
		if e.IsDir() {
			// folder-based movie: Movies/Interstellar (2014)/
			if s.scanMovieDir(full, e.Name()) {
				seen[relPath(s.conf.MediaDir, full)] = true
			}
		} else if isVideo(e.Name()) {
			// loose file: Movies/Interstellar.mkv
			title := cleanTitle(stripYearMark(strings.TrimSuffix(e.Name(), filepath.Ext(e.Name()))))
			year := extractYear(e.Name())
			if title == "" {
				continue
			}
			s.upsertMovie(startMovie(title, year, full, 0), false)
			if id := s.movieIDByPath(relPath(s.conf.MediaDir, full)); id != 0 {
				stem := strings.TrimSuffix(filepath.Base(full), filepath.Ext(filepath.Base(full)))
				s.setLocalArt("movie", id, dir, stem)
			}
			seen[relPath(s.conf.MediaDir, full)] = true
		}
	}
	return seen, nil
}

// scanMovieDir handles a movie inside a subfolder; returns true if a video was found.
func (s *Server) scanMovieDir(dir, name string) bool {
	title := cleanTitle(stripYearMark(name))
	year := extractYear(name)
	best := ""
	var bestSize int64
	fs, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, f := range fs {
		if f.IsDir() || !isVideo(f.Name()) {
			continue
		}
		fp := filepath.Join(dir, f.Name())
		fi, err := f.Info()
		sz := int64(0)
		if err == nil {
			sz = fi.Size()
		}
		if sz > bestSize {
			bestSize = sz
			best = fp
		}
	}
	if best == "" {
		return false
	}
	if title == "" {
		title = cleanTitle(stripYearMark(strings.TrimSuffix(filepath.Base(best), filepath.Ext(best))))
	}
	s.upsertMovie(startMovie(title, year, best, 0), false)
	if id := s.movieIDByPath(relPath(s.conf.MediaDir, best)); id != 0 {
		s.setLocalArt("movie", id, dir, "")
	}
	return true
}

// probeMovie inspects a movie file at scan time: returns its duration in
// seconds and whether the file is unreadable/corrupt (ffprobe cannot parse it).
func (s *Server) probeMovie(full string) (int64, bool) {
	d, err := ffprobeDuration(full)
	if err != nil {
		return 0, true
	}
	return d, d <= 0
}

func startMovie(title string, year int, path string, size int64) *Movie {
	if size == 0 {
		if fi, err := os.Stat(path); err == nil {
			size = fi.Size()
		}
	}
	return &Movie{Title: title, FileTitle: title, Year: year, FilePath: path, SizeBytes: size}
}

// ffprobeDuration returns the length of a media file in seconds.
func ffprobeDuration(full string) (int64, error) {
	probe, err := exec.LookPath("ffprobe")
	if err != nil {
		return 0, fmt.Errorf("ffprobe not found")
	}
	out, err := exec.Command(probe, "-v", "error",
		"-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1", full).Output()
	if err != nil {
		return 0, err
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	if err != nil {
		return 0, err
	}
	return int64(f), nil
}

func (s *Server) upsertMovie(m *Movie, metadataOnly bool) {
	rel := m.FilePath
	// always store a path relative to the media root
	if filepath.IsAbs(rel) {
		if r, err := filepath.Rel(s.conf.MediaDir, rel); err == nil {
			rel = r
		} else {
			rel = filepath.Base(rel)
		}
	}
	year := m.Year
	var existing *Movie
	if e, err := s.lookupMovieByPath(rel); err == nil {
		existing = e
	}
	if existing != nil && metadataOnly {
		upd := strings.Builder{}
		upd.WriteString("UPDATE movies SET ")
		var args []any
		if m.Overview != "" && existing.Overview == "" {
			upd.WriteString("overview=?, ")
			args = append(args, m.Overview)
		}
		if m.Poster != "" && existing.Poster == "" {
			upd.WriteString("poster=?, ")
			args = append(args, m.Poster)
		}
		if m.Backdrop != "" && existing.Backdrop == "" {
			upd.WriteString("backdrop=?, ")
			args = append(args, m.Backdrop)
		}
		if m.Title != "" {
			upd.WriteString("title=?, ")
			args = append(args, m.Title)
		}
		upd.WriteString("trailer_url=?, tmdb_id=?, year=? WHERE id=?")
		args = append(args, m.TrailerURL, m.TMDbID, year, existing.ID)
		s.db.Exec(upd.String(), args...)
		return
	}
	if existing != nil {
		// refresh file metadata, but never clobber a TMDB-matched title/year on
		// a plain rescan (file_title stays the on-disk name).
		full := existing.FilePath
		if resolved, err := resolveRel(s.conf.MediaDir, existing.FilePath); err == nil {
			full = resolved
		}
		dur, broken := s.probeMovie(full)
		_, err := s.db.Exec(`UPDATE movies SET file_title=?, size_bytes=?, duration_sec=?, broken=? WHERE id=?`,
			m.FileTitle, m.SizeBytes, dur, boolInt(broken), existing.ID)
		if err != nil {
			fmt.Println("upsert movie:", err)
		}
		if existing.TMDbID == 0 {
			if existing.Title != m.Title {
				s.db.Exec(`UPDATE movies SET title=? WHERE id=?`, m.Title, existing.ID)
			}
			if existing.Year != year {
				s.db.Exec(`UPDATE movies SET year=? WHERE id=?`, year, existing.ID)
			}
		}
		return
	}
	dur, broken := s.probeMovie(filepath.Join(s.conf.MediaDir, rel))
	res, err := s.db.Exec(`INSERT INTO movies (title, file_title, year, file_path, size_bytes, overview, poster, backdrop, trailer_url, duration_sec, tmdb_id, broken)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
		m.Title, m.FileTitle, year, rel, m.SizeBytes, m.Overview, m.Poster, m.Backdrop, m.TrailerURL, dur, m.TMDbID, boolInt(broken))
	if err != nil {
		fmt.Println("insert movie:", err)
		return
	}
	m.ID, _ = res.LastInsertId()
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func (s *Server) lookupMovieByPath(rel string) (*Movie, error) {
	m := &Movie{}
	err := s.db.QueryRow(`SELECT id, title, COALESCE(year,0), file_path, size_bytes, COALESCE(overview,''),
		COALESCE(poster,''), COALESCE(backdrop,''), COALESCE(trailer_url,''), duration_sec, COALESCE(tmdb_id,0) FROM movies WHERE file_path = ?`, rel).
		Scan(&m.ID, &m.Title, &m.Year, &m.FilePath, &m.SizeBytes, &m.Overview, &m.Poster, &m.Backdrop, &m.TrailerURL, &m.Duration, &m.TMDbID)
	if err != nil {
		return nil, err
	}
	return m, nil
}

func (s *Server) pruneMovies(dir string) error {
	rows, err := s.db.Query(`SELECT id, file_path FROM movies`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var rel string
		rows.Scan(&id, &rel)
		if rel == "" {
			// rows without a file path are metadata ghosts; drop them
			s.db.Exec(`DELETE FROM movies WHERE id=?`, id)
			s.db.Exec(`DELETE FROM progress WHERE media_kind='movie' AND media_id=?`, id)
			continue
		}
		if full, err := resolveRel(s.conf.MediaDir, rel); err != nil || !fileExists(full) {
			s.db.Exec(`DELETE FROM movies WHERE id=?`, id)
			s.db.Exec(`DELETE FROM progress WHERE media_kind='movie' AND media_id=?`, id)
		}
	}
	return rows.Err()
}

// ---- Shows ----

func (s *Server) scanShows(dir string) (int, int, error) {
	epCount := 0
	shows, err := os.ReadDir(dir)
	if err != nil {
		return 0, 0, err
	}
	found := 0
	for _, sh := range shows {
		if !sh.IsDir() {
			continue
		}
		showDir := filepath.Join(dir, sh.Name())
		title := cleanTitle(sh.Name())
		year := extractYear(sh.Name())
		if title == "" {
			continue
		}
		show, err := s.upsertShow(startShow(title, year))
		if err != nil {
			continue
		}
		n, err := s.scanSeasons(show, showDir)
		if err != nil {
			continue
		}
		epCount += n
		found++
		s.setLocalArt("show", show.ID, showDir, "")
	}
	return found, epCount, nil
}

// movieIDByPath returns the DB id for a movie stored at the given relative path.
func (s *Server) movieIDByPath(rel string) int64 {
	var id int64
	s.db.QueryRow(`SELECT id FROM movies WHERE file_path = ?`, rel).Scan(&id)
	return id
}

func (s *Server) scanSeasons(show *Show, dir string) (int, error) {
	seasons, err := os.ReadDir(dir)
	if err != nil {
		return 0, err
	}
	epCount := 0
	for _, se := range seasons {
		if !se.IsDir() {
			// loose episode file directly under the show folder
			if isVideo(se.Name()) {
				s.upsertEpisode(show, 1, se.Name(), filepath.Join(dir, se.Name()))
				epCount++
			}
			continue
		}
		seasonNum := parseSeasonFolder(se.Name())
		if seasonNum == 0 {
			continue
		}
		seasonDir := filepath.Join(dir, se.Name())
		eps, err := os.ReadDir(seasonDir)
		if err != nil {
			continue
		}
		for _, ep := range eps {
			if ep.IsDir() || !isVideo(ep.Name()) {
				continue
			}
			n := s.upsertEpisode(show, seasonNum, ep.Name(), filepath.Join(seasonDir, ep.Name()))
			if n {
				epCount++
			}
		}
	}
	return epCount, nil
}

func parseSeasonFolder(name string) int {
	m := seasonFolderRe.FindStringSubmatch(name)
	if m == nil {
		return 0
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

func (s *Server) upsertShow(sh *Show) (*Show, error) {
	var id int64
	err := s.db.QueryRow(`SELECT id FROM shows WHERE title = ?`, sh.Title).Scan(&id)
	if err == nil {
		sh.ID = id
		_, e := s.db.Exec(`UPDATE shows SET year=? WHERE id=?`, sh.Year, id)
		return sh, e
	}
	res, e := s.db.Exec(`INSERT INTO shows (title, year) VALUES (?,?)`, sh.Title, sh.Year)
	if e != nil {
		return nil, e
	}
	sh.ID, _ = res.LastInsertId()
	return sh, nil
}

func startShow(title string, year int) *Show {
	return &Show{Title: title, Year: year}
}

// upsertEpisode returns true if a new episode was added or size changed.
func (s *Server) upsertEpisode(show *Show, season int, fileName, fullPath string) bool {
	_, eNum, title := parseEpisodeName(show.Title, fileName)
	rel := relPath(s.conf.MediaDir, fullPath)
	var size int64
	if fi, err := os.Stat(fullPath); err == nil {
		size = fi.Size()
	}

	var id int64
	var oldSize int64
	err := s.db.QueryRow(`SELECT id, size_bytes FROM episodes WHERE file_path = ?`, rel).Scan(&id, &oldSize)
	dur, broken := s.probeMovie(fullPath)
	if err == nil {
		if oldSize == size {
			s.db.Exec(`UPDATE episodes SET title=?, duration_sec=?, broken=? WHERE id=? AND title != ?`, title, dur, boolInt(broken), id, title)
			return false
		}
		s.db.Exec(`UPDATE episodes SET size_bytes=?, title=?, duration_sec=?, broken=? WHERE id=?`, size, title, dur, boolInt(broken), id)
		return true
	}
	_, e := s.db.Exec(`INSERT INTO episodes (show_id, season, episode, title, file_path, size_bytes, duration_sec, broken)
		VALUES (?,?,?,?,?,?,?,?)`, show.ID, season, eNum, title, rel, size, dur, boolInt(broken))
	if e != nil {
		fmt.Println("insert episode:", e)
		return false
	}
	return true
}

// parseEpisodeName extracts season/episode/title from a filename.
func parseEpisodeName(showTitle, fileName string) (int, int, string) {
	stem := strings.TrimSuffix(fileName, filepath.Ext(fileName))
	sNum, eNum := 0, 0
	if m := episodeNameRe.FindStringSubmatch(stem); m != nil {
		sNum, _ = strconv.Atoi(m[1])
		eNum, _ = strconv.Atoi(m[2])
	} else if m := episodeXRe.FindStringSubmatch(stem); m != nil {
		sNum, _ = strconv.Atoi(m[1])
		eNum, _ = strconv.Atoi(m[2])
	} else if m := episodeWordRe.FindStringSubmatch(stem); m != nil {
		eNum, _ = strconv.Atoi(m[1])
		sNum = 1
	}
	if sNum == 0 {
		sNum = 1
	}
	if eNum == 0 {
		eNum = len(stem) // fallback marker (won't collide in practice)
	}
	// strip marker from title
	t := stripEpisodeMarker(stem)
	if strings.HasPrefix(strings.ToLower(t), strings.ToLower(showTitle)+" ") {
		t = strings.TrimSpace(t[len(showTitle):])
	}
	t = strings.TrimLeft(t, "-– ")
	t = cleanTitle(t)
	if t == "" {
		t = fmt.Sprintf("Episode %d", eNum)
	}
	return sNum, eNum, t
}

func stripEpisodeMarker(s string) string {
	s = episodeNameRe.ReplaceAllString(s, " ")
	s = episodeXRe.ReplaceAllString(s, " ")
	s = episodeWordRe.ReplaceAllString(s, " ")
	s = cleanTitle(s)
	s = strings.TrimPrefix(s, "Episode")
	s = strings.TrimSpace(s)
	_, err := strconv.Atoi(s)
	if err == nil {
		return ""
	}
	return s
}

func (s *Server) pruneEpisodes(showDir string) error {
	rows, err := s.db.Query(`SELECT id, file_path FROM episodes`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var rel string
		rows.Scan(&id, &rel)
		if full, err := resolveRel(s.conf.MediaDir, rel); err != nil || !fileExists(full) {
			s.db.Exec(`DELETE FROM episodes WHERE id=?`, id)
			s.db.Exec(`DELETE FROM progress WHERE media_kind='episode' AND media_id=?`, id)
		}
	}
	// prune shows with no episodes
	s.db.Exec(`DELETE FROM shows WHERE id NOT IN (SELECT DISTINCT show_id FROM episodes)`)
	return rows.Err()
}

// ---- path helpers ----

func relPath(base, p string) string {
	if base == "" {
		base = "/"
	}
	r, err := filepath.Rel(base, p)
	if err != nil {
		return p
	}
	if strings.HasPrefix(r, "..") {
		return p
	}
	return r
}

func resolveRel(base, rel string) (string, error) {
	if filepath.IsAbs(rel) {
		return rel, nil
	}
	if strings.HasPrefix(rel, "..") || strings.HasPrefix(rel, string(filepath.Separator)) {
		return "", fmt.Errorf("unsafe path")
	}
	return filepath.Join(base, rel), nil
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func sortedKeys[T any](m map[string]T) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
