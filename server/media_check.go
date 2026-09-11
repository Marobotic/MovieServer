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
	"time"
)

const (
	classWebDirect    = "web_direct"
	classQuickFix     = "quick_fix"
	classNeedsEncode  = "needs_encode"
	classWebReady     = "web_ready"
	classPreparing    = "preparing"
	classDamaged      = "damaged"
	classStillCopying = "still_copying"
	classMissing      = "missing"
)

type mediaCheck struct {
	ID          int64  `json:"-"`
	Kind        string `json:"-"`
	MediaID     int64  `json:"id"`
	State       string `json:"state"`
	Reason      string `json:"reason,omitempty"`
	Container   string `json:"container"`
	VCodec      string `json:"vcodec"`
	PixFmt      string `json:"pix_fmt"`
	Width       int    `json:"width"`
	Height      int    `json:"height"`
	HDR         bool   `json:"hdr"`
	ACodec      string `json:"acodec"`
	Channels    int    `json:"channels"`
	AudioLangs  string `json:"audio_langs,omitempty"`
	DurationSec int64  `json:"duration_sec"`
	Size        int64  `json:"size_bytes"`
	MTime       int64  `json:"mtime"`
	CheckedAt   string `json:"checked_at"`
	Title       string `json:"title,omitempty"`
}

type checkedProbe struct {
	Ext         string
	Container   string
	VCodec      string
	PixFmt      string
	Width       int
	Height      int
	HDR         bool
	ACodec      string
	Channels    int
	AudioLangs  []string
	DurationSec int64
}

func (s *Server) checkMedia(kind string, id int64) {
	full, err := s.resolveMediaFile(kind, id)
	if err != nil {
		s.storeCheck(kind, id, mediaCheck{Kind: kind, MediaID: id, State: classMissing,
			Reason: "file not found", CheckedAt: nowRFC()})
		return
	}
	fi, err := os.Stat(full)
	if err != nil {
		s.storeCheck(kind, id, mediaCheck{Kind: kind, MediaID: id, State: classMissing,
			Reason: "file not found", CheckedAt: nowRFC()})
		return
	}
	prev := s.getCheck(kind, id)
	if prev != nil && prev.Size == fi.Size() && prev.MTime == fi.ModTime().Unix() {
		return
	}

	c := mediaCheck{Kind: kind, MediaID: id, Size: fi.Size(),
		MTime: fi.ModTime().Unix(), CheckedAt: nowRFC()}

	if beingCopied(full) {
		c.State = classStillCopying
		c.Reason = "file size is still changing; it may still be copying"
		s.storeCheck(kind, id, c)
		return
	}

	p, err := probeFile(full)
	if err != nil {
		c.State = classDamaged
		c.Reason = "can't be opened (header is damaged)"
		s.storeCheck(kind, id, c)
		return
	}
	c.Container = p.Ext
	c.VCodec = p.VCodec
	c.PixFmt = p.PixFmt
	c.Width = p.Width
	c.Height = p.Height
	c.HDR = p.HDR
	c.ACodec = p.ACodec
	c.Channels = p.Channels
	c.AudioLangs = strings.Join(p.AudioLangs, ",")
	c.DurationSec = p.DurationSec

	switch {
	case p.VCodec == "":
		c.State, c.Reason = classDamaged, "has no video stream"
		s.storeCheck(kind, id, c)
		return
	case p.DurationSec <= 0:
		c.State, c.Reason = classDamaged, "reports no length"
		s.storeCheck(kind, id, c)
		return
	}
	if br := c.Size * 8 / (p.DurationSec + 1); br < 100_000 || br > 150_000_000 {
		c.State, c.Reason = classDamaged, fmt.Sprintf("implausible bitrate (%d kbps)", br/1000)
		s.storeCheck(kind, id, c)
		return
	}

	c.State, c.Reason = classifyProbe(p)

	if dmg, why := sampleDecodeError(full, p.DurationSec); dmg {
		c.State, c.Reason = classDamaged, why
	}
	s.storeCheck(kind, id, c)
}

func beingCopied(full string) bool {
	fi1, err := os.Stat(full)
	if err != nil {
		return false
	}
	time.Sleep(time.Second)
	fi2, err := os.Stat(full)
	if err != nil {
		return false
	}
	return fi1.Size() != fi2.Size() || fi1.ModTime() != fi2.ModTime()
}

