import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:core_models/core_models.dart';
import 'package:dio/dio.dart';

import 'gotify_api.dart';
import 'models/gotify_models.dart';

enum GotifyConnectionState { connecting, connected, retrying, stopped }

/// One connection, shared by foreground and Android background delivery.
/// Only message ids are persisted; credentials never enter the cursor store.
class GotifySubscription {
  GotifySubscription({
    required this.instance,
    required this.createDio,
    required this.readCursor,
    required this.writeCursor,
    required this.onMessages,
    required this.onState,
    this.retryBase = const Duration(seconds: 1),
    this.retryMax = const Duration(minutes: 1),
  });

  final Instance instance;
  final Future<Dio> Function() createDio;
  final Future<int?> Function() readCursor;
  final Future<void> Function(int id) writeCursor;
  final Future<void> Function(List<GotifyMessage> messages) onMessages;
  final void Function(GotifyConnectionState state) onState;
  final Duration retryBase;
  final Duration retryMax;

  final Completer<void> _stop = Completer<void>();
  Future<void>? _running;
  Dio? _dio;
  HttpClient? _http;
  WebSocket? _socket;
  int? _cursor;

  Future<void> start() => _running ??= _run();

  Future<void> stop() async {
    if (!_stop.isCompleted) _stop.complete();
    _dio?.close(force: true);
    _http?.close(force: true);
    await _socket?.close();
    await _running;
  }

  Future<void> _run() async {
    int failures = 0;
    while (!_stop.isCompleted) {
      final Stopwatch connectedFor = Stopwatch();
      try {
        _cursor ??= await readCursor();
        if (_stop.isCompleted) break;
        onState(GotifyConnectionState.connecting);
        final Dio dio = await createDio();
        _dio = dio;
        if (_cursor == null) {
          final GotifyMessagePage baseline =
              await GotifyApi(dio).getMessages(limit: 1);
          if (_stop.isCompleted) break;
          await _commit(
            baseline.messages.isEmpty ? 0 : baseline.messages.first.id,
          );
        }
        if (_stop.isCompleted) break;
        final HttpClient http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        if (instance.allowSelfSignedCerts) {
          http.badCertificateCallback =
              (X509Certificate _, String __, int ___) => true;
        }
        _http = http;
        final Uri endpoint = Uri.parse(dio.options.baseUrl).resolve('stream');
        final InstanceAuth auth = instance.auth;
        if (auth is! InstanceAuthApiKey || auth.apiKey.isEmpty) {
          throw const FormatException('Gotify requires a client token');
        }
        final Map<String, dynamic> headers =
            Map<String, dynamic>.of(dio.options.headers)
              ..removeWhere(
                (String key, dynamic _) => key.toLowerCase() == 'x-gotify-key',
              )
              ..['X-Gotify-Key'] = auth.apiKey;
        final WebSocket socket = await WebSocket.connect(
          endpoint
              .replace(scheme: endpoint.scheme == 'https' ? 'wss' : 'ws')
              .toString(),
          headers: headers,
          customClient: http,
        ).timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            http.close(force: true);
            throw TimeoutException('Gotify handshake timed out');
          },
        );
        _socket = socket;
        socket.pingInterval = const Duration(seconds: 30);
        // Subscribe before REST catch-up. Frames received during catch-up
        // stay buffered and are deduplicated against the committed cursor.
        final StreamIterator<dynamic> frames = StreamIterator<dynamic>(socket);
        try {
          await _catchUp(GotifyApi(dio));
          if (_stop.isCompleted) break;
          onState(GotifyConnectionState.connected);
          connectedFor.start();
          while (!_stop.isCompleted && await frames.moveNext()) {
            final Object? frame = frames.current;
            if (frame is! String) throw const GotifyUnexpectedAnswer();
            final Object? data = jsonDecode(frame);
            if (data is! Map<String, dynamic> || data['id'] is! int) {
              throw const GotifyUnexpectedAnswer();
            }
            await _deliver(<GotifyMessage>[GotifyMessage.fromJson(data)]);
            failures = 0;
          }
        } finally {
          if (connectedFor.elapsed >= const Duration(minutes: 1)) failures = 0;
          await frames.cancel();
        }
      } on Exception {
        // Never log exception text: a handshake error may contain proxy
        // credentials or a server URL. The caller exposes the retry state.
        if (!_stop.isCompleted) onState(GotifyConnectionState.retrying);
      } finally {
        await _socket?.close();
        _socket = null;
        _http?.close(force: true);
        _http = null;
        _dio?.close(force: true);
        _dio = null;
      }
      if (_stop.isCompleted) break;
      onState(GotifyConnectionState.retrying);
      final int delay = min(
        retryMax.inMilliseconds,
        retryBase.inMilliseconds * (1 << min(failures++, 10)),
      );
      final Completer<void> retry = Completer<void>();
      final Timer timer = Timer(Duration(milliseconds: delay), retry.complete);
      try {
        await Future.any<void>(<Future<void>>[_stop.future, retry.future]);
      } finally {
        timer.cancel();
      }
    }
    onState(GotifyConnectionState.stopped);
  }

  Future<void> _catchUp(GotifyApi api) async {
    final Map<int, GotifyMessage> pending = <int, GotifyMessage>{};
    int? since;
    do {
      final GotifyMessagePage page = await api.getMessages(
        limit: GotifyApi.maxPageSize,
        since: since,
      );
      if (_stop.isCompleted) return;
      bool reachedCursor = false;
      for (final GotifyMessage message in page.messages) {
        if (message.id <= _cursor!) {
          reachedCursor = true;
        } else {
          pending[message.id] = message;
        }
      }
      if (reachedCursor || page.nextSince == null || page.messages.isEmpty) {
        break;
      }
      if (since != null && page.nextSince! >= since) {
        throw const GotifyUnexpectedAnswer();
      }
      since = page.nextSince;
    } while (!_stop.isCompleted);
    final List<GotifyMessage> ordered = pending.values.toList()
      ..sort((GotifyMessage a, GotifyMessage b) => a.id.compareTo(b.id));
    await _deliver(ordered);
  }

  Future<void> _deliver(List<GotifyMessage> messages) async {
    if (_stop.isCompleted) return;
    final List<GotifyMessage> fresh = messages
        .where((GotifyMessage message) => message.id > (_cursor ?? 0))
        .toList();
    if (fresh.isEmpty) return;
    await onMessages(fresh);
    // A failed notification is retried by REST catch-up, not acknowledged.
    await _commit(fresh.last.id);
  }

  Future<void> _commit(int id) async {
    await writeCursor(id);
    _cursor = id;
  }
}
