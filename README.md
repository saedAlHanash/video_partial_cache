# video_partial_cache

Facebook-style progressive video caching for Flutter. Everything the player
downloads (watched **or** only buffered) is persisted on disk in fixed-size
chunks; replays and seeks into already-downloaded parts are served from disk
with no network.

* Pure Dart: no native code, no platform channels (works on Android and iOS).
* Works with any player that can play a URL (`video_player`, `chewie`, ...).
* Direct MP4 / progressive URLs over HTTP byte ranges, and **HLS** (`.m3u8`)
  streams (see *HLS* below). DASH is not implemented.

## Installation

```yaml
dependencies:
  video_partial_cache:
    path: ../video_partial_cache   # or a git dependency
```

### Platform setup (cleartext traffic to localhost)

The player talks plain HTTP to `127.0.0.1`, which must be allowed:

**Android** – `android/app/src/main/AndroidManifest.xml`

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<application android:usesCleartextTraffic="true" ...>
```

**iOS** – `ios/Runner/Info.plist`

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key>
  <true/>
</dict>
```

## Usage

```dart
// Create once (singleton / provider) and init at startup.
final cache = VideoPartialCache();
await cache.init();

// Wherever you create a player:
final url = cache.getPlayableUrl('https://example.com/video.mp4');
final controller = VideoPlayerController.networkUrl(Uri.parse(url));
await controller.initialize();

// Housekeeping
final bytes = await cache.getCacheSizeBytes();
final stats = await cache.getStats();     // per-video breakdown + hit/miss
final ranges = await cache.getCachedRanges(cache.videoIdFor(url)); // for a seek bar
await cache.clearVideo('some-id');
await cache.clearCache();
await cache.dispose();                    // stops the proxy
```

For signed URLs whose query string changes on every request, pass a stable id
so the cache can recognise the video:

```dart
cache.getPlayableUrl(signedUrl, videoId: 'lesson-42');
```

See `example/` for a complete app.

## Configuration

| Parameter | Default | Meaning |
|---|---|---|
| `chunkSizeBytes` | 256 KB | Cache granularity. Requests are aligned to multiples of it. Changing it requires clearing the cache. |
| `maxCacheSizeBytes` | 500 MB | Total disk budget; eviction across all videos. Changeable at runtime. |
| `evictionStrategy` | `lru` | What is removed first when full (`lru`, `lfu`, `fifo`, `lruVideo`). Changeable at runtime. |
| `cacheDirectory` | `<ApplicationSupport>/video_partial_cache` | Where chunks and the index live. |
| `onLog` | `null` | `void Function(String)`; receives `HIT` / `PART` / `MISS` lines per request. **Only called in debug builds.** |
| `httpClient` | internal `http.Client` | Inject your own (e.g. for tests or custom headers). |
| `upstreamTimeout` | 30 s | Origin response / stall timeout (→ HTTP 504). |
| `upstreamHeaders` | `{}` | Extra headers for the origin (auth, referer). The player's `User-Agent` is forwarded automatically; some CDNs (e.g. w3schools) reject Dart's default one. |
| `maxStallDuration` | 60 s | How long a started response waits for a temporarily unreachable origin before giving up. |
| `maxUpstreamRunChunks` | 8 | Max chunks per upstream request (bounds waste for open-ended `bytes=N-` requests if the player stops). |

```dart
VideoPartialCache(
  chunkSizeBytes: 512 * 1024,
  maxCacheSizeBytes: 1024 * 1024 * 1024,
  onLog: (m) => debugPrint(m),
);
```

## Managing the cache at runtime

Everything below can be changed while the app runs (for example from a
settings screen):

```dart
// Limit + algorithm (a smaller limit evicts immediately, returns bytes freed)
await cache.updateSettings(
  maxCacheSizeBytes: 2 * 1024 * 1024 * 1024,
  strategy: EvictionStrategy.lruVideo,
);
final CacheSettings s = cache.settings;

// Inspect
final stats = await cache.getStats();    // total/max bytes, strategy, hit ratio
for (final v in stats.videos) {          // title, bytes, %, lastAccess, hits, pinned
  print('${v.title ?? v.videoId}: ${v.cachedBytes}');
}

// Act
await cache.setPinned('lesson-42', true);               // never auto-evicted
await cache.trimTo(500 * 1024 * 1024);                  // free space now
await cache.clearVideosOlderThan(const Duration(days: 30)); // skips pinned
await cache.clearVideo('lesson-42');                    // explicit delete
```

