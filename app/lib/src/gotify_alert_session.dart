import 'dart:async';

import 'package:core_models/core_models.dart';
import 'package:core_networking/core_networking.dart';
import 'package:service_gotify/service_gotify.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owns the same delivery implementation in the UI or foreground-service
/// isolate. The two owners are stopped/started serially by the controller.
class GotifyAlertSession {
  GotifyAlertSession({
    required ConnectionResolver resolver,
    required Map<String, String> headers,
    required this.onStatus,
  }) : _factory = DioFactory(resolver: resolver, globalHeaders: headers);

  final DioFactory _factory;
  final void Function(String status) onStatus;
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  final List<GotifySubscription> _subscriptions = <GotifySubscription>[];
  final Map<String, GotifyConnectionState> _states =
      <String, GotifyConnectionState>{};

  void start(List<Instance> instances) {
    for (final Instance instance in instances) {
      final String key = 'gotify.cursor.${instance.id}';
      _states[instance.id] = GotifyConnectionState.connecting;
      final GotifyAppNames appNames =
          GotifyAppNames(() => _factory.create(instance));
      final GotifySubscription subscription = GotifySubscription(
        instance: instance,
        createDio: () => _factory.create(instance),
        readCursor: () => _preferences.getInt(key),
        writeCursor: (int id) => _preferences.setInt(key, id),
        onMessages: (List<GotifyMessage> messages) async {
          await showGotifyArrivals(
            instance: instance,
            arrivals: messages,
            appNames: await appNames.load(),
          );
        },
        onState: (GotifyConnectionState state) {
          _states[instance.id] = state;
          final int connected = _states.values
              .where((GotifyConnectionState s) =>
                  s == GotifyConnectionState.connected)
              .length;
          onStatus(
            connected == _states.length
                ? 'Connected to $connected Gotify server'
                    '${connected == 1 ? '' : 's'}'
                : 'Connected to $connected of ${_states.length} Gotify servers'
                    ' - reconnecting',
          );
        },
      );
      _subscriptions.add(subscription);
      unawaited(subscription.start());
    }
  }

  Future<void> stop() async {
    await Future.wait<void>(
      _subscriptions
          .map((GotifySubscription subscription) => subscription.stop()),
    );
    _subscriptions.clear();
    _states.clear();
  }
}
