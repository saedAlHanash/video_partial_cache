import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_partial_cache/src/cache/cache_entry.dart';
import 'package:video_partial_cache/src/cache/cache_store.dart';
import 'package:video_partial_cache/src/cache/eviction_policy.dart';

Uint8List bytes(int n, [int fill = 1]) =>
    Uint8List.fromList(List<int>.filled(n, fill));

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vpc_store_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  CacheStore newStore({int max = 1000}) =>
      CacheStore(directory: dir, maxBytes: max);

  test('write / read / hasChunk round-trip', () async {
    final s = newStore();
    await s.init();
    expect(s.hasChunk('v', 0), isFalse);
    expect(await s.readChunk('v', 0), isNull);
    expect(await s.writeChunk('v', 0, bytes(100, 7)), isTrue);
    expect(s.hasChunk('v', 0), isTrue);
    expect(s.totalBytes, 100);
    expect(await s.readChunk('v', 0), bytes(100, 7));
    await s.close();
  });

  test('persists index and lengths across restarts', () async {
    var s = newStore();
    await s.init();
    await s.setVideoInfo('v', totalLength: 12345, contentType: 'video/mp4');
    await s.writeChunk('v', 0, bytes(100));
    await s.writeChunk('v', 3, bytes(50));
    await s.close();

    s = newStore();
    await s.init();
    expect(s.totalLength('v'), 12345);
    expect(s.contentType('v'), 'video/mp4');
    expect(s.hasChunk('v', 0), isTrue);
    expect(s.hasChunk('v', 3), isTrue);
    expect(s.hasChunk('v', 1), isFalse);
    expect(s.totalBytes, 150);
    expect(await s.readChunk('v', 3), bytes(50));
    await s.close();
  });

  test('LRU eviction across videos; recently read chunk survives', () async {
    final s = newStore(max: 300);
    await s.init();
    await s.writeChunk('a', 0, bytes(100));
    await s.writeChunk('b', 0, bytes(100));
    await s.writeChunk('a', 1, bytes(100));
    // touch a#0 so b#0 becomes the least recently used
    await s.readChunk('a', 0);
    await s.writeChunk('c', 0, bytes(100));
    expect(s.totalBytes, 300);
    expect(s.hasChunk('b', 0), isFalse);
    expect(s.hasChunk('a', 0), isTrue);
    expect(s.hasChunk('a', 1), isTrue);
    expect(s.hasChunk('c', 0), isTrue);
    // file really deleted
    final bFile = File('${dir.path}/chunks/b/0.chunk');
    expect(await bFile.exists(), isFalse);
    await s.close();
  });

  test('evicts multiple chunks when a bigger chunk arrives', () async {
    final s = newStore(max: 300);
    await s.init();
    for (var i = 0; i < 3; i++) {
      await s.writeChunk('a', i, bytes(100));
    }
    expect(await s.writeChunk('b', 0, bytes(250)), isTrue);
    expect(s.totalBytes, lessThanOrEqualTo(300));
    expect(s.hasChunk('b', 0), isTrue);
    await s.close();
  });

  test('chunk larger than the whole budget is not cached', () async {
    final s = newStore(max: 100);
    await s.init();
    expect(await s.writeChunk('a', 0, bytes(101)), isFalse);
    expect(s.totalBytes, 0);
    await s.close();
  });

  test('overwriting a chunk does not double count', () async {
    final s = newStore();
    await s.init();
    await s.writeChunk('a', 0, bytes(100));
    await s.writeChunk('a', 0, bytes(100, 2));
    expect(s.totalBytes, 100);
    expect(await s.readChunk('a', 0), bytes(100, 2));
    await s.close();
  });

  test('clearVideo and clearAll', () async {
    final s = newStore();
    await s.init();
    await s.writeChunk('a', 0, bytes(100));
    await s.writeChunk('b', 0, bytes(100));
    await s.setVideoInfo('a', totalLength: 500);
    await s.clearVideo('a');
    expect(s.hasChunk('a', 0), isFalse);
    expect(s.totalLength('a'), isNull);
    expect(s.totalBytes, 100);
    expect(s.hasChunk('b', 0), isTrue);
    await s.clearAll();
    expect(s.totalBytes, 0);
    expect(s.videoStats(), isEmpty);
    await s.close();

    final s2 = newStore();
    await s2.init();
    expect(s2.totalBytes, 0);
    expect(s2.hasChunk('b', 0), isFalse);
    await s2.close();
  });

  test('missing or truncated file is dropped from the index', () async {
    final s = newStore();
    await s.init();
    await s.writeChunk('a', 0, bytes(100));
    await s.writeChunk('a', 1, bytes(100));
    await File('${dir.path}/chunks/a/0.chunk').delete();
    await File('${dir.path}/chunks/a/1.chunk').writeAsBytes(bytes(10));
    expect(await s.readChunk('a', 0), isNull);
    expect(await s.readChunk('a', 1), isNull);
    expect(s.hasChunk('a', 0), isFalse);
    expect(s.hasChunk('a', 1), isFalse);
    expect(s.totalBytes, 0);
    await s.close();
  });

  test('orphan chunk files are removed on init', () async {
    var s = newStore();
    await s.init();
    await s.writeChunk('a', 0, bytes(100));
    await s.close();
    final orphan = File('${dir.path}/chunks/a/9.chunk');
    await orphan.writeAsBytes(bytes(10));
    s = newStore();
    await s.init();
    expect(await orphan.exists(), isFalse);
    expect(s.hasChunk('a', 0), isTrue);
    await s.close();
  });

  test('changed total length invalidates stale chunks', () async {
    final s = newStore();
    await s.init();
    await s.setVideoInfo('a', totalLength: 1000);
    await s.writeChunk('a', 0, bytes(100));
    await s.setVideoInfo('a', totalLength: 2000);
    expect(s.hasChunk('a', 0), isFalse);
    expect(s.totalLength('a'), 2000);
    await s.close();
  });

  test('unsafe video ids are mapped to safe directories', () async {
    final s = newStore();
    await s.init();
    const id = 'https://x.com/a b?c=d|e';
    await s.writeChunk(id, 0, bytes(10));
    expect(await s.readChunk(id, 0), bytes(10));
    expect(safeDirName(id), startsWith('h_'));
    await s.close();
    final s2 = newStore();
    await s2.init();
    expect(s2.hasChunk(id, 0), isTrue);
    await s2.close();
  });

  test('concurrent writes keep accounting consistent', () async {
    final s = newStore(max: 500);
    await s.init();
    await Future.wait([
      for (var i = 0; i < 20; i++) s.writeChunk('v', i, bytes(100)),
    ]);
    expect(s.totalBytes, lessThanOrEqualTo(500));
    final stats = s.videoStats().single;
    expect(stats.cachedBytes, s.totalBytes);
    expect(stats.chunkCount, s.totalBytes ~/ 100);
    await s.close();
  });

  test('LruEvictionPolicy picks oldest first and honours protection', () {
    final es = [
      CacheEntry(videoId: 'a', chunkIndex: 0, size: 10, lastAccess: 3),
      CacheEntry(videoId: 'a', chunkIndex: 1, size: 10, lastAccess: 1),
      CacheEntry(videoId: 'b', chunkIndex: 0, size: 10, lastAccess: 2),
    ];
    const lru = LruEvictionPolicy();
    expect(lru.selectVictims(es, 15).map((e) => e.lastAccess), [1, 2]);
    expect(lru.selectVictims(es, 0), isEmpty);
    expect(
      lru
          .selectVictims(es, 10, isProtected: (e) => e.lastAccess == 1)
          .map((e) => e.lastAccess),
      [2],
    );
  });
}
