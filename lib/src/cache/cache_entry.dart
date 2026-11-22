/// Metadata of a single cached chunk file.
class CacheEntry {
  CacheEntry({
    required this.videoId,
    required this.chunkIndex,
    required this.size,
    required this.lastAccess,
    int? createdAt,
    this.hits = 0,
  }) : createdAt = createdAt ?? lastAccess;

  final String videoId;
  final int chunkIndex;

  /// Size of the chunk file in bytes.
  final int size;

  /// When the chunk was written, milliseconds since epoch.
  final int createdAt;

  /// Last read/write time, milliseconds since epoch.
  int lastAccess;

  /// How many times the chunk was served from disk.
  int hits;

  @override
  String toString() =>
      'CacheEntry($videoId#$chunkIndex, $size B, lastAccess=$lastAccess, hits=$hits)';
}
