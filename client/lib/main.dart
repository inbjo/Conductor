import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

const buildDefaultServerUrl = String.fromEnvironment(
  'CONDUCTOR_DEFAULT_SERVER_URL',
  defaultValue: 'https://conductor.moyu.ge',
);
const buildDefaultAgentToken = String.fromEnvironment(
  'CONDUCTOR_DEFAULT_AGENT_TOKEN',
);
const buildDefaultAgentName = String.fromEnvironment(
  'CONDUCTOR_DEFAULT_AGENT_NAME',
);
const buildDefaultAgentRoot = String.fromEnvironment(
  'CONDUCTOR_DEFAULT_AGENT_ROOT',
);
const buildDefaultAudioInput = String.fromEnvironment(
  'CONDUCTOR_DEFAULT_AUDIO_INPUT',
);
const buildDefaultInteractiveApprovalText = String.fromEnvironment(
  'CONDUCTOR_DEFAULT_INTERACTIVE_APPROVAL',
  defaultValue: 'false',
);

void main() {
  runApp(const ConductorClientApp());
}

class ConductorClientApp extends StatelessWidget {
  const ConductorClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Conductor Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff3f5f4a),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff4f6f1),
        useMaterial3: true,
      ),
      home: const AgentLauncherPage(),
    );
  }
}

class AgentLauncherPage extends StatefulWidget {
  const AgentLauncherPage({super.key});

  @override
  State<AgentLauncherPage> createState() => _AgentLauncherPageState();
}

class _AgentLauncherPageState extends State<AgentLauncherPage> {
  final _serverUrl = TextEditingController(text: buildDefaultServerUrl);
  final _agentToken = TextEditingController(text: buildDefaultAgentToken);
  final _agentName = TextEditingController(text: buildDefaultAgentName);
  final _agentRoot = TextEditingController(text: buildDefaultAgentRoot);
  final _agentBin = TextEditingController();
  final _audioInput = TextEditingController(text: buildDefaultAudioInput);
  final _agentCommand = TextEditingController();
  final _logs = <String>[];
  final _scrollController = ScrollController();

  Process? _process;
  int? _lastExitCode;
  String? _activeSessionId;
  String? _displayCode;
  bool _interactiveApproval = flagValue(buildDefaultInteractiveApprovalText);
  bool _starting = false;

  bool get _running => _process != null;

