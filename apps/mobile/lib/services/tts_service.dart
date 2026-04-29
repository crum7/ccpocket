import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;

/// Which TTS engine to use.
enum TtsEngine { system, voicevox }

TtsEngine ttsEngineFromString(String s) {
  switch (s) {
    case 'voicevox':
      return TtsEngine.voicevox;
    case 'system':
    default:
      return TtsEngine.system;
  }
}

String ttsEngineToString(TtsEngine e) {
  switch (e) {
    case TtsEngine.voicevox:
      return 'voicevox';
    case TtsEngine.system:
      return 'system';
  }
}

/// A speaker entry returned by `/speakers` from VOICEVOX.
class VoicevoxSpeaker {
  VoicevoxSpeaker({
    required this.id,
    required this.name,
    required this.styleName,
  });

  /// VOICEVOX style id (used as `speaker` query parameter).
  final int id;
  final String name;
  final String styleName;

  String get displayName => '$name ($styleName)';
}

/// Streaming text-to-speech service.
///
/// Buffers incoming text deltas and emits them to a backend (system TTS or
/// VOICEVOX) sentence-by-sentence so the user starts hearing audio while the
/// LLM is still streaming. Code blocks (delimited by ``` ) and inline code
/// (`...`) are stripped before being read aloud.
class TtsService {
  TtsService();

  // ---------------------------------------------------------------------------
  // Backends
  // ---------------------------------------------------------------------------

  final FlutterTts _systemTts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final http.Client _http = http.Client();

  bool _systemInitialized = false;
  bool _audioListenerWired = false;

  // ---------------------------------------------------------------------------
  // Current settings
  // ---------------------------------------------------------------------------

  bool _enabled = false;
  TtsEngine _engine = TtsEngine.system;
  String _systemVoiceName = '';
  String _systemVoiceLocale = 'ja-JP';
  String _voicevoxUrl = 'http://localhost:50021';
  int _voicevoxSpeaker = 3; // ずんだもん（ノーマル）by default
  double _rate = 1.0;

  // ---------------------------------------------------------------------------
  // Streaming buffer / queue
  // ---------------------------------------------------------------------------

  final StringBuffer _buffer = StringBuffer();
  final Queue<String> _queue = Queue<String>();
  bool _isSpeaking = false;
  bool _inCodeBlock = false;
  bool _inInlineCode = false;

  /// Monotonic counter so we can ignore audio playback completions from a
  /// previous `stop()` cycle.
  int _speakGeneration = 0;

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  Future<void> initialize() async {
    if (_systemInitialized) return;
    _systemInitialized = true;
    try {
      await _systemTts.awaitSpeakCompletion(true);
      _systemTts.setCompletionHandler(() {
        if (_engine == TtsEngine.system) {
          _onSpeakComplete(_speakGeneration);
        }
      });
      _systemTts.setErrorHandler((msg) {
        debugPrint('[TTS] system error: $msg');
        if (_engine == TtsEngine.system) {
          _onSpeakComplete(_speakGeneration);
        }
      });
    } catch (e) {
      debugPrint('[TTS] system init error: $e');
    }
    if (!_audioListenerWired) {
      _audioListenerWired = true;
      _audioPlayer.onPlayerComplete.listen((_) {
        if (_engine == TtsEngine.voicevox) {
          _onSpeakComplete(_speakGeneration);
        }
      });
    }
  }

