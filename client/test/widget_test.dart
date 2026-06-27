import 'dart:ui';

import 'package:conductor_client/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes common server URL inputs', () {
    expect(
      normalizeAgentServerUrl('127.0.0.1:8080'),
      'ws://127.0.0.1:8080/ws/agent',
    );
    expect(
      normalizeAgentServerUrl('http://example.test:8080'),
      'ws://example.test:8080/ws/agent',
    );
    expect(
      normalizeAgentServerUrl('https://example.test'),
      'wss://example.test/ws/agent',
    );
    expect(
      normalizeAgentServerUrl('wss://example.test/custom'),
      'wss://example.test/custom',
    );
  });

  testWidgets('shows the agent launcher', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ConductorClientApp());

    expect(find.text('Conductor Client'), findsOneWidget);
    expect(find.text('Controlled Endpoint'), findsOneWidget);
    expect(find.text('Agent Command'), findsOneWidget);
    expect(find.text('Start Agent'), findsOneWidget);
    expect(find.text('Agent Configuration'), findsNothing);

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();

    expect(find.text('Agent Configuration'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Agent Token'), findsOneWidget);
  });
}
