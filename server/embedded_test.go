package main

import "testing"

func TestEmbeddedLabelsAreReadable(t *testing.T) {
	cases := []struct {
		sub  embeddedSub
		want string
	}{
		{embeddedSub{Language: "eng"}, "English - in video"},
		{embeddedSub{Language: "ara"}, "Arabic - in video"},
		{embeddedSub{Title: "GalaxyTV"}, "GalaxyTV - in video"},
		{embeddedSub{Language: "eng", Forced: true}, "English (forced) - in video"},
		{embeddedSub{Language: ""}, "Unknown - in video"},
	}
	for _, c := range cases {
		if got := c.sub.Label(); got != c.want {
			t.Errorf("Label() = %q, want %q", got, c.want)
		}
	}
}

func TestOnlyTextSubtitlesAreOffered(t *testing.T) {
	// Bitmap formats are pictures of text; offering them would mean handing
	// the player something it cannot render.
	for _, codec := range []string{"subrip", "ass", "ssa", "mov_text", "webvtt"} {
		if !textSubCodecs[codec] {
			t.Errorf("%s should be offered", codec)
		}
	}
	for _, codec := range []string{"hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"} {
		if textSubCodecs[codec] {
			t.Errorf("%s is a bitmap format and should be skipped", codec)
		}
	}
}

func TestShortLangCodeMatchesScannerNaming(t *testing.T) {
	// The scanner writes "Movie.en.srt"; a replacement for an embedded track
	// has to land on the same name or it will not be found again.
	cases := map[string]string{
		"eng": "en", "en": "en", "ara": "ar", "ar": "ar",
		"fre": "fr", "deu": "de", "": "en", "swe": "sw",
	}
	for in, want := range cases {
		if got := shortLangCode(in); got != want {
			t.Errorf("shortLangCode(%q) = %q, want %q", in, got, want)
		}
	}
}
