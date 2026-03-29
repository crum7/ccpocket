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
  Stream<FileContentMessage> get fileContent => _mockMessageController.stream
      .where((m) => m is FileContentMessage)
      .cast<FileContentMessage>();

  @override
  Stream<DirListingMessage> get dirListing => _mockMessageController.stream
      .where((m) => m is DirListingMessage)
      .cast<DirListingMessage>();

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
    // Path-specific content for File Peek mock scenario
    final knownFiles = _knownMockFiles;
    final match = knownFiles[filePath];
    if (match != null) return match;

    // Fallback: extension-based generic content
    final ext = filePath.split('.').lastOrNull?.toLowerCase();
    return switch (ext) {
      'dart' => _genericDart(filePath),
      'md' => _genericMarkdown(filePath),
      'yaml' || 'yml' => _genericYaml(filePath),
      'json' => _genericJson(filePath),
      'ts' || 'tsx' => _genericTypeScript(filePath),
      _ => 'File content for: $filePath\n\nThis is a mock file preview.',
    };
  }

  // --- Path-specific mock contents (matched by exact path) ---

  static final Map<String, String> _knownMockFiles = {
    'lib/main.dart': '''import 'package:flutter/material.dart';
import 'features/session_list/session_list_screen.dart';

void main() {
  runApp(const MyApp(title: "Hello"));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: title,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const SessionListScreen(),
    );
  }
}''',
    'pubspec.yaml': '''name: ccpocket
description: Claude Code / Codex mobile client
publish_to: 'none'
version: 2.4.0+82

environment:
  sdk: '>=3.5.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  web_socket_channel: ^3.0.1
  flutter_bloc: ^9.1.0
  shared_preferences: ^2.3.0
  flutter_markdown: ^0.7.7
  url_launcher: ^6.3.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0''',
    'packages/bridge/src/index.ts': '''import { startServer } from "./websocket.js";

const PORT = Number(process.env.BRIDGE_PORT ?? 8765);
const HOST = process.env.BRIDGE_HOST ?? "0.0.0.0";
const API_KEY = process.env.BRIDGE_API_KEY;

async function main() {
  console.log(`Starting Bridge Server on \${HOST}:\${PORT}`);
  if (API_KEY) {
    console.log("API key authentication enabled");
  }

  const server = await startServer({ port: PORT, host: HOST, apiKey: API_KEY });

  process.on("SIGINT", () => {
    console.log("Shutting down...");
    server.close();
    process.exit(0);
  });
}

main().catch((err) => {
  console.error("Failed to start:", err);
  process.exit(1);
});''',
    'README.md': '''# CC Pocket

Claude Code / Codex mobile client for iOS and Android.

## Features

- **Real-time streaming** of agent responses
- **Approval flow** for tool execution
- **Diff viewer** with syntax highlighting
- **File Peek** — tap file paths to preview contents
- **Multi-session** management
- **Tailscale** remote access support

## Quick Start

```bash
# 1. Start Bridge Server
npm run bridge

# 2. Run the app
cd apps/mobile && flutter run
```

## Architecture

```
Flutter App <─ WebSocket ─> Bridge Server <─ SDK ─> Claude Code CLI
```

> Bridge Server must be running on the same machine as Claude Code.

## License

MIT''',
    'package.json': '''{
  "name": "ccpocket",
  "version": "2.4.0",
  "private": true,
  "type": "module",
  "workspaces": ["packages/*"],
  "scripts": {
    "bridge": "tsx packages/bridge/src/index.ts",
    "bridge:build": "tsc -p packages/bridge/tsconfig.json",
    "dev": "bash scripts/dev-restart.sh"
  },
  "devDependencies": {
    "typescript": "^5.7.0",
    "tsx": "^4.19.0",
    "@anthropic-ai/sdk": "^0.39.0"
  }
}''',
    'docs/architecture.md': '''# Architecture

## Overview

CC Pocket uses a **Bridge Server** pattern to connect the mobile app
to Claude Code / Codex CLIs running on a desktop machine.

## Components

### Bridge Server (`packages/bridge/`)

TypeScript WebSocket server that:
- Manages multiple concurrent sessions
- Spawns Claude Code / Codex CLI processes via SDK
- Streams responses back to the mobile client
- Handles file operations (read, diff)

### Mobile App (`apps/mobile/`)

Flutter app that:
- Connects to Bridge Server via WebSocket
- Renders streaming assistant messages as Markdown
- Provides approval/rejection flow for tool execution
- Displays git diffs with syntax highlighting

## Data Flow

```
User Input ─> WebSocket ─> Bridge Server ─> Claude SDK ─> Claude Code CLI
                                                              │
User <── Rendered UI <── Stream Parser <── WebSocket <────────┘
```

## Security

- Optional API key authentication
- Path allowlist (`BRIDGE_ALLOWED_DIRS`)
- Read-only file access from mobile client''',
    'test/widget_test.dart': '''import 'package:flutter_test/flutter_test.dart';
import 'package:ccpocket/main.dart';

void main() {
  group('MyApp', () {
    testWidgets('renders with title', (tester) async {
      await tester.pumpWidget(const MyApp(title: 'Test'));
      expect(find.text('Test'), findsOneWidget);
    });

    testWidgets('navigates to session list', (tester) async {
      await tester.pumpWidget(const MyApp(title: 'CC Pocket'));
      expect(find.byType(SessionListScreen), findsOneWidget);
    });
  });
}''',
  };

  // --- Extension-based fallback content ---

  static String _genericDart(String filePath) {
    final name = filePath.split('/').last.replaceAll('.dart', '');
    return "// $filePath\n\nclass ${_toPascalCase(name)} {\n  // TODO: implementation\n}";
  }

  static String _genericMarkdown(String filePath) {
    final name = filePath.split('/').last;
    return '# $name\n\nDocumentation for `$filePath`.';
  }

  static String _genericYaml(String filePath) =>
      '# $filePath\n# Configuration file';

  static String _genericJson(String filePath) =>
      '{\n  "_comment": "$filePath"\n}';

  static String _genericTypeScript(String filePath) =>
      '// $filePath\n\nexport {};';

  static String _toPascalCase(String input) => input
      .split(RegExp(r'[_\-]'))
      .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
      .join();

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
