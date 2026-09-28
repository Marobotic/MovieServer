package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Finding a subtitle that is already in sync, rather than bending one that is
// not.
//
// Correcting a mistimed subtitle is guesswork on a soundtrack that is wall to
// wall music. Fetching a different file is not: OpenSubtitles indexes uploads
// by a hash of the video itself, so a "moviehash match" is a subtitle somebody
// timed against this exact release. When one exists it needs no correction at
// all, which is the whole game.

const osHashChunk = 64 * 1024

// openSubtitlesHash implements OpenSubtitles' file hash: the file size plus
// every 64-bit little-endian word of the first and last 64KB, all wrapping.
func openSubtitlesHash(path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return "", 0, err
	}
	size := fi.Size()
	if size < osHashChunk*2 {
		return "", size, fmt.Errorf("file too small to hash")
	}

	hash := uint64(size)
	buf := make([]byte, osHashChunk)

	sum := func(off int64) error {
		if _, err := f.Seek(off, io.SeekStart); err != nil {
			return err
		}
		if _, err := io.ReadFull(f, buf); err != nil {
			return err
		}
		for i := 0; i+8 <= len(buf); i += 8 {
			hash += binary.LittleEndian.Uint64(buf[i : i+8])
		}
		return nil
	}
	if err := sum(0); err != nil {
		return "", size, err
	}
	if err := sum(size - osHashChunk); err != nil {
		return "", size, err
	}
	return fmt.Sprintf("%016x", hash), size, nil
}

// osCandidate is one subtitle on offer for an item.
type osCandidate struct {
	FileID    int
	Language  string
	FileName  string
	Release   string
	HashMatch bool
	Downloads int
}

// searchCandidates lists subtitles for one language, newest API fields and
// all, with the movie hash attached so exact-release matches surface.
func (c *osClient) searchCandidates(b osSearchBody, lang, movieHash string, size int64) ([]osCandidate, error) {
	q := url.Values{}
	q.Set("languages", lang)
	q.Set("ai_translated", "exclude")
	q.Set("order_by", "download_count")
	q.Set("order_direction", "desc")
	if movieHash != "" {
		q.Set("moviehash", movieHash)
	}
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

	// The listing carries more than the shared search helper keeps, so it is
	// decoded again here rather than widening that one.
	var sr struct {
		Data []struct {
			Attributes struct {
				Language      string `json:"language"`
				AiTranslated  bool   `json:"ai_translated"`
				MovieHashMatch bool  `json:"moviehash_match"`
				DownloadCount int    `json:"download_count"`
				Release       string `json:"release"`
				Files         []struct {
					FileID   int    `json:"file_id"`
					FileName string `json:"file_name"`
				} `json:"files"`
			} `json:"attributes"`
		} `json:"data"`
	}
	if err := json.Unmarshal(data, &sr); err != nil {
		return nil, err
	}

	out := make([]osCandidate, 0, len(sr.Data))
	for _, d := range sr.Data {
		a := d.Attributes
		if a.AiTranslated || len(a.Files) == 0 {
			continue
		}
		name := a.Files[0].FileName
		out = append(out, osCandidate{
			FileID:    a.Files[0].FileID,
			Language:  a.Language,
			FileName:  name,
			Release:   a.Release,
			HashMatch: a.MovieHashMatch,
			Downloads: a.DownloadCount,
		})
	}
	// Exact-release matches first, then by popularity.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0; j-- {
			a, b := out[j-1], out[j]
			better := (b.HashMatch && !a.HashMatch) ||
				(b.HashMatch == a.HashMatch && b.Downloads > a.Downloads)
			if !better {
				break
			}
			out[j-1], out[j] = b, a
		}
	}
	return out, nil
}

// releaseTag pulls the group/source part of a filename so a candidate can be
// matched against the video's own release name.
func releaseTag(name string) string {
	s := strings.ToLower(name)
	for _, ext := range []string{".srt", ".ass", ".ssa", ".mkv", ".mp4", ".avi"} {
		s = strings.TrimSuffix(s, ext)
	}
	s = strings.NewReplacer(".", " ", "_", " ", "-", " ", "[", " ", "]", " ").Replace(s)
	return s
}

// sharedReleaseWords counts meaningful tokens two release names have in
// common: "1080p", "bluray", "galaxyrg" and so on.
func sharedReleaseWords(a, b string) int {
	skip := map[string]bool{"the": true, "a": true, "of": true, "and": true, "": true}
	seen := map[string]bool{}
	for _, w := range strings.Fields(releaseTag(a)) {
		if len(w) >= 3 && !skip[w] {
			seen[w] = true
		}
	}
	n := 0
	for _, w := range strings.Fields(releaseTag(b)) {
		if seen[w] {
			n++
			delete(seen, w)
		}
	}
	return n
}

