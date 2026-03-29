import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../l10n/app_localizations.dart';
import '../../services/bridge_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/diff_parser.dart';
import 'state/commit_cubit.dart';
import 'state/diff_view_cubit.dart';
import 'state/diff_view_state.dart';
import 'widgets/commit_bottom_sheet.dart';
import 'widgets/diff_content_list.dart';
import 'widgets/diff_empty_state.dart';
import 'widgets/diff_error_state.dart';
import 'widgets/diff_file_path_text.dart';
import 'widgets/diff_stats_badge.dart';

/// Dedicated screen for viewing unified diffs.
///
/// Two modes:
/// - **Individual diff**: Pass [initialDiff] with raw diff text (from tool_result).
/// - **Session-wide diff**: Pass [projectPath] to request `git diff` from Bridge.
///
/// Returns a [String] (reconstructed diff) via [Navigator.pop] when the user
/// selects hunks and taps the send-to-chat FAB.
@RoutePage()
class DiffScreen extends StatelessWidget {
  /// Raw diff text for immediate display (individual tool result).
  final String? initialDiff;

  /// Project path — triggers `git diff` request on init.
  final String? projectPath;

  /// Display title (e.g. file path for individual diff).
  final String? title;

  /// Pre-selected hunk keys to restore selection state.
  final Set<String>? initialSelectedHunkKeys;

  const DiffScreen({
    super.key,
    this.initialDiff,
    this.projectPath,
    this.title,
    this.initialSelectedHunkKeys,
  });

  @override
  Widget build(BuildContext context) {
    final bridge = context.read<BridgeService>();
    final isProjectMode = projectPath != null;

    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) => DiffViewCubit(
            bridge: bridge,
            initialDiff: initialDiff,
            projectPath: projectPath,
            initialSelectedHunkKeys: initialSelectedHunkKeys,
          ),
        ),
        if (isProjectMode)
          BlocProvider(
            create: (_) => CommitCubit(
              bridge: bridge,
              projectPath: projectPath!,
            ),
          ),
      ],
      child: _DiffScreenBody(title: title, isProjectMode: isProjectMode),
    );
  }
}

class _DiffScreenBody extends StatelessWidget {
  final String? title;
  final bool isProjectMode;

  const _DiffScreenBody({this.title, this.isProjectMode = false});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<DiffViewCubit>().state;
    final cubit = context.read<DiffViewCubit>();
    final appColors = Theme.of(context).extension<AppColors>()!;
    final l = AppLocalizations.of(context);

    final screenTitle = title ?? l.changes;

