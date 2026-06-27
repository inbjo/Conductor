import 'package:conductor_client/main.dart';
import 'package:flutter/material.dart';
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
    expect(
      normalizeAgentServerUrl('  example.test:8080  '),
      'ws://example.test:8080/ws/agent',
    );
    expect(
      normalizeAgentServerUrl('http://example.test/?debug=1'),
      'ws://example.test/ws/agent?debug=1',
    );
    expect(
      () => normalizeAgentServerUrl('file:///tmp/conductor'),
      throwsFormatException,
    );
    expect(normalizeAgentServerUrl(''), '');
  });

  test('safely rejects invalid server URL inputs before starting', () {
    expect(
      tryNormalizeAgentServerUrl('http://example.test:8080'),
      'ws://example.test:8080/ws/agent',
    );
    expect(tryNormalizeAgentServerUrl('file:///tmp/conductor'), isNull);
    expect(tryNormalizeAgentServerUrl('http://[::1'), isNull);
  });

  test('settings server URL normalization keeps empty values optional', () {
    expect(normalizedSettingsServerUrl(''), '');
    expect(normalizedSettingsServerUrl('   '), '');
    expect(
      normalizedSettingsServerUrl('http://example.test:8080'),
      'ws://example.test:8080/ws/agent',
    );
    expect(normalizedSettingsServerUrl('file:///tmp/conductor'), isNull);
  });

  test('parses boolean flag values used by build defaults and smoke env', () {
    for (final value in ['1', 'true', 'TRUE', ' yes ', 'on']) {
      expect(flagValue(value), isTrue, reason: value);
    }
    for (final value in [null, '', '0', 'false', 'no', 'off', 'random']) {
      expect(flagValue(value), isFalse, reason: '$value');
    }
  });

  test('settings file can be isolated by environment override', () {
    expect(
      settingsFile({
        'CONDUCTOR_CLIENT_SETTINGS_FILE': '/tmp/conductor-test/settings.json',
        'HOME': '/home/example',
      }).path,
      '/tmp/conductor-test/settings.json',
    );
    expect(
      settingsFile({'HOME': '/home/example'}).path,
      pathJoin('/home/example', '.conductor-client', 'settings.json'),
    );
  });

  test('startup commands are parsed from smoke environment', () {
    expect(startupCommandsFromEnv({}), isEmpty);
    expect(
      startupCommandsFromEnv({
        'CONDUCTOR_CLIENT_AUTOCOMMANDS': ' /diagnostics ; /requests\n/help ',
      }),
      ['/diagnostics', '/requests', '/help'],
    );
  });

  test('partial settings preserve existing build defaults', () {
    final settings = <String, dynamic>{
      'serverUrl': 'ws://saved/ws/agent',
      'interactiveApproval': false,
    };

    expect(
      settingsStringValue(settings, 'serverUrl', 'ws://default'),
      'ws://saved/ws/agent',
    );
    expect(
      settingsStringValue(settings, 'agentName', 'built-agent'),
      'built-agent',
    );
    expect(
      settingsStringValue(settings, 'agentRoot', '/built/root'),
      '/built/root',
    );
    expect(
      settingsStringValue(settings, 'audioInput', 'built-audio'),
      'built-audio',
    );
    expect(settingsBoolValue(settings, 'interactiveApproval', true), isFalse);
    expect(settingsBoolValue(settings, 'missingApproval', true), isTrue);
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
    expect(find.text('Agent Name'), findsOneWidget);
    expect(find.text('File Root'), findsOneWidget);
    expect(find.text('Audio Input'), findsOneWidget);
    expect(find.text('Require local approval'), findsOneWidget);
  });

  testWidgets('settings page only applies draft on save', (tester) async {
    SettingsDraft? saved;

    Widget host() {
      return MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (context) => SettingsPage(
                      serverUrl: 'ws://old/ws/agent',
                      agentToken: 'old-token',
                      agentName: '',
                      agentRoot: '',
                      agentBin: '/tmp/conductor-agent',
                      audioInput: '',
                      interactiveApproval: false,
                      onSave: (settings) async {
                        saved = settings;
                      },
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            );
          },
        ),
      );
    }

    await tester.pumpWidget(host());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Server URL'),
      'http://new.example:8080',
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(saved, isNull);

    await tester.pumpWidget(host());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Server URL'),
      'http://new.example:8080',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Agent Token'),
      'new-token',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Agent Name'),
      'new-agent',
    );
    await tester.enterText(find.widgetWithText(TextField, 'File Root'), '/tmp');
    await tester.enterText(
      find.widgetWithText(TextField, 'Audio Input'),
      'default',
    );
    await tester.tap(find.text('Require local approval'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved?.serverUrl, 'ws://new.example:8080/ws/agent');
    expect(saved?.agentToken, 'new-token');
    expect(saved?.agentName, 'new-agent');
    expect(saved?.agentRoot, '/tmp');
    expect(saved?.audioInput, 'default');
    expect(saved?.interactiveApproval, isTrue);
  });

  testWidgets('settings page rejects invalid server url on save', (
    tester,
  ) async {
    SettingsDraft? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          serverUrl: 'ws://old/ws/agent',
          agentToken: 'old-token',
          agentName: '',
          agentRoot: '',
          agentBin: '/tmp/conductor-agent',
          audioInput: '',
          interactiveApproval: false,
          onSave: (settings) async {
            saved = settings;
          },
        ),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Server URL'),
      'file:///tmp/conductor',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(saved, isNull);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Server URL is invalid'), findsOneWidget);
  });
}
