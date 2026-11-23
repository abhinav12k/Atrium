import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';

import '../models/unraid_models.dart';
import 'unraid_ssh_config.dart';

/// A failure worth showing as it is: a refused login, a changed host key, an
/// unreachable port.
class UnraidSshException implements Exception {
  const UnraidSshException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The bare Docker id behind Unraid's compound `server:container` id.
///
/// Only hex-and-name characters are accepted, since the id is placed into a
/// remote command line. Anything else is refused rather than escaped.
String? dockerIdOf(UnraidContainer container) {
  final String id = container.id.split(':').last;
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(id) ? id : null;
}

/// Opens a shell inside the container, using bash when the image has it.
String containerShellCommand(String dockerId) =>
    'docker exec -it $dockerId sh -c '
    "'command -v bash >/dev/null 2>&1 && exec bash || exec sh'";

/// Connects and authenticates to [host] with the saved key.
///
/// On first connect the host key is pinned through [onPinHostKey]. A later
/// mismatch fails here, before anything is sent to the server.
Future<SSHClient> connectUnraidSsh({
  required String host,
  required UnraidSshConfig config,
  required Future<void> Function(String fingerprint) onPinHostKey,
}) async {
  final List<SSHKeyPair> identities;
  try {
    identities = SSHKeyPair.fromPem(config.privateKey, config.passphrase);
  } on Object {
    throw const UnraidSshException(
      'Could not read that private key. Encrypted keys need their passphrase.',
    );
  }

  final SSHSocket socket;
  try {
    socket = await SSHSocket.connect(
      host,
      config.port,
      timeout: const Duration(seconds: 10),
    );
  } on Object {
    throw UnraidSshException(
      'Could not reach SSH at $host:${config.port}. Check the port is open '
      'on the server.',
    );
  }

  final SSHClient client = SSHClient(
    socket,
    username: config.user,
    identities: identities,
    onVerifyHostKey: (String type, Uint8List fingerprint) async {
      final String presented = base64.encode(fingerprint);
      switch (decideHostKey(config.hostKeyFingerprint, presented)) {
        case HostKeyDecision.pinNew:
          await onPinHostKey(presented);
          return true;
        case HostKeyDecision.matches:
          return true;
        case HostKeyDecision.mismatch:
          return false;
      }
    },
  );

  try {
    await client.authenticated;
    return client;
  } on SSHHostkeyError {
    await client.close();
    throw const UnraidSshException(
      'The server presented a different host key than the one trusted before. '
      'If the server was reinstalled, reset the trusted host key under SSH '
      'settings.',
    );
  } on SSHAuthError {
    await client.close();
    throw const UnraidSshException(
      'Login was refused. Check the user name and that the matching public key '
      'is in the server\'s authorized keys.',
    );
  } on Object {
    await client.close();
    throw const UnraidSshException('The SSH connection ended during login.');
  }
}

/// Connects an SSH session to an xterm [Terminal].
///
/// Remote output is decoded as UTF-8 across chunk boundaries and written to
/// the terminal. Keystrokes and resizes are sent back to the remote pty. The
/// streams end when the session closes, so nothing needs cancelling.
void attachSshSession(Terminal terminal, SSHSession session) {
  Stream<String> decode(Stream<Uint8List> bytes) => bytes
      .cast<List<int>>()
      .transform<String>(const Utf8Decoder(allowMalformed: true));

  decode(session.stdout).listen(terminal.write);
  decode(session.stderr).listen(terminal.write);
  terminal.onOutput = (String data) {
    session.stdin.add(Uint8List.fromList(utf8.encode(data)));
  };
  terminal.onResize = (int width, int height, int pixelWidth, int pixelHeight) {
    session.resizeTerminal(width, height, pixelWidth, pixelHeight);
  };
}
