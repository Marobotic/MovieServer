package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	jobTypeQuickFix = "quick_fix"
	jobTypeEncode   = "encode"
)

type prepareJob struct {
	ID          int64   `json:"id"`
	Kind        string  `json:"kind"`
	MediaID     int64   `json:"media_id"`
	Type        string  `json:"type"`
	Mode        string  `json:"mode"`
	Status      string  `json:"status"`
	Worker      string  `json:"worker"`
	AudioIndex  int     `json:"audio_index"`
	OutPath     string  `json:"out_path"`
	Percent     float64 `json:"percent"`
	Speed       float64 `json:"speed"`
	FPS         float64 `json:"fps"`
	ETASec      int     `json:"eta_sec"`
	Error       string  `json:"error,omitempty"`
	Title       string  `json:"title,omitempty"`
	RequestedBy string  `json:"requested_by"`
	CreatedAt   string  `json:"created_at"`

	mu       sync.Mutex
	cmd      *exec.Cmd
	part     string
	srcPath  string
	srcSize  int64
	srcMtime int64
	durSec   int64
	lastDB   time.Time
}

type jobManager struct {
	mu    sync.Mutex
	jobs  map[int64]*prepareJob
	queue []*prepareJob
}

var jobMgr = &jobManager{jobs: map[int64]*prepareJob{}}

type warmJob struct {
	ID          int64
	Kind        string
	MediaID     int64
	Type        string
	Mode        string
	Status      string
	Worker      string
	AudioIndex  int
	OutPath     string
	Percent     float64
	Speed       float64
	FPS         float64
	ETASec      int
	Error       string
	RequestedBy string
}

func (s *Server) loadJobsOnStart() {
	hlsInit()
	rows, err := s.db.Query(`SELECT id, kind, media_id, type, mode, status, worker, audio_index,
		out_path, percent, speed, fps, eta_sec, COALESCE(error,''), requested_by
		FROM prepare_jobs ORDER BY id`)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var w warmJob
		if err := rows.Scan(&w.ID, &w.Kind, &w.MediaID, &w.Type, &w.Mode, &w.Status,
			&w.Worker, &w.AudioIndex, &w.OutPath, &w.Percent, &w.Speed, &w.FPS,
			&w.ETASec, &w.Error, &w.RequestedBy); err != nil {
			continue
		}
		j := &prepareJob{
			ID: w.ID, Kind: w.Kind, MediaID: w.MediaID, Type: w.Type, Mode: w.Mode,
			Status: w.Status, Worker: w.Worker, AudioIndex: w.AudioIndex, OutPath: w.OutPath,
			Percent: w.Percent, Speed: w.Speed, FPS: w.FPS, ETASec: w.ETASec, Error: w.Error,
			RequestedBy: w.RequestedBy,
		}
		jobMgr.jobs[j.ID] = j
		switch j.Status {
		case "queued":
			jobMgr.queue = append(jobMgr.queue, j)
		case "running", "paused", "canceling":
			j.Status = "queued"
			_, _ = s.db.Exec(`UPDATE prepare_jobs SET status='queued' WHERE id=?`, j.ID)
			s.refreshWebReadyClear(j.Kind, j.MediaID)
			jobMgr.queue = append(jobMgr.queue, j)
		}
	}
	s.jobsInit()
}

func (s *Server) refreshWebReadyClear(kind string, id int64) {
	check := s.getCheck(kind, id)
	if check != nil && check.State == classWebReady {
		s.checkMedia(kind, id)
	}
}

func (j *prepareJob) snapshot() map[string]any {
	j.mu.Lock()
	defer j.mu.Unlock()
	return map[string]any{
		"id":          j.ID,
		"kind":        j.Kind,
		"media_id":    j.MediaID,
		"type":        j.Type,
		"mode":        j.Mode,
		"status":      j.Status,
		"worker":      j.Worker,
		"audio_index": j.AudioIndex,
		"out_path":    j.OutPath,
		"percent":     j.Percent,
		"speed":       j.Speed,
		"fps":         j.FPS,
		"eta_sec":     j.ETASec,
		"error":       j.Error,
		"title":       j.Title,
		"created_at":  j.CreatedAt,
	}
}

func (j *prepareJob) finished() bool {
	return j.Status == "done" || j.Status == "failed" || j.Status == "canceled"
}

