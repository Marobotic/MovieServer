package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// On-the-fly HLS transcoding/remuxing via ffmpeg. Browsers cannot play MKV,
// HEVC-in-MKV and many other real-world files, so anything that isn't
// H.264/AAC in a browser-friendly container is converted to a growing HLS
// playlist that hls.js (web) and libmpv (native) both play natively.

type hlsJob struct {
	dir        string
	cmd        *exec.Cmd
	lastAccess time.Time
}

var (
	hlsMu     sync.Mutex
	hlsJobs   = map[string]*hlsJob{}
	hlsOnce   sync.Once
	ffmpegBin string
	ffprobe   string
)

func hlsInit() {
	hlsOnce.Do(func() {
		ffprobe, _ = exec.LookPath("ffprobe")
		ffmpegBin, _ = exec.LookPath("ffmpeg")
		go hlsJanitor()
	})
}

func hlsBaseDir() string {
	dir := filepath.Join(os.TempDir(), "movieserver-hls")
	os.MkdirAll(dir, 0o755)
	return dir
}

// hlsJobKey produces a deterministic, start-aware key for a media item.
func hlsJobKey(kind string, id, start int) string {
	return fmt.Sprintf("%s-%d-%d", kind, id, start)
}

// killJob terminates an ffmpeg job and reaps the process so it does not
// remain as a zombie.
func killJob(j *hlsJob) {
	if j == nil || j.cmd == nil || j.cmd.Process == nil {
		return
	}
	j.cmd.Process.Kill()
	j.cmd.Wait()
}

// hlsJanitor kills idle ffmpeg jobs so stale processes do not pile up.
func hlsJanitor() {
	for range time.Tick(5 * time.Minute) {
		hlsMu.Lock()
		now := time.Now()
		for k, j := range hlsJobs {
			if now.Sub(j.lastAccess) > 30*time.Minute {
				killJob(j)
				os.RemoveAll(j.dir)
				delete(hlsJobs, k)
			}
		}
		hlsMu.Unlock()
	}
}

