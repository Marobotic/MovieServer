package main

import (
	"bufio"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Automatic subtitle synchronisation.
//
// Two routes. If a dedicated engine is installed (alass, then ffsubsync - the
// same tools AutoSubSync drives) it is used, because those handle cuts and
// per-scene drift better than anything worth reimplementing here. Otherwise a
// built-in analysis runs, which needs no extra software.
//
// The built-in method is the ffsubsync idea: you do not need to understand the
// speech, only to know *when* there is speech. ffmpeg's silencedetect gives a
// speech/silence timeline for the audio and the subtitle file gives a second
// timeline of when text is on screen; sliding one past the other recovers the
// drift.
//
// Crucially it measures the drift twice - once near the start of the dialogue,
// once near the end - because a subtitle cut for a different frame rate does
// not sit at a constant offset, it *slides*. A single number can never fix
// that, which is why matching only the middle leaves the ends wrong. Two
// anchors give a straight line through the whole runtime.

const (
	syncCoarseBinMS = 100             // first pass: wide search, cheap
	syncFineBinMS   = 10              // second pass: refine around the peak
	syncMaxLagSec   = 60              // search +/- this many seconds
	syncFineLagMS   = 250             // refinement window around the coarse peak
	syncWindowSec   = 200             // length of each sampled window
	syncWindows     = 6               // how many windows to sample
	syncNoiseDB     = -32             // silencedetect threshold
	syncMinSilence  = 0.25            // seconds; ignore shorter gaps
	syncTimeout     = 4 * time.Minute // hard cap on the ffmpeg passes
	syncMinConf     = 3.0             // below this the match is not trusted
	syncDriftMinMS  = 250             // ends must disagree by this to count as drift
	runtimeSlackSec = 5.0             // tolerance when checking cues fit the file
	swapWorthItSec  = 2.0             // beyond this, look for a better-timed file
)

// syncResult reports what the analysis found.
type syncResult struct {
	Engine     string  `json:"engine"`
	Method     string  `json:"method"` // offset | linear | rewrite
	OffsetMS   int     `json:"offset_ms"`
	DriftMS    int     `json:"drift_ms"` // end-to-end slide across the runtime
	Scale      float64 `json:"scale"`
	Confidence float64 `json:"confidence"`
	Applied    bool    `json:"applied"`
	Rewrote    bool    `json:"rewrote_file"`
	SpeechSecs float64 `json:"speech_seconds"`
	CueCount   int     `json:"cue_count"`
	Windows    int     `json:"windows"`
	Message    string  `json:"message"`
}

type timeSpan struct{ start, end float64 }

// ---- subtitle parsing ----

var srtTimeRe = regexp.MustCompile(
	`(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})`)

// parseCueSpans pulls the on-screen intervals out of an SRT or VTT file.
func parseCueSpans(path string) ([]timeSpan, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	out := make([]timeSpan, 0, 1024)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		m := srtTimeRe.FindStringSubmatch(sc.Text())
		if m == nil {
			continue
		}
		start := srtSeconds(m[1], m[2], m[3], m[4])
		end := srtSeconds(m[5], m[6], m[7], m[8])
		if end > start && end-start < 30 {
			out = append(out, timeSpan{start, end})
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].start < out[j].start })
	return out, nil
}

func srtSeconds(h, m, s, frac string) float64 {
	hh, _ := strconv.Atoi(h)
	mm, _ := strconv.Atoi(m)
	ss, _ := strconv.Atoi(s)
	// The fractional field may be 1-3 digits; scale it to milliseconds.
	for len(frac) < 3 {
		frac += "0"
	}
	ms, _ := strconv.Atoi(frac[:3])
	return float64(hh*3600+mm*60+ss) + float64(ms)/1000
}

func formatSRTTime(sec float64) string {
	if sec < 0 {
		sec = 0
	}
	total := int(math.Round(sec * 1000))
	ms := total % 1000
	total /= 1000
	return fmt.Sprintf("%02d:%02d:%02d,%03d", total/3600, (total%3600)/60, total%60, ms)
}

// rewriteSubtitle applies t' = scale*t + offset to every cue, keeping a
// one-time .orig backup so the untouched file is always recoverable.
func rewriteSubtitle(path string, scale float64, offsetSec float64) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	backup := path + ".orig"
	if !fileExists(backup) {
		if err := os.WriteFile(backup, data, 0o644); err != nil {
			return fmt.Errorf("could not back up the original: %w", err)
		}
	}

	lines := strings.Split(string(data), "\n")
	for i, line := range lines {
		m := srtTimeRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		start := srtSeconds(m[1], m[2], m[3], m[4])*scale + offsetSec
		end := srtSeconds(m[5], m[6], m[7], m[8])*scale + offsetSec
		lines[i] = srtTimeRe.ReplaceAllString(line,
			formatSRTTime(start)+" --> "+formatSRTTime(end))
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(lines, "\n")), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ---- speech detection ----

var (
	silenceStartRe = regexp.MustCompile(`silence_start:\s*(-?[\d.]+)`)
	silenceEndRe   = regexp.MustCompile(`silence_end:\s*(-?[\d.]+)`)
)

// speechSpansIn decodes one window of audio and returns the intervals that are
// not silence, in absolute file time.
func (s *Server) speechSpansIn(file string, startSec, durSec float64, audioStream int) ([]timeSpan, error) {
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		return nil, fmt.Errorf("ffmpeg not installed")
	}
	args := []string{
		"-nostdin", "-hide_banner",
		"-ss", strconv.FormatFloat(startSec, 'f', 3, 64),
		"-t", strconv.FormatFloat(durSec, 'f', 3, 64),
		"-i", file,
		"-map", fmt.Sprintf("0:a:%d", audioStream),
		"-vn", "-sn", "-dn",
		"-af", fmt.Sprintf("silencedetect=noise=%ddB:d=%g", syncNoiseDB, syncMinSilence),
		"-f", "null", "-",
	}
	cmd := exec.Command(ff, args...)
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	// silencedetect reports the gaps; invert them into speech spans. Times are
	// relative to the seek point, so shift by startSec.
	var silences []timeSpan
	cur := timeSpan{start: -1}
	sc := bufio.NewScanner(stderr)
	for sc.Scan() {
		line := sc.Text()
		if m := silenceStartRe.FindStringSubmatch(line); m != nil {
			v, _ := strconv.ParseFloat(m[1], 64)
			cur = timeSpan{start: v, end: -1}
			continue
		}
		if m := silenceEndRe.FindStringSubmatch(line); m != nil && cur.start >= 0 {
			v, _ := strconv.ParseFloat(m[1], 64)
			cur.end = v
			silences = append(silences, cur)
			cur = timeSpan{start: -1}
		}
	}
	_ = cmd.Wait()

	if cur.start >= 0 {
		silences = append(silences, timeSpan{cur.start, durSec})
	}
	sort.Slice(silences, func(i, j int) bool { return silences[i].start < silences[j].start })

	speech := make([]timeSpan, 0, len(silences)+1)
	pos := 0.0
	for _, sil := range silences {
		if sil.start > pos {
			speech = append(speech, timeSpan{startSec + pos, startSec + sil.start})
		}
		if sil.end > pos {
			pos = sil.end
		}
	}
	if pos < durSec {
		speech = append(speech, timeSpan{startSec + pos, startSec + durSec})
	}
	return speech, nil
}

