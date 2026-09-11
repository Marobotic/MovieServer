package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Per-media-file extras: local artwork in the item's folder (poster, backdrop,
// banner, logo, icon...), external subtitles (SRT/VTT/ASS), and audio track
// listing (for dual-audio files).

// ---- artwork ----

var artSlots = map[string][]string{
	"poster":    {"poster", "folder"},
	"backdrop":  {"backdrop", "fanart"},
	"banner":    {"banner", "wide"},
	"logo":      {"logo", "clearlogo"},
	"icon":      {"icon", "thumb"},
	"still":     {"still", "thumb"},
	"thumb":     {"thumb", "icon"},
	"fanart":    {"fanart", "backdrop"},
	"clearlogo": {"clearlogo", "logo"},
	"folder":    {"folder", "poster"},
	"wide":      {"wide", "banner"},
}

var artExts = []string{".jpg", ".jpeg", ".png", ".webp", ".gif"}

// isLocalArt reports whether a stored poster/backdrop URL is served from the
// media folder (user-provided artwork) rather than fetched by the server.
func isLocalArt(u string) bool {
	return strings.HasPrefix(u, "/api/movies/") ||
		strings.HasPrefix(u, "/api/shows/") ||
		strings.HasPrefix(u, "/api/episodes/")
}

func findArtFile(dir string, names []string) (string, bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	want := map[string]bool{}
	for _, n := range names {
		want[n] = true
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		stem := strings.ToLower(strings.TrimSuffix(e.Name(), filepath.Ext(e.Name())))
		if want[stem] {
			ext := strings.ToLower(filepath.Ext(e.Name()))
			for _, a := range artExts {
				if ext == a {
					return filepath.Join(dir, e.Name()), true
				}
			}
		}
	}
	return "", false
}

// mediaDirFor returns the folder that contains the media item.
func (s *Server) mediaDirFor(kind string, id int64) (string, error) {
	switch kind {
	case "movie":
		full, err := s.resolveMediaFile("movie", id)
		if err != nil {
			return "", err
		}
		return filepath.Dir(full), nil
	case "episode":
		full, err := s.resolveMediaFile("episode", id)
		if err != nil {
			return "", err
		}
		return filepath.Dir(full), nil
	case "show":
		sh, err := s.getShow(id)
		if err != nil {
			return "", err
		}
		return findShowDir(s.conf.MediaDir, sh.Title)
	}
	return "", fmt.Errorf("unknown kind %q", kind)
}

func findShowDir(mediaDir, title string) (string, error) {
	base := filepath.Join(mediaDir, "Shows")
	entries, err := os.ReadDir(base)
	if err != nil {
		return "", err
	}
	for _, e := range entries {
		if e.IsDir() && cleanTitle(e.Name()) == cleanTitle(title) {
			return filepath.Join(base, e.Name()), nil
		}
	}
	return "", fmt.Errorf("show folder not found")
}

