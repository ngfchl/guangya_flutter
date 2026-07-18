import 'cloud_file.dart';

enum BatchRenameRuleKind { remove, replace, regex, prefix, suffix }

class BatchRenameRule {
  final String id;
  final bool enabled;
  final BatchRenameRuleKind kind;
  final String pattern;
  final String replacement;
  final bool ignoreCase;

  const BatchRenameRule({
    required this.id,
    this.enabled = true,
    this.kind = BatchRenameRuleKind.replace,
    this.pattern = '',
    this.replacement = '',
    this.ignoreCase = false,
  });

  BatchRenameRule copyWith({
    bool? enabled,
    BatchRenameRuleKind? kind,
    String? pattern,
    String? replacement,
    bool? ignoreCase,
  }) => BatchRenameRule(
    id: id,
    enabled: enabled ?? this.enabled,
    kind: kind ?? this.kind,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    ignoreCase: ignoreCase ?? this.ignoreCase,
  );

  String apply(String value) {
    if (!enabled) return value;
    switch (kind) {
      case BatchRenameRuleKind.remove:
        return pattern.isEmpty
            ? value
            : value.replaceAll(
                RegExp(RegExp.escape(pattern), caseSensitive: !ignoreCase),
                '',
              );
      case BatchRenameRuleKind.replace:
        return pattern.isEmpty
            ? value
            : value.replaceAll(
                RegExp(RegExp.escape(pattern), caseSensitive: !ignoreCase),
                replacement,
              );
      case BatchRenameRuleKind.regex:
        return pattern.isEmpty
            ? value
            : value.replaceAll(
                RegExp(pattern, caseSensitive: !ignoreCase),
                replacement,
              );
      case BatchRenameRuleKind.prefix:
        return '$pattern$value';
      case BatchRenameRuleKind.suffix:
        return '$value$pattern';
    }
  }
}

class BatchRenamePreview {
  final CloudFile file;
  final String newName;
  final String? error;

  const BatchRenamePreview({
    required this.file,
    required this.newName,
    this.error,
  });
  bool get changed => file.name != newName;
  bool get applicable => changed && error == null;
}

List<BatchRenamePreview> buildRenamePreviews(
  List<CloudFile> files,
  List<BatchRenameRule> rules, {
  required bool preserveExtension,
}) {
  final values = <BatchRenamePreview>[];
  for (final file in files) {
    try {
      final dot = !file.isDirectory && preserveExtension
          ? file.name.lastIndexOf('.')
          : -1;
      final base = dot > 0 ? file.name.substring(0, dot) : file.name;
      final extension = dot > 0 ? file.name.substring(dot) : '';
      final renamed =
          rules.fold(base, (value, rule) => rule.apply(value)) + extension;
      final trimmed = renamed.trim();
      values.add(
        BatchRenamePreview(
          file: file,
          newName: renamed,
          error:
              trimmed.isEmpty ||
                  renamed.contains('/') ||
                  renamed.contains('\u0000')
              ? '名称包含非法字符或为空'
              : null,
        ),
      );
    } on FormatException {
      values.add(
        BatchRenamePreview(file: file, newName: file.name, error: '正则表达式无效'),
      );
    }
  }
  final proposed = <String, int>{};
  for (final item in values.where((item) => item.applicable)) {
    final key =
        '${item.file.cloudPath.toLowerCase()}/${item.newName.toLowerCase()}';
    proposed[key] = (proposed[key] ?? 0) + 1;
  }
  return values.map((item) {
    final key =
        '${item.file.cloudPath.toLowerCase()}/${item.newName.toLowerCase()}';
    return proposed[key] != null && proposed[key]! > 1
        ? BatchRenamePreview(
            file: item.file,
            newName: item.newName,
            error: '规则产生同名项目',
          )
        : item;
  }).toList();
}
