import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/shared.dart';

void main() {
  testWidgets('FadeSlideIn fades and slides in once, then rests at identity', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: FadeSlideIn(
          duration: Duration(milliseconds: 300),
          offsetY: 16,
          child: SizedBox(width: 10, height: 10),
        ),
      ),
    );

    FadeTransition fade() => tester.widget(find.byType(FadeTransition));
    Transform transform() => tester.widget(
      find.descendant(
        of: find.byType(FadeSlideIn),
        matching: find.byType(Transform),
      ),
    );

    expect(fade().opacity.value, 0);
    expect(transform().transform.getTranslation().y, 16);

    await tester.pump(const Duration(milliseconds: 150));
    expect(fade().opacity.value, inExclusiveRange(0, 1));
    expect(transform().transform.getTranslation().y, inExclusiveRange(0, 16));

    await tester.pumpAndSettle();
    expect(fade().opacity.value, 1);
    expect(transform().transform.getTranslation().y, 0);

    // Rebuilding with the same key doesn't replay the animation.
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: FadeSlideIn(
          duration: Duration(milliseconds: 300),
          offsetY: 16,
          child: SizedBox(width: 10, height: 10),
        ),
      ),
    );
    expect(fade().opacity.value, 1);
  });

  testWidgets('does not stack a second RepaintBoundary', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: FadeSlideIn(
          child: RepaintBoundary(child: SizedBox(width: 10, height: 10)),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(FadeSlideIn),
        matching: find.byType(RepaintBoundary),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('opacityCurve is applied on top of the progress curve', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: FadeSlideIn(
          duration: Duration(milliseconds: 200),
          curve: Curves.linear,
          opacityCurve: Curves.easeOut,
          child: SizedBox(width: 10, height: 10),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final fade = tester.widget<FadeTransition>(find.byType(FadeTransition));
    expect(fade.opacity.value, closeTo(Curves.easeOut.transform(0.5), 1e-6));
  });
}
