import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide showShadDialog, showShadSheet;

import '../core/utils/guangya_share_link.dart';
import '../core/utils/json_deep.dart';
import '../models/cloud_file.dart';
import '../providers/auth_provider.dart';
import 'app_dialog.dart';
import 'app_loading_indicator.dart';
import 'file_icon.dart';

Future<bool?> showShareRestoreDialog(
  BuildContext context,
  GuangyaShareLink link,
) => showShadDialog<bool>(
  context: context,
  builder: (_) => ShareRestoreDialog(link: link),
);

class ShareRestoreDialog extends ConsumerStatefulWidget {
  final GuangyaShareLink link;

  const ShareRestoreDialog({super.key, required this.link});

  @override
  ConsumerState<ShareRestoreDialog> createState() => _ShareRestoreDialogState();
}

class _ShareRestoreDialogState extends ConsumerState<ShareRestoreDialog> {
  final _path = <CloudFile>[];
  final _selected = <String>{};
  var _files = <CloudFile>[];
  var _title = '';
  var _owner = '';
  var _accessToken = '';
  String? _targetID;
  var _targetLabel = '云盘根目录';
  var _loading = true;
  var _restoring = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(authProvider.notifier).api;
      final responses = await Future.wait([
        api.shareSummary(widget.link.shareID),
        api.shareAccessToken(widget.link.shareID, widget.link.code),
      ]);
      _title =
          JsonDeep.findString(responses[0], const ['title', 'shareTitle']) ??
          widget.link.title ??
          '分享文件';
      _owner =
          JsonDeep.findString(responses[0], const ['nickName', 'nickname']) ??
          '';
      _accessToken =
          JsonDeep.findString(responses[1], const [
            'accessToken',
            'access_token',
          ]) ??
          '';
      if (_accessToken.isEmpty) throw Exception('无法获取分享访问令牌');
      await _loadFiles(selectAll: true);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadFiles({bool selectAll = false}) async {
    if (_accessToken.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .shareFilesList(
            _accessToken,
            parentID: _path.isEmpty ? '' : _path.last.id,
            pageSize: 1000,
          );
      final files = _extractFiles(response);
      if (!mounted) return;
      setState(() {
        _files = files;
        if (selectAll) _selected.addAll(files.map((file) => file.id));
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<CloudFile> _extractFiles(Map<String, dynamic> response) {
    final list = JsonDeep.findArray(response, const [
      'list',
      'files',
      'fileList',
      'items',
    ]);
    if (list == null) return const [];
    return list
        .whereType<Map>()
        .map((item) => CloudFile.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  String _friendlyError(Object error) => error
      .toString()
      .replaceFirst(RegExp(r'^Exception:\s*'), '')
      .replaceFirst(RegExp(r'^ApiException:\s*'), '');

  void _toggle(CloudFile file, bool selected) {
    setState(() {
      selected ? _selected.add(file.id) : _selected.remove(file.id);
    });
  }

  void _enter(CloudFile folder) {
    setState(() {
      _selected.remove(folder.id);
      _path.add(folder);
    });
    unawaited(_loadFiles());
  }

  Future<void> _chooseTarget() async {
    final result = await showShadDialog<_ShareTargetDirectory>(
      context: context,
      builder: (_) => const _ShareTargetDirectoryPicker(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _targetID = result.id;
      _targetLabel = result.label;
    });
  }

  Future<void> _restore() async {
    if (_selected.isEmpty || _restoring) return;
    setState(() => _restoring = true);
    try {
      await ref
          .read(authProvider.notifier)
          .api
          .shareRestore(
            _accessToken,
            _selected.toList(),
            parentID: _targetID ?? '',
          );
      if (!mounted) return;
      ShadToaster.maybeOf(context)?.show(
        ShadToast(
          title: const Text('转存完成'),
          description: Text('已将 ${_selected.length} 个项目转存到 $_targetLabel'),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ShadToaster.maybeOf(context)?.show(
        ShadToast.destructive(
          title: const Text('转存失败'),
          description: Text(_friendlyError(error)),
        ),
      );
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48).clamp(260.0, 620.0);
    final height = (size.height - 180).clamp(320.0, 620.0);
    return ShadDialog(
      title: Text(_title.isEmpty ? widget.link.title ?? '读取分享文件' : _title),
      description: Text(
        _owner.isEmpty ? '光鸭云盘分享' : '分享者：$_owner',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        ShadButton.outline(
          onPressed: _restoring ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: _selected.isEmpty || _restoring ? null : _restore,
          leading: _restoring
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_alt_rounded, size: 16),
          child: Text(_restoring ? '转存中' : '转存 ${_selected.length} 项'),
        ),
      ],
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _path.isEmpty
                        ? '分享根目录'
                        : _path.map((folder) => folder.name).join(' / '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.mutedForeground),
                  ),
                ),
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  onPressed: _chooseTarget,
                  leading: const Icon(Icons.folder_open_rounded, size: 15),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      _targetLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_path.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: () {
                    setState(() => _path.removeLast());
                    unawaited(_loadFiles());
                  },
                  leading: const Icon(Icons.arrow_back_rounded, size: 15),
                  child: const Text('返回上级'),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: AppLoadingIndicator(
                        size: AppLoadingSize.page,
                        label: '正在读取分享文件',
                      ),
                    )
                  : _error != null
                  ? _ErrorView(message: _error!, onRetry: _initialize)
                  : _files.isEmpty
                  ? Center(
                      child: Text(
                        '当前目录为空',
                        style: TextStyle(color: cs.mutedForeground),
                      ),
                    )
                  : Material(
                      type: MaterialType.transparency,
                      child: ListView.separated(
                        itemCount: _files.length,
                        separatorBuilder: (_, _) =>
                            const ShadSeparator.horizontal(),
                        itemBuilder: (context, index) {
                          final file = _files[index];
                          final selected = _selected.contains(file.id);
                          return InkWell(
                            onTap: () => _toggle(file, !selected),
                            child: SizedBox(
                              height: 52,
                              child: Row(
                                children: [
                                  ShadCheckbox(
                                    value: selected,
                                    onChanged: (value) => _toggle(file, value),
                                  ),
                                  const SizedBox(width: 10),
                                  FileIcon(file: file, size: 22),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          file.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          file.isDirectory
                                              ? file.directoryContentSummary ??
                                                    '文件夹'
                                              : file.formattedSize,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: cs.mutedForeground,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (file.isDirectory)
                                    ShadButton.ghost(
                                      size: ShadButtonSize.sm,
                                      onPressed: () => _enter(file),
                                      child: const Icon(
                                        Icons.chevron_right_rounded,
                                        size: 18,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareTargetDirectory {
  final String? id;
  final String label;

  const _ShareTargetDirectory(this.id, this.label);
}

class _ShareTargetDirectoryPicker extends ConsumerStatefulWidget {
  const _ShareTargetDirectoryPicker();

  @override
  ConsumerState<_ShareTargetDirectoryPicker> createState() =>
      _ShareTargetDirectoryPickerState();
}

class _ShareTargetDirectoryPickerState
    extends ConsumerState<_ShareTargetDirectoryPicker> {
  final _path = <CloudFile>[];
  var _folders = <CloudFile>[];
  var _loading = true;
  String? _error;

  String? get _parentID => _path.isEmpty ? null : _path.last.id;
  String get _label =>
      _path.isEmpty ? '云盘根目录' : _path.map((file) => file.name).join(' / ');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref
          .read(authProvider.notifier)
          .api
          .fsFiles(parentID: _parentID, pageSize: 1000);
      final list = JsonDeep.findArray(response, const [
        'list',
        'files',
        'fileList',
        'items',
      ]);
      final folders =
          (list ?? const [])
              .whereType<Map>()
              .map(
                (item) => CloudFile.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((file) => file.isDirectory)
              .toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
      if (mounted) setState(() => _folders = folders);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    return ShadDialog(
      title: const Text('选择转存目录'),
      description: Text('目标：$_label'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(_ShareTargetDirectory(_parentID, _label)),
          child: const Text('使用此目录'),
        ),
      ],
      child: SizedBox(
        width: (size.width - 48).clamp(260.0, 480.0),
        height: (size.height - 200).clamp(300.0, 420.0),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: _path.isEmpty
                    ? null
                    : () {
                        setState(() => _path.removeLast());
                        unawaited(_load());
                      },
                leading: const Icon(Icons.arrow_back_rounded, size: 15),
                child: const Text('返回上级'),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: AppLoadingIndicator())
                  : _error != null
                  ? _ErrorView(message: _error!, onRetry: _load)
                  : _folders.isEmpty
                  ? Center(
                      child: Text(
                        '当前目录没有文件夹',
                        style: TextStyle(color: cs.mutedForeground),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _folders.length,
                      itemBuilder: (context, index) {
                        final folder = _folders[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.folder_rounded,
                            color: Color(0xFFF59E0B),
                          ),
                          title: Text(
                            folder.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () {
                            setState(() => _path.add(folder));
                            unawaited(_load());
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.destructive),
          ),
          const SizedBox(height: 10),
          ShadButton.outline(
            size: ShadButtonSize.sm,
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