// searchBodyFor builds the OpenSubtitles query for one library item.
func (s *Server) searchBodyFor(kind string, id int64) (osSearchBody, error) {
	switch kind {
	case "movie":
		var title string
		var year int
		err := s.db.QueryRow(`SELECT title, COALESCE(year,0) FROM movies WHERE id=?`, id).
			Scan(&title, &year)
		if err != nil {
			return osSearchBody{}, err
		}
		return osSearchBody{Query: title, Year: year, Type: "movie"}, nil
	case "episode":
		var title string
		var season, episode int
		err := s.db.QueryRow(
			`SELECT sh.title, e.season, e.episode FROM episodes e
			 JOIN shows sh ON sh.id = e.show_id WHERE e.id = ?`, id).
			Scan(&title, &season, &episode)
		if err != nil {
			return osSearchBody{}, err
		}
		return osSearchBody{Query: title, Type: "episode",
			SeasonNumber: season, EpisodeNumber: episode}, nil
	}
	return osSearchBody{}, fmt.Errorf("unknown kind %q", kind)
}

// subtitleTrial is one downloaded candidate and how well it fits the audio.
type subtitleTrial struct {
	cand     osCandidate
	body     []byte
	shiftSec float64 // what a synchroniser would still have to move it by
	fits     bool
	overlap  int // release-name words shared with the video file
}

// findBetterSubtitle downloads a few alternative subtitles and keeps whichever
// one already lines up with the audio.
//
// This is the answer when correcting a file cannot work: rather than bending
// bad timings into shape, fetch a version somebody already timed for this
// release. Candidates are ranked before spending any download quota - an exact
// moviehash match first, then ones whose release name shares words with the
// video - and then each is measured, because a promising name is not proof.
func (s *Server) findBetterSubtitle(kind string, id int64, lang string,
	duration float64, limit int) (*subtitleTrial, []string, error) {

	if s.conf.OSTUser == "" || s.conf.OSTPass == "" || s.conf.OSTApiKey == "" {
		return nil, nil, fmt.Errorf("OpenSubtitles is not configured")
	}
	video, err := s.resolveMediaFile(kind, id)
	if err != nil {
		return nil, nil, err
	}
	body, err := s.searchBodyFor(kind, id)
	if err != nil {
		return nil, nil, fmt.Errorf("could not identify the item: %w", err)
	}

	client := newOSClient(s.conf.OSTUser, s.conf.OSTPass, s.conf.OSTApiKey)
	if err := client.login(); err != nil {
		return nil, nil, fmt.Errorf("OpenSubtitles login failed: %w", err)
	}

	hash, _, herr := openSubtitlesHash(video)
	if herr != nil {
		log.Printf("subtitle search: could not hash %s: %v", filepath.Base(video), herr)
	}
	cands, err := client.searchCandidates(body, lang, hash, 0)
	if err != nil {
		return nil, nil, err
	}
	if len(cands) == 0 {
		return nil, nil, fmt.Errorf("OpenSubtitles has no %s subtitles for this title", lang)
	}

	// Rank by what actually predicts correct timing, in order of authority:
	// an exact file match, then how much of the release name is shared with
	// the video, and only then popularity.
	//
	// These must not be blended into one score. Download counts run into the
	// hundreds of thousands, so any sensible per-word bonus disappears next to
	// them - which is how a widely downloaded PAL DVD rip outranked the
	// BluRay subtitle cut for this very encode.
	videoName := filepath.Base(video)
	words := make(map[int]int, len(cands))
	for i := range cands {
		words[i] = sharedReleaseWords(videoName, cands[i].Release+" "+cands[i].FileName)
	}
	order := make([]int, len(cands))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool {
		i, j := order[a], order[b]
		if cands[i].HashMatch != cands[j].HashMatch {
			return cands[i].HashMatch
		}
		if words[i] != words[j] {
			return words[i] > words[j]
		}
		return cands[i].Downloads > cands[j].Downloads
	})
	ranked := make([]osCandidate, len(cands))
	for k, i := range order {
		ranked[k] = cands[i]
	}
	cands = ranked

	eng, engPath := findEngine()
	var best *subtitleTrial
	var notes []string
	// Trials go to a scratch directory, never beside the video: anything
	// ending in .srt in the media folder shows up as a subtitle track.
	scratch, err := os.MkdirTemp("", "movieserver-subs-")
	if err != nil {
		return nil, nil, err
	}
	defer os.RemoveAll(scratch)
	tmp := filepath.Join(scratch, "candidate.srt")

	for i, c := range cands {
		if i >= limit {
			break
		}
		content, err := client.downloadFile(c.FileID)
		if err != nil {
			notes = append(notes, fmt.Sprintf("%s: download failed", shortRelease(c)))
			continue
		}
		if !looksLikeSRT(content) {
			notes = append(notes, fmt.Sprintf("%s: not an SRT", shortRelease(c)))
			continue
		}
		if err := os.WriteFile(tmp, content, 0o644); err != nil {
			return nil, notes, err
		}
		spans, err := parseCueSpans(tmp)
		if err != nil || len(spans) < 20 {
			notes = append(notes, fmt.Sprintf("%s: unreadable", shortRelease(c)))
			continue
		}

		trial := &subtitleTrial{cand: c, body: content,
			overlap: sharedReleaseWords(videoName, c.Release+" "+c.FileName)}
		fits, _ := fitsRuntime(spans, duration)
		trial.fits = fits

		// How far a synchroniser would still move it. A file already timed for
		// this release barely needs to move at all.
		trial.shiftSec = math.Inf(1)
		if eng != nil {
			if corrected, out, err := runEngine(eng, engPath, video, tmp, modeShift); err == nil {
				os.Remove(out)
				n := min(len(spans), len(corrected))
				if n > 0 {
					trial.shiftSec = math.Abs(corrected[0].start - spans[0].start)
				}
			}
		}
		notes = append(notes, fmt.Sprintf("%s: off by %s%s",
			shortRelease(c), shiftLabel(trial.shiftSec),
			map[bool]string{true: "", false: ", does not fit the runtime"}[fits]))

		if best == nil || betterTrial(trial, best) {
			best = trial
		}
		// An exact fit is as good as it gets; stop burning quota.
		if trial.fits && trial.shiftSec < 0.35 {
			break
		}
	}
	if best == nil {
		return nil, notes, fmt.Errorf("none of the candidates could be read")
	}
	return best, notes, nil
}

