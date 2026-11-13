import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core_models/core_models.dart';
import 'package:core_networking/core_networking.dart';
import 'package:core_profile/core_profile.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:service_gotify/service_gotify.dart';

import 'gotify_alert_session.dart';
import 'gotify_background_task.dart';
import 'preferences.dart';

final gotifyDeliveryStatusProvider = StateProvider<String?>((Ref ref) => null);

final _gotifyDeliveryControllerProvider = Provider<_GotifyDeliveryController>(
  (Ref ref) {
    final _GotifyDeliveryController controller = _GotifyDeliveryController(
      resolver: ref.watch(connectionResolverProvider),
      onStatus: (String status) {
        scheduleMicrotask(() {
          if (ref.mounted) {
            ref.read(gotifyDeliveryStatusProvider.notifier).state = status;
          }
        });
      },
    );
    ref.onDispose(controller.dispose);
    return controller;
  },
);

/// Keeps one socket owner for the active profile, independent of the screen
/// and application filter. Android background mode moves ownership to a task.
final gotifyAlertsListenerProvider = Provider<void>((Ref ref) {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  final _GotifyDeliveryController controller =
      ref.watch(_gotifyDeliveryControllerProvider);
  final List<Instance> instances =
      ref.watch(instancesByKindProvider(ServiceKind.gotify));
  final Map<String, String> headers =
      ref.watch(activeProfileProvider)?.globalHeaders ??
          const <String, String>{};
  final bool background = ref.watch(
    preferencesProvider
        .select((Preferences p) => p.gotifyBackgroundNotifications),
  );
  controller.configure(instances, headers, background: background);
});

class _GotifyDeliveryController with WidgetsBindingObserver {
  _GotifyDeliveryController({required this.resolver, required this.onStatus}) {
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      FlutterForegroundTask.initCommunicationPort();
      FlutterForegroundTask.addTaskDataCallback(_onTaskData);
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'gotify_connection',
          channelName: 'Gotify connection',
          channelDescription: 'Background connection to your Gotify servers',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowAutoRestart: false,
          stopWithTask: false,
        ),
      );
    }
  }

  final ConnectionResolver resolver;
  final void Function(String status) onStatus;
  List<Instance> _instances = const <Instance>[];
  Map<String, String> _headers = const <String, String>{};
  bool _background = false;
  bool _disposed = false;
  String? _configuration;
  GotifyAlertSession? _foreground;
  Future<void> _pending = Future<void>.value();
  Completer<void>? _taskReply;
  String? _expectedReply;
  Map<String, Object>? _activeTaskConfiguration;

  bool get _visible {
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  void configure(
    List<Instance> instances,
    Map<String, String> headers, {
    required bool background,
  }) {
    _instances = instances;
    _headers = headers;
    _background = Platform.isAndroid && background;
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive) _schedule();
  }

  void _schedule() {
    _pending = _pending.then((_) => _apply()).catchError(
      (Object error, StackTrace stack) {
        debugPrint('Gotify delivery setup failed (${error.runtimeType}).');
        _configuration = null;
        onStatus('Unable to start Gotify delivery. Reopen Atrium or toggle '
            'background notifications to retry.');
      },
    );
  }

  Future<void> _apply() async {
    if (_disposed) return;
    final List<Instance> instances = List<Instance>.of(_instances);
    final Map<String, String> headers = Map<String, String>.of(_headers);
    final bool background = _background;
    final Map<String, Object> taskConfiguration = <String, Object>{
      'instances': instances.map((Instance i) => i.toJson()).toList(),
      'headers': headers,
    };
    final bool enabled = instances.isNotEmpty && (background || _visible);
    final String configuration = jsonEncode(<String, Object>{
      ...taskConfiguration,
      'enabled': enabled,
      'background': background,
    });
    final bool serviceRunning =
        Platform.isAndroid && await FlutterForegroundTask.isRunningService;
    if (configuration == _configuration &&
        (!background || !enabled || serviceRunning)) {
      return;
    }
    await _foreground?.stop();
    _foreground = null;
    if (serviceRunning) {
      await _sendToTask('stop', reply: 'stopped');
      _checkResult(await FlutterForegroundTask.stopService());
    }
    // Close stale configurations even when not visible, but start a new
    // Android foreground service only while the user is in the app.
    if (background && enabled && !_visible) {
      _configuration = null;
      return;
    }
    if (!enabled) {
      _configuration = configuration;
      onStatus(instances.isEmpty ? 'No Gotify servers configured' : 'Paused');
      return;
    }
    if (_visible) {
      if (!await requestGotifyNotificationPermission()) {
        onStatus('Notifications are disabled. Allow them in system settings.');
        return;
      }
    }
    if (_disposed || !_visible) {
      _configuration = null;
      return;
    }
    if (background) {
      // The service receives credentials through an in-memory port, never
      // through the plugin's unencrypted shared-preference storage.
      _checkResult(await FlutterForegroundTask.startService(
        serviceId: 701001,
        serviceTypes: <ForegroundServiceTypes>[
          ForegroundServiceTypes.specialUse
        ],
        notificationTitle: 'Atrium - Gotify',
        notificationText: 'Connecting to your Gotify servers',
        notificationIcon: const NotificationIcon(
          metaDataName: 'app.atrium.gotify_notification_icon',
        ),
        callback: gotifyBackgroundEntryPoint,
      ));
      _activeTaskConfiguration = taskConfiguration;
      await _sendToTask(taskConfiguration, reply: 'configured');
    } else {
      _foreground = GotifyAlertSession(
        resolver: resolver,
        headers: headers,
        onStatus: onStatus,
      )..start(instances);
    }
    _configuration = configuration;
  }

  void _onTaskData(Object data) {
    if (data == 'ready' && _expectedReply == 'configured') {
      FlutterForegroundTask.sendDataToTask(_activeTaskConfiguration!);
    } else if (data == _expectedReply && _taskReply?.isCompleted == false) {
      _taskReply!.complete();
    } else if (data == 'configuration-error') {
      if (_taskReply?.isCompleted == false) {
        _taskReply!.completeError(StateError('Gotify service setup failed'));
      } else {
        onStatus('Gotify background delivery failed. Reopen Atrium to retry.');
      }
    } else if (data is Map && data['status'] is String) {
      onStatus(data['status'] as String);
    }
  }

  Future<void> _sendToTask(Object data, {required String reply}) async {
    final Completer<void> completer = Completer<void>();
    _taskReply = completer;
    _expectedReply = reply;
    try {
      FlutterForegroundTask.sendDataToTask(data);
      await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      _taskReply = null;
      _expectedReply = null;
    }
  }

  void _checkResult(ServiceRequestResult result) {
    if (result is ServiceRequestFailure) {
      throw StateError('Gotify foreground service request failed');
    }
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    }
    unawaited(_pending.then((_) => _foreground?.stop()));
    // A configured foreground service intentionally outlives the app UI.
  }
}
