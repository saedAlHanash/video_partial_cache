import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

import '../cache/cache_store.dart';
import '../video_partial_cache_config.dart';
import 'hls_playlist.dart';
import 'mp4_range_handler.dart' show CacheCounters;
import 'range_utils.dart';

class _HlsUpstreamError implements Exception {
  _HlsUpstreamError(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;
  @override
  String toString() => 'HlsUpstreamError($message, status=$statusCode)';
}

/// Serves HLS (`.m3u8`) streams through the cache.
///
/// * Playlists are always fetched from the origin first (their signed urls
///   expire), rewritten to point at this proxy, and stored. If the origin is
///   unreachable the stored copy is served, so a fully cached video plays
///   offline.
/// * Every media segment / init section is stored whole, as one entry of
///   [CacheStore], under a stable key (see `hls_playlist.dart`).
/// * Live playlists, `EXT-X-BYTERANGE` segments and encryption keys are
///   streamed through without being stored.
///
/// Route: `/hls/<videoId>/<key><ext>?src=<absolute url>`.
class HlsHandler {
  HlsHandler({
    required this.store,
    required this.client,
    required this.counters,
    this.timeout = const Duration(seconds: 30),
    this.onLog,
    this.upstreamHeaders = const {},
  });

  final CacheStore store;
  final http.Client client;
  final CacheCounters counters;
  final Duration timeout;
  final CacheLogCallback? onLog;
  final Map<String, String> upstreamHeaders;

  /// Largest single resource that is buffered and cached.
  static const int maxResourceBytes = 128 * 1024 * 1024;

  final Map<String, Future<Uint8List>> _inflight = {};
  final Set<Future<void>> _activeWrites = {};

  void _log(String m) {
    if (kDebugMode) onLog?.call(m);
  }

  Future<void> whenIdle() async {
    while (_activeWrites.isNotEmpty) {
      await Future.wait(_activeWrites.toList());
    }
  }

  Map<String, String> _originHeaders(Request request) => {
    'user-agent': request.headers['user-agent'] ?? 'video_partial_cache/0.1',
    ...upstreamHeaders,
  };

  /// Stable non-negative integer id of a key (48 bits of its SHA-1).
  static int entryIndex(String key) {
    final d = sha1.convert(utf8.encode(key)).bytes;
    var v = 0;
    for (var i = 0; i < 6; i++) {
      v = (v << 8) | d[i];
    }
    return v;
  }

  /// shelf entry point. Never throws.
  Future<Response> call(Request request) async {
    counters.requests++;
    try {
      return await _handle(request);
    } on _HlsUpstreamError catch (e) {
      _log('hls upstream error: $e');
      final s = e.statusCode;
      return _error(
        s == 401 || s == 403 || s == 404 || s == 410 ? s! : 502,
        'Upstream error: ${e.message}',
      );
    } on TimeoutException {
      return _error(504, 'Upstream timeout');
    } on SocketException {
      return _error(503, 'Upstream unreachable');
    } on http.ClientException {
      return _error(503, 'Upstream unreachable');
    } catch (e, st) {
      _log('hls internal error: $e\n$st');
      return _error(500, 'Internal error');
    }
  }

  Response _error(int status, String message) => Response(
    status,
    body: message,
    headers: {'content-type': 'text/plain', 'cache-control': 'no-store'},
  );

  Future<Response> _handle(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return _error(405, 'Method not allowed');
    }
    final segs = request.url.pathSegments;
    if (segs.length != 3 || segs[0] != 'hls' || segs[1].isEmpty) {
      return _error(404, 'Not found');
    }
    final videoId = segs[1];
    final file = segs[2];
    final dot = file.lastIndexOf('.');
    final key = dot < 0 ? file : file.substring(0, dot);
    final ext = dot < 0 ? '' : file.substring(dot).toLowerCase();

    final src = request.url.queryParameters['src'];
    final uri = src == null ? null : Uri.tryParse(src);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return _error(400, 'Missing or invalid src');
    }

    final hdrs = _originHeaders(request);

    if (key.startsWith('x')) return _passthrough(request, uri, hdrs);

    final title = request.url.queryParameters['title'];
    if (title != null && title.isNotEmpty) await store.setTitle(videoId, title);

