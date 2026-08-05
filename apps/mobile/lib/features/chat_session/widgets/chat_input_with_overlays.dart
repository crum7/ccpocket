import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:image_picker/image_picker.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../../l10n/app_localizations.dart';
import '../../../utils/platform_helper.dart';
import '../../../utils/composer_tokens.dart';
import '../../../hooks/use_list_auto_complete.dart';
import '../../../hooks/use_voice_input.dart';
import '../../../models/file_attachment.dart';
import '../../../models/messages.dart';
import '../../../providers/bridge_cubits.dart';
import '../../../services/prompt_history_service.dart';
import '../../../services/attachment_picker.dart';
import '../../../utils/diff_parser.dart';
import '../../../widgets/chat_input_bar.dart';
import '../../../widgets/file_mention_overlay.dart';
import '../../../widgets/slash_command_overlay.dart';
import '../../settings/state/settings_cubit.dart';
import '../../../services/draft_service.dart';
import '../../../services/bridge_service.dart';
import '../../prompt_history/widgets/prompt_history_sheet.dart';
import '../../../widgets/slash_command_sheet.dart'
    show
        SlashCommand,
        SlashCommandCategory,
        fallbackCodexSlashCommands,
        fallbackSlashCommands;
import '../state/chat_session_cubit.dart';

/// Manages the chat input bar together with slash-command and @-mention
/// overlays using [OverlayPortal].
///
/// [inputController] is managed by the parent widget to preserve text across
/// rebuilds (e.g., when approval bar appears/disappears).
/// Overlay controllers and voice input are managed via hooks.
class ChatInputWithOverlays extends HookWidget {
  final String sessionId;
  final ProcessStatus status;
  final VoidCallback onScrollToBottom;
  final TextEditingController inputController;

  /// Diff selection to attach (set by parent when returning from GitScreen).
  final DiffSelection? initialDiffSelection;

  /// Called after the diff selection is consumed into local state.
  final VoidCallback? onDiffSelectionConsumed;

  /// Called when the diff selection is cleared (sent or manually removed).
  final VoidCallback? onDiffSelectionCleared;

  /// Opens the diff screen with current selection state.
  final void Function(DiffSelection? currentSelection)? onOpenGitScreen;

  /// Custom hint text for the input field (e.g. provider-specific).
  final String? hintText;

  const ChatInputWithOverlays({
    super.key,
    required this.sessionId,
    required this.status,
    required this.onScrollToBottom,
    required this.inputController,
    this.initialDiffSelection,
    this.onDiffSelectionConsumed,
    this.onDiffSelectionCleared,
    this.onOpenGitScreen,
    this.hintText,
  });

