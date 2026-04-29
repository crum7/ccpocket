import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../models/app_icon.dart';
import '../../../models/new_session_tab.dart';
import '../../../models/terminal_app.dart';

part 'settings_state.freezed.dart';

/// Keys for FCM status messages (resolved to localized strings in the UI).
enum FcmStatusKey {
  unavailable,
  bridgeNotInitialized,
  tokenFailed,
  enabled,
  enabledPending,
  disabled,
  disabledPending,
}

/// Application-wide user settings.
@freezed
abstract class SettingsState with _$SettingsState {
  const SettingsState._();

  const factory SettingsState({
    /// Theme mode: system, light, or dark.
    @Default(ThemeMode.system) ThemeMode themeMode,

    /// App display locale ID (e.g. 'ja', 'en').
    /// Empty string means follow the device default.
    @Default('') String appLocaleId,

    /// Locale ID for speech recognition (e.g. 'ja-JP', 'en-US').
    /// Empty string means use device default.
    @Default('ja-JP') String speechLocaleId,

    /// Set of Machine IDs that have push notifications enabled.
    @Default({}) Set<String> fcmEnabledMachines,

    /// Set of Machine IDs that have privacy mode enabled for push notifications.
    @Default({}) Set<String> fcmPrivacyMachines,

    /// Currently connected Machine ID (null when disconnected).
    String? activeMachineId,

    /// Whether Firebase Messaging is available in this runtime.
    @Default(false) bool fcmAvailable,

    /// True while token registration/unregistration is being synchronized.
    @Default(false) bool fcmSyncInProgress,

    /// Last push sync status key (resolved to localized string in UI).
    FcmStatusKey? fcmStatusKey,

    /// Shorebird update track ('stable' or 'staging').
    @Default('stable') String shorebirdTrack,

    /// Indent size for list formatting (1-4 spaces).
    @Default(2) int indentSize,

    /// Whether to hide the voice input button in the chat input bar.
    @Default(false) bool hideVoiceInput,

    /// Selected app icon preference for monthly Supporter perks.
    @Default(AppIconVariant.defaultIcon) AppIconVariant selectedAppIcon,

    /// Whether app icon switching is supported on the current platform.
    @Default(false) bool appIconSupported,

    /// External terminal app configuration (preset or custom URL template).
    @Default(TerminalAppConfig.empty) TerminalAppConfig terminalApp,

    /// Visible tabs (and their order) in the new session sheet.
    @Default(defaultNewSessionTabs) List<NewSessionTab> newSessionTabs,

    /// UI scale factor for macOS (0.8 – 2.0, default 1.0).
    @Default(1.0) double uiScale,

    /// Whether to read assistant replies aloud via TTS.
    @Default(false) bool ttsEnabled,

    /// Selected system TTS voice name. Empty = system default.
    @Default('') String ttsVoiceName,

    /// TTS engine: 'system' (flutter_tts) or 'voicevox'.
    @Default('system') String ttsEngine,

    /// VOICEVOX engine HTTP URL.
    @Default('http://localhost:50021') String ttsVoicevoxUrl,

    /// VOICEVOX speaker (style) id.
    @Default(3) int ttsVoicevoxSpeaker,

    /// Speech rate / playback speed (0.5 – 2.0, 1.0 = normal).
    @Default(1.0) double ttsRate,
  }) = _SettingsState;

  /// Whether push notifications are enabled for the currently connected machine.
  bool get fcmEnabled =>
      activeMachineId != null && fcmEnabledMachines.contains(activeMachineId);

  /// Whether privacy mode is enabled for the currently connected machine.
  bool get fcmPrivacy =>
      activeMachineId != null && fcmPrivacyMachines.contains(activeMachineId);
}
