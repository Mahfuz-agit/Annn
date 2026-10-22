import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_state.dart';
import 'cache.dart';
import 'sources.dart';

const Color _ink = Color(0xFF2C2C2A);
const Color _muted = Color(0xFF5F5E5A);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AppState app = AppState.instance;
  late final TextEditingController _folder =
      TextEditingController(text: app.folderPath);
  final TextEditingController _url = TextEditingController();
  int? _cacheBytes;
  bool _access = true;

  @override
  void initState() {
    super.initState();
    app.addListener(_refresh);
    _loadCache();
    _loadAccess();
  }

  @override
  void dispose() {
    app.removeListener(_refresh);
    _folder.dispose();
    _url.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadCache() async {
    final b = await CacheService.sizeBytes();
    if (mounted) setState(() => _cacheBytes = b);
  }

  Future<void> _loadAccess() async {
    final ok = await Sources.hasAccess();
    if (mounted) setState(() => _access = ok);
  }

  String _size(int b) {
    if (b < 1024 * 1024) return '${(b / 1024).round()} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Future<void> _askAccess() async {
    final ok = await Sources.requestAccess();
    if (!ok) await openAppSettings();
    app.markDirty();
    await _loadAccess();
  }

  void _addUrl() {
    final u = _url.text.trim();
    if (!u.startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a full link that starts with https')),
      );
      return;
    }
    app.addManifest(u);
    _url.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Sources'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const _Header('Phone folder'),
          SwitchListTile(
            title: const Text('Use phone folder'),
            subtitle: Text('${app.localCount} videos'),
            value: app.folderEnabled,
            onChanged: app.setFolderEnabled,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _folder,
              onChanged: app.setFolderPath,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Folder path',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (!_access)
            ListTile(
              leading: const Icon(Icons.lock_open_rounded),
              title: const Text('Allow video access'),
              subtitle: const Text('Needed to read your phone folder'),
              onTap: _askAccess,
            ),

          const _Header('Manifest links'),
          for (final u in app.manifests)
            ListTile(
              dense: true,
              title: Text(u, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.close_rounded),
                onPressed: () => app.removeManifest(u),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onSubmitted: (_) => _addUrl(),
                    decoration: const InputDecoration(
                      hintText: 'https://raw.githubusercontent.com/you/repo/main/videos.json',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _addUrl,
                ),
              ],
            ),
          ),
          ListTile(
            title: const Text('Refresh now'),
            subtitle: Text('${app.remoteCount} videos from links'),
            trailing: app.refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _ink),
                  )
                : const Icon(Icons.refresh_rounded),
            onTap: app.refreshing ? null : () => app.refreshRemote(),
          ),

          const _Header('Feed'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment<String>(value: 'newest', label: Text('Newest')),
                ButtonSegment<String>(value: 'shuffle', label: Text('Shuffle')),
              ],
              selected: <String>{app.order},
              onSelectionChanged: (s) => app.setOrder(s.first),
            ),
          ),
          SwitchListTile(
            title: const Text('Favorites only'),
            value: app.favoritesOnly,
            onChanged: app.setFavoritesOnly,
          ),
          SwitchListTile(
            title: const Text('Play next automatically'),
            subtitle: const Text('Off means each video loops'),
            value: app.autoNext,
            onChanged: app.setAutoNext,
          ),
          SwitchListTile(
            title: const Text('Haptics'),
            value: app.haptics,
            onChanged: app.setHaptics,
          ),

          const _Header('Offline'),
          SwitchListTile(
            title: const Text('Save videos for offline'),
            subtitle: const Text('Link videos are kept on this phone after the first play'),
            value: app.cacheOffline,
            onChanged: app.setCacheOffline,
          ),
          ListTile(
            title: const Text('Saved videos'),
            subtitle: Text(_cacheBytes == null ? '...' : _size(_cacheBytes!)),
            trailing: TextButton(
              onPressed: () async {
                await CacheService.clear();
                await _loadCache();
              },
              child: const Text('Clear'),
            ),
          ),

          const Padding(
            padding: EdgeInsets.fromLTRB(16, 28, 16, 0),
            child: Text(
              'Your own feed. Your own videos. Nothing else.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 6),
      child: Text(
        text,
        style: const TextStyle(
          color: _muted,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
