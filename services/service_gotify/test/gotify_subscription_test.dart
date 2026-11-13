import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core_models/core_models.dart';
import 'package:core_networking/core_networking.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_gotify/service_gotify.dart';

void main() {
  late _GotifyServer server;
  final List<GotifySubscription> subscriptions = <GotifySubscription>[];
  int? savedCursor;

  GotifySubscription subscribe({
    required Future<void> Function(List<GotifyMessage>) onMessages,
    void Function(GotifyConnectionState)? onState,
  }) {
    final Instance instance = Instance(
      id: 'test',
      name: 'Test Gotify',
      kind: ServiceKind.gotify,
      localUrl: server.url,
      externalUrl: '',
      urlMode: UrlMode.forceLocal,
      auth: const InstanceAuth.apiKey(apiKey: 'client-token'),
      customHeaders: const <String, String>{
        'Authorization': 'Basic proxy-auth',
      },
    );
    final GotifySubscription subscription = GotifySubscription(
      instance: instance,
      createDio: () async => Dio(
        BaseOptions(
          baseUrl: server.url,
          headers: instance.customHeaders,
        ),
      )..interceptors.add(
          AuthInterceptor(kind: instance.kind, auth: instance.auth),
        ),
      readCursor: () async => savedCursor,
      writeCursor: (int id) async => savedCursor = id,
      onMessages: onMessages,
      onState: onState ?? (_) {},
      retryBase: const Duration(milliseconds: 10),
      retryMax: const Duration(milliseconds: 50),
    );
    subscriptions.add(subscription);
    unawaited(subscription.start());
    return subscription;
  }

  setUp(() async {
    savedCursor = null;
    server = await _GotifyServer.start();
  });

  tearDown(() async {
    for (final GotifySubscription subscription in subscriptions) {
      await subscription.stop();
    }
    subscriptions.clear();
    await server.close();
  });

  test('skips backlog, authenticates the socket, and delivers live messages',
      () async {
    server.ids.addAll(<int>[5, 4]);
    final Completer<void> connected = Completer<void>();
    final Completer<List<int>> received = Completer<List<int>>();
    subscribe(
      onState: (GotifyConnectionState state) {
        if (state == GotifyConnectionState.connected &&
            !connected.isCompleted) {
          connected.complete();
        }
      },
      onMessages: (List<GotifyMessage> messages) async =>
          received.complete(messages.map((GotifyMessage m) => m.id).toList()),
    );
    await connected.future.timeout(const Duration(seconds: 5));
    expect(savedCursor, 5);
    expect(server.messageRequests.length, 2);
    expect(server.handshakes.single.uri.path, '/gotify/stream');
    expect(server.handshakes.single.uri.query, isEmpty);
    expect(
      server.handshakes.single.headers.value('X-Gotify-Key'),
      'client-token',
    );
    expect(
      server.handshakes.single.headers.value('Authorization'),
      'Basic proxy-auth',
    );

    server.sockets.single.add(jsonEncode(_message(6)));
    expect(await received.future.timeout(const Duration(seconds: 5)), <int>[6]);
    expect(server.messageRequests.length, 2);
  });

  test('recovers arrivals between the first baseline and socket handshake',
      () async {
    server.ids.add(5);
    server.onConnect = (WebSocket socket) {
      server.ids.insert(0, 6);
      socket.add(jsonEncode(_message(6)));
    };
    final List<int> delivered = <int>[];
    final Completer<void> connected = Completer<void>();
    subscribe(
      onMessages: (List<GotifyMessage> messages) async =>
          delivered.addAll(messages.map((GotifyMessage m) => m.id)),
      onState: (GotifyConnectionState state) {
        if (state == GotifyConnectionState.connected &&
            !connected.isCompleted) {
          connected.complete();
        }
      },
    );
    await connected.future.timeout(const Duration(seconds: 5));
    server.sockets.single.add(jsonEncode(_message(7)));
    await _waitUntil(() => savedCursor == 7);
    expect(delivered, <int>[6, 7]);
  });

  test(
      'reconnect paginates all missed messages and deduplicates buffered frames',
      () async {
    savedCursor = 1;
    server.ids.add(1);
    final Completer<void> connected = Completer<void>();
    final Completer<void> caughtUp = Completer<void>();
    final List<int> delivered = <int>[];
    subscribe(
      onState: (GotifyConnectionState state) {
        if (state == GotifyConnectionState.connected &&
            !connected.isCompleted) {
          connected.complete();
        } else if (state == GotifyConnectionState.connected &&
            !caughtUp.isCompleted) {
          caughtUp.complete();
        }
      },
      onMessages: (List<GotifyMessage> messages) async =>
          delivered.addAll(messages.map((GotifyMessage m) => m.id)),
    );
    await connected.future.timeout(const Duration(seconds: 5));
    server.ids
      ..clear()
      ..addAll(List<int>.generate(452, (int i) => 452 - i));
    server.onConnect = (WebSocket socket) {
      socket.add(jsonEncode(_message(452)));
      socket.add(jsonEncode(_message(453)));
    };
    final Completer<void> live = Completer<void>();
    server.onMessageRequest = () {
      if (server.messageRequests.length >= 4 && !live.isCompleted) {
        live.complete();
      }
    };
    await server.sockets.first.close();
    await caughtUp.future.timeout(const Duration(seconds: 5));
    // A final live frame proves buffered frames have been drained.
    server.sockets.last.add(jsonEncode(_message(454)));
    await _waitUntil(() => savedCursor == 454);
    expect(delivered, List<int>.generate(453, (int i) => i + 2));
    expect(server.messageRequests.length, 4);
    expect(
      server.messageRequests
          .skip(1)
          .map((Uri uri) => uri.queryParameters['limit']),
      everyElement('200'),
    );
    expect(live.isCompleted, isTrue);
  });

  test('does not acknowledge failed notifications and retries on reconnect',
      () async {
    savedCursor = 1;
    server.ids.addAll(<int>[2, 1]);
    int attempts = 0;
    final Completer<void> delivered = Completer<void>();
    subscribe(
      onMessages: (List<GotifyMessage> messages) async {
        attempts++;
        expect(savedCursor, 1);
        if (attempts == 1) throw const FormatException('Notification failed');
        expect(messages.single.id, 2);
        delivered.complete();
      },
    );
    await delivered.future.timeout(const Duration(seconds: 5));
    await _waitUntil(() => savedCursor == 2);
    expect(attempts, 2);
    expect(server.handshakes.length, 2);
  });

  test('an empty initial server still alerts for its first message', () async {
    final Completer<void> connected = Completer<void>();
    final Completer<void> delivered = Completer<void>();
    subscribe(
      onState: (GotifyConnectionState state) {
        if (state == GotifyConnectionState.connected &&
            !connected.isCompleted) {
          connected.complete();
        }
      },
      onMessages: (List<GotifyMessage> messages) async {
        expect(messages.single.id, 1);
        delivered.complete();
      },
    );
    await connected.future.timeout(const Duration(seconds: 5));
    expect(savedCursor, 0);
    server.sockets.single.add(jsonEncode(_message(1)));
    await delivered.future.timeout(const Duration(seconds: 5));
  });

  test('stopping cancels a catch-up request without delivering or retrying',
      () async {
    savedCursor = 1;
    server.ids.addAll(<int>[2, 1]);
    server.blockMessages = true;
    final Completer<void> requested = Completer<void>();
    server.onMessageRequest = requested.complete;
    final GotifySubscription subscription = subscribe(
      onMessages: (_) async => fail('A stopped subscription must not notify'),
    );
    await requested.future.timeout(const Duration(seconds: 5));
    await subscription.stop().timeout(const Duration(seconds: 5));
    expect(savedCursor, 1);
    expect(server.handshakes.length, 1);
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail('Timed out waiting for Gotify delivery');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Map<String, Object> _message(int id) => <String, Object>{
      'id': id,
      'appid': 1,
      'message': 'Message $id',
      'priority': 5,
    };

class _GotifyServer {
  _GotifyServer(this.server) {
    server.listen((HttpRequest request) async {
      if (request.uri.path == '/gotify/stream') {
        handshakes.add(request);
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        onConnect?.call(socket);
        return;
      }
      if (request.uri.path != '/gotify/message') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      messageRequests.add(request.uri);
      onMessageRequest?.call();
      if (blockMessages) return;
      final int? since =
          int.tryParse(request.uri.queryParameters['since'] ?? '');
      final int limit = int.parse(request.uri.queryParameters['limit']!);
      final List<int> matching =
          ids.where((int id) => since == null || id < since).toList();
      final List<int> page = matching.take(limit).toList();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object>{
          'messages': page.map(_message).toList(),
          'paging': <String, Object>{
            if (matching.length > page.length) ...<String, Object>{
              'since': page.last,
              'next': 'next-page',
            },
          },
        }),
      );
      await request.response.close();
    });
  }

  static Future<_GotifyServer> start() async =>
      _GotifyServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer server;
  final List<int> ids = <int>[];
  final List<WebSocket> sockets = <WebSocket>[];
  final List<HttpRequest> handshakes = <HttpRequest>[];
  final List<Uri> messageRequests = <Uri>[];
  void Function(WebSocket socket)? onConnect;
  void Function()? onMessageRequest;
  bool blockMessages = false;

  String get url => 'http://127.0.0.1:${server.port}/gotify/';

  Future<void> close() async {
    for (final WebSocket socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}
