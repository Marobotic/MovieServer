package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const tmdbImageBase = "https://image.tmdb.org/t/p"

type tmdbClient struct {
	key   string
	token string
	lang  string
	hc    *http.Client
}

func newTMDbClient(key, token, lang string) *tmdbClient {
	if lang == "" {
		lang = "en"
	}
	return &tmdbClient{key: key, token: token, lang: lang, hc: &http.Client{Timeout: 15 * time.Second}}
}

func (s *Server) tmdb() *tmdbClient {
	return newTMDbClient(s.conf.TMDbAPIKey, s.conf.TMDbReadToken, s.conf.TMDbLang)
}

func (c *tmdbClient) get(path string, out interface{}) error {
	if c.key == "" && c.token == "" {
		return fmt.Errorf("tmdb api key not configured")
	}
	u := "https://api.themoviedb.org/3" + path
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return err
	}
	if c.token != "" {
		// Read-access token is the modern, officially supported auth method.
		req.Header.Set("Authorization", "Bearer "+c.token)
	} else {
		q := req.URL.Query()
		q.Set("api_key", c.key)
		q.Set("language", c.lang)
		req.URL.RawQuery = q.Encode()
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("tmdb %d: %s", resp.StatusCode, truncate(string(body), 120))
	}
	return json.Unmarshal(body, out)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

type tmdbSearchResp struct {
	Results []struct {
		ID          int    `json:"id"`
		Title       string `json:"title"`
		Name        string `json:"name"`
		OriginalTitle string `json:"original_title"`
		ReleaseDate string `json:"release_date"`
		FirstAirDate string `json:"first_air_date"`
		PosterPath  string `json:"poster_path"`
		Overview    string `json:"overview"`
		MediaType   string `json:"media_type"`
	} `json:"results"`
}

type tmdbMovieDetail struct {
	ID          int     `json:"id"`
	Title       string  `json:"title"`
	Overview    string  `json:"overview"`
	PosterPath  string  `json:"poster_path"`
	BackdropPath string `json:"backdrop_path"`
	Runtime     int     `json:"runtime"`
	ReleaseDate string  `json:"release_date"`
	Videos      struct {
		Results []struct {
			Key  string `json:"key"`
			Site string `json:"site"`
			Type string `json:"type"`
		} `json:"results"`
	} `json:"videos"`
}

type tmdbTVDetail struct {
	ID      int    `json:"id"`
	Name    string `json:"name"`
	Overview string `json:"overview"`
	PosterPath  string `json:"poster_path"`
	BackdropPath string `json:"backdrop_path"`
	FirstAirDate string `json:"first_air_date"`
	Videos  struct {
		Results []struct {
			Key  string `json:"key"`
			Site string `json:"site"`
			Type string `json:"type"`
		} `json:"results"`
	} `json:"videos"`
}

type tmdbEpisodeDetail struct {
	ID         int    `json:"id"`
	Name       string `json:"name"`
	Overview   string `json:"overview"`
	StillPath  string `json:"still_path"`
	AirDate    string `json:"air_date"`
	EpisodeNumber int  `json:"episode_number"`
}

func trailerFromVideos(results []struct {
	Key  string `json:"key"`
	Site string `json:"site"`
	Type string `json:"type"`
}) string {
	for _, v := range results {
		if v.Site == "YouTube" && v.Type == "Trailer" {
			return "https://www.youtube.com/watch?v=" + v.Key
		}
	}
	return ""
}

type tmdbMovieSearch struct {
	ID          int    `json:"id"`
	Title       string `json:"title"`
	ReleaseDate string `json:"release_date"`
	PosterPath  string `json:"poster_path"`
	Overview    string `json:"overview"`
}

type tmdbTVSearch struct {
	ID           int    `json:"id"`
	Name         string `json:"name"`
	FirstAirDate string `json:"first_air_date"`
	PosterPath   string `json:"poster_path"`
	Overview     string `json:"overview"`
}

func (c *tmdbClient) searchMovie(query string, year int) ([]tmdbMovieSearch, error) {
	var resp tmdbSearchResp
	err := c.get("/search/movie?query="+url.QueryEscape(query), &resp)
	out := make([]tmdbMovieSearch, 0, len(resp.Results))
	for _, r := range resp.Results {
		out = append(out, tmdbMovieSearch{ID: r.ID, Title: r.Title, ReleaseDate: r.ReleaseDate, PosterPath: r.PosterPath, Overview: r.Overview})
	}
	return out, err
}

