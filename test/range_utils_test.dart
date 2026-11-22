import 'package:flutter_test/flutter_test.dart';
import 'package:video_partial_cache/src/proxy/range_utils.dart';

const cs = 262144; // 256KB

void main() {
  group('parseRangeHeader', () {
    test('null / blank / malformed -> null', () {
      expect(parseRangeHeader(null), isNull);
      expect(parseRangeHeader(''), isNull);
      expect(parseRangeHeader('bytes='), isNull);
      expect(parseRangeHeader('bytes=-'), isNull);
      expect(parseRangeHeader('items=0-5'), isNull);
      expect(parseRangeHeader('bytes=10-5'), isNull);
      expect(parseRangeHeader('garbage'), isNull);
    });
    test('closed range', () {
      final r = parseRangeHeader('bytes=300000-310000')!;
      expect(r.start, 300000);
      expect(r.end, 310000);
    });
    test('open-ended', () {
      final r = parseRangeHeader('bytes=500-')!;
      expect(r.start, 500);
      expect(r.end, isNull);
    });
    test('suffix', () {
      final r = parseRangeHeader('bytes=-500')!;
      expect(r.start, isNull);
      expect(r.suffixLength, 500);
    });
    test('case/space tolerant and multi-range uses first', () {
      final r = parseRangeHeader('Bytes = 0-9, 20-29')!;
      expect(r.start, 0);
      expect(r.end, 9);
    });
  });

  group('resolveRange', () {
    test('open-ended resolves to last byte', () {
      expect(
        resolveRange(parseRangeHeader('bytes=500-')!, 1000),
        const ByteRange(500, 999),
      );
    });
    test('end beyond total is clamped', () {
      expect(
        resolveRange(parseRangeHeader('bytes=0-5000')!, 1000),
        const ByteRange(0, 999),
      );
    });
    test('start beyond total -> null', () {
      expect(resolveRange(parseRangeHeader('bytes=1000-')!, 1000), isNull);
    });
    test('suffix', () {
      expect(
        resolveRange(parseRangeHeader('bytes=-100')!, 1000),
        const ByteRange(900, 999),
      );
      expect(
        resolveRange(parseRangeHeader('bytes=-5000')!, 1000),
        const ByteRange(0, 999),
      );
      expect(resolveRange(parseRangeHeader('bytes=-0')!, 1000), isNull);
    });
    test('empty resource', () {
      expect(resolveRange(const RangeSpec(start: 0), 0), isNull);
    });
  });

  group('chunksForRange', () {
    test('start at 0', () {
      expect(chunksForRange(0, 0, cs), [0]);
      expect(chunksForRange(0, 100, cs), [0]);
    });
    test('exact chunk boundaries', () {
      expect(chunksForRange(0, cs - 1, cs), [0]);
      expect(chunksForRange(cs, 2 * cs - 1, cs), [1]);
      expect(chunksForRange(cs - 1, cs, cs), [0, 1]);
      expect(chunksForRange(cs, cs, cs), [1]);
    });
    test('example from the spec: 300000-310000 -> chunk 1', () {
      expect(chunksForRange(300000, 310000, cs), [1]);
      final a = alignRangeToChunks(300000, 310000, cs);
      expect(a, const ByteRange(262144, 524287));
    });
    test('spanning many chunks', () {
      expect(
        chunksForRange(10, 10 * cs + 5, cs),
        List<int>.generate(11, (i) => i),
      );
      expect(chunksForRange(3 * cs + 7, 7 * cs, cs), [3, 4, 5, 6, 7]);
    });
    test('invalid args', () {
      expect(() => chunksForRange(-1, 5, cs), throwsArgumentError);
      expect(() => chunksForRange(5, 4, cs), throwsArgumentError);
      expect(() => chunksForRange(0, 5, 0), throwsArgumentError);
    });
    test('small chunk size', () {
      expect(chunksForRange(5, 14, 10), [0, 1]);
    });
  });

  group('alignRangeToChunks', () {
    test('already aligned', () {
      expect(alignRangeToChunks(0, cs - 1, cs), const ByteRange(0, cs - 1));
      expect(
        alignRangeToChunks(cs, 3 * cs - 1, cs),
        const ByteRange(cs, 3 * cs - 1),
      );
    });
    test('open-ended style: resolved to total-1 then aligned & clamped', () {
      final total = 3 * cs + 1000; // last chunk smaller
      final a = alignRangeToChunks(500, total - 1, cs, totalLength: total);
      expect(a, ByteRange(0, total - 1));
    });
    test('last chunk smaller than chunkSize', () {
      final total = 2 * cs + 10;
      expect(
        alignRangeToChunks(2 * cs + 3, 2 * cs + 5, cs, totalLength: total),
        ByteRange(2 * cs, total - 1),
      );
    });
    test('without total the end is not clamped', () {
      expect(alignRangeToChunks(0, 5, cs), const ByteRange(0, cs - 1));
    });
  });

  group('chunk geometry', () {
    test('chunkByteRange', () {
      expect(chunkByteRange(0, cs), const ByteRange(0, cs - 1));
      expect(chunkByteRange(2, cs), ByteRange(2 * cs, 3 * cs - 1));
      final total = 2 * cs + 10;
      expect(
        chunkByteRange(2, cs, totalLength: total),
        ByteRange(2 * cs, total - 1),
      );
      expect(chunkLength(2, cs, total), 10);
      expect(chunkLength(1, cs, total), cs);
      expect(
        () => chunkByteRange(3, cs, totalLength: total),
        throwsArgumentError,
      );
    });
    test('chunkCount', () {
      expect(chunkCount(0, cs), 0);
      expect(chunkCount(1, cs), 1);
      expect(chunkCount(cs, cs), 1);
      expect(chunkCount(cs + 1, cs), 2);
    });
    test('sliceWithinChunk', () {
      expect(
        sliceWithinChunk(1, 100, const ByteRange(150, 180)),
        const ByteRange(50, 80),
      );
      expect(
        sliceWithinChunk(1, 100, const ByteRange(50, 250)),
        const ByteRange(0, 99),
      );
      expect(
        sliceWithinChunk(0, 100, const ByteRange(50, 250)),
        const ByteRange(50, 99),
      );
      expect(
        sliceWithinChunk(2, 100, const ByteRange(50, 250)),
        const ByteRange(0, 50),
      );
      expect(
        () => sliceWithinChunk(5, 100, const ByteRange(0, 10)),
        throwsArgumentError,
      );
    });
  });

  group('mergeContiguousChunks', () {
    test('empty', () => expect(mergeContiguousChunks([]), isEmpty));
    test('single', () {
      expect(mergeContiguousChunks([4]), [const ChunkRun(4, 4)]);
    });
    test('merges adjacent, splits gaps, handles unsorted/dupes', () {
      expect(mergeContiguousChunks([7, 1, 2, 3, 3, 9, 8, 20]), [
        const ChunkRun(1, 3),
        const ChunkRun(7, 9),
        const ChunkRun(20, 20),
      ]);
    });
  });

  group('Content-Range', () {
    test('format', () {
      expect(contentRangeHeader(0, 9, 100), 'bytes 0-9/100');
    });
    test('parse', () {
      final c = parseContentRange('bytes 0-9/100')!;
      expect([c.start, c.end, c.total], [0, 9, 100]);
      expect(parseContentRange('bytes 0-9/*')!.total, isNull);
      expect(parseContentRange('bytes */100'), isNull);
      expect(parseContentRange(null), isNull);
    });
  });
}
