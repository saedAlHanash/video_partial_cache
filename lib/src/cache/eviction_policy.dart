import 'cache_entry.dart';

/// Built-in eviction strategies (selectable at runtime).
enum EvictionStrategy {
  /// Least recently used chunk first (default). Best general purpose.
  lru,

  /// Least frequently used chunk first (ties: least recently used). Keeps
  /// videos that are replayed often.
  lfu,

  /// Oldest written chunk first, regardless of use.
  fifo,

  /// Whole videos at a time: the least recently played video is removed
  /// completely before touching any other. Avoids many half-cached videos.
  lruVideo;

  /// The policy implementing this strategy.
  EvictionPolicy get policy => switch (this) {
    EvictionStrategy.lru => const LruEvictionPolicy(),
    EvictionStrategy.lfu => const LfuEvictionPolicy(),
    EvictionStrategy.fifo => const FifoEvictionPolicy(),
    EvictionStrategy.lruVideo => const LruVideoEvictionPolicy(),
  };
}

/// Decides which chunks to delete when the cache is over budget.
abstract class EvictionPolicy {
  const EvictionPolicy();

  /// Returns entries to evict so that at least [bytesToFree] bytes are freed
  /// (or as many as possible). Entries for which [isProtected] returns true
  /// must never be returned.
  List<CacheEntry> selectVictims(
    Iterable<CacheEntry> entries,
    int bytesToFree, {
    bool Function(CacheEntry entry)? isProtected,
  });
}

/// Shared helper: take entries in [order] until [bytesToFree] is reached.
List<CacheEntry> _takeUntilFreed(
  Iterable<CacheEntry> entries,
  int bytesToFree,
  int Function(CacheEntry a, CacheEntry b) order,
  bool Function(CacheEntry entry)? isProtected,
) {
  if (bytesToFree <= 0) return const [];
  final candidates =
      entries.where((e) => isProtected == null || !isProtected(e)).toList()
        ..sort(order);
  final victims = <CacheEntry>[];
  var freed = 0;
  for (final e in candidates) {
    if (freed >= bytesToFree) break;
    victims.add(e);
    freed += e.size;
  }
  return victims;
}

int _tieBreak(CacheEntry a, CacheEntry b) {
  // Deterministic; evict later chunks first within a video.
  final byVideo = a.videoId.compareTo(b.videoId);
  if (byVideo != 0) return byVideo;
  return b.chunkIndex.compareTo(a.chunkIndex);
}

/// Least-recently-used eviction across the whole cache (all videos).
class LruEvictionPolicy extends EvictionPolicy {
  const LruEvictionPolicy();

  @override
  List<CacheEntry> selectVictims(
    Iterable<CacheEntry> entries,
    int bytesToFree, {
    bool Function(CacheEntry entry)? isProtected,
  }) => _takeUntilFreed(entries, bytesToFree, (a, b) {
    final c = a.lastAccess.compareTo(b.lastAccess);
    return c != 0 ? c : _tieBreak(a, b);
  }, isProtected);
}

/// Least-frequently-used eviction (ties broken by recency).
class LfuEvictionPolicy extends EvictionPolicy {
  const LfuEvictionPolicy();

  @override
  List<CacheEntry> selectVictims(
    Iterable<CacheEntry> entries,
    int bytesToFree, {
    bool Function(CacheEntry entry)? isProtected,
  }) => _takeUntilFreed(entries, bytesToFree, (a, b) {
    var c = a.hits.compareTo(b.hits);
    if (c != 0) return c;
    c = a.lastAccess.compareTo(b.lastAccess);
    return c != 0 ? c : _tieBreak(a, b);
  }, isProtected);
}

/// First-in-first-out: oldest written chunk goes first.
class FifoEvictionPolicy extends EvictionPolicy {
  const FifoEvictionPolicy();

  @override
  List<CacheEntry> selectVictims(
    Iterable<CacheEntry> entries,
    int bytesToFree, {
    bool Function(CacheEntry entry)? isProtected,
  }) => _takeUntilFreed(entries, bytesToFree, (a, b) {
    final c = a.createdAt.compareTo(b.createdAt);
    return c != 0 ? c : _tieBreak(a, b);
  }, isProtected);
}

/// Evicts whole videos, least recently played video first.
class LruVideoEvictionPolicy extends EvictionPolicy {
  const LruVideoEvictionPolicy();

  @override
  List<CacheEntry> selectVictims(
    Iterable<CacheEntry> entries,
    int bytesToFree, {
    bool Function(CacheEntry entry)? isProtected,
  }) {
    if (bytesToFree <= 0) return const [];
    final byVideo = <String, List<CacheEntry>>{};
    for (final e in entries) {
      if (isProtected != null && isProtected(e)) continue;
      byVideo.putIfAbsent(e.videoId, () => []).add(e);
    }
    int recency(List<CacheEntry> l) =>
        l.fold(0, (m, e) => e.lastAccess > m ? e.lastAccess : m);
    final videos = byVideo.entries.toList()
      ..sort((a, b) {
        final c = recency(a.value).compareTo(recency(b.value));
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final victims = <CacheEntry>[];
    var freed = 0;
    for (final v in videos) {
      if (freed >= bytesToFree) break;
      for (final e in v.value) {
        victims.add(e);
        freed += e.size;
      }
    }
    return victims;
  }
}
