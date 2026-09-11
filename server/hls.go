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

// On-the-fly HLS transcoding/remuxing via ffmpeg. Browsers cannot play MKV,
// HEVC-in-MKV and many other real-world files, so anything that isn't
// H.264/AAC in a browser-friendly container is converted to a growing HLS
// playlist that hls.js (web) and libmpv (native) both play natively.

type hlsJob struct {
	dir        string
	cmd        *exec.Cmd
	done       chan error
	logF       *os.File
	lastAccess time.Time
	starting   bool // placeholder jobs older than a moment are stale
}

var (
	hlsMu      sync.Mutex
	hlsJobs    = map[string]*hlsJob{}
	hlsOnce    sync.Once
	ffmpegBin  string
	ffprobe    string
	hlsDataDir string
)

func hlsInit() {
	hlsOnce.Do(func() {
		ffprobe, _ = exec.LookPath("ffprobe")
		ffmpegBin, _ = exec.LookPath("ffmpeg")
		go hlsJanitor()
	})
}

// hlsBaseDir returns the on-disk scratch dir for HLS jobs. It lives next to
// the database (not under /tmp, which is tmpfs/RAM here). Callers pass the
// data dir the first time so the janitor knows where to sweep.
func (s *Server) hlsBaseDir() string {
	hlsMu.Lock()
	defer hlsMu.Unlock()
	if hlsDataDir == "" {
		hlsDataDir = filepath.Join(s.conf.DataDir, "hls")
		os.MkdirAll(hlsDataDir, 0o755)
	}
	return hlsDataDir
}

// hlsJobKey produces a deterministic, start-aware key for a media item.
func hlsJobKey(kind string, id, start int) string {
	return fmt.Sprintf("%s-%d-%d", kind, id, start)
}

// hlsFullKey extends the job key with the chosen audio stream index so
// different audio selections get separate jobs (and segments).
func hlsFullKey(kind string, id, start, audioIdx int) string {
	key := hlsJobKey(kind, id, start)
	if audioIdx >= 0 {
		key = fmt.Sprintf("%s-a%d", key, audioIdx)
	}
	return key
}

// killJob terminates an ffmpeg job. The reaper goroutine owned by the job
// calls Wait(), which prevents zombies; killJob never blocks on Wait.
func killJob(j *hlsJob) {
	if j == nil || j.cmd == nil || j.cmd.Process == nil {
		return
	}
	j.cmd.Process.Kill()
}

// hlsJanitor kills idle ffmpeg jobs and enforces a total scratch size cap so
// stale processes and segments do not pile up (the dir lives on disk).
func hlsJanitor() {
	for range time.Tick(5 * time.Minute) {
		hlsMu.Lock()
		now := time.Now()
		for k, j := range hlsJobs {
			if j.starting {
				continue
			}
			if now.Sub(j.lastAccess) > 30*time.Minute {
				killJob(j)
				os.RemoveAll(j.dir)
				delete(hlsJobs, k)
			}
		}
		hlsMu.Unlock()
		if hlsDataDir != "" {
			sweepHLSDir()
		}
	}
}

// sweepHLSDir enforces a 20GB cap on the HLS scratch dir, deleting the least
// recently accessed job folders first.
func sweepHLSDir() {
	dirs, _ := os.ReadDir(hlsDataDir)
	var total int64
	type jobDir struct {
		path string
		at   time.Time
	}
	var jobs []jobDir
	hlsMu.Lock()
	for _, d := range dirs {
		full := filepath.Join(hlsDataDir, d.Name())
		var size int64
		filepath.WalkDir(full, func(p string, de os.DirEntry, err error) error {
			if err == nil && !de.IsDir() {
				if fi, e := de.Info(); e == nil {
					size += fi.Size()
				}
			}
			return nil
		})
		at := time.Now()
		if j, ok := hlsJobs[d.Name()]; ok && !j.starting {
			at = j.lastAccess
		}
		total += size
		jobs = append(jobs, jobDir{full, at})
	}
	hlsMu.Unlock()
	if total <= 20<<30 {
		return
	}
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].at.Before(jobs[j].at) })
	var freed int64
	for _, j := range jobs {
		if j.at.Add(5 * time.Minute).After(time.Now()) {
			break // never delete something that is actively serving
		}
		os.RemoveAll(j.path)
		freed, _ = dirSize(j.path)
		_ = freed
		total -= freed
		if total <= 20<<30 {
			break
		}
	}
}

