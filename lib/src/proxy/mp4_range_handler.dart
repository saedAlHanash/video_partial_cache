import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

import '../cache/cache_store.dart';
import '../video_partial_cache_config.dart';
import 'range_utils.dart';

/// In-memory request/chunk counters.
class CacheCounters {
  int hitChunks = 0;
  int missChunks = 0;
  int requests = 0;
}

class _UpstreamError implements Exception {
  _UpstreamError(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;
  @override
  String toString() => 'UpstreamError($message, status=$statusCode)';
}

/// Origin ignored our Range header (answered 200): it cannot be chunk-cached.
class _RangeUnsupported implements Exception {}

/// Fast-fail marker while the origin is considered down (see circuit breaker).
class _OriginDown extends SocketException {
  const _OriginDown() : super('Origin unreachable (recent failure)');
}

/// Serves progressive MP4 byte-range requests from the chunk cache,
/// fetching missing chunks from the origin.
///
/// This is the "progressive file" handler. An HLS/TS handler can later be
/// added next to it, reusing [CacheStore] and `range_utils.dart`.
class Mp4RangeHandler {
  Mp4RangeHandler({
    required this.store,
    required this.chunkSize,
    required this.client,
    this.timeout = const Duration(seconds: 30),
    this.maxRunChunks = 8,
    this.onLog,
    this.upstreamHeaders = const {},
    Duration stallLimit = const Duration(seconds: 60),
  }) : _stallLimit = stallLimit; // ignore: prefer_initializing_formals

  final Duration _stallLimit;

  final CacheStore store;
  final int chunkSize;
  final Duration timeout;
  final int maxRunChunks;
  final CacheLogCallback? onLog;

  /// Extra headers sent to the origin (e.g. auth). A `user-agent` set here
  /// wins over the player's.
  final Map<String, String> upstreamHeaders;
  final CacheCounters counters = CacheCounters();

  final http.Client client;
  final Map<String, Future<Uint8List>> _inflight = {};
  final Set<String> _noRange = {};
  final Set<Future<void>> _activeRuns = {};

  /// After a network failure the origin is not contacted again for this long,
  /// so offline playback fails fast instead of stalling on connect timeouts.
  Duration originRetryDelay = const Duration(seconds: 3);

  /// How long a started response may stall waiting for the origin.
  late final Duration stallLimit = _stallLimit;
  late final Duration stallPoll = Duration(
    milliseconds: (_stallLimit.inMilliseconds ~/ 10).clamp(50, 1000),
  );
  final Map<String, DateTime> _originDownUntil = {};

  bool _isOriginDown(Uri uri) {
    final until = _originDownUntil[uri.host];
    return until != null && DateTime.now().isBefore(until);
  }

  Duration get _connectTimeout => timeout < const Duration(seconds: 10)
      ? timeout
      : const Duration(seconds: 10);

  void _log(String m) {
    if (kDebugMode) onLog?.call(m);
  }

  /// Completes when all in-progress upstream fetches (and their disk
  /// writes) have finished.
  Future<void> whenIdle() async {
    while (_activeRuns.isNotEmpty) {
      await Future.wait(_activeRuns.toList());
    }
  }

  /// Many CDNs reject Dart's default User-Agent, so forward the player's.
  Map<String, String> _originHeaders(Request request) => {
    'user-agent': request.headers['user-agent'] ?? 'video_partial_cache/0.1',
    ...upstreamHeaders,
  };

  static String _key(String id, int idx) => '$id#$idx';

