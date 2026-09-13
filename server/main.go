package main

import (
	"database/sql"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Server holds the shared dependencies.
type Server struct {
	conf    *ServerConfig
	db      *sql.DB
	dataDir string
	hc      *http.Client
	version string
	webDir  string
}

func main() {
	configPath := flag.String("config", "config.json", "path to config.json")
	organize := flag.Bool("organize", false, "reorganize media into folder-per-movie / season-per-show layout, then exit")
	flag.Parse()

	// Mirror every log line into the in-memory ring so the admin panel can
	// surface recent server activity.
	log.SetOutput(io.MultiWriter(os.Stderr, serverLogs))

	if *organize {
		conf, err := loadConfig(*configPath)
		if err != nil {
			log.Fatal(err)
		}
		if err := organizeMedia(conf.MediaDir); err != nil {
			log.Fatalf("organize: %v", err)
		}
		log.Printf("organize: done")
		return
	}

	server, err := newServer(configPath)
	if err != nil {
		log.Fatalf("startup: %v", err)
	}
	log.Printf("MovieServer %s listening on http://0.0.0.0:%d", server.version, server.conf.Port)
	log.Printf("Media: %s", server.conf.MediaDir)
	if server.conf.TMDbAPIKey == "" {
		log.Printf("TMDB API key not set - metadata/trailers will be skipped. Run with -config or edit config.json later.")
	}
	log.Printf("Web frontend: %s", server.webDir)
	if err := http.ListenAndServe(fmt.Sprintf(":%d", server.conf.Port), server.routes()); err != nil {
		log.Fatal(err)
	}
}

func newServer(configPath *string) (*Server, error) {
	conf, err := loadConfig(*configPath)
	if err != nil {
		return nil, err
	}
	if !filepath.IsAbs(conf.DataDir) {
		cwd, _ := os.Getwd()
		conf.DataDir = filepath.Join(cwd, conf.DataDir)
	}
	os.MkdirAll(conf.DataDir, 0o755)
	if !filepath.IsAbs(conf.WebFrontend) {
		if cwd, err := os.Getwd(); err == nil {
			conf.WebFrontend = filepath.Clean(filepath.Join(cwd, conf.WebFrontend))
		}
	}

	// Scan once at startup so the catalog is ready immediately.
	db, err := openDB(conf.DataDir)
	if err != nil {
		return nil, err
	}
	if err := migrate(db); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}

	s := &Server{
		conf:    conf,
		db:      db,
		dataDir: conf.DataDir,
		hc:      &http.Client{Timeout: 30 * time.Second},
		version: "0.1.0",
		webDir:  conf.WebFrontend,
	}

	s.loadJobsOnStart()

	if _, err := s.scanLibrary(); err != nil {
		log.Printf("initial scan warning: %v", err)
	}

	printSetupHint(s)
	return s, nil
}

func printSetupHint(s *Server) {
	if s.userCount() == 0 {
		log.Println("No users yet - POST /api/auth/setup with {username, password} to create the admin account.")
	}
	ip := localIP()
	if ip != "" {
		log.Printf("Share with family: http://%s:%d", ip, s.conf.Port)
	}
}

func localIP() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok {
				if ip4 := ipnet.IP.To4(); ip4 != nil {
					return ip4.String()
				}
			}
		}
	}
	return ""
}

