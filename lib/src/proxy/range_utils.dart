/// Pure, side-effect-free helpers for HTTP byte ranges and chunk arithmetic.
///
/// All ranges are **inclusive** on both ends, like HTTP `Range` headers.
library;

/// An inclusive byte range `[start, end]`.
class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ByteRange($start-$end)';
}

/// A parsed (but not yet resolved against a total length) `Range` header.
class RangeSpec {
  const RangeSpec({this.start, this.end, this.suffixLength});

  /// First byte; null for suffix ranges (`bytes=-500`).
  final int? start;

  /// Last byte; null for open-ended ranges (`bytes=500-`).
  final int? end;

  /// Number of trailing bytes for suffix ranges.
  final int? suffixLength;
}

/// A contiguous run of chunk indexes `[first, last]`.
class ChunkRun {
  const ChunkRun(this.first, this.last);

  final int first;
  final int last;

  int get count => last - first + 1;

  @override
  bool operator ==(Object other) =>
      other is ChunkRun && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);

  @override
  String toString() => 'ChunkRun($first..$last)';
}

/// Parsed `Content-Range` response header.
class ContentRange {
  const ContentRange(this.start, this.end, this.total);

  final int start;
  final int end;

  /// Null when the origin sent `*`.
  final int? total;
}

final RegExp _rangeRe = RegExp(
  r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*(?:,.*)?$',
  caseSensitive: false,
);

/// Parses a `Range` header. Only the first range of a multi-range header is
/// used. Returns null when the header is absent, blank, not in bytes units or
/// malformed (RFC 7233: such a header is ignored and the full body is served).
RangeSpec? parseRangeHeader(String? header) {
  if (header == null || header.trim().isEmpty) return null;
  final m = _rangeRe.firstMatch(header);
  if (m == null) return null;
  final a = m.group(1)!;
  final b = m.group(2)!;
  if (a.isEmpty && b.isEmpty) return null;
  final int? start = a.isEmpty ? null : int.tryParse(a);
  final int? end = b.isEmpty ? null : int.tryParse(b);
  if ((a.isNotEmpty && start == null) || (b.isNotEmpty && end == null)) {
    return null;
  }
  if (start == null) return RangeSpec(suffixLength: end);
  if (end != null && end < start) return null;
  return RangeSpec(start: start, end: end);
}

/// Resolves [spec] against [totalLength]. Returns null if unsatisfiable (416).
/// An end beyond the resource is clamped to the last byte.
ByteRange? resolveRange(RangeSpec spec, int totalLength) {
  if (totalLength <= 0) return null;
  final last = totalLength - 1;
  if (spec.suffixLength != null) {
    final n = spec.suffixLength!;
    if (n <= 0) return null;
    return ByteRange(n >= totalLength ? 0 : totalLength - n, last);
  }
  final start = spec.start ?? 0;
  if (start > last) return null;
  final end = spec.end == null || spec.end! > last ? last : spec.end!;
  return ByteRange(start, end);
}

void _checkChunkSize(int chunkSize) {
  if (chunkSize <= 0) throw ArgumentError.value(chunkSize, 'chunkSize');
}

void _checkRange(int start, int end) {
  if (start < 0 || end < start) {
    throw ArgumentError('Invalid range $start-$end');
  }
}

/// Index of the chunk containing byte [offset].
int chunkIndexOf(int offset, int chunkSize) {
  _checkChunkSize(chunkSize);
  if (offset < 0) throw ArgumentError.value(offset, 'offset');
  return offset ~/ chunkSize;
}

/// All chunk indexes touched by the inclusive byte range `[start, end]`.
List<int> chunksForRange(int start, int end, int chunkSize) {
  _checkChunkSize(chunkSize);
  _checkRange(start, end);
  final first = start ~/ chunkSize;
  final last = end ~/ chunkSize;
  return List<int>.generate(last - first + 1, (i) => first + i);
}

/// Expands `[start, end]` outward to chunk boundaries. If [totalLength] is
/// given the aligned end is clamped to `totalLength - 1` (short last chunk).
ByteRange alignRangeToChunks(
  int start,
  int end,
  int chunkSize, {
  int? totalLength,
}) {
  _checkChunkSize(chunkSize);
  _checkRange(start, end);
  final alignedStart = (start ~/ chunkSize) * chunkSize;
  var alignedEnd = (end ~/ chunkSize + 1) * chunkSize - 1;
  if (totalLength != null && alignedEnd > totalLength - 1) {
    alignedEnd = totalLength - 1;
  }
  return ByteRange(alignedStart, alignedEnd);
}

/// Byte range covered by chunk [index]; the last chunk may be shorter.
ByteRange chunkByteRange(int index, int chunkSize, {int? totalLength}) {
  _checkChunkSize(chunkSize);
  if (index < 0) throw ArgumentError.value(index, 'index');
  final start = index * chunkSize;
  var end = start + chunkSize - 1;
  if (totalLength != null) {
    if (start >= totalLength) {
      throw ArgumentError('Chunk $index is beyond length $totalLength');
    }
    if (end > totalLength - 1) end = totalLength - 1;
  }
  return ByteRange(start, end);
}

/// Size in bytes of chunk [index] for a resource of [totalLength] bytes.
int chunkLength(int index, int chunkSize, int totalLength) =>
    chunkByteRange(index, chunkSize, totalLength: totalLength).length;

/// Number of chunks needed for [totalLength] bytes.
int chunkCount(int totalLength, int chunkSize) {
  _checkChunkSize(chunkSize);
  if (totalLength <= 0) return 0;
  return (totalLength + chunkSize - 1) ~/ chunkSize;
}

/// Offsets *inside chunk [index]* (inclusive) that overlap the absolute
/// [range]. Throws if the chunk does not overlap the range.
ByteRange sliceWithinChunk(int index, int chunkSize, ByteRange range) {
  final base = index * chunkSize;
  final s = range.start > base ? range.start - base : 0;
  final e = range.end < base + chunkSize - 1 ? range.end - base : chunkSize - 1;
  if (e < s) throw ArgumentError('Chunk $index does not overlap $range');
  return ByteRange(s, e);
}

/// Groups chunk indexes into maximal contiguous runs (input need not be
/// sorted or unique). Used to merge adjacent missing chunks into as few
/// upstream requests as possible.
List<ChunkRun> mergeContiguousChunks(Iterable<int> indexes) {
  final sorted = indexes.toSet().toList()..sort();
  final runs = <ChunkRun>[];
  int? first;
  int? prev;
  for (final i in sorted) {
    if (first == null) {
      first = i;
    } else if (i != prev! + 1) {
      runs.add(ChunkRun(first, prev));
      first = i;
    }
    prev = i;
  }
  if (first != null) runs.add(ChunkRun(first, prev!));
  return runs;
}

/// `Content-Range` header value for a 206 response.
String contentRangeHeader(int start, int end, int total) =>
    'bytes $start-$end/$total';

final RegExp _contentRangeRe = RegExp(
  r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$',
  caseSensitive: false,
);

/// Parses `Content-Range: bytes a-b/total`. Returns null if malformed
/// (this includes the `bytes */total` form used by 416 responses).
ContentRange? parseContentRange(String? header) {
  if (header == null) return null;
  final m = _contentRangeRe.firstMatch(header);
  if (m == null) return null;
  final t = m.group(3)!;
  return ContentRange(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    t == '*' ? null : int.parse(t),
  );
}
