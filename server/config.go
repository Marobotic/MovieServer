package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ServerConfig holds all runtime configuration.
type ServerConfig struct {
	Port         int    `json:"port"`
	MediaDir     string `json:"media_dir"`
	DataDir      string `json:"data_dir"`
	JWTSecret    string `json:"jwt_secret"`
	TMDbAPIKey   string `json:"tmdb_api_key,omitempty"`
	TMDbReadToken string `json:"tmdb_read_token,omitempty"`
	TMDbLang     string `json:"tmdb_language,omitempty"`
	OSTUser      string `json:"opensubtitles_user,omitempty"`
	OSTPass      string `json:"opensubtitles_password,omitempty"`
	OSTApiKey    string `json:"opensubtitles_api_key,omitempty"`
	WebFrontend  string `json:"web_frontend,omitempty"`
}

// defaultConfig returns a usable config with defaults applied.
func defaultConfig() *ServerConfig {
	home, _ := os.UserHomeDir()
	return &ServerConfig{
		Port:        8080,
		MediaDir:    filepath.Join(home, "Documents", "MovieServer"),
		DataDir:     "data",
		JWTSecret:   randomHex(32),
		TMDbAPIKey:  "",
		TMDbLang:    "en",
		WebFrontend: filepath.Join("..", "app_flutter", "build", "web"),
	}
}

// loadConfig loads config.json next to the binary or in the working dir.
// It creates a default one if missing and ensures the media dirs exist.
func loadConfig(path string) (*ServerConfig, error) {
	var conf *ServerConfig
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			conf = defaultConfig()
			if err := saveConfig(path, conf); err != nil {
				return nil, fmt.Errorf("create default config: %w", err)
			}
		} else {
			return nil, err
		}
	} else {
		conf = defaultConfig()
		if err := json.Unmarshal(data, conf); err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
		if conf.JWTSecret == "" {
			conf.JWTSecret = randomHex(32)
		}
	}

	conf.MediaDir = expandHome(conf.MediaDir)
	movieDir := filepath.Join(conf.MediaDir, "Movies")
	showDir := filepath.Join(conf.MediaDir, "Shows")
	for _, d := range []string{movieDir, showDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, fmt.Errorf("create media dir %s: %w", d, err)
		}
	}
	return conf, nil
}

func saveConfig(path string, conf *ServerConfig) error {
	data, err := json.MarshalIndent(conf, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		p = filepath.Join(home, strings.TrimPrefix(p, "~/"))
	}
	return p
}