func dirSize(dir string) (int64, error) {
	var n int64
	err := filepath.WalkDir(dir, func(p string, de os.DirEntry, err error) error {
		if err == nil && !de.IsDir() {
			if fi, e := de.Info(); e == nil {
				n += fi.Size()
			}
		}
		return nil
	})
	return n, err
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

// waitForSegments blocks until at least one non-empty segment exists or the
// ffmpeg process exits.
func (s *Server) waitForSegments(job *hlsJob) error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-job.done:
			return fmt.Errorf("ffmpeg exited early")
		default:
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

// ensureHLSJob starts (or reuses) an ffmpeg job producing HLS for the item and
// blocks until the first segment is ready. audioIdx selects one audio stream
// (-map 0:a:audioIdx); -1 maps all audio streams.
func (s *Server) ensureHLSJob(kind string, id, start int, audioIdx int) (string, error) {
	hlsInit()
	if ffmpegBin == "" {
		return "", fmt.Errorf("ffmpeg not found")
	}

	full, err := s.resolveMediaFile(kind, int64(id))
	if err != nil {
		return "", err
	}

	key := hlsFullKey(kind, id, start, audioIdx)
	hlsMu.Lock()
	if j, ok := hlsJobs[key]; ok {
		if j.starting {
			// A sibling request is starting this job; wait for it instead of
			// launching a duplicate ffmpeg.
			hlsMu.Unlock()
			if !waitForReady(j) {
				return "", fmt.Errorf("job startup failed")
			}
			hlsMu.Lock()
			j, ok = hlsJobs[key]
			if ok && !j.starting {
				j.lastAccess = time.Now()
				hlsMu.Unlock()
				return j.dir, nil
			}
			hlsMu.Unlock()
			return "", fmt.Errorf("job disappeared during startup")
		}
		j.lastAccess = time.Now()
		hlsMu.Unlock()
		return j.dir, nil
	}
	// Reserve the key immediately so concurrent requests coalesce on this
	// single in-flight start.
	hlsJobs[key] = &hlsJob{starting: true}
	hlsMu.Unlock()

	video, audio, err := probeCodecs(full)
	if err != nil {
		s.dropHLSJob(key)
		return "", err
	}
	copyVideo := video == "h264"
	copyAudio := audio == "" || audio == "aac" || audio == "mp3"

	dir := filepath.Join(s.hlsBaseDir(), key)
	os.RemoveAll(dir)
	os.MkdirAll(dir, 0o755)
	logF, err := os.Create(filepath.Join(dir, "ffmpeg.log"))
	if err != nil {
		s.dropHLSJob(key)
		return "", err
	}
	cmd, err := s.startFFmpegHLS(full, dir, start, copyVideo, copyAudio, audioIdx, logF)
	if err != nil {
		logF.Close()
		os.RemoveAll(dir)
		s.dropHLSJob(key)
		return "", err
	}

	job := &hlsJob{
		dir:        dir,
		cmd:        cmd,
		done:       make(chan error, 1),
		logF:       logF,
		lastAccess: time.Now(),
	}
	// The goroutine owns Wait(), so finished ffmpeg processes are reaped and
	// never become zombies.
	go func() {
		err := cmd.Wait()
		select {
		case job.done <- err:
		default:
		}
		logF.Close()
	}()
	hlsMu.Lock()
	hlsJobs[key] = job
	hlsMu.Unlock()

	if s.waitForSegments(job) != nil {
		killJob(job)
		s.dropHLSJob(key)
		return "", fmt.Errorf("transcoding failed, see %s/ffmpeg.log", dir)
	}
	return dir, nil
}

// waitForReady polls until a starting job is replaced by a real one or the
// placeholder expires.
func waitForReady(j *hlsJob) bool {
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		hlsMu.Lock()
		nowStarting := j.starting
		hlsMu.Unlock()
		if !nowStarting {
			return true
		}
		time.Sleep(250 * time.Millisecond)
	}
	return false
}

// dropHLSJob removes a key from the jobs table.
func (s *Server) dropHLSJob(key string) {
	hlsMu.Lock()
	delete(hlsJobs, key)
	hlsMu.Unlock()
}

// startFFmpegHLS builds and starts the ffmpeg command for one HLS job.
// audioIdx >= 0 maps only that audio stream (0:a:audioIdx), -1 maps all.
func (s *Server) startFFmpegHLS(full, dir string, start int, copyVideo, copyAudio bool, audioIdx int, logF *os.File) (*exec.Cmd, error) {
	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin"}
	if start > 0 {
		args = append(args, "-ss", strconv.Itoa(start))
	}
	args = append(args, "-i", full)
	aMap := []string{"-map", "0:a?"}
	if audioIdx >= 0 {
		aMap = []string{"-map", fmt.Sprintf("0:a:%d", audioIdx)}
	}
	switch {
	case copyVideo && copyAudio:
		args = append(args, "-map", "0:v:0", aMap[0], aMap[1], "-c:v", "copy", "-c:a", "copy")
	case copyVideo:
		args = append(args, "-map", "0:v:0", aMap[0], aMap[1],
			"-c:v", "copy",
			"-c:a", "aac", "-b:a", "128k")
	default:
		args = append(args, "-map", "0:v:0", aMap[0], aMap[1],
			"-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p",
			"-c:a", "aac", "-b:a", "128k")
	}
	args = append(args,
		"-f", "hls", "-hls_time", "10", "-hls_list_size", "0", "-hls_playlist_type", "event",
		"-hls_segment_filename", filepath.Join(dir, "seg_%05d.ts"),
		filepath.Join(dir, "index.m3u8"))

	cmd := exec.Command(ffmpegBin, args...)
	cmd.Stdout = logF
	cmd.Stderr = logF
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return cmd, nil
}

// handleHLSMaster starts the job and serves the playlist with token-bearing
// segment URLs so browser players can fetch everything themselves.
func (s *Server) handleHLSMaster(w http.ResponseWriter, r *http.Request) {
	u := currentUser(r)
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

	audioIdx := -1
	full, err := s.resolveMediaFile(kind, id)
	if err == nil {
		var pref string
		if u != nil {
			pref = u.AudioLang
		}
		audioIdx = preferredAudioIndex(audioTracksFor(full), pref)
	}

	key := hlsFullKey(kind, int(id), start, audioIdx)
	dir, err := s.ensureHLSJob(kind, int(id), start, audioIdx)
	if err != nil {
		writeError(w, 500, "transcoding failed: "+err.Error())
		return
	}
	hlsMu.Lock()
	if j, ok := hlsJobs[key]; ok {
		j.lastAccess = time.Now()
	}
	hlsMu.Unlock()

	data, err := os.ReadFile(filepath.Join(dir, "index.m3u8"))
	if err != nil {
		writeError(w, 500, "playlist not ready")
		return
	}
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
