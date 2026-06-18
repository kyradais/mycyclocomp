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
    expect(find.text('12.40 km'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();

    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Lokasi user di tengah peta'), findsOneWidget);
  });
}
