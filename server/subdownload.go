package main

import (
	"archive/zip"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const osAPIBase = "https://api.opensubtitles.com/api/v1"

var subLangs = []string{"en", "ar"}

type osAuth struct {
	Token string `json:"token"`
}

type osSearchBody struct {
	Query          string   `json:"query,omitempty"`
	Year           int      `json:"year,omitempty"`
	Type           string   `json:"type,omitempty"`
	SeasonNumber   int      `json:"season_number,omitempty"`
	EpisodeNumber  int      `json:"episode_number,omitempty"`
	Languages      []string `json:"languages"`
	AiTranslated   string   `json:"ai_translated,omitempty"`
	OrderBy        string   `json:"order_by,omitempty"`
	OrderDirection string   `json:"order_direction,omitempty"`
}

type osSubResult struct {
	ID         string `json:"id"`
	Attributes struct {
		Language       string `json:"language"`
		AiTranslated   bool   `json:"ai_translated"`
		MovieHashMatch string `json:"moviehash_match"`
		Files          []struct {
			FileID   int    `json:"file_id"`
			FileName string `json:"file_name"`
		} `json:"files"`
	} `json:"attributes"`
}

type osSearchResponse struct {
	TotalCount int           `json:"total_count"`
	Data       []osSubResult `json:"data"`
}

type osDownloadBody struct {
	FileID int `json:"file_id"`
}

type osDownloadResponse struct {
	Link      string `json:"link"`
	Remaining int    `json:"remaining"`
}

// osClient talks to the OpenSubtitles REST API v1.
type osClient struct {
	user, pass string
	apiKey     string
	token      string
	remaining  int
	mu         sync.Mutex
	lastReq    time.Time
	hc         *http.Client
}

func (c *osClient) gate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if wait := time.Until(c.lastReq.Add(1100 * time.Millisecond)); wait > 0 {
		time.Sleep(wait)
	}
	c.lastReq = time.Now()
}

// osDo performs an API call via the curl binary. OpenSubtitles' CDN blocks
// Go's default HTTP/TLS fingerprint (curl succeeds with identical headers),
// so we shell out to curl - which is a dependency we already accept (ffmpeg
// is required anyway). Falls back to the Go client if curl is absent.
func osDo(method, url string, headers [][2]string, body string) ([]byte, int, error) {
	curl, err := exec.LookPath("curl")
	if err != nil {
		return osDoFallback(method, url, headers, body)
	}
	args := []string{"-s", "-L", "-m", "60", "-X", method}
	for _, h := range headers {
		args = append(args, "-H", h[0]+": "+h[1])
	}
	if body != "" {
		args = append(args, "-d", body)
	}
	args = append(args, "-w", "\n__HTTP_CODE__%{http_code}")
	args = append(args, url)
	out, err := exec.Command(curl, args...).Output()
	if err != nil {
		return nil, 0, err
	}
	idx := bytes.LastIndex(out, []byte("\n__HTTP_CODE__"))
	if idx < 0 {
		return nil, 200, fmt.Errorf("malformed curl output")
	}
	codeStr := strings.TrimSpace(string(out[idx+len("\n__HTTP_CODE__"):]))
	code, _ := strconv.Atoi(codeStr)
	return out[:idx], code, nil
}

