import 'package:core_models/core_models.dart';
import 'package:core_storage/core_storage.dart';

/// SSH login details for one Unraid server.
///
/// Everything here is a secret or tied to one server's identity, so it lives in
/// secure storage next to the API key rather than in the profile JSON that gets
/// exported.
class UnraidSshConfig {
  const UnraidSshConfig({
    required this.user,
    required this.port,
    required this.privateKey,
    this.passphrase,
    this.hostKeyFingerprint,
  });

  final String user;
  final int port;

  /// PEM text of the private key, as pasted or imported.
  final String privateKey;

  final String? passphrase;

  /// Base64 SHA-256 of the server's host key, pinned on first connect. A later
  /// mismatch means the key changed, which is either a reinstalled server or an
  /// interception, so the connection is refused until the user resets it.
  final String? hostKeyFingerprint;
}

/// Reads and writes [UnraidSshConfig] for an instance.
class UnraidSshStore {
  UnraidSshStore(this._secrets);

  final AtriumSecureStorage _secrets;

  static const String _user = 'ssh.user';
  static const String _port = 'ssh.port';
  static const String _key = 'ssh.privateKey';
  static const String _passphrase = 'ssh.passphrase';
  static const String _hostKey = 'ssh.hostKeyFingerprint';

  // Same `instance:<id>:<field>` convention as the rest of the app's secrets.
  String _k(Instance instance, String field) =>
      'instance:${instance.id}:$field';

  /// Null until a private key has been saved.
  Future<UnraidSshConfig?> read(Instance instance) async {
    final String? key = await _secrets.read(_k(instance, _key));
    if (key == null || key.isEmpty) return null;
    return UnraidSshConfig(
      user: await _secrets.read(_k(instance, _user)) ?? 'root',
      port: int.tryParse(await _secrets.read(_k(instance, _port)) ?? '') ?? 22,
      privateKey: key,
      passphrase: await _secrets.read(_k(instance, _passphrase)),
      hostKeyFingerprint: await _secrets.read(_k(instance, _hostKey)),
    );
  }

  Future<void> save(Instance instance, UnraidSshConfig config) async {
    await _secrets.write(_k(instance, _user), config.user);
    await _secrets.write(_k(instance, _port), config.port.toString());
    await _secrets.write(_k(instance, _key), config.privateKey);
    await _secrets.write(_k(instance, _passphrase), config.passphrase);
  }

  Future<void> saveHostKey(Instance instance, String fingerprint) =>
      _secrets.write(_k(instance, _hostKey), fingerprint);

  Future<void> forgetHostKey(Instance instance) =>
      _secrets.write(_k(instance, _hostKey), null);
}

/// What to do with a host key the server presented.
enum HostKeyDecision { pinNew, matches, mismatch }

/// Trust on first use: the first key seen is pinned, and any later change is
/// refused rather than silently accepted.
HostKeyDecision decideHostKey(String? pinned, String presented) {
  if (pinned == null || pinned.isEmpty) return HostKeyDecision.pinNew;
  return pinned == presented
      ? HostKeyDecision.matches
      : HostKeyDecision.mismatch;
}
