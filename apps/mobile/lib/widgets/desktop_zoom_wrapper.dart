import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../features/settings/state/settings_cubit.dart';
import '../features/settings/state/settings_state.dart';

/// Wraps the app with Cmd+Plus / Cmd+Minus / Cmd+0 zoom shortcuts on macOS.
///
/// On non-macOS platforms this widget is a no-op pass-through.
class DesktopZoomWrapper extends StatelessWidget {
  const DesktopZoomWrapper({required this.child, super.key});

  final Widget child;

  static const _step = 0.1;
  static const _min = 0.8;
  static const _max = 2.0;

  @override
  Widget build(BuildContext context) {
    // Only enable on macOS (not web).
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      return child;
    }

    return BlocBuilder<SettingsCubit, SettingsState>(
      buildWhen: (prev, curr) => prev.uiScale != curr.uiScale,
      builder: (context, settings) {
        return Shortcuts(
          shortcuts: {
            // Cmd + =  (same key as Cmd + + without shift)
            SingleActivator(LogicalKeyboardKey.equal, meta: true):
                const _ZoomInIntent(),
            // Cmd + Shift + = (explicit plus)
            SingleActivator(LogicalKeyboardKey.equal, meta: true, shift: true):
                const _ZoomInIntent(),
            // Cmd + -
            SingleActivator(LogicalKeyboardKey.minus, meta: true):
                const _ZoomOutIntent(),
            // Cmd + 0
            SingleActivator(LogicalKeyboardKey.digit0, meta: true):
                const _ZoomResetIntent(),
          },
          child: Actions(
            actions: {
              _ZoomInIntent: CallbackAction<_ZoomInIntent>(
                onInvoke: (_) {
                  final cubit = context.read<SettingsCubit>();
                  final next = (cubit.state.uiScale + _step).clamp(_min, _max);
                  cubit.setUiScale(next);
                  return null;
                },
              ),
              _ZoomOutIntent: CallbackAction<_ZoomOutIntent>(
                onInvoke: (_) {
                  final cubit = context.read<SettingsCubit>();
                  final next = (cubit.state.uiScale - _step).clamp(_min, _max);
                  cubit.setUiScale(next);
                  return null;
                },
              ),
              _ZoomResetIntent: CallbackAction<_ZoomResetIntent>(
                onInvoke: (_) {
                  context.read<SettingsCubit>().setUiScale(1.0);
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(settings.uiScale)),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ZoomInIntent extends Intent {
  const _ZoomInIntent();
}

class _ZoomOutIntent extends Intent {
  const _ZoomOutIntent();
}

class _ZoomResetIntent extends Intent {
  const _ZoomResetIntent();
}
