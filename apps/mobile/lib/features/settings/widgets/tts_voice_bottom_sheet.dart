import 'package:flutter/material.dart';

import '../../../services/tts_service.dart';

/// Shows a bottom sheet that lets the user pick a TTS voice.
///
/// Voices are fetched from the platform TTS engine on demand. The current
/// selection is highlighted via [currentVoiceName].
Future<void> showTtsVoiceBottomSheet({
  required BuildContext context,
  required TtsService ttsService,
  required String currentVoiceName,
  required ValueChanged<String> onSelected,
}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _TtsVoiceSheet(
      ttsService: ttsService,
      currentVoiceName: currentVoiceName,
      onSelected: onSelected,
    ),
  );
}

class _TtsVoiceSheet extends StatefulWidget {
  const _TtsVoiceSheet({
    required this.ttsService,
    required this.currentVoiceName,
    required this.onSelected,
  });

  final TtsService ttsService;
  final String currentVoiceName;
  final ValueChanged<String> onSelected;

  @override
  State<_TtsVoiceSheet> createState() => _TtsVoiceSheetState();
}

class _TtsVoiceSheetState extends State<_TtsVoiceSheet> {
  late Future<List<Map<String, String>>> _voicesFuture;

  @override
  void initState() {
    super.initState();
    _voicesFuture = widget.ttsService.getSystemVoices();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: FutureBuilder<List<Map<String, String>>>(
          future: _voicesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final all = snapshot.data ?? const [];
            // Show Japanese voices first, then the rest. Empty list -> hint.
            final japanese = all
                .where(
                  (v) => (v['locale'] ?? '').toLowerCase().startsWith('ja'),
                )
                .toList();
            final others = all
                .where(
                  (v) => !(v['locale'] ?? '').toLowerCase().startsWith('ja'),
                )
                .toList();
            final ordered = [...japanese, ...others];
            if (ordered.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Text('No TTS voices available on this device.'),
              );
            }
            return ListView(
              shrinkWrap: true,
              children: [
                RadioListTile<String>(
                  title: const Text('System default'),
                  value: '',
                  groupValue: widget.currentVoiceName,
                  onChanged: (v) {
                    widget.onSelected('');
                    Navigator.of(context).pop();
                  },
                ),
                const Divider(height: 1),
                for (final voice in ordered)
                  RadioListTile<String>(
                    title: Text(voice['name'] ?? ''),
                    subtitle: Text(voice['locale'] ?? ''),
                    value: voice['name'] ?? '',
                    groupValue: widget.currentVoiceName,
                    onChanged: (v) {
                      widget.onSelected(v ?? '');
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
