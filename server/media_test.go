package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Preserves the real-world leak: one season folder, several episodes, each
// with its own .en.srt plus one season-level English file. Without an owner
// every file leaks onto every episode; with an owner only that episode's
// markers and the season-level fallback survive.
func TestFindSubtitlesIsolatesEpisodes(t *testing.T) {
	dir := t.TempDir()
	files := []string{
		"Show.S01E01.1080p.WEB.mkv",
		"Show.S01E01.1080p.WEB.en.srt",
		"Show.S01E02.1080p.WEB.mkv",
		"Show.S01E02.1080p.WEB.en.srt",
		"Show.S01E03.1080p.WEB.mkv",
		"Show.S01E03.1080p.WEB.en.srt",
		"Show.S01.en.srt",
	}
	for _, f := range files {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("1\n00:00:00,000 --> 00:00:01,000\nx\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	owner := &seriesKey{season: 1, episode: 2}
	subs := findSubtitles(dir, "Show.S01E02.1080p.WEB", owner)

	names := make([]string, 0, len(subs))
	for _, s := range subs {
		names = append(names, filepath.Base(s.Path))
	}
	if len(names) != 2 {
		t.Fatalf("expected 2 subtitles for the episode, got %d: %v", len(names), names)
	}
	wantE02 := false
	wantSeason := false
	for _, n := range names {
		if n == "Show.S01E02.1080p.WEB.en.srt" {
			wantE02 = true
		}
		if n == "Show.S01.en.srt" {
			wantSeason = true
		}
		if n == "Show.S01E01.1080p.WEB.en.srt" || n == "Show.S01E03.1080p.WEB.en.srt" {
			t.Errorf("subtitle from another episode leaked: %s", n)
		}
	}
	if !wantE02 || !wantSeason {
		t.Errorf("missing expected subtitle; got %v", names)
	}
}

func TestSeasonEpFrom(t *testing.T) {
	cases := []struct {
		name string
		s, e int
	}{
		{"Show.S01E02.1080p.WEB.en", 1, 2},
		{"Show.2005.S14E03.mkv", 14, 3},
		{"Show.1x03.bin", 1, 3},
		{"Show.episode 3.en.srt", -1, 3},
		{"Show.S01.en.srt", 1, -1},
		{"Show.en.srt", -1, -1},
	}
	for _, c := range cases {
		s, e := seasonEpFrom(c.name)
		if s != c.s || e != c.e {
			t.Errorf("seasonEpFrom(%q) = (%d,%d), want (%d,%d)", c.name, s, e, c.s, c.e)
		}
	}
}