    if (ext == '.m3u8') {
      return _playlist(request, videoId, key, uri, hdrs);
    }
    return _resource(request, videoId, key, ext, uri, hdrs);
  }

  // -------------------------------------------------------------- playlists

  Future<Response> _playlist(
    Request request,
    String videoId,
    String key,
    Uri uri,
    Map<String, String> hdrs,
  ) async {
    final idx = entryIndex(key);
    String body;
    try {
      final bytes = (await _download(uri, hdrs)).bytes;
      body = utf8.decode(bytes, allowMalformed: true);
      if (!body.trimLeft().startsWith('#EXTM3U')) {
        throw _HlsUpstreamError('Not an HLS playlist');
      }
      counters.missChunks++;
    } on Object catch (e) {
      // Offline (or origin failing): fall back to the stored playlist.
      final cached = await store.readChunk(videoId, idx);
      if (cached == null) rethrow;
      counters.hitChunks++;
      _log('OFFLINE playlist $videoId/$key ($e)');
      body = utf8.decode(cached, allowMalformed: true);
      return _playlistResponse(request, videoId, key, uri, body, persist: false);
    }
    return _playlistResponse(request, videoId, key, uri, body, persist: true, idx: idx);
  }

  Response _playlistResponse(
    Request request,
    String videoId,
    String key,
    Uri uri,
    String body, {
    required bool persist,
    int? idx,
  }) {
    final origin = request.requestedUri.origin;
    final result = rewriteHlsPlaylist(
      body: body,
      base: uri,
      playlistKey: key,
      proxyUrl: (childKey, target, ext) =>
          '$origin/hls/${Uri.encodeComponent(videoId)}/$childKey$ext'
          '?src=${Uri.encodeQueryComponent(target.toString())}',
    );

    if (persist && idx != null && result.cacheable) {
      _track(store.writeChunk(videoId, idx, Uint8List.fromList(utf8.encode(body))));
    }
    _log('${result.cacheable ? 'PLAYLIST' : 'LIVE    '} $videoId/$key');

    final bytes = utf8.encode(result.text);
    return Response.ok(
      request.method == 'HEAD' ? null : bytes,
      headers: {
        'content-type': 'application/vnd.apple.mpegurl',
        'content-length': '${bytes.length}',
        'cache-control': 'no-store',
      },
    );
  }

  // -------------------------------------------------------------- resources

  Future<Response> _resource(
    Request request,
    String videoId,
    String key,
    String ext,
    Uri uri,
    Map<String, String> hdrs,
  ) async {
    final data = await _obtain(videoId, key, uri, hdrs);
    final contentType = _contentTypeFor(ext);
    final base = <String, String>{
      'content-type': contentType,
      'accept-ranges': 'bytes',
    };

    final spec = parseRangeHeader(request.headers['range']);
    if (spec == null) {
      return Response.ok(
        request.method == 'HEAD' ? null : data,
        headers: {...base, 'content-length': '${data.length}'},
      );
    }
    final r = resolveRange(spec, data.length);
    if (r == null) {
      return Response(
        416,
        headers: {
          ...base,
          'content-range': 'bytes */${data.length}',
          'content-length': '0',
        },
      );
    }
    return Response(
      206,
      body: request.method == 'HEAD'
          ? null
          : Uint8List.sublistView(data, r.start, r.end + 1),
      headers: {
        ...base,
        'content-length': '${r.length}',
        'content-range': contentRangeHeader(r.start, r.end, data.length),
      },
    );
  }

  /// Returns the resource from disk, an in-flight download, or the origin.
  Future<Uint8List> _obtain(
    String videoId,
    String key,
    Uri uri,
    Map<String, String> hdrs,
  ) async {
    final idx = entryIndex(key);
    final id = '$videoId#$key';

    while (true) {
      final pending = _inflight[id];
      if (pending != null) {
        counters.missChunks++;
        return pending;
      }
      if (store.hasChunk(videoId, idx)) {
        final data = await store.readChunk(videoId, idx);
        if (data != null) {
          counters.hitChunks++;
          _log('HIT  $videoId/$key');
          return data;
        }
        continue; // dropped meanwhile -> re-evaluate
      }
      break;
    }

    counters.missChunks++;
    _log('MISS $videoId/$key');
    final future = () async {
      final bytes = (await _download(uri, hdrs)).bytes;
      try {
        await store.writeChunk(videoId, idx, bytes);
      } catch (_) {
        // caching is best effort
      }
      return bytes;
    }();
    future.ignore();
    _inflight[id] = future;
    _track(future.whenComplete(() => _inflight.remove(id)).then((_) {}, onError: (_) {}));
    return future;
  }

  void _track(Future<void> f) {
    _activeWrites.add(f);
    unawaited(f.whenComplete(() => _activeWrites.remove(f)).catchError((_) {}));
  }

  // ---------------------------------------------------------------- network

  Future<({Uint8List bytes, String? contentType})> _download(
    Uri uri,
    Map<String, String> hdrs,
  ) async {
    final req = http.Request('GET', uri)..headers.addAll(hdrs);
    final resp = await client.send(req).timeout(timeout);
    if (resp.statusCode != 200) {
      unawaited(resp.stream.listen((_) {}).cancel());
      throw _HlsUpstreamError('HTTP ${resp.statusCode}', resp.statusCode);
    }
    final len = resp.contentLength;
    if (len != null && len > maxResourceBytes) {
      unawaited(resp.stream.listen((_) {}).cancel());
      throw _HlsUpstreamError('Resource too large ($len bytes)');
    }
    final buf = BytesBuilder(copy: false);
    await for (final d in resp.stream.timeout(timeout)) {
      buf.add(d);
      if (buf.length > maxResourceBytes) {
        throw _HlsUpstreamError('Resource too large');
      }
    }
    return (bytes: buf.takeBytes(), contentType: resp.headers['content-type']);
  }

  /// Streams the origin response unchanged (live segments, keys, byte ranges).
  Future<Response> _passthrough(
    Request request,
    Uri uri,
    Map<String, String> hdrs,
  ) async {
    _log('PASSTHROUGH $uri');
    final req = http.Request(request.method, uri)..headers.addAll(hdrs);
    final range = request.headers['range'];
    if (range != null) req.headers['range'] = range;
    final resp = await client.send(req).timeout(timeout);
    final headers = <String, String>{
      for (final h in const [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
      ])
        if (resp.headers[h] != null) h: resp.headers[h]!,
    };
    if (request.method == 'HEAD') {
      unawaited(resp.stream.listen((_) {}).cancel());
      return Response(resp.statusCode, headers: headers);
    }
    return Response(resp.statusCode, headers: headers, body: resp.stream);
  }

  static String _contentTypeFor(String ext) {
    switch (ext) {
      case '.ts':
        return 'video/mp2t';
      case '.m4s':
      case '.mp4':
      case '.cmfv':
      case '.m4v':
        return 'video/mp4';
      case '.m4a':
      case '.cmfa':
        return 'audio/mp4';
      case '.aac':
        return 'audio/aac';
      case '.mp3':
        return 'audio/mpeg';
      case '.vtt':
      case '.webvtt':
        return 'text/vtt';
      default:
        return 'application/octet-stream';
    }
  }
}
