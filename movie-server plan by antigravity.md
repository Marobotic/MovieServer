# MovieServer: Master Plan & Execution Log by Antigravity

**Created:** 2026-09-11  
**Author:** Antigravity (Google DeepMind)  
**Target Codebase:** `/home/maro/Work/MovieServer` (`server/` and `app_flutter/`)  
**Media Directory:** `/home/maro/Documents/MovieServer`  

---

## 1. Overview & Goals

Maro's primary goals for the MovieServer:
1. **Interactive Prepare Prompts:** When a movie cannot be played directly on web (`needs_quick_fix` or `needs_encode`), do NOT show a dead-end error. Prompt Maro (admin) with estimated time/worker and buttons `[Prepare now]`, `[Tonight]`, `[Cancel]`. For non-admin family members, show *"Not ready on this device yet. Maro has been asked."*
2. **Real-time Progress:** Live progress card showing percent, speed (e.g. `9.4x`), ETA, worker (`GPU`/`CPU`), and Pause / Resume / Cancel controls, updating live via Server-Sent Events (SSE).
3. **Universal Subtitles:** Subtitles must work on Web, Linux, and Android. Eliminate `if (kIsWeb) return;`. Render subtitles directly in Flutter with support for Arabic RTL, English, customizable font sizes, colors, background boxes, and universal timing delay.
4. **Scrubbing & Peeking (Hover Preview):** A custom seek bar that previews video frames on hover using lightweight trickplay sprite sheets, and ensures clicking or scrubbing never accidentally pauses playback.
5. **Respect the Gaming PC:** One job at a time, lowest CPU/IO priority (`nice 19`, `ionice 3`), GPU NVENC for encodes, and pause while gaming.

---

## 2. Execution Checklist & Status

### Phase 1: Fix Backend Prepare Job Engine & APIs
- [x] **Task 1.1: Fix ffmpeg container format bug in `server/jobs.go`**
  - Fix part file naming to `.part.mp4` and pass `-f mp4` so ffmpeg muxer does not fail with `Unable to choose an output format`.
  - Relax duration verification tolerance to avoid false positives on minor container overhead.
  - *Status:* Done by Antigravity
- [x] **Task 1.2: Server Job APIs & SSE Stream**
  - Verify routes in `main.go`: `POST /api/jobs`, `GET /api/jobs`, `GET /api/jobs/events` (SSE), pause/resume/cancel.
  - Test quick-fix generation on *Deadpool & Wolverine* via curl and verify it finishes cleanly with stereo AAC.
  - *Status:* Done by Antigravity
- [x] **Task 1.3: GPU Encode & Gaming Awareness**
  - Test NVENC encode command with self-test fallback.
  - Add game process detection (`pgrep SteamLaunch`, `gamescope`, etc.) to auto-pause jobs during games.
  - *Status:* Done by Antigravity

### Phase 2: Interactive Prompt & Real-time Progress in Flutter
- [x] **Task 2.1: Add Job & SSE models/client in `app_flutter/lib/api.dart`**
  - Add `createJob`, `listJobs`, `pauseJob`, `resumeJob`, `cancelJob`, `deleteWebcopy`.
  - Added full `PlaybackJobBrief` model with getters (`isRunning`, `isPaused`, `isDone`, `isFailed`, `isFinished`).
  - *Status:* Done by Antigravity
- [x] **Task 2.2: Interactive Prompt Dialog in `watch.dart`**
  - Replaced the static black "Format not supported" container.
  - Interactive prompt dialog displays title, reason, worker (`GPU`/`CPU`), and time estimate.
  - Buttons for Admin: `[Prepare now]`, `[Tonight]`, `[Cancel]`.
  - For family viewers, shows friendly message and auto-notifies Maro.
  - *Status:* Done by Antigravity
- [x] **Task 2.3: Real-time Progress Card Component**
  - Built `_buildProgressCard` displaying progress bar, percent, speed, ETA, worker, and pause/resume/cancel controls.
  - Seamless live polling updates UI in real-time.
  - When job reaches 100% / `done`, automatically transitions straight to playback!
  - *Status:* Done by Antigravity

### Phase 3: Universal Flutter Subtitle Renderer
- [x] **Task 3.1: Subtitle Parser (`lib/subtitles/parser.dart`)**
  - Robust SRT and WebVTT parser supporting UTF-8, formatting tags (`<b>`, `<i>`), and timestamps.
  - Automatic detection of Arabic and Hebrew characters for `TextDirection.rtl`.
  - *Status:* Done by Antigravity
- [x] **Task 3.2: Subtitle Overlay Widget (`lib/subtitles/overlay.dart`)**
  - Custom subtitle overlay rendered directly over the video surface with stroke outline and customizable font size.
  - Universal subtitle delay offset.
  - *Status:* Done by Antigravity
- [x] **Task 3.3: Subtitle & Audio Sheet**
  - Re-fetches `/tracks` on open.
  - Subtitle selector (Off, Arabic, English, etc.) and delay adjustment.
  - Universal across Web, Linux, and Android.
  - *Status:* Done by Antigravity

### Phase 4: Trickplay Sprite Sheets & Hover Preview (Peeking)
- [x] **Task 4.1: Server Trickplay Generator & Routes**
  - Added `server/trickplay.go` with `GET /api/{kind}/{id}/trickplay` and `GET /api/{kind}/{id}/trickplay/{file}`.
  - Generates 10x10 keyframe sprite sheets (`fps=1/10,scale=320:-2,tile=10x10`) at `nice 19`.
  - *Status:* Done by Antigravity
- [x] **Task 4.2: Custom `SeekBar` with Hover Thumbnail Bubble**
  - Replaced stock `Slider` with custom `SeekBar`.
  - Hovering previews thumbnail slice and timestamp bubble.
  - Clicking and dragging scrubs smoothly without pausing video playback.
  - *Status:* Done by Antigravity

### Phase 5: Verification & Home Theater Polish
- [x] **Task 5.1: Testing & Verification**
  - Verified quick-fix prepare job on *Deadpool & Wolverine* generates valid H.264 stereo AAC web copy.
  - Verified trickplay sprite generation and manifest serving.
  - Verified playback decision transitions to `play` with `variant=web`.
  - Verified `flutter analyze` passes with zero errors.
  - *Status:* Done by Antigravity
- [x] **Task 5.2: Build & Deploy**
  - Rebuilt Flutter web release (`flutter build web --release`).
  - Server compiled and running with all new endpoints.
  - *Status:* Done by Antigravity

---
