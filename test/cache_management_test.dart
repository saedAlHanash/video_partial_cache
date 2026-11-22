import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video_partial_cache/src/cache/cache_entry.dart';
import 'package:video_partial_cache/src/cache/cache_store.dart';
import 'package:video_partial_cache/src/cache/eviction_policy.dart';
import 'package:video_partial_cache/video_partial_cache.dart';

Uint8List bytes(int n, [int fill = 1]) =>
    Uint8List.fromList(List<int>.filled(n, fill));

CacheEntry entry(
  String v,
  int i, {
  int size = 10,
  int last = 0,
  int created = 0,
  int hits = 0,
}) => CacheEntry(
  videoId: v,
  chunkIndex: i,
  size: size,
  lastAccess: last,
  createdAt: created,
  hits: hits,
);

void main() {
  group('eviction policies', () {
    test('LFU: fewest hits first, ties by recency', () {
      final es = [
        entry('a', 0, hits: 5, last: 1),
        entry('b', 0, hits: 1, last: 9),
        entry('c', 0, hits: 1, last: 3),
      ];
      final v = const LfuEvictionPolicy().selectVictims(es, 15);
      expect(v.map((e) => e.videoId), ['c', 'b']);
    });

    test('FIFO: oldest created first regardless of use', () {
      final es = [
        entry('a', 0, created: 5, last: 1),
        entry('b', 0, created: 1, last: 100),
        entry('c', 0, created: 3, last: 50),
      ];
      final v = const FifoEvictionPolicy().selectVictims(es, 15);
      expect(v.map((e) => e.videoId), ['b', 'c']);
    });

    test('LRU-video: evicts a whole video before touching the next', () {
      final es = [
        entry('old', 0, last: 1),
        entry('old', 1, last: 2),
        entry('old', 2, last: 3),
        entry('new', 0, last: 10),
      ];
      // Only 5 bytes needed, but the whole "old" video goes.
      final v = const LruVideoEvictionPolicy().selectVictims(es, 5);
      expect(v.map((e) => e.videoId).toSet(), {'old'});
      expect(v, hasLength(3));
    });

    test('protected entries are never selected by any policy', () {
      for (final s in EvictionStrategy.values) {
        final es = [entry('pin', 0, last: 1), entry('x', 0, last: 2)];
        final v = s.policy.selectVictims(
          es,
          100,
          isProtected: (e) => e.videoId == 'pin',
        );
        expect(v.map((e) => e.videoId), ['x'], reason: '$s');
      }
    });
  });

  group('CacheStore management', () {
    late Directory dir;
    var now = DateTime(2026, 1, 1);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('vpc_mgmt_test');
      now = DateTime(2026, 1, 1);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    CacheStore newStore({int max = 1000, EvictionStrategy? s}) => CacheStore(
      directory: dir,
      maxBytes: max,
      strategy: s ?? EvictionStrategy.lru,
      clock: () => now,
    );

    test('lowering the limit trims immediately; raising keeps data', () async {
      final s = newStore(max: 1000);
      await s.init();
      for (var i = 0; i < 5; i++) {
        await s.writeChunk('v', i, bytes(100));
      }
      expect(s.totalBytes, 500);
      expect(await s.setMaxBytes(2000), 0);
      expect(s.totalBytes, 500);
      final freed = await s.setMaxBytes(300);
      expect(freed, 200);
      expect(s.totalBytes, 300);
      // new limit is enforced for writes too
      await s.writeChunk('v', 9, bytes(100));
      expect(s.totalBytes, lessThanOrEqualTo(300));
      await s.close();
    });

    test('strategy switch changes who is evicted', () async {
      final s = newStore(max: 300, s: EvictionStrategy.lru);
      await s.init();
      await s.writeChunk('a', 0, bytes(100));
      await s.writeChunk('b', 0, bytes(100));
      await s.writeChunk('c', 0, bytes(100));
      // a is used a lot but is the least recently touched below.
      for (var i = 0; i < 5; i++) {
        await s.readChunk('a', 0);
      }
      await s.readChunk('b', 0);
      await s.readChunk('c', 0);
      // LRU would evict a (oldest touch); LFU keeps it (most hits).
      s.setStrategy(EvictionStrategy.lfu);
      await s.writeChunk('d', 0, bytes(100));
      expect(s.hasChunk('a', 0), isTrue);
      expect(s.hasChunk('b', 0) && s.hasChunk('c', 0), isFalse);
      await s.close();
    });

    test('pinned video survives eviction and trimming', () async {
      final s = newStore(max: 300);
      await s.init();
      await s.writeChunk('keep', 0, bytes(100));
      await s.setPinned('keep', true);
      await s.writeChunk('x', 0, bytes(100));
      await s.writeChunk('y', 0, bytes(100));
      await s.writeChunk('z', 0, bytes(100)); // forces eviction
      expect(s.hasChunk('keep', 0), isTrue);
      await s.trimTo(100);
      expect(s.hasChunk('keep', 0), isTrue);
      expect(s.totalBytes, 100);
      // everything pinned + full => new chunk cannot be cached
      await s.setPinned('keep', true);
      final s2 = newStore(max: 100);
      await s.close();
      await s2.init();
      expect(await s2.writeChunk('other', 0, bytes(100)), isFalse);
      expect(s2.hasChunk('keep', 0), isTrue);
      await s2.close();
    });

    test('title and pin persist across restarts, with stats', () async {
      var s = newStore();
      await s.init();
      await s.writeChunk('v', 0, bytes(50));
      await s.setTitle('v', 'Lesson 1');
      await s.setPinned('v', true);
      await s.readChunk('v', 0);
      await s.close();

      s = newStore();
      await s.init();
      final st = s.videoStats().single;
      expect(st.title, 'Lesson 1');
      expect(st.pinned, isTrue);
      expect(st.hits, greaterThanOrEqualTo(1));
      expect(st.lastAccess, isNotNull);
      await s.close();
    });

    test('hits and createdAt persist (index rows have 4 fields)', () async {
      var s = newStore();
      await s.init();
      await s.writeChunk('v', 0, bytes(10));
      await s.readChunk('v', 0);
      await s.readChunk('v', 0);
      await s.close();
      s = newStore();
      await s.init();
      expect(s.videoStats().single.hits, 2);
      await s.close();
    });

    test('evictOlderThan removes only stale, unpinned videos', () async {
      final s = newStore();
      await s.init();
      await s.writeChunk('old', 0, bytes(100));
      await s.writeChunk('oldpin', 0, bytes(100));
      await s.setPinned('oldpin', true);
      now = now.add(const Duration(days: 10));
      await s.writeChunk('fresh', 0, bytes(100));
      final freed = await s.evictOlderThan(const Duration(days: 7));
      expect(freed, 100);
      expect(s.hasChunk('old', 0), isFalse);
      expect(s.hasChunk('oldpin', 0), isTrue);
      expect(s.hasChunk('fresh', 0), isTrue);
      await s.close();
    });

    test('stale-length reset keeps title and pin', () async {
      final s = newStore();
      await s.init();
      await s.setVideoInfo('v', totalLength: 1000);
      await s.setTitle('v', 'T');
      await s.setPinned('v', true);
      await s.writeChunk('v', 0, bytes(10));
      await s.setVideoInfo('v', totalLength: 2000);
      expect(s.hasChunk('v', 0), isFalse);
      expect(s.title('v'), 'T');
      expect(s.isPinned('v'), isTrue);
      await s.close();
    });
  });

  group('VideoPartialCache management API', () {
    const total = 4000;
    final data = Uint8List.fromList(
      List<int>.generate(total, (i) => (i * 7) % 251),
    );
    late Directory dir;
    late VideoPartialCache cache;
    final seenHeaders = <Map<String, String>>[];

    final client = MockClient.streaming((req, _) async {
      seenHeaders.add(req.headers);
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(req.headers['range']!)!;
      final s = int.parse(m.group(1)!);
      final e = int.parse(m.group(2)!).clamp(0, total - 1);
      return http.StreamedResponse(
        Stream.value(data.sublist(s, e + 1)),
        206,
        contentLength: e - s + 1,
        headers: {'content-range': 'bytes $s-$e/$total'},
      );
    });

    Future<void> play(String url) async {
      final c = HttpClient();
      final r = await (await c.getUrl(Uri.parse(url))).close();
      await r.drain<void>();
      c.close();
      await cache.debugWaitForIdle();
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('vpc_api_test');
      seenHeaders.clear();
      cache = VideoPartialCache(
        chunkSizeBytes: 1000,
        maxCacheSizeBytes: 10000,
        cacheDirectory: dir,
        httpClient: client,
        upstreamHeaders: {'x-token': 'abc'},
        evictionStrategy: EvictionStrategy.lfu,
      );
      await cache.init();
    });

    tearDown(() async {
      await cache.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test(
      'settings, updateSettings and stats reflect runtime changes',
      () async {
        expect(cache.settings.maxCacheSizeBytes, 10000);
        expect(cache.settings.strategy, EvictionStrategy.lfu);
        await play(
          cache.getPlayableUrl(
            'https://o.test/v.mp4',
            videoId: 'v',
            title: 'My video',
          ),
        );
        expect(await cache.getCacheSizeBytes(), total);
        final freed = await cache.updateSettings(
          maxCacheSizeBytes: 2000,
          strategy: EvictionStrategy.fifo,
        );
        expect(freed, 2000);
        final stats = await cache.getStats();
        expect(stats.maxBytes, 2000);
        expect(stats.strategy, EvictionStrategy.fifo);
        expect(stats.totalBytes, 2000);
        expect(stats.videos.single.title, 'My video');
      },
    );

    test('custom upstream headers reach the origin', () async {
      await play(cache.getPlayableUrl('https://o.test/v.mp4', videoId: 'v'));
      expect(seenHeaders, isNotEmpty);
      expect(seenHeaders.every((h) => h['x-token'] == 'abc'), isTrue);
    });

    test('pin, trimTo and clearVideosOlderThan', () async {
      await play(cache.getPlayableUrl('https://o.test/a.mp4', videoId: 'a'));
      await play(cache.getPlayableUrl('https://o.test/b.mp4', videoId: 'b'));
      await cache.setPinned('a', true);
      expect(
        (await cache.getStats()).videos
            .firstWhere((v) => v.videoId == 'a')
            .pinned,
        isTrue,
      );
      await cache.trimTo(0);
      expect(await cache.getCacheSizeBytes(), total); // only pinned 'a' left
      expect(await cache.clearVideosOlderThan(Duration.zero), 0); // pinned
      await cache.setPinned('a', false);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await cache.clearVideosOlderThan(Duration.zero), total);
      expect(await cache.getCacheSizeBytes(), 0);
    });
  });
}
