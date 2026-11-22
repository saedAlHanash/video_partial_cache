// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

import 'cache_entry.dart';
import 'cache_stats.dart';
import 'eviction_policy.dart';

class _VideoMeta {
  int? totalLength;
  String? contentType;
  String? title;
  bool pinned = false;
  final Map<int, CacheEntry> chunks = {};
  int bytes = 0;

  int get lastAccess =>
      chunks.values.fold(0, (m, e) => e.lastAccess > m ? e.lastAccess : m);

  Map<String, Object?> toJson() => {
    't': totalLength,
    'c': contentType,
    'n': title,
    'p': pinned,
  };
}

/// Chunk metadata index (Hive, in-memory mirror) + chunk file IO.
///
/// Layout on disk:
/// ```
/// <root>/index/            Hive box (chunk index, video lengths)
/// <root>/chunks/<video>/<n>.chunk
/// ```
///
/// Why Hive: the access pattern is "load everything at startup, then tiny
/// key/value upserts". Hive is pure Dart (no platform channel), append-only
/// and fast for that; sqflite would add a native dependency for no benefit.
/// `lastAccess` touches are kept in memory and flushed in batches.
class CacheStore {
  CacheStore({
    required this.directory,
    required int maxBytes,
    EvictionStrategy strategy = EvictionStrategy.lru,
    DateTime Function()? clock,
    this.flushInterval = const Duration(seconds: 5),
  }) : _maxBytes = maxBytes,
       _strategy = strategy,
       _clock = clock ?? DateTime.now;

  final Directory directory;
  final Duration flushInterval;
  int _maxBytes;
  EvictionStrategy _strategy;
  final DateTime Function() _clock;

  final Map<String, _VideoMeta> _videos = {};
  final Set<CacheEntry> _dirty = {};
  Box<dynamic>? _box;
  Timer? _flushTimer;
  int _totalBytes = 0;
  int _lastTick = 0;
  Future<void> _lock = Future<void>.value();

  int get maxBytes => _maxBytes;
  EvictionStrategy get strategy => _strategy;
  EvictionPolicy get _policy => _strategy.policy;

  bool get isOpen => _box != null;
  int get totalBytes => _totalBytes;

  Directory get _chunksDir => Directory(p.join(directory.path, 'chunks'));

  // ---------------------------------------------------------------- init --

  Future<void> init() async {
    if (_box != null) return;
    final indexDir = Directory(p.join(directory.path, 'index'));
    await indexDir.create(recursive: true);
    await _chunksDir.create(recursive: true);
    final name =
        'vpc_${sha1.convert(utf8.encode(directory.path)).toString().substring(0, 12)}';
    final box = await Hive.openBox<dynamic>(name, path: indexDir.path);
    _box = box;

    for (final key in box.keys.cast<String>()) {
      final value = box.get(key);
      if (key.startsWith('m|')) {
        final meta = _metaFor(key.substring(2));
        if (value is Map) {
          meta.totalLength = value['t'] as int?;
          meta.contentType = value['c'] as String?;
          meta.title = value['n'] as String?;
          meta.pinned = value['p'] == true;
        }
      } else if (key.startsWith('c|') && value is List) {
        final cut = key.lastIndexOf('|');
        final videoId = key.substring(2, cut);
        final idx = int.parse(key.substring(cut + 1));
        final entry = CacheEntry(
          videoId: videoId,
          chunkIndex: idx,
          size: value[0] as int,
          lastAccess: value[1] as int,
          createdAt: value.length > 2 ? value[2] as int : null,
          hits: value.length > 3 ? value[3] as int : 0,
        );
        final meta = _metaFor(videoId);
        meta.chunks[idx] = entry;
        meta.bytes += entry.size;
        _totalBytes += entry.size;
        if (entry.lastAccess > _lastTick) _lastTick = entry.lastAccess;
      }
    }
    await _removeOrphanFiles();
    _flushTimer = Timer.periodic(flushInterval, (_) => flush());
  }

