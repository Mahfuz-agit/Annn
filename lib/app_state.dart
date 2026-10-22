import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'sources.dart';

class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  static const String defaultFolder = '/storage/emulated/0/Movies/Reels';

  late SharedPreferences _p;

  // Settings
  bool folderEnabled = true;
  String folderPath = defaultFolder;
  List<String> manifests = <String>[];
  String order = 'newest';
  bool favoritesOnly = false;
  bool autoNext = false;
  bool haptics = true;
  bool cacheOffline = true;
  Set<String> favorites = <String>{};
  Set<String> knownIds = <String>{};

  // Feed
  List<VideoItem> items = <VideoItem>[];
  int feedVersion = 0;
  int localCount = 0;
  int remoteCount = 0;
  bool loading = true;
  bool refreshing = false;
  String? toast;

  List<VideoItem> _remote = <VideoItem>[];
  Set<String> _allIds = <String>{};
  int _seed = DateTime.now().millisecondsSinceEpoch;
  int _sig = 0;
  bool _dirty = false;
  bool _remoteDirty = false;
  Timer? _toastTimer;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    folderEnabled = _p.getBool('folderEnabled') ?? true;
    folderPath = _p.getString('folderPath') ?? defaultFolder;
    manifests = _p.getStringList('manifests') ?? <String>[];
    order = _p.getString('order') ?? 'newest';
    favoritesOnly = _p.getBool('favoritesOnly') ?? false;
    autoNext = _p.getBool('autoNext') ?? false;
    haptics = _p.getBool('haptics') ?? true;
    cacheOffline = _p.getBool('cacheOffline') ?? true;
    favorites = (_p.getStringList('favorites') ?? <String>[]).toSet();
    knownIds = (_p.getStringList('knownIds') ?? <String>[]).toSet();
    final raw = _p.getString('remote_items');
    if (raw != null) {
      try {
        _remote = (jsonDecode(raw) as List<dynamic>)
            .map((e) => VideoItem.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
  }

  /// Called once after the first frame.
  Future<void> start() async {
    await rebuild();
    await refreshRemote();
  }

  // ---- Feed building ----

  Future<void> rebuild() async {
    final local = (folderEnabled && folderPath.trim().isNotEmpty)
        ? await Sources.scanLocal(folderPath.trim())
        : <VideoItem>[];
    localCount = local.length;
    remoteCount = _remote.length;

    final seen = <String>{};
    final all = <VideoItem>[];
    for (final v in <VideoItem>[...local, ..._remote]) {
      if (seen.add(v.id)) all.add(v);
    }
    _allIds = seen;

    var list = _order(all);
    if (favoritesOnly) {
      list = list.where((v) => favorites.contains(v.id)).toList();
    }

    final sig = Object.hashAll(list.map((v) => v.id));
    final changed = sig != _sig;
    _sig = sig;
    items = list;
    loading = false;
    if (changed) feedVersion++;
    notifyListeners();
  }

  List<VideoItem> _order(List<VideoItem> all) {
    final sorted = <VideoItem>[...all];
    if (order == 'shuffle') {
      sorted.shuffle(Random(_seed));
    } else {
      final idx = <String, int>{};
      for (var i = 0; i < all.length; i++) {
        idx[all[i].id] = i;
      }
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      sorted.sort((a, b) {
        final c = (b.date ?? epoch).compareTo(a.date ?? epoch);
        return c != 0 ? c : idx[a.id]!.compareTo(idx[b.id]!);
      });
    }
    // Resurface one memory near the top.
    if (sorted.length > 3) {
      final i = sorted.indexWhere((v) => v.memoryLabel != null);
      if (i > 2) {
        final m = sorted.removeAt(i);
        sorted.insert(2, m);
      }
    }
    return sorted;
  }

  Future<void> refreshRemote({bool announce = true}) async {
    refreshing = true;
    notifyListeners();
    if (manifests.isEmpty) {
      _remote = <VideoItem>[];
      await _saveRemote();
    } else {
      final fetched = <VideoItem>[];
      var ok = false;
      for (final u in manifests) {
        try {
          fetched.addAll(await Sources.fetchManifest(u));
          ok = true;
        } catch (_) {}
      }
      if (ok) {
        _remote = fetched;
        await _saveRemote();
      }
    }
    refreshing = false;
    await rebuild();
    if (announce) _announceNew();
    knownIds = <String>{..._allIds};
    await _p.setStringList('knownIds', knownIds.toList());
  }

  Future<void> _saveRemote() async {
    await _p.setString(
      'remote_items',
      jsonEncode(_remote.map((v) => v.toJson()).toList()),
    );
  }

  void _announceNew() {
    if (knownIds.isEmpty) return;
    final n = _allIds.difference(knownIds).length;
    if (n > 0) _showToast(n == 1 ? '1 new video' : '$n new videos');
  }

  void _showToast(String text) {
    toast = text;
    notifyListeners();
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      toast = null;
      notifyListeners();
    });
  }

  /// Applies pending settings changes once, when the user leaves Settings.
  Future<void> applyChanges() async {
    if (_remoteDirty) {
      _remoteDirty = false;
      _dirty = false;
      await refreshRemote(announce: false);
    } else if (_dirty) {
      _dirty = false;
      await rebuild();
    }
  }

  void markDirty() => _dirty = true;

  // ---- Favorites ----

  bool isFav(String id) => favorites.contains(id);

  Future<void> setFav(String id, bool value) async {
    if (value) {
      favorites.add(id);
    } else {
      favorites.remove(id);
    }
    notifyListeners();
    await _p.setStringList('favorites', favorites.toList());
  }

  // ---- Settings setters ----

  Future<void> setFolderEnabled(bool v) async {
    folderEnabled = v;
    _dirty = true;
    notifyListeners();
    await _p.setBool('folderEnabled', v);
  }

  void setFolderPath(String v) {
    folderPath = v.trim();
    _dirty = true;
    _p.setString('folderPath', folderPath);
  }

  Future<void> addManifest(String url) async {
    final u = url.trim();
    if (u.isEmpty || manifests.contains(u)) return;
    manifests = <String>[...manifests, u];
    _remoteDirty = true;
    notifyListeners();
    await _p.setStringList('manifests', manifests);
  }

  Future<void> removeManifest(String url) async {
    manifests = manifests.where((m) => m != url).toList();
    _remoteDirty = true;
    notifyListeners();
    await _p.setStringList('manifests', manifests);
  }

  Future<void> setOrder(String v) async {
    order = v;
    _seed = DateTime.now().millisecondsSinceEpoch;
    _dirty = true;
    notifyListeners();
    await _p.setString('order', v);
  }

  Future<void> setFavoritesOnly(bool v) async {
    favoritesOnly = v;
    _dirty = true;
    notifyListeners();
    await _p.setBool('favoritesOnly', v);
  }

  Future<void> setAutoNext(bool v) async {
    autoNext = v;
    notifyListeners();
    await _p.setBool('autoNext', v);
  }

  Future<void> setHaptics(bool v) async {
    haptics = v;
    notifyListeners();
    await _p.setBool('haptics', v);
  }

  Future<void> setCacheOffline(bool v) async {
    cacheOffline = v;
    notifyListeners();
    await _p.setBool('cacheOffline', v);
  }
}