// handleArt serves a named artwork slot from the media item's folder.
func (s *Server) handleArt(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	slot := strings.ToLower(r.PathValue("name"))
	if _, ok := artSlots[slot]; !ok {
		writeError(w, 404, "unknown art slot")
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	dir, err := s.mediaDirFor(kind, id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	full, ok := findArtFile(dir, artSlots[slot])
	if !ok {
		writeError(w, 404, "no such artwork")
		return
	}
	http.ServeFile(w, r, full)
}

// ---- subtitles ----

// iso639 maps common codes to display names. Subtitle languages are matched
// from filename tokens like "Movie.en.srt" or "Subs/Fra.srt".
var iso639 = map[string]string{
	"en": "English", "eng": "English",
	"fr": "French", "fra": "French",
	"de": "German", "deu": "German", "ger": "German",
	"es": "Spanish", "spa": "Spanish",
	"it": "Italian", "ita": "Italian",
	"pt": "Portuguese", "por": "Portuguese",
	"nl": "Dutch", "nld": "Dutch", "dut": "Dutch",
	"ru": "Russian", "rus": "Russian",
	"pl": "Polish", "pol": "Polish",
	"sv": "Swedish", "swe": "Swedish",
	"da": "Danish", "dan": "Danish",
	"no": "Norwegian", "nor": "Norwegian",
	"fi": "Finnish", "fin": "Finnish",
	"cs": "Czech", "ces": "Czech",
	"hu": "Hungarian", "hun": "Hungarian",
	"ja": "Japanese", "jpn": "Japanese",
	"zh": "Chinese", "zho": "Chinese", "chi": "Chinese",
	"ko": "Korean", "kor": "Korean",
	"ar": "Arabic", "ara": "Arabic",
	"hi": "Hindi", "hin": "Hindi",
	"tr": "Turkish", "tur": "Turkish",
	"el": "Greek", "ell": "Greek",
	"he": "Hebrew", "heb": "Hebrew",
	"th": "Thai", "tha": "Thai",
	"vi": "Vietnamese", "vie": "Vietnamese",
}

func subtitleExt(s string) bool {
	e := strings.ToLower(filepath.Ext(s))
	return e == ".srt" || e == ".vtt" || e == ".ass" || e == ".ssa" || e == ".sub"
}

type subFile struct {
	Path string
	Lang string
	Code string
	Name string
}

// findSubtitles scans an item folder for external subtitle files.
func findSubtitles(dir, videoStem string) []subFile {
	videoStem = strings.ToLower(videoStem)
	var files []string
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if e.IsDir() || !subtitleExt(e.Name()) {
			continue
		}
		files = append(files, filepath.Join(dir, e.Name()))
	}
	// sub folders are checked too
	for _, sub := range []string{"subs", "subtitles", "Subs", "Subtitles"} {
		subDir := filepath.Join(dir, sub)
		if se, err := os.ReadDir(subDir); err == nil {
			for _, e := range se {
				if !e.IsDir() && subtitleExt(e.Name()) {
					files = append(files, filepath.Join(subDir, e.Name()))
				}
			}
		}
	}
	out := make([]subFile, 0)
	for _, f := range files {
		stem := strings.ToLower(strings.TrimSuffix(filepath.Base(f), filepath.Ext(f)))
		code := ""
		if strings.HasPrefix(stem, videoStem) {
			code = strings.TrimSpace(strings.TrimPrefix(stem, videoStem))
			code = strings.TrimLeft(code, ".-_ ")
		} else if n := strings.Index(stem, "."+videoStem); n > 0 {
			code = stem[:n]
		}
		name := code
		langName := ""
		if code != "" {
			if nm, ok := iso639[strings.ToLower(code)]; ok {
				langName = nm
				name = nm
			}
		}
		if name == "" {
			name = filepath.Base(f)
		}
		out = append(out, subFile{Path: f, Lang: langName, Code: code, Name: name})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

type subtitleTrack struct {
	Index    int    `json:"index"`
	URL      string `json:"url"`
	Language string `json:"language,omitempty"`
	Name     string `json:"name"`
}

func (s *Server) subtitleTracks(kind string, id int64) ([]subtitleTrack, error) {
	dir, err := s.mediaDirFor(kind, id)
	if err != nil {
		return nil, err
	}
	full, err := s.resolveMediaFile(kind, id)
	if err != nil {
		return nil, err
	}
	stem := strings.TrimSuffix(filepath.Base(full), filepath.Ext(full))
	subs := findSubtitles(dir, stem)
	route := "movies"
	if kind == "episode" {
		route = "episodes"
	}
	out := make([]subtitleTrack, 0, len(subs))
	for i, sf := range subs {
		mime := "text/plain"
		if strings.EqualFold(filepath.Ext(sf.Path), ".vtt") {
			mime = "text/vtt"
		}
		_ = mime
		out = append(out, subtitleTrack{
			Index:    i,
			URL:      fmt.Sprintf("/api/%s/%d/subtitles/%d", route, id, i),
			Language: sf.Lang,
			Name:     sf.Name,
		})
	}
	return out, nil
}

func (s *Server) handleSubtitle(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	idx, err := strconv.Atoi(r.PathValue("index"))
	if err != nil {
		writeError(w, 400, "bad index")
		return
	}
	dir, err := s.mediaDirFor(kind, id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	full, err := s.resolveMediaFile(kind, id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	stem := strings.TrimSuffix(filepath.Base(full), filepath.Ext(full))
	subs := findSubtitles(dir, stem)
	if idx < 0 || idx >= len(subs) {
		writeError(w, 404, "subtitle not found")
		return
	}
	ext := strings.ToLower(filepath.Ext(subs[idx].Path))
	switch ext {
	case ".vtt":
		w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	case ".ass", ".ssa":
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	default:
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	}
	http.ServeFile(w, r, subs[idx].Path)
}

// ---- audio tracks ----

type audioTrack struct {
	Index    int    `json:"index"`
	Language string `json:"language,omitempty"`
	Title    string `json:"title,omitempty"`
	Default  bool   `json:"default"`
}

type trackCacheEntry struct {
	tracks   []audioTrack
	probedAt time.Time
}

var (
	trackCacheMu sync.Mutex
	trackCache   = map[string]trackCacheEntry{}
)

// audioTracksFor lists audio streams via ffprobe, cached briefly.
func audioTracksFor(full string) []audioTrack {
	fi, err := os.Stat(full)
	if err != nil {
		return nil
	}
	key := fmt.Sprintf("%s|%d|%d", full, fi.Size(), fi.ModTime().UnixNano())
	trackCacheMu.Lock()
	if e, ok := trackCache[key]; ok && time.Since(e.probedAt) < 30*time.Minute {
		trackCacheMu.Unlock()
		return e.tracks
	}
	trackCacheMu.Unlock()

	probe, err := exec.LookPath("ffprobe")
	tracks := make([]audioTrack, 0)
	if err == nil {
		out, perr := exec.Command(probe, "-v", "error",
			"-select_streams", "a",
			"-show_entries", "stream=index:stream_tags=language,title",
			"-of", "json", full).Output()
		if perr == nil {
			var res struct {
				Streams []struct {
					Index int `json:"index"`
					Tags  struct {
						Language string `json:"language"`
						Title    string `json:"title"`
					} `json:"tags"`
				} `json:"streams"`
			}
			if json.Unmarshal(out, &res) == nil {
				for i, s := range res.Streams {
					lang := s.Tags.Language
					if lang == "" {
						lang = "Unknown"
					}
					name := s.Tags.Title
					if name == "" {
						name = lang
					}
					tracks = append(tracks, audioTrack{
						Index:    s.Index,
						Language: lang,
						Title:    name,
						Default:  i == 0,
					})
				}
			}
		}
	}
	trackCacheMu.Lock()
	trackCache[key] = trackCacheEntry{tracks: tracks, probedAt: time.Now()}
	trackCacheMu.Unlock()
	return tracks
}

func (s *Server) handleTracks(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	full, err := s.resolveMediaFile(kind, id)
	if err != nil {
		writeError(w, 404, "media not found")
		return
	}
	subs, err := s.subtitleTracks(kind, id)
	if err != nil {
		subs = make([]subtitleTrack, 0)
	}
	writeJSON(w, 200, map[string]any{
		"subtitles":    subs,
		"audio_tracks": audioTracksFor(full),
	})
}

// setLocalArt stores user-supplied artwork URLs in the DB (preferred over TMDB).
// When stem is non-empty (a loose file in a shared folder), only art named like
// "<stem>-poster.jpg" is accepted so one poster does not leak across movies.
func (s *Server) setLocalArt(kind string, id int64, dir string, stem string) {
	var table, posterCol, backdropCol string
	switch kind {
	case "movie":
		table, posterCol, backdropCol = "movies", "poster", "backdrop"
	case "show":
		table, posterCol, backdropCol = "shows", "poster", "backdrop"
	case "episode":
		table, posterCol, backdropCol = "episodes", "still", "still"
	default:
		return
	}
	artBase := "/api/" + kindPlural(kind) + "/" + strconv.FormatInt(id, 10) + "/art"
	posterNames := []string{"poster", "folder"}
	backdropNames := []string{"backdrop", "fanart"}
	if stem != "" {
		stem = strings.ToLower(stem)
		posterNames = []string{stem + "-poster", stem + "-folder"}
		backdropNames = []string{stem + "-backdrop", stem + "-fanart"}
	}
	if _, ok := findArtFile(dir, posterNames); ok {
		s.db.Exec(fmt.Sprintf("UPDATE %s SET %s=? WHERE id=?", table, posterCol), artBase+"/poster", id)
	}
	if _, ok := findArtFile(dir, backdropNames); ok && kind != "episode" {
		s.db.Exec(fmt.Sprintf("UPDATE %s SET %s=? WHERE id=?", table, backdropCol), artBase+"/backdrop", id)
	}
}

var supportedVideoCodecs = map[string]bool{
	"h264": true, "hevc": true, "h265": true, "mpeg4": true, "mpeg2video": true,
	"vp8": true, "vp9": true, "av1": true, "wmv3": true, "vc1": true,
	"msmpeg4v3": true, "msmpeg4v2": true,
}

var supportedAudioCodecs = map[string]bool{
	"aac": true, "mp3": true, "ac3": true, "eac3": true, "dts": true,
	"flac": true, "opus": true, "vorbis": true, "mlp": true, "truehd": true,
	"mp2": true, "pcm_s16le": true,
}

type mediaFormat struct {
	Container     string `json:"container"`
	VideoCodec    string `json:"video_codec"`
	VideoWidth    int    `json:"video_width"`
	VideoHeight   int    `json:"video_height"`
	VideoFPS      string `json:"video_fps,omitempty"`
	AudioCodec    string `json:"audio_codec,omitempty"`
	AudioChannels int    `json:"audio_channels"`
	SampleRate    int    `json:"sample_rate"`
	DurationSec   int64  `json:"duration_sec"`
	Supported     bool   `json:"supported"`
	Reason        string `json:"reason,omitempty"`
}

// probeFormat inspects a media file with ffprobe and reports whether the
// server can transcode it for browser playback.
func probeFormat(full string) (mediaFormat, error) {
	f := mediaFormat{}
	probe, err := exec.LookPath("ffprobe")
	if err != nil {
		return f, fmt.Errorf("ffprobe not installed on the server")
	}
	out, perr := exec.Command(probe, "-v", "error",
		"-show_format", "-show_streams", "-of", "json", full).Output()
	if perr != nil {
		return f, fmt.Errorf("cannot read file (corrupt or unsupported?): %s", strings.TrimSpace(string(out)))
	}
	var res struct {
		Format struct {
			FormatName string `json:"format_name"`
			Duration   string `json:"duration"`
		} `json:"format"`
		Streams []struct {
			CodecType    string `json:"codec_type"`
			CodecName    string `json:"codec_name"`
			Width        int    `json:"width"`
			Height       int    `json:"height"`
			AvgFrameRate string `json:"avg_frame_rate"`
			Channels     int    `json:"channels"`
			SampleRate   string `json:"sample_rate"`
			SampleFmt    string `json:"sample_fmt"`
		} `json:"streams"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		return f, fmt.Errorf("could not parse media info")
	}
	f.Container = res.Format.FormatName
	if d, err := strconv.ParseFloat(res.Format.Duration, 64); err == nil {
		f.DurationSec = int64(d)
	}
	for _, st := range res.Streams {
		switch st.CodecType {
		case "video":
			if f.VideoCodec == "" {
				f.VideoCodec = st.CodecName
				f.VideoWidth = st.Width
				f.VideoHeight = st.Height
				f.VideoFPS = st.AvgFrameRate
			}
		case "audio":
			if f.AudioCodec == "" {
				f.AudioCodec = st.CodecName
				f.AudioChannels = st.Channels
				f.SampleRate, _ = strconv.Atoi(st.SampleRate)
			}
		}
	}
	switch {
	case f.VideoCodec == "":
		f.Reason = "no video stream found"
	case !supportedVideoCodecs[f.VideoCodec]:
		f.Reason = fmt.Sprintf("video codec \"%s\" is not supported", f.VideoCodec)
	case f.AudioCodec != "" && !supportedAudioCodecs[f.AudioCodec]:
		f.Reason = fmt.Sprintf("audio codec \"%s\" is not supported", f.AudioCodec)
	default:
		f.Supported = true
	}
	return f, nil
}

func (s *Server) handleDetect(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	full, err := s.resolveMediaFile(kind, id)
	if err != nil {
		writeError(w, 404, "media not found")
		return
	}
	f, err := probeFormat(full)
	if err != nil {
		f = mediaFormat{Supported: false, Reason: err.Error()}
	}
	writeJSON(w, 200, f)
}

func kindPlural(kind string) string {
	switch kind {
	case "movie":
		return "movies"
	case "show":
		return "shows"
	case "episode":
		return "episodes"
	}
	return kind
}