type probeResult struct {
	Format struct {
		FormatName string `json:"format_name"`
		Duration   string `json:"duration"`
	} `json:"format"`
	Streams []struct {
		CodecType     string `json:"codec_type"`
		CodecName     string `json:"codec_name"`
		Width         int    `json:"width"`
		Height        int    `json:"height"`
		PixFmt        string `json:"pix_fmt"`
		ColorTransfer string `json:"color_transfer"`
		Channels      int    `json:"channels"`
		SampleRate    string `json:"sample_rate"`
		Duration      string `json:"duration"`
		Tags          struct {
			Language string `json:"language"`
		} `json:"tags"`
	} `json:"streams"`
}

func probeFile(full string) (*checkedProbe, error) {
	ffprobeBin, err := exec.LookPath("ffprobe")
	if err != nil {
		return nil, fmt.Errorf("ffprobe not found")
	}
	out, err := exec.Command(ffprobeBin, "-v", "error",
		"-show_format", "-show_streams", "-of", "json", full).Output()
	if err != nil {
		return nil, fmt.Errorf("ffprobe failed: %v", strings.TrimSpace(string(out)))
	}
	var res probeResult
	if err := json.Unmarshal(out, &res); err != nil {
		return nil, fmt.Errorf("parse probe: %v", err)
	}
	p := &checkedProbe{
		Ext:       strings.ToLower(filepath.Ext(full)),
		Container: res.Format.FormatName,
	}
	if d, e := strconv.ParseFloat(res.Format.Duration, 64); e == nil {
		p.DurationSec = int64(d)
	}
	for _, st := range res.Streams {
		d := int64(0)
		if v, e := strconv.ParseFloat(st.Duration, 64); e == nil {
			d = int64(v)
		}
		switch st.CodecType {
		case "video":
			if p.VCodec == "" {
				p.VCodec = st.CodecName
				p.Width = st.Width
				p.Height = st.Height
				p.PixFmt = st.PixFmt
				p.HDR = st.ColorTransfer == "smpte2084" || st.ColorTransfer == "arib-std-b67"
			}
		case "audio":
			if p.ACodec == "" {
				p.ACodec = st.CodecName
				p.Channels = st.Channels
			}
			lang := st.Tags.Language
			if lang != "" {
				dup := false
				for _, l := range p.AudioLangs {
					if l == lang {
						dup = true
					}
				}
				if !dup {
					p.AudioLangs = append(p.AudioLangs, lang)
				}
			}
			if d > p.DurationSec {
				p.DurationSec = d
			}
		}
	}
	if p.DurationSec == 0 {
		for _, st := range res.Streams {
			if st.CodecType == "video" {
				if d, e := strconv.ParseFloat(st.Duration, 64); e == nil {
					p.DurationSec = int64(d)
				}
			}
		}
	}
	return p, nil
}

func classifyProbe(p *checkedProbe) (string, string) {
	browserSafeAudio := p.ACodec == "" ||
		((p.ACodec == "aac" || p.ACodec == "mp3") && p.Channels <= 2)
	switch {
	case p.VCodec != "h264":
		return classNeedsEncode, fmt.Sprintf("video is %s; browsers can't play it directly, it must be encoded first", p.VCodec)
	case p.HDR:
		return classNeedsEncode, "HDR video must be tone-mapped and encoded for browsers"
	case p.PixFmt != "" && p.PixFmt != "yuv420p" && p.PixFmt != "yuvj420p":
		return classNeedsEncode, fmt.Sprintf("video is 10-bit (%s); browsers need 8-bit H.264", p.PixFmt)
	case p.Ext == ".mp4" || p.Ext == ".m4v":
		if browserSafeAudio {
			return classWebDirect, ""
		}
		return classQuickFix, fmt.Sprintf("audio is %s %dch; browsers accept stereo AAC only", p.ACodec, p.Channels)
	default:
		if browserSafeAudio {
			return classQuickFix, fmt.Sprintf("container %s isn't browser-safe; remux to MP4", p.Ext)
		}
		return classQuickFix, fmt.Sprintf("remux needed: %s container with %s %dch audio", p.Ext, p.ACodec, p.Channels)
	}
}