// ---- correlation ----

// binTimeline rasterises spans into a 0/1 array at the given resolution.
func binTimelineAt(spans []timeSpan, bins, binMS int) []float32 {
	out := make([]float32, bins)
	for _, sp := range spans {
		lo := int(sp.start * 1000 / float64(binMS))
		hi := int(sp.end * 1000 / float64(binMS))
		if hi >= bins {
			hi = bins - 1
		}
		for i := lo; i <= hi; i++ {
			if i >= 0 && i < bins {
				out[i] = 1
			}
		}
	}
	return out
}

// binTimeline keeps the coarse default for callers that do not care.
func binTimeline(spans []timeSpan, bins int) []float32 {
	return binTimelineAt(spans, bins, syncCoarseBinMS)
}

// correlateAt slides subs against speech over the given lag range (in bins)
// and returns the best lag in bins plus how far that peak stands out.
//
// The score is a Pearson correlation rather than a plain overlap count. In a
// feature film well over half of the runtime carries some sound, so a raw
// overlap is high at *every* offset and the true peak barely shows; removing
// each signal's mean cancels that constant background and leaves only the
// co-variation that actually identifies the alignment.
//
// mask marks the bins that were really decoded; only those are scored.
func correlateAt(speech, subs, mask []float32, loLag, hiLag int) (int, float64) {
	bins := len(speech)

	idx := make([]int32, 0, bins/8)
	for t := 0; t < bins; t++ {
		if mask[t] != 0 {
			idx = append(idx, int32(t))
		}
	}
	n := float64(len(idx))
	if n == 0 {
		return 0, 0
	}

	// The speech side never moves.
	var sx float64
	for _, t := range idx {
		sx += float64(speech[t])
	}

	scores := make([]float64, 0, hiLag-loLag+1)
	bestScore, bestLag := math.Inf(-1), 0
	for lag := loLag; lag <= hiLag; lag++ {
		var sy, sxy float64
		for _, t := range idx {
			src := int(t) - lag
			if src < 0 || src >= bins || subs[src] == 0 {
				continue
			}
			sy++
			if speech[t] != 0 {
				sxy++
			}
		}
		// Both signals are 0/1, so the sums of squares equal the sums.
		varX := n*sx - sx*sx
		varY := n*sy - sy*sy
		score := 0.0
		if varX > 0 && varY > 0 {
			score = (n*sxy - sx*sy) / math.Sqrt(varX*varY)
		}
		scores = append(scores, score)
		if score > bestScore {
			bestScore, bestLag = score, lag
		}
	}

	// Confidence: how many standard deviations the peak sits above the mean of
	// every other candidate offset. A genuine alignment is a sharp spike; an
	// ambiguous one sits in the noise.
	var sum, sumSq float64
	for _, v := range scores {
		sum += v
		sumSq += v * v
	}
	cnt := float64(len(scores))
	mean := sum / cnt
	variance := sumSq/cnt - mean*mean
	conf := 0.0
	if variance > 1e-12 {
		conf = (bestScore - mean) / math.Sqrt(variance)
	}
	return bestLag, conf
}

// bestOffset does the full coarse sweep and reports milliseconds.
func bestOffset(speech, subs, mask []float32) (int, float64) {
	maxLag := syncMaxLagSec * 1000 / syncCoarseBinMS
	lag, conf := correlateAt(speech, subs, mask, -maxLag, maxLag)
	return lag * syncCoarseBinMS, conf
}

// ---- external engines ----

type syncEngine struct {
	name string
	bin  string
	// args builds the command line for reference -> in -> out.
	args func(bin, video, in, out string, m engineMode) []string
}

// externalEngines are tried in order, alass first.
//
// alass earns the top slot because of one thing the built-in analysis cannot
// do: it looks for *splits*. When a release has been cut differently - an
// advert break removed, a scene trimmed - the required shift changes partway
// through, and no single offset can fix that.
//
// That same strength is a hazard. On a sparse, heavily scored soundtrack alass
// will happily invent segmentation that fits the music rather than the speech,
// and its default penalty of 7 splits eagerly. Doctor Who came back cut into
// four blocks shifted by +1.2s, +31s, -34s and -2m05s, when the whole episode
// simply needed +1.2s. So the conservative pass runs first and splitting is
// only accepted when it measurably beats it.
var externalEngines = []syncEngine{
	{
		// lapse is preferred for two reasons. It will use a subtitle track
		// muxed into the video as its reference instead of guessing from the
		// audio, which is far more reliable on a heavily scored soundtrack;
		// and it reports its own confidence and declines to write when it is
		// not sure, rather than always returning its best guess.
		name: "lapse",
		bin:  "lapse",
		args: func(bin, video, in, out string, m engineMode) []string {
			mode := "nosplit"
			switch m {
			case modeRate:
				mode = "ols" // linear drift
			case modeSplit:
				mode = "split"
			}
			return []string{video, in, mode, "--output", out,
				"--no-backup", "--json", "--quiet"}
		},
	},
	{
		name: "alass",
		bin:  "alass-cli",
		args: func(bin, video, in, out string, m engineMode) []string {
			return alassArgs(video, in, out, m)
		},
	},
	{
		name: "alass",
		bin:  "alass",
		args: func(bin, video, in, out string, m engineMode) []string {
			return alassArgs(video, in, out, m)
		},
	},
	{
		name: "ffsubsync",
		bin:  "ffsubsync",
		args: func(bin, video, in, out string, m engineMode) []string {
			args := []string{video, "-i", in, "-o", out}
			if m < modeRate {
				args = append(args, "--no-fix-framerate")
			}
			return args
		},
	},
}