  /// Deletes chunk files that are not in the index (e.g. crash mid-write).
  Future<void> _removeOrphanFiles() async {
    final known = <String>{
      for (final e in _videos.entries)
        for (final idx in e.value.chunks.keys)
          p.join(_chunksDir.path, safeDirName(e.key), '$idx.chunk'),
    };
    try {
      await for (final f in _chunksDir.list(recursive: true)) {
        if (f is File && !known.contains(f.path)) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // --------------------------------------------------------------- query --

  int? totalLength(String videoId) => _videos[videoId]?.totalLength;
  String? contentType(String videoId) => _videos[videoId]?.contentType;

  /// Indexes of the chunks currently on disk for [videoId].
  List<int> chunkIndexes(String videoId) =>
      _videos[videoId]?.chunks.keys.toList() ?? const [];

  bool hasChunk(String videoId, int index) =>
      _videos[videoId]?.chunks.containsKey(index) ?? false;

  String? title(String videoId) => _videos[videoId]?.title;
  bool isPinned(String videoId) => _videos[videoId]?.pinned ?? false;

  Future<void> setVideoInfo(
    String videoId, {
    required int totalLength,
    String? contentType,
  }) async {
    final meta = _metaFor(videoId);
    if (meta.totalLength == totalLength &&
        (contentType == null || meta.contentType == contentType)) {
      return;
    }
    String? keepTitle;
    var keepPinned = false;
    if (meta.totalLength != null && meta.totalLength != totalLength) {
      // The origin file changed: drop stale chunks (keep user metadata).
      keepTitle = meta.title;
      keepPinned = meta.pinned;
      await clearVideo(videoId);
    }
    final m = _metaFor(videoId);
    m.totalLength = totalLength;
    m.contentType = contentType ?? m.contentType;
    m.title ??= keepTitle;
    m.pinned = m.pinned || keepPinned;
    await _box?.put('m|$videoId', m.toJson());
  }

  /// Sets the display name of a video (no-op if unchanged).
  Future<void> setTitle(String videoId, String? title) async {
    final m = _metaFor(videoId);
    if (m.title == title) return;
    m.title = title;
    await _box?.put('m|$videoId', m.toJson());
  }

  /// Pinned videos are skipped by every eviction run.
  Future<void> setPinned(String videoId, bool pinned) async {
    final m = _metaFor(videoId);
    if (m.pinned == pinned) return;
    m.pinned = pinned;
    await _box?.put('m|$videoId', m.toJson());
  }

  bool _isProtected(CacheEntry e) => _videos[e.videoId]?.pinned ?? false;

  /// Changes the budget and immediately evicts down to it.
  Future<int> setMaxBytes(int bytes) {
    if (bytes <= 0) throw ArgumentError.value(bytes, 'bytes');
    _maxBytes = bytes;
    return trimTo(bytes);
  }

  void setStrategy(EvictionStrategy strategy) => _strategy = strategy;

  /// Evicts (with the active strategy; pinned videos excluded) until at most
  /// [targetBytes] are used. Returns the number of bytes freed.
  Future<int> trimTo(int targetBytes) {
    return _synchronized(() async {
      final before = _totalBytes;
      final over = _totalBytes - targetBytes;
      if (over > 0) {
        final victims = _policy.selectVictims(
          _videos.values.expand((m) => m.chunks.values),
          over,
          isProtected: _isProtected,
        );
        for (final v in victims) {
          await _removeEntry(v, deleteFile: true);
        }
        await _dropEmptyVideoDirs();
      }
      return before - _totalBytes;
    });
  }

  /// Removes every non-pinned video not played for [age]. Returns bytes freed.
  Future<int> evictOlderThan(Duration age) {
    final cutoff = _clock().subtract(age).millisecondsSinceEpoch;
    return _synchronized(() async {
      final before = _totalBytes;
      final stale = [
        for (final e in _videos.entries)
          if (!e.value.pinned &&
              e.value.chunks.isNotEmpty &&
              e.value.lastAccess < cutoff)
            e.key,
      ];
      for (final id in stale) {
        await _clearVideoLocked(id);
      }
      return before - _totalBytes;
    });
  }

  Future<void> _dropEmptyVideoDirs() async {
    for (final e in _videos.entries) {
      if (e.value.chunks.isEmpty) await _deleteDir(_videoDir(e.key));
    }
  }

  // ------------------------------------------------------------------ IO --

  /// Reads a chunk, or null if absent/corrupt (the index entry is dropped
  /// when the file is missing or has the wrong size).
  ///
  /// [touch] = false reads without counting as a use (no LRU/LFU update),
  /// e.g. for inspecting the cache from a settings screen.
  Future<Uint8List?> readChunk(
    String videoId,
    int index, {
    bool touch = true,
  }) async {
    final entry = _videos[videoId]?.chunks[index];
    if (entry == null) return null;
    try {
      final bytes = await _chunkFile(videoId, index).readAsBytes();
      if (bytes.length != entry.size) {
        await _synchronized(() => _removeEntry(entry, deleteFile: true));
        return null;
      }
      if (touch) _touch(entry);
      return bytes;
    } on FileSystemException {
      await _synchronized(() => _removeEntry(entry, deleteFile: false));
      return null;
    }
  }

  /// Persists a chunk, evicting least-recently-used chunks first if the
  /// budget would be exceeded. Returns false if it could not be cached.
  Future<bool> writeChunk(String videoId, int index, Uint8List bytes) {
    return _synchronized(() async {
      if (_box == null || bytes.isEmpty || bytes.length > _maxBytes) {
        return false;
      }
      final old = _videos[videoId]?.chunks[index];
      if (old != null) await _removeEntry(old, deleteFile: false);

      final overflow = _totalBytes + bytes.length - _maxBytes;
      if (overflow > 0) {
        final victims = _policy.selectVictims(
          _videos.values.expand((m) => m.chunks.values),
          overflow,
          isProtected: _isProtected,
        );
        for (final v in victims) {
          await _removeEntry(v, deleteFile: true);
        }
        if (_totalBytes + bytes.length > _maxBytes) return false;
      }

      final file = _chunkFile(videoId, index);
      try {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
      } on FileSystemException {
        return false;
      }
      final entry = CacheEntry(
        videoId: videoId,
        chunkIndex: index,
        size: bytes.length,
        lastAccess: _tick(),
      );
      final meta = _metaFor(videoId);
      meta.chunks[index] = entry;
      meta.bytes += entry.size;
      _totalBytes += entry.size;
      await _box!.put('c|$videoId|$index', _row(entry));
      return true;
    });
  }

  Future<void> clearVideo(String videoId) =>
      _synchronized(() => _clearVideoLocked(videoId));

  Future<void> _clearVideoLocked(String videoId) async {
    final meta = _videos.remove(videoId);
    if (meta == null) return;
    _totalBytes -= meta.bytes;
    _dirty.removeWhere((e) => e.videoId == videoId);
    await _box?.deleteAll([
      'm|$videoId',
      for (final i in meta.chunks.keys) 'c|$videoId|$i',
    ]);
    await _deleteDir(_videoDir(videoId));
  }

  Future<void> clearAll() {
    return _synchronized(() async {
      _videos.clear();
      _dirty.clear();
      _totalBytes = 0;
      await _box?.clear();
      await _deleteDir(_chunksDir);
      await _chunksDir.create(recursive: true);
    });
  }

  /// Writes pending `lastAccess` updates to Hive.
  Future<void> flush() async {
    final box = _box;
    if (box == null || _dirty.isEmpty) return;
    final batch = _dirty.toList();
    _dirty.clear();
    await box.putAll({
      for (final e in batch)
        if (_videos[e.videoId]?.chunks[e.chunkIndex] == e)
          'c|${e.videoId}|${e.chunkIndex}': _row(e),
    });
  }

  Future<void> close() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _synchronized(() async {
      await flush();
      await _box?.close();
      _box = null;
    });
  }

  List<VideoCacheStats> videoStats() => [
    for (final e in _videos.entries)
      if (e.value.chunks.isNotEmpty || e.value.totalLength != null)
        VideoCacheStats(
          videoId: e.key,
          cachedBytes: e.value.bytes,
          chunkCount: e.value.chunks.length,
          totalLength: e.value.totalLength,
          title: e.value.title,
          pinned: e.value.pinned,
          lastAccess: e.value.chunks.isEmpty
              ? null
              : DateTime.fromMillisecondsSinceEpoch(e.value.lastAccess),
          hits: e.value.chunks.values.fold(0, (n, c) => n + c.hits),
        ),
  ]..sort((a, b) => b.cachedBytes.compareTo(a.cachedBytes));

  // ------------------------------------------------------------- helpers --

  _VideoMeta _metaFor(String videoId) =>
      _videos.putIfAbsent(videoId, _VideoMeta.new);

  static List<int> _row(CacheEntry e) => [
    e.size,
    e.lastAccess,
    e.createdAt,
    e.hits,
  ];

  void _touch(CacheEntry e) {
    e.lastAccess = _tick();
    e.hits++;
    _dirty.add(e);
  }

  /// Strictly increasing timestamp so LRU order is deterministic.
  int _tick() {
    final now = _clock().millisecondsSinceEpoch;
    _lastTick = now > _lastTick ? now : _lastTick + 1;
    return _lastTick;
  }

  Future<void> _removeEntry(CacheEntry e, {required bool deleteFile}) async {
    final meta = _videos[e.videoId];
    if (meta == null || meta.chunks[e.chunkIndex] != e) return;
    meta.chunks.remove(e.chunkIndex);
    meta.bytes -= e.size;
    _totalBytes -= e.size;
    _dirty.remove(e);
    await _box?.delete('c|${e.videoId}|${e.chunkIndex}');
    if (deleteFile) {
      try {
        await _chunkFile(e.videoId, e.chunkIndex).delete();
      } catch (_) {}
    }
  }

  Future<void> _deleteDir(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  Directory _videoDir(String videoId) =>
      Directory(p.join(_chunksDir.path, safeDirName(videoId)));

  File _chunkFile(String videoId, int index) =>
      File(p.join(_videoDir(videoId).path, '$index.chunk'));

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }
}

final RegExp _safeName = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Directory name for a video id: the id itself when it is filesystem-safe,
/// otherwise a stable hash.
String safeDirName(String videoId) => _safeName.hasMatch(videoId)
    ? videoId
    : 'h_${sha1.convert(utf8.encode(videoId)).toString()}';

/// Stable id derived from a URL (hex SHA-1).
String stableVideoId(String url) => sha1.convert(utf8.encode(url)).toString();
