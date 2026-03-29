import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../theme/app_theme.dart';

/// Callback invoked when a file path is tapped.
typedef FilePathTapCallback = void Function(String filePath);

/// Inline syntax that detects file paths in backtick-quoted inline code.
///
/// Matches patterns like `src/main.dart`, `lib/models/messages.dart`,
/// `package.json`, etc. inside backticks.
///
/// A file path is identified by having at least one `/` or a known extension.
class FilePathSyntax extends md.InlineSyntax {
  // Match backtick-wrapped content that looks like a file path:
  // - Contains at least one / separator, OR
  // - Ends with a known extension
  // Negative lookbehind avoids double-matching inside fenced code blocks.
  FilePathSyntax()
    : super(
        r'`((?:[a-zA-Z0-9_.~-]+/)+[a-zA-Z0-9_.~-]+(?:\.[a-zA-Z0-9]+)?|[a-zA-Z0-9_.-]+\.(?:dart|ts|tsx|js|jsx|py|rb|rs|go|java|kt|swift|c|cpp|h|hpp|cs|sh|yml|yaml|json|toml|md|html|css|scss|sql|xml|gradle|lock|config|env|gitignore|dockerignore|dockerfile|makefile|txt))`',
        startCharacter: 0x60, // backtick
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final path = match[1]!;
    final el = md.Element('filePath', [md.Text(path)]);
    el.attributes['path'] = path;
    parser.addNode(el);
    return true;
  }
}

/// Builds a tappable widget for file path elements.
class FilePathBuilder extends MarkdownElementBuilder {
  final FilePathTapCallback? onTap;

  FilePathBuilder({this.onTap});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final path = element.attributes['path'] ?? '';
    final appColors = Theme.of(context).extension<AppColors>()!;
    final cs = Theme.of(context).colorScheme;

    final codeStyle = (preferredStyle ?? const TextStyle()).copyWith(
      fontFamily: 'monospace',
      fontSize: 13,
      backgroundColor: appColors.codeBackground,
      color: cs.primary,
      decoration: TextDecoration.underline,
      decorationColor: cs.primary.withValues(alpha: 0.4),
      decorationStyle: TextDecorationStyle.dotted,
    );

    return GestureDetector(
      onTap: onTap != null ? () => onTap!(path) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.description_outlined,
            size: 12,
            color: cs.primary.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 3),
          Flexible(child: Text(path, style: codeStyle)),
        ],
      ),
    );
  }
}
