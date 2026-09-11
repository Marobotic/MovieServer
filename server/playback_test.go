package main

import "testing"

func TestDecidePlayback(t *testing.T) {
	cases := []struct {
		name     string
		client   string
		c        mediaCheck
		decision string
		variant  string
		nativeOK bool
	}{
		{"web web_direct plays original", clientWeb, mediaCheck{State: classWebDirect}, "play", "original", true},
		{"web mp4 web_ready plays web copy", clientWeb, mediaCheck{State: classWebReady}, "play", "web", true},
		{"web quick_fix blocked with cpu estimate", clientWeb, mediaCheck{State: classQuickFix, DurationSec: 7753}, "needs_quick_fix", "web", true},
		{"web needs_encode blocked with gpu estimate", clientWeb, mediaCheck{State: classNeedsEncode, DurationSec: 7753}, "needs_encode", "web", true},
		{"web damaged", clientWeb, mediaCheck{State: classDamaged, Reason: "header is damaged"}, "damaged", "original", false},
		{"web still copying", clientWeb, mediaCheck{State: classStillCopying}, "still_copying", "original", false},
		{"native plays hevc original", clientNative, mediaCheck{State: classNeedsEncode}, "play", "original", true},
		{"native damaged blocked", clientNative, mediaCheck{State: classDamaged}, "damaged", "original", false},
	}
	for _, tc := range cases {
		d := decidePlayback(tc.client, tc.c)
		if d.Decision != tc.decision {
			t.Errorf("%s: decision got %s want %s", tc.name, d.Decision, tc.decision)
		}
		if d.Variant != tc.variant {
			t.Errorf("%s: variant got %s want %s", tc.name, d.Variant, tc.variant)
		}
		if d.NativeOK != tc.nativeOK {
			t.Errorf("%s: native_ok got %v want %v", tc.name, d.NativeOK, tc.nativeOK)
		}
		if d.Decision == "needs_quick_fix" && (d.Estimate == nil || d.Estimate.Worker != "cpu" || d.Estimate.Minutes < 1) {
			t.Errorf("%s: bad quick fix estimate %+v", tc.name, d.Estimate)
		}
		if d.Decision == "needs_encode" && (d.Estimate == nil || d.Estimate.Worker != "gpu" || d.Estimate.SizeGB < 1) {
			t.Errorf("%s: bad encode estimate %+v", tc.name, d.Estimate)
		}
	}
}

func TestEstimateFor(t *testing.T) {
	e := estimateFor(mediaCheck{DurationSec: 7753}, "needs_quick_fix")
	if e.Worker != "cpu" || e.Minutes < 4 || e.Minutes > 6 {
		t.Errorf("quick fix estimate unexpected: %+v", e)
	}
	e = estimateFor(mediaCheck{DurationSec: 7753}, "needs_encode")
	if e.Worker != "gpu" || e.SizeGB < 3 || e.SizeGB > 6 {
		t.Errorf("encode estimate unexpected: %+v", e)
	}
}