// routes wires up all endpoints.
func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()

	// public
	mux.HandleFunc("GET /api/capabilities", s.handleCapabilities)
	mux.HandleFunc("GET /api/profiles", s.handleProfiles)
	mux.HandleFunc("POST /api/auth/setup", s.handleSetup)
	mux.HandleFunc("POST /api/auth/login", s.handleLogin)

	// authenticated
	mux.HandleFunc("GET /api/me", s.authMiddleware(s.handleMe))
	mux.HandleFunc("GET /api/movies", s.authMiddleware(s.handleMovies))
	mux.HandleFunc("GET /api/shows", s.authMiddleware(s.handleShows))
	mux.HandleFunc("GET /api/movies/{id}", s.authMiddleware(s.handleMovieDetail))
	mux.HandleFunc("GET /api/shows/{id}", s.authMiddleware(s.handleShowDetail))
	mux.HandleFunc("GET /api/library/continue_watching", s.authMiddleware(s.handleContinueWatching))
	mux.HandleFunc("POST /api/progress", s.authMiddleware(s.handleProgress))
	mux.HandleFunc("DELETE /api/progress", s.authMiddleware(s.handleClearProgress))
	mux.HandleFunc("GET /api/search", s.authMiddleware(s.handleSearch))
	mux.HandleFunc("GET /api/asset/{name}", s.handleAsset)

	// streaming (Range-enabled, works in browsers/players)
	mux.HandleFunc("GET /api/movies/{id}/stream", s.authMiddleware(s.handleMovieStream))
	mux.HandleFunc("HEAD /api/movies/{id}/stream", s.authMiddleware(s.handleMovieStream))
	mux.HandleFunc("GET /api/episodes/{id}/stream", s.authMiddleware(s.handleEpisodeStream))
	mux.HandleFunc("HEAD /api/episodes/{id}/stream", s.authMiddleware(s.handleEpisodeStream))
	mux.HandleFunc("GET /api/movies/{id}/playback", s.authMiddleware(s.handlePlayback))
	mux.HandleFunc("GET /api/episodes/{id}/playback", s.authMiddleware(s.handlePlayback))
	mux.HandleFunc("GET /api/jobs", s.authMiddleware(s.handleListJobs))
	mux.HandleFunc("GET /api/jobs/events", s.authMiddleware(s.handleJobEvents))
	mux.HandleFunc("POST /api/jobs", s.requireAdmin(s.handleCreateJob))
	mux.HandleFunc("POST /api/jobs/{id}/pause", s.requireAdmin(s.handleJobAction))
	mux.HandleFunc("POST /api/jobs/{id}/resume", s.requireAdmin(s.handleJobAction))
	mux.HandleFunc("POST /api/jobs/{id}/cancel", s.requireAdmin(s.handleJobAction))
	mux.HandleFunc("DELETE /api/webcopies/movies/{id}", s.requireAdmin(s.handleDeleteWebcopy))
	mux.HandleFunc("DELETE /api/webcopies/episodes/{id}", s.requireAdmin(s.handleDeleteWebcopy))

	// HLS transcoding (browsers cannot play MKV/HEVC directly)
	mux.HandleFunc("GET /api/movies/{id}/hls/master.m3u8", s.authMiddleware(s.handleHLSMaster))
	mux.HandleFunc("GET /api/episodes/{id}/hls/master.m3u8", s.authMiddleware(s.handleHLSMaster))
	mux.HandleFunc("GET /api/hls/{job}/{file}", s.authMiddleware(s.handleHLSSegment))

	// media extras: local artwork, subtitle tracks, audio tracks
	mux.HandleFunc("GET /api/movies/{id}/art/{name}", s.handleArt)
	mux.HandleFunc("GET /api/shows/{id}/art/{name}", s.handleArt)
	mux.HandleFunc("GET /api/episodes/{id}/art/{name}", s.handleArt)
	mux.HandleFunc("GET /api/movies/{id}/tracks", s.authMiddleware(s.handleTracks))
	mux.HandleFunc("GET /api/episodes/{id}/tracks", s.authMiddleware(s.handleTracks))
	mux.HandleFunc("GET /api/movies/{id}/subtitles/{index}", s.authMiddleware(s.handleSubtitle))
	mux.HandleFunc("GET /api/episodes/{id}/subtitles/{index}", s.authMiddleware(s.handleSubtitle))
	mux.HandleFunc("GET /api/movies/{id}/detect", s.authMiddleware(s.handleDetect))
	mux.HandleFunc("GET /api/episodes/{id}/detect", s.authMiddleware(s.handleDetect))
	mux.HandleFunc("GET /api/movies/{id}/trickplay", s.authMiddleware(s.handleTrickplayManifest))
	mux.HandleFunc("GET /api/episodes/{id}/trickplay", s.authMiddleware(s.handleTrickplayManifest))
	mux.HandleFunc("GET /api/movies/{id}/trickplay/{file}", s.handleTrickplayImage)
	mux.HandleFunc("GET /api/episodes/{id}/trickplay/{file}", s.handleTrickplayImage)

	// requests (any authenticated user)
	mux.HandleFunc("POST /api/requests", s.authMiddleware(s.handleCreateRequest))
	mux.HandleFunc("GET /api/requests", s.authMiddleware(s.handleListRequests))
	mux.HandleFunc("PATCH /api/requests/{id}", s.requireAdmin(s.handleUpdateRequest))
	mux.HandleFunc("DELETE /api/requests/{id}", s.authMiddleware(s.handleDeleteRequest))
	mux.HandleFunc("GET /api/catalog", s.authMiddleware(s.handleCatalog))
	mux.HandleFunc("GET /api/catalog/{type}/{id}", s.authMiddleware(s.handleCatalogDetail))

	// user management (admin)
	mux.HandleFunc("GET /api/users", s.requireAdmin(s.handleListUsers))
	mux.HandleFunc("POST /api/users", s.requireAdmin(s.handleCreateUser))
	mux.HandleFunc("PUT /api/users/{id}", s.requireAdmin(s.handleUpdateUser))
	mux.HandleFunc("DELETE /api/users/{id}", s.requireAdmin(s.handleDeleteUser))

	// subtitle delay per media item (admin-writable, everyone reads)
	mux.HandleFunc("GET /api/movies/{id}/subtitle-delay", s.authMiddleware(s.handleGetSubtitleDelay))
	mux.HandleFunc("GET /api/episodes/{id}/subtitle-delay", s.authMiddleware(s.handleGetSubtitleDelay))
	mux.HandleFunc("PUT /api/admin/movies/{id}/subtitle-delay", s.requireAdmin(s.handleUpdateSubtitleDelay))
	mux.HandleFunc("PUT /api/admin/episodes/{id}/subtitle-delay", s.requireAdmin(s.handleUpdateSubtitleDelay))

	// admin operations
	mux.HandleFunc("POST /api/admin/scan", s.requireAdmin(s.handleScan))
	mux.HandleFunc("POST /api/admin/subs", s.requireAdmin(s.handleSubDownload))
	mux.HandleFunc("POST /api/admin/upload", s.requireAdmin(s.handleUpload))
	mux.HandleFunc("GET /api/admin/tmdb/search", s.authMiddleware(s.handleTMDBSearch))
	mux.HandleFunc("GET /api/admin/problems", s.requireAdmin(s.handleProblems))
	mux.HandleFunc("GET /api/admin/logs", s.requireAdmin(s.handleAdminLogs))
	mux.HandleFunc("GET /api/admin/library_health", s.requireAdmin(s.handleLibraryHealth))

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok", "version": s.version})
	})

	return s.withCORS(withStatic(s.webDir, mux))
}

