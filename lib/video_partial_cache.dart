/// Transparent progressive disk caching for MP4 / progressive video URLs.
library;

export 'src/cache/cache_stats.dart'
    show
        CacheSettings,
        CacheStats,
        CachedRange,
        CachedSpan,
        VideoCacheProgress,
        VideoCacheStats;
export 'src/cache/eviction_policy.dart' show EvictionStrategy;
export 'src/video_partial_cache_api.dart' show VideoPartialCache;
export 'src/video_partial_cache_config.dart'
    show VideoPartialCacheConfig, CacheLogCallback;
