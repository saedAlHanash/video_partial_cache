import 'dart:io';

import 'package:http/http.dart' as http;

import 'cache/eviction_policy.dart';

/// Callback receiving human readable cache hit/miss log lines.
/// Only ever invoked in debug builds.
typedef CacheLogCallback = void Function(String message);

/// Configuration of a [VideoPartialCache].
class VideoPartialCacheConfig {
  const VideoPartialCacheConfig({
    this.chunkSizeBytes = 256 * 1024,
    this.maxCacheSizeBytes = 500 * 1024 * 1024,
    this.cacheDirectory,
    this.onLog,
    this.httpClient,
    this.upstreamTimeout = const Duration(seconds: 30),
    this.maxUpstreamRunChunks = 8,
    this.upstreamHeaders = const {},
    this.maxStallDuration = const Duration(seconds: 60),
    this.evictionStrategy = EvictionStrategy.lru,
  }) : assert(chunkSizeBytes > 0),
       assert(maxCacheSizeBytes > 0),
       assert(maxUpstreamRunChunks > 0);

  /// Size of one cache chunk. Requests are aligned to multiples of this.
  /// **Changing it between runs invalidates nothing automatically** — the
  /// chunk size is part of the on-disk layout, so use a fresh
  /// [cacheDirectory] (or call `clearCache()`) when you change it.
  final int chunkSizeBytes;

  /// Upper bound for all cached chunk files together. Both the limit and
  /// the strategy can be changed at runtime with `updateSettings`.
  ///
  final int maxCacheSizeBytes;

  /// Where the cache lives. Defaults to
  /// `<getApplicationSupportDirectory()>/video_partial_cache`.
  final Directory? cacheDirectory;

  /// Debug-only hit/miss logging hook.
  final CacheLogCallback? onLog;

  /// HTTP client used to talk to the origin (inject a mock in tests).
  final http.Client? httpClient;

  /// Timeout for the origin to answer and between body packets.
  final Duration upstreamTimeout;

  /// Max number of chunks fetched by one upstream request. Bounds the amount
  /// of data downloaded for open-ended `bytes=N-` requests if the player
  /// stops reading.
  final int maxUpstreamRunChunks;

  /// Extra headers sent to the origin (auth, referer, ...). By default the
  /// player's `User-Agent` is forwarded, since several CDNs reject Dart's.
  final Map<String, String> upstreamHeaders;

  /// How long an already started response waits for a temporarily unreachable
  /// origin before giving up. While waiting the player just shows buffering
  /// and stays seekable (e.g. back into cached parts).
  final Duration maxStallDuration;

  /// What gets deleted first when the cache is full.
  final EvictionStrategy evictionStrategy;
}
