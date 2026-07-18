import 'cloud_file.dart';

enum BatchRenameRuleKind { remove, replace, regex, prefix, suffix }

enum BatchRenameItemType { all, files, folders }

/// How a rename rule handles a destination that is already occupied.
enum BatchRenameConflictStrategy { reject, appendIndex }

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
  BatchRenameConflictStrategy conflictStrategy =
      BatchRenameConflictStrategy.reject,
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
  final existing = <String, Set<String>>{};
  for (final file in files) {
    final key = _destinationKey(file, file.name);
    (existing[key] ??= <String>{}).add(file.id);
  }
  final reserved = <String, Set<String>>{
    for (final entry in existing.entries) entry.key: {...entry.value},
  };
  final proposedCounts = <String, int>{};
  for (final item in values.where((item) => item.applicable)) {
    final key = _destinationKey(item.file, item.newName);
    proposedCounts[key] = (proposedCounts[key] ?? 0) + 1;
  }
  final result = <BatchRenamePreview>[];
  for (final item in values) {
    if (!item.applicable) {
      result.add(item);
      continue;
    }
    var targetName = item.newName;
    var targetKey = _destinationKey(item.file, targetName);
    if (conflictStrategy == BatchRenameConflictStrategy.reject &&
        proposedCounts[targetKey]! > 1) {
      result.add(
        BatchRenamePreview(
          file: item.file,
          newName: item.newName,
          error: '规则产生同名项目',
        ),
      );
      continue;
    }
    bool conflicts() =>
        reserved[targetKey]?.any((id) => id != item.file.id) ?? false;
    if (conflicts() &&
        conflictStrategy == BatchRenameConflictStrategy.appendIndex) {
      var index = 2;
      do {
        targetName = _appendIndex(item.newName, index++);
        targetKey = _destinationKey(item.file, targetName);
      } while (conflicts());
    }
    if (conflicts()) {
      result.add(
        BatchRenamePreview(
          file: item.file,
          newName: item.newName,
          error: '规则产生同名项目或目标名称已存在',
        ),
      );
      continue;
    }
    (reserved[targetKey] ??= <String>{}).add(item.file.id);
    result.add(BatchRenamePreview(file: item.file, newName: targetName));
  }
  return result;
}

String _appendIndex(String name, int index) {
  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    return '${name.substring(0, dot)} ($index)${name.substring(dot)}';
  }
  return '$name ($index)';
}

/// Collision scope is a single cloud directory, never the whole drive.
String _destinationKey(CloudFile file, String name) {
  final parentID = file.parentID?.trim();
  if (parentID != null && parentID.isNotEmpty) {
    return 'id:$parentID/${name.toLowerCase()}';
  }
  final path = file.cloudPath;
  final separator = path.lastIndexOf('/');
  final parent = separator < 0 ? '' : path.substring(0, separator);
  return '${parent.toLowerCase()}/${name.toLowerCase()}';
}
