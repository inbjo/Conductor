import 'dart:ui';

import 'package:conductor_client/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the agent launcher', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ConductorClientApp());

    expect(find.text('Conductor Client'), findsOneWidget);
    expect(find.text('Agent Configuration'), findsOneWidget);
    expect(find.text('Agent Command'), findsOneWidget);
    expect(find.text('Start Agent'), findsOneWidget);
  });
}