func osDoFallback(method, url string, headers [][2]string, body string) ([]byte, int, error) {
	var rdr io.Reader
	if body != "" {
		rdr = bytes.NewReader([]byte(body))
	}
	req, err := http.NewRequest(method, url, rdr)
	if err != nil {
		return nil, 0, err
	}
	for _, h := range headers {
		req.Header.Set(h[0], h[1])
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	return data, resp.StatusCode, err
}

func newOSClient(user, pass, apiKey string) *osClient {
	return &osClient{user: user, pass: pass, apiKey: apiKey, hc: &http.Client{Timeout: 60 * time.Second}}
}

func (c *osClient) login() error {
	body, _ := json.Marshal(map[string]string{"username": c.user, "password": c.pass})
	c.gate()
	data, code, err := osDo("POST", osAPIBase+"/login", [][2]string{
		{"Content-Type", "application/json"},
		{"User-Agent", "MovieServer/v0.1.0"},
		{"Api-Key", c.apiKey},
	}, string(body))
	if err != nil {
		return err
	}
	if code != http.StatusOK {
		return fmt.Errorf("login failed (%d): %s", code, truncateStr(string(data), 300))
	}
	var a osAuth
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	c.token = a.Token
	return nil
}

// search returns the best non-AI result per requested language.
func (c *osClient) search(b osSearchBody) (map[string]int, error) {
	q := url.Values{}
	q.Set("languages", strings.Join(subLangs, ","))
	q.Set("ai_translated", "exclude")
	q.Set("order_by", "download_count")
	q.Set("order_direction", "desc")
	if b.Query != "" {
		q.Set("query", b.Query)
	}
	if b.Year > 0 {
		q.Set("year", strconv.Itoa(b.Year))
	}
	if b.Type != "" {
		q.Set("type", b.Type)
	}
	if b.SeasonNumber > 0 {
		q.Set("season_number", strconv.Itoa(b.SeasonNumber))
	}
	if b.EpisodeNumber > 0 {
		q.Set("episode_number", strconv.Itoa(b.EpisodeNumber))
	}
	c.gate()
	data, code, err := osDo("GET", osAPIBase+"/subtitles?"+q.Encode(), [][2]string{
		{"Accept", "application/json"},
		{"Authorization", "Bearer " + c.token},
		{"User-Agent", "MovieServer/v0.1.0"},
		{"Api-Key", c.apiKey},
	}, "")
	if err != nil {
		return nil, err
	}
	if code != http.StatusOK {
		return nil, fmt.Errorf("search failed (%d): %s", code, truncateStr(string(data), 300))
	}
	var sr osSearchResponse
	if err := json.Unmarshal(data, &sr); err != nil {
		return nil, err
	}
	byLang := map[string]int{}
	for i := range sr.Data {
		sub := &sr.Data[i]
		attrs := sub.Attributes
		if attrs.AiTranslated {
			continue
		}
		if _, ok := byLang[attrs.Language]; ok {
			continue
		}
		if len(attrs.Files) == 0 {
			continue
		}
		byLang[attrs.Language] = attrs.Files[0].FileID
	}
	return byLang, nil
}

func (c *osClient) downloadFile(fileID int) ([]byte, error) {
	body, _ := json.Marshal(osDownloadBody{FileID: fileID})
	c.gate()
	data, code, err := osDo("POST", osAPIBase+"/download", [][2]string{
		{"Content-Type", "application/json"},
		{"Authorization", "Bearer " + c.token},
		{"User-Agent", "MovieServer/v0.1.0"},
		{"Api-Key", c.apiKey},
	}, string(body))
	if err != nil {
		return nil, err
	}
	if code != http.StatusOK {
		return nil, fmt.Errorf("download request failed (%d) file_id=%d: %s", code, fileID, truncateStr(string(data), 300))
	}
	var dr osDownloadResponse
	if err := json.Unmarshal(data, &dr); err != nil {
		return nil, err
	}
	c.remaining = dr.Remaining
	if dr.Link == "" {
		return nil, fmt.Errorf("empty download link")
	}
	data, code, err = osDo("GET", dr.Link, [][2]string{
		{"User-Agent", "MovieServer/v0.1.0"},
	}, "")
	if err != nil {
		return nil, err
	}
	if code != http.StatusOK {
		return nil, fmt.Errorf("subtitle link failed (%d)", code)
	}
	raw := data
	if len(raw) >= 2 && raw[0] == 0x1f && raw[1] == 0x8b {
		gz, err := gzip.NewReader(bytes.NewReader(raw))
		if err != nil {
			return nil, err
		}
		defer gz.Close()
		uncompressed, err := io.ReadAll(gz)
		if err != nil {
			return nil, err
		}
		return uncompressed, nil
	}
	if len(raw) >= 4 && bytes.Equal(raw[:4], []byte{0x50, 0x4b, 0x03, 0x04}) {
		zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
		if err != nil {
			return nil, err
		}
		for _, f := range zr.File {
			if strings.HasSuffix(strings.ToLower(f.Name), ".srt") || strings.HasSuffix(strings.ToLower(f.Name), ".vtt") || strings.HasSuffix(strings.ToLower(f.Name), ".ass") {
				rc, err := f.Open()
				if err != nil {
					continue
				}
				content, err := io.ReadAll(rc)
				rc.Close()
				if err == nil {
					return content, nil
				}
			}
		}
		return nil, fmt.Errorf("no subtitle file in zip archive")
	}
	return raw, nil
}

type subtitleJob struct {
	mediaDir string
	relPath  string
	query    string
	year     int
	kind     string // movie | episode
	season   int
	episode  int
}

// downloadSubtitles fetches en+ar SRTs for every movie and episode that does
// not already have them, saving them next to the video file.
func (s *Server) downloadSubtitles() {
	if s.conf.OSTUser == "" || s.conf.OSTPass == "" || s.conf.OSTApiKey == "" {
		log.Printf("subtitles: configure opensubtitles_user/opensubtitles_password/opensubtitles_api_key to auto-fetch en/ar subtitles")
		return
	}
	client := newOSClient(s.conf.OSTUser, s.conf.OSTPass, s.conf.OSTApiKey)
	if err := client.login(); err != nil {
		log.Printf("subtitles: login failed: %v", err)
		return
	}
	jobs := s.subtitleJobs()
	log.Printf("subtitles: checking %d items", len(jobs))
	var got, errN int
	for i := range jobs {
		j := jobs[i]
		abs := filepath.Join(s.conf.MediaDir, j.relPath)
		dir := filepath.Dir(abs)
		stem := strings.TrimSuffix(filepath.Base(abs), filepath.Ext(abs))
		// A track already inside the video beats anything downloadable, so do
		// not spend quota fetching a language the release already carries.
		muxed := map[string]bool{}
		for _, e := range embeddedSubtitles(abs) {
			muxed[shortLangCode(e.Language)] = true
		}
		for _, lang := range subLangs {
			dest := filepath.Join(dir, fmt.Sprintf("%s.%s.srt", stem, lang))
			if fileExists(dest) {
				continue
			}
			if muxed[lang] {
				continue
			}
			b := osSearchBody{Query: j.query, Year: j.year, Type: j.kind}
			if j.kind == "episode" {
				b.SeasonNumber = j.season
				b.EpisodeNumber = j.episode
			}
			files, err := client.search(b)
			if err != nil {
				log.Printf("subtitles: %s: %v", j.relPath, err)
				errN++
				continue
			}
			fileID, ok := files[lang]
			if !ok {
				continue
			}
			content, err := client.downloadFile(fileID)
			if err != nil {
				log.Printf("subtitles: %s (%s): %v", j.relPath, lang, err)
				errN++
				continue
			}
			if !looksLikeSRT(content) {
				log.Printf("subtitles: %s (%s): downloaded content not SRT, skipping", j.relPath, lang)
				errN++
				continue
			}
			if err := os.WriteFile(dest, content, 0o644); err != nil {
				log.Printf("subtitles: write %s: %v", dest, err)
				errN++
				continue
			}
			got++
			log.Printf("subtitles: wrote %s", dest)
			if client.remaining <= 0 {
				log.Printf("subtitles: daily download quota reached (%d remaining) - stopping", client.remaining)
				log.Printf("subtitles: done - downloaded %d, errors %d", got, errN)
				return
			}
		}
		time.Sleep(1200 * time.Millisecond)
	}
	log.Printf("subtitles: done - downloaded %d, errors %d", got, errN)
}

func (s *Server) subtitleJobs() []subtitleJob {
	var jobs []subtitleJob
	rows, err := s.db.Query(`SELECT title, COALESCE(year,0), file_path FROM movies WHERE file_path != ''`)
	if err == nil {
		for rows.Next() {
			var t, p string
			var y int
			rows.Scan(&t, &y, &p)
			jobs = append(jobs, subtitleJob{mediaDir: s.conf.MediaDir, relPath: p, query: t, year: y, kind: "movie"})
		}
		rows.Close()
	}
	rows, err = s.db.Query(`SELECT s.title, e.season, e.episode, e.file_path FROM episodes e JOIN shows s ON s.id=e.show_id WHERE e.file_path != ''`)
	if err == nil {
		for rows.Next() {
			var t, p string
			var se, ep int
			rows.Scan(&t, &se, &ep, &p)
			jobs = append(jobs, subtitleJob{mediaDir: s.conf.MediaDir, relPath: p, query: t, year: 0, kind: "episode", season: se, episode: ep})
		}
		rows.Close()
	}
	return jobs
}

func (s *Server) handleSubDownload(w http.ResponseWriter, r *http.Request) {
	if s.conf.OSTUser == "" || s.conf.OSTPass == "" || s.conf.OSTApiKey == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "set opensubtitles_user, opensubtitles_password and opensubtitles_api_key in config.json first",
		})
		return
	}
	go s.downloadSubtitles()
	writeJSON(w, http.StatusOK, map[string]string{"status": "started"})
}

func looksLikeSRT(b []byte) bool {
	head := string(b)
	if len(head) < 8 {
		return false
	}
	// SRT chunks revert to "digits\nHH:MM:SS,mmm -->"
	for i := 0; i < 3; i++ {
		idx := strings.Index(head, "-->")
		if idx > 0 && idx < 512 {
			return true
		}
		head = head[min(len(head)/2, 1024):]
	}
	return false
}

func truncateStr(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
