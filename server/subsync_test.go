package main

import (
	"math"
	"os"
	"path/filepath"
	"testing"
)

// buildSpans lays out dialogue-like spans with irregular gaps. Evenly spaced
// spans would be genuinely ambiguous - every shift of one period scores the
// same - so the fixture has to be aperiodic, like real speech.
func buildSpans(count int, period, on, shift float64) []timeSpan {
	out := make([]timeSpan, 0, count)
	t := shift
	seed := uint32(12345)
	for i := 0; i < count; i++ {
		seed = seed*1664525 + 1013904223
		jitter := float64(seed%1000) / 1000 // 0..1
		gap := period * (0.4 + 1.2*jitter)
		length := on * (0.5 + jitter)
		out = append(out, timeSpan{t, t + length})
		t += length + gap
	}
	return out
}

func TestBestOffsetRecoversAKnownShift(t *testing.T) {
	const bins = 12000 // 20 minutes at 100ms
	mask := make([]float32, bins)
	for i := range mask {
		mask[i] = 1
	}

	for _, shiftSec := range []float64{0, 2.5, -4.0, 12.0, -30.0} {
		speech := binTimeline(buildSpans(300, 4.0, 1.6, 0), bins)
		// Subtitles sit `shiftSec` EARLIER than the speech, so playing them
		// back needs a delay of +shiftSec.
		subs := binTimeline(buildSpans(300, 4.0, 1.6, -shiftSec), bins)

		got, conf := bestOffset(speech, subs, mask)
		want := int(math.Round(shiftSec*1000/syncCoarseBinMS)) * syncCoarseBinMS
		if got != want {
			t.Errorf("shift %.1fs: got %+d ms, want %+d ms (confidence %.2f)",
				shiftSec, got, want, conf)
		}
		if conf < 3 {
			t.Errorf("shift %.1fs: confidence %.2f too low for a clean signal",
				shiftSec, conf)
		}
	}
}

func TestBestOffsetIgnoresUnsampledBins(t *testing.T) {
	const bins = 12000
	mask := make([]float32, bins)
	// Only the first five minutes were decoded.
	for i := 0; i < 3000; i++ {
		mask[i] = 1
	}
	speech := binTimeline(buildSpans(75, 4.0, 1.6, 0), bins)
	subs := binTimeline(buildSpans(300, 4.0, 1.6, -3.0), bins)

	got, _ := bestOffset(speech, subs, mask)
	if got != 3000 {
		t.Errorf("got %+d ms, want +3000 ms", got)
	}
}

func TestParseCueSpansReadsSRTAndVTT(t *testing.T) {
	dir := t.TempDir()

	srt := filepath.Join(dir, "a.srt")
	os.WriteFile(srt, []byte("1\n00:00:01,500 --> 00:00:03,250\nHello\n\n"+
		"2\n00:01:10,000 --> 00:01:12,000\nWorld\n\n"), 0o644)
	spans, err := parseCueSpans(srt)
	if err != nil {
		t.Fatal(err)
	}
	if len(spans) != 2 {
		t.Fatalf("got %d spans, want 2", len(spans))
	}
	if math.Abs(spans[0].start-1.5) > 1e-6 || math.Abs(spans[0].end-3.25) > 1e-6 {
		t.Errorf("first span = %v", spans[0])
	}
	if math.Abs(spans[1].start-70) > 1e-6 {
		t.Errorf("second span start = %v", spans[1].start)
	}

	vtt := filepath.Join(dir, "a.vtt")
	os.WriteFile(vtt, []byte("WEBVTT\n\n00:00:02.000 --> 00:00:04.000\nHi\n\n"), 0o644)
	spans, err = parseCueSpans(vtt)
	if err != nil {
		t.Fatal(err)
	}
	if len(spans) != 1 || math.Abs(spans[0].start-2) > 1e-6 {
		t.Errorf("vtt spans = %v", spans)
	}
}

func TestSnapScalePullsOntoFrameRateRatios(t *testing.T) {
	cases := []struct {
		in, want float64
		note     string
	}{
		{1.0, 1.0, "already exact"},
		{1.00002, 1.0, "noise around 1"},
		{1.0427, 25.0 / 23.976, "25fps subs on a 23.976fps cut"},
		{0.9591, 23.976 / 25.0, "the reverse"},
		{1.2, 1.2, "nowhere near a real ratio, left alone"},
	}
	for _, c := range cases {
		got := snapScale(c.in)
		if math.Abs(got-c.want) > 1e-6 {
			t.Errorf("%s: snapScale(%v) = %v, want %v", c.note, c.in, got, c.want)
		}
	}
}