func sampleDecodeError(full string, dur int64) (bool, string) {
	ffmpegBin, err := exec.LookPath("ffmpeg")
	if err != nil {
		return false, ""
	}
	points := []int64{int64(float64(dur) * 0.1), int64(float64(dur) * 0.5), dur - 60}
	var midErrors bool
	for i, t := range points {
		if t < 2 || t >= dur {
			continue
		}
		out, e := exec.Command("nice", "-n", "19", ffmpegBin, "-v", "error",
			"-nostdin", "-ss", strconv.FormatInt(t, 10), "-i", full,
			"-t", "2", "-map", "0:v:0", "-f", "null", "-").CombinedOutput()
		msg := strings.TrimSpace(string(out))
		if len(msg) == 0 && e == nil {
			continue
		}
		if i == len(points)-1 {
			return true, "the end of the file is missing (copy or download was cut short)"
		}
		midErrors = true
	}
	if midErrors {
		return true, "damaged in places (decoder errors mid-file)"
	}
	return false, ""
}

func (s *Server) storeCheck(kind string, id int64, c mediaCheck) {
	_ = c.ID
	s.db.Exec(`INSERT INTO media_checks (kind, media_id, size, mtime, state, reason, container, vcodec, pix_fmt, width, height, hdr, acodec, channels, audio_langs, duration_sec, checked_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(kind, media_id) DO UPDATE SET
		size=excluded.size, mtime=excluded.mtime, state=excluded.state, reason=excluded.reason,
		container=excluded.container, vcodec=excluded.vcodec, pix_fmt=excluded.pix_fmt,
		width=excluded.width, height=excluded.height, hdr=excluded.hdr, acodec=excluded.acodec,
		channels=excluded.channels, audio_langs=excluded.audio_langs, duration_sec=excluded.duration_sec,
		checked_at=excluded.checked_at`,
		kind, id, c.Size, c.MTime, c.State, c.Reason, c.Container, c.VCodec, c.PixFmt,
		c.Width, c.Height, boolInt(c.HDR), c.ACodec, c.Channels, c.AudioLangs, c.DurationSec, c.CheckedAt)
}

func (s *Server) getCheck(kind string, id int64) *mediaCheck {
	row := s.db.QueryRow(`SELECT size, mtime FROM media_checks WHERE kind=? AND media_id=?`, kind, id)
	c := &mediaCheck{}
	if err := row.Scan(&c.Size, &c.MTime); err != nil {
		return nil
	}
	return c
}

func (s *Server) handleLibraryHealth(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`SELECT mc.kind, mc.media_id, mc.state, COALESCE(mc.reason,''), mc.container,
		mc.vcodec, mc.pix_fmt, mc.width, mc.height, mc.hdr, mc.acodec, mc.channels,
		mc.audio_langs, mc.duration_sec, COALESCE(mc.checked_at,''),
		COALESCE(m.title, COALESCE(e.title, '')) AS title
		FROM media_checks mc
		LEFT JOIN movies m ON mc.kind='movie' AND m.id=mc.media_id
		LEFT JOIN episodes e ON mc.kind='episode' AND e.id=mc.media_id`)
	if err != nil {
		writeError(w, 500, "query checks: "+err.Error())
		return
	}
	defer rows.Close()
	counts := map[string]int{}
	items := make([]mediaCheck, 0)
	var webBytes int64
	for rows.Next() {
		var c mediaCheck
		var hdr int
		if err := rows.Scan(&c.Kind, &c.MediaID, &c.State, &c.Reason, &c.Container,
			&c.VCodec, &c.PixFmt, &c.Width, &c.Height, &hdr, &c.ACodec, &c.Channels,
			&c.AudioLangs, &c.DurationSec, &c.CheckedAt, &c.Title); err != nil {
			writeError(w, 500, "scan check: "+err.Error())
			return
		}
		c.HDR = hdr != 0
		counts[c.State]++
		if c.State == classWebReady {
			webBytes += c.Size
		}
		items = append(items, c)
	}
	writeJSON(w, 200, map[string]any{
		"counts":        counts,
		"items":         items,
		"disk_used_web": webBytes,
	})
}

func nowRFC() string {
	return time.Now().UTC().Format(time.RFC3339)
}
