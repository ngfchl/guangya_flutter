import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/organize_action.dart';
import '../providers/file_provider.dart';
import '../providers/organize_provider.dart';

class OrganizeView extends ConsumerStatefulWidget {
  const OrganizeView({super.key});

  @override
  ConsumerState<OrganizeView> createState() => _OrganizeViewState();
}

class _OrganizeViewState extends ConsumerState<OrganizeView> {
  bool _inited = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(organizeProvider);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    if (!_inited) {
      _inited = true;
      final api = ref.read(fileProvider.notifier).api;
      if (api != null) {
        ref.read(organizeProvider.notifier).api = api;
      }
    }

    return Column(
      children: [
        _buildHeader(context, cs, tt, state),

        if (state.phase == OrganizePhase.preview ||
            state.phase == OrganizePhase.executing ||
            state.phase == OrganizePhase.done)
          _buildStats(context, cs, tt, state),

        if (state.phase == OrganizePhase.scanning ||
            state.phase == OrganizePhase.executing)
          _buildProgress(context, tt, state),

        Expanded(child: _buildBody(context, cs, tt, state)),

        if (state.phase == OrganizePhase.preview ||
            state.phase == OrganizePhase.done)
          _buildBottomBar(context, state),
      ],
    );
  }

  String get _parentId {
    final fileState = ref.read(fileProvider);
    return fileState.folderPath.isNotEmpty ? fileState.folderPath.last.id : '';
  }

  String get _parentPath {
    final fileState = ref.read(fileProvider);
    if (fileState.folderPath.isEmpty) return '根目录';
    return fileState.folderPath.map((f) => f.name).join('/');
  }

  // ── 头部 ──

  Widget _buildHeader(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    OrganizeState state,
  ) {
    final notifier = ref.read(organizeProvider.notifier);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: cs.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(Icons.auto_fix_high, color: cs.primary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('自动识别重复文件与文件夹', style: tt.titleSmall),
                if (state.phase == OrganizePhase.idle)
                  Text(
                    '将扫描「$_parentPath」及所有子目录',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  )
                else if (state.phase == OrganizePhase.scanning)
                  Text(
                    '正在扫描...',
                    style: tt.bodySmall?.copyWith(color: cs.primary),
                  )
                else if (state.phase == OrganizePhase.executing)
                  Text(
                    '正在执行...',
                    style: tt.bodySmall?.copyWith(color: cs.primary),
                  )
                else
                  Text(
                    'GCID 相同 → 删除副本  ·  GCID 不同 → 保留两份',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ),

          // ── 日志阶段：复制全部按钮 ──
          if (state.phase == OrganizePhase.scanning ||
              state.phase == OrganizePhase.done)
            IconButton(
              icon: const Icon(Icons.copy_all, size: 20),
              tooltip: '复制扫描日志',
              onPressed: state.logs.isEmpty
                  ? null
                  : () => _copyLogs(context, state.logs),
            ),

          // ── 日志阶段：复制全部按钮 ──
          if (state.phase == OrganizePhase.preview && state.actions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy_all, size: 20),
              tooltip: '复制扫描结果',
              onPressed: () => _copyActions(context, state),
            ),

          if (state.phase == OrganizePhase.idle)
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: () {
                final api = ref.read(fileProvider.notifier).api;
                if (api == null) return;
                notifier.api = api;
                notifier.scan(_parentId, rootPath: _parentPath);
              },
              leading: const Icon(Icons.search_rounded, size: 16),
              child: const Text('扫描预览'),
            ),

          if (state.phase == OrganizePhase.scanning ||
              state.phase == OrganizePhase.executing)
            IconButton(
              icon: const Icon(Icons.stop, size: 20),
              tooltip: '取消',
              onPressed: notifier.cancel,
            ),

          if (state.phase == OrganizePhase.preview ||
              state.phase == OrganizePhase.done)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: '重新扫描',
              onPressed: () => notifier.scan(_parentId, rootPath: _parentPath),
            ),
        ],
      ),
    );
  }

  // ── 复制日志 ──

  void _copyLogs(BuildContext context, List<String> logs) {
    Clipboard.setData(ClipboardData(text: logs.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制扫描日志'), duration: Duration(seconds: 2)),
    );
  }

  void _copyActions(BuildContext context, OrganizeState state) {
    final lines = state.actions.map((a) {
      final prefix = switch (a.type) {
        OrganizeActionType.moveToBase => '移动',
        OrganizeActionType.renameBase => '重命名基准',
        OrganizeActionType.renameConflict => '冲突重命名',
        OrganizeActionType.deleteDuplicate => '删除副本',
        OrganizeActionType.cleanDir => '清理目录',
      };
      return '[$prefix] ${a.sourceName} — ${a.reason}';
    }).toList();

    final summary =
        '移动: ${state.moveCount}  '
        '重命名: ${state.renameCount}  '
        '删除: ${state.deleteCount}  '
        '清理: ${state.cleanCount}';

    Clipboard.setData(ClipboardData(text: '$summary\n\n${lines.join('\n')}'));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制扫描结果'), duration: Duration(seconds: 2)),
    );
  }

  // ── 统计 ──

  Widget _buildStats(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    OrganizeState state,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _statItem(
                context,
                '移动',
                state.moveCount,
                Icons.drive_file_move,
                cs.primary,
              ),
              _statItem(
                context,
                '重命名',
                state.renameCount,
                Icons.edit,
                Colors.orange,
              ),
              _statItem(
                context,
                '删除',
                state.deleteCount,
                Icons.delete,
                Colors.red,
              ),
              _statItem(
                context,
                '清理',
                state.cleanCount,
                Icons.folder_delete,
                Colors.purple,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statItem(
    BuildContext context,
    String label,
    int count,
    IconData icon,
    Color color,
  ) {
    final tt = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: 2),
        Text(
          '$count',
          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(label, style: tt.bodySmall),
      ],
    );
  }

  // ── 进度 ──

  Widget _buildProgress(
    BuildContext context,
    TextTheme tt,
    OrganizeState state,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(),
          if (state.progressMessage.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              state.progressMessage,
              style: tt.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  // ── 内容区 ──

  Widget _buildBody(
    BuildContext context,
    ColorScheme cs,
    TextTheme tt,
    OrganizeState state,
  ) {
    if (state.phase == OrganizePhase.idle) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 56, color: cs.outlineVariant),
            const SizedBox(height: 12),
            Text(
              '点击上方「扫描预览」开始',
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    // 扫描中 / 完成后 → 日志列表（可点击复制单条）
    if (state.phase == OrganizePhase.scanning ||
        (state.phase == OrganizePhase.done && state.actions.isEmpty)) {
      return _buildLogList(context, state);
    }

    if (state.actions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 56, color: cs.primary),
            const SizedBox(height: 12),
            Text('没有发现重复项', style: tt.bodyMedium),
          ],
        ),
      );
    }

    return _buildActionList(context, state);
  }

  Widget _buildLogList(BuildContext context, OrganizeState state) {
    if (state.logs.isEmpty) {
      return const Center(child: Text('暂无日志'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: state.logs.length,
      itemBuilder: (_, i) {
        final log = state.logs[i];
        return InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () {
            Clipboard.setData(ClipboardData(text: log));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('已复制: $log'),
                duration: const Duration(seconds: 1),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    log,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontFamilyFallback: ['Menlo', 'Consolas'],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.copy,
                  size: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionList(BuildContext context, OrganizeState state) {
    final notifier = ref.read(organizeProvider.notifier);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      itemCount: state.actions.length,
      itemBuilder: (_, i) => _ActionTile(
        action: state.actions[i],
        onToggle: () => notifier.toggleAction(i),
      ),
    );
  }

  // ── 底部按钮 ──

  Widget _buildBottomBar(BuildContext context, OrganizeState state) {
    final notifier = ref.read(organizeProvider.notifier);

    if (state.phase == OrganizePhase.preview) {
      if (state.actions.isEmpty) return const SizedBox.shrink();
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () => notifier.setAllSelected(!state.allSelected),
                icon: Icon(
                  state.allSelected ? Icons.deselect : Icons.select_all,
                  size: 18,
                ),
                label: Text(state.allSelected ? '取消全选' : '全选'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: state.selectedCount == 0
                      ? null
                      : () => _confirmExecute(context, state),
                  icon: const Icon(Icons.play_arrow),
                  label: Text('执行整理 (${state.selectedCount})'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (state.phase == OrganizePhase.done) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => notifier.reset(),
              icon: const Icon(Icons.check),
              label: const Text('完成'),
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Future<void> _confirmExecute(
    BuildContext context,
    OrganizeState state,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认执行'),
        content: Text(
          '将移动 ${state.moveCount} 个文件，'
          '重命名 ${state.renameCount} 个，'
          '回收 ${state.deleteCount} 个重复文件，'
          '清理 ${state.cleanCount} 个空目录。\n\n'
          '删除的文件会移入回收站。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('执行'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(organizeProvider.notifier).execute();
    }
  }
}

// ── 单条操作 ──

class _ActionTile extends StatelessWidget {
  final OrganizeAction action;
  final VoidCallback onToggle;
  const _ActionTile({required this.action, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _styleFor(action.type);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: action.selected
          ? null
          : cs.surfaceContainerHighest.withValues(alpha: 0.4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: action.selected,
                onChanged: (_) => onToggle(),
                visualDensity: VisualDensity.compact,
              ),
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _actionLabel(action.type),
                            style: tt.labelSmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            action.sourceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    _InfoRow(label: '来源', value: action.sourcePath),
                    const SizedBox(height: 4),
                    _InfoRow(label: '处理', value: _targetText(action)),
                    if (action.reason.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        action.reason,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (action.failed &&
                        action.errorMessage?.isNotEmpty == true) ...[
                      const SizedBox(height: 4),
                      Text(
                        action.errorMessage!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(color: cs.error),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (action.failed)
                const Icon(Icons.error_outline, color: Colors.red, size: 16)
              else if (action.executed)
                const Icon(Icons.check, color: Colors.green, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  String _actionLabel(OrganizeActionType type) {
    return switch (type) {
      OrganizeActionType.moveToBase => '移动合并',
      OrganizeActionType.renameBase => '改为基准名',
      OrganizeActionType.renameConflict => '冲突改名',
      OrganizeActionType.deleteDuplicate => '删除副本',
      OrganizeActionType.cleanDir => '清理目录',
    };
  }

  String _targetText(OrganizeAction action) {
    return switch (action.type) {
      OrganizeActionType.moveToBase =>
        '移动到 ${action.targetPath ?? action.targetParentName ?? '--'}',
      OrganizeActionType.renameBase =>
        '重命名为 ${action.targetPath ?? action.newFileName ?? '--'}',
      OrganizeActionType.renameConflict =>
        action.targetParentId == null
            ? '重命名为 ${action.targetPath ?? action.newFileName ?? '--'}'
            : '重命名为 ${action.newFileName ?? '--'} 后移动到 ${action.targetPath ?? action.targetParentName ?? '--'}',
      OrganizeActionType.deleteDuplicate => '移入回收站',
      OrganizeActionType.cleanDir => '合并后删除空目录',
    };
  }

  (IconData, Color) _styleFor(OrganizeActionType type) {
    return switch (type) {
      OrganizeActionType.moveToBase => (Icons.drive_file_move, Colors.blue),
      OrganizeActionType.renameBase ||
      OrganizeActionType.renameConflict => (Icons.edit_note, Colors.orange),
      OrganizeActionType.deleteDuplicate => (Icons.delete, Colors.red),
      OrganizeActionType.cleanDir => (Icons.folder_delete, Colors.purple),
    };
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          padding: const EdgeInsets.only(top: 1),
          child: Text(
            label,
            style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: tt.bodySmall?.copyWith(color: cs.onSurface),
          ),
        ),
      ],
    );
  }
}
