package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

type TrickplayManifest struct {
	Interval int     `json:"interval"`
	Cols     int     `json:"cols"`
	Rows     int     `json:"rows"`
	ThumbW   int     `json:"thumb_w"`
	ThumbH   int     `json:"thumb_h"`
	Count    int     `json:"count"`
	Sprites  int     `json:"sprites"`
	SrcSize  int64   `json:"src_size"`
	SrcMtime int64   `json:"src_mtime"`
}

var trickplayMu sync.Mutex

func (s *Server) trickplayDir(kind string, id int64) string {
	dir := filepath.Join(s.conf.DataDir, "trickplay", fmt.Sprintf("%s-%d", kind, id))
	_ = os.MkdirAll(dir, 0o755)
	return dir
}

func (s *Server) handleTrickplayManifest(w http.ResponseWriter, r *http.Request) {
	kind := "movie"
	if strings.Contains(r.URL.Path, "/episodes/") {
		kind = "episode"
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}

	dir := s.trickplayDir(kind, id)
	manifestPath := filepath.Join(dir, "manifest.json")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		// If manifest doesn't exist, try to generate it in background if idle
		go s.ensureTrickplay(kind, id)
		writeError(w, 404, "trickplay not ready")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write(data)
}

func (s *Server) handleTrickplayImage(w http.ResponseWriter, r *http.Request) {
	kind := "movie"
	if strings.Contains(r.URL.Path, "/episodes/") {
		kind = "episode"
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	file := r.PathValue("file")
	if !strings.HasSuffix(file, ".jpg") {
		writeError(w, 400, "bad image filename")
		return
	}

	dir := s.trickplayDir(kind, id)
	imgPath := filepath.Join(dir, file)
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	http.ServeFile(w, r, imgPath)
}

func (s *Server) ensureTrickplay(kind string, id int64) {
	trickplayMu.Lock()
	defer trickplayMu.Unlock()

	dir := s.trickplayDir(kind, id)
	manifestPath := filepath.Join(dir, "manifest.json")
	if _, err := os.Stat(manifestPath); err == nil {
		return
	}

	src, err := s.resolveMediaFile(kind, id)
	if err != nil {
		return
	}
	fi, err := os.Stat(src)
	if err != nil {
		return
	}

	check := s.getCheck(kind, id)
	durSec := int64(0)
	if check != nil {
		durSec = check.DurationSec
	}
	if durSec <= 0 {
		return
	}

	const interval = 10
	const cols = 10
	const rows = 10
	const thumbW = 320

	// Use nice 19 and ionice 3
	pattern := filepath.Join(dir, "sprite_%03d.jpg")
	args := []string{
		"-hide_banner", "-loglevel", "error", "-nostdin", "-y",
		"-skip_frame", "nokey",
		"-i", src,
		"-an", "-sn",
		"-vf", fmt.Sprintf("fps=1/%d,scale=%d:-2,tile=%dx%d", interval, thumbW, cols, rows),
		"-fps_mode", "vfr",
		"-q:v", "4",
		pattern,
	}

	cmd := exec.Command("nice", append([]string{"-n", "19", "ionice", "-c", "3", ffmpegBin}, args...)...)
	if err := cmd.Run(); err != nil {
		// Fallback without nice/ionice wrapper if not permitted
		cmd = exec.Command(ffmpegBin, args...)
		if err := cmd.Run(); err != nil {
			return
		}
	}

	// Count generated sprites
	entries, _ := os.ReadDir(dir)
	spriteCount := 0
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "sprite_") && strings.HasSuffix(e.Name(), ".jpg") {
			spriteCount++
		}
	}
	if spriteCount == 0 {
		return
	}

	// Read thumb height from first sprite
	thumbH := 180
	firstSprite := filepath.Join(dir, "sprite_001.jpg")
	if out, err := exec.Command(ffprobe, "-v", "error", "-select_streams", "v:0",
		"-show_entries", "stream=height", "-of", "csv=p=0", firstSprite).Output(); err == nil {
		if h, err := strconv.Atoi(strings.TrimSpace(string(out))); err == nil && h > 0 {
			thumbH = h / rows
		}
	}

	totalThumbs := int(math.Ceil(float64(durSec) / float64(interval)))
	manifest := TrickplayManifest{
		Interval: interval,
		Cols:     cols,
		Rows:     rows,
		ThumbW:   thumbW,
		ThumbH:   thumbH,
		Count:    totalThumbs,
		Sprites:  spriteCount,
		SrcSize:  fi.Size(),
		SrcMtime: fi.ModTime().Unix(),
	}

	manifestData, _ := json.MarshalIndent(manifest, "", "  ")
	_ = os.WriteFile(manifestPath, manifestData, 0o644)
}
