import 'package:flutter/services.dart';

import 'app_state.dart';

/// Every action has its own haptic signature, so the feed can be felt
/// without looking at it.
class Haptics {
  static bool get _on => AppState.instance.haptics;

  static void tick() {
    if (_on) HapticFeedback.selectionClick();
  }

  static void soft() {
    if (_on) HapticFeedback.lightImpact();
  }

  static void medium() {
    if (_on) HapticFeedback.mediumImpact();
  }

  static Future<void> like() async {
    if (!_on) return;
    HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    HapticFeedback.lightImpact();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    HapticFeedback.mediumImpact();
  }
}
