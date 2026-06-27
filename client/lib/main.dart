import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

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
  final _serverUrl = TextEditingController(
    text: 'ws://127.0.0.1:8080/ws/agent',
  );
  final _agentToken = TextEditingController(text: 'dev-agent-token-change-me');
  final _agentName = TextEditingController();
  final _agentRoot = TextEditingController();
  final _agentBin = TextEditingController();
  final _audioInput = TextEditingController();
  final _agentCommand = TextEditingController();
  final _logs = <String>[];
  final _scrollController = ScrollController();

  Process? _process;
  int? _lastExitCode;
  bool _interactiveApproval = false;
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
        _serverUrl.text = value.stringValue('serverUrl') ?? _serverUrl.text;
        _agentToken.text = value.stringValue('agentToken') ?? _agentToken.text;
        _agentName.text = value.stringValue('agentName') ?? '';
        _agentRoot.text = value.stringValue('agentRoot') ?? '';
        _agentBin.text = value.stringValue('agentBin') ?? _agentBin.text;
        _audioInput.text = value.stringValue('audioInput') ?? '';
        _interactiveApproval = value['interactiveApproval'] == true;
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
    if (_agentToken.text.isEmpty) {
      _appendLog('agent token is empty');
      return;
    }

    setState(() {
      _starting = true;
      _lastExitCode = null;
    });

    final serverUrl = normalizeAgentServerUrl(_serverUrl.text);
    _serverUrl.text = serverUrl;
    await _saveSettings();

    final env = Map<String, String>.from(Platform.environment)
      ..['CONDUCTOR_SERVER_URL'] = serverUrl
      ..['CONDUCTOR_AGENT_TOKEN'] = _agentToken.text
      ..['CONDUCTOR_INTERACTIVE_APPROVAL'] = _interactiveApproval ? '1' : '0';

    final name = _agentName.text.trim();
    final root = _agentRoot.text.trim();
    final audioInput = _audioInput.text.trim();
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
      unawaited(
        process.exitCode.then((code) {
          if (!mounted) return;
          setState(() {
            _lastExitCode = code;
            _process = null;
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

  void _stopAgent() {
    final process = _process;
    if (process == null) return;
    _appendLog('stopping agent pid=${process.pid}');
    process.kill();
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
    if (!mounted) return;
    setState(() {
      final timestamp = DateTime.now().toIso8601String().substring(11, 19);
      _logs.add('[$timestamp] $line');
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
            final form = LauncherForm(
              serverUrl: _serverUrl,
              agentToken: _agentToken,
              agentName: _agentName,
              agentRoot: _agentRoot,
              agentBin: _agentBin,
              audioInput: _audioInput,
              interactiveApproval: _interactiveApproval,
              running: _running || _starting,
              onInteractiveApprovalChanged: (value) {
                setState(() => _interactiveApproval = value);
              },
              onSave: () async {
                await _saveSettings();
                _appendLog('settings saved');
              },
              onStart: _startAgent,
              onStop: _stopAgent,
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
                        SizedBox(width: 440, child: form),
                        const SizedBox(width: 16),
                        Expanded(child: logs),
                      ],
                    )
                  : ListView(
                      children: [
                        form,
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
}

class LauncherForm extends StatelessWidget {
  const LauncherForm({
    super.key,
    required this.serverUrl,
    required this.agentToken,
    required this.agentName,
    required this.agentRoot,
    required this.agentBin,
    required this.audioInput,
    required this.interactiveApproval,
    required this.running,
    required this.onInteractiveApprovalChanged,
    required this.onSave,
    required this.onStart,
    required this.onStop,
  });

  final TextEditingController serverUrl;
  final TextEditingController agentToken;
  final TextEditingController agentName;
  final TextEditingController agentRoot;
  final TextEditingController agentBin;
  final TextEditingController audioInput;
  final bool interactiveApproval;
  final bool running;
  final ValueChanged<bool> onInteractiveApprovalChanged;
  final VoidCallback onSave;
  final VoidCallback onStart;
  final VoidCallback onStop;

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
            Text(
              'Agent Configuration',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Field(controller: serverUrl, label: 'Server WebSocket URL'),
            Field(
              controller: agentToken,
              label: 'Agent Token',
              obscureText: true,
            ),
            Field(controller: agentName, label: 'Agent Name', hint: 'optional'),
            Field(
              controller: agentRoot,
              label: 'File Root',
              hint: 'optional, defaults to home',
            ),
            Field(controller: agentBin, label: 'Agent Binary'),
            Field(
              controller: audioInput,
              label: 'Audio Input',
              hint: 'optional',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Require local approval'),
              subtitle: const Text(
                'Remote control and voice requests wait for local CLI approval.',
              ),
              value: interactiveApproval,
              onChanged: running ? null : onInteractiveApprovalChanged,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onSave,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: running ? onStop : onStart,
                    icon: Icon(running ? Icons.stop : Icons.play_arrow),
                    label: Text(running ? 'Stop Agent' : 'Start Agent'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
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
  if (uri.path.isEmpty || uri.path == '/') {
    return uri.replace(path: '/ws/agent').toString();
  }
  return uri.toString();
}

File settingsFile() {
  final home =
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  final base = home == null || home.isEmpty ? Directory.current.path : home;
  return File(pathJoin(base, '.conductor-client', 'settings.json'));
}

bool envFlag(String key) {
  final value = Platform.environment[key]?.trim().toLowerCase();
  return value == '1' || value == 'true' || value == 'yes' || value == 'on';
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