func TestRewriteSubtitleAppliesScaleAndOffset(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.srt")
	body := "1\n00:00:10,000 --> 00:00:12,000\nfirst\n\n" +
		"2\n01:00:00,000 --> 01:00:02,000\nlast\n\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	// A subtitle running 0.1% slow, sitting 2s early.
	if err := rewriteSubtitle(p, 1.001, 2.0); err != nil {
		t.Fatal(err)
	}
	spans, err := parseCueSpans(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(spans) != 2 {
		t.Fatalf("got %d spans, want 2", len(spans))
	}
	if math.Abs(spans[0].start-(10*1.001+2)) > 0.002 {
		t.Errorf("first start = %v", spans[0].start)
	}
	if math.Abs(spans[1].start-(3600*1.001+2)) > 0.002 {
		t.Errorf("last start = %v", spans[1].start)
	}

	// The untouched original must still be recoverable.
	orig, err := parseCueSpans(p + ".orig")
	if err != nil {
		t.Fatal(err)
	}
	if math.Abs(orig[0].start-10) > 1e-6 {
		t.Errorf("backup was modified: %v", orig[0])
	}

	// A second run must not overwrite the backup with already-shifted times.
	if err := rewriteSubtitle(p, 1.0, 5.0); err != nil {
		t.Fatal(err)
	}
	orig, _ = parseCueSpans(p + ".orig")
	if math.Abs(orig[0].start-10) > 1e-6 {
		t.Errorf("backup clobbered on the second run: %v", orig[0])
	}
}

func TestParseCueSpansDropsImplausibleCues(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.srt")
	// A 90s cue is a subtitle-file artefact, not dialogue; end<=start is junk.
	os.WriteFile(p, []byte("1\n00:00:01,000 --> 00:01:40,000\nlong\n\n"+
		"2\n00:00:20,000 --> 00:00:19,000\nbad\n\n"+
		"3\n00:00:30,000 --> 00:00:32,000\ngood\n\n"), 0o644)
	spans, err := parseCueSpans(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(spans) != 1 || math.Abs(spans[0].start-30) > 1e-6 {
		t.Errorf("spans = %v, want only the 30s cue", spans)
	}
}

func TestFitsRuntimeRejectsImpossibleTimings(t *testing.T) {
	const runtime = 1354.9 // President Curtis S01E02

	cases := []struct {
		name string
		last float64
		want bool
	}{
		{"ends just before the credits", 1350.4, true},
		{"ends within the slack", runtime + 3, true},
		// A stretch applied to an already-correct subtitle pushes the closing
		// line past the end of the video, which cannot be right.
		{"pushed past the end", 1379.7, false},
		{"stops less than halfway in", 600, false},
	}
	for _, c := range cases {
		spans := []timeSpan{{10, 12}, {c.last - 2, c.last}}
		got, reason := fitsRuntime(spans, runtime)
		if got != c.want {
			t.Errorf("%s: fitsRuntime = %v (%s), want %v", c.name, got, reason, c.want)
		}
	}

	if ok, _ := fitsRuntime(nil, runtime); ok {
		t.Error("an empty subtitle should never be accepted")
	}
	// With no known runtime the check must not block anything.
	if ok, _ := fitsRuntime([]timeSpan{{10, 12}}, 0); !ok {
		t.Error("unknown runtime should not reject")
	}
}

func TestVerdictOnlyVetoesWhenSure(t *testing.T) {
	const runtime = 2800.0
	good := []timeSpan{{10, 12}, {2700, 2702}}

	// Confident and aligned: accept.
	if ok, _, _ := verdict(good, runtime, 0.05, 6.0); !ok {
		t.Error("a sharp, aligned match should be accepted")
	}
	// Confident and badly out: reject, and say so definitively.
	ok, confident, _ := verdict(good, runtime, 12.0, 6.0)
	if ok || !confident {
		t.Errorf("a confident mismatch should be a definite rejection, got ok=%v confident=%v", ok, confident)
	}
	// No usable opinion from the audio (a wall-to-wall score): defer to the
	// engine rather than overriding a real VAD with a worse one.
	ok, confident, _ = verdict(good, runtime, 40.0, 1.9)
	if !ok || confident {
		t.Errorf("a weak reading must not veto, got ok=%v confident=%v", ok, confident)
	}
	// ...but the runtime check still applies, whatever the audio says.
	past := []timeSpan{{10, 12}, {runtime + 40, runtime + 42}}
	if ok, _, _ := verdict(past, runtime, 0.01, 1.0); ok {
		t.Error("cues past the end of the file must be rejected regardless")
	}
}

func TestCandidateScalePairsByIndex(t *testing.T) {
	original := make([]timeSpan, 0, 400)
	for i := 0; i < 400; i++ {
		t0 := float64(i) * 6.0
		original = append(original, timeSpan{t0, t0 + 2})
	}

	// A plain shift is not a rate change.
	shifted := make([]timeSpan, len(original))
	for i, sp := range original {
		shifted[i] = timeSpan{sp.start + 7.7, sp.end + 7.7}
	}
	if got := candidateScale(original, shifted); math.Abs(got-1) > 1e-6 {
		t.Errorf("plain shift: scale = %v, want 1", got)
	}

	// A 25/23.976 stretch must be seen for what it is. Pairing by proximity
	// misses this entirely once late cues drift minutes away.
	const want = 25.0 / 23.976
	stretched := scaleSpans(original, want)
	if got := candidateScale(original, stretched); math.Abs(got-want) > 1e-4 {
		t.Errorf("stretched: scale = %v, want %v", got, want)
	}
}

func TestRateChangeNeedsSupportFromASibling(t *testing.T) {
	original := make([]timeSpan, 0, 400)
	for i := 0; i < 400; i++ {
		t0 := float64(i) * 6.0
		original = append(original, timeSpan{t0, t0 + 2})
	}
	// Another language for the same cut: same rate, slightly different times.
	sibling := make([]timeSpan, len(original))
	for i, sp := range original {
		sibling[i] = timeSpan{sp.start + 0.4, sp.end + 0.5}
	}
	stretched := scaleSpans(original, 25.0/23.976)
	shifted := make([]timeSpan, len(original))
	for i, sp := range original {
		shifted[i] = timeSpan{sp.start + 7.7, sp.end + 7.7}
	}

	if rateChangeSupported(stretched, original, [][]timeSpan{sibling}) {
		t.Error("a sibling running at the same rate should veto a stretch")
	}
	if !rateChangeSupported(shifted, original, [][]timeSpan{sibling}) {
		t.Error("a plain shift is not a rate change and must not be vetoed")
	}
	// With nothing to compare against, the other checks have to carry it.
	if !rateChangeSupported(stretched, original, nil) {
		t.Error("with no sibling the check must not block on its own")
	}
	// Known limitation, chosen deliberately. If both languages were authored
	// at the wrong frame rate they agree with each other, and the veto blocks
	// a stretch that was in fact needed. That is the safer way round: a wrong
	// stretch drifts further out every minute and ruins the file, whereas a
	// missed one leaves a constant offset the slider can fix.
	bothStretched := scaleSpans(sibling, 25.0/23.976)
	_ = bothStretched
	if rateChangeSupported(stretched, original, [][]timeSpan{sibling}) {
		t.Error("agreement between languages must veto, even at the cost of a missed stretch")
	}
}

func TestEngineModesEscalate(t *testing.T) {
	// The default must be the safest thing: one shift, no rate guessing.
	shift := alassArgs("v.mkv", "in.srt", "out.srt", modeShift)
	if !hasArg(shift, "--no-split") || !hasArg(shift, "--disable-fps-guessing") {
		t.Errorf("modeShift args = %v, want both restrictions", shift)
	}
	rate := alassArgs("v.mkv", "in.srt", "out.srt", modeRate)
	if !hasArg(rate, "--no-split") || hasArg(rate, "--disable-fps-guessing") {
		t.Errorf("modeRate args = %v, want splitting off but rate guessing on", rate)
	}
	split := alassArgs("v.mkv", "in.srt", "out.srt", modeSplit)
	if hasArg(split, "--no-split") || hasArg(split, "--disable-fps-guessing") {
		t.Errorf("modeSplit args = %v, want no restrictions", split)
	}
	// Positional arguments stay last and in order for every mode.
	for _, args := range [][]string{shift, rate, split} {
		tail := args[len(args)-3:]
		if tail[0] != "v.mkv" || tail[1] != "in.srt" || tail[2] != "out.srt" {
			t.Errorf("args = %v, want reference/in/out last", args)
		}
	}
}

func hasArg(xs []string, v string) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}
