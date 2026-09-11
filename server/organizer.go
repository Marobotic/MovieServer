package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var subExts = map[string]bool{".srt": true, ".vtt": true, ".ass": true, ".ssa": true, ".sub": true}

// organizeMedia restructures loose movie files and show episodes into
// per-movie folders (Movies/<Title> (Year)/) and per-season folders
// (Shows/<Show>/Season NN/) so artwork and subtitles can live alongside.
// Files that are still being copied (size keeps changing) are skipped.
func organizeMedia(mediaDir string) error {
	movieDir := filepath.Join(mediaDir, "Movies")
	showDir := filepath.Join(mediaDir, "Shows")
	if _, err := os.Stat(movieDir); err != nil {
		log.Printf("organize: Movies/ folder not found, skipping")
	} else if err := organizeMovies(movieDir); err != nil {
		return err
	}
	if _, err := os.Stat(showDir); err != nil {
		log.Printf("organize: Shows/ folder not found, skipping")
	} else if err := organizeShows(showDir); err != nil {
		return err
	}
	return nil
}

func organizeMovies(movieDir string) error {
	entries, err := os.ReadDir(movieDir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		renameFolder(movieDir, e.Name())
	}
	entries, err = os.ReadDir(movieDir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if !isVideo(e.Name()) {
			continue
		}
		if err := moveMovieIntoFolder(movieDir, e.Name()); err != nil {
			log.Printf("organize movie %q: %v", e.Name(), err)
		}
	}
	return nil
}

// moveMovieIntoFolder moves a loose movie file (and its sibling subtitles)
// into Movies/<Clean Title> (Year)/.
func moveMovieIntoFolder(movieDir, fileName string) error {
	if !fileStable(filepath.Join(movieDir, fileName)) {
		log.Printf("organize: skipping %q (still being copied)", fileName)
		return nil
	}
	stem := strings.TrimSuffix(fileName, filepath.Ext(fileName))
	title := cleanTitle(stripYearMark(stem))
	if title == "" {
		title = stem
	}
	dirName := title
	if y := extractYear(stem); y > 0 {
		dirName = fmt.Sprintf("%s (%d)", title, y)
	}
	destDir := filepath.Join(movieDir, dirName)
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return err
	}
	if err := moveInto(destDir, filepath.Join(movieDir, fileName)); err != nil {
		return err
	}
	// move sibling subtitle files (e.g. "X.en.srt") along with the video
	entries, _ := os.ReadDir(movieDir)
	for _, e := range entries {
		if e.IsDir() || !subExts[strings.ToLower(filepath.Ext(e.Name()))] {
			continue
		}
		if strings.HasPrefix(e.Name(), stem+".") || strings.HasPrefix(e.Name(), stem+"-") || strings.HasPrefix(e.Name(), stem+"_") {
			if fileStable(filepath.Join(movieDir, e.Name())) {
				moveInto(destDir, filepath.Join(movieDir, e.Name()))
			}
		}
	}
	log.Printf("organize movie -> %s", dirName)
	return nil
}

func organizeShows(showDir string) error {
	shows, err := os.ReadDir(showDir)
	if err != nil {
		return err
	}
	for _, s := range shows {
		if !s.IsDir() {
			continue
		}
		name := s.Name()
		if renamed := renameFolder(showDir, name); renamed != "" {
			name = renamed
		}
		if err := organizeOneShow(filepath.Join(showDir, name), name); err != nil {
			log.Printf("organize show %q: %v", name, err)
		}
	}
	return nil
}

// renameFolder renames a media folder to its clean title ("<Title> (Year)")
// when the current name carries release noise. Returns the new name, or "".
func renameFolder(parent, name string) string {
	if strings.HasPrefix(name, ".") {
		return ""
	}
	title := cleanTitle(stripYearMark(name))
	year := extractYear(name)
	want := title
	if year > 0 {
		want = fmt.Sprintf("%s (%d)", title, year)
	}
	if want == "" || want == name {
		return ""
	}
	old := filepath.Join(parent, name)
	neu := filepath.Join(parent, want)
	if fileExists(neu) {
		return ""
	}
	if err := os.Rename(old, neu); err != nil {
		log.Printf("organize: rename %q -> %q: %v", name, want, err)
		return ""
	}
	log.Printf("organize folder -> %s", want)
	return want
}

// organizeOneShow moves loose episode files under a show folder into
// Shows/<Show>/Season NN/.
func organizeOneShow(showDir, showTitle string) error {
	entries, err := os.ReadDir(showDir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		full := filepath.Join(showDir, e.Name())
		if e.IsDir() {
			continue
		}
		if !isVideo(e.Name()) {
			continue
		}
		if !fileStable(full) {
			log.Printf("organize: skipping %q (still being copied)", e.Name())
			continue
		}
		sNum, _, _ := parseEpisodeName(showTitle, e.Name())
		seasonDir := filepath.Join(showDir, fmt.Sprintf("Season %02d", sNum))
		if err := os.MkdirAll(seasonDir, 0o755); err != nil {
			return err
		}
		if err := moveInto(seasonDir, full); err != nil {
			return err
		}
		// sibling subtitles
		stem := strings.TrimSuffix(e.Name(), filepath.Ext(e.Name()))
		for _, x := range entries {
			if x.IsDir() || !subExts[strings.ToLower(filepath.Ext(x.Name()))] {
				continue
			}
			if strings.HasPrefix(x.Name(), stem+".") && fileStable(filepath.Join(showDir, x.Name())) {
				moveInto(seasonDir, filepath.Join(showDir, x.Name()))
			}
		}
		log.Printf("organize episode -> %s/Season %02d/%s", showTitle, sNum, e.Name())
	}
	return nil
}

var sizeCheckSleep = 700 * time.Millisecond

// fileStable reports true if the file size does not change across a short
// pause, i.e. the copy appears to have finished.
func fileStable(p string) bool {
	fi1, err := os.Stat(p)
	if err != nil {
		return false
	}
	time.Sleep(sizeCheckSleep)
	fi2, err := os.Stat(p)
	if err != nil {
		return false
	}
	return fi1.Size() == fi2.Size()
}

func moveInto(destDir, src string) error {
	dest := filepath.Join(destDir, filepath.Base(src))
	if fileExists(dest) {
		dest = dedupePath(dest)
	}
	if err := os.Rename(src, dest); err != nil {
		return err
	}
	return nil
}

func dedupePath(p string) string {
	dir := filepath.Dir(p)
	base := filepath.Base(p)
	ext := filepath.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	n := 2
	for fileExists(filepath.Join(dir, fmt.Sprintf("%s - %d%s", stem, n, ext))) {
		n++
	}
	return filepath.Join(dir, fmt.Sprintf("%s - %d%s", stem, n, ext))
}
