package main

import (
	"strings"
	"testing"
)

func TestProgressParser(t *testing.T) {
	j := &prepareJob{durSec: 7200}
	blocks := []string{
		"frame=1200\nfps=75.0\nout_time_us=3600000000\nspeed=27.5x\nprogress=continue\n",
		"frame=2400\nfps=80.0\nout_time_us=7200000000\nspeed=27.5x\nprogress=continue\n",
	}
	first := strings.SplitN(blocks[0], "\n", -1)
	for _, line := range first {
		j.applyProgress(line)
	}
	j.mu.Lock()
	pct, spd := j.Percent, j.Speed
	j.mu.Unlock()
	if pct < 49.9 || pct > 50.1 {
		t.Errorf("percent got %f want ~50", pct)
	}
	if spd != 27.5 {
		t.Errorf("speed got %f want 27.5", spd)
	}
	j.applyProgress("speed=27.5x")
	j.applyProgress("out_time_us=3600000000")
	j.mu.Lock()
	eta := j.ETASec
	j.mu.Unlock()
	if eta < 120 || eta > 140 {
		t.Errorf("eta got %d want ~131 (50%% left / 27.5x)", eta)
	}
	for _, line := range strings.Split(blocks[1], "\n") {
		j.applyProgress(line)
	}
	j.applyProgress("progress=end")
	j.mu.Lock()
	pct = j.Percent
	j.mu.Unlock()
	if pct != 100 {
		t.Errorf("percent after end got %f want 100", pct)
	}
}

func TestProgressParserNoDurationSafe(t *testing.T) {
	j := &prepareJob{durSec: 0}
	j.applyProgress("out_time_us=1000000")
	j.mu.Lock()
	p := j.Percent
	j.mu.Unlock()
	_ = p
}

func TestRunRemaining(t *testing.T) {
	if runRemaining(0, 27, 7200) != 0 {
		t.Error("zero percent must yield zero eta")
	}
	if runRemaining(50, 0, 7200) != 0 {
		t.Error("zero speed must yield zero eta")
	}
	v := runRemaining(50, 27, 7200)
	if v < 131 || v > 134 {
		t.Errorf("eta got %f want ~133", v)
	}
}

func TestVerifyWebcopyDetectsBadOutput(t *testing.T) {
	err := verifyWebcopy("/nonexistent.mp4", 7200, jobTypeEncode)
	if err == nil {
		t.Error("expected error for missing file")
	}
}
