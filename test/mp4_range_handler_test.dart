import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video_partial_cache/video_partial_cache.dart';

const cs = 1000;
const total = 10500; // 10 full chunks + a 500 byte last chunk
const url = 'https://origin.test/video.mp4';

final Uint8List data = Uint8List.fromList(
  List<int>.generate(total, (i) => (i * 7 + 3) % 251),
);

/// Fake byte-range origin that records every request it receives.
class FakeOrigin {
  final List<String> ranges = [];
  final List<Map<String, String>> headers = [];
  bool supportsRange = true;
  int? failWithStatus;
  bool unreachable = false;
  Duration delay = Duration.zero;
  Uint8List body = data;

  late final MockClient client = MockClient.streaming((req, _) async {
    ranges.add(req.headers['range'] ?? 'none');
    headers.add(req.headers);
    if (unreachable) throw const SocketException('unreachable');
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (failWithStatus != null) {
      return http.StreamedResponse(const Stream.empty(), failWithStatus!);
    }
    final rh = req.headers['range'];
    if (!supportsRange || rh == null) {
      return http.StreamedResponse(
        Stream.value(body),
        200,
        contentLength: body.length,
        headers: {'content-type': 'video/mp4'},
      );
    }
    final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rh)!;
    final s = int.parse(m.group(1)!);
    final e = int.parse(m.group(2)!).clamp(0, body.length - 1);
    final slice = body.sublist(s, e + 1);
    // deliver in small packets to exercise chunk re-assembly
    Stream<List<int>> packets() async* {
      for (var o = 0; o < slice.length; o += 333) {
        yield slice.sublist(o, (o + 333).clamp(0, slice.length));
      }
    }

    return http.StreamedResponse(
      packets(),
      206,
      contentLength: slice.length,
      headers: {
        'content-range': 'bytes $s-$e/${body.length}',
        'content-type': 'video/mp4',
      },
    );
  });
}

class Resp {
  Resp(this.status, this.headers, this.body);
  final int status;
  final HttpHeaders headers;
  final Uint8List body;
}

VideoPartialCache? current;

Future<Resp> fetch(
  String playable, {
  String? range,
  String method = 'GET',
}) async {
  final c = HttpClient();
  try {
    final req = await c.openUrl(method, Uri.parse(playable));
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final b = BytesBuilder();
    await for (final d in res) {
      b.add(d);
    }
    final resp = Resp(res.statusCode, res.headers, b.takeBytes());
    await current?.debugWaitForIdle(); // let the background disk write finish
    return resp;
  } finally {
    c.close(force: true);
  }
}