// withCORS allows the Flutter web build (served from another origin during dev) to call the API.
func (s *Server) withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// mediaKindFor maps the registered route pattern to a media kind.
func mediaKindFor(r *http.Request) string {
	switch {
	case strings.Contains(r.Pattern, "/movies/"):
		return "movie"
	case strings.Contains(r.Pattern, "/shows/"):
		return "show"
	case strings.Contains(r.Pattern, "/episodes/"):
		return "episode"
	}
	return ""
}

// withStatic serves the Flutter web build when it exists; otherwise a splash page.
func withStatic(webDir string, next http.Handler) http.Handler {
	index := filepath.Join(webDir, "index.html")
	hasWeb := fileExists(index)

	if !hasWeb {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if strings.HasPrefix(r.URL.Path, "/api/") || r.URL.Path == "/health" {
				next.ServeHTTP(w, r)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(w, splashHTML)
		})
	}

	fileServer := http.FileServer(http.Dir(webDir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") || r.URL.Path == "/health" {
			next.ServeHTTP(w, r)
			return
		}
		if r.URL.Path == "/" || strings.HasPrefix(r.URL.Path, "/#/") {
			http.ServeFile(w, r, index)
			return
		}
		// For client-side routes, serve index.html unless a real asset matches.
		if f, err := os.Stat(filepath.Join(webDir, strings.TrimPrefix(r.URL.Path, "/"))); err == nil && !f.IsDir() {
			fileServer.ServeHTTP(w, r)
			return
		}
		http.ServeFile(w, r, index)
	})
}

const splashHTML = `<!doctype html>
<html>
<head><meta charset="utf-8"><title>MovieServer</title>
<style>
 body{background:#141414;color:#eee;font-family:system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
 .box{text-align:center}
 h1{color:#E50914;margin-bottom:.2em}
 p{color:#999}
</style></head>
<body><div class="box">
<h1>MovieServer</h1>
<p>Running. No app built yet.</p>
<p><a href="/health" style="color:#E50914">health check</a></p>
</div></body></html>`
