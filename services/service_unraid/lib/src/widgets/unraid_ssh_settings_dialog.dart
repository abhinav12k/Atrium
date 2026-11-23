import 'package:core_models/core_models.dart';
import 'package:core_ui/core_ui.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/unraid_ssh_config.dart';
import '../unraid_providers.dart';

/// Login details for the server's SSH, shown from the container sheet.
///
/// Returns true when something was saved. A stored key is never shown back;
/// leaving the key field empty keeps the one already saved.
Future<bool?> showUnraidSshSettings(
  BuildContext context, {
  required Instance instance,
}) {
  return showDialog<bool>(
    context: context,
    builder: (BuildContext context) => _SshSettingsDialog(instance: instance),
  );
}

class _SshSettingsDialog extends ConsumerStatefulWidget {
  const _SshSettingsDialog({required this.instance});

  final Instance instance;

  @override
  ConsumerState<_SshSettingsDialog> createState() => _SshSettingsDialogState();
}

class _SshSettingsDialogState extends ConsumerState<_SshSettingsDialog> {
  final TextEditingController _user = TextEditingController(text: 'root');
  final TextEditingController _port = TextEditingController(text: '22');
  final TextEditingController _key = TextEditingController();
  final TextEditingController _passphrase = TextEditingController();

  UnraidSshConfig? _existing;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final UnraidSshConfig? existing =
        await ref.read(unraidSshStoreProvider).read(widget.instance);
    if (!mounted) return;
    setState(() {
      _existing = existing;
      if (existing != null) {
        _user.text = existing.user;
        _port.text = existing.port.toString();
      }
      _loading = false;
    });
  }

  @override
  void dispose() {
    _user.dispose();
    _port.dispose();
    _key.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final UnraidSshStore store = ref.read(unraidSshStoreProvider);
    final String user = _user.text.trim();
    final int? port = int.tryParse(_port.text.trim());
    final String pastedKey = _key.text.trim();
    final String? passphrase =
        _passphrase.text.isEmpty ? null : _passphrase.text;
    final String? privateKey =
        pastedKey.isNotEmpty ? pastedKey : _existing?.privateKey;

    if (user.isEmpty) {
      setState(() => _error = 'Enter the user name to log in as.');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'The port must be between 1 and 65535.');
      return;
    }
    if (privateKey == null) {
      setState(() => _error = 'Paste the private key to connect.');
      return;
    }
    try {
      SSHKeyPair.fromPem(privateKey, passphrase);
    } on Object {
      setState(
        () => _error =
            'That does not read as a private key. Encrypted keys need their '
                'passphrase filled in.',
      );
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    // The pinned host key identifies the server, not the login key, so it
    // survives a key change and is only reset from its own button.
    await store.save(
      widget.instance,
      UnraidSshConfig(
        user: user,
        port: port,
        privateKey: privateKey,
        passphrase: passphrase,
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _forgetHostKey() async {
    await ref.read(unraidSshStoreProvider).forgetHostKey(widget.instance);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('The next connection will trust the server\'s key.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    return AlertDialog(
      title: const Text('SSH settings'),
      scrollable: true,
      content: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Connects to the same host as this Unraid instance, on the '
                  'port below.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: Insets.md),
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(labelText: 'User'),
                  autocorrect: false,
                ),
                const SizedBox(height: Insets.sm),
                TextField(
                  controller: _port,
                  decoration: const InputDecoration(labelText: 'Port'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: Insets.sm),
                TextField(
                  controller: _key,
                  minLines: 3,
                  maxLines: 8,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Private key',
                    hintText: _existing != null
                        ? 'A key is saved. Paste one to replace it.'
                        : '-----BEGIN OPENSSH PRIVATE KEY-----',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: Insets.sm),
                TextField(
                  controller: _passphrase,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Key passphrase (if encrypted)',
                  ),
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: Insets.sm),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                  ),
                ],
                if (_existing?.hostKeyFingerprint != null) ...<Widget>[
                  const SizedBox(height: Insets.sm),
                  TextButton(
                    onPressed: _forgetHostKey,
                    child: const Text('Reset trusted host key'),
                  ),
                ],
              ],
            ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _loading || _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