// engineMode is how much licence the engine is given. Each step can fix more
// but can also break more, so they are tried in order and only escalated on
// evidence.
type engineMode int

const (
	// Shift everything by one constant. Cannot make a subtitle progressively
	// worse, so it is the default.
	modeShift engineMode = iota
	// Also allow a frame-rate correction. Fixes 25fps subtitles on a 23.976fps
	// cut, but a wrong guess drifts further out with every minute.
	modeRate
	// Also allow the file to be cut into independently shifted segments.
	modeSplit
)

func (m engineMode) String() string {
	switch m {
	case modeRate:
		return "with a rate correction"
	case modeSplit:
		return "in segments"
	}
	return "as one block"
}

func alassArgs(video, in, out string, m engineMode) []string {
	args := []string{}
	if m < modeSplit {
		args = append(args, "--no-split")
	}
	if m < modeRate {
		// alass guesses frame-rate differences by default. On Doctor Who that
		// invented a 25/23.976 stretch for a subtitle that was already correct,
		// pulling the closing lines nearly two minutes out of place.
		args = append(args, "--disable-fps-guessing")
	}
	return append(args, video, in, out)
}

// extraBinDirs are searched as well as PATH. A server started from a desktop
// launcher or a systemd unit does not inherit the shell's PATH, so tools the
// user installed into their home would otherwise look missing.
var extraBinDirs = []string{
	"~/.cargo/bin",
	"~/.local/bin",
	"/usr/local/bin",
}

// findEngine returns the first installed external synchroniser.
func findEngine() (*syncEngine, string) {
	for i := range externalEngines {
		if path, err := exec.LookPath(externalEngines[i].bin); err == nil {
			return &externalEngines[i], path
		}
		for _, dir := range extraBinDirs {
			candidate := filepath.Join(expandHome(dir), externalEngines[i].bin)
			if fi, err := os.Stat(candidate); err == nil && !fi.IsDir() &&
				fi.Mode()&0o111 != 0 {
				return &externalEngines[i], candidate
			}
		}
	}
	return nil, ""
}

