import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Offline-first cache for remote videos.
class CacheService {
  static final Set<String> _inflight = <String>{};

  static Future<Directory> dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/videos');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _name(String url) {
    var h = 0x811c9dc5;
    for (final u in url.codeUnits) {
      h ^= u;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return '${h.toRadixString(16).padLeft(8, '0')}_${url.length}';
  }

  static Future<File> _file(String url) async {
    final d = await dir();
    return File('${d.path}/${_name(url)}.mp4');
  }

  static Future<File?> cached(String url) async {
    final f = await _file(url);
    return await f.exists() ? f : null;
  }

  /// Downloads in the background. Safe to call many times.
  static Future<void> download(String url) async {
    if (_inflight.contains(url)) return;
    _inflight.add(url);
    final client = http.Client();
    try {
      final target = await _file(url);
      if (await target.exists()) return;
      final tmp = File('${target.path}.part');
      final res = await client.send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode != 200) return;
      final sink = tmp.openWrite();
      await res.stream.pipe(sink);
      await tmp.rename(target.path);
    } catch (_) {
      // Ignore. The video keeps streaming and the next play retries.
    } finally {
      client.close();
      _inflight.remove(url);
    }
  }

  static Future<int> sizeBytes() async {
    var total = 0;
    try {
      final d = await dir();
      await for (final e in d.list()) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  static Future<void> clear() async {
    try {
      final d = await dir();
      if (await d.exists()) await d.delete(recursive: true);
      await d.create(recursive: true);
    } catch (_) {}
  }
}
