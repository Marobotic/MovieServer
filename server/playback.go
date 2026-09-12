package main

import (
	"net/http"
	"strconv"
	"strings"
)

const (
	clientWeb    = "web"
	clientNative = "native"
)

type playbackEstimate struct {
	Minutes int    `json:"minutes"`
	SizeGB  int    `json:"size_gb,omitempty"`
	Worker  string `json:"worker"`
}

type playbackJob struct {
	ID      int     `json:"id"`
	Status  string  `json:"status"`
	Percent float64 `json:"percent"`
	Speed   float64 `json:"speed"`
	ETASec  int     `json:"eta_sec"`
}

type playbackDecision struct {
	Decision string            `json:"decision"`
	URL      string            `json:"url,omitempty"`
	Variant  string            `json:"variant"`
	Reason   string            `json:"reason,omitempty"`
	Estimate *playbackEstimate `json:"estimate"`
	Job      *playbackJob      `json:"job"`
	NativeOK bool              `json:"native_ok"`
}

func estimateFor(c mediaCheck, decision string) *playbackEstimate {
	switch decision {
	case "needs_quick_fix":
		min := 1
		if c.DurationSec > 0 {
			min = int(c.DurationSec/27+59) / 60
		}
		if min < 1 {
			min = 1
		}
		return &playbackEstimate{Minutes: min, Worker: "cpu"}
	case "needs_encode":
		min := int(float64(c.DurationSec)/9.4+59) / 60
		if min < 1 {
			min = 1
		}
		gb := int(float64(c.DurationSec)*0.000625 + 0.5)
		if gb < 1 {
			gb = 1
		}
		return &playbackEstimate{Minutes: min, SizeGB: gb, Worker: "gpu"}
	}
	return nil
}

func playbackURL(kind string, id int64, variant string) string {
	plural := "movies"
	if kind == "episode" {
		plural = "episodes"
	}
	if variant == "web" {
		return "/api/" + plural + "/" + strconv.FormatInt(id, 10) + "/stream?variant=web"
	}
	return "/api/" + plural + "/" + strconv.FormatInt(id, 10) + "/stream"
}

func decidePlayback(client string, c mediaCheck) playbackDecision {
	d := playbackDecision{}
	if client == clientNative {
		d.Variant = "original"
		d.NativeOK = true
		switch c.State {
		case classDamaged:
			return playbackDecision{Decision: "damaged", Variant: "original", Reason: c.Reason, NativeOK: false}
		case classStillCopying:
			return playbackDecision{Decision: "still_copying", Variant: "original", Reason: c.Reason, NativeOK: false}
		}
		d.Decision = "play"
		return d
	}
	switch c.State {
	case classDamaged:
		return playbackDecision{Decision: "damaged", Variant: "original", Reason: c.Reason, NativeOK: false}
	case classStillCopying:
		return playbackDecision{Decision: "still_copying", Variant: "original", Reason: c.Reason, NativeOK: false}
	case classWebDirect:
		return playbackDecision{Decision: "play", Variant: "original", NativeOK: true}
	case classWebReady:
		return playbackDecision{Decision: "play", Variant: "web", NativeOK: true}
	case classQuickFix:
		d = playbackDecision{Decision: "needs_quick_fix", Variant: "web", Reason: c.Reason, NativeOK: true}
		d.Estimate = estimateFor(c, "needs_quick_fix")
		return d
	case classNeedsEncode:
		d = playbackDecision{Decision: "needs_encode", Variant: "web", Reason: c.Reason, NativeOK: true}
		d.Estimate = estimateFor(c, "needs_encode")
		return d
	case classPreparing:
		return playbackDecision{Decision: "preparing", Variant: "web", Reason: c.Reason, NativeOK: true}
	}
	return playbackDecision{Decision: "play", Variant: "original", NativeOK: false}
}

func (s *Server) handlePlayback(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	kind := "movie"
	if strings.HasPrefix(r.Pattern, "GET /api/episodes/") {
		kind = "episode"
	}
	client := r.URL.Query().Get("client")
	if client == "" {
		client = clientWeb
	}
	if client != clientWeb && client != clientNative {
		writeError(w, 400, "client must be web or native")
		return
	}
	var title string
	if kind == "movie" {
		m, err := s.getMovie(id)
		if err != nil {
			writeError(w, 404, "movie not found")
			return
		}
		title = m.Title
	} else {
		e, err := s.getEpisode(id)
		if err != nil {
			writeError(w, 404, "episode not found")
			return
		}
		title = e.Title
	}
	c := s.getCheck(kind, id)
	if c == nil {
		s.checkMedia(kind, id)
		c = s.getCheck(kind, id)
	}
	if c == nil {
		writeError(w, 500, "media check failed")
		return
	}
	d := decidePlayback(client, *c)
	if client == clientWeb {
		if j := s.activeJob(kind, id); j != nil {
			d = playbackDecision{Decision: "preparing", Variant: "web",
				Reason: "a prepare job is running", NativeOK: true}
			writeJSON(w, 200, map[string]any{
				"decision":   d.Decision,
				"title":      title,
				"url":        d.URL,
				"variant":    d.Variant,
				"reason":     d.Reason,
				"estimate":   d.Estimate,
				"job":        j.snapshot(),
				"native_ok":  d.NativeOK,
				"checked_at": c.CheckedAt,
			})
			return
		}
	}
	if d.Decision == "play" {
		d.URL = playbackURL(kind, id, d.Variant)
	}
	writeJSON(w, 200, map[string]any{
		"decision":   d.Decision,
		"title":      title,
		"url":        d.URL,
		"variant":    d.Variant,
		"reason":     d.Reason,
		"estimate":   d.Estimate,
		"job":        d.Job,
		"native_ok":  d.NativeOK,
		"checked_at": c.CheckedAt,
	})
}

func (s *Server) activeJob(kind string, id int64) *prepareJob {
	jobMgr.mu.Lock()
	defer jobMgr.mu.Unlock()
	for _, j := range jobMgr.jobs {
		if j.Kind == kind && j.MediaID == id && !j.finished() {
			return j
		}
	}
	return nil
}

func webcopyPath(dataDir, kind string, id int64) string {
	return dataDir + "/webcopies/" + kind + "-" + strconv.FormatInt(id, 10) + ".mp4"
}
