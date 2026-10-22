import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'models.dart';

/// Finds videos: from a phone folder and from manifest links.
class Sources {
  static const List<String> _ext = ['.mp4', '.mov', '.m4v', '.mkv', '.webm', '.3gp'];

  static bool _isVideo(String s) {
    final l = s.toLowerCase().split('?').first;
    return _ext.any((e) => l.endsWith(e));
  }

  static String titleFromPath(String p) {
    var name = p.split('?').first.split('/').last;
    try {
      name = Uri.decodeComponent(name);
    } catch (_) {}
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    name = name.replaceAll(RegExp(r'[_\-.]+'), ' ').trim();
    return name.isEmpty ? 'Untitled' : name;
  }

  // ---- Permission ----

  static Future<bool> hasAccess() async {
    if (!Platform.isAndroid) return true;
    return (await Permission.videos.status).isGranted ||
        (await Permission.storage.status).isGranted;
  }

  static Future<bool> requestAccess() async {
    if (!Platform.isAndroid) return true;
    if (await hasAccess()) return true;
    await Permission.videos.request();
    if (await hasAccess()) return true;
    await Permission.storage.request();
    return hasAccess();
  }

  // ---- Phone folder ----

  static Future<List<VideoItem>> scanLocal(String path) async {
    final out = <VideoItem>[];
    try {
      if (!await requestAccess()) return out;
      final dir = Directory(path);
      if (!await dir.exists()) return out;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (!_isVideo(e.path)) continue;
        DateTime? d;
        try {
          d = await e.lastModified();
        } catch (_) {}
        out.add(VideoItem(
          id: e.path,
          title: titleFromPath(e.path),
          uri: e.path,
          remote: false,
          date: d,
        ));
      }
    } catch (_) {}
    return out;
  }

  // ---- Manifest links ----

  static Future<List<VideoItem>> fetchManifest(String url) async {
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return parseManifest(utf8.decode(res.bodyBytes, allowMalformed: true), url);
  }

  static List<VideoItem> parseManifest(String text, String base) {
    final t = text.trim();
    final out = <VideoItem>[];
    final seen = <String>{};

    void add(String? raw, {String? title, DateTime? date}) {
      if (raw == null) return;
      var u = raw.trim().replaceAll('&amp;', '&');
      if (u.isEmpty) return;
      try {
        u = Uri.parse(base).resolve(u).toString();
      } catch (_) {
        return;
      }
      if (!seen.add(u)) return;
      var name = title?.trim() ?? '';
      if (name.isEmpty || _isVideo(name)) {
        name = titleFromPath(name.isEmpty ? u : name);
      }
      out.add(VideoItem(id: u, title: name, uri: u, remote: true, date: date));
    }

    // 1. JSON
    if (t.startsWith('{') || t.startsWith('[')) {
      final dynamic j = jsonDecode(t);
      List<dynamic> list = const <dynamic>[];
      if (j is List) {
        list = j;
      } else if (j is Map) {
        final v = j['videos'] ?? j['items'] ?? j['files'] ?? j['assets'];
        if (v is List) list = v;
      }
      for (final e in list) {
        if (e is String) {
          add(e);
        } else if (e is Map) {
          final u = e['url'] ??
              e['src'] ??
              e['link'] ??
              e['video'] ??
              e['browser_download_url'];
          final title = (e['title'] ?? e['name'])?.toString();
          final d = DateTime.tryParse(
              '${e['date'] ?? e['created_at'] ?? e['published_at'] ?? e['updated_at'] ?? ''}');
          add(u?.toString(), title: title, date: d);
        }
      }
      return out;
    }

    // 2. Sitemap XML
    if (t.contains('<loc>') || t.contains('content_loc')) {
      final blocks = RegExp(r'<url>(.*?)</url>', dotAll: true).allMatches(t).toList();
      final locRe = RegExp(r'<loc>\s*([^<]+?)\s*</loc>');
      final vidRe = RegExp(r'<video:content_loc>\s*([^<]+?)\s*</video:content_loc>');
      final titleRe = RegExp(r'<video:title>\s*(?:<!\[CDATA\[)?\s*([^<\]]+?)\s*(?:\]\]>)?\s*</video:title>');
      final modRe = RegExp(r'<lastmod>\s*([^<]+?)\s*</lastmod>');
      final parts = blocks.isEmpty ? <String>[t] : blocks.map((m) => m.group(1)!).toList();
      for (final b in parts) {
        final date = DateTime.tryParse(modRe.firstMatch(b)?.group(1) ?? '');
        final title = titleRe.firstMatch(b)?.group(1);
        final vids = vidRe.allMatches(b).map((m) => m.group(1)).toList();
        if (vids.isNotEmpty) {
          for (final v in vids) {
            add(v, title: title, date: date);
          }
        } else {
          for (final m in locRe.allMatches(b)) {
            final u = m.group(1);
            if (u != null && _isVideo(u)) add(u, title: title, date: date);
          }
        }
      }
      return out;
    }

    // 3. Plain text, one URL per line
    for (final line in const LineSplitter().convert(t)) {
      final l = line.trim();
      if (l.startsWith('http')) add(l);
    }
    return out;
  }
}
