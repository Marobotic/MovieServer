class User {
  final int id;
  final String username;
  final String role;
  final String avatarColor;
  final String audioLang;

  const User({
    required this.id,
    required this.username,
    required this.role,
    required this.avatarColor,
    this.audioLang = 'eng',
  });

  bool get isAdmin => role == 'admin';

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'],
        username: j['username'] ?? '',
        role: j['role'] ?? 'viewer',
        avatarColor: j['avatar_color'] ?? '#E50914',
        audioLang: j['audio_lang'] ?? 'eng',
      );
}

class Movie {
  final int id;
  final String title;
  final int year;
  final String filePath;
  final int sizeBytes;
  final String overview;
  final String poster;
  final String backdrop;
  final String trailerUrl;
  final int durationSec;

  const Movie({
    required this.id,
    required this.title,
    required this.year,
    required this.filePath,
    required this.sizeBytes,
    required this.overview,
    required this.poster,
    required this.backdrop,
    required this.trailerUrl,
    required this.durationSec,
  });

  factory Movie.fromJson(Map<String, dynamic> j) => Movie(
        id: j['id'],
        title: j['title'] ?? '',
        year: j['year'] ?? 0,
        filePath: j['file_path'] ?? '',
        sizeBytes: j['size_bytes'] ?? 0,
        overview: j['overview'] ?? '',
        poster: j['poster'] ?? '',
        backdrop: j['backdrop'] ?? '',
        trailerUrl: j['trailer_url'] ?? '',
        durationSec: j['duration_sec'] ?? 0,
      );
}

class Show {
  final int id;
  final String title;
  final int year;
  final String overview;
  final String poster;
  final String backdrop;
  final String trailerUrl;

  const Show({
    required this.id,
    required this.title,
    required this.year,
    required this.overview,
    required this.poster,
    required this.backdrop,
    required this.trailerUrl,
  });

  factory Show.fromJson(Map<String, dynamic> j) => Show(
        id: j['id'],
        title: j['title'] ?? '',
        year: j['year'] ?? 0,
        overview: j['overview'] ?? '',
        poster: j['poster'] ?? '',
        backdrop: j['backdrop'] ?? '',
        trailerUrl: j['trailer_url'] ?? '',
      );
}

class Episode {
  final int id;
  final int showId;
  final int season;
  final int episode;
  final String title;
  final String overview;
  final String still;
  final int sizeBytes;
  final int durationSec;
  final String showTitle;
  final String trailerUrl;
  final int positionSec;
  final bool completed;

  const Episode({
    required this.id,
    required this.showId,
    required this.season,
    required this.episode,
    required this.title,
    required this.overview,
    required this.still,
    required this.sizeBytes,
    required this.durationSec,
    required this.showTitle,
    required this.trailerUrl,
    required this.positionSec,
    required this.completed,
  });

  String get label =>
      completed ? 'Watched' : (positionSec > 0 ? 'Continue' : '');

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
        id: j['id'],
        showId: j['show_id'] ?? 0,
        season: j['season'] ?? 1,
        episode: j['episode'] ?? 1,
        title: j['title'] ?? '',
        overview: j['overview'] ?? '',
        still: j['still'] ?? '',
        sizeBytes: j['size_bytes'] ?? 0,
        durationSec: j['duration_sec'] ?? 0,
        showTitle: j['show_title'] ?? '',
        trailerUrl: j['trailer_url'] ?? '',
        positionSec: j['watched_sec'] ?? 0,
        completed: j['completed'] == true,
      );
}

class ShowDetail {
  final Show show;
  final List<Episode> episodes;

  const ShowDetail({required this.show, required this.episodes});

  factory ShowDetail.fromJson(Map<String, dynamic> j) => ShowDetail(
        show: Show.fromJson(j['show']),
        episodes:
            (j['episodes'] as List).map((e) => Episode.fromJson(e)).toList(),
      );
}

class ContinueItem {
  final String mediaKind;
  final int mediaId;
  final int position;
  final int duration;
  final String title;
  final String poster;
  final int showId;
  final int season;
  final int episode;

  const ContinueItem({
    required this.mediaKind,
    required this.mediaId,
    required this.position,
    required this.duration,
    required this.title,
    required this.poster,
    required this.showId,
    required this.season,
    required this.episode,
  });

  factory ContinueItem.fromJson(Map<String, dynamic> j) => ContinueItem(
        mediaKind: j['media_kind'],
        mediaId: j['media_id'],
        position: j['position'],
        duration: j['duration'],
        title: j['title'] ?? '',
        poster: j['poster'] ?? '',
        showId: j['show_id'] ?? 0,
        season: j['season'] ?? 0,
        episode: j['episode'] ?? 0,
      );
}