  @override
  Widget build(BuildContext context) {
    // Track if input has text (initialize from controller's current value)
    final hasInputText = useState(inputController.text.trim().isNotEmpty);

    // Track if input is completely empty (for slash command button swap)
    final isInputEmpty = useState(inputController.text.isEmpty);
    final isInMentionContext = useState(false);

    // List auto-complete (Google Keep-style)
    useListAutoComplete(inputController);

    // Voice input
    final voice = useVoiceInput(inputController);

    // Indent settings
    final indentSize = context.watch<SettingsCubit>().state.indentSize;
    final canDedent = useState(false);

    // OverlayPortal controllers
    final slashPortalController = useMemoized(() => OverlayPortalController());
    final dollarPortalController = useMemoized(() => OverlayPortalController());
    final filePortalController = useMemoized(() => OverlayPortalController());

    // LayerLink for CompositedTransformFollower positioning
    final layerLink = useMemoized(() => LayerLink());

    // Filtered overlay items
    final filteredSlash = useState<List<SlashCommand>>(const []);
    final filteredDollar = useState<List<SlashCommand>>(const []);
    final filteredFiles = useState<List<String>>(const []);

    // Image attachment state (multiple images)
    final attachedImages = useState<List<({Uint8List bytes, String mimeType})>>(
      [],
    );
    final attachedFiles = useState<List<FileAttachment>>([]);

    // Restore image draft on mount
    useEffect(() {
      final draftService = context.read<DraftService>();
      final imageDrafts = draftService.getImageDraft(sessionId);
      if (imageDrafts != null && imageDrafts.isNotEmpty) {
        attachedImages.value = imageDrafts;
      }
      final fileDrafts = draftService.getFileDraft(sessionId);
      if (fileDrafts != null && fileDrafts.isNotEmpty) {
        attachedFiles.value = fileDrafts;
      }
      return null;
    }, [sessionId]);

    // Diff selection attachment state
    final attachedDiffSelection = useState<DiffSelection?>(null);

    // Consume initialDiffSelection from parent
    useEffect(() {
      if (initialDiffSelection != null && !initialDiffSelection!.isEmpty) {
        attachedDiffSelection.value = initialDiffSelection;
        onDiffSelectionConsumed?.call();
      }
      return null;
    }, [initialDiffSelection]);

    // Project files for @-mention
    final projectFiles = context.watch<FileListCubit>().state;

    // Slash commands from cubit
    final chatCubit = context.read<ChatSessionCubit>();
    final isCodex = chatCubit.isCodex;
    final completionItems = context
        .watch<ChatSessionCubit>()
        .state
        .slashCommands;
    final sessionSlashCommands = completionItems
        .where((c) => c.command.startsWith('/'))
        .toList();
    final fallbackCommands = isCodex
        ? fallbackCodexSlashCommands
        : fallbackSlashCommands;
    final commands = [
      ...fallbackCommands,
      ...sessionSlashCommands.where(
        (item) => !fallbackCommands.any(
          (fallback) => fallback.command == item.command,
        ),
      ),
    ];
    final dollarEntities = completionItems
        .where((c) => c.command.startsWith(r'$'))
        .toList();
    final skillTokens = dollarEntities
        .where((c) => c.category == SlashCommandCategory.skill)
        .map((c) => c.command)
        .toSet();
    final appTokens = dollarEntities
        .where((c) => c.category == SlashCommandCategory.app)
        .map((c) => c.command)
        .toSet();
    final composerTokenConfig = ComposerTokenConfig(
      provider: isCodex ? Provider.codex : Provider.claude,
      slashCommands: commands.map((c) => c.command).toSet(),
      skillTokens: skillTokens,
      appTokens: appTokens,
      fileMentions: projectFiles.toSet(),
    );
    final composerTokenPalette = ComposerTokenPalette.fromTheme(
      Theme.of(context),
    );

    if (inputController case final ComposerTextEditingController controller) {
      controller.updateTokenState(
        config: composerTokenConfig,
        palette: composerTokenPalette,
      );
    }

    // Input change listener
    useEffect(() {
      void onChange() {
        final text = inputController.text;
        final trimHasText = text.trim().isNotEmpty;
        if (trimHasText != hasInputText.value) {
          hasInputText.value = trimHasText;
        }
        final empty = text.isEmpty;
        if (empty != isInputEmpty.value) {
          isInputEmpty.value = empty;
        }

        final slashQuery = _extractTriggerQuery(
          text,
          inputController.selection.baseOffset,
          trigger: '/',
        );
        if (slashQuery != null) {
          if (isInMentionContext.value) {
            isInMentionContext.value = false;
          }
          final query = '/${slashQuery.toLowerCase()}';
          final filtered = commands
              .where((c) => c.command.toLowerCase().startsWith(query))
              .toList();
          if (filtered.isNotEmpty) {
            filteredSlash.value = filtered;
            _setPortalVisibility(slashPortalController, visible: true);
          } else {
            _setPortalVisibility(slashPortalController, visible: false);
          }
          _setPortalVisibility(dollarPortalController, visible: false);
          _setPortalVisibility(filePortalController, visible: false);
        } else {
          _setPortalVisibility(slashPortalController, visible: false);
          final dollarQuery = isCodex
              ? _extractTriggerQuery(
                  text,
                  inputController.selection.baseOffset,
                  trigger: r'$',
                )
              : null;
          if (dollarQuery != null) {
            if (isInMentionContext.value) {
              isInMentionContext.value = false;
            }
            final q = '${r'$'}${dollarQuery.toLowerCase()}';
            final filtered =
                dollarEntities
                    .where((c) => c.command.toLowerCase().startsWith(q))
                    .toList()
                  ..sort((a, b) => a.command.compareTo(b.command));
            if (filtered.isNotEmpty) {
              filteredDollar.value = filtered;
              _setPortalVisibility(dollarPortalController, visible: true);
            } else {
              _setPortalVisibility(dollarPortalController, visible: false);
            }
            _setPortalVisibility(filePortalController, visible: false);
            return;
          }
          _setPortalVisibility(dollarPortalController, visible: false);
          // @-mention filtering
          final mentionQuery = _extractMentionQuery(
            text,
            inputController.selection.baseOffset,
          );
          // Track whether cursor is in @-mention context (for button state)
          final inMention = mentionQuery != null;
          if (inMention != isInMentionContext.value) {
            isInMentionContext.value = inMention;
            // Fetch the project file list on demand the moment an @-mention
            // begins (it is no longer fetched proactively). The watched
            // FileListCubit rebuilds this widget when the result arrives, so
            // suggestions appear as soon as the bridge responds.
            if (inMention) {
              final projectPath =
                  context.read<ChatSessionCubit>().state.projectPath;
              if (projectPath != null && projectPath.isNotEmpty) {
                context.read<BridgeService>().requestFileList(projectPath);
              }
            }
          }
          if (mentionQuery != null && projectFiles.isNotEmpty) {
            final q = mentionQuery.toLowerCase();
            final scored =
                projectFiles
                    .map((f) => (file: f, score: _fileScore(f, q)))
                    .where((e) => e.score >= 0)
                    .toList()
                  ..sort((a, b) {
                    final cmp = a.score.compareTo(b.score);
                    return cmp != 0
                        ? cmp
                        : a.file.length.compareTo(b.file.length);
                  });
            final filtered = scored.take(15).map((e) => e.file).toList();
            if (filtered.isNotEmpty) {
              filteredFiles.value = filtered;
              _setPortalVisibility(filePortalController, visible: true);
            } else {
              _setPortalVisibility(filePortalController, visible: false);
            }
          } else {
            _setPortalVisibility(filePortalController, visible: false);
          }
        }
      }

      inputController.addListener(onChange);
      return () => inputController.removeListener(onChange);
    }, [commands, dollarEntities, isCodex, projectFiles]);

    // Update canDedent on cursor/text changes
    useEffect(() {
      void onCursorChange() {
        canDedent.value = _currentLineHasLeadingSpaces(inputController);
      }

      inputController.addListener(onCursorChange);
      return () => inputController.removeListener(onCursorChange);
    }, [inputController]);

    void indent() {
      final spaces = ' ' * indentSize;
      _applyIndent(inputController, spaces, isIndent: true);
      canDedent.value = _currentLineHasLeadingSpaces(inputController);
    }

    void dedent() {
      final spaces = ' ' * indentSize;
      _applyIndent(inputController, spaces, isIndent: false);
      canDedent.value = _currentLineHasLeadingSpaces(inputController);
    }

    void insertSlashPrefix() {
      inputController.text = '/';
      inputController.selection = TextSelection.fromPosition(
        const TextPosition(offset: 1),
      );
    }

    void insertMention() {
      _insertTrigger(inputController, '@');
    }

    void insertDollar() {
      _insertTrigger(inputController, r'$');
    }

    // Callbacks
    void onSlashCommandSelected(SlashCommand command) {
      _setPortalVisibility(slashPortalController, visible: false);
      _replaceActiveTriggerQuery(
        inputController,
        trigger: '/',
        replacement: command.insertText,
      );
    }

    void onDollarEntitySelected(SlashCommand command) {
      _setPortalVisibility(dollarPortalController, visible: false);
      _replaceActiveTriggerQuery(
        inputController,
        trigger: r'$',
        replacement: '${command.command} ',
      );
    }

    void onFileMentionSelected(String filePath) {
      _setPortalVisibility(filePortalController, visible: false);
      final text = inputController.text;
      final cursorPos = inputController.selection.baseOffset;
      final beforeCursor = text.substring(0, cursorPos);
      final atIndex = beforeCursor.lastIndexOf('@');
      if (atIndex < 0) return;
      final afterCursor = text.substring(cursorPos);
      final newText = '${text.substring(0, atIndex)}@$filePath $afterCursor';
      inputController.text = newText;
      final newCursor = atIndex + 1 + filePath.length + 1;
      inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: newCursor),
      );
    }

    int currentAttachmentCount() =>
        attachedImages.value.length + attachedFiles.value.length;

    void showAttachmentLimitReached() {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(
              context,
            ).attachmentLimitReached(maxAttachmentCount),
          ),
        ),
      );
    }

    void showFileTooLarge(String name) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(
              context,
            ).fileTooLarge(name, maxFileAttachmentBytes ~/ (1024 * 1024)),
          ),
        ),
      );
    }

    /// Add image bytes to attachment list (shared by paste and drag-and-drop).
    void addImageBytes(Uint8List bytes, String mimeType) {
      if (currentAttachmentCount() >= maxAttachmentCount) {
        showAttachmentLimitReached();
        return;
      }
      final updated = [
        ...attachedImages.value,
        (bytes: bytes, mimeType: mimeType),
      ];
      attachedImages.value = updated;
      if (context.mounted) {
        context.read<DraftService>().saveImageDraft(sessionId, updated);
      }
    }

    void addFileAttachment(FileAttachment file) {
      if (currentAttachmentCount() >= maxAttachmentCount) {
        showAttachmentLimitReached();
        return;
      }
      if (file.bytes.length > maxFileAttachmentBytes) {
        showFileTooLarge(file.name);
        return;
      }
      if (file.isSupportedImage) {
        addImageBytes(file.bytes, file.mimeType);
        return;
      }
      final updated = [...attachedFiles.value, file];
      attachedFiles.value = updated;
      if (context.mounted) {
        context.read<DraftService>().saveFileDraft(sessionId, updated);
      }
    }

    /// Handle items dropped via OS drag-and-drop (desktop).
    Future<void> handleDroppedItems(PerformDropEvent event) async {
      for (final item in event.session.items) {
        final reader = item.dataReader;
        if (reader == null) continue;
        var handled = false;
        for (final format in [Formats.png, Formats.jpeg]) {
          if (reader.canProvide(format)) {
            reader.getFile(format, (file) async {
              try {
                final bytes = await file.readAll();
                final mimeType = format == Formats.png
                    ? 'image/png'
                    : 'image/jpeg';
                addImageBytes(bytes, mimeType);
              } catch (e) {
                debugPrint('[drop] Failed to read dropped image: $e');
              }
            });
            handled = true;
            break;
          }
        }
        if (handled) continue;

        final fileFormats = reader
            .getFormats(Formats.standardFormats)
            .whereType<FileFormat>()
            .toList();
        if (fileFormats.isEmpty) continue;
        final suggestedName = await reader.getSuggestedName();
        reader.getFile(fileFormats.first, (file) async {
          final name = file.fileName ?? suggestedName ?? 'attachment';
          try {
            if ((file.fileSize ?? 0) > maxFileAttachmentBytes) {
              showFileTooLarge(name);
              return;
            }
            final bytes = await file.readAll();
            addFileAttachment(
              FileAttachment(
                name: name,
                mimeType: mimeTypeForFileName(name),
                bytes: bytes,
              ),
            );
          } catch (error) {
            debugPrint('[drop] Failed to read dropped file: $error');
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    AppLocalizations.of(context).failedToLoadFile(name),
                  ),
                ),
              );
            }
          }
        });
      }
    }

    void sendMessage() {
      final text = inputController.text.trim();
      if (text.isEmpty &&
          attachedImages.value.isEmpty &&
          attachedFiles.value.isEmpty &&
          attachedDiffSelection.value == null) {
        return;
      }
      HapticFeedback.lightImpact();

      final cubit = context.read<ChatSessionCubit>();

      // Capture and clear attached images
      List<({Uint8List bytes, String mimeType})>? images;
      if (attachedImages.value.isNotEmpty) {
        images = List.of(attachedImages.value);
        attachedImages.value = [];
      }

      List<FileAttachment>? files;
      if (attachedFiles.value.isNotEmpty) {
        files = List.of(attachedFiles.value);
        attachedFiles.value = [];
      }

      // Capture and clear diff selection
      DiffSelection? selection;
      if (attachedDiffSelection.value != null) {
        selection = attachedDiffSelection.value;
        attachedDiffSelection.value = null;
        onDiffSelectionCleared?.call();
      }

      // Build final message text with the requested diff prepended.
      var finalText = text;
      if (selection != null) {
        if (selection.diffText.isNotEmpty) {
          final prefix = '```diff\n${selection.diffText}\n```';
          finalText = finalText.isEmpty ? prefix : '$prefix\n\n$finalText';
        }
      }

      final messageToSend = finalText.isNotEmpty
          ? finalText
          : files != null && files.isNotEmpty
          ? 'Please inspect the attached file${files.length > 1 ? 's' : ''}.'
          : 'What is in this image?';
      cubit.sendMessage(messageToSend, images: images, files: files);
      inputController.clear();
      final draftService = context.read<DraftService>();
      draftService.deleteDraft(sessionId);
      draftService.deleteImageDraft(sessionId);
      draftService.deleteFileDraft(sessionId);
      onScrollToBottom();

      // Record prompt in history (skip auto-generated fallback text)
      if (finalText.isNotEmpty) {
        final projectPath = cubit.state.projectPath ?? '';
        context.read<PromptHistoryService>().recordPrompt(
          finalText,
          projectPath: projectPath,
        );
      }
    }

    Future<void> pickImageFromGallery() async {
      final remaining = maxAttachmentCount - currentAttachmentCount();

      if (remaining <= 0) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(
                  context,
                ).attachmentLimitReached(maxAttachmentCount),
              ),
            ),
          );
        }
        return;
      }

      final picker = ImagePicker();
      final List<XFile> picked = await picker.pickMultiImage(
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );

      if (picked.isEmpty) return;

      // Truncate to remaining slots
      final truncated = picked.length > remaining;
      final filesToAdd = picked.take(remaining).toList();

      final newImages = <({Uint8List bytes, String mimeType})>[];
      for (final file in filesToAdd) {
        final bytes = await file.readAsBytes();
        if (!context.mounted) return;
        final mimeType = _detectMimeType(bytes, file.path);
        newImages.add((bytes: bytes, mimeType: mimeType));
      }

      final updated = [...attachedImages.value, ...newImages];
      attachedImages.value = updated;

      // Persist image draft
      if (context.mounted) {
        context.read<DraftService>().saveImageDraft(sessionId, updated);

        if (truncated) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context).imageLimitTruncated(
                  maxAttachmentCount,
                  picked.length - filesToAdd.length,
                ),
              ),
            ),
          );
        }
      }
    }

    Future<void> pickFiles() async {
      final remaining = maxAttachmentCount - currentAttachmentCount();
      if (remaining <= 0) {
        showAttachmentLimitReached();
        return;
      }
      try {
        final result = await pickFileAttachments(maxFiles: remaining);
        if (!context.mounted) return;
        for (final file in result.files) {
          addFileAttachment(file);
        }
        for (final name in result.tooLargeFileNames) {
          showFileTooLarge(name);
        }
        for (final name in result.failedFileNames) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context).failedToLoadFile(name),
              ),
            ),
          );
        }
      } catch (error) {
        debugPrint('[attachment] Failed to pick files: $error');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context).failedToLoadFile('file'),
              ),
            ),
          );
        }
      }
    }

    Future<void> pasteFromClipboard() async {
      if (currentAttachmentCount() >= maxAttachmentCount) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(
                  context,
                ).attachmentLimitReached(maxAttachmentCount),
              ),
            ),
          );
        }
        return;
      }

      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).clipboardNotAvailable),
            ),
          );
        }
        return;
      }

      try {
        final reader = await clipboard.read();

        // Try PNG first, then JPEG
        for (final format in [Formats.png, Formats.jpeg]) {
          if (reader.canProvide(format)) {
            reader.getFile(format, (file) async {
              try {
                final bytes = await file.readAll();
                if (context.mounted) {
                  final mimeType = format == Formats.png
                      ? 'image/png'
                      : 'image/jpeg';

                  addImageBytes(bytes, mimeType);
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppLocalizations.of(context).failedToLoadImage,
                      ),
                    ),
                  );
                }
              }
            });
            return;
          }
        }

        // No image found in clipboard
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).noImageInClipboard),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).failedToReadClipboard),
            ),
          );
        }
      }
    }

    /// Try to paste an image from clipboard. Returns true if an image was
    /// found, false if only text (or nothing) is in the clipboard.
    /// Used by Cmd+V handler to decide whether to fall back to text paste.
    Future<bool> tryPasteImage() async {
      if (currentAttachmentCount() >= maxAttachmentCount) return false;
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) return false;
      try {
        final reader = await clipboard.read();
        for (final format in [Formats.png, Formats.jpeg]) {
          if (reader.canProvide(format)) {
            reader.getFile(format, (file) async {
              try {
                final bytes = await file.readAll();
                final mimeType = format == Formats.png
                    ? 'image/png'
                    : 'image/jpeg';
                addImageBytes(bytes, mimeType);
              } catch (e) {
                debugPrint('[paste] Failed to read clipboard image: $e');
              }
            });
            return true;
          }
        }
        return false;
      } catch (e) {
        debugPrint('[paste] Failed to read clipboard: $e');
        return false;
      }
    }

    Future<bool> hasClipboardImage() async {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) return false;
      try {
        final reader = await clipboard.read();
        return reader.canProvide(Formats.png) ||
            reader.canProvide(Formats.jpeg);
      } catch (_) {
        return false;
      }
    }

    Future<void> showAttachOptions() async {
      final hasClipImage = await hasClipboardImage();
      if (!context.mounted) return;

      showModalBottomSheet(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isMacOSPlatform)
                ListTile(
                  key: const ValueKey('attach_files'),
                  leading: const Icon(Icons.attach_file),
                  title: Text(AppLocalizations.of(context).selectFiles),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    pickFiles();
                  },
                ),
              ListTile(
                key: const ValueKey('attach_from_gallery'),
                leading: const Icon(Icons.photo_library),
                title: Text(AppLocalizations.of(context).selectFromGallery),
                onTap: () {
                  Navigator.pop(sheetContext);
                  pickImageFromGallery();
                },
              ),
              ListTile(
                key: const ValueKey('attach_from_clipboard'),
                leading: Icon(
                  Icons.content_paste,
                  color: hasClipImage
                      ? null
                      : Theme.of(sheetContext).colorScheme.outline,
                ),
                title: Text(
                  AppLocalizations.of(context).pasteFromClipboard,
                  style: hasClipImage
                      ? null
                      : TextStyle(
                          color: Theme.of(sheetContext).colorScheme.outline,
                        ),
                ),
                enabled: hasClipImage,
                onTap: hasClipImage
                    ? () {
                        Navigator.pop(sheetContext);
                        pasteFromClipboard();
                      }
                    : null,
              ),
            ],
          ),
        ),
      );
    }

    void clearAttachment([int? index]) {
      if (index != null && index < attachedImages.value.length) {
        final updated = [...attachedImages.value]..removeAt(index);
        attachedImages.value = updated;
        if (updated.isEmpty) {
          context.read<DraftService>().deleteImageDraft(sessionId);
        } else {
          context.read<DraftService>().saveImageDraft(sessionId, updated);
        }
      } else {
        attachedImages.value = [];
        context.read<DraftService>().deleteImageDraft(sessionId);
      }
    }

    void clearFileAttachment(int index) {
      if (index >= attachedFiles.value.length) return;
      final updated = [...attachedFiles.value]..removeAt(index);
      attachedFiles.value = updated;
      if (updated.isEmpty) {
        context.read<DraftService>().deleteFileDraft(sessionId);
      } else {
        context.read<DraftService>().saveFileDraft(sessionId, updated);
      }
    }

    void clearDiffSelection() {
      attachedDiffSelection.value = null;
      onDiffSelectionCleared?.call();
    }

    void stopSession() {
      HapticFeedback.mediumImpact();
      context.read<ChatSessionCubit>().stop();
    }

    void interruptSession() {
      HapticFeedback.mediumImpact();
      context.read<ChatSessionCubit>().interrupt();
    }

    void showPromptHistory() {
      final service = context.read<PromptHistoryService>();
      final projectPath = context.read<ChatSessionCubit>().state.projectPath;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        builder: (_) => PromptHistorySheet(
          service: service,
          currentProjectPath: projectPath,
          onSelect: (text) {
            inputController.text = text;
            inputController.selection = TextSelection.fromPosition(
              TextPosition(offset: text.length),
            );
          },
        ),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;

    Widget buildFollowerOverlay({required Widget child}) {
      return CompositedTransformFollower(
        link: layerLink,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        child: SizedBox(width: screenWidth - 16, child: child),
      );
    }

    return OverlayPortal(
      controller: slashPortalController,
      overlayChildBuilder: (_) => Positioned(
        left: 8,
        child: buildFollowerOverlay(
          child: SlashCommandOverlay(
            filteredCommands: filteredSlash.value,
            onSelect: onSlashCommandSelected,
            onDismiss: slashPortalController.hide,
          ),
        ),
      ),
      child: OverlayPortal(
        controller: dollarPortalController,
        overlayChildBuilder: (_) => Positioned(
          left: 8,
          child: buildFollowerOverlay(
            child: SlashCommandOverlay(
              filteredCommands: filteredDollar.value,
              onSelect: onDollarEntitySelected,
              onDismiss: dollarPortalController.hide,
            ),
          ),
        ),
        child: OverlayPortal(
          controller: filePortalController,
          overlayChildBuilder: (_) => Positioned(
            left: 8,
            child: buildFollowerOverlay(
              child: FileMentionOverlay(
                filteredFiles: filteredFiles.value,
                onSelect: onFileMentionSelected,
                onDismiss: filePortalController.hide,
              ),
            ),
          ),
          child: CompositedTransformTarget(
            link: layerLink,
            child: _wrapWithDropRegion(
              enabled: isDesktopPlatform,
              onPerformDrop: handleDroppedItems,
              child: ChatInputBar(
                inputController: inputController,
                status: status,
                hasInputText:
                    hasInputText.value ||
                    attachedImages.value.isNotEmpty ||
                    attachedFiles.value.isNotEmpty ||
                    attachedDiffSelection.value != null,
                isInputEmpty: isInputEmpty.value,
                isVoiceAvailable:
                    !context.watch<SettingsCubit>().state.hideVoiceInput &&
                    voice.isAvailable,
                isRecording: voice.isRecording,
                onSend: sendMessage,
                onStop: stopSession,
                onInterrupt: interruptSession,
                onToggleVoice: voice.toggle,
                onIndent: indent,
                onDedent: dedent,
                canDedent: canDedent.value,
                onSlashCommand: insertSlashPrefix,
                onMention: insertMention,
                onDollarMention: isCodex ? insertDollar : null,
                showDollarButton: isCodex,
                isInMentionContext: isInMentionContext.value,
                onShowPromptHistory: showPromptHistory,
                onAttachImage: showAttachOptions,
                attachedImages: attachedImages.value,
                onClearImage: clearAttachment,
                attachedFiles: attachedFiles.value,
                onClearFile: clearFileAttachment,
                attachedDiffSelection: attachedDiffSelection.value,
                onClearDiffSelection: clearDiffSelection,
                onTapDiffPreview: onOpenGitScreen != null
                    ? () => onOpenGitScreen!(attachedDiffSelection.value)
                    : null,
                hintText: hintText,
                onPasteImage: isDesktopPlatform ? tryPasteImage : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps child with a [DropRegion] for accepting OS-level drag-and-drop.
Widget _wrapWithDropRegion({
  required bool enabled,
  required Future<void> Function(PerformDropEvent) onPerformDrop,
  required Widget child,
}) {
  if (!enabled) return child;
  return DropRegion(
    formats: Formats.standardFormats,
    hitTestBehavior: HitTestBehavior.opaque,
    onDropOver: (event) {
      final hasAttachment = event.session.items.any(
        (item) => Formats.standardFormats.any(
          (format) => format is FileFormat && item.canProvide(format),
        ),
      );
      return hasAttachment ? DropOperation.copy : DropOperation.none;
    },
    onPerformDrop: onPerformDrop,
    child: child,
  );
}

/// Detect MIME type from image bytes using magic bytes.
///
/// On Android, [image_picker] with `imageQuality` re-encodes to JPEG but may
/// keep the original file extension (e.g. `.png`). Relying on the extension
/// causes a mismatch between `media_type` and the actual image content,
/// which the Claude API rejects. Inspecting magic bytes is reliable.
String _detectMimeType(Uint8List bytes, String fallbackPath) {
  if (bytes.length >= 8) {
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    // GIF: 47 49 46 38
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'image/gif';
    }
    // WebP: RIFF....WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes.length >= 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
  }
  // Fallback: guess from extension
  final ext = fallbackPath.split('.').last.toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    _ => 'image/jpeg',
  };
}

/// Score a file path against a query for @-mention ranking.
/// Lower score = better match. Returns -1 if no match.
int _fileScore(String path, String query) {
  final lower = path.toLowerCase();
  final fileName = lower.split('/').last;
  final nameWithoutExt = fileName.split('.').first;
  if (nameWithoutExt == query) return 0;
  if (fileName.startsWith(query)) return 1;
  if (nameWithoutExt.startsWith(query)) return 1;
  if (fileName.contains(query)) return 2;
  if (lower.split('/').any((s) => s.startsWith(query))) return 3;
  if (lower.contains(query)) return 4;
  return -1;
}

/// Extract the file query after the last '@' before cursor position.
/// Returns null if no active @-mention is being typed.
String? _extractMentionQuery(String text, int cursorPos) {
  return _extractTriggerQuery(text, cursorPos, trigger: '@');
}

String? _extractTriggerQuery(
  String text,
  int cursorPos, {
  required String trigger,
}) {
  if (cursorPos < 0) return null;
  final beforeCursor = text.substring(0, cursorPos);
  final triggerIndex = beforeCursor.lastIndexOf(trigger);
  if (triggerIndex < 0) return null;
  if (triggerIndex > 0 &&
      !RegExp(r'[\s(\[{:,;]').hasMatch(beforeCursor[triggerIndex - 1])) {
    return null;
  }
  final query = beforeCursor.substring(triggerIndex + 1);
  if (query.contains(RegExp(r'\s'))) return null;
  return query;
}

void _insertTrigger(TextEditingController controller, String trigger) {
  final text = controller.text;
  final cursorPos = controller.selection.baseOffset;
  final pos = cursorPos < 0 ? text.length : cursorPos;
  final before = text.substring(0, pos);
  final after = text.substring(pos);
  final needSpace = before.isNotEmpty && !RegExp(r'\s$').hasMatch(before);
  final insertion = needSpace ? ' $trigger' : trigger;
  controller.text = '$before$insertion$after';
  controller.selection = TextSelection.collapsed(
    offset: pos + insertion.length,
  );
}

void _replaceActiveTriggerQuery(
  TextEditingController controller, {
  required String trigger,
  required String replacement,
}) {
  final text = controller.text;
  final cursorPos = controller.selection.baseOffset;
  final pos = cursorPos < 0 ? text.length : cursorPos;
  final before = text.substring(0, pos);
  final triggerIndex = before.lastIndexOf(trigger);
  if (triggerIndex < 0) {
    _insertTrigger(controller, trigger);
    return;
  }
  final after = text.substring(pos);
  final nextText = '${before.substring(0, triggerIndex)}$replacement$after';
  final nextOffset = triggerIndex + replacement.length;
  controller.text = nextText;
  controller.selection = TextSelection.collapsed(offset: nextOffset);
}

/// Check if the current cursor line has leading spaces.
bool _currentLineHasLeadingSpaces(TextEditingController controller) {
  final text = controller.text;
  if (text.isEmpty) return false;
  final cursorPos = controller.selection.baseOffset;
  if (cursorPos < 0) return false;

  // Find line start
  final beforeCursor = text.substring(0, cursorPos);
  final lineStart = beforeCursor.lastIndexOf('\n') + 1;
  final lineEnd = text.indexOf('\n', lineStart);
  final line = text.substring(lineStart, lineEnd < 0 ? text.length : lineEnd);
  return line.startsWith(' ');
}

void _setPortalVisibility(
  OverlayPortalController controller, {
  required bool visible,
}) {
  void update() {
    if (visible) {
      controller.show();
    } else {
      controller.hide();
    }
  }

  if (WidgetsBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    WidgetsBinding.instance.addPostFrameCallback((_) => update());
    return;
  }
  update();
}

/// Apply indent or dedent to the current line(s).
void _applyIndent(
  TextEditingController controller,
  String spaces, {
  required bool isIndent,
}) {
  final text = controller.text;
  final selection = controller.selection;

  if (!selection.isValid) return;

  // Determine line range
  final selStart = selection.start;
  final selEnd = selection.end;

  // Find first line start
  final beforeStart = text.substring(0, selStart);
  final firstLineStart = beforeStart.lastIndexOf('\n') + 1;

  // Find last line end
  final lastLineEnd = text.indexOf('\n', selEnd);
  final endPos = lastLineEnd < 0 ? text.length : lastLineEnd;

  // Extract the block of lines
  final block = text.substring(firstLineStart, endPos);
  final lines = block.split('\n');

  // Track cursor offset changes
  var startDelta = 0;
  var endDelta = 0;

  final modifiedLines = <String>[];
  var charsSoFar = firstLineStart;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    String newLine;

    if (isIndent) {
      newLine = '$spaces$line';
      final delta = spaces.length;
      // Adjust selection deltas
      if (charsSoFar + line.length >= selStart && i == 0) {
        startDelta += delta;
      }
      endDelta += delta;
    } else {
      // Remove up to `spaces.length` leading spaces
      var removeCount = 0;
      for (var j = 0; j < spaces.length && j < line.length; j++) {
        if (line[j] == ' ') {
          removeCount++;
        } else {
          break;
        }
      }
      newLine = line.substring(removeCount);
      final delta = -removeCount;
      if (i == 0) {
        startDelta += delta;
      }
      endDelta += delta;
    }

    modifiedLines.add(newLine);
    charsSoFar += line.length + 1; // +1 for \n
  }

  final newBlock = modifiedLines.join('\n');
  final newText =
      text.substring(0, firstLineStart) + newBlock + text.substring(endPos);

  // Calculate new selection
  final newStart = (selStart + startDelta).clamp(
    firstLineStart,
    newText.length,
  );
  final newEnd = (selEnd + endDelta).clamp(newStart, newText.length);

  controller.value = TextEditingValue(
    text: newText,
    selection: selection.isCollapsed
        ? TextSelection.collapsed(offset: newStart)
        : TextSelection(baseOffset: newStart, extentOffset: newEnd),
  );
}
