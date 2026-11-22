/// Pure helpers to rewrite an HLS playlist so every referenced resource goes
/// through the local proxy, and to give each resource a **stable cache key**.
///
/// Why not key by URL? Real CDNs sign their urls (`exp`, `pathsig`, ...) and
/// some (e.g. Vimeo) even serve every segment from the *same path*, telling
/// them apart only by a query parameter (`sid=7`). A key built from the
/// position of the resource inside its (fingerprinted) playlist is immune to
/// both.
///
/// Key grammar (file name in the proxy url, before the extension):
/// * `m`                      – the root (master or media) playlist
/// * `<parent>_p<n><fp>`      – the n-th child playlist of `<parent>`
///                              (`fp` = fingerprint of its descriptor)
/// * `<parent>_s<n>`          – the n-th media segment of `<parent>`
/// * `<parent>_i<n>`          – the n-th `EXT-X-MAP` init section
/// * `x<n>`                   – never cached (live segments, byte ranges, keys)
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Builds the proxy url for one rewritten reference.
typedef HlsProxyUrl = String Function(String key, Uri target, String ext);

class HlsRewriteResult {
  const HlsRewriteResult({
    required this.text,
    required this.isMaster,
    required this.cacheable,
  });

  /// The rewritten playlist.
  final String text;

  /// True when the playlist lists variant streams.
  final bool isMaster;

  /// False for live playlists (no `#EXT-X-ENDLIST`): they must not be stored.
  final bool cacheable;
}

final RegExp _uriAttr = RegExp(r'URI="([^"]*)"');
final RegExp _extRe = RegExp(r'\.[A-Za-z0-9]{1,5}$');

/// Short stable fingerprint of a playlist descriptor line.
String hlsFingerprint(String descriptor) =>
    sha1.convert(utf8.encode(descriptor)).toString().substring(0, 8);

/// File extension (with dot) of the last path segment, or '' if none.
String hlsExtensionOf(Uri uri) {
  final seg = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  return _extRe.firstMatch(seg)?.group(0)?.toLowerCase() ?? '';
}

bool _isHttp(Uri u) => u.scheme == 'http' || u.scheme == 'https';

/// Rewrites [body] (the playlist fetched from [base]).
///
/// [playlistKey] is the key of this playlist (`m` for the root).
HlsRewriteResult rewriteHlsPlaylist({
  required String body,
  required Uri base,
  required String playlistKey,
  required HlsProxyUrl proxyUrl,
}) {
  final lines = body.split(RegExp(r'\r?\n'));
  final isMaster = body.contains('#EXT-X-STREAM-INF');
  final isLive = !isMaster && !body.contains('#EXT-X-ENDLIST');
  final hasByteRange = body.contains('#EXT-X-BYTERANGE');

  var playlistRefs = 0;
  var segments = 0;
  var inits = 0;
  var uncached = 0;
  String? pendingStreamInf; // descriptor of the STREAM-INF awaiting its uri

  String passthrough(Uri target) =>
      proxyUrl('x${uncached++}', target, hlsExtensionOf(target));

  String childPlaylist(Uri target, String descriptor) {
    final key = '${playlistKey}_p${playlistRefs++}${hlsFingerprint(descriptor)}';
    return proxyUrl(key, target, '.m3u8');
  }

  final out = <String>[];
  for (final raw in lines) {
    final line = raw.trimRight();

    if (line.isEmpty) {
      out.add(line);
      continue;
    }

    if (line.startsWith('#')) {
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pendingStreamInf = line;
        out.add(line);
      } else if (line.startsWith('#EXT-X-MEDIA:') ||
          line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
        out.add(_rewriteUriAttr(line, base, (target, descriptor) {
          return childPlaylist(target, descriptor);
        }));
      } else if (line.startsWith('#EXT-X-MAP:')) {
        out.add(_rewriteUriAttr(line, base, (target, _) {
          if (isLive) return passthrough(target);
          return proxyUrl('${playlistKey}_i${inits++}', target, hlsExtensionOf(target));
        }));
      } else if (line.startsWith('#EXT-X-KEY:') ||
          line.startsWith('#EXT-X-SESSION-KEY:')) {
        // Encryption keys are never written to disk.
        out.add(_rewriteUriAttr(line, base, (target, _) => passthrough(target)));
      } else {
        out.add(line);
      }
      continue;
    }

    // A uri line.
    final target = base.resolve(line);
    if (!_isHttp(target)) {
      out.add(line);
      continue;
    }
    if (pendingStreamInf != null) {
      out.add(childPlaylist(target, pendingStreamInf));
      pendingStreamInf = null;
    } else if (isLive || hasByteRange) {
      out.add(passthrough(target));
    } else {
      out.add(proxyUrl('${playlistKey}_s${segments++}', target, hlsExtensionOf(target)));
    }
  }

  return HlsRewriteResult(
    text: out.join('\n'),
    isMaster: isMaster,
    cacheable: !isLive,
  );
}

/// One media segment of a media playlist: its cache key and duration.
class HlsSegmentRef {
  const HlsSegmentRef(this.key, this.seconds);
  final String key;
  final double seconds;
}

/// The cache keys a stored playlist refers to, in playlist order.
class HlsOutline {
  const HlsOutline({
    required this.isMaster,
    required this.variantKeys,
    required this.segments,
  });

  final bool isMaster;

  /// Master playlist: keys of the `EXT-X-STREAM-INF` variant playlists.
  final List<String> variantKeys;

  /// Media playlist: the cacheable segments with their `EXTINF` durations.
  final List<HlsSegmentRef> segments;
}

/// Lists the keys [rewriteHlsPlaylist] gives to the children of [body].
/// Keys never depend on the base url, so a stored playlist can be outlined
/// without knowing where it came from.
HlsOutline hlsOutline(String body, String playlistKey) {
  const mark = '\u0001';
  final r = rewriteHlsPlaylist(
    body: body,
    base: Uri.parse('https://hls.invalid/'),
    playlistKey: playlistKey,
    proxyUrl: (key, _, _) => '$mark$key',
  );
  final variants = <String>[];
  final segments = <HlsSegmentRef>[];
  double? duration;
  for (final line in r.text.split('\n')) {
    if (line.startsWith('#EXTINF:')) {
      duration = double.tryParse(line.substring(8).split(',').first.trim());
      continue;
    }
    if (!line.startsWith(mark)) continue;
    final key = line.substring(1);
    if (r.isMaster) {
      variants.add(key);
    } else if (key.startsWith('${playlistKey}_s')) {
      segments.add(HlsSegmentRef(key, duration ?? 0));
      duration = null;
    }
  }
  return HlsOutline(isMaster: r.isMaster, variantKeys: variants, segments: segments);
}

String _rewriteUriAttr(
  String line,
  Uri base,
  String Function(Uri target, String descriptor) rewrite,
) {
  final match = _uriAttr.firstMatch(line);
  if (match == null) return line;
  final target = base.resolve(match.group(1)!);
  if (!_isHttp(target)) return line; // skd://, data:, ...
  final descriptor = line.replaceFirst(_uriAttr, '');
  return line.replaceFirst(_uriAttr, 'URI="${rewrite(target, descriptor)}"');
}