class MediaRequest {
  final int id;
  final int userId;
  final String username;
  final String kind;
  final String title;
  final int year;
  final String note;
  final String status;
  final int tmdbId;
  final String createdAt;

  const MediaRequest({
    required this.id,
    required this.userId,
    required this.username,
    required this.kind,
    required this.title,
    required this.year,
    required this.note,
    required this.status,
    required this.tmdbId,
    required this.createdAt,
  });

  factory MediaRequest.fromJson(Map<String, dynamic> j) => MediaRequest(
        id: j['id'],
        userId: j['user_id'],
        username: j['username'] ?? '',
        kind: j['kind'] ?? 'movie',
        title: j['title'] ?? '',
        year: j['year'] ?? 0,
        note: j['note'] ?? '',
        status: j['status'] ?? 'pending',
        tmdbId: j['tmdb_id'] ?? 0,
        createdAt: j['created_at'] ?? '',
      );
}

class TMDbHit {
  final int tmdbId;
  final String title;
  final int year;
  final String overview;
  final String poster;
  final String backdrop;
  final String trailerUrl;
  final String type;

  const TMDbHit({
    required this.tmdbId,
    required this.title,
    required this.year,
    required this.overview,
    required this.poster,
    this.backdrop = '',
    this.trailerUrl = '',
    required this.type,
  });

  factory TMDbHit.fromJson(Map<String, dynamic> j) => TMDbHit(
        tmdbId: j['tmdb_id'],
        title: j['title'] ?? '',
        year: j['year'] ?? 0,
        overview: j['overview'] ?? '',
        poster: j['poster'] ?? '',
        backdrop: j['backdrop'] ?? '',
        trailerUrl: j['trailer_url'] ?? '',
        type: j['type'] ?? 'movie',
      );
}

class CatalogPage {
  final int page;
  final int totalPages;
  final List<TMDbHit> results;

  const CatalogPage({
    required this.page,
    required this.totalPages,
    required this.results,
  });