// runEngine produces a corrected subtitle in a temporary file and returns its
// cue timings. Nothing is written over the user's file here.
func runEngine(eng *syncEngine, path, video, subPath string, m engineMode) ([]timeSpan, string, error) {
	out := subPath + ".sync-candidate.srt"
	cmd := exec.Command(path, eng.args(path, video, subPath, out, m)...)
	combined, err := cmd.CombinedOutput()
	if err != nil {
		os.Remove(out)
		tail := strings.TrimSpace(string(combined))
		if len(tail) > 300 {
			tail = tail[len(tail)-300:]
		}
		return nil, "", fmt.Errorf("%s failed: %v (%s)", eng.name, err, tail)
	}
	if !fileExists(out) {
		return nil, "", fmt.Errorf("%s produced no output", eng.name)
	}
	spans, err := parseCueSpans(out)
	if err != nil || len(spans) == 0 {
		os.Remove(out)
		return nil, "", fmt.Errorf("%s produced an unreadable subtitle", eng.name)
	}
	return spans, out, nil
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// ---- frame-rate snapping ----

// commonRates are the frame rates subtitles get mistimed between. A subtitle
// authored for one and played against another slides by a fixed ratio, so a
// measured scale very close to one of these is almost certainly exactly it.
var commonRates = []float64{23.976, 24, 25, 29.97, 30}

// snapScale pulls a measured scale onto an exact frame-rate ratio when it is
// within a hair of one, which removes the residual error at the ends.
func snapScale(scale float64) float64 {
	if math.Abs(scale-1) < 0.0005 {
		return 1
	}
	best, bestErr := scale, 0.002
	for _, a := range commonRates {
		for _, b := range commonRates {
			if a == b {
				continue
			}
			ratio := a / b
			if e := math.Abs(scale - ratio); e < bestErr {
				best, bestErr = ratio, e
			}
		}
	}
	return best
}

// ---- built-in analysis ----

// maskFor rasterises the sampled windows at a given resolution.
func maskFor(windows []timeSpan, bins, binMS int) []float32 {
	mask := make([]float32, bins)
	for _, w := range windows {
		lo := int(w.start * 1000 / float64(binMS))
		hi := int(w.end * 1000 / float64(binMS))
		for t := lo; t <= hi && t < bins; t++ {
			if t >= 0 {
				mask[t] = 1
			}
		}
	}
	return mask
}

func binCount(duration float64, binMS int) int {
	return int(duration*1000/float64(binMS)) + syncMaxLagSec*1000/binMS + 2
}

// scaleSpans stretches a subtitle timeline by a constant factor.
func scaleSpans(spans []timeSpan, scale float64) []timeSpan {
	if scale == 1 {
		return spans
	}
	out := make([]timeSpan, len(spans))
	for i, sp := range spans {
		out[i] = timeSpan{sp.start * scale, sp.end * scale}
	}
	return out
}

// measureCoarse finds the shift for one group of windows at 100ms resolution.
func measureCoarse(speechSpans, cues []timeSpan, windows []timeSpan, duration float64) (float64, float64) {
	if len(windows) == 0 {
		return 0, 0
	}
	bins := binCount(duration, syncCoarseBinMS)
	mask := maskFor(windows, bins, syncCoarseBinMS)
	speech := binTimelineAt(speechSpans, bins, syncCoarseBinMS)
	subs := binTimelineAt(cues, bins, syncCoarseBinMS)
	ms, conf := bestOffset(speech, subs, mask)
	return float64(ms) / 1000, conf
}

// refineFine re-searches a narrow band around a coarse answer at 10ms, so the
// final number lands close enough that the first and last lines both sit right.
func refineFine(speechSpans, cues []timeSpan, windows []timeSpan, duration, coarseSec float64) (float64, float64) {
	if len(windows) == 0 {
		return coarseSec, 0
	}
	bins := binCount(duration, syncFineBinMS)
	mask := maskFor(windows, bins, syncFineBinMS)
	speech := binTimelineAt(speechSpans, bins, syncFineBinMS)
	subs := binTimelineAt(cues, bins, syncFineBinMS)

	centre := int(math.Round(coarseSec * 1000 / syncFineBinMS))
	span := syncFineLagMS / syncFineBinMS
	lag, conf := correlateAt(speech, subs, mask, centre-span, centre+span)
	return float64(lag*syncFineBinMS) / 1000, conf
}

// scaleCandidates is 1.0 plus every distinct ratio between the frame rates
// subtitles get mistimed across.
//
// This is the case a single offset can never fix: a subtitle authored at 25fps
// played against a 23.976fps cut does not sit a fixed distance away, it slides
// - by roughly four percent, which is several minutes across a feature. No lag
// search will find that, so the ratio has to be a candidate in its own right.
func scaleCandidates() []float64 {
	seen := map[float64]bool{1: true}
	out := []float64{1}
	for _, a := range commonRates {
		for _, b := range commonRates {
			if a == b {
				continue
			}
			r := math.Round(a/b*1e6) / 1e6
			if !seen[r] {
				seen[r] = true
				out = append(out, r)
			}
		}
	}
	return out
}

type timelineFit struct {
	scale     float64
	offsetSec float64
	conf      float64
}

// fitTimeline tries each candidate rate ratio and keeps whichever produces the
// sharpest alignment.
func fitTimeline(speech, cues, windows []timeSpan, duration float64) timelineFit {
	best := timelineFit{scale: 1, conf: math.Inf(-1)}
	for _, a := range scaleCandidates() {
		scaled := scaleSpans(cues, a)
		// A stretched timeline runs past the original end, so give it room.
		off, conf := measureCoarse(speech, scaled, windows, duration*math.Max(1, a))
		if conf > best.conf {
			best = timelineFit{scale: a, offsetSec: off, conf: conf}
		}
	}
	return best
}

// speechSample is the decoded audio evidence, reused for every candidate.
type speechSample struct {
	spans    []timeSpan
	windows  []timeSpan
	seconds  float64
	duration float64
}

// sampleSpeech decodes a handful of windows spread across the runtime.
func (s *Server) sampleSpeech(file string, duration float64) (*speechSample, error) {
	usable := duration * 0.86
	start := duration * 0.07
	windows := syncWindows
	span := float64(syncWindowSec)
	if usable < float64(windows)*span {
		windows = int(usable / span)
		if windows < 2 {
			windows, span = 2, usable/2
		}
	}

	out := &speechSample{duration: duration}
	deadline := time.Now().Add(syncTimeout)
	for i := 0; i < windows; i++ {
		if time.Now().After(deadline) {
			break
		}
		at := start + (usable-span)*float64(i)/float64(windows-1)
		spans, err := s.speechSpansIn(file, at, span, 0)
		if err != nil {
			return nil, err
		}
		out.windows = append(out.windows, timeSpan{at, at + span})
		for _, sp := range spans {
			out.seconds += sp.end - sp.start
		}
		out.spans = append(out.spans, spans...)
	}
	if len(out.windows) < 2 {
		return nil, fmt.Errorf("could not analyse enough of the audio")
	}
	if out.seconds < 30 {
		return nil, fmt.Errorf("found only %.0fs of dialogue in the sampled windows",
			out.seconds)
	}
	return out, nil
}

// gradeCandidate asks how well an already-corrected subtitle lines up with the
// speech: a good one needs no further shift and correlates sharply.
//
// This is the check that was missing when an external engine ran. alass has no
// notion of confidence and will return its best guess however poor it is, so
// without an independent opinion its output was being applied blind - which is
// exactly how a wrongly split episode got written over a good subtitle.
func gradeCandidate(sample *speechSample, cues []timeSpan) (residualSec, conf float64) {
	coarse, c := measureCoarse(sample.spans, cues, sample.windows, sample.duration)
	fine, fc := refineFine(sample.spans, cues, sample.windows, sample.duration, coarse)
	if fc > c {
		c = fc
	}
	return fine, c
}

// acceptable reports whether a graded candidate is worth applying.
func acceptable(residualSec, conf float64) bool {
	return conf >= syncMinConf && math.Abs(residualSec) <= 0.35
}

// fitsRuntime rejects a correction that puts dialogue outside the file.
//
// This catches what the audio check cannot: it needs no speech detection, so
// it works just as well on a wall-to-wall orchestral score. A stretch applied
// to an already-correct subtitle pushes the closing line past the end of the
// video, which is impossible and is exactly how a good President Curtis
// subtitle got ruined.
func fitsRuntime(spans []timeSpan, duration float64) (bool, string) {
	if len(spans) == 0 {
		return false, "it produced no cues"
	}
	last := spans[len(spans)-1].end
	if duration > 0 && last > duration+runtimeSlackSec {
		return false, fmt.Sprintf(
			"the closing line would land %.0fs after the video ends", last-duration)
	}
	// Leaving a big chunk of the runtime with no dialogue at all is the same
	// mistake in the other direction.
	if duration > 0 && last < duration*0.5 {
		return false, fmt.Sprintf(
			"the closing line would fall %.0f minutes before the end",
			(duration-last)/60)
	}
	return true, ""
}

// verdict combines both checks. confident reports whether a rejection is
// something we are sure about, which is what licenses trying a riskier pass.
func verdict(spans []timeSpan, duration, residual, conf float64) (ok, confident bool, reason string) {
	if fits, why := fitsRuntime(spans, duration); !fits {
		return false, true, why
	}
	if conf < syncMinConf {
		// No usable opinion from the audio; the runtime check has to carry it.
		return true, false, ""
	}
	if !acceptable(residual, conf) {
		return false, true, fmt.Sprintf("it would still be %+.1fs out", residual)
	}
	return true, true, ""
}

// impliedScale fits after ~ scale*before + offset by pairing each cue with its
// nearest counterpart, and reports the scale plus the median residual.
func impliedScale(before, after []timeSpan) (scale float64, median float64, paired int) {
	if len(before) < 40 || len(after) < 40 {
		return 1, 0, 0
	}
	starts := make([]float64, len(after))
	for i, sp := range after {
		starts[i] = sp.start
	}
	var xs, ys []float64
	for _, b := range before {
		i := sort.SearchFloat64s(starts, b.start)
		best, bestD := 0.0, math.Inf(1)
		for _, j := range []int{i - 1, i, i + 1} {
			if j < 0 || j >= len(starts) {
				continue
			}
			if d := math.Abs(starts[j] - b.start); d < bestD {
				best, bestD = starts[j], d
			}
		}
		if bestD < 25 {
			xs = append(xs, b.start)
			ys = append(ys, best)
		}
	}
	if len(xs) < 40 {
		return 1, 0, len(xs)
	}
	n := float64(len(xs))
	var sx, sy, sxx, sxy float64
	for i := range xs {
		sx += xs[i]
		sy += ys[i]
		sxx += xs[i] * xs[i]
		sxy += xs[i] * ys[i]
	}
	den := n*sxx - sx*sx
	if den == 0 {
		return 1, 0, len(xs)
	}
	scale = (n*sxy - sx*sy) / den
	off := (sy - scale*sx) / n
	res := make([]float64, len(xs))
	for i := range xs {
		res[i] = math.Abs(ys[i] - (scale*xs[i] + off))
	}
	sort.Float64s(res)
	return scale, res[len(res)/2], len(xs)
}

// candidateScale reports the rate change a candidate applies, from how much
// further the closing line moved than the opening one.
//
// The engines rewrite cue for cue, so pairing by index is exact. Pairing by
// proximity is not: once a stretch pushes the late cues a minute or two away
// they match the wrong neighbours and the fit comes back as no change at all,
// which is how a 4% stretch slipped past this check.
func candidateScale(original, candidate []timeSpan) float64 {
	n := min(len(original), len(candidate))
	if n < 2 {
		return 1
	}
	span := original[n-1].start - original[0].start
	if span < 60 {
		return 1
	}
	shiftFirst := candidate[0].start - original[0].start
	shiftLast := candidate[n-1].start - original[n-1].start
	return 1 + (shiftLast-shiftFirst)/span
}

// rateChangeSupported asks a second subtitle for the same title whether the
// original timing was really stretched.
//
// Two subtitles authored independently for the same cut track each other at a
// scale of 1. When they do, the file is not stretched and a candidate that
// claims otherwise is wrong - which is exactly how a good Doctor Who subtitle
// got pulled two minutes out of place. With no sibling to ask, the caller's
// other checks stand on their own.
func rateChangeSupported(candidate, original []timeSpan, siblings [][]timeSpan) bool {
	if math.Abs(candidateScale(original, candidate)-1) < 0.002 {
		return true // not a meaningful rate change
	}
	for _, sib := range siblings {
		sibScale, medianResidual, n := impliedScale(original, sib)
		if n < 40 || medianResidual > 3 {
			continue // too loose a pairing to conclude anything
		}
		if math.Abs(sibScale-1) < 0.002 {
			return false // the sibling says the original runs at the right rate
		}
	}
	return true
}

// syncSubtitle measures how far a subtitle drifts from the audio and applies
// the correction.
func (s *Server) syncSubtitle(kind string, id int64, subPath string, siblingPaths []string, apply bool) (*syncResult, error) {
	file, err := s.resolveMediaFile(kind, id)
	if err != nil {
		return nil, fmt.Errorf("media file not found")
	}

	cues, err := parseCueSpans(subPath)
	if err != nil {
		return nil, fmt.Errorf("could not read subtitle: %w", err)
	}
	if len(cues) < 20 {
		return nil, fmt.Errorf("subtitle has too few cues to sync (%d)", len(cues))
	}

	duration := float64(0)
	if c := s.getCheck(kind, id); c != nil {
		duration = float64(c.DurationSec)
	}
	if duration <= 0 {
		duration = cues[len(cues)-1].end + 60
	}
	if duration < 180 {
		return nil, fmt.Errorf("item is too short to sync")
	}

	sample, err := s.sampleSpeech(file, duration)
	if err != nil {
		return nil, err
	}

	// Other languages for the same title, used to sanity-check a rate change.
	var siblings [][]timeSpan
	for _, p := range siblingPaths {
		if spans, err := parseCueSpans(p); err == nil && len(spans) >= 40 {
			siblings = append(siblings, spans)
		}
	}

	// ---- external engine, sanity-checked against the audio ----
	//
	// The check is a veto, not a vote. Energy-based speech detection cannot
	// tell dialogue from a continuous orchestral score, so on something like
	// Doctor Who it has almost no opinion - and a weak opinion must not be
	// allowed to override a real VAD. It only overrides when it is *confident*
	// the result is wrong, and splitting is only attempted in that case: left
	// to its own devices alass will happily cut a music-heavy episode into
	// blocks shifted by half a minute in each direction.
	if eng, path := findEngine(); eng != nil {
		// Escalate only on evidence. A constant shift is tried first because
		// it cannot make a subtitle progressively worse; a rate correction or
		// a segmented fit is allowed only once the audio confidently says the
		// simple answer is wrong. Left to itself alass reached for a frame-rate
		// guess on a Doctor Who subtitle that was already correctly timed.
		var (
			chosen     []timeSpan
			chosenFile string
			chosenMode engineMode
			conf       float64
			checked    bool
			accepted   bool
			reason     string
		)
		for _, mode := range []engineMode{modeShift, modeRate, modeSplit} {
			spans, out, err := runEngine(eng, path, file, subPath, mode)
			if err != nil {
				log.Printf("subtitle sync: %v", err)
				continue
			}
			residual, c := gradeCandidate(sample, spans)
			ok, confident, why := verdict(spans, duration, residual, c)
			if ok && mode > modeShift && !rateChangeSupported(spans, cues, siblings) {
				ok, confident = false, true
				why = "a second subtitle for this title says the timing is not stretched"
			}

			if ok {
				chosen, chosenFile, chosenMode = spans, out, mode
				conf, checked, accepted = c, c >= syncMinConf, true
				break
			}
			os.Remove(out)
			conf, reason = c, why
			if !confident {
				// No firm opinion either way; a riskier pass would be a guess.
				break
			}
		}
		if chosenFile != "" {
			defer os.Remove(chosenFile)
		}

		if !accepted {
			// Correcting this file cannot be done safely, so go looking for a
			// version that was timed for this release in the first place.
			if fetched := s.trySwapSubtitle(kind, id, subPath, duration, reason, apply); fetched != nil {
				return fetched, nil
			}
			return &syncResult{
				Engine:     eng.name,
				Method:     "rewrite",
				Confidence: math.Round(conf*100) / 100,
				SpeechSecs: math.Round(sample.seconds),
				CueCount:   len(cues),
				Windows:    len(sample.windows),
				Message: fmt.Sprintf(
					"Left unchanged: %s. No better-timed subtitle was available either - nudge it with the slider.",
					reason),
			}, nil
		}

		shiftFirst := chosen[0].start - cues[0].start
		n := min(len(cues), len(chosen))
		shiftLast := chosen[n-1].start - cues[n-1].start

		res := &syncResult{
			Engine:     eng.name,
			Method:     "rewrite",
			OffsetMS:   int(math.Round(shiftFirst * 1000)),
			DriftMS:    int(math.Round((shiftLast - shiftFirst) * 1000)),
			Scale:      1,
			Confidence: math.Round(conf*100) / 100,
			SpeechSecs: math.Round(sample.seconds),
			CueCount:   len(chosen),
			Windows:    len(sample.windows),
		}
		if apply {
			data, err := os.ReadFile(chosenFile)
			if err != nil {
				return nil, err
			}
			if !fileExists(subPath + ".orig") {
				if orig, err := os.ReadFile(subPath); err == nil {
					os.WriteFile(subPath+".orig", orig, 0o644)
				}
			}
			if err := os.WriteFile(subPath, data, 0o644); err != nil {
				return nil, err
			}
			_ = s.setSubtitleDelay(kind, id, 0)
			res.Applied, res.Rewrote = true, true
		}

		// A large correction means this subtitle was cut for a different
		// release. Shifting it may land the dialogue but the line breaks and
		// timings still belong to another edit, so prefer a file that was
		// timed for this one if OpenSubtitles has it.
		if math.Abs(shiftFirst) > swapWorthItSec {
			if swapped := s.trySwapSubtitle(kind, id, subPath, duration,
				fmt.Sprintf("it was %+.1fs out, which usually means it was cut for another release", shiftFirst),
				apply); swapped != nil {
				return swapped, nil
			}
		}

		verb := map[bool]string{true: "Resynced", false: "Measured"}[apply]
		res.Message = fmt.Sprintf("%s with %s %s: %+.2fs",
			verb, eng.name, chosenMode, shiftFirst)
		if abs(res.DriftMS) >= syncDriftMinMS {
			res.Message += fmt.Sprintf(" at the start, %+.2fs at the end", shiftLast)
		}
		if checked {
			res.Message += fmt.Sprintf(". Checked against the audio, confidence %.1f.", conf)
		} else {
			res.Message += ". Too much music to check it against the audio, so give it a look."
		}
		return res, nil
	}

	// ---- built-in analysis (no external engine installed) ----
	allSpeech := sample.spans
	sampled := sample.windows
	speechSecs := sample.seconds

	// Find the rate ratio and shift that align best overall, then sharpen the
	// shift and check whether the two ends still disagree.
	fit := fitTimeline(allSpeech, cues, sampled, duration)
	scaled := scaleSpans(cues, fit.scale)
	scaledDuration := duration * math.Max(1, fit.scale)
	globalSec, fineConf := refineFine(allSpeech, scaled, sampled, scaledDuration, fit.offsetSec)
	conf := math.Max(fit.conf, fineConf)

	half := len(sampled) / 2
	earlyCoarse, earlyConf := measureCoarse(allSpeech, scaled, sampled[:half], scaledDuration)
	lateCoarse, lateConf := measureCoarse(allSpeech, scaled, sampled[half:], scaledDuration)
	earlyShift, _ := refineFine(allSpeech, scaled, sampled[:half], scaledDuration, earlyCoarse)
	lateShift, _ := refineFine(allSpeech, scaled, sampled[half:], scaledDuration, lateCoarse)

	res := &syncResult{
		Engine:     "built-in",
		Method:     "offset",
		OffsetMS:   int(math.Round(globalSec * 1000)),
		Scale:      math.Round(fit.scale*1e6) / 1e6,
		Confidence: math.Round(conf*100) / 100,
		SpeechSecs: math.Round(speechSecs),
		CueCount:   len(cues),
		Windows:    len(sampled),
	}

	if conf < syncMinConf {
		res.Message = fmt.Sprintf(
			"Measured %+.2fs but the match is weak (confidence %.1f). Left unchanged.",
			globalSec, conf)
		return res, nil
	}

	midOf := func(ws []timeSpan) float64 {
		return (ws[0].start + ws[len(ws)-1].end) / 2
	}
	residualDrift := 0.0
	if earlyConf >= syncMinConf && lateConf >= syncMinConf {
		residualDrift = lateShift - earlyShift
	}

	scale := fit.scale
	offset := globalSec
	driftMS := int(math.Round(residualDrift * 1000))
	if abs(driftMS) >= syncDriftMinMS {
		t1, t2 := midOf(sampled[:half]), midOf(sampled[half:])
		extra := snapScale(1 + residualDrift/(t2-t1))
		offset = earlyShift - (extra-1)*t1
		scale = scale * extra
	}
	res.DriftMS = int(math.Round((scale-1)*duration*1000)) + driftMS
	res.Scale = math.Round(scale*1e6) / 1e6

	if math.Abs(scale-1) > 1e-6 {
		res.Method = "linear"
		if apply {
			if err := rewriteSubtitle(subPath, scale, offset); err != nil {
				return nil, fmt.Errorf("could not rewrite the subtitle: %w", err)
			}
			if err := s.setSubtitleDelay(kind, id, 0); err != nil {
				return nil, fmt.Errorf("could not clear the delay: %w", err)
			}
			res.Applied, res.Rewrote = true, true
		}
		res.OffsetMS = int(math.Round(offset * 1000))
		res.Message = fmt.Sprintf(
			"Subtitles were sliding (%+.0fs end to end). Rewrote the file at rate x%.4f, %+.2fs at the start.",
			float64(res.DriftMS)/1000, scale, offset)
		return res, nil
	}

	// A constant shift: keep it as a delay, which stays reversible.
	res.OffsetMS = int(math.Round(offset * 1000))
	if res.OffsetMS == 0 {
		res.Message = "Already in sync."
		res.Applied = apply
		return res, nil
	}
	if apply {
		if err := s.setSubtitleDelay(kind, id, res.OffsetMS); err != nil {
			return nil, fmt.Errorf("could not store the delay: %w", err)
		}
		res.Applied = true
	}
	res.Message = fmt.Sprintf("Shifted subtitles by %+.2fs (confidence %.1f).",
		offset, conf)
	return res, nil
}

// betterCandidate prefers a sharper match, but only when its residual shift is
// also small: a high correlation at the wrong place is not an improvement.
func betterCandidate(resA, confA, resB, confB float64) bool {
	okA, okB := acceptable(resA, confA), acceptable(resB, confB)
	if okA != okB {
		return okA
	}
	return confA > confB
}

// trySwapSubtitle replaces a subtitle that cannot be corrected with a
// better-timed one from OpenSubtitles. Returns nil when nothing better was
// found, so the caller can report its own failure.
func (s *Server) trySwapSubtitle(kind string, id int64, subPath string,
	duration float64, why string, apply bool) *syncResult {

	lang := languageOf(subPath)
	best, notes, err := s.findBetterSubtitle(kind, id, lang, duration, 3)
	if err != nil {
		log.Printf("subtitle search %s/%d: %v", kind, id, err)
		return nil
	}
	if !best.fits || best.shiftSec > 1.5 {
		log.Printf("subtitle search %s/%d: nothing better (%s)", kind, id,
			strings.Join(notes, "; "))
		return nil
	}

	res := &syncResult{
		Engine:   "opensubtitles",
		Method:   "replaced",
		OffsetMS: int(math.Round(best.shiftSec * 1000)),
		Scale:    1,
		CueCount: 0,
	}
	if apply {
		if !fileExists(subPath + ".orig") {
			if orig, err := os.ReadFile(subPath); err == nil {
				os.WriteFile(subPath+".orig", orig, 0o644)
			}
		}
		if err := os.WriteFile(subPath, best.body, 0o644); err != nil {
			log.Printf("subtitle search %s/%d: write failed: %v", kind, id, err)
			return nil
		}
		_ = s.setSubtitleDelay(kind, id, 0)
		res.Applied, res.Rewrote = true, true
	}
	if spans, err := parseCueSpans(subPath); err == nil {
		res.CueCount = len(spans)
	}
	verb := map[bool]string{true: "Swapped in", false: "Found"}[apply]
	res.Message = fmt.Sprintf(
		"%s a subtitle timed for this release from OpenSubtitles (%s) - it lines up to within %s. The old file was left behind because %s.",
		verb, shortRelease(best.cand), shiftLabel(best.shiftSec), why)
	return res
}

// languageOf reads the language tag a subtitle filename carries, as the
// scanner writes them: "Movie.en.srt".
func languageOf(path string) string {
	base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	if i := strings.LastIndex(base, "."); i >= 0 {
		tag := strings.ToLower(base[i+1:])
		if len(tag) >= 2 && len(tag) <= 5 {
			return tag
		}
	}
	return "en"
}

// pickSubtitle resolves a track index from /tracks into something a
// sync/replace operation can act on.
//
// Every endpoint has to resolve indices the same way the track list builds
// them, or a user picking "track 2" acts on a different file than the one they
// are watching.
func (s *Server) pickSubtitle(kind string, id int64, index *int) (
	path string, src *resolvedSubtitle, dest string, err error) {

	dir, derr := s.mediaDirFor(kind, id)
	if derr != nil {
		return "", nil, "", fmt.Errorf("media not found")
	}
	full, ferr := s.resolveMediaFile(kind, id)
	if ferr != nil {
		return "", nil, "", fmt.Errorf("media file not found")
	}
	stem := strings.TrimSuffix(filepath.Base(full), filepath.Ext(full))

	sources, serr := s.subtitleSources(kind, id)
	if serr != nil {
		return "", nil, "", serr
	}
	idx := 0
	if index != nil {
		idx = *index
	}
	if idx < 0 || idx >= len(sources) {
		return "", nil, "", fmt.Errorf("subtitle index out of range")
	}
	chosen := sources[idx]

	lang := "en"
	if chosen.external != nil {
		path = chosen.external.Path
		lang = languageOf(path)
		dest = path
	} else {
		// An embedded track has no file to rewrite; a replacement is written
		// alongside the video instead.
		lang = shortLangCode(chosen.embedded.Language)
		dest = filepath.Join(dir, fmt.Sprintf("%s.%s.srt", stem, lang))
	}
	return path, &chosen, dest, nil
}

// shortLangCode maps ffprobe's three-letter tags onto the two-letter ones the
// scanner uses for filenames.
func shortLangCode(code string) string {
	switch strings.ToLower(code) {
	case "eng", "en":
		return "en"
	case "ara", "ar":
		return "ar"
	case "fre", "fra", "fr":
		return "fr"
	case "ger", "deu", "de":
		return "de"
	case "spa", "es":
		return "es"
	case "":
		return "en"
	}
	if len(code) >= 2 {
		return strings.ToLower(code[:2])
	}
	return "en"
}

// handleSubtitleSync runs the analysis for one subtitle track of one item.
func (s *Server) handleSubtitleSync(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	var body struct {
		Index *int  `json:"index"`
		Apply *bool `json:"apply"`
	}
	_ = readJSON(r, &body)

	path, src, _, err := s.pickSubtitle(kind, id, body.Index)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	if src.embedded != nil {
		// Nothing to do: it came out of the video itself.
		writeJSON(w, 200, &syncResult{
			Engine: "none", Method: "none", Scale: 1,
			Message: "This track comes from inside the video file, so it is already in sync. Nothing to correct.",
		})
		return
	}
	apply := true
	if body.Apply != nil {
		apply = *body.Apply
	}

	// Other languages beside the video, used to sanity-check a rate change.
	var siblingPaths []string
	if sources, serr := s.subtitleSources(kind, id); serr == nil {
		for _, other := range sources {
			if other.external != nil && other.external.Path != path {
				siblingPaths = append(siblingPaths, other.external.Path)
			}
		}
	}
	res, err := s.syncSubtitle(kind, id, path, siblingPaths, apply)
	if err != nil {
		writeError(w, 422, err.Error())
		return
	}
	log.Printf("subtitle sync %s/%d (%s) via %s: %+d ms, drift %+d ms, confidence %.2f, applied=%v",
		kind, id, filepath.Base(path), res.Engine, res.OffsetMS, res.DriftMS,
		res.Confidence, res.Applied)
	writeJSON(w, 200, res)
}

// handleSubtitleFind swaps in a better-timed subtitle from OpenSubtitles,
// without first trying to bend the existing one into shape.
//
// Correcting a file can only move timings that are already there; when a
// subtitle was cut for a different edit entirely, the answer is a different
// file. This is that, on demand.
func (s *Server) handleSubtitleFind(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	var body struct {
		Index *int   `json:"index"`
		Lang  string `json:"language"`
		Limit *int   `json:"limit"`
		Apply *bool  `json:"apply"`
	}
	_ = readJSON(r, &body)

	_, _, dest, err := s.pickSubtitle(kind, id, body.Index)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	lang := body.Lang
	if lang == "" {
		lang = languageOf(dest)
	}

	duration := float64(0)
	if c := s.getCheck(kind, id); c != nil {
		duration = float64(c.DurationSec)
	}
	limit := 3
	if body.Limit != nil && *body.Limit > 0 && *body.Limit <= 5 {
		limit = *body.Limit
	}
	apply := true
	if body.Apply != nil {
		apply = *body.Apply
	}

	best, notes, err := s.findBetterSubtitle(kind, id, lang, duration, limit)
	if err != nil {
		writeError(w, 422, err.Error())
		return
	}

	res := &syncResult{
		Engine:   "opensubtitles",
		Method:   "replaced",
		OffsetMS: int(math.Round(best.shiftSec * 1000)),
		Scale:    1,
	}
	if !best.fits {
		res.Message = fmt.Sprintf(
			"The closest match (%s) does not fit this cut. Tried: %s.",
			shortRelease(best.cand), strings.Join(notes, "; "))
		writeJSON(w, 200, res)
		return
	}
	if apply {
		if fileExists(dest) && !fileExists(dest+".orig") {
			if orig, rerr := os.ReadFile(dest); rerr == nil {
				os.WriteFile(dest+".orig", orig, 0o644)
			}
		}
		if err := os.WriteFile(dest, best.body, 0o644); err != nil {
			writeError(w, 500, "could not write the subtitle")
			return
		}
		_ = s.setSubtitleDelay(kind, id, 0)
		res.Applied, res.Rewrote = true, true
	}
	if spans, perr := parseCueSpans(dest); perr == nil {
		res.CueCount = len(spans)
	}
	verb := map[bool]string{true: "Installed", false: "Found"}[apply]
	res.Message = fmt.Sprintf("%s %s - it lines up to within %s.",
		verb, shortRelease(best.cand), shiftLabel(best.shiftSec))
	log.Printf("subtitle find %s/%d (%s): %s [%s]", kind, id, lang,
		shortRelease(best.cand), strings.Join(notes, "; "))
	writeJSON(w, 200, res)
}

// handleSubtitleOptions lists the subtitles on offer for an item so the user
// can pick one themselves, rather than only ever getting the server's choice.
//
// Listing costs no download quota, so the whole list is cheap to browse; only
// installing one spends anything.
func (s *Server) handleSubtitleOptions(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	lang := r.URL.Query().Get("language")
	if lang == "" {
		lang = "en"
	}
	limit := 12
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 40 {
		limit = v
	}
	cands, err := s.listCandidates(kind, id, lang, limit)
	if err != nil {
		writeError(w, 422, err.Error())
		return
	}
	out := make([]map[string]any, 0, len(cands))
	for _, c := range cands {
		name := c.Release
		if name == "" {
			name = c.FileName
		}
		out = append(out, map[string]any{
			"file_id":    c.FileID,
			"name":       name,
			"language":   c.Language,
			"downloads":  c.Downloads,
			"hash_match": c.HashMatch,
		})
	}
	writeJSON(w, 200, map[string]any{"language": lang, "options": out})
}

// handleSubtitleInstall downloads one chosen option and puts it in place.
func (s *Server) handleSubtitleInstall(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	var body struct {
		FileID int    `json:"file_id"`
		Lang   string `json:"language"`
		Index  *int   `json:"index"`
	}
	if err := readJSON(r, &body); err != nil || body.FileID == 0 {
		writeError(w, 400, "file_id is required")
		return
	}
	_, _, dest, err := s.pickSubtitle(kind, id, body.Index)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	lang := body.Lang
	if lang == "" {
		lang = languageOf(dest)
	}

	cues, err := s.installCandidate(kind, id, body.FileID, lang, dest)
	if err != nil {
		writeError(w, 422, err.Error())
		return
	}
	_ = s.setSubtitleDelay(kind, id, 0)
	log.Printf("subtitle install %s/%d (%s): file_id=%d, %d cues", kind, id, lang, body.FileID, cues)
	writeJSON(w, 200, &syncResult{
		Engine:   "opensubtitles",
		Method:   "replaced",
		Applied:  true,
		Rewrote:  true,
		CueCount: cues,
		Scale:    1,
		Message:  fmt.Sprintf("Installed a different subtitle (%d lines). Try it, and pick another if it is still off.", cues),
	})
}

// handleSubtitleRestore puts back the untouched subtitle kept aside by a sync.
func (s *Server) handleSubtitleRestore(w http.ResponseWriter, r *http.Request) {
	kind := mediaKindFor(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	var body struct {
		Index *int `json:"index"`
	}
	_ = readJSON(r, &body)

	path, src, _, err := s.pickSubtitle(kind, id, body.Index)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	if src.embedded != nil {
		writeError(w, 400, "that track comes from inside the video and was never changed")
		return
	}
	backup := path + ".orig"
	if !fileExists(backup) {
		writeError(w, 404, "this subtitle has not been rewritten, so there is nothing to restore")
		return
	}
	data, err := os.ReadFile(backup)
	if err != nil {
		writeError(w, 500, "could not read the backup")
		return
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		writeError(w, 500, "could not restore the subtitle")
		return
	}
	os.Remove(backup)
	_ = s.setSubtitleDelay(kind, id, 0)
	writeJSON(w, 200, map[string]any{"restored": true})
}
