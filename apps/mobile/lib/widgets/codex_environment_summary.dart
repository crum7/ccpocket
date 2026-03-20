import 'package:flutter/material.dart';

import '../models/messages.dart';
import '../theme/app_theme.dart';

class CodexEnvironmentSummary extends StatelessWidget {
  final String? model;
  final String? reasoningEffort;
  final String? approvalPolicy;
  final String? permissionMode;
  final String? sandboxMode;
  final bool compact;
  final String? leadingLabel;

  const CodexEnvironmentSummary({
    super.key,
    this.model,
    this.reasoningEffort,
    this.approvalPolicy,
    this.permissionMode,
    this.sandboxMode,
    this.compact = false,
    this.leadingLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = theme.extension<AppColors>()!;
    final textStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: compact ? 11 : 12,
      color: appColors.subtleText,
      height: 1.2,
    );

    final children = <Widget>[
      if (leadingLabel != null) Text(leadingLabel!, style: textStyle),
      if (_displayModel(model) case final modelText?)
        Text(modelText, style: textStyle, overflow: TextOverflow.ellipsis),
      if (_displayReasoning(reasoningEffort) case final reasoningText?)
        Text(reasoningText, style: textStyle, overflow: TextOverflow.ellipsis),
      _EnvironmentIcon(
        icon: _permissionIcon(permissionMode, approvalPolicy),
        tooltip: _permissionLabel(permissionMode, approvalPolicy),
        compact: compact,
      ),
      _EnvironmentIcon(
        icon: _sandboxIcon(sandboxMode),
        tooltip: _sandboxLabel(sandboxMode),
        compact: compact,
      ),
    ];

    return Wrap(
      spacing: compact ? 6 : 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

class _EnvironmentIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool compact;

  const _EnvironmentIcon({
    required this.icon,
    required this.tooltip,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final appColors = theme.extension<AppColors>()!;

    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        child: Container(
          padding: EdgeInsets.all(compact ? 3 : 4),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: Icon(
            icon,
            size: compact ? 12 : 14,
            color: appColors.subtleText,
          ),
        ),
      ),
    );
  }
}

String? _displayModel(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return raw;
}

String? _displayReasoning(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  ReasoningEffort? effort;
  for (final value in ReasoningEffort.values) {
    if (value.value == raw) {
      effort = value;
      break;
    }
  }
  return effort == null ? raw : 'Reasoning ${effort.label}';
}

IconData _permissionIcon(String? permissionMode, String? approvalPolicy) {
  final effective =
      permissionMode ?? _permissionModeFromApprovalPolicy(approvalPolicy);
  return switch (effective) {
    'plan' => Icons.assignment_outlined,
    'bypassPermissions' => Icons.flash_on,
    'acceptEdits' => Icons.edit_note,
    'default' || null => Icons.tune,
    _ => Icons.tune,
  };
}

String _permissionLabel(String? permissionMode, String? approvalPolicy) {
  final effective =
      permissionMode ?? _permissionModeFromApprovalPolicy(approvalPolicy);
  return switch (effective) {
    'plan' => PermissionMode.plan.label,
    'bypassPermissions' => PermissionMode.bypassPermissions.label,
    'acceptEdits' => PermissionMode.acceptEdits.label,
    'default' => PermissionMode.defaultMode.label,
    null => approvalPolicy ?? PermissionMode.defaultMode.label,
    final other => other,
  };
}

String? _permissionModeFromApprovalPolicy(String? approvalPolicy) {
  return switch (approvalPolicy) {
    'never' => PermissionMode.bypassPermissions.value,
    'on-request' || 'unless-allow-listed' => PermissionMode.acceptEdits.value,
    null || '' => null,
    _ => null,
  };
}

IconData _sandboxIcon(String? sandboxMode) {
  return switch (sandboxMode) {
    'off' || 'danger-full-access' => Icons.warning_amber,
    _ => Icons.shield_outlined,
  };
}

String _sandboxLabel(String? sandboxMode) {
  return switch (sandboxMode) {
    'off' || 'danger-full-access' => SandboxMode.off.label,
    'on' ||
    'workspace-write' ||
    'read-only' ||
    null ||
    '' => SandboxMode.on.label,
    final other => other,
  };
}