func (j *prepareJob) persist(s *Server, force bool) {
	j.mu.Lock()
	now := time.Now()
	if force || j.finished() || j.lastDB.IsZero() || now.Sub(j.lastDB) >= time.Second {
		j.lastDB = now
		_, _ = s.db.Exec(`INSERT INTO prepare_jobs (id, kind, media_id, type, mode, status, worker,
			audio_index, src_path, src_size, src_mtime, out_path, percent, speed, fps, eta_sec, error, requested_by, created_at)
			VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,COALESCE(?,created_at))
			ON CONFLICT(id) DO UPDATE SET status=excluded.status, percent=excluded.percent,
			speed=excluded.speed, fps=excluded.fps, eta_sec=excluded.eta_sec, error=excluded.error,
			audio_index=excluded.audio_index, started_at=CASE WHEN excluded.status='running'
			AND prepare_jobs.started_at IS NULL THEN CURRENT_TIMESTAMP ELSE prepare_jobs.started_at END,
			finished_at=CASE WHEN excluded.status IN ('done','failed','canceled') THEN CURRENT_TIMESTAMP
			ELSE prepare_jobs.finished_at END`,
			j.ID, j.Kind, j.MediaID, j.Type, j.Mode, j.Status, j.Worker,
			j.AudioIndex, j.srcPath, j.srcSize, j.srcMtime, j.OutPath, j.Percent, j.Speed, j.FPS,
			j.ETASec, j.Error, j.RequestedBy, j.CreatedAt)
	}
	j.mu.Unlock()
}

func (j *prepareJob) setStatus(st string) {
	j.mu.Lock()
	j.Status = st
	j.mu.Unlock()
}

func (j *prepareJob) pause() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.cmd != nil && j.cmd.Process != nil {
		_ = syscall.Kill(-j.cmd.Process.Pid, syscall.SIGSTOP)
		if j.Status != "canceling" {
			j.Status = "paused"
		}
	}
}

func (j *prepareJob) resume() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.cmd != nil && j.cmd.Process != nil {
		_ = syscall.Kill(-j.cmd.Process.Pid, syscall.SIGCONT)
		if j.Status == "paused" {
			j.Status = "running"
		}
	}
}

func (j *prepareJob) cancel() {
	var pid int
	j.mu.Lock()
	if j.cmd != nil && j.cmd.Process != nil {
		pid = j.cmd.Process.Pid
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		if j.Status != "queued" {
			j.Status = "canceling"
		}
	}
	j.mu.Unlock()
	if pid != 0 {
		time.AfterFunc(5*time.Second, func() {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		})
	}
}

func (j *prepareJob) setCmd(c *exec.Cmd) {
	j.mu.Lock()
	j.cmd = c
	j.mu.Unlock()
}

func (s *Server) webcopiesDir() string {
	dir := s.conf.WebcopiesDir
	if dir == "" {
		dir = filepath.Join(s.conf.DataDir, "webcopies")
	}
	_ = os.MkdirAll(dir, 0o755)
	return dir
}

func (s *Server) jobsInit() {
	go s.jobScheduler()
}

func (s *Server) jobScheduler() {
	for {
		jobMgr.mu.Lock()
		var next *prepareJob
		for _, j := range jobMgr.queue {
			if j.Status == "queued" {
				next = j
				break
			}
		}
		jobMgr.mu.Unlock()
		if next == nil {
			time.Sleep(2 * time.Second)
			continue
		}
		s.runJob(next)
		jobMgr.mu.Lock()
		for i, q := range jobMgr.queue {
			if q == next {
				jobMgr.queue = append(jobMgr.queue[:i], jobMgr.queue[i+1:]...)
				break
			}
		}
		jobMgr.mu.Unlock()
	}
}

