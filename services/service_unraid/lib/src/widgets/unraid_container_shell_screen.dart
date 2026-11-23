import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_models/core_models.dart';
import 'package:core_networking/core_networking.dart';
import 'package:core_ui/core_ui.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../models/unraid_models.dart';
import '../ssh/unraid_ssh_config.dart';
import '../ssh/unraid_ssh_shell.dart';
import '../unraid_providers.dart';
import 'unraid_ssh_settings_dialog.dart';

/// An interactive shell inside one container, over SSH to the Unraid host.
Future<void> openUnraidContainerShell(
  BuildContext context, {
  required Instance instance,
  required UnraidContainer container,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => UnraidContainerShellScreen(
        instance: instance,
        container: container,
      ),
    ),
  );
}

enum _Phase { connecting, needsSetup, connected, ended, failed }

class UnraidContainerShellScreen extends ConsumerStatefulWidget {
  const UnraidContainerShellScreen({
    super.key,
    required this.instance,
    required this.container,
  });

  final Instance instance;
  final UnraidContainer container;

  @override
  ConsumerState<UnraidContainerShellScreen> createState() =>
      _UnraidContainerShellScreenState();
}

class _UnraidContainerShellScreenState
    extends ConsumerState<UnraidContainerShellScreen> {
  _Phase _phase = _Phase.connecting;
  String? _message;
  SSHClient? _client;
  SSHSession? _session;
  Terminal? _terminal;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _session?.close();
    unawaited(_client?.close());
    super.dispose();
  }

  void _disconnect() {
    _session?.close();
    unawaited(_client?.close());
    _session = null;
    _client = null;
  }

  Future<void> _connect() async {
    _disconnect();
    setState(() {
      _phase = _Phase.connecting;
      _message = null;
      _terminal = null;
    });

    final String? dockerId = dockerIdOf(widget.container);
    if (!widget.container.isRunning) {
      return _fail('Start the container before opening a shell in it.');
    }
    if (dockerId == null) {
      return _fail('This container\'s id cannot be used for a shell.');
    }

    final UnraidSshStore store = ref.read(unraidSshStoreProvider);
    final UnraidSshConfig? config = await store.read(widget.instance);
    if (!mounted) return;
    if (config == null) {
      setState(() => _phase = _Phase.needsSetup);
      return;
    }

    try {
      final Uri base =
          await ref.read(connectionResolverProvider).resolve(widget.instance);
      if (!mounted) return;

      final SSHClient client = await connectUnraidSsh(
        host: base.host,
        config: config,
        onPinHostKey: (String fp) => store.saveHostKey(widget.instance, fp),
      );
      if (!mounted) {
        await client.close();
        return;
      }
      _client = client;

      final SSHSession session = await client.execute(
        containerShellCommand(dockerId),
        pty: const SSHPtyConfig(),
      );
      if (!mounted) {
        session.close();
        return;
      }
      _session = session;

      final Terminal terminal = Terminal(maxLines: 5000);
      attachSshSession(terminal, session);
      setState(() {
        _terminal = terminal;
        _phase = _Phase.connected;
      });

      unawaited(
        session.done.then((_) {
          if (!mounted || _session != session) return;
          setState(() => _phase = _Phase.ended);
        }),
      );
    } on UnraidSshException catch (e) {
      _fail(e.message);
    } on Object {
      _fail('Could not open a shell in this container.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _message = message;
    });
  }

  Future<void> _openSettings() async {
    final bool? saved = await showUnraidSshSettings(
      context,
      instance: widget.instance,
    );
    if (saved == true) await _connect();
  }

  /// Sends a key the phone keyboard lacks. Escape sequences are the ones a
  /// terminal expects for the arrow keys.
  void _sendKey(String sequence) {
    _session?.stdin.add(Uint8List.fromList(utf8.encode(sequence)));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool canType = _phase == _Phase.connected && _terminal != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.container.displayName,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          if (_phase == _Phase.ended || _phase == _Phase.failed)
            IconButton(
              tooltip: 'Reconnect',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _connect,
            ),
          IconButton(
            tooltip: 'SSH settings',
            icon: const Icon(Icons.key_rounded),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(child: _body(theme, cs)),
          if (canType)
            SafeArea(
              top: false,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.sm,
                  vertical: Insets.xs,
                ),
                child: Row(
                  children: <Widget>[
                    for (final (String label, String seq) in _keys)
                      Padding(
                        padding: const EdgeInsets.only(right: Insets.xs),
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 36),
                            padding: const EdgeInsets.symmetric(
                              horizontal: Insets.sm,
                            ),
                          ),
                          onPressed: () => _sendKey(seq),
                          child: Text(label),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static const List<(String, String)> _keys = <(String, String)>[
    ('Esc', '\x1b'),
    ('Tab', '\t'),
    ('Ctrl+C', '\x03'),
    ('Ctrl+D', '\x04'),
    ('←', '\x1b[D'),
    ('↓', '\x1b[B'),
    ('↑', '\x1b[A'),
    ('→', '\x1b[C'),
  ];

  Widget _body(ThemeData theme, ColorScheme cs) {
    switch (_phase) {
      case _Phase.connecting:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CircularProgressIndicator(strokeWidth: 2),
              SizedBox(height: Insets.md),
              Text('Connecting…'),
            ],
          ),
        );
      case _Phase.needsSetup:
        return _Message(
          text: 'Add the SSH login for this server to open a shell here.',
          actionLabel: 'SSH settings',
          onAction: _openSettings,
        );
      case _Phase.failed:
        return _Message(
          text: _message ?? 'Could not open a shell.',
          actionLabel: 'Try again',
          onAction: _connect,
          secondaryLabel: 'SSH settings',
          onSecondary: _openSettings,
        );
      case _Phase.ended:
      case _Phase.connected:
        final Terminal? terminal = _terminal;
        if (terminal == null) return const SizedBox.shrink();
        return Column(
          children: <Widget>[
            if (_phase == _Phase.ended)
              Container(
                width: double.infinity,
                color: cs.errorContainer,
                padding: const EdgeInsets.all(Insets.sm),
                child: Text(
                  'Session ended. Use reconnect to open a new shell.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onErrorContainer,
                  ),
                ),
              ),
            Expanded(
              child: TerminalView(terminal, autofocus: true),
            ),
          ],
        );
    }
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    required this.actionLabel,
    required this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String text;
  final String actionLabel;
  final VoidCallback onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: Insets.md),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
            if (secondaryLabel != null && onSecondary != null)
              TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
          ],
        ),
      ),
    );
  }
}
