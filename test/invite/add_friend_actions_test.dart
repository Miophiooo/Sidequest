import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/features/invite/add_friend_actions.dart';

void main() {
  testWidgets('share is an icon button right of "Freund hinzufügen"', (
    tester,
  ) async {
    var adds = 0;
    BuildContext? shareContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: AddFriendActions(
              loading: false,
              onAdd: () => adds++,
              onShare: (context) => shareContext = context,
            ),
          ),
        ),
      ),
    );

    final add = tester.getRect(find.text('Freund hinzufügen'));
    final share = tester.getRect(find.byIcon(Icons.ios_share_rounded));
    expect(share.left, greaterThan(add.right));
    expect((share.center.dy - add.center.dy).abs(), lessThan(1));
    expect(find.text('Meinen Link teilen'), findsNothing);
    expect(
      tester.getSize(find.byType(AddFriendActions)).height,
      AddFriendActions.height,
    );

    await tester.tap(find.byIcon(Icons.ios_share_rounded));
    await tester.tap(find.text('Freund hinzufügen'));
    expect(shareContext, isNotNull);
    expect(adds, 1);
  });

  testWidgets('add is disabled while loading', (tester) async {
    var adds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddFriendActions(
            loading: true,
            onAdd: () => adds++,
            onShare: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ElevatedButton));
    expect(adds, 0);
  });
}