Name videos for such a screen with `getPlayableUrl(url, title: 'Lesson 1')`.

| `EvictionStrategy` | Removes first |
|---|---|
| `lru` (default) | the chunk read longest ago |
| `lfu` | the chunk served least often (ties: least recent) |
| `fifo` | the chunk written first |
| `lruVideo` | a whole video at a time, least recently played first |

Pinned videos are skipped by every strategy; if everything left is pinned and
the cache is full, new chunks are simply not cached (playback is unaffected).
Persist the user's choices in your app and pass them to the constructor at
start-up (`maxCacheSizeBytes`, `evictionStrategy`).

## How it works

1. `init()` starts a small [shelf](https://pub.dev/packages/shelf) HTTP server
   on `127.0.0.1` (ephemeral port).
2. `getPlayableUrl(url)` returns `http://127.0.0.1:PORT/proxy/<id>?src=<url>`.
3. ExoPlayer / AVPlayer send normal `Range` requests to that URL.
4. For each request the proxy computes which fixed-size chunks cover the
   range (e.g. `bytes=300000-310000` with 256 KB chunks → chunk 1, bytes
   262144–524287). Chunks already on disk are read locally; missing ones are
   fetched from the origin (adjacent missing chunks are merged into one
   upstream range request), streamed to the player **and** written to disk.
5. The reply is a correct `206` with `Content-Range`, `Content-Length` and
   `Accept-Ranges: bytes`, trimmed to exactly what the player asked for. A
   request without `Range` gets the whole file (`200`).
6. Concurrent/overlapping requests (seeks) share in-flight chunk fetches, so a
   chunk is never downloaded twice at the same time.
7. The index (which chunks exist, sizes, last access, total video length) is
   stored in a Hive box and survives restarts. Chunk files are
   `chunks/<videoId>/<n>.chunk`.

Failures never hang: origin unreachable → `503` (or, once a response has started, the response stalls up to `maxStallDuration` waiting for the origin, so the player shows buffering instead of failing), timeout → `504`, origin
`401/403/404/410` is passed through, bad requests → `400/404/405`. If an origin
ignores `Range` (answers `200`) the video is streamed through uncached.

### Architecture / extension points

```
lib/src/cache/   cache_store (Hive index + chunk IO), eviction_policy (LRU), cache_entry, cache_stats
lib/src/proxy/   proxy_server (shelf lifecycle), mp4_range_handler, range_utils (pure functions)
```

`HlsHandler` sits next to `Mp4RangeHandler` and reuses `CacheStore` (a segment
is just a "video id + entry index" entry) and the eviction policy.

## HLS

`getPlayableUrl('https://.../master.m3u8')` is detected automatically (force it
with `hls: true`) and returns `http://127.0.0.1:PORT/hls/<id>/m.m3u8?src=...`.

* Playlists are fetched from the origin first (their signed urls expire),
  rewritten so every variant, audio/subtitle rendition, init section and
  segment goes through the proxy, and stored. When the origin is unreachable the
  stored playlist is served, so a fully played video plays **offline**.
* Each segment is stored whole under a key built from its **position in its
  playlist** (not its url), so signed/changing urls, and CDNs that serve every
  segment from one path (`segment.m4s?sid=7`), are handled.
* Not cached, streamed through: live playlists (no `#EXT-X-ENDLIST`),
  `#EXT-X-BYTERANGE` streams, and encryption keys (never written to disk).
  DRM (`skd://`) uris are left untouched and are not supported.
* Use **one `videoId` per playlist**, not per quality: the master already holds
  all qualities and the player switches between them.
* If the origin replaces a video under the same `videoId`, call
  `clearVideo(videoId)`.

## Design notes

* **Hive over sqflite**: the index is loaded fully into memory at startup and
  then only receives small upserts, which is exactly Hive's sweet spot, and
  Hive is pure Dart. sqflite is a platform-channel plugin, which would violate
  the "no native code" requirement. `lastAccess` touches are kept in memory
  and flushed in batches (every 5 s and on `dispose()`).
* **Eviction** runs before a chunk is written: if the new chunk would exceed
  `maxCacheSizeBytes`, least-recently-used chunks (across all videos) are
  deleted until it fits.
* The only platform dependency is `path_provider`, used solely to find the
  default cache directory; pass `cacheDirectory` to avoid it.

## Limitations

* MP4 / progressive and HLS only (no DASH, no DRM, no live caching).
* Origin must support `Range` to be cached.
* The proxy listens on loopback and does not authenticate callers.
* `chunkSizeBytes` is part of the on-disk format.