  /// Returns system TTS voices as `{name, locale}` maps.
  Future<List<Map<String, String>>> getSystemVoices() async {
    await initialize();
    try {
      final voices = await _systemTts.getVoices;
      if (voices is! List) return const [];
      return voices
          .whereType<Map>()
          .map(
            (v) => {
              'name': (v['name'] ?? '').toString(),
              'locale': (v['locale'] ?? '').toString(),
            },
          )
          .where((v) => v['name']!.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[TTS] getSystemVoices error: $e');
      return const [];
    }
  }

  /// Fetch the speaker list from a running VOICEVOX engine.
  Future<List<VoicevoxSpeaker>> getVoicevoxSpeakers({String? url}) async {
    final base = (url ?? _voicevoxUrl).replaceAll(RegExp(r'/+$'), '');
    try {
      final res = await _http
          .get(Uri.parse('$base/speakers'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        debugPrint('[TTS] voicevox /speakers status=${res.statusCode}');
        return const [];
      }
      final data = jsonDecode(res.body);
      if (data is! List) return const [];
      final result = <VoicevoxSpeaker>[];
      for (final speaker in data) {
        if (speaker is! Map) continue;
        final name = (speaker['name'] ?? '').toString();
        final styles = speaker['styles'];
        if (styles is! List) continue;
        for (final style in styles) {
          if (style is! Map) continue;
          final id = style['id'];
          if (id is! int) continue;
          result.add(
            VoicevoxSpeaker(
              id: id,
              name: name,
              styleName: (style['name'] ?? '').toString(),
            ),
          );
        }
      }
      return result;
    } catch (e) {
      debugPrint('[TTS] getVoicevoxSpeakers error: $e');
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // Settings application
  // ---------------------------------------------------------------------------

  Future<void> applySettings({
    required bool enabled,
    required TtsEngine engine,
    required String systemVoiceName,
    required String voicevoxUrl,
    required int voicevoxSpeaker,
    required double rate,
  }) async {
    final wasEnabled = _enabled;
    final prevEngine = _engine;

    _enabled = enabled;
    _engine = engine;
    _voicevoxUrl = voicevoxUrl;
    _voicevoxSpeaker = voicevoxSpeaker;
    _rate = rate.clamp(0.5, 2.0);

    if (!enabled) {
      await stop();
      return;
    }

    await initialize();

    // System voice / rate
    if (engine == TtsEngine.system) {
      if (systemVoiceName != _systemVoiceName ||
          !wasEnabled ||
          prevEngine != TtsEngine.system) {
        _systemVoiceName = systemVoiceName;
        if (systemVoiceName.isNotEmpty) {
          final voices = await getSystemVoices();
          final match = voices.firstWhere(
            (v) => v['name'] == systemVoiceName,
            orElse: () => const {},
          );
          if (match.isNotEmpty) {
            _systemVoiceLocale = match['locale'] ?? _systemVoiceLocale;
            try {
              await _systemTts.setVoice({
                'name': systemVoiceName,
                'locale': _systemVoiceLocale,
              });
              await _systemTts.setLanguage(_systemVoiceLocale);
            } catch (e) {
              debugPrint('[TTS] setVoice error: $e');
            }
          }
        }
      }
      try {
        // flutter_tts speech rate is platform-specific. macOS expects ~0.0–1.0
        // where 0.5 is normal. Map 1.0 -> 0.5, 2.0 -> 1.0, 0.5 -> 0.25.
        await _systemTts.setSpeechRate(_rate * 0.5);
      } catch (e) {
        debugPrint('[TTS] setSpeechRate error: $e');
      }
    }

    // Engine swap → drop pending audio so we don't hear the old engine finish.
    if (prevEngine != engine) {
      await stop();
    }
  }

  // ---------------------------------------------------------------------------
  // Streaming feed
  // ---------------------------------------------------------------------------

  void feedDelta(String delta) {
    if (!_enabled || delta.isEmpty) return;
    _buffer.write(delta);
    _extractSentences();
  }

  void flush() {
    if (!_enabled) return;
    final remaining = _buffer.toString().trim();
    _buffer.clear();
    if (remaining.isNotEmpty) {
      final cleaned = _stripMarkdown(remaining);
      if (cleaned.isNotEmpty) {
        _queue.add(cleaned);
        unawaited(_drainQueue());
      }
    }
    _inCodeBlock = false;
    _inInlineCode = false;
  }

  Future<void> stop() async {
    _buffer.clear();
    _queue.clear();
    _inCodeBlock = false;
    _inInlineCode = false;
    _speakGeneration++;
    if (_isSpeaking) {
      _isSpeaking = false;
      try {
        await _systemTts.stop();
      } catch (_) {}
      try {
        await _audioPlayer.stop();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Sentence extraction / markdown stripping
  // ---------------------------------------------------------------------------

  void _extractSentences() {
    final text = _buffer.toString();
    var lastBoundary = 0;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (_isSentenceTerminator(ch)) {
        final sentence = text.substring(lastBoundary, i + 1);
        final cleaned = _stripMarkdown(sentence);
        if (cleaned.isNotEmpty) {
          _queue.add(cleaned);
        }
        lastBoundary = i + 1;
      }
    }
    if (lastBoundary > 0) {
      final remainder = text.substring(lastBoundary);
      _buffer
        ..clear()
        ..write(remainder);
      unawaited(_drainQueue());
    }
  }

  bool _isSentenceTerminator(String ch) {
    return ch == '。' ||
        ch == '！' ||
        ch == '？' ||
        ch == '.' ||
        ch == '!' ||
        ch == '?' ||
        ch == '\n';
  }

  String _stripMarkdown(String input) {
    final out = StringBuffer();
    var i = 0;
    while (i < input.length) {
      if (i + 2 < input.length &&
          input[i] == '`' &&
          input[i + 1] == '`' &&
          input[i + 2] == '`') {
        _inCodeBlock = !_inCodeBlock;
        i += 3;
        continue;
      }
      if (_inCodeBlock) {
        i++;
        continue;
      }
      if (input[i] == '`') {
        _inInlineCode = !_inInlineCode;
        i++;
        continue;
      }
      if (_inInlineCode) {
        i++;
        continue;
      }
      final ch = input[i];
      if (ch == '*' || ch == '_' || ch == '#' || ch == '>') {
        i++;
        continue;
      }
      out.write(ch);
      i++;
    }
    return out.toString().trim();
  }

  // ---------------------------------------------------------------------------
  // Speech playback queue
  // ---------------------------------------------------------------------------

  Future<void> _drainQueue() async {
    if (_isSpeaking || _queue.isEmpty || !_enabled) return;
    _isSpeaking = true;
    final next = _queue.removeFirst();
    final generation = _speakGeneration;
    try {
      if (_engine == TtsEngine.system) {
        // awaitSpeakCompletion(true) means this returns when the speech ends,
        // so we don't need to wait for the completion handler. But the
        // completion handler also fires; guard via generation check.
        await _systemTts.speak(next);
      } else {
        await _speakVoicevox(next);
      }
    } catch (e) {
      debugPrint('[TTS] speak error: $e');
      _onSpeakComplete(generation);
    }
  }

  Future<void> _speakVoicevox(String text) async {
    final base = _voicevoxUrl.replaceAll(RegExp(r'/+$'), '');
    final speaker = _voicevoxSpeaker;
    // 1) audio_query
    final queryUri = Uri.parse(
      '$base/audio_query?speaker=$speaker&text=${Uri.encodeQueryComponent(text)}',
    );
    final queryRes = await _http
        .post(queryUri)
        .timeout(const Duration(seconds: 15));
    if (queryRes.statusCode != 200) {
      throw Exception('voicevox audio_query failed: ${queryRes.statusCode}');
    }
    final query = jsonDecode(queryRes.body) as Map<String, dynamic>;
    query['speedScale'] = _rate;

    // 2) synthesis
    final synthUri = Uri.parse('$base/synthesis?speaker=$speaker');
    final synthRes = await _http
        .post(
          synthUri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(query),
        )
        .timeout(const Duration(seconds: 30));
    if (synthRes.statusCode != 200) {
      throw Exception('voicevox synthesis failed: ${synthRes.statusCode}');
    }

    // 3) play
    final bytes = Uint8List.fromList(synthRes.bodyBytes);
    await _audioPlayer.play(BytesSource(bytes, mimeType: 'audio/wav'));
    // Completion is reported via the onPlayerComplete listener wired in
    // initialize(); _onSpeakComplete advances the queue.
  }

  void _onSpeakComplete(int generation) {
    // Drop completions from a previous stop() cycle.
    if (generation != _speakGeneration) return;
    _isSpeaking = false;
    unawaited(_drainQueue());
  }

  void dispose() {
    _buffer.clear();
    _queue.clear();
    try {
      _systemTts.stop();
    } catch (_) {}
    try {
      _audioPlayer.dispose();
    } catch (_) {}
    _http.close();
  }
}
