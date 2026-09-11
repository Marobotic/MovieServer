package main

import (
	"fmt"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// guessContentType returns a mime type for a video file.
func guessContentType(path string) string {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".mkv":
		return "video/x-matroska"
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".webm":
		return "video/webm"
	case ".mov":
		return "video/quicktime"
	case ".avi":
		return "video/x-msvideo"
	case ".ts":
		return "video/mp2t"
	case ".flv":
		return "video/x-flv"
	case ".wmv":
		return "video/x-ms-wmv"
	case ".mpg", ".mpeg":
		return "video/mpeg"
	}
	if t := mime.TypeByExtension(ext); t != "" {
		return t
	}
	return "application/octet-stream"
}

// handleMovieStream serves a movie file with HTTP Range support.
func (s *Server) handleMovieStream(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	m, err := s.getMovie(id)
	if err != nil {
		writeError(w, 404, "movie not found")
		return
	}
	full, err := resolveRel(s.conf.MediaDir, m.FilePath)
	if err != nil {
		writeError(w, 404, "file missing")
		return
	}
	s.serveVideoFile(w, r, full)
}

// handleEpisodeStream serves an episode file with HTTP Range support.
func (s *Server) handleEpisodeStream(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, 400, "bad id")
		return
	}
	e, err := s.getEpisode(id)
	if err != nil {
		writeError(w, 404, "episode not found")
		return
	}
	full, err := resolveRel(s.conf.MediaDir, e.FilePath)
	if err != nil {
		writeError(w, 404, "file missing")
		return
	}
	s.serveVideoFile(w, r, full)
}

// serveVideoFile hands the file to ServeContent, which handles Range + seeking.
func (s *Server) serveVideoFile(w http.ResponseWriter, r *http.Request, full string) {
	f, err := os.Open(full)
	if err != nil {
		if os.IsNotExist(err) {
			writeError(w, 404, "file missing")
			return
		}
		writeError(w, 500, "open failed")
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		writeError(w, 500, "stat failed")
		return
	}
	if r.Method == "HEAD" {
		w.Header().Set("Content-Type", guessContentType(full))
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Length", strconv.FormatInt(fi.Size(), 10))
		w.WriteHeader(http.StatusOK)
		return
	}
	w.Header().Set("Content-Type", guessContentType(full))
	w.Header().Set("Accept-Ranges", "bytes")
	http.ServeContent(w, r, filepath.Base(full), fi.ModTime(), f)
}

// nopWriter is a tiny helper to check handler wiring at startup.
func streamDesc(kind string, id int64) string {
	return fmt.Sprintf("%s/%d (Range-enabled)", kind, id)
}
