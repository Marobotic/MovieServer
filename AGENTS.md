# MovieServer - project notes for the assistant

## Reminder (important)

TMDB is now configured: `server/config.json` has `tmdb_api_key` and the
`tmdb_read_token` (JWT) stored. Enrichment runs on `POST /api/admin/scan`
(async, in a goroutine). The client prefers the read-access Bearer token; it
falls back to `api_key` if the token is absent. Re-run the scan after adding
new media. If TMDB metadata misses a title, the movie/show stays unenriched
until the next scan.

## Layout

- `server/` - Go 1.24+ backend. Single binary `movieserver`, SQLite data dir,
  serves the Flutter web build from `../app_flutter/build/web`.
- `app_flutter/` - Flutter app, one codebase for Android / Windows / Linux /
  web. Video: media_kit everywhere (libmpv native, hls.js on web) via
  `lib/playback.dart`; `video_player` was removed.
- Media root defaults to `~/Documents/MovieServer` with `Movies/` and `Shows/`.

## Build & run

Server (must run from `server/`):

```
cd server
go build -o movieserver . && ./movieserver
```

One-shot library organizer (create per-movie folders, move episodes into
`Season NN/`, rename messy folders to clean titles; skips files that are still
being copied):

```
./movieserver -organize
```

Loose files dropped into `Movies/` keep working (scanner handles both), but
running `-organize` keeps the library tidy. It runs on the strict name cleaner
in `scanner.go` (release tags, groups, brackets stripped).

Restart pattern on this machine: `systemctl --user restart movieserver`
(user unit at `~/.config/systemd/user/movieserver.service`, logs in journald
via `journalctl --user -u movieserver -f`; `loginctl enable-linger maro` keeps
it running after logout).

Flutter app:

```
cd app_flutter
flutter build web --release   # output auto-served by the server
flutter build linux --release
flutter build windows --release   # on a Windows machine
flutter build apk --release       # needs Android SDK
```

## Toolchain on this machine

- Go: `~/go-sdk/go-sdk/bin/go` (not installed system-wide; use this path or
  add it to PATH).
- Flutter: `~/flutter/bin/flutter`.
- ffmpeg/ffprobe installed (`n9.0.1`); used for HLS transcoding.
- No Android SDK installed; Android APK and `flutter run -d chrome` cannot run
  locally yet. Headless browser tests use `/usr/bin/chromium` via puppeteer-core
  (harness in `~/.cache/test-movieserver/`).

## Conventions

- Server handlers build on Go 1.22+ mux patterns (`GET /api/movies/{id}`); use
  `r.PathValue("id")`, not manual path parsing. Do NOT register routes with a
  bare `{kind}` wildcard - the Go 1.26 mux rejects them as ambiguous with other
  wildcard routes; register one route per literal (`/api/movies/...`,
  `/api/shows/...`, `/api/episodes/...`) and derive the kind from `r.Pattern`
  via `mediaKindFor(r)`.
- SQLite via `modernc.org/sqlite` (no cgo). Do not set `SetMaxOpenConns(1)` -
  nested queries deadlock.
- Media organization: movies may live loose in `Movies/` or in per-movie
  folders `Movies/<Title> (Year)/` (scanner picks the largest video file).
  Shows live in `Shows/<Title>/S01/...`. Users drop artwork in the item folder:
  `poster.*`, `backdrop.*`/`fanart.*`, `banner.*`, `logo.*`/`clearlogo.*`,
  `icon.*`/`thumb.*`, `folder.*`. On scan, local `poster`/`backdrop` override
  TMDB (URLs become `/api/movies/{id}/art/poster` etc.); enrichment never
  overwrites local-art URLs (`isLocalArt`). All slots fetchable at
  `GET /api/{movies|shows|episodes}/{id}/art/{slot}` (public).
- External subtitles: drop `Video.en.srt` (or in `subs/`/`subtitles/` folder).
  Listed under `GET /api/movies|episodes/{id}/tracks` (also audio tracks via
  ffprobe, cached 30min). Served at
  `GET /api/movies|episodes/{id}/subtitles/{index}` (auth via `?token=`).
  Auto-fetch en+ar SRTs from OpenSubtitles REST v1 (`subtitles.go`) with config
  `opensubtitles_user` / `opensubtitles_password` / `opensubtitles_api_key`
  (all required; key from opensubtitles.com). Trigger: `POST /api/admin/subs`
  (async goroutine, throttled ~1.2s/item, skips files that already exist next
  to the video as `<stem>.<lang>.srt`). Subtitle timing can be offset from the
  app via mpv `sub-delay` (native players only; see `sub_delay_io.dart`).
- Video playback: native apps use Range-based direct play
  (`/api/{kind}/{id}/stream`); the web app uses on-the-fly HLS
  (`/api/{kind}/{id}/hls/master.m3u8`, segments under `/api/hls/{job}/{file}`).
  The live HLS path only remuxes **H.264** video (`-c:v copy`) and always
  re-encodes audio to **stereo AAC** (`-c:a aac -ac 2`): Chromium's MSE rejects
  multichannel AAC, so never feed it 5.1/7.1. Non-H.264 video (HEVC/AV1/etc.)
  returns `409 {"decision":"needs_encode",...}` from the master endpoint - the
  live path never encodes video. ffmpeg jobs live in `<data_dir>/hls` and are
  janitor-garbage-collected. Requires ffmpeg/ffprobe on the server. Audio/
  subtitle switching in the app is media_kit-native only (no-op on web).
- Token auth via `Authorization: Bearer` header; stream + HLS + subtitle
  endpoints also accept `?token=` for browser players.
- Empty list endpoints must marshal as `[]`, never `null` (Dart casts results
  to `List`). Initialize slices with `make([]T, 0)`.
- No comments in code unless asked.

## Test flows (curl)

1. `POST /api/auth/setup` (first run only).
2. `POST /api/auth/login` -> token.
3. `GET /api/movies`, `GET /api/shows/{id}`.
4. `GET /api/movies/{id}/stream` with `-r 0-99` should return 206.
5. `GET /api/movies/{id}/hls/master.m3u8?token=...` returns a playlist; its
   segment URLs (`/api/hls/.../seg_*.ts` ) should return `video/mp2t` 200, and
   segments should probe as `aac,LC,48000,2` (always stereo). HEVC files return
   `409 {"decision":"needs_encode"}` instead of a playlist.
6. `POST /api/progress`, `GET /api/library/continue_watching`.
7. `POST /api/requests` (viewer), `PATCH /api/requests/{id}` (admin).
8. Unaauthenticated/unprivileged calls should 401/403.