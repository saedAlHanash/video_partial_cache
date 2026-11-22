import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Lifecycle wrapper around the local shelf HTTP server (127.0.0.1 only,
/// ephemeral port).
class ProxyServer {
  ProxyServer(this._handler);

  final Handler _handler;
  HttpServer? _server;

  bool get isRunning => _server != null;

  /// The bound port. Throws if the server is not running.
  int get port {
    final s = _server;
    if (s == null) throw StateError('ProxyServer is not running');
    return s.port;
  }

  Future<void> start() async {
    if (_server != null) return;
    _server = await shelf_io.serve(
      _handler,
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
    // Players keep connections open; don't let idle ones linger forever.
    _server!.idleTimeout = const Duration(seconds: 60);
  }

  Future<void> stop({bool force = true}) async {
    final s = _server;
    _server = null;
    await s?.close(force: force);
  }
}