func (s *Server) runJob(j *prepareJob) {
	if ffmpegBin == "" {
		j.Error = "ffmpeg not found"
		j.setStatus("failed")
		j.persist(s, true)
		return
	}
	srcPath, err := s.resolveMediaFile(j.Kind, j.MediaID)
	if err != nil {
		j.Error = "source file is missing"
		j.setStatus("failed")
		j.persist(s, true)
		return
	}
	fi, err := os.Stat(srcPath)
	if err != nil {
		j.Error = "cannot stat source file"
		j.setStatus("failed")
		j.persist(s, true)
		return
	}
	j.srcPath = srcPath
	j.srcSize = fi.Size()
	j.srcMtime = fi.ModTime().Unix()
	check := s.getCheck(j.Kind, j.MediaID)
	if check == nil {
		j.Error = "no media check for this item"
		j.setStatus("failed")
		j.persist(s, true)
		return
	}
	j.durSec = check.DurationSec
	out := filepath.Join(s.webcopiesDir(), fmt.Sprintf("%s-%d.mp4", j.Kind, j.MediaID))
	j.part = strings.TrimSuffix(out, ".mp4") + ".part.mp4"
	j.OutPath = out
	_ = os.Remove(j.part)
	_ = os.Remove(j.part + ".log")
	j.Title = s.jobTitle(j.Kind, j.MediaID)

	j.AudioIndex = s.pickAudioIndex(j.Kind, j.MediaID)
	if j.Worker == "" {
		if j.Type == jobTypeEncode {
			j.Worker = s.pickWorker()
		} else {
			j.Worker = "cpu"
		}
	}

	args := []string{"-progress", "pipe:1", "-nostats"}
	if j.Type == jobTypeEncode {
		args = append(args, encodeArgs(srcPath, j.part, j.AudioIndex, j.Worker, check)...)
	} else {
		args = append(args, quickFixArgs(srcPath, j.part, j.AudioIndex, check)...)
	}
	logF, err := os.Create(j.part + ".log")
	if err != nil {
		j.Error = "cannot create job log"
		j.setStatus("failed")
		j.persist(s, true)
		return
	}

	progR, progW, err := os.Pipe()
	if err != nil {
		j.Error = "cannot create progress pipe"
		j.setStatus("failed")
		j.persist(s, true)
		return
	}
	cmd := exec.Command(ffmpegBin, args...)
	cmd.Stdout = progW
	cmd.Stderr = logF
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		j.Error = "failed to start ffmpeg: " + err.Error()
		j.setStatus("failed")
		j.persist(s, true)
		return
	}
	_ = progW.Close()
	go s.progressReader(j, progR)
	j.setCmd(cmd)
	j.setStatus("running")
	j.reprio()
	j.persist(s, true)
	s.markPreparing(j.Kind, j.MediaID)

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	stopMonitor := make(chan struct{})
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		autoPaused := false
		for {
			select {
			case <-stopMonitor:
				return
			case <-ticker.C:
				gaming := isGaming()
				j.mu.Lock()
				status := j.Status
				j.mu.Unlock()
				if gaming && status == "running" {
					j.pause()
					j.setStatus("paused_gaming")
					j.persist(s, true)
					autoPaused = true
				} else if !gaming && autoPaused && status == "paused_gaming" {
					j.resume()
					j.setStatus("running")
					j.persist(s, true)
					autoPaused = false
				}
			}
		}
	}()

	waitErr := <-done
	close(stopMonitor)

	j.mu.Lock()
	st := j.Status
	j.mu.Unlock()
	if st == "canceling" {
		_ = os.Remove(j.part)
		_ = os.Remove(j.part + ".log")
		j.Error = ""
		j.setStatus("canceled")
		j.persist(s, true)
		s.refreshWebReadyClear(j.Kind, j.MediaID)
		return
	}
	if waitErr != nil {
		j.Error = "ffmpeg failed: " + tailLog(j.part+".log")
		j.OutPath = ""
		j.setStatus("failed")
		j.persist(s, true)
		_ = os.Remove(j.part)
		_ = os.Remove(j.part + ".log")
		s.refreshWebReadyClear(j.Kind, j.MediaID)
		return
	}
	if _, err := os.Stat(j.part); err != nil {
		j.Error = "ffmpeg produced no output"
		j.setStatus("failed")
		j.persist(s, true)
		s.refreshWebReadyClear(j.Kind, j.MediaID)
		return
	}
	if verr := verifyWebcopy(j.part, j.durSec, j.Type); verr != nil {
		j.Error = "web copy failed verification: " + verr.Error()
		j.setStatus("failed")
		j.persist(s, true)
		_ = os.Remove(j.part)
		s.refreshWebReadyClear(j.Kind, j.MediaID)
		return
	}
	if err := os.Rename(j.part, out); err != nil {
		j.Error = "finalize web copy: " + err.Error()
		j.setStatus("failed")
		j.persist(s, true)
		s.refreshWebReadyClear(j.Kind, j.MediaID)
		return
	}
	j.mu.Lock()
	j.Percent = 100
	j.ETASec = 0
	j.mu.Unlock()
	j.setStatus("done")
	j.persist(s, true)
	s.markWebReady(j.Kind, j.MediaID)
}

