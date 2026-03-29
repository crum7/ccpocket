import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../l10n/app_localizations.dart';
import '../../models/messages.dart';
import '../../services/bridge_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/markdown_style.dart';

/// Resolves a potentially partial file path against the project's file list,
/// then shows the file peek sheet.
///
/// If the path matches exactly or resolves to a single candidate, opens
/// directly. If multiple candidates match, shows a picker first.
Future<void> openFilePeek(
  BuildContext context, {
  required BridgeService bridge,
  required String projectPath,
  required String filePath,
  required List<String> projectFiles,
}) async {
  final resolved = _resolveFilePath(filePath, projectFiles);

  switch (resolved.length) {
    case 1:
      // Single match — open directly.
      return showFilePeekSheet(
        context,
        bridge: bridge,
        projectPath: projectPath,
        filePath: resolved.first,
      );
    case 0:
      // No match — try the original path as-is (Bridge may still find it).
      return showFilePeekSheet(
        context,
        bridge: bridge,
        projectPath: projectPath,
        filePath: filePath,
      );
    default:
      // Multiple matches — let the user pick.
      final picked = await _showFilePickerSheet(context, filePath, resolved);
      if (picked != null && context.mounted) {
        return showFilePeekSheet(
          context,
          bridge: bridge,
          projectPath: projectPath,
          filePath: picked,
        );
      }
  }
}

/// Returns project file paths whose suffix matches [filePath].
List<String> _resolveFilePath(String filePath, List<String> projectFiles) {
  // Exact match first.
  if (projectFiles.contains(filePath)) return [filePath];

  // Suffix match: e.g. "lib/main.dart" matches "apps/mobile/lib/main.dart".
  final suffix = filePath.startsWith('/') ? filePath : '/$filePath';
  final candidates =
      projectFiles.where((f) => '/$f'.endsWith(suffix)).toList();

  return candidates;
}

/// Bottom sheet that lists candidate file paths for the user to pick from.
Future<String?> _showFilePickerSheet(
  BuildContext context,
  String originalPath,
  List<String> candidates,
) {
  final appColors = Theme.of(context).extension<AppColors>()!;

  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: appColors.subtleText.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Icon(Icons.help_outline, size: 18, color: appColors.subtleText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$originalPath — ${candidates.length} files found',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: appColors.subtleText,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (context, index) {
                final path = candidates[index];
                final fileName = path.split('/').last;
                final dir = path.contains('/')
                    ? path.substring(0, path.lastIndexOf('/'))
                    : '';
                return ListTile(
                  leading: Icon(
                    Icons.description_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(
                    fileName,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: dir.isNotEmpty
                      ? Text(
                          dir,
                          style: TextStyle(
                            fontSize: 12,
                            color: appColors.subtleText,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  dense: true,
                  onTap: () => Navigator.of(context).pop(path),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// Shows a bottom sheet that loads and displays file content from Bridge.
///
/// [projectPath] is the project root on the server.
/// [filePath] is the relative path within the project (e.g. "lib/main.dart").
Future<void> showFilePeekSheet(
  BuildContext context, {
  required BridgeService bridge,
  required String projectPath,
  required String filePath,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _FilePeekContent(
        bridge: bridge,
        projectPath: projectPath,
        filePath: filePath,
        scrollController: scrollController,
      ),
    ),
  );
}

class _FilePeekContent extends StatefulWidget {
  final BridgeService bridge;
  final String projectPath;
  final String filePath;
  final ScrollController scrollController;

  const _FilePeekContent({
    required this.bridge,
    required this.projectPath,
    required this.filePath,
    required this.scrollController,
  });

  @override
  State<_FilePeekContent> createState() => _FilePeekContentState();
}

class _FilePeekContentState extends State<_FilePeekContent> {
  FileContentMessage? _result;
  bool _loading = true;
  StreamSubscription<FileContentMessage>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.bridge.fileContent.listen((msg) {
      if (msg.filePath == widget.filePath) {
        setState(() {
          _result = msg;
          _loading = false;
        });
      }
    });
    widget.bridge.send(
      ClientMessage.readFile(widget.projectPath, widget.filePath),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _copyPath() {
    Clipboard.setData(ClipboardData(text: widget.filePath));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).copied),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    final fileName =
        widget.filePath.split('/').lastOrNull ?? widget.filePath;
    final isMarkdown = widget.filePath.endsWith('.md');

    return Column(
      children: [
        // Drag handle
        Container(
          margin: const EdgeInsets.only(top: 8),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: appColors.subtleText.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 18,
                color: appColors.subtleText,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.filePath != fileName)
                      Text(
                        widget.filePath,
                        style: TextStyle(
                          fontSize: 11,
                          color: appColors.subtleText,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                onPressed: _copyPath,
                tooltip: 'Copy path',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.of(context).pop(),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        if (_result != null && _result!.totalLines != null)
          Padding(
            padding: const EdgeInsets.only(left: 42, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_result!.totalLines} lines${_result!.truncated ? ' (truncated)' : ''}${_result!.language != null ? ' \u00b7 ${_result!.language}' : ''}',
                style: TextStyle(
                  fontSize: 11,
                  color: appColors.subtleText,
                ),
              ),
            ),
          ),
        const Divider(height: 1),
        // Content
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator.adaptive())
              : _result?.error != null
                  ? _buildError(appColors)
                  : isMarkdown
                      ? _buildMarkdownPreview()
                      : _buildCodeContent(appColors),
        ),
      ],
    );
  }

  Widget _buildError(AppColors appColors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: appColors.subtleText),
            const SizedBox(height: 12),
            Text(
              _result!.error!,
              style: TextStyle(color: appColors.subtleText),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMarkdownPreview() {
    return Markdown(
      controller: widget.scrollController,
      data: _result!.content,
      selectable: true,
      styleSheet: buildMarkdownStyle(context),
      onTapLink: handleMarkdownLink,
      inlineSyntaxes: colorCodeInlineSyntaxes,
      builders: markdownBuilders,
      padding: const EdgeInsets.all(16),
    );
  }

  Widget _buildCodeContent(AppColors appColors) {
    final content = _result!.content;
    final language = _result!.language;

    final baseStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.5,
      color: Theme.of(context).colorScheme.onSurface,
    );

    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText.rich(
          TextSpan(
            style: baseStyle,
            children: _buildHighlightedContent(
              context: context,
              source: content,
              baseStyle: baseStyle,
              language: language,
            ),
          ),
        ),
      ),
    );
  }

  /// Reuses the existing syntax highlighting from markdown_style.dart's
  /// approach, but directly as TextSpan children.
  List<TextSpan> _buildHighlightedContent({
    required BuildContext context,
    required String source,
    required TextStyle baseStyle,
    required String? language,
  }) {
    // Add line numbers
    final lines = source.split('\n');
    final gutterWidth = '${lines.length}'.length;

    final spans = <TextSpan>[];
    final appColors = Theme.of(context).extension<AppColors>()!;

    for (var i = 0; i < lines.length; i++) {
      final lineNum = '${i + 1}'.padLeft(gutterWidth);
      spans.add(TextSpan(
        text: '$lineNum  ',
        style: baseStyle.copyWith(
          color: appColors.subtleText.withValues(alpha: 0.5),
        ),
      ));
      spans.add(TextSpan(text: '${lines[i]}\n'));
    }

    return spans;
  }
}