func (c *tmdbClient) movie(id int) (*tmdbMovieDetail, error) {
	d := &tmdbMovieDetail{}
	err := c.get(fmt.Sprintf("/movie/%d?append_to_response=videos", id), d)
	return d, err
}

func (c *tmdbClient) searchTV(query string, year int) ([]tmdbTVSearch, error) {
	var resp tmdbSearchResp
	err := c.get("/search/tv?query="+url.QueryEscape(query), &resp)
	out := make([]tmdbTVSearch, 0, len(resp.Results))
	for _, r := range resp.Results {
		out = append(out, tmdbTVSearch{ID: r.ID, Name: r.Name, FirstAirDate: r.FirstAirDate, PosterPath: r.PosterPath, Overview: r.Overview})
	}
	return out, err
}

func (c *tmdbClient) tv(id int) (*tmdbTVDetail, error) {
	d := &tmdbTVDetail{}
	err := c.get(fmt.Sprintf("/tv/%d?append_to_response=videos", id), d)
	return d, err
}

func (c *tmdbClient) episode(showID, season, ep int) (*tmdbEpisodeDetail, error) {
	d := &tmdbEpisodeDetail{}
	err := c.get(fmt.Sprintf("/tv/%d/season/%d/episode/%d", showID, season, ep), d)
	return d, err
}

// ---- enrichment ----

// enrichLibrary pulls metadata from TMDB for anything missing it.
func (s *Server) enrichLibrary() {
	if s.conf.TMDbAPIKey == "" && s.conf.TMDbReadToken == "" {
		return
	}
	c := s.tmdb()
	// movies
	rows, err := s.db.Query(`SELECT id, title, year, file_path, poster, overview FROM movies`)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var id int64
			var title, fp, poster, overview string
			var year int
			rows.Scan(&id, &title, &year, &fp, &poster, &overview)
			if poster != "" && overview != "" {
				continue
			}
			if m, ok := s.enrichMovie(c, id, title, year); ok && m != nil {
				m.FilePath = fp
				s.upsertMovie(m, true)
			}
		}
	}
	// shows
	srows, err := s.db.Query(`SELECT id, title, year, poster, overview FROM shows`)
	if err == nil {
		defer srows.Close()
		for srows.Next() {
			var id int64
			var title, poster, overview string
			var year int
			srows.Scan(&id, &title, &year, &poster, &overview)
			if poster != "" && overview != "" {
				continue
			}
			if sh, ok := s.enrichShow(c, id, title, year); ok && sh != nil {
				s.applyShowMetadata(sh)
			}
		}
	}
}

func (s *Server) enrichMovie(c *tmdbClient, id int64, title string, year int) (*Movie, bool) {
	results, err := c.searchMovie(title, year)
	if err != nil || len(results) == 0 {
		return nil, false
	}
	best := results[0]
	for _, r := range results {
		if year > 0 && strings.Contains(r.ReleaseDate, fmt.Sprintf("-%d-", year)) {
			best = r
			break
		}
	}
	d, err := c.movie(best.ID)
	if err != nil {
		return nil, false
	}
	m := &Movie{ID: id, Title: d.Title, Year: derpYear(d.ReleaseDate), TMDbID: d.ID, Overview: d.Overview}
	m.TrailerURL = trailerFromVideos(d.Videos.Results)
	if d.PosterPath != "" {
		m.Poster = s.downloadImage(posterURL(d.PosterPath, "w342"), "")
	}
	if d.BackdropPath != "" {
		m.Backdrop = s.downloadImage(backdropURL(d.BackdropPath, "w1280"), "")
	}
	return m, true
}

