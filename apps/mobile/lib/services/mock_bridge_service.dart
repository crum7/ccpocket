import 'dart:async';
import 'dart:convert';

import '../mock/mock_scenarios.dart';
import '../models/messages.dart';
import 'bridge_service.dart';

class MockBridgeService extends BridgeService {
  final _mockMessageController = StreamController<ServerMessage>.broadcast();
  final List<Timer> _timers = [];

  @override
  Stream<ServerMessage> get messages => _mockMessageController.stream;

  @override
  String? get httpBaseUrl => null;

  @override
  bool get isConnected => true;

  @override
  Stream<BridgeConnectionState> get connectionStatus =>
      Stream.value(BridgeConnectionState.connected);

  @override
  void send(ClientMessage message) {
    final json = jsonDecode(message.toJson()) as Map<String, dynamic>;
    final type = json['type'] as String;

    switch (type) {
      case 'approve':
        // Simulate tool execution result after approval
        _scheduleMessage(
          const Duration(milliseconds: 300),
          const StatusMessage(status: ProcessStatus.running),
        );
        _scheduleMessage(
          const Duration(milliseconds: 800),
          ToolResultMessage(
            toolUseId: json['id'] as String? ?? '',
            content: 'Tool executed successfully (mock)',
          ),
        );
        _scheduleMessage(
          const Duration(milliseconds: 1200),
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'mock-post-approve',
              role: 'assistant',
              content: [
                const TextContent(
                  text: 'The tool has been executed successfully.',
                ),
              ],
              model: 'mock',
            ),
          ),
        );
        _scheduleMessage(
          const Duration(milliseconds: 1500),
          const StatusMessage(status: ProcessStatus.idle),
        );
      case 'reject':
        _scheduleMessage(
          const Duration(milliseconds: 300),
          const StatusMessage(status: ProcessStatus.idle),
        );
        _scheduleMessage(
          const Duration(milliseconds: 500),
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'mock-post-reject',
              role: 'assistant',
              content: [
                const TextContent(
                  text: 'Understood. I will not execute that tool.',
                ),
              ],
              model: 'mock',
            ),
          ),
        );
      case 'answer':
        final result = json['result'] as String? ?? '';
        _scheduleMessage(
          const Duration(milliseconds: 500),
          AssistantServerMessage(
            message: AssistantMessage(
              id: 'mock-post-answer',
              role: 'assistant',
              content: [
                TextContent(
                  text:
                      'Thank you for your answer: "$result". '
                      'I will proceed accordingly.',
                ),
              ],
              model: 'mock',
            ),
          ),
        );
      case 'input':
        final text = json['text'] as String? ?? '';
        _scheduleMessage(
          const Duration(milliseconds: 300),
          const StatusMessage(status: ProcessStatus.running),
        );
        _playStreamingScenario(
          'You said: "$text". This is a mock response echoing your input.',
          startDelay: const Duration(milliseconds: 500),
        );
      case 'read_file':
        final filePath = json['filePath'] as String? ?? '';
        _scheduleMessage(
          const Duration(milliseconds: 400),
          FileContentMessage(
            filePath: filePath,
            content: _mockFileContent(filePath),
            language: _mockFileLanguage(filePath),
            totalLines: _mockFileContent(filePath).split('\n').length,
          ),
        );
      case 'list_dir':
        final dirPath = json['dirPath'] as String? ?? '';
        _scheduleMessage(
          const Duration(milliseconds: 300),
          DirListingMessage(
            dirPath: dirPath,
            entries: const [
              DirEntry(name: 'lib', isDirectory: true),
              DirEntry(name: 'test', isDirectory: true),
              DirEntry(name: 'docs', isDirectory: true),
              DirEntry(name: 'main.dart', isDirectory: false, size: 1024),
              DirEntry(name: 'pubspec.yaml', isDirectory: false, size: 512),
              DirEntry(name: 'README.md', isDirectory: false, size: 2048),
            ],
          ),
        );
      default:
        break;
    }
  }

  @override
  Stream<List<String>> get fileList => const Stream.empty();

  @override
  Stream<List<SessionInfo>> get sessionList => const Stream.empty();

  @override
  void requestFileList(String projectPath) {
    // No-op for mock
  }

  @override
  void interrupt(String sessionId) {
    // Simulate interrupt: stop running and go idle
    _scheduleMessage(
      const Duration(milliseconds: 200),
      const StatusMessage(status: ProcessStatus.idle),
    );
  }

  @override
  void requestSessionList() {
    // No-op for mock
  }

  @override
  void requestSessionHistory(String sessionId) {
    // No-op for mock — history is empty
  }

  @override
  Stream<ServerMessage> messagesForSession(String sessionId) => messages;

  @override
  void stopSession(String sessionId) {
    _scheduleMessage(
      const Duration(milliseconds: 200),
      const ResultMessage(subtype: 'stopped'),
    );
    _scheduleMessage(
      const Duration(milliseconds: 300),
      const StatusMessage(status: ProcessStatus.idle),
    );
  }

  /// Load a list of messages as history (instant, no animation delay).
  void loadHistory(List<ServerMessage> messages) {
    _mockMessageController.add(HistoryMessage(messages: messages));
  }

  /// Play a scenario: emit each step's message after its delay.
  void playScenario(MockScenario scenario) {
    if (scenario.streamingText != null) {
      // Find the delay of the last step to start streaming after it
      final lastStepDelay = scenario.steps.isNotEmpty
          ? scenario.steps.last.delay
          : Duration.zero;
      for (final step in scenario.steps) {
        _scheduleMessage(step.delay, step.message);
      }
      _playStreamingScenario(
        scenario.streamingText!,
        startDelay: lastStepDelay + const Duration(milliseconds: 300),
      );
    } else {
      for (final step in scenario.steps) {
        _scheduleMessage(step.delay, step.message);
      }
    }
  }

  void _playStreamingScenario(
    String text, {
    Duration startDelay = Duration.zero,
  }) {
    const charDelay = Duration(milliseconds: 20);
    for (var i = 0; i < text.length; i++) {
      _scheduleMessage(
        startDelay + charDelay * i,
        StreamDeltaMessage(text: text[i]),
      );
    }
    // Final assistant message after streaming completes
    _scheduleMessage(
      startDelay + charDelay * text.length + const Duration(milliseconds: 100),
      AssistantServerMessage(
        message: AssistantMessage(
          id: 'mock-stream-final',
          role: 'assistant',
          content: [TextContent(text: text)],
          model: 'mock',
        ),
      ),
    );
    _scheduleMessage(
      startDelay + charDelay * text.length + const Duration(milliseconds: 200),
      const StatusMessage(status: ProcessStatus.idle),
    );
  }

  void _scheduleMessage(Duration delay, ServerMessage message) {
    final timer = Timer(delay, () {
      if (!_mockMessageController.isClosed) {
        _mockMessageController.add(message);
      }
    });
    _timers.add(timer);
  }

  static String _mockFileContent(String filePath) {
    if (filePath.endsWith('.dart')) {
      return '''import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CC Pocket',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Text('Count: \$_counter'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        child: const Icon(Icons.add),
      ),
    );
  }
}''';
    }
    if (filePath.endsWith('.md')) {
      return '''# CC Pocket

Claude Code / Codex mobile client for iOS and Android.

## Features

- **Real-time streaming** of agent responses
- **Approval flow** for tool execution
- **Diff viewer** with syntax highlighting
- **Multi-session** management
- **Tailscale** remote access support

## Getting Started

1. Install Flutter SDK
2. Run `flutter pub get`
3. Run `flutter run`

### Architecture

```
Flutter App <-- WebSocket --> Bridge Server <-- SDK --> Claude Code CLI
```

> Note: Bridge Server must be running on the same machine as Claude Code.

## License

MIT
''';
    }
    if (filePath.endsWith('.yaml') || filePath.endsWith('.yml')) {
      return '''name: ccpocket
description: Claude Code mobile client
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.5.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  web_socket_channel: ^3.0.0
  flutter_bloc: ^9.1.0
  shared_preferences: ^2.3.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
''';
    }
    if (filePath.endsWith('.json')) {
      return '''{
  "name": "ccpocket-bridge",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "bridge": "tsx packages/bridge/src/index.ts",
    "bridge:build": "tsc -p packages/bridge/tsconfig.json"
  },
  "devDependencies": {
    "typescript": "^5.6.0",
    "tsx": "^4.19.0"
  }
}
''';
    }
    if (filePath.endsWith('.ts') || filePath.endsWith('.tsx')) {
      return '''import { WebSocketServer, WebSocket } from "ws";

const PORT = process.env.BRIDGE_PORT ?? 8765;

const wss = new WebSocketServer({ port: Number(PORT) });

wss.on("connection", (ws: WebSocket) => {
  console.log("Client connected");

  ws.on("message", (data: Buffer) => {
    const msg = JSON.parse(data.toString());
    handleMessage(ws, msg);
  });

  ws.on("close", () => {
    console.log("Client disconnected");
  });
});

function handleMessage(ws: WebSocket, msg: Record<string, unknown>) {
  switch (msg.type) {
    case "start":
      ws.send(JSON.stringify({ type: "system", subtype: "init" }));
      break;
    default:
      console.warn("Unknown message type:", msg.type);
  }
}

console.log("Bridge server running on port " + PORT);
''';
    }
    // Default: plain text
    return 'File content for: $filePath\n\nThis is a mock file preview.';
  }

  static String? _mockFileLanguage(String filePath) {
    final ext = filePath.split('.').lastOrNull?.toLowerCase();
    return switch (ext) {
      'dart' => 'dart',
      'ts' || 'tsx' => 'typescript',
      'js' || 'jsx' => 'javascript',
      'py' => 'python',
      'yaml' || 'yml' => 'yaml',
      'json' => 'json',
      'md' => 'markdown',
      'html' => 'html',
      'css' => 'css',
      _ => null,
    };
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _mockMessageController.close();
    super.dispose();
  }
}