  @override
  void initState() {
    super.initState();
    _agentBin.text = defaultAgentBinary();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _process?.kill();
    _serverUrl.dispose();
    _agentToken.dispose();
    _agentName.dispose();
    _agentRoot.dispose();
    _agentBin.dispose();
    _audioInput.dispose();
    _agentCommand.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _loadSettings();
    if (!mounted) return;
    _applyEnvironmentOverrides();
    if (envFlag('CONDUCTOR_CLIENT_AUTOSTART')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_startAgent());
      });
    }
  }

  Future<void> _loadSettings() async {
    final file = settingsFile();
    if (!await file.exists()) return;
    try {
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _serverUrl.text = settingsStringValue(
          value,
          'serverUrl',
          _serverUrl.text,
        );
        _agentToken.text = settingsStringValue(
          value,
          'agentToken',
          _agentToken.text,
        );
        _agentName.text = settingsStringValue(
          value,
          'agentName',
          _agentName.text,
        );
        _agentRoot.text = settingsStringValue(
          value,
          'agentRoot',
          _agentRoot.text,
        );
        final savedAgentBin = settingsStringValue(
          value,
          'agentBin',
          _agentBin.text,
        );
        _agentBin.text =
            savedAgentBin.trim().isNotEmpty && !File(savedAgentBin).existsSync()
            ? defaultAgentBinary()
            : savedAgentBin;
        _audioInput.text = settingsStringValue(
          value,
          'audioInput',
          _audioInput.text,
        );
        _interactiveApproval = settingsBoolValue(
          value,
          'interactiveApproval',
          _interactiveApproval,
        );
      });
    } catch (error) {
      _appendLog('settings load failed: $error');
    }
  }

  void _applyEnvironmentOverrides() {
    final env = Platform.environment;
    final serverUrl = env['CONDUCTOR_SERVER_URL'];
    final agentToken = env['CONDUCTOR_AGENT_TOKEN'];
    final agentName = env['CONDUCTOR_AGENT_NAME'];
    final agentRoot = env['CONDUCTOR_AGENT_ROOT'];
    final agentBin = env['CONDUCTOR_CLIENT_AGENT_BIN'];
    final audioInput = env['CONDUCTOR_AUDIO_INPUT'];
    final approval = env['CONDUCTOR_INTERACTIVE_APPROVAL'];

    if (serverUrl == null &&
        agentToken == null &&
        agentName == null &&
        agentRoot == null &&
        agentBin == null &&
        audioInput == null &&
        approval == null) {
      return;
    }

    setState(() {
      if (serverUrl != null && serverUrl.trim().isNotEmpty) {
        _serverUrl.text = serverUrl.trim();
      }
      if (agentToken != null) _agentToken.text = agentToken;
      if (agentName != null) _agentName.text = agentName.trim();
      if (agentRoot != null) _agentRoot.text = agentRoot.trim();
      if (agentBin != null && agentBin.trim().isNotEmpty) {
        _agentBin.text = agentBin.trim();
      }
      if (audioInput != null) _audioInput.text = audioInput.trim();
      if (approval != null) {
        _interactiveApproval = envFlag('CONDUCTOR_INTERACTIVE_APPROVAL');
      }
    });
  }

  Future<void> _saveSettings() async {
    final file = settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'serverUrl': _serverUrl.text.trim(),
        'agentToken': _agentToken.text,
        'agentName': _agentName.text.trim(),
        'agentRoot': _agentRoot.text.trim(),
        'agentBin': _agentBin.text.trim(),
        'audioInput': _audioInput.text.trim(),
        'interactiveApproval': _interactiveApproval,
      }),
    );
  }

  Future<void> _startAgent() async {
    if (_running || _starting) return;

    final binary = _agentBin.text.trim();
    if (binary.isEmpty) {
      _appendLog('agent binary path is empty');
      return;
    }
    if (!File(binary).existsSync()) {
      _appendLog('agent binary does not exist: $binary');
      return;
    }
    if (_serverUrl.text.trim().isEmpty) {
      _appendLog('server url is empty');
      return;
    }
    final serverUrl = tryNormalizeAgentServerUrl(_serverUrl.text);
    if (serverUrl == null) {
      _appendLog('server url is invalid: ${_serverUrl.text.trim()}');
      return;
    }

    setState(() {
      _starting = true;
      _lastExitCode = null;
    });

    _serverUrl.text = serverUrl;
    await _saveSettings();

    final env = Map<String, String>.from(Platform.environment)
      ..['CONDUCTOR_SERVER_URL'] = serverUrl
      ..['CONDUCTOR_INTERACTIVE_APPROVAL'] = _interactiveApproval ? '1' : '0';

    final token = _agentToken.text.trim();
    final name = _agentName.text.trim();
    final root = _agentRoot.text.trim();
    final audioInput = _audioInput.text.trim();
    if (token.isNotEmpty) env['CONDUCTOR_AGENT_TOKEN'] = token;
    if (name.isNotEmpty) env['CONDUCTOR_AGENT_NAME'] = name;
    if (root.isNotEmpty) env['CONDUCTOR_AGENT_ROOT'] = root;
    if (audioInput.isNotEmpty) env['CONDUCTOR_AUDIO_INPUT'] = audioInput;

    try {
      _appendLog('starting agent: $binary');
      final process = await Process.start(
        binary,
        const [],
        environment: env,
        mode: ProcessStartMode.normal,
      );
      setState(() {
        _process = process;
        _starting = false;
      });
      _streamLines(process.stdout, 'out');
      _streamLines(process.stderr, 'err');
      unawaited(_sendStartupCommands());
      unawaited(
        process.exitCode.then((code) {
          if (!mounted) return;
          setState(() {
            _lastExitCode = code;
            _process = null;
            _activeSessionId = null;
          });
          _appendLog('agent exited with code $code');
        }),
      );
    } catch (error) {
      setState(() {
        _starting = false;
      });
      _appendLog('start failed: $error');
    }
  }

  Future<void> _sendStartupCommands() async {
    final commands = startupCommandsFromEnv(Platform.environment);
    if (commands.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final command in commands) {
      await _sendAgentCommand(command);
    }
  }

  void _stopAgent() {
    final process = _process;
    if (process == null) return;
    _appendLog('stopping agent pid=${process.pid}');
    process.kill();
  }

  Future<void> _endRemoteControl() async {
    final sessionId = _activeSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    await _sendAgentCommand('/session close $sessionId');
  }

  Future<void> _sendAgentCommand([String? value]) async {
    final process = _process;
    final command = (value ?? _agentCommand.text).trim();
    if (command.isEmpty) return;
    if (process == null) {
      _appendLog('cannot send command while agent is stopped: $command');
      return;
    }
    try {
      process.stdin.writeln(command);
      await process.stdin.flush();
      _appendLog('in: $command');
      if (value == null) _agentCommand.clear();
    } catch (error) {
      _appendLog('send command failed: $error');
    }
  }

  void _streamLines(Stream<List<int>> stream, String label) {
    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('$label: $line'));
  }

  void _appendLog(String line) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final message = '[$timestamp] $line';
    final activeSession = remoteActiveSessionFromLog(line);
    final endedSession = remoteEndedSessionFromLog(line);
    final displayCode = displayCodeFromLog(line);
    stdout.writeln(message);
    if (!mounted) return;
    setState(() {
      if (activeSession != null) _activeSessionId = activeSession;
      if (endedSession != null && endedSession == _activeSessionId) {
        _activeSessionId = null;
      }
      if (displayCode != null) _displayCode = displayCode;
      _logs.add(message);
      if (_logs.length > 500) _logs.removeRange(0, _logs.length - 500);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final statusText = _running
        ? 'running pid=${_process!.pid}'
        : _starting
        ? 'starting'
        : _lastExitCode == null
        ? 'stopped'
        : 'stopped exit=$_lastExitCode';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Conductor Client'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: _running || _starting ? null : _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: StatusPill(text: statusText, running: _running),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 920;
            final overview = AgentOverview(
              statusText: statusText,
              running: _running,
              starting: _starting,
              lastExitCode: _lastExitCode,
              logCount: _logs.length,
              activeSessionId: _activeSessionId,
              displayCode: _displayCode,
              onStart: _startAgent,
              onStop: _stopAgent,
              onEndRemoteControl: _endRemoteControl,
              onOpenSettings: _openSettings,
            );
            final logs = LogPanel(
              logs: _logs,
              controller: _scrollController,
              command: _agentCommand,
              running: _running,
              onSendCommand: _sendAgentCommand,
            );
            return Padding(
              padding: const EdgeInsets.all(16),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 360, child: overview),
                        const SizedBox(width: 16),
                        Expanded(child: logs),
                      ],
                    )
                  : ListView(
                      children: [
                        overview,
                        const SizedBox(height: 16),
                        SizedBox(height: 360, child: logs),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => SettingsPage(
          serverUrl: _serverUrl.text,
          agentToken: _agentToken.text,
          agentName: _agentName.text,
          agentRoot: _agentRoot.text,
          agentBin: _agentBin.text,
          audioInput: _audioInput.text,
          interactiveApproval: _interactiveApproval,
          onSave: (settings) async {
            setState(() {
              _serverUrl.text = settings.serverUrl;
              _agentToken.text = settings.agentToken;
              _agentName.text = settings.agentName;
              _agentRoot.text = settings.agentRoot;
              _agentBin.text = settings.agentBin;
              _audioInput.text = settings.audioInput;
              _interactiveApproval = settings.interactiveApproval;
            });
            await _saveSettings();
            _appendLog('settings saved');
          },
        ),
      ),
    );
  }
}

