import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'app_state.dart';
import 'cache.dart';
import 'haptics.dart';
import 'models.dart';
import 'physics.dart';
import 'settings_screen.dart';

const Color _ink = Color(0xFF2C2C2A);
const Color _glass = Color(0xE0FFFFFF);
const Color _glassLine = Color(0x1A000000);
const Color _pink = Color(0xFFD4537E);
const Color _placeholder = Color(0xFFF1EFE8);

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _BurstData {
  _BurstData(this.id, this.pos);
  final int id;
  final Offset pos;
}

class _FeedScreenState extends State<FeedScreen> with WidgetsBindingObserver {
  final AppState app = AppState.instance;
  final PageController _page = PageController(keepPage: false);

  final Map<int, VideoPlayerController> _ctrls = <int, VideoPlayerController>{};
  final Set<int> _initializing = <int>{};
  final Set<int> _failed = <int>{};
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  final ValueNotifier<bool> _flash = ValueNotifier<bool>(false);
  final List<_BurstData> _bursts = <_BurstData>[];

  VideoPlayerController? _listening;
  int _index = 0;
  int _seenVersion = -1;
  String? _currentId;
  bool _playing = true;
  bool _scrubbing = false;
  bool _advancing = false;
  bool _hud = true;
  bool _inSettings = false;
  Timer? _hudTimer;
  Timer? _flashTimer;
  Offset _lastTap = Offset.zero;
  int _lastScrubSecond = -1;
  String _scrubLabel = '';
  int _burstId = 0;