func (j *prepareJob) reprio() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.cmd == nil || j.cmd.Process == nil {
		return
	}
	pid := j.cmd.Process.Pid
	if nice, err := exec.LookPath("nice"); err == nil {
		_ = exec.Command(nice, "-n", "19", "-p", strconv.Itoa(pid)).Run()
	}
	if ionice, err := exec.LookPath("ionice"); err == nil {
		_ = exec.Command(ionice, "-c", "3", "-p", strconv.Itoa(pid)).Run()
	}
}

func tailLog(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	lines := []string{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if len(lines) == 0 {
		return "no ffmpeg log"
	}
	start := len(lines) - 6
	if start < 0 {
		start = 0
	}
	return strings.Join(lines[start:], " | ")
}

func (s *Server) jobTitle(kind string, id int64) string {
	if kind == "movie" {
		if m, e := s.getMovie(id); e == nil {
			return m.Title
		}
	} else {
		if ej, e := s.getEpisode(id); e == nil {
			return ej.Title
		}
	}
	return kind + " " + strconv.FormatInt(id, 10)
}

func (s *Server) markPreparing(kind string, id int64) {
	check := s.getCheck(kind, id)
	if check == nil {
		return
	}
	check.State = classPreparing
	check.Reason = "a prepare job is running"
	check.CheckedAt = nowRFC()
	s.storeCheck(kind, id, *check)
}

func (s *Server) markWebReady(kind string, id int64) {
	check := s.getCheck(kind, id)
	if check != nil {
		check.State = classWebReady
		check.Reason = "prepared web copy is current"
		check.CheckedAt = nowRFC()
		s.storeCheck(kind, id, *check)
	}
}

func quickFixArgs(src, part string, audioIdx int, check *mediaCheck) []string {
	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin", "-y"}
	args = append(args, "-i", src,
		"-map", "0:v:0", "-map", fmt.Sprintf("0:a:%d", audioIdx),
		"-sn", "-dn", "-c:v", "copy")
	if check != nil && check.ACodec == "aac" && check.Channels <= 2 {
		args = append(args, "-c:a", "copy")
	} else {
		args = append(args, "-c:a", "aac", "-ac", "2", "-b:a", "192k")
	}
	args = append(args, "-f", "mp4", "-movflags", "+faststart", part)
	return args
}

func encodeArgs(src, part string, audioIdx int, worker string, check *mediaCheck) []string {
	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin", "-y"}
	if worker == "gpu" {
		args = append(args,
			"-hwaccel", "cuda", "-hwaccel_output_format", "cuda",
			"-i", src,
			"-map", "0:v:0", "-map", fmt.Sprintf("0:a:%d", audioIdx),
			"-sn", "-dn", "-map_chapters", "0",
			"-vf", "scale_cuda=format=yuv420p",
			"-c:v", "h264_nvenc", "-preset", "p5", "-tune", "hq",
			"-rc", "vbr", "-cq", "23", "-b:v", "0",
			"-maxrate", "10M", "-bufsize", "20M", "-profile:v", "high",
			"-c:a", "aac", "-ac", "2", "-b:a", "192k",
			"-threads", "2", "-f", "mp4", "-movflags", "+faststart", part)
		return args
	}
	_ = check
	args = append(args,
		"-i", src,
		"-map", "0:v:0", "-map", fmt.Sprintf("0:a:%d", audioIdx),
		"-sn", "-dn", "-map_chapters", "0",
		"-vf", "format=yuv420p",
		"-c:v", "libx264", "-preset", "veryfast", "-crf", "21",
		"-pix_fmt", "yuv420p",
		"-c:a", "aac", "-ac", "2", "-b:a", "192k",
		"-threads", "4", "-f", "mp4", "-movflags", "+faststart", part)
	return args
}

func verifyWebcopy(part string, durSec int64, typ string) error {
	out, err := exec.Command(ffprobe, "-v", "error",
		"-show_entries", "format=duration:stream=codec_name,codec_type,channels",
		"-of", "json", part).Output()
	if err != nil {
		return err
	}
	var res struct {
		Format struct {
			Duration string `json:"duration"`
		} `json:"format"`
		Streams []struct {
			CodecName string `json:"codec_name"`
			CodecType string `json:"codec_type"`
			Channels  int    `json:"channels"`
		} `json:"streams"`
	}
	if json.Unmarshal(out, &res) != nil {
		return fmt.Errorf("bad verification output")
	}
	d, _ := strconv.ParseFloat(res.Format.Duration, 64)
	if durSec > 0 {
		diff := abs64(d - float64(durSec))
		if diff > 5.0 && diff > float64(durSec)*0.02 {
			return fmt.Errorf("duration %0.1fs differs from source %ds", d, durSec)
		}
	}
	var hasVideo, hasStereo bool
	for _, st := range res.Streams {
		if st.CodecType == "video" && st.CodecName == "h264" {
			hasVideo = true
		}
		if st.CodecType == "audio" && st.CodecName == "aac" && st.Channels == 2 {
			hasStereo = true
		}
	}
	if !hasVideo {
		return fmt.Errorf("output has no H.264 video")
	}
	if typ == jobTypeEncode && !hasStereo {
		return fmt.Errorf("output audio is not stereo AAC")
	}
	return nil
}

func abs64(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}

// pickAudioIndex returns the N to use in -map 0:a:N (position among audio
// streams), preferring the profile's languages order eng -> ara -> first.
func (s *Server) pickAudioIndex(kind string, id int64) int {
	full, err := s.resolveMediaFile(kind, id)
	if err != nil {
		return 0
	}
	out, err := exec.Command(ffprobe, "-v", "error",
		"-select_streams", "a", "-show_entries",
		"stream=index:stream_tags=language", "-of", "json", full).Output()
	if err != nil {
		return 0
	}
	var res struct {
		Streams []struct {
			Index int `json:"index"`
			Tags  struct {
				Language string `json:"language"`
			} `json:"tags"`
		} `json:"streams"`
	}
	if json.Unmarshal(out, &res) != nil {
		return 0
	}
	if len(res.Streams) == 0 {
		return 0
	}
	langs := res.Streams
	posOf := func(lang string) int {
		for i, st := range langs {
			if st.Tags.Language == lang {
				return i
			}
		}
		return -1
	}
	for _, want := range []string{"eng", "ara"} {
		if p := posOf(want); p >= 0 {
			return p
		}
	}
	return 0
}

// pickWorker checks NVENC with a 1-second self-test and returns gpu or cpu.
func (s *Server) pickWorker() string {
	if ffmpegBin == "" {
		return "cpu"
	}
	cmd := exec.Command(ffmpegBin, "-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24", "-t", "1",
		"-c:v", "h264_nvenc", "-f", "null", "-")
	if cmd.Run() != nil {
		return "cpu"
	}
	return "gpu"
}

// progressReader parses `-progress pipe:1` key=value blocks and keeps the
// job's live metrics in memory.
func (s *Server) progressReader(j *prepareJob, r *os.File) {
	defer r.Close()
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		j.applyProgress(sc.Text())
	}
}

