import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Page snapping with a slightly under-damped spring, so a released swipe
/// carries its momentum and settles with a tiny overshoot.
class FeedPhysics extends PageScrollPhysics {
  const FeedPhysics({super.parent});

  @override
  FeedPhysics applyTo(ScrollPhysics? ancestor) {
    return FeedPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 0.6,
        stiffness: 170.0,
        ratio: 0.8,
      );
}
