import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nummwe3/features/invite/invite_progress_card.dart';
import 'package:nummwe3/features/onboarding/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  for (final size in const [Size(320, 568), Size(375, 667), Size(430, 932)]) {
    testWidgets('all pages fit without overflow on $size', (tester) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: OnboardingScreen()));
      await tester.pump();
      for (var page = 0; page < 2; page++) {
        await tester.drag(find.byType(PageView), const Offset(-400, 0));
        await tester.pumpAndSettle();
      }

      expect(find.byType(InviteProgressCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('progress card shows how many friends are still missing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: InviteProgressCard(friendCount: 2, surface: 'test'),
        ),
      ),
    );
    expect(find.textContaining('1'), findsWidgets);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
  });
}
