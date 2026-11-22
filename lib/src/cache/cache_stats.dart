import 'eviction_policy.dart';

/// Cache statistics for one video.
class VideoCacheStats {
  const VideoCacheStats({
    required this.videoId,
    required this.cachedBytes,
    required this.chunkCount,
    this.totalLength,
    this.title,
    this.pinned = false,
    this.lastAccess,
    this.hits = 0,
  });

  final String videoId;

  /// Bytes currently on disk for this video.
  final int cachedBytes;

  /// Number of chunk files on disk for this video.
  final int chunkCount;

  /// Full size of the video, if the origin has been probed.
  final int? totalLength;

  /// Optional display name given through `getPlayableUrl(title: ...)`.
  final String? title;

  /// Pinned videos are never evicted automatically.
  final bool pinned;

  /// Last time any part of the video was read or written.
  final DateTime? lastAccess;

  /// Total number of chunk reads served from disk for this video.
  final int hits;

  /// Fraction of the video on disk (0..1), or null if the length is unknown.
  double? get cachedFraction => totalLength == null || totalLength == 0
      ? null
      : (cachedBytes / totalLength!).clamp(0.0, 1.0);

  @override
  String toString() =>
      'VideoCacheStats($videoId, $cachedBytes B, $chunkCount chunks, total=$totalLength)';
}

/// Aggregate cache statistics.
class CacheStats {
  const CacheStats({
    required this.totalBytes,
    required this.maxBytes,
    required this.videos,
    required this.hitChunks,
    required this.missChunks,
    required this.requests,
    this.strategy = EvictionStrategy.lru,
  });

  final int totalBytes;
  final int maxBytes;
  final List<VideoCacheStats> videos;

  /// Active eviction strategy.
  final EvictionStrategy strategy;

  /// Chunks served from disk since the cache was created (not persisted).
  final int hitChunks;

  /// Chunks that had to be fetched from the origin since creation.
  final int missChunks;

  /// Number of proxy requests handled since creation.
  final int requests;

  int get videoCount => videos.length;

  /// Hit ratio over served chunks, or null if nothing was served yet.
  double? get hitRatio {
    final n = hitChunks + missChunks;
    return n == 0 ? null : hitChunks / n;
  }

  @override
  String toString() =>
      'CacheStats($totalBytes/$maxBytes B, ${videos.length} videos, '
      'hits=$hitChunks, misses=$missChunks)';
}

/// Runtime-adjustable cache settings.
class CacheSettings {
  const CacheSettings({
    required this.maxCacheSizeBytes,
    required this.strategy,
  });

  final int maxCacheSizeBytes;
  final EvictionStrategy strategy;
}

/// A contiguous cached byte span of one video.
class CachedRange {
  const CachedRange({
    required this.startByte,
    required this.endByte,
    required this.totalLength,
  });

  /// Inclusive byte offsets.
  final int startByte;
  final int endByte;
  final int totalLength;

  /// Position within the file, 0..1. For constant-bitrate video this is also
  /// the position on the timeline; for VBR it is an approximation.
  double get startFraction => startByte / totalLength;
  double get endFraction => (endByte + 1) / totalLength;

  @override
  String toString() => 'CachedRange($startByte-$endByte/$totalLength)';
}

/// A cached part of a video's **timeline**, as fractions 0..1.
class CachedSpan {
  const CachedSpan(this.start, this.end);

  final double start;
  final double end;

  @override
  String toString() => 'CachedSpan($start-$end)';
}

/// How much of a video is cached and where, ready to draw on a seek bar.
///
/// * Progressive files (MP4): from the cached byte ranges. Exact for
///   constant bitrate, an approximation for variable bitrate.
/// * HLS: from the cached segments and their durations (exact). For a master
///   playlist the variant with the most cached time is reported.
class VideoCacheProgress {
  const VideoCacheProgress({
    this.spans = const [],
    this.fraction,
    this.duration,
    this.isHls = false,
  });

  static const empty = VideoCacheProgress();

  /// Merged, sorted cached parts of the timeline.
  final List<CachedSpan> spans;

  /// Cached share of the timeline (0..1), or null if unknown.
  final double? fraction;

  /// Total duration, known for HLS (from the playlist).
  final Duration? duration;

  final bool isHls;

  @override
  String toString() =>
      'VideoCacheProgress(${fraction?.toStringAsFixed(3)}, $spans, hls=$isHls)';
}