func betterTrial(a, b *subtitleTrial) bool {
	if a.fits != b.fits {
		return a.fits
	}
	return a.shiftSec < b.shiftSec
}

func shortRelease(c osCandidate) string {
	name := c.Release
	if name == "" {
		name = c.FileName
	}
	if len(name) > 38 {
		name = name[:38]
	}
	if c.HashMatch {
		return name + " (exact match)"
	}
	return name
}

func shiftLabel(sec float64) string {
	if math.IsInf(sec, 1) {
		return "an unknown amount"
	}
	return fmt.Sprintf("%.2fs", sec)
}

// listCandidates returns what OpenSubtitles has for an item without spending
// any download quota - names and popularity only, ranked the same way the
// automatic search ranks them.
func (s *Server) listCandidates(kind string, id int64, lang string, limit int) ([]osCandidate, error) {
	if s.conf.OSTUser == "" || s.conf.OSTPass == "" || s.conf.OSTApiKey == "" {
		return nil, fmt.Errorf("OpenSubtitles is not configured")
	}
	video, err := s.resolveMediaFile(kind, id)
	if err != nil {
		return nil, err
	}
	body, err := s.searchBodyFor(kind, id)
	if err != nil {
		return nil, fmt.Errorf("could not identify the item: %w", err)
	}
	client := newOSClient(s.conf.OSTUser, s.conf.OSTPass, s.conf.OSTApiKey)
	if err := client.login(); err != nil {
		return nil, fmt.Errorf("OpenSubtitles login failed: %w", err)
	}
	hash, _, _ := openSubtitlesHash(video)
	cands, err := client.searchCandidates(body, lang, hash, 0)
	if err != nil {
		return nil, err
	}
	if len(cands) > limit {
		cands = cands[:limit]
	}
	return cands, nil
}

// installCandidate downloads one chosen subtitle and writes it beside the
// video, keeping whatever was there before.
func (s *Server) installCandidate(kind string, id int64, fileID int, lang, dest string) (int, error) {
	client := newOSClient(s.conf.OSTUser, s.conf.OSTPass, s.conf.OSTApiKey)
	if err := client.login(); err != nil {
		return 0, fmt.Errorf("OpenSubtitles login failed: %w", err)
	}
	content, err := client.downloadFile(fileID)
	if err != nil {
		return 0, err
	}
	if !looksLikeSRT(content) {
		return 0, fmt.Errorf("that file did not come back as a subtitle")
	}
	if fileExists(dest) && !fileExists(dest+".orig") {
		if orig, rerr := os.ReadFile(dest); rerr == nil {
			os.WriteFile(dest+".orig", orig, 0o644)
		}
	}
	if err := os.WriteFile(dest, content, 0o644); err != nil {
		return 0, err
	}
	spans, _ := parseCueSpans(dest)
	return len(spans), nil
}