  /// shelf entry point. Never throws.
  Future<Response> call(Request request) async {
    counters.requests++;
    try {
      return await _handle(request);
    } on _UpstreamError catch (e) {
      _log('upstream error: $e');
      final s = e.statusCode;
      return _error(
        s == 401 || s == 403 || s == 404 || s == 410 ? s! : 502,
        'Upstream error: ${e.message}',
      );
    } on TimeoutException {
      _log('upstream timeout');
      return _error(504, 'Upstream timeout');
    } on SocketException catch (e) {
      _log('upstream unreachable: $e');
      return _error(503, 'Upstream unreachable');
    } on http.ClientException catch (e) {
      _log('upstream unreachable: $e');
      return _error(503, 'Upstream unreachable');
    } catch (e, st) {
      _log('internal error: $e\n$st');
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
    if (segs.length != 2 || segs[0] != 'proxy' || segs[1].isEmpty) {
      return _error(404, 'Not found');
    }
    final videoId = segs[1];
    final src = request.url.queryParameters['src'];
    final uri = src == null ? null : Uri.tryParse(src);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return _error(400, 'Missing or invalid src');
    }

    final hdrs = _originHeaders(request);
    if (_noRange.contains(videoId)) return _passthrough(request, uri, hdrs);

    final spec = parseRangeHeader(request.headers['range']);

    int? total = store.totalLength(videoId);
    if (total == null) {
      try {
        await _obtainChunk(videoId, uri, 0, 0, hdrs);
      } on _RangeUnsupported {
        _noRange.add(videoId);
        return _passthrough(request, uri, hdrs);
      }
      total = store.totalLength(videoId);
      if (total == null) throw _UpstreamError('Unknown content length');
    }
    final title = request.url.queryParameters['title'];
    if (title != null && title.isNotEmpty) {
      await store.setTitle(videoId, title);
    }
    final contentType = store.contentType(videoId) ?? 'video/mp4';
    final baseHeaders = <String, String>{
      'content-type': contentType,
      'accept-ranges': 'bytes',
    };

    final ByteRange range;
    final bool partial = spec != null;
    if (spec == null) {
      if (total == 0) {
        return Response.ok(
          null,
          headers: {...baseHeaders, 'content-length': '0'},
        );
      }
      range = ByteRange(0, total - 1);
    } else {
      final r = resolveRange(spec, total);
      if (r == null) {
        return Response(
          416,
          headers: {
            ...baseHeaders,
            'content-range': 'bytes */$total',
            'content-length': '0',
          },
        );
      }
      range = r;
    }

    final status = partial ? 206 : 200;

    if (request.method == 'HEAD') {
      return Response(
        status,
        headers: {
          ...baseHeaders,
          'content-length': '${range.length}',
          if (partial)
            'content-range': contentRangeHeader(range.start, range.end, total),
        },
      );
    }

    final served = range;
    final firstIdx = range.start ~/ chunkSize;
    final lastIdx = range.end ~/ chunkSize;

    final headers = <String, String>{
      ...baseHeaders,
      'content-length': '${served.length}',
      if (partial)
        'content-range': contentRangeHeader(served.start, served.end, total),
    };

    if (onLog != null && kDebugMode) {
      var cached = 0;
      for (var i = firstIdx; i <= lastIdx; i++) {
        if (store.hasChunk(videoId, i)) cached++;
      }
      final n = lastIdx - firstIdx + 1;
      _log(
        '${cached == n
            ? 'HIT '
            : cached == 0
            ? 'MISS'
            : 'PART'} '
        '$videoId ${request.headers['range'] ?? 'bytes=0-'} -> '
        '$served chunks $firstIdx..$lastIdx '
        '(cached $cached/$n)',
      );
    }

    // Fetch the first chunk eagerly so origin failures become a proper HTTP
    // error instead of a truncated 206.
    final first = await _obtainChunk(videoId, uri, firstIdx, lastIdx, hdrs);

    return Response(
      status,
      headers: headers,
      body: _body(videoId, uri, hdrs, served, firstIdx, lastIdx, first, total),
    );
  }

  Stream<List<int>> _body(
    String videoId,
    Uri uri,
    Map<String, String> hdrs,
    ByteRange range,
    int firstIdx,
    int lastIdx,
    Uint8List first,
    int total,
  ) async* {
    for (var i = firstIdx; i <= lastIdx; i++) {
      final data = i == firstIdx
          ? first
          : await _obtainChunkPatiently(videoId, uri, i, lastIdx, hdrs);
      final expected = chunkLength(i, chunkSize, total);
      if (data.length != expected) {
        throw _UpstreamError(
          'Chunk $i has ${data.length} bytes, '
          'expected $expected',
        );
      }
      final s = sliceWithinChunk(i, chunkSize, range);
      yield Uint8List.sublistView(data, s.start, s.end + 1);
    }
  }

  /// Mid-stream chunk fetch that survives a temporary connection loss: while
  /// the origin is unreachable the response simply stalls (like a slow
  /// network) and resumes when it is back, so the player shows buffering
  /// instead of a fatal error and stays seekable. Gives up after [stallLimit].
  Future<Uint8List> _obtainChunkPatiently(
    String videoId,
    Uri uri,
    int idx,
    int lastNeeded,
    Map<String, String> hdrs,
  ) async {
    final deadline = DateTime.now().add(stallLimit);
    while (true) {
      try {
        return await _obtainChunk(videoId, uri, idx, lastNeeded, hdrs);
      } on TimeoutException {
        if (!DateTime.now().isBefore(deadline)) rethrow;
      } on SocketException {
        if (!DateTime.now().isBefore(deadline)) rethrow;
      } on http.ClientException {
        if (!DateTime.now().isBefore(deadline)) rethrow;
      }
      _log('STALL waiting for origin: $videoId chunk $idx');
      await Future<void>.delayed(stallPoll);
    }
  }

  // ------------------------------------------------------ chunk acquisition

