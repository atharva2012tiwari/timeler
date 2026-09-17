import 'package:flutter_test/flutter_test.dart';
import 'package:timeler/main.dart';

void main() {
  testWidgets('shows the Timeler timer and controls', (tester) async {
    await tester.pumpWidget(const Timeler());
    expect(find.text('TIMELER'), findsOneWidget);
    expect(find.text('30:00'), findsOneWidget);
    expect(find.text('Begin focus'), findsOneWidget);
  });
}
