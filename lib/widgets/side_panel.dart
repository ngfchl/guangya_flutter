import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import '../providers/file_provider.dart';
import '../providers/auth_provider.dart';
import '../models/cloud_file.dart';
import 'share_link_dialog.dart';

class SidePanel extends ConsumerWidget {
  const SidePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        border: Border(left: BorderSide(color: theme.colorScheme.border)),
      ),
      child: Column(
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(
                  LucideIcons.info,
                  size: 18,
                  color: theme.colorScheme.foreground,
                ),
                const SizedBox(width: 8),
                Text(
                  '详情',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.foreground,
                  ),
                ),
              ],
            ),
          ),
          const ShadSeparator.horizontal(),
          Expanded(child: _buildContent(context, ref)),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref) {
    final fileState = ref.watch(fileProvider);
    final selected = fileState.files
        .where((f) => fileState.selectedIDs.contains(f.id))
        .toList();

    if (selected.isEmpty) {
      return _buildDefaultContent(context, ref);
    }
    if (selected.length == 1) {
      return _buildSingleFileDetail(context, selected.first, ref);
    }
    return _buildMultiSelectDetail(context, selected, ref);
  }

  Widget _buildDefaultContent(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final fileState = ref.watch(fileProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(context, '账号信息'),
          const SizedBox(height: 12),
          _infoRow(context, '用户名', auth.userName),
          _infoRow(context, '会员等级', auth.memberLevel),
          _infoRow(context, '存储空间', auth.capacityText),
          const SizedBox(height: 24),

          if (fileState.section == WorkspaceSection.recycle) ...[
            _sectionTitle(context, '回收站'),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ShadButton.outline(
                onPressed: () {
                  showShadDialog(
                    context: context,
                    builder: (context) => ShadDialog(
                      title: const Text('清空回收站'),
                      description: const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('确定要永久删除回收站中的所有文件吗？此操作不可恢复。'),
                      ),
                      actions: [
                        ShadButton.outline(
                          child: const Text('取消'),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        ShadButton(
                          child: const Text('清空'),
                          onPressed: () {
                            ref.read(fileProvider.notifier).clearRecycleBin();
                            Navigator.of(context).pop();
                          },
                        ),
                      ],
                    ),
                  );
                },
                leading: const Icon(LucideIcons.trash2, size: 16),
                child: const Text('清空回收站'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSingleFileDetail(
    BuildContext context,
    CloudFile file,
    WidgetRef ref,
  ) {
    final theme = ShadTheme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              children: [
                Icon(
                  file.isDirectory ? LucideIcons.folder : LucideIcons.file,
                  size: 64,
                  color: file.isDirectory
                      ? const Color(0xFFF59E0B)
                      : theme.colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  file.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.foreground,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _sectionTitle(context, '文件信息'),
          const SizedBox(height: 12),
          _infoRow(context, '类型', file.typeName),
          if (!file.isDirectory) _infoRow(context, '大小', file.formattedSize),
          if (file.modifiedAt.isNotEmpty)
            _infoRow(context, '修改时间', file.modifiedAt),
          const SizedBox(height: 24),
          _sectionTitle(context, '操作'),
          const SizedBox(height: 12),
          _buildActionButtons(context, file, ref),
        ],
      ),
    );
  }

  Widget _buildMultiSelectDetail(
    BuildContext context,
    List<CloudFile> files,
    WidgetRef ref,
  ) {
    final theme = ShadTheme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              children: [
                Icon(
                  LucideIcons.checkCircle,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  '已选择 ${files.length} 个项目',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.foreground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _sectionTitle(context, '批量操作'),
          const SizedBox(height: 12),
          _buildActionButtons(context, files.first, ref),
        ],
      ),
    );
  }

  Widget _buildActionButtons(
    BuildContext context,
    CloudFile file,
    WidgetRef ref,
  ) {
    final theme = ShadTheme.of(context);
    final fp = ref.read(fileProvider.notifier);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (file.isDirectory)
          _actionChip(
            context,
            icon: LucideIcons.folderOpen,
            label: '打开',
            onTap: () => fp.navigateToFolder(file),
          ),
        _actionChip(
          context,
          icon: LucideIcons.copy,
          label: '复制',
          onTap: () => fp.copyToClipboard([file]),
        ),
        _actionChip(
          context,
          icon: LucideIcons.scissors,
          label: '剪切',
          onTap: () => fp.cutToClipboard([file]),
        ),
        _actionChip(
          context,
          icon: LucideIcons.download,
          label: '下载',
          onTap: () => fp.downloadFile(file),
        ),
        _actionChip(
          context,
          icon: LucideIcons.share2,
          label: '分享',
          onTap: () => showShareLinkDialog(
            context,
            createLink: () => fp.createShare(file),
          ),
        ),
        _actionChip(
          context,
          icon: LucideIcons.trash2,
          label: '删除',
          color: theme.colorScheme.destructive,
          onTap: () => fp.deleteFiles([file]),
        ),
      ],
    );
  }

  Widget _actionChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    Color? color,
    required VoidCallback onTap,
  }) {
    return ShadButton.outline(
      onPressed: onTap,
      leading: Icon(icon, size: 14, color: color),
      child: Text(label, style: TextStyle(fontSize: 12, color: color)),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    final theme = ShadTheme.of(context);
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.mutedForeground,
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.mutedForeground,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.foreground,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
