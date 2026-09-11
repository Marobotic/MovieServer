package main

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

// ---- Models ----

type User struct {
	ID          int64     `json:"id"`
	Username    string    `json:"username"`
	Password    string    `json:"-"`
	Role        string    `json:"role"`
	AvatarColor string    `json:"avatar_color"`
	AudioLang   string    `json:"audio_lang,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
}

type Movie struct {
	ID         int64     `json:"id"`
	Title      string    `json:"title"`
	FileTitle  string    `json:"file_title,omitempty"`
	Year       int       `json:"year"`
	FilePath   string    `json:"file_path"`
	SizeBytes  int64     `json:"size_bytes"`
	Overview   string    `json:"overview"`
	Poster     string    `json:"poster"`
	Backdrop   string    `json:"backdrop"`
	TrailerURL string    `json:"trailer_url"`
	Duration   int64     `json:"duration_sec,omitempty"`
	TMDbID     int       `json:"tmdb_id,omitempty"`
	Broken     bool      `json:"broken,omitempty"`
	AddedAt    time.Time `json:"added_at"`
}

type Show struct {
	ID         int64     `json:"id"`
	Title      string    `json:"title"`
	Year       int       `json:"year"`
	Overview   string    `json:"overview"`
	Poster     string    `json:"poster"`
	Backdrop   string    `json:"backdrop"`
	TrailerURL string    `json:"trailer_url"`
	TMDbID     int       `json:"tmdb_id,omitempty"`
	AddedAt    time.Time `json:"added_at"`
}

type Episode struct {
	ID         int64      `json:"id"`
	ShowID     int64      `json:"show_id"`
	Season     int        `json:"season"`
	Episode    int        `json:"episode"`
	Title      string     `json:"title"`
	FileTitle  string     `json:"file_title,omitempty"`
	Overview   string     `json:"overview"`
	Still      string     `json:"still"`
	FilePath   string     `json:"file_path"`
	SizeBytes  int64      `json:"size_bytes"`
	Duration   int64      `json:"duration_sec,omitempty"`
	Broken     bool       `json:"broken,omitempty"`
	ShowTitle  string     `json:"show_title,omitempty"`
	TrailerURL string     `json:"trailer_url,omitempty"`
	WatchedAt  *time.Time `json:"-"`
}

type Progress struct {
	ID        int64     `json:"-"`
	UserID    int64     `json:"user_id"`
	MediaKind string    `json:"media_kind"` // "movie" | "episode"
	MediaID   int64     `json:"media_id"`
	Position  int64     `json:"position"`
	Duration  int64     `json:"duration"`
	Completed bool      `json:"completed"`
	UpdatedAt time.Time `json:"updated_at"`
	Title     string    `json:"title,omitempty"`
	Poster    string    `json:"poster,omitempty"`
	ShowID    int64     `json:"show_id,omitempty"`
	Season    int       `json:"season,omitempty"`
	Episode   int       `json:"episode,omitempty"`
}

type Request struct {
	ID        int64     `json:"id"`
	UserID    int64     `json:"user_id"`
	Username  string    `json:"username,omitempty"`
	Kind      string    `json:"kind"` // movie | show
	Title     string    `json:"title"`
	Year      int       `json:"year"`
	Note      string    `json:"note"`
	Status    string    `json:"status"` // pending | approved | denied
	TMDbID    int       `json:"tmdb_id,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// ---- DB helpers ----

func openDB(dataDir string) (*sql.DB, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	path := filepath.Join(dataDir, "movieserver.db")
	db, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	return db, nil
}

func migrate(db *sql.DB) error {
	schema := `
CREATE TABLE IF NOT EXISTS users (
	id            INTEGER PRIMARY KEY AUTOINCREMENT,
	username      TEXT NOT NULL UNIQUE,
	password_hash TEXT NOT NULL,
	role          TEXT NOT NULL DEFAULT 'viewer',
	avatar_color  TEXT NOT NULL DEFAULT '#E50914',
	created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS movies (
	id           INTEGER PRIMARY KEY AUTOINCREMENT,
	title        TEXT NOT NULL,
	file_title   TEXT NOT NULL DEFAULT '',
	year         INTEGER NOT NULL DEFAULT 0,
	file_path    TEXT NOT NULL UNIQUE,
	size_bytes   INTEGER NOT NULL DEFAULT 0,
	overview     TEXT NOT NULL DEFAULT '',
	poster       TEXT NOT NULL DEFAULT '',
	backdrop     TEXT NOT NULL DEFAULT '',
	trailer_url  TEXT NOT NULL DEFAULT '',
	duration_sec INTEGER NOT NULL DEFAULT 0,
	tmdb_id      INTEGER NOT NULL DEFAULT 0,
	broken       INTEGER NOT NULL DEFAULT 0,
	added_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS shows (
	id           INTEGER PRIMARY KEY AUTOINCREMENT,
	title        TEXT NOT NULL,
	year         INTEGER NOT NULL DEFAULT 0,
	overview     TEXT NOT NULL DEFAULT '',
	poster       TEXT NOT NULL DEFAULT '',
	backdrop     TEXT NOT NULL DEFAULT '',
	trailer_url  TEXT NOT NULL DEFAULT '',
	tmdb_id      INTEGER NOT NULL DEFAULT 0,
	added_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS episodes (
	id          INTEGER PRIMARY KEY AUTOINCREMENT,
	show_id     INTEGER NOT NULL REFERENCES shows(id) ON DELETE CASCADE,
	season      INTEGER NOT NULL DEFAULT 1,
	episode     INTEGER NOT NULL DEFAULT 1,
	title       TEXT NOT NULL DEFAULT '',
	file_title  TEXT NOT NULL DEFAULT '',
	overview    TEXT NOT NULL DEFAULT '',
	still       TEXT NOT NULL DEFAULT '',
	file_path   TEXT NOT NULL UNIQUE,
	size_bytes  INTEGER NOT NULL DEFAULT 0,
	duration_sec INTEGER NOT NULL DEFAULT 0,
	broken      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS progress (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	media_kind TEXT NOT NULL,
	media_id   INTEGER NOT NULL,
	position   INTEGER NOT NULL DEFAULT 0,
	duration   INTEGER NOT NULL DEFAULT 0,
	completed  INTEGER NOT NULL DEFAULT 0,
	updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	UNIQUE(user_id, media_kind, media_id)
);

CREATE TABLE IF NOT EXISTS requests (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	kind       TEXT NOT NULL,
	title      TEXT NOT NULL,
	year       INTEGER NOT NULL DEFAULT 0,
	note       TEXT NOT NULL DEFAULT '',
	status     TEXT NOT NULL DEFAULT 'pending',
	tmdb_id    INTEGER NOT NULL DEFAULT 0,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
`
	_, err := db.Exec(schema)
	if err != nil {
		return err
	}
	return runMigrations(db)
}

// runMigrations applies ordered ALTER TABLE steps to databases that were
// created before a schema change. Each migration is recorded in
// schema_version so it runs exactly once.
func runMigrations(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)`); err != nil {
		return err
	}
	var ver int
	_ = db.QueryRow(`SELECT COALESCE(MAX(version),0) FROM schema_version`).Scan(&ver)
	steps := []string{
		`ALTER TABLE movies ADD COLUMN file_title TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE episodes ADD COLUMN file_title TEXT NOT NULL DEFAULT ''`,
		`CREATE INDEX IF NOT EXISTS idx_progress_user ON progress(user_id, updated_at)`,
		`CREATE INDEX IF NOT EXISTS idx_episodes_show ON episodes(show_id, season, episode)`,
		`ALTER TABLE users ADD COLUMN audio_lang TEXT NOT NULL DEFAULT 'eng'`,
		`ALTER TABLE movies ADD COLUMN broken INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE episodes ADD COLUMN broken INTEGER NOT NULL DEFAULT 0`,
	}
	for i := ver; i < len(steps); i++ {
		if _, err := db.Exec(steps[i]); err != nil {
			return err
		}
		if _, err := db.Exec(`INSERT INTO schema_version (version) VALUES (?)`, i+1); err != nil {
			return err
		}
	}
	return nil
}
