import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video_partial_cache/src/proxy/hls_playlist.dart';
import 'package:video_partial_cache/video_partial_cache.dart';

const masterUrl = 'https://cdn.test/a/master.m3u8?exp=1&sig=AAA';

String proxyOf(String key, Uri target, String ext) => 'P/$key$ext|$target';

void main() {
  group('rewriteHlsPlaylist', () {
    const master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",URI="audio/en.m3u8?t=1"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="aud"
v360/index.m3u8?t=1
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud"
v720/index.m3u8?t=1
''';

    test('master: children get fingerprinted playlist keys, urls resolved', () {
      final r = rewriteHlsPlaylist(
        body: master,
        base: Uri.parse(masterUrl),
        playlistKey: 'm',
        proxyUrl: proxyOf,
      );
      expect(r.isMaster, isTrue);
      expect(r.cacheable, isTrue);
      final lines = r.text.split('\n');
      expect(lines[1], contains('URI="P/m_p0'));
      expect(lines[1], contains('.m3u8|https://cdn.test/a/audio/en.m3u8?t=1"'));
      final k360 = RegExp(r'P/(m_p\d\w+)\.m3u8').firstMatch(lines[3])!.group(1);
      final k720 = RegExp(r'P/(m_p\d\w+)\.m3u8').firstMatch(lines[5])!.group(1);
      expect(k360, isNot(k720));
      // same input -> same keys (stability across sessions)
      final again = rewriteHlsPlaylist(
        body: master,
        base: Uri.parse('https://cdn.test/a/master.m3u8?exp=999&sig=ZZZ'),
        playlistKey: 'm',
        proxyUrl: proxyOf,
      );
      expect(again.text.split('\n')[3].split('|').first, lines[3].split('|').first);
    });

    test('segments sharing one path (Vimeo style) still get distinct keys', () {
      const media = '''
#EXTM3U
#EXT-X-MAP:URI="init.mp4?sid=0"
#EXTINF:6,
segment.m4s?sid=1&pathsig=abc
#EXTINF:6,
segment.m4s?sid=2&pathsig=abc
#EXT-X-ENDLIST
''';
      final r = rewriteHlsPlaylist(
        body: media,
        base: Uri.parse('https://cdn.test/v/index.m3u8'),
        playlistKey: 'm_p0abc',
        proxyUrl: proxyOf,
      );
      expect(r.cacheable, isTrue);
      expect(r.text, contains('URI="P/m_p0abc_i0.mp4|'));
      expect(r.text, contains('P/m_p0abc_s0.m4s|https://cdn.test/v/segment.m4s?sid=1&pathsig=abc'));
      expect(r.text, contains('P/m_p0abc_s1.m4s|https://cdn.test/v/segment.m4s?sid=2&pathsig=abc'));
    });

    test('live playlist is not cacheable and its segments pass through', () {
      const live = '#EXTM3U\n#EXTINF:6,\nseg1.ts\n';
      final r = rewriteHlsPlaylist(
        body: live,
        base: Uri.parse('https://cdn.test/live.m3u8'),
        playlistKey: 'm',
        proxyUrl: proxyOf,
      );
      expect(r.cacheable, isFalse);
      expect(r.text, contains('P/x0.ts|https://cdn.test/seg1.ts'));
    });

    test('byte-range segments and keys are not cached; DRM uris untouched', () {
      const media = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://keys.test/k1"
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://drm"
#EXT-X-BYTERANGE:100@0
big.ts
#EXT-X-ENDLIST
''';
      final r = rewriteHlsPlaylist(
        body: media,
        base: Uri.parse('https://cdn.test/v/index.m3u8'),
        playlistKey: 'm',
        proxyUrl: proxyOf,
      );
      expect(r.text, contains('URI="P/x0|https://keys.test/k1"'));
      expect(r.text, contains('URI="skd://drm"'));
      expect(r.text, contains('P/x1.ts|https://cdn.test/v/big.ts'));
    });
  });

  group('HLS through the cache', () {
    late Directory dir;
    late VideoPartialCache cache;
    final requests = <String>[];
    var offline = false;

    Uint8List seg(int n) => Uint8List.fromList(List.generate(500, (i) => (i + n) % 251));

    http.Response respond(http.Request req) {
      requests.add(req.url.toString());
      if (offline) throw const SocketException('offline');
      final u = req.url;
      if (u.path == '/a/master.m3u8') {
        return http.Response(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nv360/index.m3u8?t=1\n',
          200,
        );
      }
      if (u.path == '/a/v360/index.m3u8') {
        return http.Response(
          '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg.ts?sid=1&sig=${requests.length}\n'
          '#EXTINF:6,\nseg.ts?sid=2&sig=${requests.length}\n#EXT-X-ENDLIST\n',
          200,
        );
      }
      if (u.path == '/a/v360/seg.ts') {
        return http.Response.bytes(seg(int.parse(u.queryParameters['sid']!)), 200);
      }
      return http.Response('nope', 404);
    }

    setUp(() async {
      requests.clear();
      offline = false;
      dir = await Directory.systemTemp.createTemp('vpc_hls_test');
      cache = VideoPartialCache(
        cacheDirectory: dir,
        httpClient: MockClient((r) async => respond(r)),
        upstreamTimeout: const Duration(seconds: 5),
      );
      await cache.init();
    });

    tearDown(() async {
      await cache.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<(int, Uint8List)> get(String url) async {
      final c = HttpClient();
      try {
        final res = await (await c.getUrl(Uri.parse(url))).close();
        final b = BytesBuilder();
        await for (final d in res) {
          b.add(d);
        }
        await cache.debugWaitForIdle();
        return (res.statusCode, b.takeBytes());
      } finally {
        c.close(force: true);
      }
    }

    /// Plays the whole stream: master -> variant -> both segments.
    Future<List<Uint8List>> playAll() async {
      final playable = cache.getPlayableUrl(masterUrl, videoId: 'vid');
      expect(Uri.parse(playable).path, endsWith('/m.m3u8'));
      final (s1, masterBody) = await get(playable);
      expect(s1, 200);
      final variantUrl = utf8
          .decode(masterBody)
          .split('\n')
          .firstWhere((l) => l.startsWith('http'));
      final (s2, variantBody) = await get(variantUrl);
      expect(s2, 200);
      final segUrls = utf8
          .decode(variantBody)
          .split('\n')
          .where((l) => l.startsWith('http'))
          .toList();
      expect(segUrls, hasLength(2));
      final out = <Uint8List>[];
      for (final u in segUrls) {
        final (s, b) = await get(u);
        expect(s, 200);
        out.add(b);
      }
      return out;
    }

    test('segments are cached: second play needs only the playlists', () async {
      final first = await playAll();
      expect(first[0], seg(1));
      expect(first[1], seg(2));
      expect(requests.where((r) => r.contains('seg.ts')), hasLength(2));

      requests.clear();
      final second = await playAll();
      expect(second[0], seg(1));
      expect(second[1], seg(2));
      expect(requests.where((r) => r.contains('seg.ts')), isEmpty);
      expect(requests, hasLength(2)); // master + variant playlist only
    });

    test('a fully cached stream plays with the origin offline', () async {
      await playAll();
      offline = true;
      final again = await playAll();
      expect(again[0], seg(1));
      expect(again[1], seg(2));
    });

    test('stats and clearVideo see the HLS entries', () async {
      await playAll();
      final stats = await cache.getStats();
      expect(stats.videos.single.videoId, 'vid');
      expect(stats.videos.single.cachedBytes, greaterThan(1000));
      await cache.clearVideo('vid');
      expect(await cache.getCacheSizeBytes(), 0);
    });

    test('getCacheProgress maps cached segments onto the timeline', () async {
      expect((await cache.getCacheProgress('vid')).spans, isEmpty);

      // Play the playlists and only the second segment.
      final playable = cache.getPlayableUrl(masterUrl, videoId: 'vid');
      final (_, masterBody) = await get(playable);
      final variantUrl =
          utf8.decode(masterBody).split('\n').firstWhere((l) => l.startsWith('http'));
      final (_, variantBody) = await get(variantUrl);
      final segUrls =
          utf8.decode(variantBody).split('\n').where((l) => l.startsWith('http')).toList();
      await get(segUrls[1]);

      var p = await cache.getCacheProgress('vid');
      expect(p.isHls, isTrue);
      expect(p.duration, const Duration(seconds: 12));
      expect(p.fraction, closeTo(0.5, 1e-9));
      expect(p.spans, hasLength(1));
      expect(p.spans.single.start, closeTo(0.5, 1e-9));
      expect(p.spans.single.end, closeTo(1.0, 1e-9));

      await get(segUrls[0]);
      p = await cache.getCacheProgress('vid');
      expect(p.fraction, closeTo(1.0, 1e-9));
      expect(p.spans, hasLength(1)); // merged into one span
      expect(p.spans.single.start, 0);
    });

    test('unknown route and bad src are rejected', () async {
      final base = Uri.parse(cache.getPlayableUrl(masterUrl, videoId: 'vid'));
      final noSrc = base.replace(queryParameters: const {});
      expect((await get(noSrc.toString())).$1, 400);
    });
  });

  test('hlsOutline lists variants and timed segments', () {
    final master = hlsOutline(
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nb.m3u8\n',
      'm',
    );
    expect(master.isMaster, isTrue);
    expect(master.variantKeys, hasLength(2));
    expect(master.variantKeys.every((k) => k.startsWith('m_p')), isTrue);

    final media = hlsOutline(
      '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4.5,\ns1.m4s\n#EXTINF:2,\ns2.m4s\n#EXT-X-ENDLIST\n',
      'm_p0x',
    );
    expect(media.isMaster, isFalse);
    expect(media.segments.map((s) => s.key), ['m_p0x_s0', 'm_p0x_s1']);
    expect(media.segments.map((s) => s.seconds), [4.5, 2]);
  });

  test('isHlsUrl', () {
    expect(VideoPartialCache.isHlsUrl('https://a.test/x/playlist.m3u8?x=1'), isTrue);
    expect(VideoPartialCache.isHlsUrl('https://a.test/x/video.mp4'), isFalse);
  });
}
