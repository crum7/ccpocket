import 'package:flutter/material.dart';

import '../../../services/tts_service.dart';

/// Bottom sheet that lets the user pick a VOICEVOX speaker (style).
///
/// Speakers are fetched from the running VOICEVOX engine at [voicevoxUrl] on
/// demand. If the engine is unreachable, the sheet shows a hint to start
/// VOICEVOX.
Future<void> showVoicevoxSpeakerBottomSheet({
  required BuildContext context,
  required TtsService ttsService,
  required String voicevoxUrl,
  required int currentSpeakerId,
  required ValueChanged<int> onSelected,
}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _Sheet(
      ttsService: ttsService,
      voicevoxUrl: voicevoxUrl,
      currentSpeakerId: currentSpeakerId,
      onSelected: onSelected,
    ),
  );
}

class _Sheet extends StatefulWidget {
  const _Sheet({
    required this.ttsService,
    required this.voicevoxUrl,
    required this.currentSpeakerId,
    required this.onSelected,
  });

  final TtsService ttsService;
  final String voicevoxUrl;
  final int currentSpeakerId;
  final ValueChanged<int> onSelected;

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  late Future<List<VoicevoxSpeaker>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.ttsService.getVoicevoxSpeakers(url: widget.voicevoxUrl);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: FutureBuilder<List<VoicevoxSpeaker>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final speakers = snapshot.data ?? const [];
            if (speakers.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'VOICEVOXエンジンに接続できません',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.voicevoxUrl,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'VOICEVOXアプリを起動してから再度お試しください。',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }
            return ListView.builder(
              shrinkWrap: true,
              itemCount: speakers.length,
              itemBuilder: (context, i) {
                final s = speakers[i];
                return RadioListTile<int>(
                  title: Text(s.displayName),
                  subtitle: Text('id: ${s.id}'),
                  value: s.id,
                  groupValue: widget.currentSpeakerId,
                  onChanged: (v) {
                    if (v != null) widget.onSelected(v);
                    Navigator.of(context).pop();
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}
