import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:core_models/core_models.dart';
import 'package:core_networking/core_networking.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:service_gotify/service_gotify.dart';

import 'gotify_alert_session.dart';

@pragma('vm:entry-point')
void gotifyBackgroundEntryPoint() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_GotifyTaskHandler());
}

class _GotifyTaskHandler extends TaskHandler {
  ConnectionResolver? _resolver;
  GotifyAlertSession? _session;
  Timer? _configurationTimeout;
  Future<void> _pending = Future<void>.value();
  String? _configuration;
  bool _closing = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    FlutterForegroundTask.sendDataToMain('ready');
    // Credentials travel only through the isolate port. A fresh task without
    // a UI to configure it must not keep an empty foreground service alive.
    _configurationTimeout = Timer(const Duration(seconds: 30), () {
      debugPrint('Gotify service stopped: no configuration received.');
      unawaited(_stopService());
    });
  }

  @override
  void onReceiveData(Object data) {
    _pending = _pending.then((_) => _handle(data)).catchError(
      (Object error, StackTrace stack) {
        debugPrint('Gotify background setup failed (${error.runtimeType}).');
        FlutterForegroundTask.sendDataToMain('configuration-error');
        unawaited(_stopService());
      },
    );
  }

  Future<void> _handle(Object data) async {
    if (data == 'stop') {
      await _closeSession();
      _configuration = null;
      FlutterForegroundTask.sendDataToMain('stopped');
      return;
    }
    if (data is! Map) {
      throw const FormatException('Invalid Gotify configuration');
    }
    final String configuration = jsonEncode(data);
    if (_configuration == configuration) {
      FlutterForegroundTask.sendDataToMain('configured');
      return;
    }
    final Object? rawInstances = data['instances'];
    final Object? rawHeaders = data['headers'];
    if (rawInstances is! List || rawHeaders is! Map) {
      throw const FormatException('Invalid Gotify configuration');
    }
    final List<Instance> instances = <Instance>[
      for (final Object? raw in rawInstances)
        if (raw is Map) Instance.fromJson(Map<String, dynamic>.from(raw)),
    ];
    if (instances.isEmpty || instances.length != rawInstances.length) {
      throw const FormatException('Invalid Gotify instances');
    }
    _configurationTimeout?.cancel();
    await _closeSession();
    await ensureGotifyNotificationsReady();
    final ConnectionResolver resolver =
        ConnectionResolver(connectivity: Connectivity());
    _resolver = resolver;
    await resolver.start();
    _closing = false;
    _session = GotifyAlertSession(
      resolver: resolver,
      headers: Map<String, String>.from(rawHeaders),
      onStatus: (String status) {
        if (_closing) return;
        FlutterForegroundTask.sendDataToMain(
            <String, String>{'status': status});
        unawaited(_updateStatus(status));
      },
    )..start(instances);
    _configuration = configuration;
    FlutterForegroundTask.sendDataToMain('configured');
  }

  Future<void> _updateStatus(String status) async {
    final ServiceRequestResult result =
        await FlutterForegroundTask.updateService(
      notificationText: status,
    );
    if (result is ServiceRequestFailure && !_closing) {
      debugPrint('Gotify service notification update failed.');
      FlutterForegroundTask.sendDataToMain('configuration-error');
    }
  }

  Future<void> _closeSession() async {
    _closing = true;
    await _session?.stop();
    _session = null;
    await _resolver?.dispose();
    _resolver = null;
  }

  Future<void> _stopService() async {
    final ServiceRequestResult result =
        await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      debugPrint('Unable to stop Gotify foreground service.');
      FlutterForegroundTask.sendDataToMain('configuration-error');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _configurationTimeout?.cancel();
    await _pending;
    await _closeSession();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}
