import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mycyclocomp/main.dart';

void main() {
  testWidgets('shows speedometer first and map after swipe', (tester) async {
    await tester.pumpWidget(
      CyclocompApp(
        repository: FakeCyclocompRepository.demo(),
        useLiveMap: false,
      ),
    );

    expect(find.text('Cyclocomp'), findsOneWidget);
    expect(find.text('Map'), findsNothing);
    expect(find.text('0.00 km'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);

    await tester.tap(find.text('Start'));
    await tester.pump();

    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    await tester.tap(find.text('Pause'));
    await tester.pump();

    expect(find.text('Resume'), findsOneWidget);

    await tester.tap(find.text('Resume'));
    await tester.pump();

    final stopFinder = find.text('Stop');
    final gesture = await tester.startGesture(tester.getCenter(stopFinder));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Start'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();

    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Akurasi ±4.5 m'), findsOneWidget);
  });
}
