import 'package:flutter_test/flutter_test.dart';
import 'package:service_unraid/service_unraid.dart';
import 'package:service_unraid/src/ssh/unraid_ssh_config.dart';
import 'package:service_unraid/src/ssh/unraid_ssh_shell.dart';

void main() {
  group('dockerIdOf', () {
    test('takes the part after the server prefix', () {
      const UnraidContainer c = UnraidContainer(
        id: 'srv:abc123',
        names: <String>['/sonarr'],
        state: 'RUNNING',
        status: 'Up',
      );
      expect(dockerIdOf(c), 'abc123');
    });

    test('refuses ids that could smuggle shell syntax', () {
      const UnraidContainer c = UnraidContainer(
        id: 'srv:abc;rm -rf /',
        names: <String>['/x'],
        state: 'RUNNING',
        status: 'Up',
      );
      expect(dockerIdOf(c), isNull);
    });
  });

  test('containerShellCommand prefers bash and falls back to sh', () {
    expect(
      containerShellCommand('abc123'),
      "docker exec -it abc123 sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'",
    );
  });

  group('decideHostKey', () {
    test('pins the first key seen', () {
      expect(decideHostKey(null, 'fp'), HostKeyDecision.pinNew);
      expect(decideHostKey('', 'fp'), HostKeyDecision.pinNew);
    });

    test('accepts the pinned key and rejects a changed one', () {
      expect(decideHostKey('fp', 'fp'), HostKeyDecision.matches);
      expect(decideHostKey('fp', 'other'), HostKeyDecision.mismatch);
    });
  });
}
