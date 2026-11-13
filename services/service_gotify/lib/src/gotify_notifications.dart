import 'package:core_models/core_models.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'models/gotify_models.dart';

/// Above this many recovered messages, they are shown as one summary.
const int gotifySummaryAbove = 5;

final FlutterLocalNotificationsPlugin _plugin =
    FlutterLocalNotificationsPlugin();

Future<void>? _ready;

// Android fixes a channel's sound and importance once created, so these IDs
// differ from the earlier silent ones; those are deleted in [_setUp].
const List<_Channel> _channels = <_Channel>[
  _Channel('gotify_sound_high', 'High priority', Importance.high),
  _Channel(
    'gotify_sound_normal',
    'Normal priority',
    Importance.defaultImportance,
  ),
  _Channel('gotify_sound_low', 'Low priority', Importance.defaultImportance),
];

const List<String> _retiredChannelIds = <String>[
  'gotify_high',
  'gotify_normal',
  'gotify_low',
];

class _Channel {
  const _Channel(this.id, this.name, this.importance);

  final String id;
  final String name;
  final Importance importance;
}

/// Sets up the plugin and its channels without prompting from a background
/// isolate. Permission is requested separately by the visible app.
Future<void> ensureGotifyNotificationsReady() async {
  try {
    await (_ready ??= _setUp());
  } on Exception {
    _ready = null;
    rethrow;
  }
}

Future<void> _setUp() async {
  await _plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_gotify_notification'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ),
  );
  final AndroidFlutterLocalNotificationsPlugin? android =
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  for (final String id in _retiredChannelIds) {
    await android?.deleteNotificationChannel(channelId: id);
  }
  for (final _Channel channel in _channels) {
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        channel.id,
        channel.name,
        importance: channel.importance,
      ),
    );
  }
}

/// Called only from the visible app, never from the service isolate.
Future<bool> requestGotifyNotificationPermission() async {
  await ensureGotifyNotificationsReady();
  final bool? android = await _plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  final bool? ios = await _plugin
      .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>()
      ?.requestPermissions(alert: true, sound: true);
  return android ?? ios ?? false;
}

_Channel _channelFor(GotifyMessage message) => switch (message.level) {
      GotifyPriority.high => _channels[0],
      GotifyPriority.normal => _channels[1],
      GotifyPriority.low => _channels[2],
    };

/// Posts [arrivals] from [instance]. [appNames] maps application ids to names
/// for the title of messages that have none.
Future<void> showGotifyArrivals({
  required Instance instance,
  required List<GotifyMessage> arrivals,
  required Map<int, String> appNames,
}) async {
  await ensureGotifyNotificationsReady();
  if (arrivals.length > gotifySummaryAbove) {
    await _plugin.show(
      id: _notificationId(instance.id, 'summary'),
      title: '${arrivals.length} new messages',
      body: instance.name,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channels[1].id,
          _channels[1].name,
          importance: _channels[1].importance,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
    return;
  }
  for (final GotifyMessage message in arrivals) {
    final _Channel channel = _channelFor(message);
    final String? appName = appNames[message.appId];
    await _plugin.show(
      id: _notificationId(instance.id, '${message.id}'),
      title: message.title ?? appName ?? instance.name,
      body: message.message.isNotEmpty ? message.message : appName,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          importance: channel.importance,
          priority: switch (message.level) {
            GotifyPriority.high => Priority.high,
            GotifyPriority.normal => Priority.defaultPriority,
            GotifyPriority.low => Priority.low,
          },
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }
}

// Stable across isolates and process restarts, so a replay replaces its own
// notification rather than creating another one.
int _notificationId(String instanceId, String messageId) {
  int hash = 0x811c9dc5;
  for (final int unit in 'gotify:$instanceId:$messageId'.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
  }
  return hash;
}
