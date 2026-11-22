import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'cache/cache_stats.dart';
import 'cache/cache_store.dart';
import 'cache/eviction_policy.dart';
import 'proxy/hls_handler.dart';
import 'proxy/hls_playlist.dart';
import 'proxy/mp4_range_handler.dart';
import 'proxy/proxy_server.dart';
import 'proxy/range_utils.dart';
import 'video_partial_cache_config.dart';

/// Transparent progressive video cache.
///
/// ```dart
/// final cache = VideoPartialCache();
/// await cache.init();                       // once, at startup
/// final url = cache.getPlayableUrl('https://.../video.mp4');
/// final controller = VideoPlayerController.networkUrl(Uri.parse(url));
/// ```
class VideoPartialCache {
  VideoPartialCache({
    int chunkSizeBytes = 256 * 1024,
    int maxCacheSizeBytes = 500 * 1024 * 1024,
    Directory? cacheDirectory,
    CacheLogCallback? onLog,
    http.Client? httpClient,
    Duration upstreamTimeout = const Duration(seconds: 30),
    int maxUpstreamRunChunks = 8,
    Map<String, String> upstreamHeaders = const {},
    Duration maxStallDuration = const Duration(seconds: 60),
    EvictionStrategy evictionStrategy = EvictionStrategy.lru,
  }) : config = VideoPartialCacheConfig(
    chunkSizeBytes: chunkSizeBytes,
    maxCacheSizeBytes: maxCacheSizeBytes,
    cacheDirectory: cacheDirectory,
    onLog: onLog,
    httpClient: httpClient,
    upstreamTimeout: upstreamTimeout,
    maxUpstreamRunChunks: maxUpstreamRunChunks,
    upstreamHeaders: upstreamHeaders,
    maxStallDuration: maxStallDuration,
    evictionStrategy: evictionStrategy,
  );

  final VideoPartialCacheConfig config;

  CacheStore? _store;
  Mp4RangeHandler? _handler;
  HlsHandler? _hls;
  ProxyServer? _server;
  http.Client? _ownedClient;
  Future<void>? _initFuture;
  bool _disposed = false;

  /// True once [init] completed and until [dispose].
  bool get isInitialized => _server?.isRunning ?? false;

  /// Port of the local proxy (after [init]).
  int get port => _server!.port;

  /// Starts the local proxy and opens the index. Safe to call repeatedly:
  /// concurrent/subsequent calls share the first one.
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    if (_disposed) throw StateError('VideoPartialCache was disposed');
    final dir =
        config.cacheDirectory ??
            Directory(
              p.join(
                (await getApplicationSupportDirectory()).path,
                'video_partial_cache',
              ),
            );
    await dir.create(recursive: true);

    final store = CacheStore(
      directory: dir,
      maxBytes: config.maxCacheSizeBytes,
      strategy: config.evictionStrategy,
    );
    await store.init();

    final client = config.httpClient ?? (_ownedClient = http.Client());
    final handler = Mp4RangeHandler(
      store: store,
      chunkSize: config.chunkSizeBytes,
      client: client,
      timeout: config.upstreamTimeout,
      maxRunChunks: config.maxUpstreamRunChunks,
      onLog: config.onLog,
      upstreamHeaders: config.upstreamHeaders,
      stallLimit: config.maxStallDuration,
    );
    final hls = HlsHandler(
      store: store,
      client: client,
      counters: handler.counters,
      timeout: config.upstreamTimeout,
      onLog: config.onLog,
      upstreamHeaders: config.upstreamHeaders,
    );
    final server = ProxyServer(
          (request) =>
      request.url.pathSegments.firstOrNull == 'hls'
          ? hls.call(request)
          : handler.call(request),
    );
    await server.start();