void main() {
  late Directory dir;
  late FakeOrigin origin;
  late VideoPartialCache cache;
  late List<String> logs;

  Future<VideoPartialCache> make({int max = 100 * 1024 * 1024}) async {
    final c = VideoPartialCache(
      chunkSizeBytes: cs,
      maxCacheSizeBytes: max,
      cacheDirectory: dir,
      httpClient: origin.client,
      upstreamTimeout: const Duration(seconds: 5),
      onLog: logs.add,
    );
    await c.init();
    current = c;
    return c;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vpc_handler_test');
    origin = FakeOrigin();
    logs = [];
    cache = await make();
  });

  tearDown(() async {
    await cache.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('getPlayableUrl shape and stable default id', () {
    final u = cache.getPlayableUrl(url);
    final uri = Uri.parse(u);
    expect(uri.host, '127.0.0.1');
    expect(uri.pathSegments.first, 'proxy');
    expect(uri.queryParameters['src'], url);
    expect(cache.getPlayableUrl(url), u);
    expect(cache.getPlayableUrl(url, videoId: 'abc'), contains('/proxy/abc?'));
  });

  test(
    'range request: correct bytes and headers, then served from disk',
    () async {
      final u = cache.getPlayableUrl(url, videoId: 'v');
      final r = await fetch(u, range: 'bytes=1500-2600');
      expect(r.status, 206);
      expect(r.headers.value('content-range'), 'bytes 1500-2600/$total');
      expect(r.headers.value('content-length'), '1101');
      expect(r.headers.value('accept-ranges'), 'bytes');
      expect(r.body, data.sublist(1500, 2601));
      expect(logs.any((l) => l.startsWith('MISS')), isTrue);

      final before = origin.ranges.length;
      final r2 = await fetch(u, range: 'bytes=1500-2600');
      expect(r2.body, data.sublist(1500, 2601));
      expect(origin.ranges.length, before, reason: 'no network on replay');
      expect(logs.any((l) => l.startsWith('HIT')), isTrue);

      final stats = await cache.getStats();
      expect(stats.hitChunks, greaterThan(0));
      expect(stats.missChunks, greaterThan(0));
      expect(stats.videos.single.videoId, 'v');
      expect(stats.videos.single.totalLength, total);
    },
  );

  test('no Range header serves the whole file with 200', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    final r = await fetch(u);
    expect(r.status, 200);
    expect(r.headers.value('content-length'), '$total');
    expect(r.body, data);
    expect(await cache.getCacheSizeBytes(), total);
  });

  test('open-ended range incl. short last chunk', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    final r = await fetch(u, range: 'bytes=10000-');
    expect(r.status, 206);
    expect(r.headers.value('content-range'), 'bytes 10000-10499/$total');
    expect(r.body, data.sublist(10000));
    final r2 = await fetch(u, range: 'bytes=500-');
    expect(r2.body, data.sublist(500));
    final r3 = await fetch(u, range: 'bytes=-700');
    expect(r3.headers.value('content-range'), 'bytes 9800-10499/$total');
    expect(r3.body, data.sublist(9800));
  });

  test('HEAD returns length without body', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    final r = await fetch(u, method: 'HEAD');
    expect(r.status, 200);
    expect(r.headers.value('content-length'), '$total');
    expect(r.body, isEmpty);
  });

  test('missing chunks are merged into few upstream requests', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    await fetch(u, range: 'bytes=0-0'); // learns length, caches chunk 0
    origin.ranges.clear();
    final r = await fetch(u, range: 'bytes=1000-5999'); // chunks 1..5
    expect(r.body, data.sublist(1000, 6000));
    expect(origin.ranges, ['bytes=1000-5999']);
  });

  test('only gaps are fetched when partially cached', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    await fetch(u, range: 'bytes=0-1999'); // chunks 0,1
    await fetch(u, range: 'bytes=4000-4999'); // chunk 4
    origin.ranges.clear();
    final r = await fetch(u, range: 'bytes=0-5999'); // 0..5
    expect(r.body, data.sublist(0, 6000));
    expect(origin.ranges, ['bytes=2000-3999', 'bytes=5000-5999']);
    expect(logs.any((l) => l.startsWith('PART')), isTrue);
  });

  test('concurrent overlapping requests share one fetch per chunk', () async {
    origin.delay = const Duration(milliseconds: 30);
    final u = cache.getPlayableUrl(url, videoId: 'v');
    await fetch(u, range: 'bytes=0-0'); // learn length
    origin.ranges.clear();
    final results = await Future.wait([
      fetch(u, range: 'bytes=2000-4999'),
      fetch(u, range: 'bytes=3000-5999'),
      fetch(u, range: 'bytes=2500-3500'),
    ]);
    expect(results[0].body, data.sublist(2000, 5000));
    expect(results[1].body, data.sublist(3000, 6000));
    expect(results[2].body, data.sublist(2500, 3501));
    // every chunk 2..5 requested from the origin exactly once
    final covered = <int>[];
    for (final r in origin.ranges) {
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(r)!;
      for (
        var c = int.parse(m.group(1)!) ~/ cs;
        c <= int.parse(m.group(2)!) ~/ cs;
        c++
      ) {
        covered.add(c);
      }
    }
    expect(covered..sort(), [2, 3, 4, 5]);
  });

  test('out-of-order seeks return correct data', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    for (final r in [
      [9000, 9500],
      [100, 200],
      [4500, 7300],
      [0, 10499],
      [7000, 7001],
    ]) {
      final res = await fetch(u, range: 'bytes=${r[0]}-${r[1]}');
      expect(res.body, data.sublist(r[0], r[1] + 1), reason: '$r');
    }
  });

  test('unsatisfiable range -> 416', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    final r = await fetch(u, range: 'bytes=20000-');
    expect(r.status, 416);
    expect(r.headers.value('content-range'), 'bytes */$total');
  });

  test('cache survives restart', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    await fetch(u, range: 'bytes=0-10499');
    await cache.dispose();
    origin.ranges.clear();
    cache = await make();
    final u2 = cache.getPlayableUrl(url, videoId: 'v');
    final r = await fetch(u2, range: 'bytes=3000-8000');
    expect(r.body, data.sublist(3000, 8001));
    expect(origin.ranges, isEmpty);
    expect(await cache.getCacheSizeBytes(), total);
  });

  test('LRU eviction keeps cache under the limit', () async {
    await cache.dispose();
    cache = await make(max: 3000);
    final u = cache.getPlayableUrl(url, videoId: 'v');
    final r = await fetch(u, range: 'bytes=0-10499');
    expect(r.body, data); // still served correctly
    expect(await cache.getCacheSizeBytes(), lessThanOrEqualTo(3000));
  });

  test('clearVideo / clearCache', () async {
    final a = cache.getPlayableUrl(url, videoId: 'a');
    final b = cache.getPlayableUrl(url, videoId: 'b');
    await fetch(a, range: 'bytes=0-999');
    await fetch(b, range: 'bytes=0-999');
    expect(await cache.getCacheSizeBytes(), 2000);
    await cache.clearVideo('a');
    expect(await cache.getCacheSizeBytes(), 1000);
    await cache.clearCache();
    expect(await cache.getCacheSizeBytes(), 0);
    // still works afterwards
    final r = await fetch(a, range: 'bytes=0-999');
    expect(r.body, data.sublist(0, 1000));
  });

  group('failures never hang or crash the proxy', () {
    test('origin unreachable -> 503', () async {
      origin.unreachable = true;
      final r = await fetch(
        cache.getPlayableUrl(url, videoId: 'v'),
        range: 'bytes=0-10',
      );
      expect(r.status, 503);
    });

    test('origin 404 -> 404, 500 -> 502', () async {
      origin.failWithStatus = 404;
      expect(
        (await fetch(cache.getPlayableUrl(url, videoId: 'v'))).status,
        404,
      );
      origin.failWithStatus = 500;
      expect(
        (await fetch(cache.getPlayableUrl(url, videoId: 'w'))).status,
        502,
      );
    });

    test('origin timeout -> 504', () async {
      await cache.dispose();
      origin.delay = const Duration(seconds: 2);
      cache = VideoPartialCache(
        chunkSizeBytes: cs,
        cacheDirectory: dir,
        httpClient: origin.client,
        upstreamTimeout: const Duration(milliseconds: 200),
      );
      await cache.init();
      current = cache;
      final r = await fetch(cache.getPlayableUrl(url, videoId: 'v'));
      expect(r.status, 504);
    });

    test('bad requests', () async {
      final base = 'http://127.0.0.1:${cache.port}';
      expect((await fetch('$base/proxy/v')).status, 400); // no src
      expect((await fetch('$base/proxy/v?src=ftp://x/y')).status, 400);
      expect((await fetch('$base/nope')).status, 404);
      expect(
        (await fetch(
          '$base/proxy/v?src=https://o.test/a',
          method: 'POST',
        )).status,
        405,
      );
      // still alive
      final ok = await fetch(
        cache.getPlayableUrl(url, videoId: 'v'),
        range: 'bytes=0-9',
      );
      expect(ok.status, 206);
    });

    test(
      'origin without range support -> pass-through, nothing cached',
      () async {
        origin.supportsRange = false;
        final r = await fetch(cache.getPlayableUrl(url, videoId: 'v'));
        expect(r.status, 200);
        expect(r.body, data);
        expect(await cache.getCacheSizeBytes(), 0);
      },
    );

    test('recovers after a transient origin failure', () async {
      origin.failWithStatus = 503;
      final u = cache.getPlayableUrl(url, videoId: 'v');
      expect((await fetch(u, range: 'bytes=0-99')).status, 502);
      origin.failWithStatus = null;
      final r = await fetch(u, range: 'bytes=0-99');
      expect(r.status, 206);
      expect(r.body, data.sublist(0, 100));
    });
  });

  test('init is idempotent; methods throw before init', () async {
    final c = VideoPartialCache(cacheDirectory: dir);
    expect(() => c.getPlayableUrl(url), throwsStateError);
    await Future.wait([c.init(), c.init()]);
    expect(c.isInitialized, isTrue);
    await c.dispose();
  });

  test('forwards player User-Agent and custom headers to the origin', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    final c = HttpClient()..userAgent = 'ExoPlayerLib/test';
    final req = await c.getUrl(Uri.parse(u));
    req.headers.set('range', 'bytes=0-9');
    await (await req.close()).drain<void>();
    c.close();
    expect(origin.headers.first['user-agent'], 'ExoPlayerLib/test');
  });

  test('getCachedRanges merges contiguous cached chunks', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    expect(await cache.getCachedRanges('v'), isEmpty);
    await fetch(u, range: 'bytes=0-1999'); // chunks 0,1
    await fetch(u, range: 'bytes=9000-10499'); // chunks 9,10 (short last)
    final r = await cache.getCachedRanges('v');
    expect(r.map((e) => [e.startByte, e.endByte]), [
      [0, 1999],
      [9000, 10499],
    ]);
    expect(r.last.endFraction, 1.0);
    expect(r.first.startFraction, 0.0);
    expect(cache.videoIdFor(url), isNotEmpty);

    final p = await cache.getCacheProgress('v');
    expect(p.isHls, isFalse);
    expect(p.spans, hasLength(2));
    expect(p.fraction, closeTo(3500 / 10500, 1e-9));
    expect(p.spans.last.end, 1.0);
  });

  test(
    'offline: stalls at the gap (no error), resumes when back online',
    () async {
      await cache.dispose();
      cache = VideoPartialCache(
        chunkSizeBytes: cs,
        cacheDirectory: dir,
        httpClient: origin.client,
        maxStallDuration: const Duration(seconds: 5),
      );
      await cache.init();
      current = cache;
      final u = cache.getPlayableUrl(url, videoId: 'v');
      await fetch(u, range: 'bytes=0-2999'); // chunks 0,1,2
      await fetch(u, range: 'bytes=10000-10499'); // last chunk
      origin.unreachable = true;

      final c = HttpClient();
      final req = await c.getUrl(Uri.parse(u));
      req.headers.set('range', 'bytes=0-');
      final res = await req.close();
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 0-10499/$total');
      final got = BytesBuilder();
      final done = Completer<void>();
      res.listen(
        got.add,
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (e) {
          if (!done.isCompleted) done.completeError(e);
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(done.isCompleted, isFalse, reason: 'connection stays open');

      origin.unreachable = false; // back online
      await done.future.timeout(const Duration(seconds: 8));
      expect(got.takeBytes(), data);
      c.close();
    },
  );

  test('offline: tail of the file is still served from cache', () async {
    final u = cache.getPlayableUrl(url, videoId: 'v');
    await fetch(u, range: 'bytes=10000-10499');
    origin.unreachable = true;
    final t = await fetch(u, range: 'bytes=10000-');
    expect(t.status, 206);
    expect(t.body, data.sublist(10000));
    expect((await fetch(u, range: 'bytes=5000-')).status, 503);
  });

  test(
    'after a network failure the origin is not retried immediately',
    () async {
      final u = cache.getPlayableUrl(url, videoId: 'v');
      await fetch(u, range: 'bytes=0-999');
      origin.unreachable = true;
      expect((await fetch(u, range: 'bytes=5000-5999')).status, 503);
      final before = origin.ranges.length;
      expect((await fetch(u, range: 'bytes=6000-6999')).status, 503);
      expect(origin.ranges.length, before, reason: 'fast-fail, no new attempt');
    },
  );
}
