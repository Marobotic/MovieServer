package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// Subtitles that ship inside the video file.
//
// Most releases mux their own subtitle track, and it is the one source that
// cannot be out of sync: whoever made the file timed it against that exact
// cut. Nothing to search for, nothing to correct. This makes those tracks
// selectable alongside the .srt files sitting next to the video.

// embeddedSub describes one subtitle stream inside a container.
type embeddedSub struct {
	StreamIndex int    // absolute ffmpeg stream index
	SubIndex    int    // position among subtitle streams, for -map 0:s:N
	Language    string
	Title       string
	Codec       string
	Forced      bool
	Default     bool
}

// Label is what the player shows in the track list.
func (e embeddedSub) Label() string {
	name := strings.TrimSpace(e.Title)
	if name == "" {
		name = languageName(e.Language)
	}
	if e.Forced {
		name += " (forced)"
	}
	return name + " - in video"
}

func languageName(code string) string {
	switch strings.ToLower(code) {
	case "eng", "en":
		return "English"
	case "ara", "ar":
		return "Arabic"
	case "fre", "fra", "fr":
		return "French"
	case "ger", "deu", "de":
		return "German"
	case "spa", "es":
		return "Spanish"
	case "ita", "it":
		return "Italian"
	case "dut", "nld", "nl":
		return "Dutch"
	case "por", "pt":
		return "Portuguese"
	case "rus", "ru":
		return "Russian"
	case "":
		return "Unknown"
	}
	return strings.ToUpper(code)
}

// textSubCodecs are the ones that convert cleanly to SRT. Bitmap subtitles
// (PGS, VobSub) are pictures of text and would need OCR, so they are skipped
// rather than offered and then failing to display.
var textSubCodecs = map[string]bool{
	"subrip": true, "srt": true, "ass": true, "ssa": true,
	"mov_text": true, "webvtt": true, "text": true,
}

var (
	embeddedCacheMu sync.Mutex
	embeddedCache   = map[string][]embeddedSub{}
)

// embeddedSubtitles lists the text subtitle streams inside a video.
func embeddedSubtitles(path string) []embeddedSub {
	fi, err := os.Stat(path)
	if err != nil {
		return nil
	}
	key := fmt.Sprintf("%s|%d|%d", path, fi.Size(), fi.ModTime().UnixNano())

	embeddedCacheMu.Lock()
	if v, ok := embeddedCache[key]; ok {
		embeddedCacheMu.Unlock()
		return v
	}
	embeddedCacheMu.Unlock()

	probe, err := exec.LookPath("ffprobe")
	if err != nil {
		return nil
	}
	out, err := exec.Command(probe, "-v", "error",
		"-select_streams", "s",
		"-show_entries", "stream=index,codec_name:stream_tags=language,title:stream_disposition=forced,default",
		"-of", "json", path).Output()
	if err != nil {
		return nil
	}
	var res struct {
		Streams []struct {
			Index       int    `json:"index"`
			CodecName   string `json:"codec_name"`
			Disposition struct {
				Forced  int `json:"forced"`
				Default int `json:"default"`
			} `json:"disposition"`
			Tags struct {
				Language string `json:"language"`
				Title    string `json:"title"`
			} `json:"tags"`
		} `json:"streams"`
	}
	if json.Unmarshal(out, &res) != nil {
		return nil
	}

	subs := make([]embeddedSub, 0, len(res.Streams))
	for i, st := range res.Streams {
		if !textSubCodecs[strings.ToLower(st.CodecName)] {
			continue
		}
		subs = append(subs, embeddedSub{
			StreamIndex: st.Index,
			SubIndex:    i,
			Language:    st.Tags.Language,
			Title:       st.Tags.Title,
			Codec:       st.CodecName,
			Forced:      st.Disposition.Forced != 0,
			Default:     st.Disposition.Default != 0,
		})
	}

	embeddedCacheMu.Lock()
	embeddedCache[key] = subs
	embeddedCacheMu.Unlock()
	return subs
}

// extractEmbedded pulls one subtitle stream out as SRT, caching the result so
// a second request costs nothing.
func (s *Server) extractEmbedded(video string, sub embeddedSub) (string, error) {
	fi, err := os.Stat(video)
	if err != nil {
		return "", err
	}
	cacheDir := filepath.Join(s.dataDir, "embedded-subs")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return "", err
	}
	stem := strings.TrimSuffix(filepath.Base(video), filepath.Ext(video))
	name := fmt.Sprintf("%s.%d.%d.srt", sanitiseName(stem), fi.ModTime().Unix(), sub.SubIndex)
	dest := filepath.Join(cacheDir, name)
	if fi2, err := os.Stat(dest); err == nil && fi2.Size() > 0 {
		return dest, nil
	}

	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		return "", fmt.Errorf("ffmpeg not installed")
	}
	tmp := dest + ".part"
	// The temp name ends in .part, so the muxer has to be named explicitly -
	// ffmpeg will not infer it from that extension.
	cmd := exec.Command(ff, "-nostdin", "-hide_banner", "-y",
		"-i", video,
		"-map", "0:s:"+strconv.Itoa(sub.SubIndex),
		"-c:s", "srt", "-f", "srt", tmp)
	if out, err := cmd.CombinedOutput(); err != nil {
		os.Remove(tmp)
		// ffmpeg's useful line is the last one, not the banner at the top.
		lines := strings.Split(strings.TrimSpace(string(out)), "\n")
		return "", fmt.Errorf("could not extract subtitle: %s",
			truncateStr(lines[len(lines)-1], 200))
	}
	if fi2, err := os.Stat(tmp); err != nil || fi2.Size() == 0 {
		os.Remove(tmp)
		return "", fmt.Errorf("extracted subtitle was empty")
	}
	if err := os.Rename(tmp, dest); err != nil {
		return "", err
	}
	return dest, nil
}

// sanitiseName keeps cache filenames tame.
func sanitiseName(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '-', r == '_', r == '.':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}