    return Scaffold(
      appBar: AppBar(
        title: Text(screenTitle, overflow: TextOverflow.ellipsis),
        bottom: isProjectMode
            ? PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: _DiffViewModeSegment(
                  viewMode: state.viewMode,
                  onChanged: cubit.switchMode,
                ),
              )
            : null,
        actions: [
          // Selection mode toggle
          if (state.files.isNotEmpty)
            IconButton(
              icon: Icon(
                Icons.alternate_email,
                color: state.selectionMode
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              tooltip: state.selectionMode
                  ? l.cancelSelection
                  : l.selectAndAttach,
              onPressed: cubit.toggleSelectionMode,
            ),
          // Filter (hidden during selection mode)
          if (state.files.length > 1 && !state.selectionMode)
            IconButton(
              icon: const Icon(Icons.filter_list),
              tooltip: l.filterFiles,
              onPressed: () =>
                  _showFilterBottomSheet(context, appColors, cubit),
            ),
          // Refresh (projectPath mode only, hidden during selection/loading)
          if (cubit.canRefresh && !state.selectionMode && !state.loading)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l.refresh,
              onPressed: cubit.refresh,
            ),
          // Commit (projectPath mode, staged tab only)
          if (isProjectMode && !state.selectionMode)
            IconButton(
              key: const ValueKey('commit_button'),
              icon: const Icon(Icons.check_circle_outline),
              tooltip: 'Commit',
              onPressed: () => showCommitBottomSheet(context),
            ),
        ],
      ),
      floatingActionButton: _buildFab(context, state, cubit, l),
      body: state.loading
          ? const Center(child: CircularProgressIndicator())
          : state.error != null
          ? DiffErrorState(error: state.error!, errorCode: state.errorCode)
          : state.files.isEmpty
          ? const DiffEmptyState()
          : DiffContentList(
              files: state.files,
              hiddenFileIndices: state.hiddenFileIndices,
              collapsedFileIndices: state.collapsedFileIndices,
              onToggleCollapse: cubit.toggleCollapse,
              onClearHidden: cubit.clearHidden,
              selectionMode: state.selectionMode,
              selectedHunkKeys: state.selectedHunkKeys,
              onToggleFileSelection: cubit.toggleFileSelection,
              onToggleHunkSelection: cubit.toggleHunkSelection,
              isFileFullySelected: cubit.isFileFullySelected,
              isFilePartiallySelected: cubit.isFilePartiallySelected,
              onLoadImage: cubit.loadImage,
              loadingImageIndices: state.loadingImageIndices,
              onSwipeStage: isProjectMode ? cubit.stageFile : null,
              onSwipeUnstage: isProjectMode ? cubit.unstageFile : null,
            ),
    );
  }

  Widget? _buildFab(
    BuildContext context,
    DiffViewState state,
    DiffViewCubit cubit,
    AppLocalizations l,
  ) {
    // Send-to-chat FAB (selection mode)
    if (state.selectionMode && cubit.hasAnySelection) {
      return FloatingActionButton.extended(
        key: const ValueKey('send_to_chat_fab'),
        onPressed: () {
          final selection = reconstructDiff(
            state.files,
            state.selectedHunkKeys,
          );
          context.router.maybePop(selection);
        },
        icon: const Icon(Icons.attach_file),
        label: Text(
          l.attachFilesAndHunks(
            cubit.selectionSummary.files,
            cubit.selectionSummary.hunks,
          ),
        ),
      );
    }

    // Stage/Unstage FAB (project mode, selection mode, has selection)
    if (isProjectMode && state.selectionMode && cubit.hasAnySelection) {
      final isStaged = state.viewMode == DiffViewMode.staged;
      return FloatingActionButton.extended(
        key: const ValueKey('stage_fab'),
        onPressed: state.staging
            ? null
            : isStaged
                ? cubit.unstageSelectedHunks
                : cubit.stageSelectedHunks,
        icon: state.staging
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(isStaged ? Icons.remove_circle_outline : Icons.add_circle_outline),
        label: Text(isStaged ? 'Unstage' : 'Stage'),
      );
    }

    // Stage All FAB (project mode, unstaged tab, not in selection, has files)
    if (isProjectMode &&
        !state.selectionMode &&
        state.files.isNotEmpty &&
        state.viewMode == DiffViewMode.unstaged) {
      return FloatingActionButton.extended(
        key: const ValueKey('stage_all_fab'),
        onPressed: state.staging ? null : cubit.stageAll,
        icon: state.staging
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_circle_outline),
        label: const Text('Stage All'),
      );
    }

    return null;
  }

  void _showFilterBottomSheet(
    BuildContext context,
    AppColors appColors,
    DiffViewCubit cubit,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return BlocBuilder<DiffViewCubit, DiffViewState>(
          bloc: cubit,
          builder: (context, state) {
            final l = AppLocalizations.of(context);
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                    child: Row(
                      children: [
                        Text(
                          l.filterFilesTitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: appColors.toolResultTextExpanded,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: cubit.clearHidden,
                          child: Text(l.all),
                        ),
                        TextButton(
                          onPressed: () => cubit.setHiddenFiles(
                            Set<int>.from(
                              List.generate(state.files.length, (i) => i),
                            ),
                          ),
                          child: Text(l.none),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: state.files.length,
                      itemBuilder: (context, index) {
                        final file = state.files[index];
                        final visible = !state.hiddenFileIndices.contains(
                          index,
                        );
                        return CheckboxListTile(
                          value: visible,
                          onChanged: (_) => cubit.toggleFileVisibility(index),
                          title: DiffFilePathText(
                            filePath: file.filePath,
                            style: const TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                            ),
                          ),
                          secondary: DiffStatsBadge(file: file),
                          controlAffinity: ListTileControlAffinity.leading,
                          dense: true,
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Segmented button for switching between Unstaged / Staged view modes.
class _DiffViewModeSegment extends StatelessWidget {
  final DiffViewMode viewMode;
  final ValueChanged<DiffViewMode> onChanged;

  const _DiffViewModeSegment({
    required this.viewMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SegmentedButton<DiffViewMode>(
        segments: const [
          ButtonSegment(
            value: DiffViewMode.unstaged,
            label: Text('Unstaged'),
            icon: Icon(Icons.edit_note, size: 18),
          ),
          ButtonSegment(
            value: DiffViewMode.staged,
            label: Text('Staged'),
            icon: Icon(Icons.check_circle_outline, size: 18),
          ),
        ],
        selected: {viewMode},
        onSelectionChanged: (s) => onChanged(s.first),
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}