  /// Returns chunk [idx], from disk, from an in-flight fetch started by a
  /// concurrent request, or by starting a new upstream request that also
  /// covers following missing chunks (up to [lastNeeded] / [maxRunChunks]).
  Future<Uint8List> _obtainChunk(
    String videoId,
    Uri uri,
    int idx,
    int lastNeeded,
    Map<String, String> hdrs,
  ) async {
    while (true) {
      final pending = _inflight[_key(videoId, idx)];
      if (pending != null) {
        counters.missChunks++;
        return pending;
      }
      if (store.hasChunk(videoId, idx)) {
        final data = await store.readChunk(videoId, idx);
        if (data != null) {
          counters.hitChunks++;
          return data;
        }
        continue; // entry was dropped (evicted/corrupt) -> re-evaluate
      }
      break;
    }

    // No awaits between the checks above and registering below, so two
    // requests can never start duplicate fetches for the same chunk.
    final limit = math.min(lastNeeded, idx + maxRunChunks - 1);
    var last = idx;
    while (last < limit &&
        !store.hasChunk(videoId, last + 1) &&
        !_inflight.containsKey(_key(videoId, last + 1))) {
      last++;
    }
    final completers = <int, Completer<Uint8List>>{};
    for (var i = idx; i <= last; i++) {
      final c = Completer<Uint8List>();
      c.future.ignore(); // nobody may be listening if the player left
      completers[i] = c;
      _inflight[_key(videoId, i)] = c.future;
    }
    counters.missChunks++;
    final run = _fetchRun(videoId, uri, hdrs, idx, last, completers);
    _activeRuns.add(run);
    unawaited(run.whenComplete(() => _activeRuns.remove(run)));
    return completers[idx]!.future;
  }

  /// One upstream request for chunks [first]..[last]; completes each chunk's
  /// completer as soon as its bytes are complete, and persists it.
  Future<void> _fetchRun(
    String videoId,
    Uri uri,
    Map<String, String> hdrs,
    int first,
    int last,
    Map<int, Completer<Uint8List>> completers,
  ) async {
    Object? failure;
    try {
      final known = store.totalLength(videoId);
      var reqEnd = (last + 1) * chunkSize - 1;
      if (known != null && reqEnd > known - 1) reqEnd = known - 1;
      final reqStart = first * chunkSize;

      final req = http.Request('GET', uri)
        ..headers.addAll(hdrs)
        ..headers['range'] = 'bytes=$reqStart-$reqEnd';
      if (_isOriginDown(uri)) {
        throw const _OriginDown();
      }
      final resp = await client.send(req).timeout(_connectTimeout);
      _originDownUntil.remove(uri.host);

      if (resp.statusCode == 200) {
        unawaited(resp.stream.listen((_) {}).cancel());
        throw _RangeUnsupported();
      }
      if (resp.statusCode != 206) {
        unawaited(resp.stream.listen((_) {}).cancel());
        throw _UpstreamError('HTTP ${resp.statusCode}', resp.statusCode);
      }
      final cr = parseContentRange(resp.headers['content-range']);
      if (cr == null || cr.total == null || cr.start != reqStart) {
        unawaited(resp.stream.listen((_) {}).cancel());
        throw _UpstreamError(
          'Bad Content-Range '
          '"${resp.headers['content-range']}"',
        );
      }
      final total = cr.total!;
      await store.setVideoInfo(
        videoId,
        totalLength: total,
        contentType: resp.headers['content-type'],
      );

      final buf = BytesBuilder(copy: false);
      var idx = first;
      await for (final data in resp.stream.timeout(timeout)) {
        var off = 0;
        while (off < data.length && idx <= last) {
          final len = chunkLength(idx, chunkSize, total);
          final take = math.min(len - buf.length, data.length - off);
          buf.add(
            Uint8List.sublistView(
              data is Uint8List ? data : Uint8List.fromList(data),
              off,
              off + take,
            ),
          );
          off += take;
          if (buf.length == len) {
            final chunk = buf.takeBytes();
            completers[idx]!.complete(chunk); // player gets bytes right away
            try {
              await store.writeChunk(videoId, idx, chunk);
            } catch (_) {
              // caching is best effort; serving already succeeded
            }
            _inflight.remove(_key(videoId, idx));
            idx++;
          }
        }
        if (idx > last) break; // cancels the upstream subscription
      }
      if (idx <= last) throw _UpstreamError('Upstream body truncated');
    } catch (e) {
      failure = e;
      if (e is! _OriginDown &&
          (e is SocketException ||
              e is http.ClientException ||
              e is TimeoutException)) {
        _originDownUntil[uri.host] = DateTime.now().add(originRetryDelay);
      }
    } finally {
      for (final e in completers.entries) {
        if (!e.value.isCompleted) {
          e.value.completeError(failure ?? StateError('aborted'));
        }
        _inflight.remove(_key(videoId, e.key));
      }
    }
  }

  // ------------------------------------------------------------ passthrough

  /// Fallback for origins that do not support byte ranges: stream through,
  /// no caching.
  Future<Response> _passthrough(
    Request request,
    Uri uri,
    Map<String, String> hdrs,
  ) async {
    _log('PASSTHROUGH (origin has no range support) $uri');
    final req = http.Request(request.method, uri)..headers.addAll(hdrs);
    final resp = await client.send(req).timeout(_connectTimeout);
    final headers = <String, String>{
      'content-type': resp.headers['content-type'] ?? 'video/mp4',
      if (resp.contentLength != null) 'content-length': '${resp.contentLength}',
    };
    if (request.method == 'HEAD') {
      unawaited(resp.stream.listen((_) {}).cancel());
      return Response(resp.statusCode, headers: headers);
    }
    return Response(resp.statusCode, headers: headers, body: resp.stream);
  }
}
