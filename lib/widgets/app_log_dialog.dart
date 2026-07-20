import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../core/logging/app_logger.dart';

class AppLogDialog extends StatelessWidget {
  const AppLogDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 720;
    return ShadDialog(
      title: const Text('运行日志'),
      description: const Text('显示级别、模块、调用位置与操作上下文；Release 同时写入本地日志文件。'),
      actions: [
        ShadButton.outline(
          size: ShadButtonSize.sm,
          onPressed: AppLogger.clear,
          leading: const Icon(Icons.delete_outline_rounded, size: 16),
          child: const Text('清空显示'),
        ),
        ShadButton(
          size: ShadButtonSize.sm,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: SizedBox(
        width: compact ? screen.width - 32 : 840,
        height: compact ? (screen.height * 0.56).clamp(280, 440) : 520,
        child: ValueListenableBuilder<List<AppLogEntry>>(
          valueListenable: AppLogger.entries,
          builder: (_, entries, _) {
            if (entries.isEmpty) {
              return Center(
                child: Text(
                  '暂无运行日志',
                  style: TextStyle(color: cs.mutedForeground),
                ),
              );
            }
            return Container(
              decoration: BoxDecoration(
                color: cs.muted.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.border),
              ),
              child: ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: entries.length,
                itemBuilder: (_, index) {
                  final entry = entries[entries.length - index - 1];
                  final color = switch (entry.level) {
                    AppLogLevel.debug => cs.mutedForeground,
                    AppLogLevel.info => cs.foreground,
                    AppLogLevel.warning => cs.primary,
                    AppLogLevel.error => cs.destructive,
                  };
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: SelectableText(
                      entry.text,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.35,
                        color: color,
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
