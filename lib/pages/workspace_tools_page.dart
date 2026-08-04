import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import '../core/logging/app_logger.dart';
import '../core/storage/file_metadata_cache.dart';
import '../core/storage/storage_manager.dart';
import '../core/utils/workspace_scanner.dart';
import '../models/cloud_file.dart';
import '../models/batch_rename.dart';
import '../models/fast_transfer.dart';
import '../models/media_library.dart';
import '../providers/auth_provider.dart';
import '../providers/file_provider.dart';
import '../providers/media_library_provider.dart';
import '../utils/fast_transfer_path_resolver.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/file_detail_dialog.dart';
import '../widgets/file_preview_dialog.dart';
import '../widgets/media_player_dialog.dart';
import 'media_library_page.dart';
import 'organize_page.dart';

part 'workspace_tools/workspace_tools_organize.dart';
part 'workspace_tools/workspace_tools_rename.dart';
part 'workspace_tools/workspace_tools_dedup.dart';
part 'workspace_tools/workspace_tools_shared.dart';


class _ToolHeader extends ConsumerWidget {
  final WorkspaceTool tool;
  final VoidCallback onClose;

  const _ToolHeader({required this.tool, required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final mediaState = tool == WorkspaceTool.tmdb
        ? ref.watch(mediaLibraryProvider)
        : null;
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 420;
          return Row(
            children: [
              ShadTooltip(
                builder: (_) => const Text('返回'),
                child: ShadButton.ghost(
                  size: compact ? ShadButtonSize.sm : ShadButtonSize.regular,
                  onPressed: onClose,
                  leading: const Icon(Icons.arrow_back_rounded, size: 16),
                  child: compact ? const SizedBox.shrink() : const Text('返回'),
                ),
              ),
              const SizedBox(width: 10),
              Icon(tool.icon, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Builder(
                  builder: (context) {
                    String titleText = tool.title;
                    if (tool == WorkspaceTool.fastTransfer) {
                      final subPage = ref.watch(fastTransferSubPageProvider);
                      if (subPage != null) {
                        titleText = '${tool.title} › $subPage';
                      }
                    }
                    return Text(
                      titleText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.foreground,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                  },
                ),
              ),
              if (mediaState != null) ...[
                const SizedBox(width: 8),
                _ToolMediaLibrarySwitcher(
                  libraries: mediaState.libraries,
                  selectedLibraryID: mediaState.selectedLibraryID,
                  compact: compact,
                  onSelected: (libraryID) => ref
                      .read(mediaLibraryProvider.notifier)
                      .selectLibrary(libraryID),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ToolMediaLibrarySwitcher extends StatefulWidget {
  final List<MediaLibraryDefinition> libraries;
  final String? selectedLibraryID;
  final ValueChanged<String> onSelected;
  final bool compact;

  const _ToolMediaLibrarySwitcher({
    required this.libraries,
    required this.selectedLibraryID,
    required this.onSelected,
    required this.compact,
  });

  @override
  State<_ToolMediaLibrarySwitcher> createState() =>
      _ToolMediaLibrarySwitcherState();
}

class _ToolMediaLibrarySwitcherState extends State<_ToolMediaLibrarySwitcher> {
  final _controller = ShadPopoverController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final selected = widget.libraries
        .where((library) => library.id == widget.selectedLibraryID)
        .firstOrNull;
    return ShadPopover(
      controller: _controller,
      popover: (_) => SizedBox(
        width: 240,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(6),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                child: Text(
                  '切换媒体库',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.mutedForeground,
                  ),
                ),
              ),
              for (final library in widget.libraries)
                ShadButton.ghost(
                  width: double.infinity,
                  mainAxisAlignment: MainAxisAlignment.start,
                  leading: Icon(
                    library.kind == MediaLibraryKind.series
                        ? Icons.live_tv_rounded
                        : Icons.movie_rounded,
                    size: 16,
                  ),
                  trailing: library.id == widget.selectedLibraryID
                      ? Icon(Icons.check_rounded, size: 16, color: cs.primary)
                      : null,
                  onPressed: () {
                    _controller.hide();
                    widget.onSelected(library.id);
                  },
                  child: Text(
                    library.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.compact ? 92 : 190),
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: widget.libraries.isEmpty ? null : _controller.toggle,
              leading: Icon(
                Icons.video_library_rounded,
                size: 16,
                color: cs.primary,
              ),
              child: Text(
                selected?.name ?? '未选择媒体库',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 2),
          ShadTooltip(
            builder: (_) => const Text('切换媒体库'),
            child: ShadButton.outline(
              size: ShadButtonSize.sm,
              onPressed: widget.libraries.isEmpty ? null : _controller.toggle,
              child: const Icon(Icons.swap_horiz_rounded, size: 17),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolSection extends StatelessWidget {
  final String title;
  final String description;
  final Widget child;
  final Widget? trailing;
  final bool expandChild;

  const _ToolSection({
    required this.title,
    required this.description,
    required this.child,
    this.trailing,
    this.expandChild = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.card,
        border: Border.all(color: cs.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: cs.foreground,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          if (expandChild) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