  factory CatalogPage.fromJson(Map<String, dynamic> j) => CatalogPage(
        page: j['page'] ?? 1,
        totalPages: j['total_pages'] ?? 1,
        results: (j['results'] as List? ?? const [])
            .map((e) => TMDbHit.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class SubtitleInfo {
  final int index;
  final String url;
  final String language;
  final String name;

  const SubtitleInfo({
    required this.index,
    required this.url,
    required this.language,
    required this.name,
  });

  factory SubtitleInfo.fromJson(Map<String, dynamic> j) => SubtitleInfo(
        index: j['index'] ?? 0,
        url: j['url'] ?? '',
        language: j['language'] ?? '',
        name: j['name'] ?? '',
      );
}

class AudioTrackInfo {
  final int index;
  final String language;
  final String title;
  final bool isDefault;

  const AudioTrackInfo({
    required this.index,
    required this.language,
    required this.title,
    required this.isDefault,
  });

  String get label => title.isNotEmpty ? title : language;

  factory AudioTrackInfo.fromJson(Map<String, dynamic> j) => AudioTrackInfo(
        index: j['index'] ?? 0,
        language: j['language'] ?? '',
        title: j['title'] ?? '',
        isDefault: j['default'] == true,
      );
}

class MediaTracks {
  final List<SubtitleInfo> subtitles;
  final List<AudioTrackInfo> audio;

  const MediaTracks({required this.subtitles, required this.audio});

  const MediaTracks.empty()
      : subtitles = const [],
        audio = const [];

  factory MediaTracks.fromJson(Map<String, dynamic> j) => MediaTracks(
        subtitles: (j['subtitles'] as List)
            .map((e) => SubtitleInfo.fromJson(e))
            .toList(),
        audio: (j['audio_tracks'] as List)
            .map((e) => AudioTrackInfo.fromJson(e))
            .toList(),
      );
}

class MediaFormat {
  final String container;
  final String videoCodec;
  final int videoWidth;
  final int videoHeight;
  final String videoFps;
  final String audioCodec;
  final int audioChannels;
  final int sampleRate;
  final int durationSec;
  final bool supported;
  final String reason;

  const MediaFormat({
    this.container = '',
    this.videoCodec = '',
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.videoFps = '',
    this.audioCodec = '',
    this.audioChannels = 0,
    this.sampleRate = 0,
    this.durationSec = 0,
    this.supported = false,
    this.reason = '',
  });

  factory MediaFormat.fromJson(Map<String, dynamic> j) => MediaFormat(
        container: j['container'] as String? ?? '',
        videoCodec: j['video_codec'] as String? ?? '',
        videoWidth: j['video_width'] as int? ?? 0,
        videoHeight: j['video_height'] as int? ?? 0,
        videoFps: j['video_fps'] as String? ?? '',
        audioCodec: j['audio_codec'] as String? ?? '',
        audioChannels: j['audio_channels'] as int? ?? 0,
        sampleRate: j['sample_rate'] as int? ?? 0,
        durationSec: j['duration_sec'] as int? ?? 0,
        supported: j['supported'] as bool? ?? false,
        reason: j['reason'] as String? ?? '',
      );
}

class PlaybackEstimate {
  final int minutes;
  final int? sizeGB;
  final String worker;

  PlaybackEstimate({
    required this.minutes,
    this.sizeGB,
    required this.worker,
  });

  factory PlaybackEstimate.fromJson(Map<String, dynamic> j) => PlaybackEstimate(
        minutes: j['minutes'] as int? ?? 1,
        sizeGB: j['size_gb'] as int?,
        worker: j['worker'] as String? ?? 'cpu',
      );
}

class PlaybackJobBrief {
  final int id;
  final String kind;
  final int mediaId;
  final String type;
  final String mode;
  final String status;
  final String worker;
  final double percent;
  final double speed;
  final int etaSec;
  final String title;
  final String error;

  PlaybackJobBrief({
    required this.id,
    this.kind = 'movie',
    this.mediaId = 0,
    this.type = 'quick_fix',
    this.mode = 'now',
    required this.status,
    this.worker = 'cpu',
    required this.percent,
    required this.speed,
    required this.etaSec,
    this.title = '',
    this.error = '',
  });

  bool get isRunning => status == 'running';
  bool get isPaused => status == 'paused' || status == 'paused_gaming';
  bool get isQueued => status == 'queued';
  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
  bool get isCanceled => status == 'canceled';
  bool get isFinished => isDone || isFailed || isCanceled;

  factory PlaybackJobBrief.fromJson(Map<String, dynamic> j) => PlaybackJobBrief(
        id: j['id'] as int? ?? 0,
        kind: j['kind'] as String? ?? 'movie',
        mediaId: j['media_id'] as int? ?? 0,
        type: j['type'] as String? ?? 'quick_fix',
        mode: j['mode'] as String? ?? 'now',
        status: j['status'] as String? ?? 'queued',
        worker: j['worker'] as String? ?? 'cpu',
        percent: (j['percent'] as num?)?.toDouble() ?? 0,
        speed: (j['speed'] as num?)?.toDouble() ?? 0,
        etaSec: j['eta_sec'] as int? ?? 0,
        title: j['title'] as String? ?? '',
        error: j['error'] as String? ?? '',
      );
}

/// Server-wide settings shared by all users. Only admins can write them.
class AppSettings {
  final Duration subtitleDelay;

  const AppSettings({this.subtitleDelay = Duration.zero});

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        subtitleDelay:
            Duration(milliseconds: j['subtitle_delay_ms'] as int? ?? 0),
      );
}

class PlaybackDecision {
  final String decision;
  final String title;
  final String url;
  final String variant;
  final String reason;
  final PlaybackEstimate? estimate;
  final PlaybackJobBrief? job;
  final int queuePos;
  final PlaybackJobBrief? activeJob;
  final bool nativeOK;

  PlaybackDecision({
    required this.decision,
    required this.title,
    required this.url,
    required this.variant,
    required this.reason,
    this.estimate,
    this.job,
    this.queuePos = 0,
    this.activeJob,
    required this.nativeOK,
  });

  factory PlaybackDecision.fromJson(Map<String, dynamic> j) => PlaybackDecision(
        decision: j['decision'] as String? ?? 'damaged',
        title: j['title'] as String? ?? '',
        url: j['url'] as String? ?? '',
        variant: j['variant'] as String? ?? 'original',
        reason: j['reason'] as String? ?? '',
        estimate: j['estimate'] == null
            ? null
            : PlaybackEstimate.fromJson(j['estimate']),
        job: j['job'] == null ? null : PlaybackJobBrief.fromJson(j['job']),
        queuePos: j['queue_pos'] as int? ?? 0,
        activeJob: j['active_job'] == null
            ? null
            : PlaybackJobBrief.fromJson(j['active_job']),
        nativeOK: j['native_ok'] as bool? ?? false,
      );
}

class LogLine {
  final DateTime time;
  final String text;

  const LogLine({required this.time, required this.text});

  factory LogLine.fromJson(Map<String, dynamic> j) => LogLine(
        time: DateTime.tryParse(j['time'] as String? ?? '')?.toLocal() ??
            DateTime.now(),
        text: j['text'] as String? ?? '',
      );
}
