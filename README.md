# MovieServer

A family media server that runs on this machine and serves your movie and TV
show collection over the local network. Netflix-style apps for Android,
Windows, Linux, and the web, each with per-user watch progress, posters,
descriptions and trailers (via TMDB), a request system, and an admin panel.

## How it works

- You drop your files into `~/Documents/MovieServer/Movies` and
  `~/Documents/MovieServer/Shows`.
- The Go server scans those folders, builds a catalog, streams videos (with
  seek support), tracks each user's progress, and serves the web app.
- The Flutter app is the same codebase that builds to Windows, Android, Linux,
  and web. Point any of them at the server and pick a profile.
- Family members can "request" titles; the admin approves and drops the file in
  the folder (or uploads it straight from the app).

```
MovieServer/
├── server/          # Go backend (API + steamer + web host)
├── app_flutter/     # Flutter app (android/ windows/ linux/ web/)
└── ~/Documents/MovieServer/   # your media (Movies/ and Shows/)
```

## Quick start (Linux server)

```bash
cd server
./movieserver
# or: go run . (Go 1.24+)
```

On first run it creates `config.json` and prints the local address, e.g.
`http://192.168.3.54:8080`. Open it in a browser, complete the one-time admin
setup, then create profiles for the family.

### Auto-start (systemd)

```bash
sudo cp server/movieserver.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now movieserver
```

Edit the service file if your paths differ.

## Building the apps

The Flutter app builds from `app_flutter/`:

| Platform | Command | Runs on |
| --- | --- | --- |
| Web | `flutter build web --release` | automatically served by the server |
| Linux | `flutter build linux --release` | this machine |
| Windows | `flutter build windows --release` | a Windows machine |
| Android | `flutter build apk --release` | needs Android Studio / SDK |

`flutter build web` output goes to `app_flutter/build/web`, which the server
serves automatically. Rebuild it whenever you change the app, then restart the
server.

## Folder layout for your media

```
~/Documents/MovieServer/
├── Movies/
│   ├── Interstellar (2014).mkv
│   └── Dune - Part Two/
│       └── Dune part two.720p.mp4
└── Shows/
    └── The Wire/
        ├── Season 01/
        │   ├── The Wire S01E01 - The Target.mkv
        │   └── The Wire S01E02.mkv
        └── Season 02/
```

Titles and years are parsed from the folder/file names. After adding files,
press **Scan library** in the admin panel (or restart the server).

## Requesting titles

Any user opens **Requests > Request** from the app, searches (via TMDB) or
types a title, and sends it. The admin sees it in **Admin > Requests** and can
approve or deny. Approved files still need to be placed in the library folder
(admin can also upload them directly with **Admin > Library > Upload**).

## TMDB metadata (posters, descriptions, trailers)

Sign up for a free API key at https://www.themoviedb.org/documentation/api.

Add it to `server/config.json`:

```json
{
  "tmdb_api_key": "your-key-here"
}
```

Restart the server and run a scan. Files that have no metadata yet are
enriched automatically. Metadata is cached locally, so the internet is only
needed during enrichment.

If you prefer, you can also drop a `poster.jpg` (and `backdrop.jpg,
fanart.jpg`) next to a movie file - local art always wins once metadata
fetching is wired to check for it.

## Configuration (`server/config.json`)

| Key | Default | Meaning |
| --- | --- | --- |
| `port` | `8080` | HTTP port |
| `media_dir` | `~/Documents/MovieServer` | where Movies/ and Shows/ live |
| `data_dir` | `data` | SQLite db + cached covers |
| `jwt_secret` | random | signs login tokens (auto-generated) |
| `tmdb_api_key` | empty | enables posters/trailers/descriptions |
| `tmdb_language` | `en` | metadata language |

## API overview

- `POST /api/auth/setup` - first-run admin (only when there are no users)
- `POST /api/auth/login` - returns a JWT
- `GET /api/movies`, `GET /api/shows`, `GET /api/movies/{id}`,
  `GET /api/shows/{id}`
- `GET /api/movies/{id}/stream` and `GET /api/episodes/{id}/stream` -
  Range-enabled streaming (seek works)
- `POST /api/progress` - save/pause resume per user
- `GET /api/library/continue_watching` - resume shelf per user
- `POST /api/requests`, `PATCH /api/requests/{id}` - request workflow (admin
  only status changes)
- `POST /api/admin/scan`, `POST /api/admin/upload`, `GET /api/admin/tmdb/search`
- `GET /api/users`, `POST /api/users`, ... - admin manages profiles

All endpoints (except setup/login/capabilities) require `Authorization: Bearer
<token>`. Stream endpoints also accept `?token=<token>` so video players that
cannot set headers (browser `<video>`) work.

## Notes

- Streaming is direct play over the LAN - no transcoding. Modern devices play
  H.264 MP4/MKV instantly; very old TVs may not play HEVC/AV1 MKV.
- It is designed for a trusted LAN: the server binds to all interfaces so
  family devices can reach it, and authentication protects the API.