// probeCodecs returns the codecs of the first video and audio stream.
func probeCodecs(file string) (video string, audio string, err error) {
	if ffprobe == "" {
		return "", "", fmt.Errorf("ffprobe not found")
	}
	out, err := exec.Command(ffprobe, "-v", "error",
		"-show_entries", "stream=codec_type,codec_name",
		"-of", "json", file).Output()
	if err != nil {
		return "", "", fmt.Errorf("ffprobe failed: %w", err)
	}
	var res struct {
		Streams []struct {
			CodecType string `json:"codec_type"`
			CodecName string `json:"codec_name"`
		} `json:"streams"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		return "", "", fmt.Errorf("parse probe: %w", err)
	}
	for _, st := range res.Streams {
		switch st.CodecType {
		case "video":
			if video == "" {
				video = st.CodecName
			}
		case "audio":
			if audio == "" {
				audio = st.CodecName
			}
		}
	}
	if video == "" {
		return "", "", fmt.Errorf("no video stream found")
	}
	return video, audio, nil
}

// resolveMediaFile maps a (kind, id) to its absolute path on disk.
func (s *Server) resolveMediaFile(kind string, id int64) (string, error) {
	switch kind {
	case "movie":
		m, err := s.getMovie(id)
		if err != nil {
			return "", err
		}
		return resolveRel(s.conf.MediaDir, m.FilePath)
	case "episode":
		e, err := s.getEpisode(id)
		if err != nil {
			return "", err
		}
		return resolveRel(s.conf.MediaDir, e.FilePath)
	}
	return "", fmt.Errorf("unknown media kind %q", kind)
}

// ensureHLSJob starts (or reuses) an ffmpeg job producing HLS for the item and
// blocks until the first segment is ready.
func (s *Server) ensureHLSJob(kind string, id, start int) (string, error) {
	hlsInit()
	if ffmpegBin == "" {
		return "", fmt.Errorf("ffmpeg not found")
	}

	full, err := s.resolveMediaFile(kind, int64(id))
	if err != nil {
		return "", err
	}

	key := hlsJobKey(kind, id, start)
	hlsMu.Lock()
	if j, ok := hlsJobs[key]; ok {
		j.lastAccess = time.Now()
		hlsMu.Unlock()
		return j.dir, nil
	}
	hlsMu.Unlock()

	video, audio, err := probeCodecs(full)
	if err != nil {
		return "", err
	}
	copyVideo := video == "h264"
	copyAudio := audio == "" || audio == "aac" || audio == "mp3"

	dir := filepath.Join(hlsBaseDir(), key)
	os.RemoveAll(dir)
	os.MkdirAll(dir, 0o755)

	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin"}
	if start > 0 {
		args = append(args, "-ss", strconv.Itoa(start))
	}
	args = append(args, "-i", full)
	switch {
	case copyVideo && copyAudio:
		args = append(args, "-map", "0:v:0", "-map", "0:a?", "-c:v", "copy", "-c:a", "copy")
	case copyVideo:
		// Video is already browser-playable (H.264); only the audio needs
		// converting, so keep CPU cost minimal instead of re-encoding video.
		args = append(args, "-map", "0:v:0", "-map", "0:a?",
			"-c:v", "copy",
			"-c:a", "aac", "-b:a", "128k")
	default:
		args = append(args, "-map", "0:v:0", "-map", "0:a?",
			"-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p",
			"-c:a", "aac", "-b:a", "128k")
	}
	args = append(args,
		"-f", "hls", "-hls_time", "10", "-hls_list_size", "0", "-hls_playlist_type", "vod",
		"-hls_segment_filename", filepath.Join(dir, "seg_%05d.ts"),
		filepath.Join(dir, "index.m3u8"))

	cmd := exec.Command(ffmpegBin, args...)
	logF, err := os.Create(filepath.Join(dir, "ffmpeg.log"))
	if err != nil {
		return "", err
	}
	cmd.Stdout = logF
	cmd.Stderr = logF
	if err := cmd.Start(); err != nil {
		logF.Close()
		return "", err
	}

	job := &hlsJob{dir: dir, cmd: cmd, lastAccess: time.Now()}
	hlsMu.Lock()
	// A concurrent request for the same key wins; ours is killed.
	if old, ok := hlsJobs[key]; ok {
		killJob(old)
		os.RemoveAll(old.dir)
	}
	hlsJobs[key] = job
	hlsMu.Unlock()

	if s.waitForSegments(job) != nil {
		killJob(job)
		logF.Close()
		hlsMu.Lock()
		delete(hlsJobs, key)
		hlsMu.Unlock()
		return "", fmt.Errorf("transcoding failed, see %s/ffmpeg.log", dir)
	}
	return dir, nil
}

// waitForSegments polls until at least one non-empty segment exists or the
// ffmpeg process exits.
func (s *Server) waitForSegments(job *hlsJob) error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if job.cmd.ProcessState != nil {
			return fmt.Errorf("ffmpeg exited early")
		}
		segs, _ := filepath.Glob(filepath.Join(job.dir, "seg_*.ts"))
		for _, f := range segs {
			if fi, err := os.Stat(f); err == nil && fi.Size() > 0 {
				return nil
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for first segment")
}

// handleHLSMaster starts the job and serves the playlist with token-bearing
// segment URLs so browser players can fetch everything themselves.
func (s *Server) handleHLSMaster(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
	_ = u
	token := r.URL.Query().Get("token")
	if token == "" {
		if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
			token = strings.TrimPrefix(h, "Bearer ")
		}
	}
	start, _ := strconv.Atoi(r.URL.Query().Get("start"))

	var kind, rawID string
	switch {
	case r.Pattern == "GET /api/movies/{id}/hls/master.m3u8":
		kind = "movie"
		rawID = r.PathValue("id")
	case r.Pattern == "GET /api/episodes/{id}/hls/master.m3u8":
		kind = "episode"
		rawID = r.PathValue("id")
	default:
		writeError(w, 404, "not found")
		return
	}
	id, err := strconv.ParseInt(rawID, 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}

	dir, err := s.ensureHLSJob(kind, int(id), start)
	if err != nil {
		writeError(w, 500, "transcoding failed: "+err.Error())
		return
	}
	hlsMu.Lock()
	if j, ok := hlsJobs[hlsJobKey(kind, int(id), start)]; ok {
		j.lastAccess = time.Now()
	}
	hlsMu.Unlock()

	data, err := os.ReadFile(filepath.Join(dir, "index.m3u8"))
	if err != nil {
		writeError(w, 500, "playlist not ready")
		return
	}
	key := hlsJobKey(kind, int(id), start)
	lines := strings.Split(string(data), "\n")
	for i, ln := range lines {
		if strings.HasPrefix(ln, "seg_") {
			base := strings.TrimSuffix(ln, "\r")
			lines[i] = "/api/hls/" + key + "/" + base + "?token=" + token
		}
	}
	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.WriteHeader(200)
	w.Write([]byte(strings.Join(lines, "\n")))
}

// handleHLSSegment serves an individual .ts segment out of a running job.
func (s *Server) handleHLSSegment(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("job")
	file := r.PathValue("file")
	if key == "" || file == "" || strings.Contains(file, "..") {
		writeError(w, 404, "not found")
		return
	}
	hlsMu.Lock()
	j, ok := hlsJobs[key]
	if ok {
		j.lastAccess = time.Now()
	}
	hlsMu.Unlock()
	if !ok {
		writeError(w, 404, "job expired")
		return
	}
	s.serveVideoFile(w, r, filepath.Join(j.dir, file))
}