class AgentOverview extends StatelessWidget {
  const AgentOverview({
    super.key,
    required this.statusText,
    required this.running,
    required this.starting,
    required this.lastExitCode,
    required this.logCount,
    required this.activeSessionId,
    required this.displayCode,
    required this.onStart,
    required this.onStop,
    required this.onEndRemoteControl,
    required this.onOpenSettings,
  });

  final String statusText;
  final bool running;
  final bool starting;
  final int? lastExitCode;
  final int logCount;
  final String? activeSessionId;
  final String? displayCode;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final Future<void> Function() onEndRemoteControl;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.desktop_windows_outlined, size: 40),
            const SizedBox(height: 16),
            Text(
              'Controlled Endpoint',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              statusText,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            _Metric(label: 'Log lines', value: '$logCount'),
            _Metric(
              label: 'Last exit',
              value: lastExitCode == null ? '-' : '$lastExitCode',
            ),
            _Metric(label: 'Device code', value: displayCode ?? '-'),
            if (activeSessionId != null) ...[
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xfffff3cd),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xffd39e00)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'An administrator is controlling this computer.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: onEndRemoteControl,
                        icon: const Icon(Icons.do_not_disturb_on_outlined),
                        label: const Text('End control'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: running ? onStop : onStart,
              icon: Icon(running ? Icons.stop : Icons.play_arrow),
              label: Text(running ? 'Stop Agent' : 'Start Agent'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: starting || running ? null : onOpenSettings,
              icon: const Icon(Icons.tune),
              label: const Text('Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.serverUrl,
    required this.agentToken,
    required this.agentName,
    required this.agentRoot,
    required this.agentBin,
    required this.audioInput,
    required this.interactiveApproval,
    required this.onSave,
  });

  final String serverUrl;
  final String agentToken;
  final String agentName;
  final String agentRoot;
  final String agentBin;
  final String audioInput;
  final bool interactiveApproval;
  final Future<void> Function(SettingsDraft settings) onSave;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _serverUrl;
  late final TextEditingController _agentToken;
  late final TextEditingController _agentName;
  late final TextEditingController _agentRoot;
  late final TextEditingController _agentBin;
  late final TextEditingController _audioInput;
  late bool _interactiveApproval;

  @override
  void initState() {
    super.initState();
    _serverUrl = TextEditingController(text: widget.serverUrl);
    _agentToken = TextEditingController(text: widget.agentToken);
    _agentName = TextEditingController(text: widget.agentName);
    _agentRoot = TextEditingController(text: widget.agentRoot);
    _agentBin = TextEditingController(text: widget.agentBin);
    _audioInput = TextEditingController(text: widget.audioInput);
    _interactiveApproval = widget.interactiveApproval;
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _agentToken.dispose();
    _agentName.dispose();
    _agentRoot.dispose();
    _agentBin.dispose();
    _audioInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Agent Configuration',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    Field(controller: _serverUrl, label: 'Server URL'),
                    Field(
                      controller: _agentToken,
                      label: 'Agent Token',
                      obscureText: true,
                    ),
                    Field(
                      controller: _agentName,
                      label: 'Agent Name',
                      hint: 'optional',
                    ),
                    Field(
                      controller: _agentRoot,
                      label: 'File Root',
                      hint: 'optional, defaults to home',
                    ),
                    Field(controller: _agentBin, label: 'Agent Binary'),
                    Field(
                      controller: _audioInput,
                      label: 'Audio Input',
                      hint: 'optional',
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Require local approval'),
                      value: _interactiveApproval,
                      onChanged: (value) {
                        setState(() => _interactiveApproval = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: () async {
                        final serverUrl = normalizedSettingsServerUrl(
                          _serverUrl.text,
                        );
                        if (serverUrl == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Server URL is invalid'),
                            ),
                          );
                          return;
                        }
                        await widget.onSave(
                          SettingsDraft(
                            serverUrl: serverUrl,
                            agentToken: _agentToken.text,
                            agentName: _agentName.text,
                            agentRoot: _agentRoot.text,
                            agentBin: _agentBin.text,
                            audioInput: _audioInput.text,
                            interactiveApproval: _interactiveApproval,
                          ),
                        );
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsDraft {
  const SettingsDraft({
    required this.serverUrl,
    required this.agentToken,
    required this.agentName,
    required this.agentRoot,
    required this.agentBin,
    required this.audioInput,
    required this.interactiveApproval,
  });

  final String serverUrl;
  final String agentToken;
  final String agentName;
  final String agentRoot;
  final String agentBin;
  final String audioInput;
  final bool interactiveApproval;
}

class Field extends StatelessWidget {
  const Field({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: label,
          hintText: hint,
          isDense: true,
        ),
      ),
    );
  }
}

class LogPanel extends StatelessWidget {
  const LogPanel({
    super.key,
    required this.logs,
    required this.controller,
    required this.command,
    required this.running,
    required this.onSendCommand,
  });

  final List<String> logs;
  final ScrollController controller;
  final TextEditingController command;
  final bool running;
  final Future<void> Function([String? value]) onSendCommand;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: const Color(0xff111714),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal, color: Color(0xffd9e5d8)),
                const SizedBox(width: 8),
                Text(
                  'Agent Logs',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: const Color(0xffd9e5d8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            CommandBar(
              command: command,
              running: running,
              onSendCommand: onSendCommand,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: logs.isEmpty
                  ? const Center(
                      child: Text(
                        'No logs yet.',
                        style: TextStyle(color: Color(0xff8fa393)),
                      ),
                    )
                  : ListView.builder(
                      controller: controller,
                      itemCount: logs.length,
                      itemBuilder: (context, index) {
                        return SelectableText(
                          logs[index],
                          style: const TextStyle(
                            color: Color(0xffd9e5d8),
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class CommandBar extends StatelessWidget {
  const CommandBar({
    super.key,
    required this.command,
    required this.running,
    required this.onSendCommand,
  });

  final TextEditingController command;
  final bool running;
  final Future<void> Function([String? value]) onSendCommand;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xff44564a)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: command,
                enabled: running,
                style: const TextStyle(
                  color: Color(0xffd9e5d8),
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
                onSubmitted: (_) => onSendCommand(),
                decoration: InputDecoration(
                  border: border,
                  enabledBorder: border,
                  focusedBorder: border.copyWith(
                    borderSide: const BorderSide(color: Color(0xff9ec69a)),
                  ),
                  disabledBorder: border,
                  isDense: true,
                  labelText: 'Agent Command',
                  labelStyle: const TextStyle(color: Color(0xff9bb09d)),
                  hintText: '/requests or /session accept <id>',
                  hintStyle: const TextStyle(color: Color(0xff6f8273)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: running ? () => onSendCommand() : null,
              icon: const Icon(Icons.send, size: 18),
              label: const Text('Send'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            QuickCommand(
              label: '/help',
              running: running,
              onPressed: () => onSendCommand('/help'),
            ),
            QuickCommand(
              label: '/sessions',
              running: running,
              onPressed: () => onSendCommand('/sessions'),
            ),
            QuickCommand(
              label: '/requests',
              running: running,
              onPressed: () => onSendCommand('/requests'),
            ),
          ],
        ),
      ],
    );
  }
}

class QuickCommand extends StatelessWidget {
  const QuickCommand({
    super.key,
    required this.label,
    required this.running,
    required this.onPressed,
  });

  final String label;
  final bool running;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: running ? onPressed : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xffd9e5d8),
        disabledForegroundColor: const Color(0xff657469),
        side: const BorderSide(color: Color(0xff44564a)),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, required this.running});

  final String text;
  final bool running;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: running ? const Color(0xffdff1df) : const Color(0xffffe7d6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          text,
          style: TextStyle(
            color: running ? const Color(0xff22502e) : const Color(0xff7a3d0b),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

extension on Map<String, dynamic> {
  String? stringValue(String key) {
    final value = this[key];
    return value is String ? value : null;
  }
}

String settingsStringValue(
  Map<String, dynamic> settings,
  String key,
  String currentValue,
) {
  return settings.stringValue(key) ?? currentValue;
}

bool settingsBoolValue(
  Map<String, dynamic> settings,
  String key,
  bool currentValue,
) {
  if (!settings.containsKey(key)) return currentValue;
  return settings[key] == true;
}

String defaultAgentBinary() {
  final fromEnv = Platform.environment['CONDUCTOR_CLIENT_AGENT_BIN'];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) return fromEnv.trim();

  final executableName = Platform.isWindows
      ? 'conductor-agent.exe'
      : 'conductor-agent';
  final executableDir = File(Platform.resolvedExecutable).parent.path;
  final currentDir = Directory.current.path;
  final parentDir = Directory.current.parent.path;

  final candidates = [
    pathJoin(executableDir, executableName),
    pathJoin(currentDir, executableName),
    pathJoin(parentDir, 'target', 'debug', executableName),
    pathJoin(parentDir, 'target', 'release', executableName),
    pathJoin(currentDir, 'target', 'debug', executableName),
    pathJoin(currentDir, 'target', 'release', executableName),
  ];

  return candidates.firstWhere(
    (candidate) => File(candidate).existsSync(),
    orElse: () => candidates.first,
  );
}

String normalizeAgentServerUrl(String value) {
  var text = value.trim();
  if (text.isEmpty) return text;
  if (!text.contains('://')) text = 'ws://$text';
  if (text.startsWith('http://')) text = text.replaceFirst('http://', 'ws://');
  if (text.startsWith('https://')) {
    text = text.replaceFirst('https://', 'wss://');
  }

  final uri = Uri.parse(text);
  if (uri.scheme != 'ws' && uri.scheme != 'wss') {
    throw FormatException('Server URL must use ws, wss, http, or https', value);
  }
  if (uri.host.isEmpty) {
    throw FormatException('Server URL host is required', value);
  }
  if (uri.path.isEmpty || uri.path == '/') {
    return uri.replace(path: '/ws/agent').toString();
  }
  return uri.toString();
}

String? tryNormalizeAgentServerUrl(String value) {
  try {
    return normalizeAgentServerUrl(value);
  } on FormatException {
    return null;
  }
}

String? normalizedSettingsServerUrl(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  return tryNormalizeAgentServerUrl(text);
}

File settingsFile([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final overridePath = env['CONDUCTOR_CLIENT_SETTINGS_FILE'];
  if (overridePath != null && overridePath.trim().isNotEmpty) {
    return File(overridePath.trim());
  }

  final home = env[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  final base = home == null || home.isEmpty ? Directory.current.path : home;
  return File(pathJoin(base, '.conductor-client', 'settings.json'));
}

bool envFlag(String key) {
  return flagValue(Platform.environment[key]);
}

bool flagValue(String? value) {
  final text = value?.trim().toLowerCase();
  return text == '1' || text == 'true' || text == 'yes' || text == 'on';
}

List<String> startupCommandsFromEnv(Map<String, String> environment) {
  final value = environment['CONDUCTOR_CLIENT_AUTOCOMMANDS'];
  if (value == null || value.trim().isEmpty) return const [];
  return value
      .split(RegExp(r'[\r\n;]+'))
      .map((command) => command.trim())
      .where((command) => command.isNotEmpty)
      .toList(growable: false);
}

String? remoteActiveSessionFromLog(String line) {
  const marker = '[session] remote control active:';
  final index = line.indexOf(marker);
  if (index < 0) return null;
  final sessionId = line.substring(index + marker.length).trim();
  return sessionId.isEmpty ? null : sessionId;
}

String? remoteEndedSessionFromLog(String line) {
  const marker = '[session] remote control ended:';
  final index = line.indexOf(marker);
  if (index < 0) return null;
  final sessionId = line.substring(index + marker.length).trim();
  return sessionId.isEmpty ? null : sessionId;
}

String? displayCodeFromLog(String line) {
  final match = RegExp(r'(?:display_code|code)=([0-9]{6})').firstMatch(line);
  return match?.group(1);
}

String pathJoin(String first, String second, [String? third, String? fourth]) {
  final separator = Platform.pathSeparator;
  final parts = [
    first,
    second,
    third,
    fourth,
  ].whereType<String>().where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  var result = parts.first;
  for (final part in parts.skip(1)) {
    final left = result.endsWith('/') || result.endsWith(r'\')
        ? result.substring(0, result.length - 1)
        : result;
    final right = part.startsWith('/') || part.startsWith(r'\')
        ? part.substring(1)
        : part;
    result = '$left$separator$right';
  }
  return result;
}

void unawaited(Future<void> future) {}