  VideoItem? get _item =>
      (_index >= 0 && _index < app.items.length) ? app.items[_index] : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(_onApp);
    _showHud();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(_onApp);
    _hudTimer?.cancel();
    _flashTimer?.cancel();
    _listening?.removeListener(_tick);
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _ctrls.clear();
    _progress.dispose();
    _flash.dispose();
    _page.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _playCurrent();
    } else if (state == AppLifecycleState.paused) {
      for (final c in _ctrls.values) {
        c.pause();
      }
    }
  }

  // ---------------------------------------------------------------- state

  void _onApp() {
    if (!mounted) return;
    if (_seenVersion != app.feedVersion) {
      _seenVersion = app.feedVersion;
      _resetFeed();
    }
    setState(() {});
  }

  void _resetFeed() {
    final prevId = _currentId;
    for (final k in _ctrls.keys.toList()) {
      _drop(k);
    }
    _initializing.clear();
    _failed.clear();
    _advancing = false;
    _progress.value = 0;

    final list = app.items;
    var start = 0;
    if (prevId != null) {
      final f = list.indexWhere((v) => v.id == prevId);
      if (f > 0) start = f;
    }
    _index = start;
    _currentId = list.isEmpty ? null : list[start].id;

    if (start > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _page.hasClients) _page.jumpToPage(start);
      });
    } else if (_page.hasClients) {
      _page.jumpToPage(0);
    }
    for (var k = start - 1; k <= start + 2; k++) {
      _ensure(k);
    }
  }

  // ------------------------------------------------------------- video

  Future<VideoPlayerController> _create(VideoItem item) async {
    if (!item.remote) {
      return VideoPlayerController.file(File(item.uri));
    }
    final cached = await CacheService.cached(item.uri);
    if (cached != null) return VideoPlayerController.file(cached);
    if (app.cacheOffline) {
      CacheService.download(item.uri);
    }
    return VideoPlayerController.networkUrl(Uri.parse(item.uri));
  }

  Future<void> _ensure(int i) async {
    final list = app.items;
    if (i < 0 || i >= list.length) return;
    if (_ctrls.containsKey(i) || _initializing.contains(i) || _failed.contains(i)) {
      return;
    }
    final version = app.feedVersion;
    _initializing.add(i);
    VideoPlayerController? c;
    try {
      c = await _create(list[i]);
      await c.initialize();
      await c.setLooping(!app.autoNext);
      final stale = !mounted ||
          version != app.feedVersion ||
          i < _index - 1 ||
          i > _index + 2;
      if (stale) {
        await c.dispose();
        return;
      }
      _ctrls[i] = c;
      if (i == _index) _playCurrent();
      setState(() {});
    } catch (_) {
      await c?.dispose();
      if (mounted && version == app.feedVersion) {
        _failed.add(i);
        if (i == _index) _skipBroken();
        setState(() {});
      }
    } finally {
      _initializing.remove(i);
    }
  }

  void _skipBroken() {
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      if (_failed.contains(_index) && _index + 1 < app.items.length) {
        _page.nextPage(
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _drop(int k) {
    final c = _ctrls.remove(k);
    if (c == null) return;
    if (identical(c, _listening)) {
      c.removeListener(_tick);
      _listening = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _onPage(int i) {
    if (i == _index) return;
    _index = i;
    _currentId = i < app.items.length ? app.items[i].id : null;
    _advancing = false;
    _progress.value = 0;
    _playing = true;
    Haptics.tick();

    for (final k in _ctrls.keys.toList()) {
      if (k < i - 1 || k > i + 2) _drop(k);
    }
    for (var k = i - 1; k <= i + 2; k++) {
      _ensure(k);
    }
    _ctrls[i]?.seekTo(Duration.zero);
    _playCurrent();
    _showHud();
    setState(() {});
  }

  void _playCurrent() {
    for (final e in _ctrls.entries) {
      if (e.key == _index && _playing && !_scrubbing && !_inSettings) {
        e.value.setLooping(!app.autoNext);
        e.value.play();
      } else {
        e.value.pause();
      }
    }
    _attach(_ctrls[_index]);
  }

  void _attach(VideoPlayerController? c) {
    if (identical(c, _listening)) return;
    _listening?.removeListener(_tick);
    _listening = c;
    c?.addListener(_tick);
  }

  void _tick() {
    final c = _listening;
    if (c == null) return;
    final v = c.value;
    if (!v.isInitialized) return;
    final total = v.duration.inMilliseconds;
    if (total <= 0) return;
    final pos = v.position.inMilliseconds;
    if (!_scrubbing) {
      _progress.value = (pos / total).clamp(0.0, 1.0).toDouble();
    }
    if (app.autoNext && !_scrubbing && !_advancing && pos >= total - 150) {
      _advancing = true;
      _next();
    }
  }

  void _next() {
    final c = _ctrls[_index];
    if (_index + 1 >= app.items.length) {
      c?.seekTo(Duration.zero);
      c?.play();
      _advancing = false;
      return;
    }
    if (MediaQuery.of(context).disableAnimations) {
      _page.jumpToPage(_index + 1);
    } else {
      _page.nextPage(
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    }
  }

  // ----------------------------------------------------------- gestures

  void _togglePlay() {
    setState(() => _playing = !_playing);
    _playCurrent();
    Haptics.soft();
    _flash.value = true;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 520), () {
      _flash.value = false;
    });
    _showHud();
  }

  void _like(Offset p) {
    final item = _item;
    if (item == null) return;
    if (!app.isFav(item.id)) app.setFav(item.id, true);
    Haptics.like();
    setState(() => _bursts.add(_BurstData(++_burstId, p)));
    _showHud();
  }

  void _toggleHeart() {
    final item = _item;
    if (item == null) return;
    app.setFav(item.id, !app.isFav(item.id));
    Haptics.soft();
    _showHud();
  }

  void _scrubStart(LongPressStartDetails d) {
    final c = _ctrls[_index];
    if (c == null) return;
    _scrubbing = true;
    c.pause();
    Haptics.medium();
    _lastScrubSecond = -1;
    _hudTimer?.cancel();
    _scrubTo(d.globalPosition.dx);
    setState(() => _hud = true);
  }

  void _scrubMove(LongPressMoveUpdateDetails d) {
    if (_scrubbing) _scrubTo(d.globalPosition.dx);
  }

  void _scrubTo(double dx) {
    final c = _ctrls[_index];
    if (c == null) return;
    final w = MediaQuery.of(context).size.width;
    final f = (dx / w).clamp(0.0, 1.0).toDouble();
    final total = c.value.duration;
    final pos = Duration(milliseconds: (total.inMilliseconds * f).round());
    c.seekTo(pos);
    _progress.value = f;
    if (pos.inSeconds != _lastScrubSecond) {
      _lastScrubSecond = pos.inSeconds;
      Haptics.tick();
    }
    setState(() => _scrubLabel = '${_fmt(pos)} / ${_fmt(total)}');
  }

  void _scrubEnd() {
    if (!_scrubbing) return;
    _scrubbing = false;
    if (_playing) _ctrls[_index]?.play();
    _showHud();
    setState(() {});
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  void _showHud() {
    _hudTimer?.cancel();
    if (!_hud && mounted) setState(() => _hud = true);
    _hudTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_scrubbing) setState(() => _hud = false);
    });
  }

  Future<void> _openSettings() async {
    _inSettings = true;
    _playCurrent();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
    _inSettings = false;
    await app.applyChanges();
    if (!mounted) return;
    _playCurrent();
    _showHud();
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final items = app.items;
    if (items.isEmpty) {
      return _Empty(loading: app.loading, onSources: _openSettings);
    }
    final mq = MediaQuery.of(context);
    final reduce = mq.disableAnimations;
    final item = _item;
    final fade = Duration(milliseconds: reduce ? 120 : 380);

    return Scaffold(
      backgroundColor: _placeholder,
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _showHud(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlay,
              onDoubleTapDown: (d) => _lastTap = d.globalPosition,
              onDoubleTap: () => _like(_lastTap),
              onLongPressStart: _scrubStart,
              onLongPressMoveUpdate: _scrubMove,
              onLongPressEnd: (_) => _scrubEnd(),
              onLongPressCancel: _scrubEnd,
              child: PageView.builder(
                scrollDirection: Axis.vertical,
                controller: _page,
                physics: reduce
                    ? const PageScrollPhysics()
                    : const FeedPhysics(parent: BouncingScrollPhysics()),
                itemCount: items.length,
                onPageChanged: _onPage,
                itemBuilder: (context, i) => _VideoPage(
                  controller: _ctrls[i],
                  failed: _failed.contains(i),
                ),
              ),
            ),

            // Progress hairline
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: ValueListenableBuilder<double>(
                    valueListenable: _progress,
                    builder: (context, p, _) => FractionallySizedBox(
                      widthFactor: p,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        height: _scrubbing ? 8 : 3,
                        decoration: const BoxDecoration(
                          color: _ink,
                          borderRadius:
                              BorderRadius.only(topRight: Radius.circular(3)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Play / pause flash
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _flash,
                    builder: (context, on, _) => AnimatedScale(
                      scale: on ? 1 : 0.7,
                      duration: Duration(milliseconds: reduce ? 1 : 220),
                      curve: Curves.easeOutBack,
                      child: AnimatedOpacity(
                        opacity: on ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            color: _glass,
                            shape: BoxShape.circle,
                            border: Border.all(color: _glassLine, width: 0.5),
                          ),
                          child: Icon(
                            _playing ? Icons.play_arrow_rounded : Icons.pause_rounded,
                            size: 34,
                            color: _ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Heart bursts
            for (final b in _bursts)
              Positioned(
                key: ValueKey<int>(b.id),
                left: b.pos.dx - 90,
                top: b.pos.dy - 90,
                width: 180,
                height: 180,
                child: IgnorePointer(
                  child: HeartBurst(
                    reduce: reduce,
                    onDone: () {
                      if (mounted) {
                        setState(() => _bursts.removeWhere((x) => x.id == b.id));
                      }
                    },
                  ),
                ),
              ),

            // Auto-hiding controls
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_hud,
                child: AnimatedOpacity(
                  opacity: _hud ? 1 : 0,
                  duration: fade,
                  curve: Curves.easeOutCubic,
                  child: Stack(
                    children: [
                      Positioned(
                        top: mq.padding.top + 8,
                        right: 12,
                        child: _GlassButton(
                          icon: Icons.tune_rounded,
                          onTap: _openSettings,
                        ),
                      ),
                      if (item != null)
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: mq.padding.bottom + 20,
                          child: _InfoPill(
                            item: item,
                            fav: app.isFav(item.id),
                            onHeart: _toggleHeart,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // Scrub time
            if (_scrubbing)
              Positioned(
                left: 0,
                right: 0,
                bottom: mq.padding.bottom + 104,
                child: IgnorePointer(
                  child: Center(child: _Pill(text: _scrubLabel)),
                ),
              ),

            // New videos toast
            if (app.toast != null)
              Positioned(
                top: mq.padding.top + 14,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey<String?>(app.toast),
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: Duration(milliseconds: reduce ? 100 : 420),
                      curve: Curves.easeOutBack,
                      builder: (context, t, child) => Opacity(
                        opacity: t.clamp(0.0, 1.0).toDouble(),
                        child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
                      ),
                      child: _Pill(text: app.toast ?? '', icon: Icons.sync_rounded),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ widgets

class _VideoPage extends StatelessWidget {
  const _VideoPage({required this.controller, required this.failed});

  final VideoPlayerController? controller;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    Widget content = const SizedBox.expand();
    if (c != null && c.value.isInitialized) {
      final s = c.value.size;
      final portrait = s.height >= s.width;
      content = FittedBox(
        fit: portrait ? BoxFit.cover : BoxFit.contain,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: s.width,
          height: s.height,
          child: VideoPlayer(c),
        ),
      );
    }
    return ColoredBox(
      color: _placeholder,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedOpacity(
            opacity: c != null ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: content,
          ),
          if (failed)
            const Center(
              child: Text(
                "Can't play this video",
                style: TextStyle(color: Color(0xFF5F5E5A), fontSize: 15),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.item, required this.fav, required this.onHeart});

  final VideoItem item;
  final bool fav;
  final VoidCallback onHeart;

  @override
  Widget build(BuildContext context) {
    final memory = item.memoryLabel;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 8, 6, 8),
      decoration: BoxDecoration(
        color: _glass,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _glassLine, width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (memory != null)
                  Text(
                    memory,
                    style: const TextStyle(
                      color: Color(0xFF993556),
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: onHeart,
            iconSize: 26,
            constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
            icon: Icon(
              fav ? Icons.favorite : Icons.favorite_border,
              color: fav ? _pink : _ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _glass,
      shape: const CircleBorder(side: BorderSide(color: _glassLine, width: 0.5)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(icon, color: _ink, size: 24),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: _glass,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _glassLine, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: _ink),
            const SizedBox(width: 6),
          ],
          Text(text, style: const TextStyle(color: _ink, fontSize: 13)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.loading, required this.onSources});

  final bool loading;
  final VoidCallback onSources;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: loading
              ? const CircularProgressIndicator(color: _ink, strokeWidth: 2)
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Your feed is empty',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                          color: _ink,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Add a phone folder or a manifest link.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF5F5E5A), fontSize: 15),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: onSources,
                        style: FilledButton.styleFrom(
                          backgroundColor: _ink,
                          minimumSize: const Size(180, 52),
                        ),
                        child: const Text('Open sources'),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Heart that springs in with a ring of particles. Falls back to a plain
/// fade when the system asks for reduced motion.
class HeartBurst extends StatefulWidget {
  const HeartBurst({super.key, required this.reduce, required this.onDone});

  final bool reduce;
  final VoidCallback onDone;

  @override
  State<HeartBurst> createState() => _HeartBurstState();
}

class _HeartBurstState extends State<HeartBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.reduce ? 450 : 800),
    );
    _c.forward().whenComplete(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final scale = widget.reduce
            ? 1.0
            : 0.3 +
                0.9 * Curves.elasticOut.transform((t / 0.55).clamp(0.0, 1.0).toDouble());
        final opacity =
            t < 0.6 ? 1.0 : (1 - (t - 0.6) / 0.4).clamp(0.0, 1.0).toDouble();
        final lift = widget.reduce ? 0.0 : -34 * Curves.easeOut.transform(t);

        final kids = <Widget>[];
        if (!widget.reduce) {
          for (var i = 0; i < 9; i++) {
            final a = i / 9 * math.pi * 2;
            final d = (52 + (i % 3) * 12) * Curves.easeOutCubic.transform(t);
            final s = 7 * (1 - t * 0.8);
            kids.add(
              Positioned(
                left: 90 + math.cos(a) * d - s / 2,
                top: 90 + math.sin(a) * d - s / 2,
                child: Opacity(
                  opacity: (1 - t).clamp(0.0, 1.0).toDouble(),
                  child: Container(
                    width: s,
                    height: s,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i.isEven ? _pink : const Color(0xFFED93B1),
                    ),
                  ),
                ),
              ),
            );
          }
        }
        kids.add(
          Center(
            child: Transform.translate(
              offset: Offset(0, lift),
              child: Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: scale,
                  child: const Icon(Icons.favorite, size: 76, color: _pink),
                ),
              ),
            ),
          ),
        );
        return Stack(clipBehavior: Clip.none, children: kids);
      },
    );
  }
}