    _store = store;
    _handler = handler;
    _hls = hls;
    _server = server;
  }

  void _ensureInit() {
    if (!isInitialized) {
      throw StateError('VideoPartialCache.init() must complete first');
    }
  }

  /// URL to hand to `VideoPlayerController.networkUrl`. [videoId] defaults to
  /// a stable hash of [originalUrl]; pass your own when the URL contains
  /// changing tokens (signed URLs) so the cache stays addressable.
  ///
  /// [title] is an optional display name stored with the video (shown in
  /// [getStats] so a cache manager UI can list videos by name).
  ///
  /// HLS playlists (`.m3u8`) are detected from the url (force it with [hls]);
  /// the returned url then ends in `.m3u8` and every playlist, segment and
  /// init section is cached too. For HLS, give a stable [videoId] when the
  /// url is signed, and use one id per playlist (not per quality).
  String getPlayableUrl(String originalUrl, {
    String? videoId,
    String? title,
    bool? hls,
  }) {
    _ensureInit();
    final id = videoId ?? stableVideoId(originalUrl);
    final t = title == null || title.isEmpty
        ? ''
        : '&title=${Uri.encodeQueryComponent(title)}';
    final isHls = hls ?? isHlsUrl(originalUrl);
    final route = isHls ? 'hls' : 'proxy';
    final file = isHls ? '/m.m3u8' : '';
    return 'http://127.0.0.1:${_server!.port}/$route/${Uri.encodeComponent(id)}$file'
        '?src=${Uri.encodeQueryComponent(originalUrl)}$t';
  }

  /// Whether [url] points at an HLS playlist.
  static bool isHlsUrl(String url) =>
      (Uri
          .tryParse(url)
          ?.path
          .toLowerCase() ?? '').contains('.m3u8');

  /// Waits until in-flight downloads and disk writes are done.
  @visibleForTesting
  Future<void> debugWaitForIdle() async {
    await _handler?.whenIdle();
    await _hls?.whenIdle();
  }

  /// The id [getPlayableUrl] uses for [originalUrl] when no `videoId` is given.
  String videoIdFor(String originalUrl) => stableVideoId(originalUrl);

  /// Cached parts of a video as contiguous byte spans (merged), e.g. to draw
  /// them on a seek bar. Empty if nothing is cached or the length is unknown.
  Future<List<CachedRange>> getCachedRanges(String videoId) async {
    _ensureInit();
    final store = _store!;
    final total = store.totalLength(videoId);
    if (total == null || total <= 0) return const [];
    final cs = config.chunkSizeBytes;
    return [
      for (final run in mergeContiguousChunks(store.chunkIndexes(videoId)))
        CachedRange(
          startByte: chunkByteRange(run.first, cs, totalLength: total).start,
          endByte: chunkByteRange(run.last, cs, totalLength: total).end,
          totalLength: total,
        ),
    ];
  }

  /// Where the video is cached on its timeline and how much of it, for both
  /// progressive files and HLS (see [VideoCacheProgress]). Reading it does
  /// not count as using the video (eviction order is unchanged).
  Future<VideoCacheProgress> getCacheProgress(String videoId) async {
    _ensureInit();
    final store = _store!;
    final total = store.totalLength(videoId);
    if (total != null && total > 0) {
      final ranges = await getCachedRanges(videoId);
      final bytes = ranges.fold<int>(0, (n, r) => n + r.endByte - r.startByte + 1);
      return VideoCacheProgress(
        spans: [for (final r in ranges) CachedSpan(r.startFraction, r.endFraction)],
        fraction: (bytes / total).clamp(0.0, 1.0),
      );
    }

    Future<HlsOutline?> outline(String key) async {
      final data = await store.readChunk(videoId, HlsHandler.entryIndex(key), touch: false);
      if (data == null) return null;
      return hlsOutline(utf8.decode(data, allowMalformed: true), key);
    }

    final root = await outline('m');
    if (root == null) return VideoCacheProgress.empty;
    if (!root.isMaster) return _hlsProgress(videoId, root.segments);

    var best = const VideoCacheProgress(isHls: true);
    for (final key in root.variantKeys) {
      final child = await outline(key);
      if (child == null) continue;
      final p = _hlsProgress(videoId, child.segments);
      if ((p.fraction ?? 0) > (best.fraction ?? 0) || best.duration == null) best = p;
    }
    return best;
  }

  VideoCacheProgress _hlsProgress(String videoId, List<HlsSegmentRef> segments) {
    if (segments.isEmpty) return const VideoCacheProgress(isHls: true);
    var total = segments.fold<double>(0, (s, e) => s + e.seconds);
    // No usable EXTINF durations: weigh every segment equally.
    final weight = total > 0 ? null : 1.0;
    if (weight != null) total = segments.length.toDouble();

    final spans = <CachedSpan>[];
    var t = 0.0;
    var cached = 0.0;
    for (final s in segments) {
      final len = weight ?? s.seconds;
      if (_store!.hasChunk(videoId, HlsHandler.entryIndex(s.key))) {
        cached += len;
        final start = t / total;
        final end = (t + len) / total;
        if (spans.isNotEmpty && (spans.last.end - start).abs() < 1e-9) {
          spans[spans.length - 1] = CachedSpan(spans.last.start, end);
        } else {
          spans.add(CachedSpan(start, end));
        }
      }
      t += len;
    }
    return VideoCacheProgress(
      spans: spans,
      fraction: (cached / total).clamp(0.0, 1.0),
      duration: weight == null ? Duration(milliseconds: (total * 1000).round()) : null,
      isHls: true,
    );
  }

  /// Current runtime settings (limit and eviction strategy).
  CacheSettings get settings {
    _ensureInit();
    return CacheSettings(
      maxCacheSizeBytes: _store!.maxBytes,
      strategy: _store!.strategy,
    );
  }

  /// Changes the size limit and/or eviction strategy while running. A smaller
  /// limit takes effect immediately (the cache is trimmed with the new
  /// strategy, pinned videos excluded). Returns the bytes freed.
  Future<int> updateSettings({
    int? maxCacheSizeBytes,
    EvictionStrategy? strategy,
  }) async {
    _ensureInit();
    if (strategy != null) _store!.setStrategy(strategy);
    if (maxCacheSizeBytes != null) {
      return _store!.setMaxBytes(maxCacheSizeBytes);
    }
    return 0;
  }

  /// Evicts with the active strategy until at most [targetBytes] remain.
  /// Returns the bytes freed.
  Future<int> trimTo(int targetBytes) {
    _ensureInit();
    return _store!.trimTo(targetBytes);
  }

  /// Deletes every non-pinned video not played for [age]. Returns bytes freed.
  Future<int> clearVideosOlderThan(Duration age) {
    _ensureInit();
    return _store!.evictOlderThan(age);
  }

  /// Pinned videos are never evicted automatically (only [clearVideo] /
  /// [clearCache] remove them).
  Future<void> setPinned(String videoId, bool pinned) {
    _ensureInit();
    return _store!.setPinned(videoId, pinned);
  }

  Future<void> clearCache() async {
    _ensureInit();
    await _store!.clearAll();
  }

  Future<void> clearVideo(String videoId) async {
    _ensureInit();
    await _store!.clearVideo(videoId);
  }

  Future<int> getCacheSizeBytes() async {
    _ensureInit();
    return _store!.totalBytes;
  }

  Future<CacheStats> getStats() async {
    _ensureInit();
    final c = _handler!.counters;
    return CacheStats(
      totalBytes: _store!.totalBytes,
      maxBytes: _store!.maxBytes,
      strategy: _store!.strategy,
      videos: _store!.videoStats(),
      hitChunks: c.hitChunks,
      missChunks: c.missChunks,
      requests: c.requests,
    );
  }

  /// Stops the proxy and flushes/closes the index. The instance cannot be
  /// reused afterwards.
  Future<void> dispose() async {
    _disposed = true;
    final pending = _initFuture;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    await _server?.stop();
    _ownedClient?.close(); // aborts upstream transfers of an owned client
    try {
      await Future.wait([
        if (_handler != null) _handler!.whenIdle(),
        if (_hls != null) _hls!.whenIdle(),
      ]).timeout(const Duration(seconds: 3));
    } catch (_) {}
    await _store?.close();
    _server = null;
    _store = null;
    _handler = null;
    _hls = null;
    _ownedClient = null;
  }
}