func (s *Server) enrichShow(c *tmdbClient, id int64, title string, year int) (*Show, bool) {
	results, err := c.searchTV(title, year)
	if err != nil || len(results) == 0 {
		return nil, false
	}
	best := results[0]
	for _, r := range results {
		if year > 0 && strings.Contains(r.FirstAirDate, fmt.Sprintf("-%d-", year)) {
			best = r
			break
		}
	}
	d, err := c.tv(best.ID)
	if err != nil {
		return nil, false
	}
	sh := &Show{ID: id, Title: d.Name, Year: derpYear(d.FirstAirDate), TMDbID: d.ID, Overview: d.Overview}
	sh.TrailerURL = trailerFromVideos(d.Videos.Results)
	if d.PosterPath != "" {
		sh.Poster = s.downloadImage(posterURL(d.PosterPath, "w342"), "")
	}
	if d.BackdropPath != "" {
		sh.Backdrop = s.downloadImage(backdropURL(d.BackdropPath, "w1280"), "")
	}
	// enrich episode titles/stills for the show
	s.enrichEpisodes(c, sh.ID, int64(sh.TMDbID))
	return sh, true
}

func (s *Server) enrichEpisodes(c *tmdbClient, showID, tmdbID int64) {
	if tmdbID == 0 {
		return
	}
	rows, err := s.db.Query(`SELECT id, season, episode, title, still FROM episodes WHERE show_id = ? AND (title = '' OR still = '')`, showID)
	if err != nil {
		return
	}
	defer rows.Close()
	type ep struct{ id int64; s, e int; title, still string }
	var eps []ep
	for rows.Next() {
		var e ep
		rows.Scan(&e.id, &e.s, &e.e, &e.title, &e.still)
		eps = append(eps, e)
	}
	for _, e := range eps {
		if e.title != "" && e.still != "" {
			continue
		}
		d, err := c.episode(int(tmdbID), e.s, e.e)
		if err != nil {
			continue
		}
		q := "UPDATE episodes SET "
		var args []any
		if e.title == "" && d.Name != "" {
			q += "title=?, "
			args = append(args, d.Name)
		}
		if e.still == "" && d.StillPath != "" {
			q += "still=?, "
			args = append(args, s.downloadImage(posterURL(d.StillPath, "w300"), ""))
		}
		if len(args) == 0 {
			continue
		}
		q = strings.TrimSuffix(q, ", ") + " WHERE id=?"
		args = append(args, e.id)
		s.db.Exec(q, args...)
	}
}

func (s *Server) applyShowMetadata(sh *Show) {
	var poster, backdrop string
	s.db.QueryRow(`SELECT poster, backdrop FROM shows WHERE id=?`, sh.ID).Scan(&poster, &backdrop)
	sets := []string{"overview=?", "trailer_url=?", "tmdb_id=?"}
	args := []any{sh.Overview, sh.TrailerURL, sh.TMDbID}
	if !isLocalArt(poster) {
		sets = append(sets, "title=?", "year=?", "poster=?")
		args = append(args, sh.Title, sh.Year, sh.Poster)
	}
	if !isLocalArt(backdrop) {
		sets = append(sets, "backdrop=?")
		args = append(args, sh.Backdrop)
	}
	args = append(args, sh.ID)
	s.db.Exec(`UPDATE shows SET `+strings.Join(sets, ", ")+` WHERE id=?`, args...)
}

func derpYear(date string) int {
	if len(date) >= 4 {
		var y int
		fmt.Sscanf(date, "%d", &y)
		if y > 1900 && y < 2100 {
			return y
		}
	}
	return 0
}

func posterURL(path, size string) string { return tmdbImageBase + "/" + size + path }
func backdropURL(path, size string) string { return tmdbImageBase + "/" + size + path }

// downloadImage stores a remote image under data/covers and returns a server-relative URL.
func (s *Server) downloadImage(src, fallbackName string) string {
	if src == "" {
		return ""
	}
	covers := filepath.Join(s.dataDir, "covers")
	os.MkdirAll(covers, 0o755)
	name := fallbackName
	if name == "" {
		idx := strings.LastIndex(src, "/")
		if idx >= 0 && idx < len(src)-1 {
			name = src[idx+1:]
		} else {
			name = fmt.Sprintf("img_%s", randomHex(4))
		}
	}
	resp, err := s.hc.Get(src)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return ""
	}
	dest := filepath.Join(covers, name)
	f, err := os.Create(dest)
	if err != nil {
		return ""
	}
	defer f.Close()
	if _, err := io.Copy(f, io.LimitReader(resp.Body, 20<<20)); err != nil {
		return ""
	}
	return "/api/asset/" + name
}