func (j *prepareJob) applyProgress(line string) {
	line = strings.TrimSpace(line)
	kv := strings.SplitN(line, "=", 2)
	if len(kv) != 2 {
		return
	}
	key := kv[0]
	val := kv[1]
	f, _ := strconv.ParseFloat(val, 64)
	if key == "out_time_us" {
		if j.durSec > 0 {
			pct := f / float64(j.durSec*1_000_000) * 100
			if pct > 100 {
				pct = 100
			}
			j.mu.Lock()
			j.Percent = pct
			if j.Speed > 0 {
				j.ETASec = int(runRemaining(pct, j.Speed, float64(j.durSec)))
			}
			j.mu.Unlock()
		}
		return
	}
	switch key {
	case "speed":
		vals := strings.TrimSuffix(strings.TrimSpace(val), "x")
		sv, err := strconv.ParseFloat(vals, 64)
		if err != nil || sv > 10000 || sv < 0 {
			sv = 0
		}
		j.mu.Lock()
		j.Speed = sv
		j.mu.Unlock()
	case "fps":
		j.mu.Lock()
		j.FPS = f
		j.mu.Unlock()
	case "progress":
		if val == "end" {
			j.mu.Lock()
			j.Percent = 100
			j.mu.Unlock()
		}
	}
}

func runRemaining(pct, speed, durSec float64) float64 {
	if pct <= 0 || speed <= 0 {
		return 0
	}
	remain := durSec * (100 - pct) / 100 / speed
	return remain
}

