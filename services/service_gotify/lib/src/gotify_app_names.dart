import 'package:dio/dio.dart';

import 'gotify_api.dart';

/// Maps application ids to names for notification titles. A successful lookup
/// is cached; a failed one is not, so the next notification retries it.
class GotifyAppNames {
  GotifyAppNames(this._createDio);

  final Future<Dio> Function() _createDio;
  Map<int, String>? _names;

  Future<Map<int, String>> load() async {
    final Map<int, String>? cached = _names;
    if (cached != null) return cached;
    try {
      final Dio dio = await _createDio();
      try {
        final Map<int, String> names = <int, String>{
          for (final app in await GotifyApi(dio).getApplications())
            app.id: app.name,
        };
        _names = names;
        return names;
      } finally {
        dio.close(force: true);
      }
    } on Exception {
      return const <int, String>{};
    }
  }
}
