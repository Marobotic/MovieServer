class User {
  final int id;
  final String username;
  final String role;
  final String avatarColor;

  const User({
    required this.id,
    required this.username,
    required this.role,
    required this.avatarColor,
  });

  bool get isAdmin => role == 'admin';

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'],
        username: j['username'] ?? '',
        role: j['role'] ?? 'viewer',
        avatarColor: j['avatar_color'] ?? '#E50914',
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

  String get label => completed ? 'Watched' : (positionSec > 0 ? 'Continue' : '');

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
        episodes: (j['episodes'] as List)
            .map((e) => Episode.fromJson(e))
            .toList(),
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
        createdAt: j['created_at'] ?? '',
      );
}

class TMDbHit {
  final int tmdbId;
  final String title;
  final int year;
  final String overview;
  final String poster;
  final String type;

  const TMDbHit({
    required this.tmdbId,
    required this.title,
    required this.year,
    required this.overview,
    required this.poster,
    required this.type,
  });

  factory TMDbHit.fromJson(Map<String, dynamic> j) => TMDbHit(
        tmdbId: j['tmdb_id'],
        title: j['title'] ?? '',
        year: j['year'] ?? 0,
        overview: j['overview'] ?? '',
        poster: j['poster'] ?? '',
        type: j['type'] ?? 'movie',
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

  const MediaTracks.empty() : subtitles = const [], audio = const [];

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