func (s *Server) handleCreateJob(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Kind string `json:"kind"`
		ID   int64  `json:"media_id"`
		Type string `json:"type"`
		Mode string `json:"mode"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "bad body")
		return
	}
	if req.Kind != "movie" && req.Kind != "episode" {
		writeError(w, 400, "kind must be movie or episode")
		return
	}
	if req.Type != jobTypeQuickFix && req.Type != jobTypeEncode {
		writeError(w, 400, "type must be quick_fix or encode")
		return
	}
	if req.Mode == "" {
		req.Mode = "now"
	}
	if req.Mode != "now" && req.Mode != "idle" {
		writeError(w, 400, "mode must be now or idle")
		return
	}
	check := s.getCheck(req.Kind, req.ID)
	if check == nil {
		writeError(w, 400, "no media check; run a scan first")
		return
	}
	want := classQuickFix
	if req.Type == jobTypeEncode {
		want = classNeedsEncode
	}
	if check.State != want || check.State == classPreparing {
		writeError(w, 409, "item is not eligible for a "+req.Type+" job")
		return
	}
	jobMgr.mu.Lock()
	defer jobMgr.mu.Unlock()
	for _, j := range jobMgr.jobs {
		if j.Kind == req.Kind && j.MediaID == req.ID && !j.finished() {
			writeError(w, 409, "a job already exists for this item")
			return
		}
	}
	res, err := s.db.Exec(`INSERT INTO prepare_jobs (kind, media_id, type, mode, status, worker)
		VALUES (?,?,?,?, 'queued', '')`, req.Kind, req.ID, req.Type, req.Mode)
	if err != nil {
		writeError(w, 500, "create job: "+err.Error())
		return
	}
	id, _ := res.LastInsertId()
	j := &prepareJob{
		ID: id, Kind: req.Kind, MediaID: req.ID, Type: req.Type, Mode: req.Mode,
		Status: "queued", Worker: "",
		Title:       s.jobTitle(req.Kind, req.ID),
		RequestedBy: currentUser(r).Username,
		CreatedAt:   time.Now().UTC().Format(time.RFC3339),
	}
	jobMgr.jobs[id] = j
	jobMgr.queue = append(jobMgr.queue, j)
	s.markPreparing(req.Kind, req.ID)
	writeJSON(w, 201, j.snapshot())
}

func (s *Server) handleListJobs(w http.ResponseWriter, r *http.Request) {
	jobMgr.mu.Lock()
	out := make([]map[string]any, 0, len(jobMgr.jobs))
	for _, j := range jobMgr.jobs {
		out = append(out, j.snapshot())
	}
	jobMgr.mu.Unlock()
	writeJSON(w, 200, out)
}

func (s *Server) handleJobAction(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	jobMgr.mu.Lock()
	j := jobMgr.jobs[id]
	jobMgr.mu.Unlock()
	if j == nil {
		writeError(w, 404, "job not found")
		return
	}
	switch {
	case strings.HasSuffix(r.Pattern, "/pause"):
		j.pause()
	case strings.HasSuffix(r.Pattern, "/resume"):
		j.resume()
	case strings.HasSuffix(r.Pattern, "/cancel"):
		j.cancel()
	}
	j.persist(s, true)
	writeJSON(w, 200, j.snapshot())
}

func (s *Server) handleDeleteWebcopy(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	kind := "movie"
	if strings.HasPrefix(r.Pattern, "DELETE /api/webcopies/episodes/") {
		kind = "episode"
	}
	out := filepath.Join(s.webcopiesDir(), fmt.Sprintf("%s-%d.mp4", kind, id))
	if err := os.Remove(out); err != nil && !os.IsNotExist(err) {
		writeError(w, 500, "remove webcopy: "+err.Error())
		return
	}
	s.refreshWebReadyClear(kind, id)
	writeJSON(w, 200, map[string]any{"ok": true})
}

func isGaming() bool {
	if err := exec.Command("pgrep", "-f", "SteamLaunch AppId=").Run(); err == nil {
		return true
	}
	for _, proc := range []string{"gamescope", "lutris-wrapper", "heroic"} {
		if err := exec.Command("pgrep", "-x", proc).Run(); err == nil {
			return true
		}
	}
	return false
}

func (s *Server) handleJobEvents(w http.ResponseWriter, r *http.Request) {
	last := make(map[int64]string)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(200)
	fl, _ := w.(http.Flusher)
	if fl != nil {
		fl.Flush()
	}

	send := func() {
		jobMgr.mu.Lock()
		for _, j := range jobMgr.jobs {
			key := fmt.Sprintf("%s|%s|%.1f|%.1f|%d", j.Status, j.Error, j.Percent, j.Speed, j.ETASec)
			if last[j.ID] == key {
				continue
			}
			last[j.ID] = key
			data, _ := json.Marshal(j.snapshot())
			_, _ = w.Write([]byte("event: job\ndata: " + string(data) + "\n\n"))
		}
		jobMgr.mu.Unlock()
		if fl != nil {
			fl.Flush()
		}
	}
	send()

	ctx := r.Context()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			send()
		}
	}
}

